"""Runs on Kubernetes: a dista cluster per run, made and removed by the
scheduler (K8S.md).

With `MORCA_RUNNER=kubernetes`, the scheduler starts a run by creating, in
`MORCA_RUNS_NAMESPACE` (default `morca-runs`), from the image the pipeline
was registered with (`morca register --image`):

| Object | |
|---|---|
| A Job, `morca-<run>-<start>` | the driver: `<binary> resume <run>` |
| A Pod and a Service, `morca-<run>-<start>-head` | the dista head, for a pipeline with tasks |
| `workers` Pods, `morca-<run>-<start>-worker-<i>` | dista's workers, for a pipeline with tasks |

All are labelled `orca.run`, `orca.start` (the run's start count),
`orca.pipeline` and `orca.role`, and the head, its Service and the workers
are owned by the Job, so deleting the Job deletes them. The Job has
`activeDeadlineSeconds` (`MORCA_RUN_DEADLINE`, default a day) and
`ttlSecondsAfterFinished` (10 minutes), and `backoffLimit: 0`, as morca
retries runs itself. The driver reaches Postgres through the Secret
`MORCA_RUN_SECRET` (default `morca-db`, key `url`) in that namespace, and the
head through `DISTA_HEAD`; the scheduler's variables named in
`MORCA_RUN_ENV` are copied to every pod.

A run's secrets (`secrets` in morca.toml), read by the scheduler as it
starts the run (`morca._internal.control.fetch_secret`), go into a Secret of
the run's own, `morca-<run>-<start>-secrets`, which every pod's variables of
those names refer to (`secretKeyRef`), so the Job and Pod objects hold only
its name. `MORCA_SECRETS` names them, and each container's output goes
through its binary's `mask` (`morca._internal.logs.mask_main`), so the pods'
logs hold `***` instead of the values; the scheduler masks the driver log it
keeps with the Secret's values too. The Secret goes with the run's other
objects in `sweep`.

Every tick, `sweep` deletes the objects of a run that isn't running at that
start any more, and those of a Job that has finished, first appending its
driver pod's log to the run's `driver.log` under `MORCA_LOGS`: what's left after a
run ends, a run restarted on a new cluster, and what a scheduler that was
killed left behind. Each pod's command runs with the sampler beside it
(`morca._internal.sample`, unless `MORCA_SAMPLE_SECONDS=0`), whose lines go to the
pod's log prefixed `orca-sample `; before a finished Job is deleted, each
of its pods' lines are kept in the run's `metrics/<pod>.jsonl` and left out
of `driver.log`. A run ends when its driver says so, before its pods
have, so the Job of a run that ended in the last `MORCA_KUBE_SETTLE_SECONDS`
(30) is kept until it finishes: its pods' last lines and samples are in
their logs by then, even a run shorter than its sampler's start. A pod deleted before its Job finishes takes its samples
with it, as it does its log. Pods ask for `MORCA_DRIVER_CPU`, `MORCA_HEAD_CPU` and
`MORCA_WORKER_CPU` (default 500m, 250m and 1) and `MORCA_POD_MEMORY` (512Mi)
each; `cpu_millis` is a run's total, which the scheduler checks against
`MORCA_VCPU_BUDGET` before making a cluster.
"""

from std.os import getenv

from json import Value
from std.base64 import b64decode

from k8s import JOBS, PODS, SERVICES, Client, Config, Resource
import morca._internal.db.kube as kube_db

from morca._internal.crash import crash_summary
from morca._internal.json import quote
from morca._internal.logs import (
    location_exists,
    mask_values,
    read_location,
    run_dir,
    write_location,
)
from morca._internal.sample import PREFIX, metrics_location, sample_seconds
from morca._internal.state import State

comptime DISTA_PORT = 6390

comptime SECRETS = Resource("/api/v1", "secrets")

