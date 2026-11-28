"""Runs on EC2: a head instance and worker instances per run, started and
ended by the scheduler (DESIGN.md, phase 5, PR 5).

With `MORCA_RUNNER=ec2` the scheduler starts a run's start `s` as:

- **a head instance** (`--head-type` at registration, else
  `MORCA_EC2_HEAD_TYPE`, on-demand): the dista head, for a pipeline with
  tasks, and the driver, `<binary> resume <run>`, beside it on localhost;
- **`workers` worker instances** (`--worker-type`, else
  `MORCA_EC2_WORKER_TYPE`; Spot with `--spot`), for a pipeline with tasks,
  started straight after with `DISTA_HEAD` at the head's private address.

Each is tagged `orca.run`, `orca.start`, `orca.pipeline` and `orca.role`,
told to terminate when it shuts down, and started from user data that runs
the pipeline's image (`MORCA_EC2_MODE=docker`, the default: `docker run
--network host`, after `MORCA_EC2_PREAMBLE`, such as an ECR login) or the
binary itself (`direct`, for the tests' stand-in EC2), then shuts down
(`MORCA_EC2_SHUTDOWN`). The head keeps the driver's output in the run's
`driver.log` (`<binary> keep-log`) before it does, and if the driver
crashed, fails the attempts it left running with the crash's first frames
(`morca._internal.crash`). Beside its work each
instance runs `<binary> sample` (`morca._internal.sample`; in docker mode as a
container with `--pid host`), whose lines its script uploads to the run's
`metrics/<role>-<instance>.jsonl` with its log (`<binary> put-log`), every
`MORCA_CLUSTER_LOG_SECONDS` and once when it ends, after telling the
sampler to write a last line and stop (`--until`).

With `--worker-procs N` (`auto`: one per vCPU of the worker type) each
worker instance's script starts `N` dista worker processes against the same
head, rather than one, since a process runs one task at a time: each takes
a port of its own, so they share the host. The script notes one that exits,
forwards a SIGTERM to all of them, and shuts the instance down once the last
has gone. Counts and costs stay in instances (`workers`, the budget); a
worker's log is its processes' logs joined.

A pipeline registered with `--workers MIN..MAX` scales: its run starts
`MIN` workers, which may be none, and every tick `scale` reads the head's
demand (`dista status --json`, from port 6390 on the head's private address,
through the pipeline's binary: `<binary> dista-status`, since dista's
sockets can't share morca's binary with flare's) and asks
`dista.scale.decide` what to do. It starts the workers asked for,
up to `MAX`, and drains the ones named with `dista drain`; a drained worker
exits once its work and results have moved, and its instance's script shuts
it down. `MORCA_SCALE_UP_AFTER` (5 s), `MORCA_SCALE_IDLE` (60 s) and
`MORCA_SCALE_STEP` (4) tune the policy. The budget counts `MAX`.

A run is scaled, and its workers are started, as its pipeline was registered
when the run started (`orca.runs.spec`, kept at each start), so registering
the pipeline again meanwhile doesn't strand a live run on settings it never
had; its next start takes the new registration.

A run that needs workers (`MAX` above 0) whose head has tasks waiting and no
worker for `MORCA_NO_WORKERS_SECONDS` (600; 0 turns it off) has the attempt
that waits fail with `no workers joined in 10 min (tasks waiting: N)`, and
its instances terminated. Its driver stops beating with them, so the
scheduler starts it again as it does a run whose process died, until its
retries are spent. Since when it has waited is `orca.runs.waiting_since`,
which the run's page shows. `timeout_seconds` on a step bounds an attempt
whatever it waits for.

A pipeline's secrets (`--secret NAME=ID`) are read by each instance's
script at start, after the preamble, with `aws secretsmanager
get-secret-value` (`MORCA_SECRET_FETCH` replaces the command, which is given
the ID), exported as NAME, given to the containers, and named in
`MORCA_SECRETS` so that every log morca writes masks them.

Every tick, `sweep` terminates the instances of runs that aren't running at
that start, and those older than `MORCA_RUN_DEADLINE` (a day). A head whose
run has just ended is left `MORCA_EC2_HEAD_GRACE` seconds (60) to finish its
script: keep the driver's log, upload its own and its samples, and shut
itself down. Instances get
`MORCA_EC2_DATABASE_URL` as `MORCA_DATABASE_URL` (the control instance's
private address), the warehouse, the logs, the region and the scheduler's
variables named in `MORCA_RUN_ENV`; `MORCA_EC2_AMI`, `MORCA_EC2_SUBNET`,
`MORCA_EC2_SECURITY_GROUP` and `MORCA_EC2_PROFILE` say where and as what they
run. `cpu_millis` is a run's instances' vCPUs, which the scheduler checks
against `MORCA_VCPU_BUDGET` first.

**The warm pool** (`MORCA_EC2_POOL_SECONDS`, 150; 0 turns it off). An
instance's script is then a loop over runs, and the next run of the same
pipeline, started as the same instances, takes its head and workers rather
than launching new ones:

- **The key.** Each instance's row has a digest of what it was started as
  (`pool_key`): role, type, market, AMI, subnet, security group, profile,
  the pipeline's registry hash, and its script but for the first run's
  line, which holds the image, binary, secrets' IDs, the environment it was
  given and its worker processes. A run takes only instances of its own
  keys, so a new registration, image or setting never reuses old ones.
- **Back to the pool.** A head's driver exits; a worker's `<binary>
  pool-wait` (`morca._internal.pool`) sees its run end and the script kills its dista
  processes, which don't end with their head. Each uploads that run's logs
  and samples and runs `<binary> pool-next`, which marks the run's row
  `idle` and beats `polled` every second until it's handed a run. Its run's
  row stays live meanwhile, so idle instances count against the budget (a
  run of the same keys counts them as its own), and `/ops/pools` shows them as
  `idle (pooled)`. A start of a pipeline waits while instances of its keys
  are still on their way there (at most the head's grace).
- **Hand-over** (`_take`). In one transaction, the idle rows of the key
  whose run has ended, that weren't drained and that beat within
  `MORCA_EC2_POOL_LIVE_SECONDS` (5) are locked `FOR UPDATE SKIP LOCKED`,
  checked with `DescribeInstances`, ended (`pooled: on to run N`) and
  replaced by rows of the new run (`pooled`); `pool-next` sees its new row,
  records that it `joined`, and the next pass runs it: a new dista head
  process for the head, new worker processes pointed at the run's head,
  secrets read again, and logs and samples under the new run. A run takes
  pooled workers up to what it starts (`MIN`, and what `scale` adds), then
  launches the rest; the others stay pooled.
- **Failure.** One handed a run that hasn't joined within
  `MORCA_EC2_POOL_JOIN_SECONDS` (30) is terminated (`pooled: never took the
  run up`) and replaced: a worker by a new worker, a head by new instances
  for the same start. The sweep ends idle instances after
  `MORCA_EC2_POOL_SECONDS` (`pooled: idle N s, shut down`), those that stop
  beating, and those that don't reach the pool within the head's grace;
  their rows end before they're terminated, so one handed on meanwhile
  isn't. An instance's tags keep its first run; the sweep goes by its live
  row. A run that's restarted, or a worker that was drained, ends as
  before.
"""

