"""`morca worker`: runs a pool's runs on this machine, talking only to
`morca ui`'s API.

```
MORCA_WORKER_TOKEN=orca_... morca worker --pool bgent --remote https://orca.mlake.dev
```

Every `--poll-seconds` (2) the worker posts its heartbeat to
`/api/worker/claim` (`orca.workers`), its name, image, CPUs, memory and
the runs it has, and, while it has fewer than `--max-runs` (1), asks for
one. A run it's given starts as the local runner starts one: the
pipeline's binary (the path it was registered with, which the worker's
image has too) with `resume <run>`, in a process group of its own, its
output staged under `--dir` (`$TMPDIR/morca-worker`), with the pipeline's
`env`, its secrets read here with `MORCA_SECRET_FETCH` and named in
`MORCA_SECRETS`, and `MORCA_STATE_URL` and `MORCA_STATE_TOKEN` in place of a
database: the run records itself over the API (`morca._internal.http_store`). Its
data and logs go where the worker's own `MORCA_WAREHOUSE` and `MORCA_LOGS`
say, as any run's do. When the process ends, its output is appended to
the run's `driver.log` by `<binary> keep-log`, which also fails the
attempts a crash left running; a process that ended before claiming its
run has the run failed, saying why (`/api/worker/exited`). Beside each
run's process it starts `<binary> sample` (`morca._internal.sample`, unless
`MORCA_SAMPLE_SECONDS=0`), which writes this machine's metrics to
`<MORCA_LOGS>/<pipeline>/<run>/metrics/worker-<name>.jsonl`, so the run's
page has its Machines card, as a local run's does. Each poll the
worker samples its runs' process trees, as the scheduler samples a local
run's, and sends the samples with `/api/worker/exited`, so their attempts
get their peak memory and CPU (`morca._internal.usage`). Where the worker can make
cgroups (`morca._internal.cgroup`), each run gets one at its grant, and an
out-of-memory kill is reported with `/api/worker/exited`, which fails the
attempts saying so and raises what the pipeline asks for.

**No database.** The worker refuses to start with `MORCA_DATABASE_URL` set:
nothing on a worker holds database credentials. Its token is
`MORCA_WORKER_TOKEN`, or the first line of `--token-file`; one that's
revoked, expired or for another pool than `--pool` is refused, and the
worker exits (code 3).

**Its pool's settings.** A pool morca.toml declares may set `max_runs`,
`env` and `secrets` for its workers (`morca._internal.pool_config`). The UI
caps each claim at the pool's `max_runs` and puts the pool's `env` and
secret IDs in each run's spec, under the pipeline's; a worker started
without `--max-runs` takes the pool's `max_runs` as its own, from the
claim's answer.

**Draining.** A worker asked to drain (`morca host drain`) is given no new
runs: it finishes those it has, keeps beating, and claims again once the
drain is lifted (`morca host undrain`).

**Following the server's image.** A worker `morca host join` installed
(`--host-image`, in a container; `--host-service`, as a service) compares
the image the server's pool workers run, which each claim's answer says,
with its own: in a container it drains, then exits 4 for its script to
start it on the server's image; as a service it says so and keeps working
(`morca._internal.host_follow`).

**Env files.** Each `--env-file` (`morca host join`'s services pass them)
is read before anything else, as Docker and systemd read one: a
`NAME=value` a line, the value as written, blank lines and `#` comments
skipped. A variable already in the environment keeps its value.

**Versions.** The worker's image is `--image`, else `MORCA_IMAGE`. A run it's
given whose pipeline's image isn't that is put back (`/api/worker/release`)
rather than started, though the UI shouldn't hand it one
(`orca.workers.version_refusal`).

**Dying.** A worker that's killed takes its runs with it: each run's
heartbeat thread exits its process once its parent isn't the worker
(`MORCA_WORKER_PID`), so the run's heartbeat goes stale and the scheduler
queues it again, for this worker or another, whatever its trigger
(`morca._internal.scheduler`'s `_requeue_lost`); a run this worker claimed and never
started has its start given back.
"""

