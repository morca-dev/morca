"""Ops' Pools (`/ops/pools`): every machine runs are placed on, one row
each, by the pool a placement names.

| Pool | Kind | A machine is |
|---|---|---|
| `ec2` | EC2 | an instance morca launched for a run (`orca.instances`), live or ended in the last hour |
| `kubernetes` | k8s | a live run's pods (`morca-<run>-<start>`), on the Kubernetes runner: the runner records no pods or nodes, so the run is what there is |
| `worker:<pool>` | self-hosted | the machine a worker token's `morca worker` runs on (`orca.workers`), with the worker as columns of its row |

The scheduler's own machine (the local runner, and control-placed runs)
isn't a pool: it is Control (`/ops/control`).

A machine's state is `live`, `draining` (an EC2 worker the scheduler
drained, or a worker asked to with `morca host drain`) or `gone` (an instance that ended; a worker whose token was
revoked or expired, or that hasn't been seen for `MORCA_STALE_SECONDS`),
with what it's doing in `detail`. Like Fleet, a page view reads
`orca.instances`, `orca.fleet_samples`, `orca.workers` and `orca.runs`,
never a sampler's file.
"""

from std.os import getenv

import morca._internal.db.machines_view as machines_db
from morca._internal.db.live import stale_limit
from morca._internal.db.machines_view import WorkerRun
from morca._internal.state import State


comptime EC2 = "ec2"
"""The kind (and the pool) of the EC2 instances morca launches."""
comptime K8S = "k8s"
"""The kind of a Kubernetes run's pods; their pool is `kubernetes`."""
comptime SELF_HOSTED = "self-hosted"
"""The kind of a machine running `morca worker`; its pool `worker:<pool>`."""
comptime KUBERNETES = "kubernetes"

comptime GONE_MINUTES = 60
"""How long an ended instance stays listed, as gone; and how long a gone
machine stays in Pools' default view."""
comptime _SPARK_SECONDS = 600


@fieldwise_init
struct Machine(Copyable, Movable):
    """A machine of a pool, and what's running on it."""

    var pool: String
    """`ec2`, `kubernetes` or `worker:<pool>`."""
    var kind: String
    """`ec2`, `k8s` or `self-hosted`."""
    var id: String
    """What its page is named by: the instance id, the pod name, the
    worker token's id."""
    var name: String
    """The instance id, the pod name, or the worker's host name (its
    token's label until it has claimed)."""
    var state: String
    """`live`, `draining` or `gone`."""
    var detail: String
    """What it's doing: `starting`, `running`, `idle (pooled)`, `ended`,
    `idle`, `revoked`, `expired`, `not seen`."""
    var image: String
    var cpus: Int
    """Its vCPUs; 0 if unknown."""
    var memory_mb: Int
    """Its memory; 0 if unknown."""
    var runs: List[Int]
    var seen_ago: Int
    """Seconds since its last heartbeat (a sample, a worker's claim, a
    run's heartbeat); -1 if never."""
    var process: String
    """What morca runs there: `head` or `worker` of a run, `morca worker`,
    or `pods`."""
    var instance_type: String
    var market: String
    var uptime: Int
    """Seconds since it launched; -1 if unknown."""
    var cpu: Float64
    """Its CPU % at the last sample; -1 without one."""
    var mem_pct: Float64
    var spark_x: List[Float64]
    """Its CPU over the last 10 minutes, as in Fleet."""
    var spark_y: List[Float64]
    var token: Int
    """Its worker token's id; 0 if it isn't a worker."""
    var label: String
    """The worker token's label."""
    var expires: String
    var ended: String
    """When an instance ended, and why, in UTC; empty while it's up."""
    var run_start: Int
    """The run's start an instance or a pod belongs to; 0 for a worker."""

    def live(self) -> Bool:
        return self.state != "gone"

    def recent(self) -> Bool:
        """Whether it is live, or went gone within `GONE_MINUTES`: an ended
        instance always has; a worker, if it was heard from that recently."""
        return (
            self.live()
            or self.kind == EC2
            or (self.seen_ago >= 0 and self.seen_ago < GONE_MINUTES * 60)
        )