comptime _SAMPLED = (
    '"$0" "$@" & m=$!; trap \'kill -TERM $m 2>/dev/null\' TERM INT; (unset'
    ' DISTA_ROLE; exec "$0" sample --out - --pid $m) & s=$!; while :; do'
    " wait $m; c=$?; kill -0 $m 2>/dev/null || break; done; wait $s; exit $c"
)
"""A container's script with the sampler beside its command (`$0 $@`):
signals go to the command, and the container exits with its code once the
sampler has written its last line."""

comptime _MASKED_SAMPLED = (
    'f=/tmp/morca-out.$$; mkfifo "$f" || exit 1; (unset DISTA_ROLE; exec'
    ' "$0" mask) < "$f" & k=$!; exec > "$f" 2>&1; rm -f "$f"; "$0" "$@" &'
    " m=$!; trap 'kill -TERM $m 2>/dev/null' TERM INT; (unset DISTA_ROLE;"
    ' exec "$0" sample --out - --pid $m) & s=$!; while :; do wait $m; c=$?;'
    " kill -0 $m 2>/dev/null || break; done; wait $s; exec > /dev/null"
    " 2>&1; wait $k; exit $c"
)
"""`_SAMPLED` with the container's output, the command's and the sampler's,
going through `$0 mask` (`morca._internal.logs.mask_main`) on its way to the
pod's log, for a run with secrets: the container exits once that has written
the last line."""

comptime _MASKED = (
    'f=/tmp/morca-out.$$; mkfifo "$f" || exit 1; (unset DISTA_ROLE; exec'
    ' "$0" mask) < "$f" & k=$!; exec > "$f" 2>&1; rm -f "$f"; "$0" "$@" &'
    " m=$!; trap 'kill -TERM $m 2>/dev/null' TERM INT; while :; do wait $m;"
    " c=$?; kill -0 $m 2>/dev/null || break; done; exec > /dev/null 2>&1;"
    " wait $k; exit $c"
)
"""`_MASKED_SAMPLED` without the sampler."""


def _command(var argv: List[String], masked: Bool = False) -> String:
    """A container's `command`: `argv`, with the sampler (`morca._internal.sample`)
    beside it unless `MORCA_SAMPLE_SECONDS=0`. Its lines go to the pod's
    log, prefixed, and the scheduler moves them to the run's metrics. With
    `masked`, for a run with secrets, the output goes through `$0 mask`."""
    var out = String("[")
    var sampled = sample_seconds() > 0
    if masked:
        out.write(
            '"/bin/sh", "-c", ',
            quote(_MASKED_SAMPLED if sampled else _MASKED),
            ", ",
        )
    elif sampled:
        out.write('"/bin/sh", "-c", ', quote(_SAMPLED), ", ")
    for i in range(len(argv)):
        out.write(", " if i else "", quote(argv[i]))
    out.write("]")
    return out^


def split_samples(text: String) -> Tuple[String, String]:
    """A pod's log as its own lines and the sampler's, the prefix dropped."""
    var own = String()
    var samples = String()
    for line in text.splitlines():
        if line.startswith(PREFIX):
            samples.write(line[byte = PREFIX.byte_length() :], "\n")
        else:
            own.write(line, "\n")
    return (own^, samples^)


def cpu_millis(s: String) raises -> Int:
    """A CPU quantity, `500m` or `2` or `1.5`, in thousandths."""
    if s.endswith("m"):
        return Int(s[byte = : s.byte_length() - 1])
    return Int(Float64(s) * 1000.0 + 0.5)


@fieldwise_init
struct RunSpec(Copyable, Movable):
    """What one start of a run needs made."""

    var run: Int
    var start: Int
    var pipeline: String
    var image: String
    var binary: String
    var workers: Int
    """0 for a pipeline without dista tasks: no head, no workers."""
    var allow_new_code: Bool
    var env: List[Tuple[String, String]]
    """The pipeline's own variables (morca.toml's `env`), given to every pod
    over those `MORCA_RUN_ENV` names."""
    var secrets: List[Tuple[String, String]]
    """The run's secrets, (NAME, value): in the run's Secret, which every
    pod's NAME refers to, over the variables above of that name."""


