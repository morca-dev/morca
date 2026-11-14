"""A registered pipeline as the scheduler reads it (`Registered`,
`registered`), and what its runs ask for (`run_request`).
"""

from std.os import getenv
import morca._internal.db.registered as registered_db
from morca.civil import Civil
from morca._internal.control import (
    CONTROL,
    pool_of,
)
from morca._internal.config import (
    parse_env,
    max_runs_auto,
)
from morca._internal.fill import (
    Fill,
    FillPipeline,
)
from morca.cron import CronExpr
from morca.day import Day
from morca.hour import Hour
from morca._internal.ec2 import Ec2Spec
from morca.month import Month
from morca.schedule import Schedule
from morca._internal.secrets import parse_secrets
from morca._internal.resources import Request
from morca._internal.recommend import (
    Recommendation,
    RunRequest,
    keep_capped,
    learned,
    resolve_request,
)
from morca._internal.state import State
from morca.tz import Zone


@fieldwise_init
struct Registered(Copyable, Movable):
    """A registered pipeline, as the scheduler reads it from `describe`."""

    var name: String
    var binary: String
    var registry_hash: String
    var since: Int64
    var cron: String
    var tz: String
    var fills: String
    var catchup: Bool
    var kind: String
    var start: String
    var max_runs: Int
    var run_retries: Int
    var retry_seconds: Int
    """The first retry's wait, doubling; 0 for `MORCA_RETRY_SECONDS`."""
    var max_retry_seconds: Int
    """The longest wait between retries; 0 for no limit."""
    var sensor: Bool
    var keys_per_run: Int
    var keys_dataset: String
    """A keyed pipeline's keys dataset; empty for time partitions."""
    var image: String
    """The image its runs' pods run (`morca register --image`), or empty."""
    var workers: Int
    """Its cluster's dista workers; 0 if it has no tasks."""
    var head_type: String
    """On EC2, its runs' head instance type; empty for the default."""
    var worker_type: String
    var spot: Bool
    """On EC2, whether its workers are Spot instances."""
    var min_workers: Int
    """On EC2, its runs' fewest workers, scaling up to `workers`; equal to
    `workers` for a fixed count."""
    var secrets: List[Tuple[String, String]]
    """Its runs' secrets: environment variable and Secrets Manager ID."""
    var paused: Bool
    """`morca pause`: its runs are queued as ever, but none is started."""
    var worker_procs: Int
    """On EC2, the dista worker processes on each worker instance
    (`morca register --worker-procs`); 0 is one per vCPU."""
    var placement: String
    """Where its runs run (`morca register --placement`): `control` (the
    scheduler's host, `morca._internal.control`), `ec2`, or empty for the scheduler's
    runner."""
    var env: List[Tuple[String, String]]
    """Its runs' own variables (`env` in morca.toml, `morca._internal.config`), given
    to its runs alone, over those `MORCA_RUN_ENV` names."""
    var fill: Fill
    """How it fills its range by itself (`morca._internal.fill`)."""
    var cpus: String
    """The CPUs it asks for, `N` or `MIN..MAX` (`morca._internal.resources`); empty
    for none."""
    var memory_gb: String
    """The memory it asks for, in GB; empty for none."""
    var memory_raised_mb: Int
    """What an out-of-memory kill raised its memory to (`morca._internal.cgroup`),
    which its runs ask for at least; 0 for none."""
    var learn: Bool
    """Whether `auto` uses what its runs suggest (`learn` in morca.toml)."""
    var learn_key: String
    """For a pipeline asking for `auto`, what a learned request now would be
    learned from: its latest successful run (and whether that's measured
    yet), its out-of-memory bump and its declared request; else empty."""
    var learned: Recommendation
    """The learned request cached in `orca.pipelines.learned` (its runs,
    memory and CPUs), learned from `learned_key`, and what its memory was
    last capped at (`capped`)."""
    var learned_key: String
    var max_runs_auto: Bool
    """`max_runs = "auto"` (#266): as many runs at once as this host has
    room for, `max_runs` the ceiling."""
    var priority: Int
    """`priority` in morca.toml (#421), 0 by default: the scheduler's pass
    starts the pipelines highest first."""

    def request(self) raises -> Request:
        """As declared: `auto` not resolved (`run_request` does)."""
        return Request.of(self.cpus, self.memory_gb)