def type_size(instance_type: String) -> Tuple[Int, Int]:
    """The vCPUs and memory (MiB) of the instance types morca runs on, as
    `morca._internal.fleet.hourly_price` prices them; (0, 0) for any other."""
    if instance_type == "c7g.large":
        return (2, 4096)
    if instance_type == "c7g.xlarge":
        return (4, 8192)
    if instance_type == "c7g.2xlarge":
        return (8, 16384)
    if instance_type == "c7g.4xlarge":
        return (16, 32768)
    if instance_type == "t4g.medium":
        return (2, 4096)
    if instance_type == "t4g.large":
        return (2, 8192)
    return (0, 0)


def _sparks(
    mut db: State,
) raises -> Tuple[Dict[String, List[Float64]], Dict[String, List[Float64]]]:
    var xs = Dict[String, List[Float64]]()
    var ys = Dict[String, List[Float64]]()
    for r in machines_db.spark_samples(db.conn, _SPARK_SECONDS):
        var h = r.host
        if h not in xs:
            xs[h] = List[Float64]()
            ys[h] = List[Float64]()
        xs[h].append(1.0 - r.ago / Float64(_SPARK_SECONDS))
        ys[h].append(r.cpu)
    return (xs^, ys^)


def _ec2(mut db: State, mut out: List[Machine], one: String) raises:
    """The instances: live, then those that ended in the last hour."""
    var sparks = _sparks(db)
    for r in machines_db.ec2_instances(db.conn, GONE_MINUTES, one):
        var id = r.id
        var sampled = r.sampled
        var size = type_size(r.instance_type)
        var cpus = size[0]
        if cpus == 0 and sampled:
            cpus = r.cores
        var gone = r.gone
        var state = String("gone") if gone else (
            String("draining") if r.draining else String("live")
        )
        var detail = String("ended") if gone else (
            String("idle (pooled)") if r.idle else (
                String("draining") if r.draining else (
                    String("running") if sampled else String("starting")
                )
            )
        )
        var ended = String()
        if gone:
            ended = String(r.ended)
            if r.why:
                ended.write(": ", r.why)
        out.append(
            Machine(
                pool=EC2,
                kind=EC2,
                id=id,
                name=id,
                state=state^,
                detail=detail^,
                image=r.image,
                cpus=cpus,
                memory_mb=size[1],
                runs=[r.run],
                seen_ago=r.ago,
                process=r.role,
                instance_type=r.instance_type,
                market=r.market,
                uptime=r.up,
                cpu=r.cpu,
                mem_pct=r.mem,
                spark_x=sparks[0].pop(id, List[Float64]()),
                spark_y=sparks[1].pop(id, List[Float64]()),
                token=0,
                label=String(),
                expires=String(),
                ended=ended^,
                run_start=r.start,
            )
        )


def _kubernetes(mut db: State, mut out: List[Machine], one: String) raises:
    """On the Kubernetes runner, a row per live run of the default
    placement: its pods, which the runner names `morca-<run>-<start>`."""
    if getenv("MORCA_RUNNER") != KUBERNETES:
        return
    for r in machines_db.pod_runs(db.conn, one):
        var run = r.id
        var start = r.starts
        var pod = String("morca-", run, "-", start)
        var millis = r.cpu_millis
        out.append(
            Machine(
                pool=KUBERNETES,
                kind=K8S,
                id=pod.copy(),
                name=pod^,
                state="live",
                detail="running" if r.ago >= 0 else "starting",
                image=r.image,
                cpus=(millis + 999) // 1000,
                memory_mb=0,
                runs=[run],
                seen_ago=r.ago,
                process="pods",
                instance_type=String(),
                market=String(),
                uptime=r.up,
                cpu=-1.0,
                mem_pct=-1.0,
                spark_x=List[Float64](),
                spark_y=List[Float64](),
                token=0,
                label=String(),
                expires=String(),
                ended=String(),
                run_start=start,
            )
        )


