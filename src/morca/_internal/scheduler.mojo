"""The scheduler: fires schedules, senses datasets, queues backfills and
rebuilds, and starts runs.

```
morca register ./build/taxi             runs `taxi describe`, records the binary
morca backfill taxi 2011-01..2024-12    a run per partition that isn't done
morca backfill labels @all              keyed: runs of keys_per_run undone keys
morca rebuild taxi.trips 2024-01        the pipelines downstream, in order
morca tick                              one pass, then exits
morca scheduler                         a pass every second
```

The scheduler links no pipeline. It knows one by the `describe` it printed,
kept in `orca.pipelines` with the binary's path, and reads the schedule,
partitions and limits from that JSON in SQL. Everything it decides is in
Postgres, so it can be stopped and restarted, or run twice, at any time:

- **A fire is a row.** `orca.fires` is keyed by (pipeline, fire time), and a
  fire's row and its `queued` run are inserted in one transaction, so a fire
  is never made twice. Fires are counted from the last one recorded (or from
  when the pipeline was registered), so the fires missed while the scheduler
  was down are made once each, or, with `catchup=False`, only the latest.
  A fire whose partition is before the pipeline's first is recorded without
  a run.
- **One live run per partition.** Every way a run is queued checks, under
  a lock on the pipeline's row, for a live run (`morca._internal.live`) of the same
  keys: a fire whose partition a live run has records that run as its own,
  a sensor leaves such keys to it (the snapshot's run, if it left nothing
  else), a rebuild's level waits for it, the UI refuses to start one, and a
  backfill skips the key. A partition that's done is run again by a fire,
  sensor, rebuild or start, and its steps append again; `morca register`
  warns of a schedule that fires more than once for one partition.
- **Starting a run is `resume`.** A queued run has nothing done, or what a
  resume or rerun from `morca ui` left it, which is what `<binary> resume
  <run>` takes (with `--allow-new-code` when the resume said so). The scheduler marks the run `running`,
  with no heartbeat and itself as owner, and execs the binary, which claims
  it. It doesn't wait: the run records its own progress.
- **`max_runs`.** Under a lock on the pipeline's row, the runs that are live
  (a fresh heartbeat, or started by the scheduler less than the stale limit
  ago) are counted, and only that many fewer than `max_runs` are started.
- **Priority** (#421, `morca._internal.tick`). Each pass takes the
  pipelines by `priority` in morca.toml (0 by default), highest first, then
  by name. Within one priority every pipeline's other runs (scheduled,
  sensed, backfilled, manual, retries) are started before any of their
  fill runs, so a fill takes only the room they left. Nothing running is
  stopped to make room. A run that waits for room on this host while a
  higher-priority pipeline's runs hold it says whose: `waiting: for
  capacity (gharchive, priority 10): needs 2 GB, ...`.
- **Memory pressure** (`orca.pressure`, `morca._internal.admission`). On the local
  runner and for control-placed runs, none starts while this host's PSI
  `some avg10` is over `MORCA_ADMIT_MEMORY_PRESSURE` (10%), each queued run
  `held` saying so; then the grants of a pipeline with a request
  (`morca._internal.resources`).
- **Backfills queue what isn't done.** A key is done when every mapped
  step has succeeded for it in a run of the pipeline's current code
  (`DONE_SQL`). A backfill drops the keys that are done or in a live run
  (queued, or running with its process alive: `live_sql`), sorts the rest
  and queues a run per `keys_per_run` of them; `morca backfill` says on
  stderr which keys it dropped and why.
- **Where runs run.** `MORCA_RUNNER` is `local` (a process here, the
  default), `kubernetes` (a dista cluster of pods per run, `morca._internal.kube`) or
  `ec2` (a head instance and worker instances per run, `morca._internal.ec2`).
  A pipeline registered with `--placement control` runs here whatever the
  runner, within the control instance's limits (`morca._internal.control`); one with
  `--placement ec2` waits on a scheduler whose runner isn't `ec2`. One with
  `--placement worker:<pool>` is never started here: a remote worker of the
  pool claims its queued runs over the UI's API (`orca.workers`), and the
  scheduler queues its due retries and its dead runs again for one, its
  fill runs too (held for a worker, `fill_max_runs` across the pool), and
  a run whose worker is gone whatever its trigger.
- **Overlapping instances** (`orca.instances`, docs/overlap.md). With
  `MORCA_OVERLAP=on` a deploy starts the new image's scheduler beside the
  old one: the newest live instance leads and alone decides, and an older
  one starts nothing more, supervises its runs until they end or
  `MORCA_DRAIN_SECONDS` (required) runs out, when it kills them, and
  exits. Its runs see that they're outdated (`morca.outdated()`). A local or control-placed
  run records the instance that started it; while that instance lists it
  the run is live (`morca._internal.live.held_sql`), counted against `max_runs`, the
  control slots and the grants, and left alone. Once the instance is gone
  and the run's heartbeat stale, it's queued again whatever its trigger,
  audited.
- **Sensors and rebuilds** (`morca._internal.sensors`). A sensor pipeline's pass
  looks for snapshots of the datasets it reads, in `orca.commits` on every
  tick and from `<binary> sense` every `MORCA_SENSE_SECONDS` (asked in a
  child the next ticks check on, killed after `MORCA_BINARY_SECONDS`), and
  queues a
  run, trigger `sensor`, for those it hasn't seen; with `keys_per_run`
  above 1 the keys go first to its queued sensor runs that haven't
  started, up to that, then to new runs of that many (#240). A keyed sensor's keys
  dataset is sensed too: a new snapshot of it queues the keys that aren't
  done, in runs of `keys_per_run`. Each rebuild queues its
  next level once the one before has succeeded.
- **A snapshot it can't run** is seen all the same. One whose keys aren't
  partitions of the sensor's kind (a week in `orca.partitions`, or names
  for a dated sensor) is recorded in `orca.sensed` with no run and why, and
  the others the tick saw are run. A pass that fails, such as a `sense` that
  exits non-zero, is kept as the pipeline's `sense_error`, which `morca ui`
  shows, and printed once rather than on every tick.
- **Fills** (`morca._internal.fill`). A pipeline registered with `fills = "all"` in
  morca.toml has a second pass after the other runs of every pipeline of
  its priority: runs with trigger
  `fill`, `keys_per_run` partitions each, over the partitions of its range no run has
  taken (`fill_status`), up to `fill_max_runs` beside `max_runs`, none
  while its other runs are queued, it's paused, outside `fill_window` or
  over `fill_budget_per_day`.
  A fill request (`morca backfill --as-fill`, `morca._internal.fill_requests`)
  is run the same way, before the range, with fills off too.
- **Retries.** A scheduled, backfilled, sensed or fill run that failed is started again
  after the pipeline's `retry_seconds` (else `MORCA_RETRY_SECONDS`, default
  60) doubling with each start, at most its `max_retry_seconds` if set,
  plus up to a tenth more as jitter, up to `run_retries` times. A due retry
  is started in the order of its run's id among the pipeline's startable
  runs, so an old partition's retry goes before newer runs. One whose process
  died (its heartbeat went stale) is started again at once, within the same
  budget. A manual, UI or rerun run is never retried by the scheduler: one
  whose process died ends `failed`, with the error `interrupted: its
  process stopped`, so it can be resumed and holds its keys no longer. A
  run whose step raised `defer` ends `deferred` with `retry_at` the time it
  asked for, and is started again then, whatever its trigger; those starts
  (`deferrals`) don't count against `run_retries`. A run asked to cancel
  whose process died ends `cancelled`.
- **New code.** `morca register` of a new build moves the queued runs to it,
  and the failed ones waiting for a retry that have no step done. A retry
  of a run with steps done by other code would be refused by the binary's
  `resume`, so the scheduler fails it at once instead of starting it, with
  an error (`runs.error`) saying to resume it with `--allow-new-code`. A
  local run whose process exits before claiming its run fails with the
  exit code and the last line of its driver log as its error; one whose
  process crashes after (a segfault, `abort`) has the attempts it left
  running failed with the crash's first frames (`morca._internal.crash`).

The scheduler's clock is `morca.civil.now`, which `MORCA_NOW` fixes; fire
times and retry times are on it. Heartbeats are on the database's clock.
A run's output goes to `<MORCA_LOGS>/<pipeline>/<run>/driver.log` when
`MORCA_LOGS` is set: written there by a local run, published there when the
process is reaped if `MORCA_LOGS` is in object storage, or kept from the
driver pod's log on Kubernetes (`morca._internal.kube`). Beside a local run's process
the scheduler starts `<binary> sample` (`morca._internal.sample`), which writes the
machine's metrics to `.../<run>/metrics/local.jsonl` until the process ends;
`MORCA_SAMPLE_SECONDS=0` turns it off, on every runner. Apart from that, each
tick reads each local and control-placed run's process tree in /proc, and
once the process is reaped its attempts get their peak memory and CPU
(`morca._internal.usage`). `morca scheduler` gives each local and control-placed run a
cgroup of its own where it can (`morca._internal.cgroup`): a memory limit at its
grant, an out-of-memory kill that fails its attempts saying so, and a retry
that asks for more.
"""

