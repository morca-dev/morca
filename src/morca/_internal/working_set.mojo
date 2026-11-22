"""The working-set probe (#281, after Meta's Senpai and TMO): while a probed
run goes, its cgroup's `memory.high` is lowered step by step below its limit,
watching its memory pressure, to learn how much memory the run needs to go
at full speed rather than how much it touched (its peak).

A pipeline opts in with `learn = "working_set"` in morca.toml; with
`probe_every = N` only about one run in N is probed (`probed`), and only a
run's first start, never a retry. The scheduler probes its local and
control-placed runs (`ProbeWatch`); a remote worker's runs aren't probed.

**The controller** (`Probe.next`, a pure function of the run's memory.high,
its memory, the pressure over the last interval and the knobs, so it's
tested without cgroups). Every `MORCA_RUN_PROBE_SECONDS` (5) the share of
the interval some of the run's tasks waited on memory (the delta of
`memory.pressure`'s `some total`) is compared to a target,
`MORCA_RUN_PROBE_TARGET` (0.1 percent, Senpai's order):

- at or under it, memory.high goes down a step (`MORCA_RUN_PROBE_STEP`, 2
  percent of the limit), never below the floor: the larger of
  `MORCA_RUN_PROBE_FLOOR` (50) percent of the limit, the run's memory now
  less a step (a step's reclaim at a time), and a step over the highest
  memory.high at which the pressure has passed the target (the wall);
- over it, memory.high goes back up four steps, or straight to the limit
  when the pressure is ten times the target, and the wall is raised to
  where it was: the run needed more than that;
- with the run at its limit already (95%, `at_limit`) or its files
  unreadable, memory.high is the limit.

**Safety.** With `memory.swap.max` 0 a run's anonymous memory can't be
reclaimed, so a memory.high under it stalls the run (#279). The floor, the
wall and the quick raise bound that to about an interval; memory.max is
never changed; and a run whose memory.high is lowered is under 95% of its
limit, so the held check (`HeldWatch`, which looks at the limit) never kills
a run for the probe. A scheduler that starts, or starts again after a tick
failed, gives each run cgroup it finds back its limit (`restore_high`), so
a probe that stops never leaves a run lowered.

**The working set** (`Probe.working_set_mb`) is the lowest memory.high the
run held at the target, raised to what it was seen to need: a step over the
wall, or its limit where the pressure passed the target at the limit. A
phase that needs more than an earlier one meets the wall and raises it; a
phase that needed more before the probe came down to it isn't seen, and a
grant learned from it may be too small for that run: it's then held or
killed and retried bigger (#279, #226), as any run is. It's recorded on the attempts (`orca.attempts.working_set_mb`) at the reap
once the run was measured over `MIN_SAMPLES` intervals, beside the peak, and
`morca._internal.recommend` learns from it. memory.current, which it reads,
counts page cache as memory.high does; without swap the probe can save only
what is reclaimable: page cache, and mapped files.
"""

from std.os import getenv
from std.time import perf_counter_ns

from morca._internal.cgroup import (
    Cgroups,
    Contained,
    at_limit,
    max_mb,
    put,
    stall_total_us,
)
from morca._internal.sample import _read

comptime MIN_SAMPLES = 3
"""Intervals at a lowered memory.high a run needs for a working set."""
comptime BACKOFF_STEPS = 4
"""How many steps memory.high goes up when the pressure passes the
target."""
comptime PANIC_TIMES: Float64 = 10.0
"""Pressure this many times the target gives the run its limit back."""
comptime MB = 1024 * 1024


@fieldwise_init
struct ProbeKnobs(ImplicitlyCopyable, Movable):
    """The probe's settings, the scheduler's environment's."""

    var every_s: Float64
    """`MORCA_RUN_PROBE_SECONDS` (5): the interval."""
    var target_pct: Float64
    """`MORCA_RUN_PROBE_TARGET` (0.1): the share of the interval, in
    percent, some tasks may wait on memory."""
    var step_pct: Int
    """`MORCA_RUN_PROBE_STEP` (2): a step, in percent of the limit."""
    var floor_pct: Int
    """`MORCA_RUN_PROBE_FLOOR` (50): the lowest memory.high, in percent of
    the limit."""

    @staticmethod
    def defaults() -> ProbeKnobs:
        return ProbeKnobs(5.0, 0.1, 2, 50)

    @staticmethod
    def from_env() raises -> ProbeKnobs:
        var d = ProbeKnobs.defaults()
        return ProbeKnobs(
            _env_float("MORCA_RUN_PROBE_SECONDS", d.every_s, 0.1, 3600.0),
            _env_float("MORCA_RUN_PROBE_TARGET", d.target_pct, 0.001, 50.0),
            Int(_env_float("MORCA_RUN_PROBE_STEP", 2.0, 1.0, 50.0)),
            Int(_env_float("MORCA_RUN_PROBE_FLOOR", 50.0, 10.0, 100.0)),
        )