def secret_name(run: Int, start: Int) -> String:
    """The run's Secret, for a run with secrets."""
    return String("morca-", run, "-", start, "-secrets")


def secret_env(
    names: List[String], secret: String, extra: String = ""
) -> String:
    """JSON `env` entries for the variables `names`, each from key NAME of
    the Secret `secret`, and `MORCA_SECRETS` naming them, after `extra`;
    `extra` alone for no names."""
    if len(names) == 0:
        return extra
    var got = String(extra)
    var listed = String()
    for n in names:
        got.write(
            ", " if got else "",
            '{"name": ',
            quote(n),
            ', "valueFrom": {"secretKeyRef": {"name": ',
            quote(secret),
            ', "key": ',
            quote(n),
            "}}}",
        )
        listed.write("," if listed else "", n)
    got.write(', {"name": "MORCA_SECRETS", "value": ', quote(listed), "}")
    return got^


def pod_env(
    copied: List[String],
    own: List[Tuple[String, String]],
    extra: String,
    taken: List[String] = [],
) -> String:
    """A container's `env`: the scheduler's variables named in `copied`
    (`MORCA_RUN_ENV`) but those the pipeline sets itself, the pipeline's own
    (`own`), then `extra`, JSON entries; none of the first two named in
    `taken` (the run's secrets and `MORCA_SECRETS`, which `extra` sets)."""
    var out = String("[")
    var first = True
    var names = copied.copy()
    # The sampler's interval, as the scheduler has it.
    if "MORCA_SAMPLE_SECONDS" not in names:
        names.append("MORCA_SAMPLE_SECONDS")
    for n in names:
        var mine = n in taken
        for kv in own:
            if kv[0] == n:
                mine = True
        var v = getenv(n)
        if not v or mine:
            continue
        out.write(
            "" if first else ", ",
            '{"name": ',
            quote(n),
            ', "value": ',
            quote(v),
            "}",
        )
        first = False
    for kv in own:
        if kv[0] in taken:
            continue
        out.write(
            "" if first else ", ",
            '{"name": ',
            quote(kv[0]),
            ', "value": ',
            quote(kv[1]),
            "}",
        )
        first = False
    if extra:
        out.write("" if first else ", ", extra)
    out.write("]")
    return out^