def _workers(mut db: State, mut out: List[Machine], one: Int) raises:
    """A row per worker token: the machine its worker runs on."""
    var stale = Int(stale_limit())
    for r in machines_db.worker_tokens(db.conn, stale, one):
        var s = r.state
        var runs = List[Int]()
        if r.running:
            for x in r.running.split(","):
                try:
                    runs.append(Int(String(x).strip()))
                except:
                    pass
        var name = r.name
        out.append(
            Machine(
                pool=String("worker:", r.pool),
                kind=SELF_HOSTED,
                id=String(r.id),
                name=name if name else r.label,
                state=s if s == "live" or s == "draining" else String("gone"),
                detail=(
                    String("running") if len(runs) > 0 else String("idle")
                ) if s
                == "live"
                or s == "draining" else s,
                image=r.image,
                cpus=r.cpus,
                memory_mb=r.memory_mb,
                runs=runs^,
                seen_ago=r.ago,
                process="morca worker",
                instance_type=String(),
                market=String(),
                uptime=-1,
                cpu=-1.0,
                mem_pct=-1.0,
                spark_x=List[Float64](),
                spark_y=List[Float64](),
                token=r.id,
                label=r.label,
                expires=r.expires,
                ended=String(),
                run_start=0,
            )
        )


def kind_of(v: String) -> String:
    """`?kind=`: `ec2`, `k8s` or `self-hosted`, else empty (all)."""
    if v == EC2 or v == K8S or v == SELF_HOSTED:
        return v
    return String()


def machines(mut db: State) raises -> List[Machine]:
    """Every machine of every pool: EC2, Kubernetes, then the workers by
    pool."""
    var out = List[Machine]()
    _ec2(db, out, "")
    _kubernetes(db, out, "")
    _workers(db, out, 0)
    return out^


def machine(
    mut db: State, kind: String, id: String
) raises -> Optional[Machine]:
    """One machine, by its kind and the id its page is named by."""
    var out = List[Machine]()
    if kind == EC2:
        _ec2(db, out, id)
    elif kind == K8S:
        _kubernetes(db, out, id)
    elif kind == SELF_HOSTED:
        var n: Int
        try:
            n = Int(id)
        except:
            return None
        if n <= 0:
            return None
        _workers(db, out, n)
    if len(out) == 0:
        return None
    return out[0].copy()


@fieldwise_init
struct PoolCount(Copyable, Movable):
    """A pool, its kind, and how many of its machines are live."""

    var pool: String
    var kind: String
    var machines: Int
    var live: Int


def pool_counts(ms: List[Machine]) -> List[PoolCount]:
    """The pools the machines are in, in their order."""
    var out = List[PoolCount]()
    for m in ms:
        var found = False
        for ref p in out:
            if p.pool == m.pool:
                p.machines += 1
                p.live += 1 if m.live() else 0
                found = True
                break
        if not found:
            out.append(PoolCount(m.pool, m.kind, 1, 1 if m.live() else 0))
    return out^


def filtered(
    ms: List[Machine], pool: String, kind: String, gone: Bool = True
) -> List[Machine]:
    """The machines of `pool` (any if empty) and `kind` (any if empty); with
    `gone` false, not those that went gone more than `GONE_MINUTES` ago."""
    var out = List[Machine]()
    for m in ms:
        if (not pool or m.pool == pool) and (not kind or m.kind == kind):
            if gone or m.recent():
                out.append(m.copy())
    return out^


def old_gone(ms: List[Machine]) -> Tuple[Int, Int]:
    """How many of `ms` are gone for good (not `recent`), and the seconds
    since the freshest was heard from; -1 if none ever was."""
    var n = 0
    var seen = -1
    for m in ms:
        if not m.recent():
            n += 1
            if m.seen_ago >= 0 and (seen < 0 or m.seen_ago < seen):
                seen = m.seen_ago
    return (n, seen)


def worker_runs(
    mut db: State, token: Int, n: Int = 20
) raises -> List[WorkerRun]:
    """The runs a worker token's latest starts were claimed by, newest
    first."""
    return machines_db.worker_runs(db.conn, token, n)


def run_pipeline(mut db: State, run: Int) raises -> String:
    """The pipeline of a run, or empty."""
    return machines_db.run_pipeline(db.conn, run)