from std.base64 import b64encode
from std.os import getenv

from dista.scale import Demand, Policy, decide
from dista.socket import wall_ns
from objectstore.crypto import sha256_hex

from morca._internal.awsec2 import Ec2, Instance
import morca._internal.db.ec2 as ec2_db
from morca._internal.db.ec2 import SpecRow
from morca._internal.config import (
    env_json,
    parse_env,
)
from morca._internal.json import quote
from morca._internal.proc import capture
from morca._internal.sample import sample_seconds
from morca._internal.scale_policy import ScaleKnobs
from morca._internal.secrets import parse_secrets
from morca._internal.state import State

comptime HEAD_PORT = 6390
"""The port of a run's dista head on its head instance, unless
`MORCA_EC2_HEAD_PORT` names another (`head_port`)."""


def head_port() -> Int:
    """`MORCA_EC2_HEAD_PORT`, or `HEAD_PORT` (6390): the port a run's head
    listens on and its workers and driver reach it at. The stack's security
    group opens 6390 only; tests that run at once on one machine, where
    every stand-in instance shares 127.0.0.1, each pick their own."""
    try:
        var port = Int(getenv("MORCA_EC2_HEAD_PORT", String(HEAD_PORT)))
        if port > 0 and port < 65536:
            return port
    except:
        pass
    return HEAD_PORT


comptime _POOL_BODY = "# the pool's key is from here"
"""The line after the first run's in a pooled instance's script."""

comptime HEAD_SECONDS = 10.0
"""How long `<binary> dista-status` or `dista-drain` may take, asking a
run's head, before it's killed and the run skipped this tick."""

comptime _COPIED = [
    "MORCA_STALE_SECONDS",
    "MORCA_WAREHOUSE",
    "MORCA_LOGS",
    "AWS_REGION",
    "MORCA_HEAD_WAIT_SECONDS",
    "MORCA_SAMPLE_SECONDS",
]
"""Variables every instance gets from the scheduler's environment."""


def vcpus(instance_type: String) raises -> Int:
    """An instance type's vCPUs: from `MORCA_EC2_VCPUS` (`type=n,...`), else
    by its size, as Graviton families are sized."""
    for pair in getenv("MORCA_EC2_VCPUS").split(","):
        var eq = pair.find("=").or_else(-1)
        if eq > 0 and String(pair[byte=:eq].strip()) == instance_type:
            return Int(pair[byte = eq + 1 :].strip())
    var dot = instance_type.find(".").or_else(-1)
    if dot < 0:
        raise Error("morca: not an instance type: ", instance_type)
    var family = String(instance_type[byte=:dot])
    var size = String(instance_type[byte = dot + 1 :])
    if family.startswith("t"):
        if size == "xlarge":
            return 4
        if size == "2xlarge":
            return 8
        return 2
    if size == "medium":
        return 1
    if size == "large":
        return 2
    if size == "xlarge":
        return 4
    if size.endswith("xlarge"):
        return Int(size[byte = : size.byte_length() - 6]) * 4
    raise Error(
        "morca: the vCPUs of ",
        instance_type,
        " aren't known; set MORCA_EC2_VCPUS",
    )


def _snapshot(mut db: State, r: Ec2Spec) raises:
    """Keeps with run `r.run` what its start `r.start` was given."""
    var secrets = String("{")
    for i in range(len(r.secrets)):
        secrets.write(
            "" if i == 0 else ", ",
            quote(r.secrets[i][0]),
            ": ",
            quote(r.secrets[i][1]),
        )
    secrets.write("}")
    var spec = String(
        '{"image": ',
        quote(r.image),
        ', "binary": ',
        quote(r.binary),
        ', "tasks": ',
        "true" if r.tasks else "false",
        ', "head_type": ',
        quote(r.head_type),
        ', "worker_type": ',
        quote(r.worker_type),
        ', "workers": ',
        r.workers,
        ', "spot": ',
        "true" if r.spot else "false",
        ', "min_workers": ',
        min(r.min_workers, r.workers),
        ', "secrets": ',
        secrets,
        ', "worker_procs": ',
        r.worker_procs,
        ', "registry_hash": ',
        quote(r.registry_hash),
        ', "env": ',
        env_json(r.env) if len(r.env) > 0 else String("{}"),
        "}",
    )
    ec2_db.save_spec(db.conn, r.run, r.start, spec)


@fieldwise_init
struct Ec2Spec(Copyable, Movable):
    """One start of a run, as the instances it needs."""

    var run: Int
    var start: Int
    var pipeline: String
    var image: String
    var binary: String
    var tasks: Bool
    """Whether the pipeline calls dista tasks: a head and workers."""
    var head_type: String
    var worker_type: String
    var workers: Int
    var spot: Bool
    var allow_new_code: Bool
    var min_workers: Int
    """The workers it starts with; fewer than `workers`, it scales."""
    var secrets: List[Tuple[String, String]]
    """Environment variable and Secrets Manager ID of each secret."""
    var worker_procs: Int
    """The dista worker processes on each worker instance; 0 is one per
    vCPU of the worker type."""
    var registry_hash: String
    """The pipeline's code, which an instance from the pool must have been
    started with."""
    var env: List[Tuple[String, String]]
    """The pipeline's own variables (morca.toml's `env`), exported on every
    instance over those `MORCA_RUN_ENV` names, and so part of the pool's
    key."""


def _sets(r: Ec2Spec, name: String) -> Bool:
    """Whether the pipeline's own `env` has `name`."""
    for kv in r.env:
        if kv[0] == name:
            return True
    return False


def _spec(row: SpecRow, tasks: Bool, min_workers: Int) raises -> Ec2Spec:
    """The start `row` reads, with `tasks` and `min_workers` as given."""
    return Ec2Spec(
        row.run,
        row.start,
        row.pipeline,
        row.image,
        row.binary_path,
        tasks,
        row.head_type,
        row.worker_type,
        row.hi,
        row.spot,
        row.allow_new_code,
        min_workers,
        parse_secrets(row.secrets),
        row.procs,
        row.registry_hash,
        parse_env(row.env),
    )


def _quote(s: String) -> String:
    """`s` as one shell word."""
    return String("'", s.replace("'", "'\\''"), "'")