from std.ffi import c_int, external_call
from std.os import getenv, makedirs, setenv
from std.sys.info import CompilationTarget, num_logical_cores
from std.time import perf_counter_ns, sleep

from json import Value

from morca._internal.run_cluster import MemberSpec, member_spec_of
from morca._internal.tokens import new_token
from morca._internal.worker_cluster import (
    free_port,
    start_dista_worker,
    start_head,
    stop_group,
)
from morca._internal.admission import Report
from morca._internal.cgroup import (
    Cgroups,
    Contained,
    HeldWatch,
    MemoryKnobs,
    held_text,
    own_limit_pressure,
)
from morca._internal.cgroup import put as put_cgroup
from morca._internal.offload import OffloadWatch
from morca._internal.cgroup import start_limit_mb
from morca._internal.run_cpu import CpuKnobs
from morca._internal.control import (
    fetch_secret,
    keep_log_ended,
    pool_problem,
)
from morca._internal.host_follow import UPGRADE_EXIT, Follow, image_problem
from morca._internal.http_store import Body, StateApi
from morca._internal.logs import run_dir
from morca._internal.pressure import (
    Admission,
    Source,
    find_source,
    pct_text,
    pressure_env,
    read_psi,
)
from morca._internal.proc import Reaped, reap, spawn
from morca._internal.resources import host_room, run_env as grant_env
from morca._internal.sample import (
    _hostname,
    _sysctl_u64,
    machine_name,
    metrics_location,
    parse_meminfo,
    sample_seconds,
    tree_usage,
)
from morca._internal.store import FINAL
from morca._internal.usage import Meter, marks_json
from morca._internal.workers import WorkerRun, version_refusal, worker_run_of

comptime WORKER_USAGE = """usage:
  morca worker --pool <pool> [--remote <url>] [--token-file <path>]
              [--max-runs N] [--poll-seconds S] [--dir <dir>]
              [--image <image>] [--name <name>] [--advertise <address>]
              [--env-file <path>]... [--host-image <image>]
              [--host-service systemd|launchd]
              (the token: MORCA_WORKER_TOKEN, or --token-file)"""


@fieldwise_init
struct _Running(Copyable, Movable):
    var spec: WorkerRun
    var stage: String
    var env: List[String]
    var helpers: List[Int]
    """Its cluster's head and dista worker (`morca._internal.worker_cluster`), stopped
    when it ends; empty for a run on this worker alone."""


def _memory_mb() -> Int:
    comptime if CompilationTarget.is_linux():
        try:
            with open("/proc/meminfo", "r") as f:
                var m = parse_meminfo(f.read())
                return m.get("MemTotal", 0) // (1024 * 1024)
        except:
            return 0
    else:
        return _sysctl_u64("hw.memsize") // (1024 * 1024)


def _last_line(path: String) -> String:
    """The last non-empty line of `path`, at most 300 bytes of it."""
    try:
        with open(path, "r") as f:
            var text = f.read()
            var lines = text.split("\n")
            var i = len(lines) - 1
            while i >= 0:
                var l = String(lines[i].strip())
                if l:
                    if l.byte_length() > 300:
                        return String(l[byte=:300])
                    return l^
                i -= 1
    except:
        pass
    return ""