struct KubeRunner(Movable):
    var k: Client
    var namespace: String
    var secret: String
    var driver_cpu: Int
    var head_cpu: Int
    var worker_cpu: Int
    var memory: String
    var deadline: Int
    var env: List[String]
    """Names of the scheduler's variables copied to every pod."""

    def __init__(out self) raises:
        self.namespace = getenv("MORCA_RUNS_NAMESPACE", "morca-runs")
        var cfg = Config.load()
        cfg.namespace = self.namespace
        self.k = Client(cfg^)
        self.secret = getenv("MORCA_RUN_SECRET", "morca-db")
        self.driver_cpu = cpu_millis(getenv("MORCA_DRIVER_CPU", "500m"))
        self.head_cpu = cpu_millis(getenv("MORCA_HEAD_CPU", "250m"))
        self.worker_cpu = cpu_millis(getenv("MORCA_WORKER_CPU", "1"))
        self.memory = getenv("MORCA_POD_MEMORY", "512Mi")
        self.deadline = Int(getenv("MORCA_RUN_DEADLINE", "86400"))
        self.env = List[String]()
        for n in getenv("MORCA_RUN_ENV").split(","):
            if n.strip():
                self.env.append(String(n.strip()))

    def cpu_of(self, workers: Int) -> Int:
        """The CPU a run asks for, in thousandths: its driver, and its head
        and workers if it has any."""
        if workers == 0:
            return self.driver_cpu
        return self.driver_cpu + self.head_cpu + workers * self.worker_cpu

    def _name(self, r: RunSpec) -> String:
        return String("morca-", r.run, "-", r.start)

    def _labels(self, r: RunSpec, role: StaticString) -> String:
        return String(
            '{"orca.run": "',
            r.run,
            '", "orca.start": "',
            r.start,
            '", "orca.pipeline": ',
            quote(r.pipeline),
            ', "orca.role": "',
            role,
            '"}',
        )

    def _env(self, r: RunSpec, extra: String) -> String:
        """A container's `env`: the copied variables, the pipeline's own,
        then `extra` and the run's secrets, from its Secret."""
        var names = List[String]()
        for kv in r.secrets:
            names.append(kv[0])
        if len(names) == 0:
            return pod_env(self.env, r.env, extra)
        var taken = names.copy()
        taken.append("MORCA_SECRETS")
        return pod_env(
            self.env,
            r.env,
            secret_env(names, secret_name(r.run, r.start), extra),
            taken,
        )

    def _resources(self, cpu: Int) -> String:
        return String(
            '{"requests": {"cpu": "',
            cpu,
            'm", "memory": ',
            quote(self.memory),
            "}}",
        )

    def _pod(
        self,
        r: RunSpec,
        name: String,
        role: StaticString,
        owner: String,
        command: String,
        env: String,
        cpu: Int,
    ) -> String:
        return String(
            '{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": ',
            quote(name),
            ', "labels": ',
            self._labels(r, role),
            ', "ownerReferences": [',
            owner,
            ']}, "spec": {"restartPolicy": "Never", "containers": [{"name":',
            ' "main", "image": ',
            quote(r.image),
            ', "imagePullPolicy": "IfNotPresent", "command": ',
            command,
            ', "env": ',
            self._env(r, env),
            ', "resources": ',
            self._resources(cpu),
            "}]}}",
        )

    def start(self, r: RunSpec) raises:
        """Makes the run's Secret if it has secrets, its driver Job, and its
        head, Service and workers if it has tasks."""
        var name = self._name(r)
        var head = String(name, "-head")
        var masked = len(r.secrets) > 0
        if masked:
            var data = String("{")
            for kv in r.secrets:
                data.write(
                    "" if data == "{" else ", ",
                    quote(kv[0]),
                    ": ",
                    quote(kv[1]),
                )
            data.write("}")
            _ = self.k.create(
                SECRETS,
                String(
                    '{"apiVersion": "v1", "kind": "Secret", "metadata":',
                    ' {"name": ',
                    quote(secret_name(r.run, r.start)),
                    ', "labels": ',
                    self._labels(r, "secrets"),
                    '}, "type": "Opaque", "stringData": ',
                    data,
                    "}",
                ),
            )
        var args: List[String] = [r.binary, "resume", String(r.run)]
        if r.allow_new_code:
            args.append("--allow-new-code")
        var argv = _command(args^, masked)
        var driver_env = String(
            '{"name": "MORCA_DATABASE_URL", "valueFrom": {"secretKeyRef":',
            ' {"name": ',
            quote(self.secret),
            ', "key": "url"}}}, {"name": "MORCA_STALE_SECONDS", "value": ',
            quote(getenv("MORCA_STALE_SECONDS", "30")),
            '}, {"name": "MORCA_IMAGE", "value": ',
            quote(r.image),
            "}",
        )
        if r.workers > 0:
            driver_env.write(
                ', {"name": "DISTA_HEAD", "value": "',
                head,
                ":",
                DISTA_PORT,
                '"}',
            )
        var job = String(
            '{"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": ',
            quote(name),
            ', "labels": ',
            self._labels(r, "driver"),
            '}, "spec": {"backoffLimit": 0, "activeDeadlineSeconds": ',
            self.deadline,
            ', "ttlSecondsAfterFinished": 600, "template": {"metadata":',
            ' {"labels": ',
            self._labels(r, "driver"),
            '}, "spec": {"restartPolicy": "Never", "containers": [{"name":',
            ' "driver", "image": ',
            quote(r.image),
            ', "imagePullPolicy": "IfNotPresent", "command": ',
            argv,
            ', "env": ',
            self._env(r, driver_env),
            ', "resources": ',
            self._resources(self.driver_cpu),
            "}]}}}}",
        )
        var made: Value
        try:
            made = self.k.create(JOBS, job)
        except e:
            if masked:
                try:
                    _ = self.k.delete(SECRETS, secret_name(r.run, r.start))
                except:
                    pass  # sweep's, then
            raise e^
        if r.workers == 0:
            return
        var owner = String(
            '{"apiVersion": "batch/v1", "kind": "Job", "name": ',
            quote(name),
            ', "uid": ',
            quote(made.at("/metadata/uid").string_value()),
            "}",
        )
        var bin = _command([r.binary], masked)
        _ = self.k.create(
            PODS,
            self._pod(
                r,
                head,
                "head",
                owner,
                bin,
                String(
                    '{"name": "DISTA_ROLE", "value": "head"}, {"name":',
                    ' "DISTA_PORT", "value": "',
                    DISTA_PORT,
                    '"}',
                ),
                self.head_cpu,
            ),
        )
        _ = self.k.create(
            SERVICES,
            String(
                '{"apiVersion": "v1", "kind": "Service", "metadata": {"name": ',
                quote(head),
                ', "labels": ',
                self._labels(r, "head"),
                ', "ownerReferences": [',
                owner,
                ']}, "spec": {"selector": ',
                self._labels(r, "head"),
                ', "ports": [{"port": ',
                DISTA_PORT,
                "}]}}",
            ),
        )
        for i in range(r.workers):
            _ = self.k.create(
                PODS,
                self._pod(
                    r,
                    String(name, "-worker-", i),
                    "worker",
                    owner,
                    bin,
                    String(
                        '{"name": "DISTA_ROLE", "value": "worker"}, {"name":',
                        ' "DISTA_HEAD", "value": "',
                        head,
                        ":",
                        DISTA_PORT,
                        '"}, {"name": "DISTA_ADVERTISE", "valueFrom":',
                        ' {"fieldRef": {"fieldPath": "status.podIP"}}}',
                    ),
                    self.worker_cpu,
                ),
            )

    def _keep_logs(self, mut db: State, job: Value):
        """Appends the log of the Job's driver pod to the run's `driver.log`
        under `MORCA_LOGS`, and keeps each of its pods' samples in the run's
        `metrics/<pod>.jsonl`, as the pods are about to go. A driver that
        crashed has the attempts it left running failed with the crash's
        first frames (`morca._internal.crash`), if the run is still at that start.
        """
        try:
            var run = Int(job.at("/metadata/labels/orca.run").string_value())
            var pipeline = job.at(
                "/metadata/labels/orca.pipeline"
            ).string_value()
            var start = job.at("/metadata/labels/orca.start").string_value()
            var at = run_dir(pipeline, run)
            if not at:
                return
            at.write("/driver.log")
            # The run's secrets, which its pods masked already: in case
            # something got past.
            var values = self._secret_values(run, Int(start))
            var text = String()
            for pod in self.k.list(
                PODS, String("orca.run=", run, ",orca.start=", start)
            ).items:
                var name = _name_of(pod)
                var log = self.k.logs(name)
                if len(values) > 0:
                    log = String(
                        from_utf8_lossy=Span(
                            mask_values(log.as_bytes(), values)
                        )
                    )
                var got = split_samples(log)
                if got[1]:
                    write_location(
                        metrics_location(pipeline, run, name),
                        got[1].as_bytes(),
                    )
                var role = pod.try_at("/metadata/labels/orca.role")
                if role and role.value().string_value() == "driver":
                    text.write(got[0])
            if not text:
                return
            var before = String()
            if location_exists(at):
                before = String(from_utf8_lossy=Span(read_location(at)))
            var all = String(before, "--- start ", start, "\n", text)
            write_location(at, all.as_bytes())
            var why = crash_summary(text)
            if why and kube_db.running_at(db.conn, run, start):
                var n = db.interrupt(run, why)
                print("run", run, "crashed,", n, "attempts failed:", why)
        except e:
            print("morca: can't keep a run's pod logs:", e)

    def _secret_values(self, run: Int, start: Int) -> List[String]:
        """The values in the run's Secret at `start`; none if it has none."""
        var out = List[String]()
        try:
            var got = self.k.get(SECRETS, secret_name(run, start))
            if not got:
                return out^
            var data = got.value().try_at("/data")
            if not data:
                return out^
            for kv in data.value().object_items():
                var bytes = b64decode(kv[1].string_value())
                out.append(String(from_utf8_lossy=Span(bytes)))
        except e:
            print("morca: can't read run", run, "'s secrets to mask:", e)
        return out^

    def remove(self, run: Int) raises:
        """Deletes everything labelled with the run, whatever its start."""
        var sel = String("orca.run=", run)
        _ = self.k.delete_all(JOBS, sel)
        _ = self.k.delete_all(SERVICES, sel)
        _ = self.k.delete_all(PODS, sel)
        _ = self.k.delete_all(SECRETS, sel)

    def sweep(self, mut db: State) raises -> Int:
        """Deletes the objects of runs that aren't running at their start,
        and of Jobs that have finished; returns how many it deleted."""
        var live = Dict[String, Bool]()
        for k in kube_db.running_keys(db.conn):
            live[k] = True
        # A run ends when its driver says so, before its pods have: their
        # last lines and samples aren't in their logs yet, and a short run
        # can end before its sampler's first line. Its Job is kept until it
        # finishes, for `MORCA_KUBE_SETTLE_SECONDS` (30) at most.
        var settling = Dict[String, Bool]()
        for k in kube_db.ended_keys(
            db.conn, Float64(getenv("MORCA_KUBE_SETTLE_SECONDS", "30"))
        ):
            settling[k] = True
        var n = 0
        for o in self.k.list(JOBS, "orca.run").items:
            var finished = (
                _count(o, "/status/succeeded") > 0
                or _count(o, "/status/failed") > 0
            )
            var key = _key(o)
            if not finished and key in settling:
                continue
            if finished or key not in live:
                self._keep_logs(db, o)
                if self.k.delete(JOBS, _name_of(o)):
                    n += 1
        # What the Job owned goes with it, but not at once, and an orphan of
        # a Job deleted by hand has no owner left to go with.
        for o in self.k.list(SERVICES, "orca.run").items:
            if _key(o) not in live:
                if self.k.delete(SERVICES, _name_of(o)):
                    n += 1
        for o in self.k.list(PODS, "orca.run").items:
            if (
                _key(o) not in live
                and _key(o) not in settling
                and not o.try_at("/metadata/deletionTimestamp")
            ):
                if self.k.delete(PODS, _name_of(o)):
                    n += 1
        # A run's Secret outlives its pods by a tick at most: after the
        # loop above has kept their logs, masked with it.
        for o in self.k.list(SECRETS, "orca.run").items:
            if _key(o) not in live and _key(o) not in settling:
                if self.k.delete(SECRETS, _name_of(o)):
                    n += 1
        return n


def _name_of(o: Value) raises -> String:
    return o.at("/metadata/name").string_value()


def _key(o: Value) raises -> String:
    """`<run>-<start>` from an object's labels."""
    var run = o.try_at("/metadata/labels/orca.run")
    var start = o.try_at("/metadata/labels/orca.start")
    if not run or not start:
        return ""
    return String(run.value().string_value(), "-", start.value().string_value())


def _count(o: Value, ptr: String) raises -> Int:
    var v = o.try_at(ptr)
    return Int(v.value().int_value()) if v else 0