def recorded_cpus(p: Registered, sized: RunRequest) -> String:
    """The CPUs a run records it asked for (`orca.runs.request_cpus`): as
    registered, or what `auto` resolved to."""
    return sized.cpus_text() if p.cpus.startswith("auto") else p.cpus


def recorded_memory_gb(p: Registered, sized: RunRequest) -> String:
    """The memory a run records it asked for, as `recorded_cpus`."""
    return sized.memory_gb_text() if p.memory_gb.startswith(
        "auto"
    ) else p.memory_gb


def run_request(
    mut db: State,
    p: Registered,
    most_cpus: Int = 0,
    most_mb: Int = 0,
    most_of: String = "this host's most",
) raises -> RunRequest:
    """The request a start of `p` gets now (`morca._internal.recommend`'s
    `resolve_request`): as declared, or for `auto` what its runs suggest. That is cached on the
    pipeline (`orca.pipelines.learned`) and learned again only when what it
    was learned from (`learn_key`) has changed, so a start doesn't query
    its runs' peaks each tick. Learned CPUs and memory are at most
    `most_cpus` and `most_mb`, what the host (or the pool's largest worker,
    `most_of`) grants a run."""
    var declared = p.request()
    if not declared.auto() or not p.learn:
        return resolve_request(declared, Recommendation.none(), p.learn)
    if p.learned_key == p.learn_key:
        return resolve_request(
            declared, p.learned, True, most_cpus, most_mb, most_of
        )
    var rec = learned(db, p.name, p.cpus, p.memory_gb)
    registered_db.keep_learned(
        db.conn, p.name, p.learn_key, rec.runs, rec.memory_mb, rec.cpus
    )
    return resolve_request(declared, rec, True, most_cpus, most_mb, most_of)


def with_cap(hold: String, sized: RunRequest) -> String:
    """`hold`, with what capped the learned memory, if something did:
    "waiting: needs 2.2 GB, 1 GB free of grants (learned 2.5 GB, capped at
    2.2 GB, this host's most)"."""
    if not hold or not sized.capped:
        return hold
    return String(hold, " (", sized.cap_text(), ")")


def say_capped(mut db: State, p: Registered, sized: RunRequest) raises:
    """Logs it once when what caps `p`'s learned memory changes (#462), and
    keeps it on the pipeline for `morca config show` and its page."""
    if sized.capped == p.learned.capped:
        return
    if sized.capped:
        print("morca: pipeline", p.name, "memory:", sized.cap_text())
    else:
        print("morca: pipeline", p.name, "memory: no longer capped")
    keep_capped(db, p.name, sized.capped)


def _ec2_spec(p: Registered, run: Int, start: Int, new_code: Bool) -> Ec2Spec:
    """Start `start` of `p`'s run `run`, as the ec2 runner starts it."""
    return Ec2Spec(
        run,
        start,
        p.name,
        p.image,
        p.binary,
        p.workers > 0,
        p.head_type,
        p.worker_type,
        p.workers,
        p.spot,
        new_code,
        p.min_workers,
        p.secrets.copy(),
        p.worker_procs,
        p.registry_hash,
        p.env.copy(),
    )


def fill_key(kind: String, fills: String, local: Civil) raises -> String:
    """The partition a fire fills, given its time on the schedule's wall
    clock: the key the time falls in, or the one before it."""
    if kind == "hourly":
        var h = Hour.containing(local.year, local.month, local.day, local.hour)
        return String(h.prev() if fills == "previous" else h^)
    if kind == "daily":
        var d = Day.containing(local.year, local.month, local.day, 0)
        return String(d.prev() if fills == "previous" else d^)
    if kind == "monthly":
        var m = Month.containing(local.year, local.month, local.day, 0)
        return String(m.prev() if fills == "previous" else m^)
    raise Error("morca: unknown partitions '", kind, "'")