struct Worker(Movable):
    var api: StateApi
    var token: String
    var pool: String
    var name: String
    var image: String
    var max_runs: Int
    var max_runs_given: Bool
    """`--max-runs` was given: the pool's `max_runs` doesn't replace it."""
    var draining: Bool
    """The UI last said this worker drains (`morca host drain`)."""
    var poll: Float64
    var dir: String
    var running: Dict[Int, _Running]
    """The runs' processes, by pid."""
    var keeping: Dict[Int, String]
    """`keep-log`s going, by pid, with the stage they're keeping."""
    var meters: Dict[Int, Meter]
    """The runs' processes' samples, by pid, sent when each ends
    (`morca._internal.usage`)."""
    var psi: Source
    """Where this host's memory pressure is read from (`orca.pressure`)."""
    var admission: Admission
    """Whether this worker claims runs for its host's memory pressure."""
    var cgroups: Cgroups
    """Where the runs' cgroups go (`morca._internal.cgroup`), or why they don't."""
    var contained: Dict[Int, Contained]
    """The runs' processes' cgroups, by pid."""
    var held: HeldWatch
    """Since when they have been held at their memory limit."""
    var offload: OffloadWatch
    """The most of each one's memory in swap so far (#282)."""
    var stalled: Dict[Int, Bool]
    """Those killed for being held there: out of memory at the reap."""
    var unswept: List[String]
    """Cgroups to remove once empty."""
    var room_mb: Int
    """The memory this host can grant, the limit of a run without a
    grant."""
    var advertise: String
    """The address the pool's machines reach this one at (`--advertise`):
    with it, a run that spreads is started as a cluster here, and runs are
    joined (`morca._internal.run_cluster`); without it, neither."""
    var members: Dict[Int, Int]
    """The dista workers this one runs for other workers' runs: pid to
    `orca.run_members` id."""
    var follow: Follow
    """What it does about the server's image (`morca._internal.host_follow`)."""

    def __init__(
        out self,
        url: String,
        token: String,
        pool: String,
        name: String,
        image: String,
        max_runs: Int,
        poll: Float64,
        dir: String,
        advertise: String = "",
        max_runs_given: Bool = True,
        host_image: String = "",
        host_service: String = "",
    ) raises:
        self.api = StateApi(url, token)
        self.token = token
        self.pool = pool
        self.name = name
        self.image = image
        self.max_runs = max_runs
        self.max_runs_given = max_runs_given
        self.draining = False
        self.poll = poll
        self.dir = dir
        self.running = Dict[Int, _Running]()
        self.keeping = Dict[Int, String]()
        self.meters = Dict[Int, Meter]()
        self.psi = find_source()
        self.admission = Admission.from_env()
        self.cgroups = Cgroups.off("off: not serving")
        self.contained = Dict[Int, Contained]()
        self.held = HeldWatch()
        self.offload = OffloadWatch()
        self.stalled = Dict[Int, Bool]()
        self.unswept = List[String]()
        self.room_mb = 0
        self.advertise = advertise
        self.members = Dict[Int, Int]()
        self.follow = Follow(host_image, host_service, image, dir)

    def _running_ids(self) -> String:
        var ids = String()
        for e in self.running.items():
            ids.write("," if ids else "", e.value.spec.run)
        return ids^

    def _post(self, path: String, var body: Body) raises -> Value:
        return self.api.request_once(
            path,
            body^.text("pool", self.pool).text("name", self.name).finish(),
        )

    def _start(mut self, spec: WorkerRun) raises:
        var why = version_refusal(spec.image, self.image)
        if why:
            print("morca worker: refusing run", spec.run, ":", why)
            _ = self._post(
                "/api/worker/release",
                Body()
                .int("run", Int64(spec.run))
                .int("start", Int64(spec.start))
                .text("why", why),
            )
            return
        # Its own variables and its grant of this host (morca.resources).
        var env = grant_env(spec.env, spec.grant, pressure_env(self.psi))
        var names = String()
        for s in spec.secrets:
            env.append(String(s[0], "=", fetch_secret(s[1])))
            names.write("," if names else "", s[0])
        if names:
            env.append(String("MORCA_SECRETS=", names))
        if self.image:
            env.append(String("MORCA_IMAGE=", self.image))
        env.append(String("MORCA_STATE_URL=", self.api.url))
        env.append(String("MORCA_STATE_TOKEN=", self.token))
        env.append(
            String("MORCA_WORKER_PID=", external_call["getpid", c_int]())
        )
        env.append(String("MORCA_RUN=", spec.run))
        makedirs(self.dir, exist_ok=True)
        var stage = String(
            self.dir,
            "/",
            spec.pipeline,
            "-",
            spec.run,
            "-",
            spec.start,
            "-driver.log",
        )
        with open(stage, "w") as f:
            f.write("")  # keep-log heads it with the start
        # A run that spreads over the pool (morca.run_cluster): its head and a
        # dista worker here, the driver joining them, the others told where.
        var helpers = List[Int]()
        var cluster_head = String()
        var cluster_token = String()
        if spec.members > 0 and self.advertise:
            var port = free_port()
            cluster_token = new_token()
            var base = String(
                self.dir, "/", spec.pipeline, "-", spec.run, "-", spec.start
            )
            helpers.append(
                start_head(
                    spec.binary,
                    env,
                    String(base, "-head.log"),
                    port,
                    cluster_token,
                )
            )
            helpers.append(
                start_dista_worker(
                    spec.binary,
                    env,
                    String(base, "-worker.log"),
                    String("127.0.0.1:", port),
                    self.advertise,
                    cluster_token,
                    spec.grant.cpus,
                    False,
                )
            )
            env.append(String("DISTA_HEAD=127.0.0.1:", port))
            env.append(String("DISTA_TOKEN=", cluster_token))
            cluster_head = String(self.advertise, ":", port)
        var argv: List[String] = [spec.binary, "resume", String(spec.run)]
        if spec.allow_new_code:
            argv.append("--allow-new-code")
        var cg = Contained(
            spec.run,
            spec.start,
            spec.pipeline,
            "",
            0,
            0,
            0,
            spec.grant.memory_mb,
        )
        if self.cgroups.on():
            var default = self.cgroups.knobs.default_mb
            cg.limit_mb = start_limit_mb(
                spec.grant.memory_mb,
                0,
                default if default > 0 else self.room_mb,
                0,
                0,
            )
            if cg.limit_mb > 0:
                try:
                    var made = self.cgroups.make(
                        spec.run, spec.start, cg.limit_mb, spec.grant.cpus
                    )
                    cg.path = made[0]
                    cg.kill_mb = made[1]
                except e:
                    print("morca worker: run", spec.run, "without a cgroup:", e)
        var pid = spawn(
            argv,
            stage,
            env=env,
            nice=self.cgroups.nice_for(cg.path),
            group=True,
            cgroup=cg.path,
        )
        if cg.path:
            self.contained[pid] = cg^
        self.meters[pid] = Meter()
        print(
            "started",
            spec.pipeline,
            "run",
            spec.run,
            "start",
            spec.start,
            "pid",
            pid,
            flush=True,
        )
        self.running[pid] = _Running(spec.copy(), stage, env^, helpers^)
        if cluster_head:
            try:
                _ = self._post(
                    "/api/worker/cluster",
                    Body()
                    .int("run", Int64(spec.run))
                    .int("start", Int64(spec.start))
                    .text("head", cluster_head)
                    .text("token", cluster_token),
                )
            except e:
                print("morca worker: can't report run", spec.run, "'s head:", e)
        # The machine's metrics while the run's process lives, as the
        # scheduler's beside a local run (morca.sample): the Machines card.
        var metrics = metrics_location(
            spec.pipeline, spec.run, machine_name(self.name)
        )
        if metrics and sample_seconds() > 0:
            try:
                _ = spawn(
                    [
                        spec.binary,
                        "sample",
                        "--out",
                        metrics,
                        "--pid",
                        String(pid),
                    ]
                )
            except e:
                print("morca worker: no sampler for run", spec.run, ":", e)

    def _join(mut self, m: MemberSpec) raises:
        """A dista worker for another worker's run (`morca._internal.run_cluster`).
        """
        var env = grant_env(m.env, m.grant, pressure_env(self.psi))
        for s in m.secrets:
            env.append(String(s[0], "=", fetch_secret(s[1])))
        if self.image:
            env.append(String("MORCA_IMAGE=", self.image))
        makedirs(self.dir, exist_ok=True)
        var pid = start_dista_worker(
            m.binary,
            env,
            String(
                self.dir,
                "/",
                m.pipeline,
                "-",
                m.run,
                "-",
                m.start,
                "-member-",
                m.member,
                ".log",
            ),
            m.head,
            self.advertise,
            m.token,
            m.grant.cpus,
            True,
        )
        self.members[pid] = m.member
        print(
            "joined",
            m.pipeline,
            "run",
            m.run,
            "start",
            m.start,
            "as member",
            m.member,
            "pid",
            pid,
            flush=True,
        )

    def _stop_member(mut self, member: Int):
        for e in self.members.items():
            if e.value == member:
                stop_group(e.key)
                print("stopping member", member, "pid", e.key, flush=True)
                return

    def _sample(mut self):
        """Samples each run's process tree (none on macOS)."""
        var pids = List[Int]()
        for e in self.meters.items():
            pids.append(e.key)
        for e in tree_usage(pids).items():
            try:
                self.meters[e.key].sample(e.value[0], e.value[1])
            except:
                pass

    def _ended(mut self, done: Reaped) raises:
        var pid = done.pid
        var code = done.code
        if pid in self.keeping:
            var stage = self.keeping.pop(pid)
            if not keep_log_ended(stage, code):
                print("morca worker: keep-log exited", code, "keeping", stage)
            return
        if pid in self.members:
            var member = self.members.pop(pid)
            print("member", member, "pid", pid, "exited", code, flush=True)
            _ = self._post(
                "/api/worker/left",
                Body().int("member", Int64(member)).int("code", Int64(code)),
            )
            return
        if pid not in self.running:
            return
        var r = self.running.pop(pid)
        for h in r.helpers:
            stop_group(h)
        print("run", r.spec.run, "pid", pid, "exited", code, flush=True)
        var m = self.meters.pop(pid, Meter())
        m.end(done.max_rss, done.cpu_seconds)
        var body = (
            Body()
            .int("run", Int64(r.spec.run))
            .int("start", Int64(r.spec.start))
            .int("code", Int64(code))
            .text("last", _last_line(r.stage))
            .int("pid", Int64(pid))
            .int("max_rss", Int64(m.max_rss))
            .raw("marks", marks_json(m.aged()))
        )
        if pid in self.contained:
            var cg = self.contained.pop(pid)
            var stalled = self.stalled.pop(pid, False)
            var oom = code != 0 and (stalled or Cgroups.oom_kills(cg.path) > 0)
            if oom:
                print(
                    "run", r.spec.run, "pid", pid, "out of memory", flush=True
                )
            var stall = Cgroups.stall_ms(cg.path)
            body = body^.int("memory_stall_ms", Int64(stall[0])).int(
                "memory_stall_full_ms", Int64(stall[1])
            )
            var off = self.offload.take(
                pid, cg.path, self.cgroups.knobs.swap_pct
            )
            body = body^.int(
                "memory_swap_peak_bytes", Int64(off.swap_bytes)
            ).int("memory_zswapped_peak_bytes", Int64(off.zswapped_bytes))
            body = body^.int("memory_limit_mb", Int64(cg.limit_mb)).int(
                "memory_max_mb", Int64(cg.kill_mb)
            ).int("oom", Int64(1 if oom else 0)).int(
                "held", Int64(1 if oom and stalled else 0)
            )
            _ = put_cgroup(String(cg.path, "/cgroup.kill"), "1")
            if not Cgroups.remove(cg.path):
                self.unswept.append(cg.path)
        try:
            _ = self._post("/api/worker/exited", body^)
        except e:
            print("morca worker: can't report run", r.spec.run, "ending:", e)
        var location = run_dir(r.spec.pipeline, r.spec.run)
        if location:
            # The output, masked, after what earlier starts left there; and
            # a crash's attempts failed with its summary (morca.crash).
            try:
                var kpid = spawn(
                    [
                        r.spec.binary,
                        "keep-log",
                        r.stage,
                        String(location, "/driver.log"),
                        String(r.spec.start),
                    ],
                    env=r.env,
                )
                self.keeping[kpid] = r.stage
            except e:
                print("morca worker: can't keep run", r.spec.run, "log:", e)
        else:
            print(
                "morca worker: run",
                r.spec.run,
                "output (no MORCA_LOGS) is in",
                r.stage,
            )

    def _settings(mut self, got: Value) raises:
        """What the claim's answer says of this worker: its pool's
        `max_runs`, and whether it drains."""
        if String("max_runs") in got and not self.max_runs_given:
            var n = Int(got["max_runs"].int_value())
            if n >= 1 and n != self.max_runs:
                print(
                    "morca worker: up to",
                    n,
                    "runs at once (the pool's max_runs)",
                    flush=True,
                )
                self.max_runs = n
        var draining = String("draining") in got
        if draining and not self.draining:
            print("morca worker:", got["draining"].string_value(), flush=True)
        elif self.draining and not draining:
            print("morca worker: no longer draining", flush=True)
        self.draining = draining

    def serve(mut self) raises -> Int:
        print(
            "morca worker",
            self.name,
            "pool",
            self.pool,
            "image",
            self.image if self.image else String("(none)"),
            "on",
            self.api.url,
            flush=True,
        )
        var cpus = num_logical_cores()
        var mem = _memory_mb()
        # What this host can grant the runs it takes (morca.resources).
        var room = host_room(worker=True)
        print(
            "morca worker: grants up to",
            room.cpus,
            "CPUs and",
            room.memory_mb,
            "MB (MORCA_RESERVE_CPUS, MORCA_RESERVE_MEMORY_MB)",
            flush=True,
        )
        if not self.psi:
            print(
                "morca worker: no memory pressure to read here (no PSI);",
                " runs are claimed on --max-runs and grants alone",
                sep="",
                flush=True,
            )
        else:
            print(
                "morca worker: memory pressure from",
                self.psi.describe(),
                "- claims nothing while some avg10 is over",
                String(pct_text(self.admission.limit), "%"),
                flush=True,
            )
        self.room_mb = room.memory_mb
        self.cgroups = Cgroups.setup(
            MemoryKnobs.from_env(), CpuKnobs.from_env()
        )
        print("morca worker: run cgroups", self.cgroups.why, flush=True)
        print(
            "morca worker: runs' CPU priority:",
            self.cgroups.cpu_text(),
            flush=True,
        )
        print("morca worker: runs' swap:", self.cgroups.swap_text(), flush=True)
        self.unswept = self.cgroups.stale()
        self.follow.start()
        var said = String()
        while True:
            for done in reap():
                try:
                    self._ended(done)
                except e:
                    print("morca worker:", e)
            if len(self.unswept) > 0:
                var left = List[String]()
                for path in self.unswept:
                    if not Cgroups.remove(path):
                        left.append(path)
                self.unswept = left^
            self._sample()
            self.offload.sample(self.contained, self.cgroups.knobs.swap_pct)
            var held_s = self.cgroups.knobs.held_s
            for pid in self.held.due(self.contained, held_s):
                self.stalled[pid] = True
                # Its own process group (spawned with group=True).
                _ = external_call["kill", c_int](c_int(-pid), c_int(9))
                try:
                    ref c = self.contained[pid]
                    print(
                        "morca worker: killed run",
                        c.run,
                        "pid",
                        pid,
                        String("(", held_text(c, held_s), ")"),
                        flush=True,
                    )
                except:
                    pass
            var slots = self.max_runs - len(self.running) - len(self.members)
            if self.follow.draining():
                slots = 0  # to move to the server's image
            # Memory pressure (orca.pressure): no claim while this host is
            # over the limit, but one at a time once a hold has lasted its
            # grace with none of its runs going.
            var now = Float64(Int(perf_counter_ns())) / 1e9
            var idle = len(self.running) == 0
            var was = self.admission.held()
            if self.psi:
                self.admission.observe(
                    read_psi(self.psi.path),
                    now,
                    idle,
                    own_limit_pressure(self.contained),
                )
            var allowed = self.admission.allows(idle)
            if allowed == 0:
                slots = 0
            elif allowed > 0:
                slots = min(slots, allowed)
            if self.admission.held() and not was:
                print(
                    "morca worker:",
                    self.admission.hold,
                    "- claiming no runs",
                    flush=True,
                )
            elif was and not self.admission.held():
                print("morca worker: memory pressure eased", flush=True)
            if self.admission.stuck:
                print(
                    "morca worker: memory pressure held past",
                    Int(self.admission.grace),
                    "s with none of its runs going: one at a time",
                    flush=True,
                )
            var got: Value
            try:
                got = self._post(
                    "/api/worker/claim",
                    Body()
                    .text("image", self.image)
                    .int("slots", Int64(slots))
                    .text("running", self._running_ids())
                    .int("cpus", Int64(cpus))
                    .int("memory_mb", Int64(mem))
                    .int("room_cpus", Int64(room.cpus))
                    .int("room_memory_mb", Int64(room.memory_mb))
                    .text("advertise", self.advertise)
                    .text("host_image", self.follow.host_image)
                    .text("host_upgrade", self.follow.state())
                    .raw(
                        "pressure",
                        Report.of(self.psi, self.admission, now).json(),
                    ),
                )
            except e:
                var msg = String(e)
                if msg.startswith(FINAL):
                    print(
                        "morca worker: refused:",
                        String(msg[byte = FINAL.byte_length() :]),
                        flush=True,
                    )
                    return 3
                if msg != said:
                    print("morca worker:", msg, flush=True)
                    said = msg
                sleep(self.poll)
                continue
            said = ""
            self._settings(got)
            self.follow.observe(got, len(self.running))
            # Drained: nothing running, nothing just given to start.
            var given = not got["run"].is_null() or (
                String("join") in got and not got["join"].is_null()
            )
            if (
                self.follow.draining()
                and not given
                and len(self.running) == 0
                and len(self.members) == 0
                and len(self.keeping) == 0
            ):
                self.follow.leave()
                return UPGRADE_EXIT
            if String("refused") in got:
                var why = got["refused"].string_value()
                print("morca worker: not given a run:", why, flush=True)
            if String("stop") in got:
                for s in got["stop"].array_items():
                    self._stop_member(Int(s.int_value()))
            if String("join") in got and not got["join"].is_null():
                var m = member_spec_of(got["join"])
                try:
                    self._join(m)
                except e:
                    print("morca worker: can't join run", m.run, ":", e)
                    _ = self._post(
                        "/api/worker/left",
                        Body().int("member", Int64(m.member)).int("code", 127),
                    )
                continue
            if not got["run"].is_null():
                var spec = worker_run_of(got["run"])
                try:
                    self._start(spec)
                except e:
                    print("morca worker: can't start run", spec.run, ":", e)
                    try:
                        _ = self._post(
                            "/api/worker/exited",
                            Body()
                            .int("run", Int64(spec.run))
                            .int("start", Int64(spec.start))
                            .int("code", Int64(127))
                            .text("last", String(e)),
                        )
                    except:
                        pass
                continue  # ask again at once while there's room
            sleep(self.poll)