struct Ec2Runner(Movable):
    var ec2: Ec2
    var mode: String
    var head_type: String
    var worker_type: String
    var deadline: Int
    var grace: Float64
    """How long a head may go on after its run ended, to shut itself
    down, before the sweep terminates it."""
    var env: List[String]
    var knobs: ScaleKnobs
    """`MORCA_SCALE_*` (`morca._internal.scale_policy`)."""
    var short_since: Dict[String, Float64]
    """For each scaling run, `run-start`, since when it's been short of
    workers: `decide`'s memory between ticks."""
    var no_workers: Int
    """`MORCA_NO_WORKERS_SECONDS` (600): how long a run whose head has tasks
    waiting and no worker may go on before its attempt is failed; 0 turns
    it off."""
    var pool_seconds: Float64
    """`MORCA_EC2_POOL_SECONDS` (150): how long an instance whose run ended
    waits, idle, to be handed another; 0 turns the pool off, and every
    instance ends with its run."""
    var pool_live: Float64
    """`MORCA_EC2_POOL_LIVE_SECONDS` (5): how recently an idle instance must
    have asked for a run (`pool-next`) to be handed one."""
    var pool_join: Float64
    """`MORCA_EC2_POOL_JOIN_SECONDS` (30): how long an instance handed a run
    has to take it up before it's terminated and replaced by a new one."""

    def __init__(out self) raises:
        self.ec2 = Ec2()
        self.mode = getenv("MORCA_EC2_MODE", "docker")
        if self.mode != "docker" and self.mode != "direct":
            raise Error(
                "morca: MORCA_EC2_MODE is docker or direct, not ", self.mode
            )
        self.head_type = getenv("MORCA_EC2_HEAD_TYPE", "c7g.large")
        self.worker_type = getenv("MORCA_EC2_WORKER_TYPE", "c7g.xlarge")
        self.deadline = Int(getenv("MORCA_RUN_DEADLINE", "86400"))
        self.grace = Float64(getenv("MORCA_EC2_HEAD_GRACE", "60"))
        self.knobs = ScaleKnobs.from_env()
        self.short_since = Dict[String, Float64]()
        self.no_workers = Int(getenv("MORCA_NO_WORKERS_SECONDS", "600"))
        self.pool_seconds = Float64(getenv("MORCA_EC2_POOL_SECONDS", "150"))
        self.pool_live = Float64(getenv("MORCA_EC2_POOL_LIVE_SECONDS", "5"))
        self.pool_join = Float64(getenv("MORCA_EC2_POOL_JOIN_SECONDS", "30"))
        self.env = List[String]()
        for n in getenv("MORCA_RUN_ENV").split(","):
            if n.strip():
                self.env.append(String(n.strip()))

    def head_of(self, s: String) -> String:
        return s if s else self.head_type

    def worker_of(self, s: String) -> String:
        return s if s else self.worker_type

    def procs_of(self, r: Ec2Spec) raises -> Int:
        """The dista worker processes on each of the run's worker
        instances: `worker_procs`, or one per vCPU for `auto` (0)."""
        if r.worker_procs > 0:
            return r.worker_procs
        return max(vcpus(self.worker_of(r.worker_type)), 1)

    def cpu_of(
        self, tasks: Bool, head_type: String, worker_type: String, workers: Int
    ) raises -> Int:
        """A run's instances' vCPUs, in thousandths."""
        var n = vcpus(self.head_of(head_type))
        if tasks:
            n += workers * vcpus(self.worker_of(worker_type))
        return n * 1000

    def _exports(
        self, r: Ec2Spec, role: StaticString, head: String, pool: Bool
    ) -> String:
        """The script's environment: what every instance gets, and its
        role's own."""
        var out = String()
        var url = getenv("MORCA_EC2_DATABASE_URL", getenv("MORCA_DATABASE_URL"))
        out.write("export MORCA_DATABASE_URL=", _quote(url), "\n")
        # The run records its version with the image it ran from.
        out.write("export MORCA_IMAGE=", _quote(r.image), "\n")
        var names = List[String]()
        for n in materialize[_COPIED]():
            names.append(String(n))
        for n in self.env:
            names.append(n)
        for n in names:
            var v = getenv(n)
            if v and not _sets(r, n):
                out.write("export ", n, "=", _quote(v), "\n")
        for kv in r.env:
            out.write("export ", kv[0], "=", _quote(kv[1]), "\n")
        if role == "worker":
            # The worker's address is the instance's private one, which
            # `orca.instances` keeps: the scheduler finds the instance of a
            # worker it drains by it. Under the tests' stand-in EC2 every
            # instance's is 127.0.0.1.
            var advertise = String("127.0.0.1")
            if self.mode == "docker":
                advertise = String(
                    "$(t=$(curl -s -X PUT -H",
                    " 'X-aws-ec2-metadata-token-ttl-seconds: 60'",
                    " http://169.254.169.254/latest/api/token); curl -s -H",
                    ' "X-aws-ec2-metadata-token: $t"',
                    " http://169.254.169.254/latest/meta-data/local-ipv4)",
                )
            # A pooled worker's head is its run's, set for each run.
            if not pool:
                out.write("export DISTA_HEAD=", head, ":", head_port(), "\n")
            out.write("export DISTA_ADVERTISE=", advertise, "\n")
        return out^

    def _run(self, r: Ec2Spec, env: List[String], args: String) -> String:
        """A line running the image's binary with `args`, given the
        variables named in `env` as well as the exported ones."""
        if self.mode == "direct":
            var pre = String()
            for kv in env:
                pre.write(kv, " ")
            return String(pre, _quote(r.binary), " ", args)
        var flags = String("--rm --network host")
        var names = List[String]()
        names.append("MORCA_DATABASE_URL")
        names.append("MORCA_IMAGE")
        for n in materialize[_COPIED]():
            names.append(String(n))
        for n in self.env:
            if not _sets(r, n):
                names.append(n)
        for kv in r.env:
            names.append(kv[0])
        if len(r.secrets) > 0:
            names.append("MORCA_SECRETS")
        for s in r.secrets:
            names.append(s[0])
        for n in names:
            flags.write(" -e ", n)
        for kv in env:
            flags.write(" -e ", kv)
        return String(
            "docker run ",
            flags,
            " --entrypoint ",
            _quote(r.binary),
            " ",
            _quote(r.image),
            " ",
            args,
        )

    def _secrets(self, r: Ec2Spec) -> String:
        """Lines reading the run's secrets into its environment. A secret
        that can't be read stops the script, and the run fails."""
        if len(r.secrets) == 0:
            return ""
        var fetch = getenv(
            "MORCA_SECRET_FETCH",
            (
                'aws secretsmanager get-secret-value --region "$AWS_REGION"'
                " --query SecretString --output text --secret-id"
            ),
        )
        var out = String()
        var names = String()
        for s in r.secrets:
            out.write(
                s[0],
                "=$(",
                fetch,
                " ",
                _quote(s[1]),
                ") || { echo \"morca: can't read secret ",
                s[1],
                '"; ',
                getenv(
                    "MORCA_EC2_SHUTDOWN",
                    "shutdown -h now" if self.mode == "docker" else "true",
                ),
                "; exit 1; }\nexport ",
                s[0],
                "\n",
            )
            names.write("," if names else "", s[0])
        out.write("export MORCA_SECRETS=", names, "\n")
        return out^

    def _instance_id(self) -> String:
        """A line setting `iid` to this instance's ID: from the instance
        metadata (IMDSv2) on EC2, from `HOSTNAME` under the tests' stand-in,
        which sets it to the ID."""
        if self.mode == "direct":
            return "iid=$HOSTNAME"
        return String(
            "t=$(curl -s -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds:",
            " 60' http://169.254.169.254/latest/api/token)\niid=$(curl -s -H",
            ' "X-aws-ec2-metadata-token: $t"',
            " http://169.254.169.254/latest/meta-data/instance-id)",
        )

    def _mounted(self, line: String) -> String:
        """`line`, a container's run, with `/tmp` mounted, for the commands
        that read a log the script wrote there."""
        return line.replace("docker run --rm", "docker run --rm -v /tmp:/tmp")

    def _put(
        self, r: Ec2Spec, run: String, local: String, under_run: String
    ) -> String:
        """A command uploading the file at `local` to `under_run` in run
        `run`'s directory under MORCA_LOGS, quietly: it may not be there
        yet."""
        return String(
            self._mounted(
                self._run(
                    r,
                    List[String](),
                    String(
                        "put-log ",
                        local,
                        ' "$MORCA_LOGS/',
                        r.pipeline,
                        "/",
                        run,
                        "/",
                        under_run,
                        '"',
                    ),
                )
            ),
            " >/dev/null 2>&1",
        )

    def _worker_procs(
        self, r: Ec2Spec, env: List[String], log: String, procs: Int
    ) -> String:
        """Lines starting `procs` dista worker processes, each with its own
        port and files (a worker listens on a port of its own and names its
        files by its process), and supervising them: a process that exits is
        noticed in the log, and the lines end once all have. A SIGTERM to
        the script goes to every process, each draining as a lone worker
        does. Each process's output is `<log>.p<k>`, joined into `log` for
        the upload."""
        var s = String("pids=\nk=1\nwhile [ $k -le ", procs, " ]; do\n")
        s.write(
            "  ",
            self._run(r, env, ""),
            " > ",
            log,
            '.p$k 2>&1 &\n  pids="$pids $!"; k=$((k + 1))\ndone\n',
            (
                "trap 'for p in $pids; do kill -TERM $p 2>/dev/null; done' TERM"
                " INT\n"
            ),
            'alive=$pids\nwhile [ -n "$alive" ]; do\n  sleep 1\n  left=\n',
            "  for p in $alive; do\n",
            '    if kill -0 $p 2>/dev/null; then left="$left $p"; else\n',
            "      wait $p; rc=$?\n",
            '      echo "morca: worker process $p exited with status $rc"',
            " | tee -a ",
            log,
            ".sup\n    fi\n  done\n  alive=$left\ndone\n",
        )
        return s^

    def _join_logs(self, log: String) -> String:
        """A line joining the processes' logs into `log`."""
        return String(
            "joinlogs() { for f in ",
            log,
            ".p* ",
            log,
            '.sup; do [ -f $f ] || continue; echo "== ${f##*/} =="; cat $f;',
            " done > ",
            log,
            "; }\n",
        )

    def _pool_workers(
        self,
        r: Ec2Spec,
        env: List[String],
        log: String,
        procs: Int,
        run: String,
        start: String,
    ) -> String:
        """A pooled worker's lines for one run: its `procs` processes as
        `_worker_procs` starts them (a lone one's output straight into
        `log`), and `<binary> pool-wait` beside them. When that returns, the
        run is over: the processes are killed, since dista workers don't end
        with their head, and `over` is set, so the instance goes back to the
        pool. A process that exits on its own (drained, or lost) is noticed
        as before, and once all have, the instance shuts down."""
        var docker = self.mode == "docker"
        var line = self._run(r, env, "")
        if docker:
            # Named, so that the run's end removes them whatever they do.
            line = line.replace(
                "docker run --rm", "docker run --rm --name morca-worker-$k"
            )
        var out = String(" > ", log, ".p$k") if procs > 1 else String(
            " > ", log
        )
        # A pass's files are its run's; ones a pass of an earlier instance
        # of this ID left (as under the stand-in) aren't added to.
        var s = String("rm -f ", log, ".p* ", log, ".sup\n")
        s.write("over=\npids=\nk=1\nwhile [ $k -le ", procs, " ]; do\n")
        s.write(
            "  ",
            line,
            out,
            ' 2>&1 &\n  pids="$pids $!"; k=$((k + 1))\ndone\n',
            (
                "trap 'for p in $pids; do kill -TERM $p 2>/dev/null; done' TERM"
                " INT\n"
            ),
            self._run(
                r,
                List[String](),
                String("pool-wait $iid ", run, " ", start),
            ),
            " >/dev/null 2>&1 &\nwatch=$!\n",
            'alive=$pids\nwhile [ -n "$alive" ]; do\n  sleep 1\n',
            "  left=\n  for p in $alive; do\n",
            '    if kill -0 $p 2>/dev/null; then left="$left $p"; else\n',
            "      wait $p; rc=$?\n",
            '      echo "morca: worker process $p exited with status $rc"',
            " | tee -a ",
            log,
            ".sup\n    fi\n  done\n  alive=$left\n",
            # Those that exited first are noted, then the rest killed.
            '  if [ -n "$alive" ] && ! kill -0 $watch 2>/dev/null; then\n',
            (
                "    over=1\n    for p in $alive; do kill -9 $p 2>/dev/null;"
                " done\n"
            ),
        )
        if docker:
            s.write(
                "    k=1; while [ $k -le ",
                procs,
                " ]; do docker rm -f morca-worker-$k >/dev/null 2>&1;",
                " k=$((k + 1)); done\n",
            )
        s.write(
            "    for p in $alive; do wait $p 2>/dev/null; done\n    break\n",
            "  fi\ndone\nkill $watch 2>/dev/null\n",
        )
        return s^

    def _user_data(
        self, r: Ec2Spec, role: StaticString, head: String
    ) raises -> String:
        """The instance's script. With the pool on, its work is a loop: run
        `run` at `start`, then, back in the pool, wait for the next with
        `<binary> pool-next` (`morca._internal.pool`), which sets the run, start, head
        and new-code flag the next pass uses, or shuts down. Everything a
        pass writes and uploads is named by its run, so each run's logs and
        samples hold its own part only, and its secrets are read again."""
        var pool = self.pool_seconds > 0
        var run = String("${run}") if pool else String(r.run)
        var start = String("${start}") if pool else String(r.start)
        var s = String(
            "#!/bin/bash\n# morca run ",
            r.run,
            " start ",
            r.start,
            ": ",
            role,
            "\n",
        )
        if pool:
            # The first run's; the rest of the script is the same for every
            # run, which is what makes it the pool's key.
            s.write(
                "run=",
                r.run,
                "; start=",
                r.start,
                "; head=",
                head if head else String("-"),
                "; newcode=",
                1 if r.allow_new_code else 0,
                "\n",
                _POOL_BODY,
                "\n",
            )
        s.write(self._exports(r, role, head, pool))
        s.write(getenv("MORCA_EC2_PREAMBLE"), "\n")
        if pool:
            s.write(self._instance_id(), "\nwhile :; do\n")
            if role == "worker":
                s.write('export DISTA_HEAD="$head:', head_port(), '"\n')
        s.write(self._secrets(r))
        # The head's or worker's output, and its machine's samples
        # (morca.sample), uploaded while it runs and once when it ends: an
        # instance can go without notice.
        var keeps = role == "worker" or r.tasks
        var samples = sample_seconds() > 0 and getenv("MORCA_LOGS") != ""
        var name = String(run, "-", start, "-", role, "-$iid")
        var log = String("/tmp/morca-", name, ".log")
        var metrics = String("/tmp/morca-", name, ".jsonl")
        var stop = String("/tmp/morca-", name, ".stop")
        var procs = self.procs_of(r) if role == "worker" else 1
        if keeps or samples:
            if not pool:
                s.write(self._instance_id(), "\n")
            if procs > 1:
                s.write(self._join_logs(log))
            s.write('up() { [ -z "${MORCA_LOGS:-}" ] || {')
            if procs > 1:
                s.write(" joinlogs;")
            if keeps:
                s.write(
                    " ",
                    self._put(
                        r, run, log, String("cluster/", role, "-$iid.log")
                    ),
                    ";",
                )
            if samples:
                s.write(
                    " ",
                    self._put(
                        r,
                        run,
                        metrics,
                        String("metrics/", role, "-$iid.jsonl"),
                    ),
                    ";",
                )
            # Stopped with TERM, the loop ends between uploads: one going
            # on finishes first (the trap waits for it), so it can't land
            # after the last upload below with older lines.
            s.write(
                " }; }\n",
                "( trap 'kill $nap 2>/dev/null; exit 0' TERM; while :; do",
                " sleep ",
                getenv("MORCA_CLUSTER_LOG_SECONDS", "30"),
                " & nap=$!; wait $nap; up; done ) &\nuploader=$!\n",
            )
        if samples:
            # Beside everything else: the script's processes, and in docker
            # mode the binary's in its containers, which aren't the
            # script's children.
            var args = String(
                "sample --out ",
                metrics,
                " --pid $$ --until ",
                stop,
                " --dirs /tmp",
            )
            var line: String
            if self.mode == "docker":
                args.write(" --match ", _quote(r.binary))
                line = self._mounted(
                    self._run(r, List[String](), args)
                ).replace("docker run --rm", "docker run --rm --pid host")
            else:
                line = self._run(r, List[String](), args)
            s.write(
                "rm -f ",
                metrics,
                " ",
                stop,
                "\n",
                line,
                " >/dev/null 2>&1 &\nsampler=$!\n",
                # Its first line before the work, for up to 10 s: a run
                # shorter than that still has a sample.
                "i=0; while [ ! -s ",
                metrics,
                ' ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done\n',
            )
        if role == "worker":
            # The role goes to the worker alone: a binary given one serves
            # it, whatever its command line says.
            var env: List[String] = [String("DISTA_ROLE=worker")]
            if self.mode == "docker":
                env.append("DISTA_HEAD")
                env.append("DISTA_ADVERTISE")
            if pool:
                s.write(self._pool_workers(r, env, log, procs, run, start))
            elif procs > 1:
                s.write(self._worker_procs(r, env, log, procs))
            else:
                s.write(
                    self._run(r, env, ""),
                    " > ",
                    log,
                    " 2>&1\n",
                )
        else:
            if r.tasks:
                var line = self._run(
                    r,
                    [
                        String("DISTA_ROLE=head"),
                        String("DISTA_PORT=", head_port()),
                    ],
                    "",
                )
                if pool and self.mode == "docker":
                    line = line.replace(
                        "docker run --rm", "docker run --rm --name morca-head"
                    )
                s.write(line, " > ", log, " 2>&1 &\nhead=$!\n")
            var args = String("resume ", run)
            if pool:
                args.write(' $([ "$newcode" = 1 ] && echo --allow-new-code)')
            elif r.allow_new_code:
                args.write(" --allow-new-code")
            var env = List[String]()
            if r.tasks:
                env.append(String("DISTA_HEAD=127.0.0.1:", head_port()))
            var out = String("/tmp/morca-", run, "-", start, "-driver.log")
            s.write(self._run(r, env, args), " > ", out, " 2>&1\n")
            if r.tasks:
                s.write("kill $head 2>/dev/null\nwait $head 2>/dev/null\n")
                if pool and self.mode == "docker":
                    # Gone before the next run's head takes its port.
                    s.write("docker rm -f morca-head >/dev/null 2>&1\n")
            s.write(
                'if [ -n "${MORCA_LOGS:-}" ]; then ',
                self._mounted(
                    self._run(
                        r,
                        # Which run's attempts a crash fails (morca.crash).
                        [String("MORCA_RUN=", run)],
                        String(
                            "keep-log ",
                            out,
                            ' "$MORCA_LOGS/',
                            r.pipeline,
                            "/",
                            run,
                            '/driver.log" ',
                            start,
                        ),
                    )
                ),
                "; fi\n",
            )
        if samples:
            # Its last line, then it ends; a wedged one isn't waited for.
            s.write(
                "touch ",
                stop,
                "\n( sleep 15; kill -9 $sampler ) 2>/dev/null &\nguard=$!\n",
                "wait $sampler 2>/dev/null\nkill $guard 2>/dev/null\n",
            )
        if keeps or samples:
            s.write(
                "kill $uploader 2>/dev/null\nwait $uploader 2>/dev/null\nup\n"
            )
        if pool:
            # A worker whose processes all ended on their own (drained, or
            # lost) shuts down as before; one whose run ended, and a head
            # whose driver did, wait for the next run.
            if role == "worker":
                s.write('[ -n "$over" ] || break\n')
            s.write(
                "next=$(",
                self._run(
                    r,
                    List[String](),
                    String(
                        "pool-next $iid ",
                        run,
                        " ",
                        start,
                        " ",
                        Int(self.pool_seconds),
                    ),
                ),
                ") || break\n",
                'set -- $(echo "$next" | grep "^next " | tail -1)\n',
                '[ "${1:-}" = next ] || break\n',
                "run=$2; start=$3; head=$4; newcode=$5\ndone\n",
            )
        s.write(
            getenv(
                "MORCA_EC2_SHUTDOWN",
                "shutdown -h now" if self.mode == "docker" else "true",
            ),
            "\n",
        )
        return s^

    def pool_key(
        self, r: Ec2Spec, role: StaticString, itype: String, spot: Bool
    ) raises -> String:
        """What an instance of `r`'s in `role` is started as, as a digest:
        its type, market, image, network and profile, the pipeline's code,
        and its script but for the first run's line (the image, binary,
        secrets' IDs, environment, worker processes and the rest). An idle
        instance is handed only to a run whose key is its own, so a new
        registration, image or setting never reuses one; empty with the pool
        off."""
        if self.pool_seconds <= 0:
            return ""
        var ud = self._user_data(r, role, "-")
        var body = ud.find(_POOL_BODY).or_else(-1)
        return sha256_hex(
            String(
                role,
                "\n",
                itype,
                "\n",
                "spot" if spot else "on-demand",
                "\n",
                getenv("MORCA_EC2_AMI"),
                "\n",
                getenv("MORCA_EC2_SUBNET"),
                "\n",
                getenv("MORCA_EC2_SECURITY_GROUP"),
                "\n",
                getenv("MORCA_EC2_PROFILE"),
                "\n",
                r.registry_hash,
                "\n",
                ud[byte=body:],
            )
        )

    def pool_keys(self, r: Ec2Spec) raises -> List[String]:
        """The keys of the head and, for a pipeline with tasks, the workers
        of `r`'s runs; none with the pool off."""
        var out = List[String]()
        if self.pool_seconds <= 0:
            return out^
        out.append(self.pool_key(r, "head", self.head_of(r.head_type), False))
        if r.tasks:
            out.append(
                self.pool_key(
                    r, "worker", self.worker_of(r.worker_type), r.spot
                )
            )
        return out^

    def _params(
        self,
        r: Ec2Spec,
        role: StaticString,
        itype: String,
        count: Int,
        spot: Bool,
        head: String,
    ) raises -> List[Tuple[String, String]]:
        var p: List[Tuple[String, String]] = [
            ("ImageId", getenv("MORCA_EC2_AMI")),
            ("InstanceType", itype),
            ("MinCount", String(count)),
            ("MaxCount", String(count)),
            ("InstanceInitiatedShutdownBehavior", "terminate"),
            ("UserData", b64encode(self._user_data(r, role, head))),
            ("MetadataOptions.HttpTokens", "required"),
            ("TagSpecification.1.ResourceType", "instance"),
            ("TagSpecification.1.Tag.1.Key", "orca.run"),
            ("TagSpecification.1.Tag.1.Value", String(r.run)),
            ("TagSpecification.1.Tag.2.Key", "orca.start"),
            ("TagSpecification.1.Tag.2.Value", String(r.start)),
            ("TagSpecification.1.Tag.3.Key", "orca.pipeline"),
            ("TagSpecification.1.Tag.3.Value", r.pipeline),
            ("TagSpecification.1.Tag.4.Key", "orca.role"),
            ("TagSpecification.1.Tag.4.Value", String(role)),
            ("TagSpecification.1.Tag.5.Key", "Name"),
            (
                "TagSpecification.1.Tag.5.Value",
                String("morca-", r.run, "-", r.start, "-", role),
            ),
        ]
        var subnet = getenv("MORCA_EC2_SUBNET")
        if subnet:
            p.append(("SubnetId", subnet))
        var sg = getenv("MORCA_EC2_SECURITY_GROUP")
        if sg:
            p.append(("SecurityGroupId.1", sg))
        var profile = getenv("MORCA_EC2_PROFILE")
        if profile:
            p.append(("IamInstanceProfile.Name", profile))
        if spot:
            p.append(("InstanceMarketOptions.MarketType", "spot"))
            p.append(
                (
                    "InstanceMarketOptions.SpotOptions.SpotInstanceType",
                    "one-time",
                )
            )
            p.append(
                (
                    "InstanceMarketOptions.SpotOptions.InstanceInterruptionBehavior",
                    "terminate",
                )
            )
        return p^

    def start(self, mut db: State, r: Ec2Spec, fresh: Bool = False) raises:
        """Starts the run's head instance, then its workers, and records
        them in `orca.instances`: from the pool first, where an idle
        instance of the same key is (unless `fresh`), else new ones. What `r`
        is, the pipeline's registration now, is kept with the run, so its
        workers are started as its head was however the pipeline is
        registered later."""
        _snapshot(db, r)
        var head_type = self.head_of(r.head_type)
        var key = String() if fresh else self.pool_key(
            r, "head", head_type, False
        )
        var head_ip: String
        var took = self._take(db, r, "head", key, 1)
        if len(took) == 1:
            head_ip = took[0]
        else:
            var head = self.ec2.run_instances(
                self._params(r, "head", head_type, 1, False, "")
            )
            _record(
                db,
                r,
                "head",
                head,
                "on-demand",
                1,
                self.pool_key(r, "head", head_type, False),
            )
            if len(head) != 1 or not head[0].private_ip:
                raise Error(
                    "morca: RunInstances gave no head instance with an address"
                )
            head_ip = head[0].private_ip
        var n = min(r.min_workers, r.workers)
        if not r.tasks or n <= 0:
            return
        self._workers(db, r, n, head_ip, fresh)

    def _workers(
        self,
        mut db: State,
        r: Ec2Spec,
        n: Int,
        head_ip: String,
        fresh: Bool = False,
    ) raises:
        """Gives the run `n` more worker instances: idle ones from the pool,
        then new ones for the rest."""
        var itype = self.worker_of(r.worker_type)
        var key = self.pool_key(r, "worker", itype, r.spot)
        var took = 0 if fresh else len(self._take(db, r, "worker", key, n))
        if took >= n:
            return
        var workers = self.ec2.run_instances(
            self._params(r, "worker", itype, n - took, r.spot, head_ip)
        )
        _record(
            db,
            r,
            "worker",
            workers,
            "spot" if r.spot else "on-demand",
            self.procs_of(r),
            key,
        )

    def _take(
        self, mut db: State, r: Ec2Spec, role: StaticString, key: String, n: Int
    ) raises -> List[String]:
        """Hands up to `n` idle instances of `key` to the run, returning
        their addresses. Only one that asked for a run lately, whose run
        has ended, that wasn't drained, and that EC2 says is running, is
        handed out; its row is locked (`SKIP LOCKED`), so two starts can't
        take the same one, and its row for the old run ends as the new
        one's is made, in one transaction, which is what the instance's
        `pool-next` waits for."""
        var out = List[String]()
        if not key or n <= 0:
            return out^
        var tx = db.conn.begin()
        var rows = ec2_db.pool_candidates(
            tx, key, String(role), self.pool_live, n
        )
        if len(rows) == 0:
            tx.rollback()
            return out^
        var ids = List[String]()
        for row in rows:
            ids.append(row.id)
        # The database's word that it's alive, then EC2's.
        var running = Dict[String, Bool]()
        var filters = List[Tuple[String, List[String]]]()
        filters.append((String("instance-id"), ids.copy()))
        for i in self.ec2.describe(filters):
            if i.state == "running":
                running[i.id] = True
        for row in rows:
            if row.id not in running:
                continue
            ec2_db.hand_on(tx, row, r.run, r.start, String(role), key)
            out.append(row.address)
        tx.commit()
        if len(out) > 0:
            print(
                "run",
                r.run,
                "took",
                len(out),
                String(role),
                "instance(s) from the pool",
            )
        return out^

    def settling(self, mut db: State, keys: List[String]) raises -> Bool:
        """Whether instances of `keys` whose run just ended are still on
        their way to the pool (finishing the run's logs, stopping its
        processes): a start waits for them, a few seconds, rather than
        launching new ones beside them. At most the head's grace: after
        that the sweep terminates them."""
        if self.pool_seconds <= 0 or len(keys) == 0:
            return False
        var b = keys[1] if len(keys) > 1 else keys[0]
        return ec2_db.settling(db.conn, keys[0], b, self.grace)

    def scale(mut self, mut db: State) raises -> Tuple[Int, Int]:
        """Grows and shrinks the workers of every running run that scales,
        from its head's demand; returns the workers started and drained."""
        var started = 0
        var drained = 0
        var rows = ec2_db.scaling_runs(db.conn)
        var live = Dict[String, Bool]()
        for row in rows:
            var lo = row.spec.lo
            var hi = row.spec.hi
            # From the run's own registration; a run that scales has fewer
            # workers at the start than at most, one that needs workers
            # at all is watched for their coming.
            var scales = lo >= 0 and lo < hi
            var watched = self.no_workers > 0 and row.spec.tasks and hi > 0
            if not scales and not watched:
                continue
            var r = _spec(row.spec, True, lo if lo >= 0 else hi)
            var key = String(r.run, "-", r.start)
            live[key] = True
            var head_ip = row.head_address
            var head = String(head_ip, ":", head_port())
            # A head whose port black-holes mustn't hold up the tick.
            var got_status: Tuple[Int, String]
            try:
                got_status = capture(
                    [r.binary, "dista-status", head], HEAD_SECONDS
                )
            except e:
                print("morca: run", r.run, "has no status from its head:", e)
                continue
            if got_status[0] != 0:
                continue  # its head isn't up yet, or has gone
            var demand: Demand
            try:
                demand = Demand.parse(got_status[1])
            except:
                continue
            if watched:
                var waiting = (
                    demand.tasks_ready
                    + demand.tasks_waiting
                    + demand.actors_waiting
                )
                var stuck = waiting > 0 and len(demand.workers) == 0
                var waited = row.waited
                if stuck and waited < 0:
                    ec2_db.start_waiting(db.conn, r.run, r.start)
                    waited = 0
                elif not stuck and waited >= 0:
                    ec2_db.stop_waiting(db.conn, r.run, r.start)
                if stuck and waited > Float64(self.no_workers):
                    self._give_up(db, r, waiting)
                    continue
            if not scales:
                continue
            # The policy counts dista worker processes; instances are what
            # starts and costs, `per` processes each. `up` is the processes
            # the live instances still have to offer.
            var per = self.procs_of(r)
            var up = ec2_db.worker_procs_up(db.conn, r.run, r.start)
            var pending = max(up - demand.live(), 0)
            var got = decide(
                demand,
                self.policy(lo * per, hi * per, per),
                Float64(wall_ns()) / 1e9,
                pending,
                self.short_since.get(key, 0),
            )
            self.short_since[key] = got.short_since
            if got.start > 0:
                var instances = (got.start + per - 1) // per
                self._workers(db, r, instances, head_ip)
                started += instances
            for addr in got.drain:
                var drain: Tuple[Int, String]
                try:
                    drain = capture(
                        [r.binary, "dista-drain", head, addr], HEAD_SECONDS
                    )
                except e:
                    print("morca: run", r.run, "can't drain", addr, ":", e)
                    continue
                if drain[0] != 0:
                    print(
                        "morca: run", r.run, "can't drain", addr, ":", drain[1]
                    )
                    continue
                drained += 1
                var ip = String(addr[byte = : addr.rfind(":").or_else(-1)])
                ec2_db.drained_one(db.conn, r.run, r.start, ip)
        # Forget runs that ended.
        var gone = List[String]()
        for k in self.short_since.keys():
            if k not in live:
                gone.append(k)
        for k in gone:
            _ = self.short_since.pop(k, 0)
        return (started, drained)

    def _give_up(mut self, mut db: State, r: Ec2Spec, waiting: Int) raises:
        """Fails the attempt of a run whose head has had `waiting` tasks and
        no worker for `MORCA_NO_WORKERS_SECONDS`: its running attempts fail
        with why, and its instances are terminated. Its driver stops beating
        with them, and the scheduler starts it again as it does a run whose
        process died, while its retries last."""
        var limit = self.no_workers
        var why = String(
            "no workers joined in ",
            String(limit // 60, " min") if limit % 60
            == 0 else String(limit, " s"),
            " (tasks waiting: ",
            waiting,
            ")",
        )
        var n = db.interrupt(r.run, why)
        var ids = ec2_db.end_start(
            db.conn, r.run, r.start, String("terminated by morca: ", why)
        )
        ec2_db.stop_waiting(db.conn, r.run, r.start)
        self.ec2.terminate(ids)
        print(
            "morca: run",
            r.run,
            "start",
            r.start,
            "failed,",
            n,
            "attempts:",
            why,
            "(",
            len(ids),
            "instances terminated)",
        )

    def policy(self, lo: Int, hi: Int, per: Int = 1) -> Policy:
        """The scaling policy over worker processes: `lo` to `hi` of them,
        and `MORCA_SCALE_STEP` instances of `per` at most at once."""
        return self.knobs.policy(lo, hi, per)

    def sweep(self, mut db: State) raises -> Int:
        """Terminates the instances of runs that aren't running at their
        start, and those older than the deadline, but for the pool's: an
        instance whose run ended goes to the pool, and is terminated once
        it has been idle `MORCA_EC2_POOL_SECONDS`, or has stopped asking for
        a run. Returns how many it terminated."""
        var live = Dict[String, Bool]()
        for k in ec2_db.running_starts(db.conn):
            live[k] = True
        # A head shuts itself down once it has kept the driver's log and
        # uploaded its own and its samples, so it gets a grace after its run
        # ends; a run restarted elsewhere is running, and its old head isn't
        # spared.
        var ending = Dict[String, Bool]()
        for k in ec2_db.ended_starts(db.conn, self.grace):
            ending[k] = True
        # The run each instance serves is its live row's: one the pool
        # handed on still has its first run's tags. The pool's are kept
        # while they wait (on their way there, for the head's grace).
        var serves = Dict[String, String]()
        var pooled = Dict[String, String]()  # each of the pool's to go: why
        var kept = Dict[String, Bool]()
        for row in ec2_db.sweep_rows(db.conn):
            var id = row.id
            serves[id] = row.serves
            if self.pool_seconds <= 0 or not row.pooling:
                continue
            if not row.idle:
                if row.since_end < self.grace:
                    kept[id] = True
                else:
                    pooled[id] = String(
                        "terminated by morca: it didn't go back to the pool"
                    )
            elif row.idle_for >= self.pool_seconds:
                pooled[id] = String(
                    "pooled: idle ", Int(self.pool_seconds), " s, shut down"
                )
            elif row.since_poll >= max(self.pool_live * 3, 15.0):
                pooled[id] = String("pooled: stopped asking for a run")
            else:
                kept[id] = True
        var old = ec2_db.utc_ago(db.conn, Float64(self.deadline))
        var filters = List[Tuple[String, List[String]]]()
        var tag: List[String] = [String("orca.run")]
        var states: List[String] = [String("pending"), String("running")]
        filters.append((String("tag-key"), tag^))
        filters.append((String("instance-state-name"), states^))
        var doomed = List[String]()
        # The pool's doomed: their rows end before they're terminated, so
        # one handed to a run meanwhile isn't.
        var leaving = List[String]()
        var up = List[String]()
        for i in self.ec2.describe(filters):
            up.append(i.id)
            var key = serves.get(
                i.id,
                String(
                    i.tags.get("orca.run", ""),
                    "-",
                    i.tags.get("orca.start", ""),
                ),
            )
            # Launch times are ISO 8601 in UTC, so they order as text.
            if i.launch_time and i.launch_time < old:
                doomed.append(i.id)
            elif key in live:
                continue
            elif i.id in pooled:
                leaving.append(i.id)
            elif i.id in kept:
                continue
            elif not (key in ending and i.tags.get("orca.role", "") == "head"):
                doomed.append(i.id)
        for id in leaving:
            var k = serves[id]
            var dash = k.find("-").or_else(-1)
            var n = ec2_db.end_row(
                db.conn,
                id,
                Int(k[byte=:dash]),
                Int(k[byte = dash + 1 :]),
                pooled[id],
            )
            if n > 0:
                doomed.append(id)
        self.ec2.terminate(doomed)
        for id in doomed:
            _ended(db, id, "terminated by morca: its run had ended")
        self._ended_since(db, up)
        self._rescue(db)
        return len(doomed)

    def _rescue(self, mut db: State) raises:
        """Replaces the instances the pool handed to a run that haven't
        taken it up within `MORCA_EC2_POOL_JOIN_SECONDS`: such a worker with a
        new one, and such a head with a new head and workers for the same
        start, well within the start grace."""
        if self.pool_seconds <= 0:
            return
        for row in ec2_db.unjoined(db.conn, self.pool_join):
            var id = row.id
            var run = row.run
            var start = row.start
            var role = row.role
            var n = ec2_db.end_never_joined(db.conn, id, run, start)
            if n == 0:
                continue
            self.ec2.terminate([id])
            print("morca: run", run, "replaces pooled", role, id, "(no answer)")
            var got = self._spec_of(db, run, start)
            guard case .Some(spec) = got else:
                continue
            if role == "worker":
                var head = ec2_db.head_address(db.conn, run, start)
                if head and head.value():
                    self._workers(db, spec, 1, head.value(), True)
                continue
            # Its workers were told the lost head's address: they go too.
            var others = ec2_db.end_lost_head(db.conn, run, start)
            self.ec2.terminate(others)
            self.start(db, spec, fresh=True)

    def _spec_of(
        self, mut db: State, run: Int, start: Int
    ) raises -> Optional[Ec2Spec]:
        """Run `run`'s start `start`, as `start` was given it."""
        var row = ec2_db.spec_of(db.conn, run, start)
        guard case .Some(s) = row else:
            return None
        return _spec(s, s.tasks, s.hi if s.lo < 0 else min(s.lo, s.hi))

    def _ended_since(self, mut db: State, up: List[String]) raises:
        """Records the end of every instance `orca.instances` has as live
        that isn't among those `up`, with EC2's reason for it."""
        var gone = List[String]()
        for id in ec2_db.live_ids(db.conn):
            if id not in up:
                gone.append(id)
        if len(gone) == 0:
            return
        var filters = List[Tuple[String, List[String]]]()
        filters.append((String("instance-id"), gone.copy()))
        var reasons = Dict[String, String]()
        for i in self.ec2.describe(filters):
            reasons[i.id] = i.state_reason
        for id in gone:
            _ended(db, id, _why(reasons.get(id, "")))


def _why(code: String) -> String:
    """EC2's state reason, said plainly."""
    if code == "Client.InstanceInitiatedShutdown":
        return "shut itself down"
    if code == "Client.UserInitiatedShutdown":
        return "terminated"
    if code == "Server.SpotInstanceTermination":
        return "Spot interruption"
    if code == "Server.InsufficientInstanceCapacity":
        return "no capacity"
    return code if code else String("gone")


def _record(
    mut db: State,
    r: Ec2Spec,
    role: StaticString,
    made: List[Instance],
    market: String,
    procs: Int,
    key: String,
) raises:
    for i in made:
        var cpu = 0
        try:
            cpu = vcpus(i.instance_type) * 1000
        except:
            pass
        ec2_db.add_instance(
            db.conn,
            i.id,
            r.run,
            r.start,
            String(role),
            i.instance_type,
            market,
            i.private_ip,
            procs,
            key,
            cpu,
        )


def _ended(mut db: State, id: String, why: String) raises:
    """Records that instance `id` ended, unless it's recorded already."""
    ec2_db.ended(db.conn, id, why)