from std.ffi import (
    c_int,
    external_call,
)
from std.os import getenv
from std.os.path import exists
from std.time import (
    perf_counter_ns,
    sleep,
)
from postgres import Transaction
from morca._internal.pool_scale import PoolScaler
from morca._internal.expiry import (
    expirable,
    expire_argv,
    maintain_binary,
)
from morca._internal.cgroup import (
    Cgroups,
    Contained,
    MemoryKnobs,
    HeldWatch,
    at_limit,
    held_text,
    ceiling_mb,
    oom_text,
    own_limit_pressure,
    put as put_cgroup,
    raised_mb,
    start_limit_mb,
)
from morca._internal.run_cpu import CpuKnobs
from morca._internal.control import ControlLimits
from morca._internal.crash import (
    crash_summary,
    crashed_by_signal,
)
from morca._internal.alerts import (
    disk as alert_disk,
    fill as alert_fill,
    lost_workers,
    watchdog_recovered,
)
from morca._internal.notify import (
    configured as notify_configured,
    flush as flush_notify,
)
from morca._internal.fill import fill_status
from morca._internal.ec2 import Ec2Runner
from morca._internal.fleet import ingest
from morca._internal.system import (
    Archive,
    keep as keep_system,
    trim as trim_system,
)
from morca._internal.kube import (
    KubeRunner,
    cpu_millis,
)
from morca._internal.instances import (
    beat,
    drain_limit,
    end as end_instance,
    join as join_instance,
    newer,
    overlap_on,
    step_down,
    try_lead,
)
import morca._internal.db.scheduler as scheduler_db
from morca._internal.db.live import stale_limit, start_grace
from morca._internal.logs import read_location
from morca._internal.proc import (
    Capture,
    binary_seconds,
    spawn,
)
from morca._internal.sample import (
    tree_rss,
    tree_usage,
)
from morca._internal.resources import (
    Grant,
    Room,
    host_room,
)
from morca._internal.admission import (
    SCHEDULER_HOST,
    Report,
    alert_stuck,
    record as record_pressure,
    resolve_stuck,
)
from morca._internal.pressure import (
    Admission,
    Source,
    find_source,
    pct_text,
    read_psi,
)
from morca._internal.recommend import learned
from morca._internal.state import State
from morca._internal.watchdog import (
    check as check_watchdog,
    config as watchdog_config,
)
from morca._internal.usage import Meter
from morca._internal.registered import (
    Registered,
    fill_pipeline,
    placed_of,
    registered,
)
from morca._internal.queueing import (
    Queued,
    _last_line,
    backfill,
)

comptime _BUDGET_LOCK = 0x6F726362  # "orcb"
"""Held while a start is weighed against `MORCA_VCPU_BUDGET`."""

comptime _CONTROL_LOCK = 0x6F726363  # "orcc"
"""Held while a control-placed start is weighed against
`MORCA_CONTROL_MAX_RUNS`."""

comptime _HOST_LOCK = 0x6F726364  # "orcd"
"""Held while a start is weighed against what this host's running runs
weren't granted (`morca._internal.resources`)."""