def _usage(msg: String) -> Int:
    print(msg)
    print(WORKER_USAGE)
    return 2


def env_file_pairs(text: String) raises -> List[Tuple[String, String]]:
    """The variables of an env file's `text`: `NAME=value` lines, the value
    as written (no quotes taken off, as Docker's `--env-file`), blank and
    `#` lines skipped. Raises on any other line, saying which."""
    var out = List[Tuple[String, String]]()
    var n = 0
    for raw in text.split("\n"):
        n += 1
        var line = String(raw.rstrip("\r"))
        var bare = String(line.strip())
        if not bare or bare.startswith("#"):
            continue
        var eq = line.find("=").or_else(-1)
        var name = String(line[byte=:eq].strip()) if eq > 0 else String()
        if eq <= 0 or not name or " " in name:
            raise Error("line ", n, " isn't NAME=value")
        out.append((name, String(line[byte = eq + 1 :])))
    return out^


def load_env_file(path: String) raises:
    """Sets the variables of the env file at `path` that aren't set."""
    var text: String
    with open(path, "r") as f:
        text = f.read()
    var pairs: List[Tuple[String, String]]
    try:
        pairs = env_file_pairs(text)
    except e:
        raise Error("morca worker: ", path, ": ", e)
    for p in pairs:
        if not getenv(p[0]):
            _ = setenv(p[0], p[1], False)