def _env_float(
    name: StaticString, default: Float64, least: Float64, most: Float64
) raises -> Float64:
    var s = getenv(name)
    if not s:
        return default
    try:
        var f = Float64(s)
        if f >= least and f <= most:
            return f
    except:
        pass
    raise Error(
        "morca: ",
        name,
        " must be a number from ",
        least,
        " to ",
        most,
        ", not ",
        s,
    )


def probed(run: Int, start: Int, every: Int) -> Bool:
    """Whether start `start` of run `run` of a pipeline that probes one run
    in `every` (0: none) is probed: only a first start, and of those about
    one in `every`, by a hash of the run's number (pipelines started in
    turn would otherwise each get the same remainder)."""
    if every <= 0 or start != 1:
        return False
    if every == 1:
        return True
    # splitmix64's finalizer.
    var z = UInt64(run) + 0x9E3779B97F4A7C15
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    z = z ^ (z >> 31)
    return Int(z % UInt64(every)) == 0


@fieldwise_init
struct Probe(ImplicitlyCopyable, Movable):
    """One run's probe: its limit, the memory.high it has now, and what it
    has learned. Values only: `next` is the controller."""

    var limit_mb: Int
    """Its cgroup's limit (`Contained.limit_mb`), where memory.high starts
    and the most it's ever set to."""
    var high_mb: Int
    var wall_mb: Int
    """The highest memory.high the pressure passed the target at; 0 for
    none."""
    var lowest_mb: Int
    """The lowest memory.high under the limit the run held at the target;
    0 for none."""
    var need_mb: Int
    """The most the run was seen to need: a step over the wall, or its
    limit if the pressure passed the target there; 0 for nothing."""
    var samples: Int
    """Intervals measured: at a lowered memory.high, or with the pressure
    over the target at the limit."""

    @staticmethod
    def of(limit_mb: Int) -> Probe:
        return Probe(limit_mb, limit_mb, 0, 0, 0, 0)

    @staticmethod
    def at(limit_mb: Int, high_mb: Int) -> Probe:
        """At `high_mb` already, having learned nothing: for the tests."""
        return Probe(limit_mb, high_mb, 0, 0, 0, 0)

    def step_mb(self, k: ProbeKnobs) -> Int:
        return max(1, self.limit_mb * k.step_pct // 100)

    def next(
        self, usage_mb: Int, pressure_pct: Float64, k: ProbeKnobs
    ) -> Probe:
        """The probe after an interval at `high_mb` in which the run's
        memory came to `usage_mb` and some of its tasks waited on memory
        `pressure_pct` percent of the time (-1 for either: unreadable)."""
        var p = self
        if usage_mb < 0 or pressure_pct < 0:
            p.high_mb = p.limit_mb
            return p
        var step = p.step_mb(k)
        if pressure_pct > k.target_pct:
            # It needed more than it had.
            p.samples += 1
            if p.high_mb < p.limit_mb:
                p.wall_mb = max(p.wall_mb, p.high_mb)
                p.need_mb = max(p.need_mb, min(p.limit_mb, p.high_mb + step))
            else:
                p.need_mb = p.limit_mb
            if pressure_pct >= k.target_pct * PANIC_TIMES:
                p.high_mb = p.limit_mb
            else:
                p.high_mb = min(p.limit_mb, p.high_mb + BACKOFF_STEPS * step)
            return p
        if p.high_mb < p.limit_mb:
            p.samples += 1
            if p.lowest_mb == 0 or p.high_mb < p.lowest_mb:
                p.lowest_mb = p.high_mb
        if at_limit(usage_mb * MB, p.limit_mb):
            # Using all its grant: lower would only throttle it.
            p.high_mb = p.limit_mb
            return p
        var floor = max(p.limit_mb * k.floor_pct // 100, usage_mb - step)
        if p.wall_mb > 0:
            floor = max(floor, p.wall_mb + step)
        p.high_mb = min(p.limit_mb, max(p.high_mb - step, floor))
        return p

    def working_set_mb(self) -> Int:
        """What it learned: the lowest memory.high the run held at the
        target, at least what it was seen to need; -1 for nothing."""
        var mb = max(self.lowest_mb, self.need_mb)
        return mb if mb > 0 else -1

    def result_mb(self) -> Int:
        """The run's working set, or -1 if it wasn't measured over
        `MIN_SAMPLES` intervals."""
        return self.working_set_mb() if self.samples >= MIN_SAMPLES else -1


def pressure_pct(stall_us: Int, elapsed_ns: Int) -> Float64:
    """The share of `elapsed_ns`, in percent, that `stall_us` microseconds of
    waiting are; -1 for an unreadable stall (< 0) or no time."""
    if stall_us < 0 or elapsed_ns <= 0:
        return -1.0
    return Float64(stall_us) * 1000.0 * 100.0 / Float64(elapsed_ns)


def limit_of_max(kill_mb: Int, margin_pct: Int) -> Int:
    """The limit whose `memory.max` (`max_mb`) is `kill_mb`: the largest
    with a `max_mb` at most it."""
    var l = kill_mb * 100 // (100 + margin_pct)
    while max_mb(l + 1, margin_pct) <= kill_mb:
        l += 1
    while l > 0 and max_mb(l, margin_pct) > kill_mb:
        l -= 1
    return l


def restore_high(path: String, margin_pct: Int) -> Bool:
    """Gives a run's cgroup the limit its memory.max says it has (the margin
    `margin_pct` under it), if its memory.high is lower: a probe stopped
    with it lowered. Never lowers it; whether it wrote."""
    try:
        var kill = Int(String(_read(String(path, "/memory.max")).strip()))
        var high = Int(String(_read(String(path, "/memory.high")).strip()))
        var limit = limit_of_max(kill // MB, margin_pct)
        if limit > 0 and high < limit * MB:
            return put(String(path, "/memory.high"), String(limit * MB))
    except:
        pass
    return False


@fieldwise_init
struct _Probing(Copyable, Movable):
    var path: String
    var probe: Probe
    var stall_us: Int
    """`some total` at the interval's start."""
    var at_ns: Int
    """When the interval started, on the monotonic clock."""


struct ProbeWatch(Copyable, Movable):
    """The scheduler's probed runs, by process."""

    var knobs: ProbeKnobs
    var runs: Dict[Int, _Probing]

    def __init__(out self, knobs: ProbeKnobs = ProbeKnobs.defaults()):
        self.knobs = knobs
        self.runs = Dict[Int, _Probing]()

    def watch(mut self, pid: Int, c: Contained):
        """Probes `pid`'s run, whose cgroup is `c`, from now."""
        if not c.path or c.limit_mb <= 0:
            return
        var total = stall_total_us(
            _read(String(c.path, "/memory.pressure")), "some"
        )
        if total < 0:
            print("morca: run", c.run, "isn't probed: no memory.pressure")
            return
        self.runs[pid] = _Probing(
            c.path, Probe.of(c.limit_mb), total, Int(perf_counter_ns())
        )
        print(
            "morca: probing run",
            c.run,
            "of",
            c.pipeline,
            "for its working set under",
            c.limit_mb,
            "MB",
        )

    def step(mut self, contained: Dict[Int, Contained]):
        """Each tick: for each probed run whose interval has passed, the
        controller's next memory.high, written. A run that's no longer
        contained is forgotten; one whose memory.high can't be written is
        given its limit back and probed no more."""
        var gone = List[Int]()
        var due = List[Int]()
        var t = Int(perf_counter_ns())
        var every = Int(self.knobs.every_s * 1e9)
        for e in self.runs.items():
            if e.key not in contained:
                gone.append(e.key)
            elif t - e.value.at_ns >= every:
                due.append(e.key)
        for pid in due:
            try:
                ref r = self.runs[pid]
                var total = stall_total_us(
                    _read(String(r.path, "/memory.pressure")), "some"
                )
                var cur = Cgroups.current(r.path)
                var pct = pressure_pct(
                    total - r.stall_us if total >= 0 else -1, t - r.at_ns
                )
                var was = r.probe.high_mb
                r.probe = r.probe.next(
                    cur // MB if cur >= 0 else -1, pct, self.knobs
                )
                r.stall_us = total
                r.at_ns = t
                if r.probe.high_mb != was and not put(
                    String(r.path, "/memory.high"),
                    String(r.probe.high_mb * MB),
                ):
                    _ = put(
                        String(r.path, "/memory.high"),
                        String(r.probe.limit_mb * MB),
                    )
                    gone.append(pid)
            except:
                pass
        for pid in gone:
            _ = self.runs.pop(pid, _Probing("", Probe.of(0), 0, 0))

    def take(mut self, pid: Int) -> Int:
        """At `pid`'s reap: its run's working set in MB, or -1 if it wasn't
        probed or measured long enough; forgotten."""
        if pid not in self.runs:
            return -1
        try:
            return self.runs.pop(pid).probe.result_mb()
        except:
            return -1