comptime AUTO_ONE_AT_A_TIME = (
    'waiting: max_runs = "auto" starts one run at a time until its runs'
    " have a request to weigh (cpus, memory_gb, learned or declared)"
)
"""Why a queued run of a `max_runs = "auto"` pipeline with no request waits
while another runs."""

comptime _WORKER_OWNER = "worker"
"""A run's owner once a worker claimed it and before its process did
(`orca.workers.WORKER_OWNER`, which imports this module)."""
comptime _RETRIED = scheduler_db.RETRIED
"""The runs the scheduler retries, as SQL (`morca._internal.db.scheduler.RETRIED`)."""
comptime RETRIED_SQL = _RETRIED
"""`_RETRIED`, for `morca._internal.actions`."""


@fieldwise_init
struct _ControlProc(Copyable, Movable):
    """A control-placed run's process, as the scheduler keeps it."""

    var run: Int
    var binary: String
    var stage: String
    """Where its output goes, or empty without `MORCA_LOGS`."""
    var location: String
    """The run's `driver.log`, which `keep-log` appends `stage` to."""
    var start: Int
    var env: List[String]
    """What it was given beside the scheduler's environment: its secrets'
    values among them, which `keep-log` masks."""
    var over: String
    """Why the scheduler killed it, over its memory cap, or empty."""