def repeated_fill(p: Registered, after: Int64) raises -> String:
    """How `p`'s schedule fires more than once for one partition in the
    year or so after `after` (such as `0 */6 * * *` on daily partitions), or
    empty if it doesn't."""
    if not p.cron or p.kind == "keyed":
        return ""
    var s = Schedule(CronExpr.parse(p.cron), Zone.load(p.tz))
    var t = after
    var last = String()
    for _ in range(2000):
        t = s.next_fire(t)
        if t > after + 400 * 86400:
            break
        var key = fill_key(p.kind, p.fills, Civil.of(s.zone.to_local(t)))
        if key == last:
            return String(
                "the schedule of ",
                p.name,
                " (",
                p.cron,
                ") fires more than once for ",
                key,
                ": a fire while a run of the partition is live is left to",
                " it, but one after that run has ended runs the partition",
                " again, and its steps append again",
            )
        last = key^
    return ""


def registered(mut db: State, only: String = "") raises -> List[Registered]:
    """Every pipeline registered with a binary, or the one named: the
    highest `priority` first, then by name, the order the scheduler's pass
    starts them in."""
    var out = List[Registered]()
    var rows = registered_db.registrations(db.conn, only)
    for r in rows:
        out.append(
            Registered(
                r.name,
                r.binary_path,
                r.registry_hash,
                r.since,
                r.cron,
                r.tz,
                r.fills,
                r.catchup,
                r.kind,
                r.start,
                r.max_runs,
                r.run_retries,
                r.retry_seconds,
                r.max_retry_seconds,
                r.sensor,
                r.keys_per_run,
                r.keys_dataset,
                r.image,
                r.workers,
                r.head_type,
                r.worker_type,
                r.spot,
                r.min_workers,
                parse_secrets(r.secrets),
                r.paused,
                r.worker_procs,
                r.placement,
                parse_env(r.env),
                Fill.of(
                    r.fill_mode,
                    r.fill_order,
                    r.fill_max_runs,
                    r.fill_budget,
                    r.fill_window,
                    r.fill_lag,
                    r.fill_max_runs_auto,
                ),
                r.cpus,
                r.memory_gb,
                r.memory_raised_mb,
                r.learn,
                r.learn_key,
                Recommendation(
                    r.learned_runs,
                    0,
                    r.learned_memory_mb,
                    r.learned_cpus,
                    "",
                    "",
                    False,
                    r.learned_capped,
                ),
                r.learned_key,
                r.max_runs_auto,
                r.priority,
            )
        )
    # A fixed count, or no tasks: no scaling.
    for ref p in out:
        if p.min_workers < 0 or p.workers == 0:
            p.min_workers = p.workers
        p.min_workers = min(p.min_workers, p.workers)
    return out^


def placed_of(p: Registered) -> String:
    """Where `p`'s runs start under a scheduler with this process's
    `MORCA_RUNNER`: `control`, `ec2`, `kubernetes` or `local`."""
    if p.placement == CONTROL or pool_of(p.placement):
        return p.placement
    var runner = getenv("MORCA_RUNNER", "local")
    if p.placement == "ec2":
        return "ec2"
    return runner


def fill_pipeline(
    p: Registered, placed: String = "", pool_seconds: Int = -1
) -> FillPipeline:
    """What `morca._internal.fill.fill_status` needs of `p`; where its runs start and
    the warm pool's seconds from this process's environment unless
    given."""
    var pool = pool_seconds
    if pool < 0:
        try:
            pool = Int(Float64(getenv("MORCA_EC2_POOL_SECONDS", "150")))
        except:
            pool = 150
    return FillPipeline(
        p.name,
        p.fill.copy(),
        p.kind,
        p.start,
        p.tz,
        p.paused,
        placed if placed else placed_of(p),
        p.head_type,
        p.worker_type,
        p.workers,
        pool,
        p.keys_per_run,
    )