def worker_command(args: List[String], target: String) raises -> Int:
    """`morca worker ...`, to the UI `target` unless `--remote` follows."""
    # Its env files first: they give what the defaults below read.
    var k = 2
    while k + 1 < len(args):
        if args[k] == "--env-file":
            try:
                load_env_file(args[k + 1])
            except e:
                return _usage(String(e))
        k += 2
    var url = target
    if not url:
        url = getenv("MORCA_REMOTE")
    var pool = String()
    var token_file = String()
    var max_runs = 1
    var max_runs_given = False
    var poll = 2.0
    var dir = String(getenv("TMPDIR", "/tmp").rstrip("/"), "/morca-worker")
    var image = getenv("MORCA_IMAGE")
    var name = _hostname()
    var advertise = getenv("MORCA_WORKER_ADVERTISE")
    var host_image = String()
    var host_service = String()
    var i = 2
    while i < len(args):
        var a = args[i]
        if i + 1 >= len(args):
            return _usage(String(a, " needs a value"))
        var val = args[i + 1]
        if a == "--pool":
            pool = val
        elif a == "--remote" or a == "--url":
            url = val
        elif a == "--token-file":
            token_file = val
        elif a == "--max-runs":
            try:
                max_runs = Int(val)
                max_runs_given = True
            except:
                return _usage("--max-runs is a count")
        elif a == "--poll-seconds":
            try:
                poll = Float64(val)
            except:
                return _usage("--poll-seconds is a number")
        elif a == "--dir":
            dir = val
        elif a == "--image":
            image = val
        elif a == "--name":
            name = val
        elif a == "--advertise":
            advertise = val
        elif a == "--host-image":
            var p = image_problem(val)
            if p:
                return _usage(String("--host-image: ", p))
            host_image = val
        elif a == "--host-service":
            if val != "systemd" and val != "launchd":
                return _usage("--host-service is systemd or launchd")
            host_service = val
        elif a == "--env-file":
            pass  # read above
        else:
            return _usage(String("unknown argument: ", a))
        i += 2
    if getenv("MORCA_DATABASE_URL"):
        print(
            "morca worker: MORCA_DATABASE_URL is set, and a worker talks only",
            " to morca ui's API: unset it",
            sep="",
        )
        return 2
    if not pool:
        return _usage("morca worker needs --pool")
    var why = pool_problem(pool)
    if why:
        return _usage(String("morca worker: ", why))
    if max_runs < 1:
        return _usage("--max-runs is at least 1")
    if not url:
        return _usage(
            "morca worker needs the UI: --remote <url>, or MORCA_REMOTE"
        )
    if not url.startswith("http://") and not url.startswith("https://"):
        url = String("https://", url)
    var token = getenv("MORCA_WORKER_TOKEN")
    if token_file:
        with open(token_file, "r") as f:
            token = String(f.read().split("\n")[0].strip())
    if not token:
        return _usage(
            "morca worker needs a token: MORCA_WORKER_TOKEN, or --token-file"
        )
    var w = Worker(
        url,
        token,
        pool,
        name,
        image,
        max_runs,
        poll,
        dir,
        advertise,
        max_runs_given,
        host_image,
        host_service,
    )
    return w.serve()