struct Scheduler(Movable):
    var db: State
    var stale: Float64
    var retry_seconds: Int64
    var sense_seconds: Float64
    var start_grace: Float64
    """How long a run the scheduler started may go without a heartbeat."""
    var budget: Int
    """`MORCA_VCPU_BUDGET` in thousandths of a vCPU; 0 for none."""
    var runner: Optional[KubeRunner]
    """Set with `MORCA_RUNNER=kubernetes`."""
    var ec2: Optional[Ec2Runner]
    """Set with `MORCA_RUNNER=ec2`; with neither, runs are local processes."""
    var pools: PoolScaler
    """The pool autoscaler's state between passes (`morca._internal.pool_scale`)."""
    var logs: String
    var _polled: Dict[String, Int]
    """When each sensor's binary was last asked to `sense`, on the monotonic
    clock in nanoseconds."""
    var _driver_logs: Dict[Int, String]
    """A local run's process to where its driver log goes, when that's in
    object storage: it's published once the process is reaped."""
    var _spawned: Dict[Int, Tuple[Int, Int, String]]
    """A local run's process to its run, the run's start count when it was
    started, and the local file its output goes to (or empty)."""
    var _asked: Dict[String, Capture]
    """The `sense` and `keys` of pipeline binaries still going, by
    `<command> <pipeline>`: a tick starts one and later ticks check on it,
    so a slow binary holds up no other pipeline."""
    var _unsensed: Dict[String, String]
    """A keyed sensor's `sense` output, kept until its keys are read."""
    var _keys: Dict[String, Tuple[Int64, List[String]]]
    """Each keyed sensor's keys as last read, by pipeline."""
    var wait_for_binaries: Bool
    """Whether a tick waits for the binaries it asks (`morca tick`, which
    has no later tick to collect them), rather than checking next tick."""
    var expire_seconds: Float64
    """How often every dataset is expired by its own policy
    (`MORCA_EXPIRE_HOURS`, 24; 0 turns it off)."""
    var maintain: String
    """The `morca_maintain` binary that expires, or empty for none."""
    var _expire_next: Int
    """When the next expiry sweep starts, on the monotonic clock."""
    var _expiring: List[String]
    """The datasets this sweep has still to expire, the first one going."""
    var fleet_seconds: Float64
    """How often the fleet page's samples are read from the instances'
    files (`MORCA_FLEET_SECONDS`, 30; 0 turns it off)."""
    var _fleet_next: Int
    """When the next pass starts, on the monotonic clock."""
    var _archive: Archive
    """The control instance's day files between passes (`morca._internal.system`)."""
    var watchdog_seconds: Float64
    """How often the watchdog's rules are checked
    (`MORCA_WATCHDOG_SECONDS`, 60; 0 turns it off): `morca._internal.watchdog`."""
    var _watchdog_next: Int
    """When the next check starts, on the monotonic clock."""
    var _notify_next: Int
    """When the alerts' checks (`orca.alerts`) run next, on the monotonic
    clock; they are every `MORCA_NOTIFY_CHECK_SECONDS` (10)."""
    var limits: ControlLimits
    """What a control-placed run may use (`morca._internal.control`)."""
    var room: Room
    """What this host can grant the runs of pipelines with a request
    (`morca._internal.resources`): its capacity less its reserve."""
    var _control: Dict[Int, _ControlProc]
    """A control-placed run's process to what its end needs."""
    var _kept: Dict[Int, _ControlProc]
    """A local run's process whose output, staged for its secrets, `keep-log`
    appends to its `driver.log` once it ends."""
    var _keeping: Dict[Int, String]
    """A `keep-log` still going to the staging file it keeps, removed once
    it has ended."""
    var _meters: Dict[Int, Meter]
    """A local or control-placed run's process to its samples, recorded on
    its attempts when it's reaped (`morca._internal.usage`)."""
    var psi: Source
    """Where this host's memory pressure is read from (`orca.pressure`),
    found once; none on macOS or without PSI."""
    var admission: Admission
    """Whether runs may start on this host for its memory pressure, from
    each tick's reading."""
    var _pressure_kept: Int
    """When the reading was last kept in `orca.pressure`, on the monotonic
    clock."""
    var _pressure_unread: Bool
    """The file was found but last couldn't be read (said once)."""
    var cgroups: Cgroups
    """Where its runs' cgroups go (`morca._internal.cgroup`); off until `contain`."""
    var _contained: Dict[Int, Contained]
    """A local or control-placed run's process to its cgroup."""
    var _unswept: List[String]
    """Runs' cgroups to remove once their processes have left them."""
    var _stalled: Dict[Int, Bool]
    """Contained runs' processes killed while held at their memory limit,
    for a stale heartbeat or by `_kill_held`: out of memory, as a kill at
    memory.max is."""
    var _wedged: Dict[Int, Bool]
    """Processes `_kill_wedged` killed for their run's stale heartbeat, until
    they're reaped: what their attempts are failed with says so."""
    var _held: HeldWatch
    """Since when contained runs have been held at their memory limit."""
    var _cgroups_next: Int
    """When the runs' cgroups' memory is next recorded, on the monotonic
    clock."""
    var instance: Int
    """This scheduler's row of `orca.schedulers` (`orca.instances`), or 0
    when it isn't an instance: `MORCA_OVERLAP` off, or `morca tick`."""
    var leading: Bool
    """Whether this instance holds the lead (always, for no instance)."""
    var draining: Bool
    """Whether this instance drains: it starts nothing, and exits once the
    processes it started have ended."""
    var drain_seconds: Float64
    """`MORCA_DRAIN_SECONDS`: how long a drain waits for its runs before it
    kills what's left. Required of an instance (#390: `join` refuses to
    start without it); -1 for a scheduler that isn't one, which never
    drains."""
    var _drain_start: Int
    """When the drain began, on the monotonic clock."""
    var finished: Bool
    """Whether a drained instance has ended: `morca scheduler` exits."""
    var _going: Int
    """For an instance, the local and control-placed runs going on this
    host across every instance, as this tick counted them: memory
    pressure's "none of morca's runs going"."""

    def __init__(out self, url: String) raises:
        self.db = State(url)
        self.db.migrate()
        self.stale = stale_limit()
        self.retry_seconds = Int64(Int(getenv("MORCA_RETRY_SECONDS", "60")))
        self.sense_seconds = Float64(getenv("MORCA_SENSE_SECONDS", "60"))
        var runner = getenv("MORCA_RUNNER", "local")
        self.runner = None
        self.ec2 = None
        self.pools = PoolScaler()
        if runner == "kubernetes":
            self.runner = KubeRunner()
        elif runner == "ec2":
            self.ec2 = Ec2Runner()
        elif runner != "local":
            raise Error(
                "morca: MORCA_RUNNER is local, kubernetes or ec2, not ", runner
            )
        # A pod can take minutes to be scheduled and pull its image.
        self.start_grace = start_grace(self.stale)
        var budget = getenv("MORCA_VCPU_BUDGET")
        self.budget = cpu_millis(budget) if budget else 0
        self.logs = getenv("MORCA_LOGS")
        self._polled = Dict[String, Int]()
        self._asked = Dict[String, Capture]()
        self._unsensed = Dict[String, String]()
        self._keys = Dict[String, Tuple[Int64, List[String]]]()
        self.wait_for_binaries = False
        self._driver_logs = Dict[Int, String]()
        self._spawned = Dict[Int, Tuple[Int, Int, String]]()
        self.expire_seconds = Float64(getenv("MORCA_EXPIRE_HOURS", "24")) * 3600
        self.maintain = maintain_binary() if self.expire_seconds > 0 else ""
        # The first sweep a few minutes after starting
        # (`MORCA_EXPIRE_DELAY_SECONDS`, 300), not at once: a scheduler
        # restarted in a loop shouldn't expire on every start.
        self._expire_next = Int(perf_counter_ns()) + Int(
            Float64(getenv("MORCA_EXPIRE_DELAY_SECONDS", "300")) * 1e9
        )
        self._expiring = List[String]()
        self.fleet_seconds = Float64(getenv("MORCA_FLEET_SECONDS", "30"))
        self._fleet_next = 0
        self._archive = Archive()
        self.watchdog_seconds = Float64(getenv("MORCA_WATCHDOG_SECONDS", "60"))
        self._watchdog_next = 0
        self._notify_next = 0
        self.limits = ControlLimits.from_env()
        self.room = host_room()
        self._control = Dict[Int, _ControlProc]()
        self._kept = Dict[Int, _ControlProc]()
        self._keeping = Dict[Int, String]()
        self._meters = Dict[Int, Meter]()
        self.psi = find_source()
        self.admission = Admission.from_env()
        self._pressure_kept = 0
        self._pressure_unread = False
        var cgroups = Cgroups.off("off: not the scheduler's loop")
        cgroups.cpu_knobs = CpuKnobs.from_env()
        self.cgroups = cgroups^
        self._contained = Dict[Int, Contained]()
        self._unswept = List[String]()
        self._stalled = Dict[Int, Bool]()
        self._wedged = Dict[Int, Bool]()
        self._held = HeldWatch()
        self._cgroups_next = 0
        self.instance = 0
        self.leading = True
        self.draining = False
        self.drain_seconds = -1.0
        self._drain_start = 0
        self.finished = False
        self._going = 0

    def join(mut self) raises:
        """With `MORCA_OVERLAP=on`, makes this scheduler an instance
        (`orca.instances`): it leads only once it holds the lead. Refuses
        to without `MORCA_DRAIN_SECONDS` (#390)."""
        if not overlap_on():
            return
        self.drain_seconds = drain_limit()
        self.instance = join_instance(self.db)
        self.leading = False
        print("morca: scheduler instance", self.instance, "joined")

    def reconnect(mut self, url: String) raises:
        """A new connection after a tick failed, keeping what this instance
        supervises; the lead, which was the old connection's, is taken
        again on the next tick if no newer instance has it."""
        self.db = State(url)
        self.db.migrate()
        self.leading = False

    def _idle(self) -> Bool:
        """Whether none of morca's runs is going on this host: none of its
        own children, or for an instance none of any instance's."""
        if self.instance > 0:
            return self._going == 0
        return len(self._spawned) == 0

    def _lead(mut self) raises:
        """An instance's turn at the lead: marks it seen with its runs,
        drains once a newer instance is live or it's asked to, takes the
        lead when free otherwise, and while draining ends once nothing it
        started is left (killing what is after `drain_seconds`)."""
        var running = String()
        for e in self._spawned.items():
            if running:
                running.write(",")
            running.write(e.value[0])
        var asked = beat(self.db, self.instance, running)
        if not self.draining:
            var n = newer(self.db, self.instance)
            if asked or n > 0:
                step_down(self.db, self.instance, self.leading)
                self.leading = False
                self.draining = True
                self._drain_start = Int(perf_counter_ns())
                var why = String("instance ", n, " is newer") if n > 0 else (
                    String("asked to")
                )
                print(
                    String("morca: scheduler instance ", self.instance),
                    String(" drains (", why, "): "),
                    len(self._spawned),
                    " runs going",
                    sep="",
                )
            elif not self.leading and try_lead(self.db, self.instance):
                self.leading = True
                print("morca: scheduler instance", self.instance, "leads")
        if not self.draining:
            return
        if len(self._spawned) == 0 and len(self._keeping) == 0:
            end_instance(self.db, self.instance)
            self.finished = True
            print("morca: scheduler instance", self.instance, "drained")
            return
        var waited = Float64(Int(perf_counter_ns()) - self._drain_start) / 1e9
        if waited < self.drain_seconds:
            return
        for e in self._spawned.items():
            if e.key in self._control:
                _ = external_call["kill", c_int](c_int(-e.key), c_int(9))
            _ = external_call["kill", c_int](c_int(e.key), c_int(9))
            print(
                "killed pid",
                e.key,
                "of run",
                e.value[0],
                "(the drain ran out after",
                Int(self.drain_seconds),
                "s)",
            )
        end_instance(self.db, self.instance)
        self.finished = True
        print(
            "morca: scheduler instance",
            self.instance,
            "ended its drain; the leader queues its runs again",
        )

    def stop(mut self) raises:
        """An instance's SIGTERM or SIGINT (`docker stop`, #426): kills what
        it started, as a drain that runs out does, and ends its row at
        once, so it isn't counted leading until its heartbeat goes stale;
        the leader queues its runs again. `morca scheduler` then exits."""
        self.finished = True
        if self.instance == 0:
            return
        for e in self._spawned.items():
            if e.key in self._control:
                _ = external_call["kill", c_int](c_int(-e.key), c_int(9))
            _ = external_call["kill", c_int](c_int(e.key), c_int(9))
            print("killed pid", e.key, "of run", e.value[0], "(stopped)")
        end_instance(self.db, self.instance)
        print("morca: scheduler instance", self.instance, "stopped")

    def _kill_held(mut self):
        """Kills each contained run held at its memory limit (`held`) for
        `MORCA_RUN_MEMORY_HELD_SECONDS` in a row: throttled at memory.high,
        it may never reach memory.max, and its heartbeat, kept on another
        thread, stays fresh. Reaped, it's out of memory (`_uncontain`)."""
        var held_s = self.cgroups.knobs.held_s
        for pid in self._held.due(self._contained, held_s):
            self._stalled[pid] = True
            if pid in self._control:
                _ = external_call["kill", c_int](c_int(-pid), c_int(9))
            _ = external_call["kill", c_int](c_int(pid), c_int(9))
            try:
                ref c = self._contained[pid]
                print(
                    "killed pid",
                    pid,
                    "of",
                    c.pipeline,
                    "run",
                    c.run,
                    String("(", held_text(c, held_s), ")"),
                )
            except:
                pass

    def _kill_wedged(mut self) raises:
        """Kills each process of ours whose run's heartbeat went stale: it's
        wedged, or stopped, rather than gone (it would have been reaped),
        and mustn't go on beside its run's next start. Until it's reaped its
        run isn't dead (`_dead`), so nothing ends or starts it again while
        the process may still be there (#398); once reaped, its run is
        cancelled, failed or started again as a dead one."""
        if len(self._spawned) == 0:
            return
        var ids = String()
        for e in self._spawned.items():
            if ids:
                ids.write(",")
            ids.write(e.value[0])
        for r in scheduler_db.stale_of(
            self.db.conn, self.stale, self.start_grace, ids
        ):
            var id = r[0]
            var pid = 0
            for e in self._spawned.items():
                if e.value[0] == id:
                    pid = e.key
            if pid <= 0:
                continue
            if pid in self._contained:
                # Throttled at its limit (memory.high) rather than wedged:
                # out of memory.
                try:
                    ref c = self._contained[pid]
                    if at_limit(Cgroups.current(c.path), c.limit_mb):
                        self._stalled[pid] = True
                except:
                    pass
            if pid in self._control:
                # Its own process group: its forked workers too.
                _ = external_call["kill", c_int](c_int(-pid), c_int(9))
            _ = external_call["kill", c_int](c_int(pid), c_int(9))
            if pid in self._wedged:
                continue  # killed already, not reaped yet
            self._wedged[pid] = True
            print(
                "killed pid",
                pid,
                "of",
                r[1],
                "run",
                id,
                "(its heartbeat went stale)",
            )

    def say_pressure(self):
        """Says once, for `morca scheduler`, where this host's memory
        pressure is read from and what it holds (`orca.pressure`)."""
        if not self.psi:
            print(
                "morca: no memory pressure to read here (no PSI: macOS, or a",
                " kernel without it); runs start on counts and grants alone",
                sep="",
            )
        elif self.admission.limit <= 0:
            print(
                "morca: memory pressure from",
                self.psi.describe(),
                "- admission by it is off (MORCA_ADMIT_MEMORY_PRESSURE=0)",
            )
        else:
            print(
                "morca: memory pressure from",
                self.psi.describe(),
                "- no new runs start here while some avg10 is over",
                String(pct_text(self.admission.limit), "%"),
            )

    def contain(mut self) raises:
        """Turns on a cgroup per run (`morca._internal.cgroup`) where this host lets
        morca make them, saying once which, and picks up the empty cgroups
        an earlier scheduler left. `morca scheduler` does this; `morca tick`
        and the other commands don't, as they don't reap what they
        start."""
        self.cgroups = Cgroups.setup(
            MemoryKnobs.from_env(), CpuKnobs.from_env()
        )
        print("morca: run cgroups", self.cgroups.why)
        print("morca: runs' CPU priority:", self.cgroups.cpu_text())
        if not self.cgroups.on():
            print(
                "morca: runs are contained as before: first to go if memory",
                "runs out, and control-placed runs killed over",
                "MORCA_CONTROL_MEMORY_MB",
            )
        self._unswept = self.cgroups.stale()
        self._sweep_cgroups()

    def _sweep_cgroups(mut self):
        """Removes the runs' cgroups their processes have left."""
        var left = List[String]()
        for path in self._unswept:
            if not Cgroups.remove(path):
                left.append(path)
        self._unswept = left^

    def _contain(
        mut self,
        p: Registered,
        run: Int,
        start: Int,
        grant: Grant,
        control: Bool,
    ) -> Contained:
        """Makes a start's cgroup at its limit (`morca._internal.cgroup`) and records
        the limit on the run; with cgroups off, or if it can't, one with no
        path, and the run starts as before."""
        var c = Contained(run, start, p.name, "", 0, 0, 0, grant.memory_mb)
        if not self.cgroups.on():
            return c^
        try:
            var req = p.request()
            var cap = self.limits.memory_mb if control else 0
            var default = self.cgroups.knobs.default_mb
            if default <= 0:
                default = cap if control else self.room.memory_mb
            c.limit_mb = start_limit_mb(
                grant.memory_mb,
                req.memory_max_mb,
                default,
                p.memory_raised_mb,
                cap,
            )
            c.ceiling_mb = ceiling_mb(
                req.memory_max_mb, self.room.memory_mb, cap
            )
            if c.limit_mb <= 0:
                return c^
            var made = self.cgroups.make(run, start, c.limit_mb, grant.cpus)
            c.path = made[0]
            c.kill_mb = made[1]
            scheduler_db.set_memory_limit(
                self.db.conn, run, start, c.limit_mb, c.kill_mb
            )
        except e:
            print("morca: run", run, "starts without a cgroup:", e)
            if c.path and not Cgroups.remove(c.path):
                self._unswept.append(c.path)
            c.path = ""
        return c^

    def _uncontain(mut self, pid: Int, code: Int, mut over: String) -> Bool:
        """At the reap of `pid`: if the kernel killed its run's processes
        for their memory, `over` says so, and its pipeline asks for more
        from now on; its attempts get its limit; the cgroup is emptied of
        what's left of the run, and removed. True if it was killed at the
        most it may ask for, so a retry would be killed again."""
        if pid not in self._contained:
            return False
        var c: Contained
        try:
            c = self._contained.pop(pid)
        except:
            return False
        var stalled = self._stalled.pop(pid, False)
        var spent = False
        if (
            code != 0
            and not over
            and (stalled or Cgroups.oom_kills(c.path) > 0)
        ):
            var next = raised_mb(
                c.limit_mb, self.cgroups.knobs.growth_pct, c.ceiling_mb
            )
            over = oom_text(
                c.limit_mb,
                c.kill_mb,
                next,
                stalled and Cgroups.oom_kills(c.path) == 0,
            )
            print("run", c.run, "pid", pid, over)
            spent = next <= c.limit_mb
            try:
                scheduler_db.raise_memory(self.db.conn, c.pipeline, next, c.run)
            except e:
                print("morca: can't raise", c.pipeline, "memory:", e)
        var stall = Cgroups.stall_ms(c.path)
        try:
            scheduler_db.attempts_memory(
                self.db.conn,
                c.run,
                pid,
                c.limit_mb,
                c.grant_mb,
                stall[0],
                stall[1],
            )
            scheduler_db.clear_memory_bytes(self.db.conn, c.run, c.start)
        except e:
            print("morca: can't record run", c.run, "memory limit:", e)
        # The run is over: what it left running goes with it.
        _ = put_cgroup(String(c.path, "/cgroup.kill"), "1")
        if not Cgroups.remove(c.path):
            self._unswept.append(c.path)
        return spent

    def _record_cgroups(mut self):
        """Every 5 s, each contained run's memory now, for Ops > Control;
        and the cgroups of ended runs removed once empty."""
        if len(self._unswept) > 0:
            self._sweep_cgroups()
        if len(self._contained) == 0:
            return
        var t = Int(perf_counter_ns())
        if t < self._cgroups_next:
            return
        self._cgroups_next = t + 5_000_000_000
        for e in self._contained.items():
            var b = Cgroups.current(e.value.path)
            if b < 0:
                continue
            try:
                scheduler_db.set_memory_bytes(
                    self.db.conn, e.value.run, e.value.start, b
                )
            except:
                pass

    def _pressure(mut self) raises:
        """Reads this host's memory pressure (`orca.pressure`) for this
        tick's starts, says when a hold starts and ends, alerts once when
        one has nothing of morca's to wait for, and keeps the reading in
        `orca.pressure` every 5 s and on each change of hold (with no
        reading where there's no PSI, so Ops says so)."""
        var t = Int(perf_counter_ns())
        var psi = read_psi(self.psi.path)
        if self.psi and not psi and not self._pressure_unread:
            print(
                "morca: can't read memory pressure from",
                self.psi.path,
                "- nothing is held until it reads",
            )
        self._pressure_unread = not psi
        var was = self.admission.hold
        var now = Float64(t) / 1e9
        self.admission.observe(
            psi, now, self._idle(), own_limit_pressure(self._contained)
        )
        ref a = self.admission
        var r = Report.of(self.psi, a, now)
        if a.held() and not was:
            print("morca:", a.hold, "- no new runs start on this host")
        if a.released:
            print(
                "morca: memory pressure",
                String(pct_text(r.some10), "%"),
                "- runs start on this host again",
            )
            resolve_stuck(self.db, "the scheduler's host", r)
        if a.stuck:
            alert_stuck(self.db, "the scheduler's host", r)
        var changed = (was.byte_length() > 0) != a.held()
        if changed or t - self._pressure_kept >= 5_000_000_000:
            record_pressure(self.db, SCHEDULER_HOST, r)
            self._pressure_kept = t

    def _exited(
        mut self,
        spawned: Tuple[Int, Int, String],
        pid: Int,
        code: Int,
        over: String = "",
    ) raises:
        """Fails the run a reaped process was started for, if the process
        never claimed it: the run is still the scheduler's, at the start it
        was given. Its error is the exit code and the last line its process
        printed, such as `resume`'s refusal. A process that claimed it and
        crashed has the attempts it left running failed with the crash's
        summary (`morca._internal.crash`), or with `over` if the scheduler killed it
        for its memory (`morca._internal.control`)."""
        var why = String(
            "its process (pid ", pid, ") exited ", code, " before claiming it"
        )
        var last = over if over else _last_line(spawned[2])
        if last:
            why.write(": ", last)
        var n = scheduler_db.fail_unclaimed(
            self.db.conn, spawned[0], spawned[1], why
        )
        if n == 1:
            print("run", spawned[0], "failed:", why)
        elif crashed_by_signal(code) or over:
            self._crashed(spawned, pid, code, over)

    def _fail_spent(
        mut self, spawned: Tuple[Int, Int, String], over: String
    ) raises:
        """Fails the run a process killed for its memory at the most it may
        ask for was started for, with `over` as its error: a retry would
        ask for the same and be killed again."""
        var n = scheduler_db.fail_unretried(
            self.db.conn, spawned[0], spawned[1], over
        )
        if n == 1:
            print("run", spawned[0], "failed, not retried:", over)

    def _crashed(
        mut self,
        spawned: Tuple[Int, Int, String],
        pid: Int,
        code: Int,
        over: String = "",
    ) raises:
        """Fails the attempts a crashed process left running, if the run is
        still its at that start, with what its driver log says of the crash
        or, with no log or no dump in it, the signal."""
        if not scheduler_db.held_by_pid(
            self.db.conn, spawned[0], spawned[1], pid
        ):
            return
        var why = over
        if not why and spawned[2] and exists(spawned[2]):
            try:
                with open(spawned[2], "r") as f:
                    why = crash_summary(f.read())
            except e:
                print("morca: can't read", spawned[2], ":", e)
        if not why:
            why = String(
                "crashed: killed by signal ",
                code - 128,
                ", with no stack dump in its output",
            )
        var n = self.db.interrupt(spawned[0], why)
        print("run", spawned[0], "crashed,", n, "attempts failed:", why)

    def _keep_control_log(mut self, c: _ControlProc):
        """Appends a control-placed run's output, or a local run's with
        secrets, to its `driver.log`, masked (`<binary> keep-log`, given the
        run's secrets as the run was); the staging file is removed once
        that has ended."""
        if not c.location:
            return
        try:
            var pid = spawn(
                [c.binary, "keep-log", c.stage, c.location, String(c.start)],
                env=c.env,
            )
            self._keeping[pid] = c.stage
        except e:
            print("morca: can't keep run", c.run, "driver log:", e)

    def _sample(mut self) -> Dict[Int, Tuple[Int, Float64]]:
        """Samples each local and control-placed run's process tree, in one
        pass over /proc (`morca._internal.usage`); the readings, by pid, are empty on
        macOS."""
        var pids = List[Int]()
        for e in self._meters.items():
            pids.append(e.key)
        var readings = tree_usage(pids)
        for e in readings.items():
            try:
                self._meters[e.key].sample(e.value[0], e.value[1])
            except:
                pass
        return readings^

    def _check_control_memory(
        mut self, readings: Dict[Int, Tuple[Int, Float64]]
    ) raises:
        """Kills each control-placed run's processes once they hold more
        than `MORCA_CONTROL_MEMORY_MB` resident; the reap fails its attempts
        saying so. The tick's `readings` say what they hold, or on macOS
        `tree_rss`."""
        if len(self._control) == 0:
            return
        var cap = self.limits.memory_mb * 1024 * 1024
        var pids = List[Int]()
        for e in self._control.items():
            # A run in a cgroup has its limit there (morca.cgroup).
            if not e.value.over and e.key not in self._contained:
                pids.append(e.key)
        for pid in pids:
            var rss = readings[pid][0] if pid in readings else tree_rss(pid)
            if rss <= cap:
                continue
            var c = self._control.pop(pid)
            c.over = String(
                "killed: its processes held ",
                rss // (1024 * 1024),
                " MB, over the control instance's cap of ",
                self.limits.memory_mb,
                " MB a run (MORCA_CONTROL_MEMORY_MB)",
            )
            _ = external_call["kill", c_int](c_int(-pid), c_int(9))
            _ = external_call["kill", c_int](c_int(pid), c_int(9))
            print("run", c.run, "pid", pid, c.over)
            self._control[pid] = c^

    def _fleet(mut self) raises:
        """Every `fleet_seconds`, keeps the new samples of the live
        instances and the control instance for the fleet page
        (`morca._internal.fleet`)."""
        if self.fleet_seconds <= 0 or not (
            self.ec2 or getenv("MORCA_CONTROL_SAMPLES")
        ):
            return
        var t = Int(perf_counter_ns())
        if t < self._fleet_next:
            return
        self._fleet_next = t + Int(self.fleet_seconds * 1e9)
        _ = ingest(self.db)
        var control = getenv("MORCA_CONTROL_SAMPLES")
        if control:
            # The same file the fleet read, for the system page's history.
            var text = String()
            try:
                text = String(from_utf8_lossy=Span(read_location(control)))
            except:
                pass  # not written yet
            if text:
                _ = keep_system(self.db, text, self._archive)
            trim_system(self.db)

    def _watchdog(mut self) raises:
        """Every `watchdog_seconds`, checks the watchdog's rules and pauses
        the pipelines of those over their limits (`morca._internal.watchdog`).
        """
        if self.watchdog_seconds <= 0:
            return
        var t = Int(perf_counter_ns())
        if t < self._watchdog_next:
            return
        self._watchdog_next = t + Int(self.watchdog_seconds * 1e9)
        _ = check_watchdog(self.db, watchdog_config())

    def _notify(mut self, now: Int64) raises:
        """Alerts to a person (`morca._internal.notify`): sends what is pending and
        due, and every `MORCA_NOTIFY_CHECK_SECONDS` (10) checks what the
        alerts of `orca.alerts` are about that the scheduler's other steps
        don't decide: a watchdog trip that ended, the control host's disk,
        workers that went quiet, and fills that stalled. A failure to send
        is logged and tried again later, never raised."""
        if not notify_configured():
            return
        _ = flush_notify(self.db)
        var t = Int(perf_counter_ns())
        if t < self._notify_next:
            return
        var every = Float64(getenv("MORCA_NOTIFY_CHECK_SECONDS", "10"))
        self._notify_next = t + Int(every * 1e9)
        watchdog_recovered(self.db)
        alert_disk(self.db)
        _ = lost_workers(self.db)
        var hour = Int((now % 86400) // 3600)
        for p in registered(self.db):
            if not p.fill.all:
                continue
            var tx = self.db.conn.begin()
            var status = fill_status(
                tx,
                fill_pipeline(
                    p,
                    placed_of(p),
                    Int(self.ec2.value().pool_seconds) if self.ec2 else 0,
                ),
                now,
                p.run_retries,
            )
            tx.commit()
            alert_fill(
                self.db, p.name, status, p.paused, p.fill.in_window(hour)
            )
        _ = flush_notify(self.db)

    def _ask(
        mut self, job: String, what: String, argv: List[String]
    ) raises -> Optional[String]:
        """What `argv` printed, once it has ended: started the first time
        `job` is asked for, and checked on by later calls, which get None
        while it's going (unless `wait_for_binaries`). One that exits
        non-zero raises `<what> exited <code>: <output>`; one going longer
        than `MORCA_BINARY_SECONDS` is killed, and raises saying so."""
        if job not in self._asked:
            self._asked[job] = Capture.start(argv)
        var limit = binary_seconds()
        while True:
            var c = self._asked.pop(job)
            if c.ended():
                var out = c.output()
                if c.code != 0:
                    raise Error(what, " exited ", c.code, ": ", out)
                return out^
            if limit > 0 and c.seconds() > limit:
                c.kill()
                raise c.timed_out(limit)
            self._asked[job] = c^
            if not self.wait_for_binaries:
                return None
            sleep(0.01)

    def _expire(mut self) raises:
        """Every `expire_seconds`, expires each dataset morca commits to by
        the table's own `history.expire.*` properties, one at a time in the
        background (`morca_maintain expire --if-policy`), with the snapshots
        live runs need retained (`morca._internal.expiry.retained`). `morca tick` waits
        for the whole sweep."""
        if self.expire_seconds <= 0 or not self.maintain:
            return
        while True:
            if len(self._expiring) == 0:
                var t = Int(perf_counter_ns())
                if t < self._expire_next:
                    return
                self._expire_next = t + Int(self.expire_seconds * 1e9)
                self._expiring = expirable(self.db)
                if len(self._expiring) == 0:
                    return
            var ds = self._expiring[0]
            var job = String("expire ", ds)
            var argv = List[String]()
            if job not in self._asked:
                argv = expire_argv(self.db, self.maintain, ds)
            var out: Optional[String]
            try:
                out = self._ask(job, String("morca: expire ", ds), argv)
            except e:
                _ = self._expiring.pop(0)
                raise e
            if not out:
                return
            _ = self._expiring.pop(0)
            var line = String(out.value().strip())
            if line:
                print(line)
            if len(self._expiring) == 0:
                return

    def _schedule_retries(mut self, p: Registered, now: Int64) raises:
        """Gives each failed run that may be retried its time to start:
        the pipeline's `retry_seconds` (or `MORCA_RETRY_SECONDS`) doubling
        with each start that wasn't after a deferral, up to its
        `max_retry_seconds`, plus up to a tenth as jitter. Not one whose
        failure at this start isn't retried (`unretried_start`)."""
        var base = Int64(p.retry_seconds) if p.retry_seconds > 0 else (
            self.retry_seconds
        )
        scheduler_db.schedule_retries(
            self.db.conn,
            p.name,
            now,
            base,
            p.run_retries,
            p.max_retry_seconds,
            p.registry_hash,
        )

    def _dead(self, stale_param: StaticString) -> String:
        """SQL true for a running run whose process died: its heartbeat is
        older than the stale limit, the parameter `stale_param`, or it has
        none and was started longer ago than the start grace, and it isn't
        one whose process this scheduler started and hasn't reaped. That
        process may be wedged rather than gone: `_kill_wedged` kills it,
        and only once it's reaped is the run dead, so it's never failed,
        cancelled or started again with its process still there (#398)."""
        var ids = String()
        for e in self._spawned.items():
            if ids:
                ids.write(",")
            ids.write(e.value[0])
        return scheduler_db.dead_except(
            String(stale_param), self.start_grace, ids
        )

    def _end_dead(
        mut self, mut tx: Transaction, p: Registered, dead: String
    ) raises:
        """Ends what of `p`'s runs can't go on: a run asked to cancel whose
        process died is cancelled; one of code that isn't the pipeline's
        any more fails, saying how to resume it; one whose process died
        with no retries left, or that the scheduler doesn't retry, fails
        (and so does a fill run's while fills are off); and while `p` is
        paused, one with retries left is queued again, as nothing restarts
        it until then and it would look running (a deploy's drain waits
        for it)."""
        scheduler_db.cancel_dead(tx, p.name, self.stale, dead)
        # A run of code that isn't the pipeline's any more would be refused
        # by the binary's `resume`, and started again until its retries were
        # spent, so it fails here, saying how to resume it.
        scheduler_db.fail_old_code(
            tx, p.name, self.stale, p.run_retries, p.registry_hash, dead
        )
        # A run whose process died and has no retries left has failed, and
        # so has one the scheduler doesn't retry (a manual, UI or rerun
        # run), so it holds its keys no longer and can be resumed.
        scheduler_db.fail_dead(
            tx, p.name, self.stale, p.run_retries, p.fill.all, dead
        )
        if p.paused:
            var n = scheduler_db.requeue_dead(tx, p.name, self.stale, dead)
            if n > 0:
                print(
                    "morca: paused",
                    p.name,
                    "has",
                    n,
                    "run(s) whose process stopped: queued again",
                )

    def backfill(
        mut self,
        pipeline: String,
        keys: String,
        rerun: Bool = False,
        allow_append: Bool = False,
    ) raises -> Queued:
        """Queues a run for each partition in `keys` that has none; see
        `backfill`."""
        var ps = registered(self.db, pipeline)
        if len(ps) == 0:
            raise Error("morca: pipeline ", pipeline, " isn't registered")
        return backfill(self.db, ps[0], keys, rerun, allow_append)
