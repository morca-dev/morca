"""Fills (#155): a pipeline filling its whole partition range by itself,
within limits, set in morca.toml (`morca._internal.config`):

    [pipelines.gharchive]
    fills = "all"                # "since_registration", the default
    fill_order = "oldest"        # or "newest"
    fill_max_runs = 2            # fill runs at once, beside its other runs
    fill_budget_per_day = 5.0    # estimated US dollars a UTC day
    fill_window = "22..6"        # UTC hours fill runs may start in
    fill_lag = "2h"              # how long after its end a partition fills

With `fills = "all"` the scheduler queues, on each tick, runs (trigger
`fill`) for the partitions of the pipeline's range that nothing has filled:
from its first partition through the last one that has ended at least
`fill_lag` ago, in `fill_order`, as long as every limit allows
(`fill_status`).

**`fill_lag`** (`0`, the default, for none) is for sources that publish a
partition's data some time after it ends: GH Archive puts each hour's file
up minutes after the hour, so at 00:00 UTC the day that just ended isn't
all there yet. A Daily day D fills from D+1 00:00 plus the lag (on the
schedule's clock), a Monthly month from the 1st of the next plus the lag.
Until then the partition is outside the range, for the fill and for the
coverage alike (`range_keys`), so it isn't counted as missing; the
pipeline page's Fill line says when it fills (`FillStatus.lag_key`). The default,
`since_registration`, is what morca did before: a schedule fills from the
pipeline's registration on, and `morca backfill` the rest by hand.

**What a fill takes.** A partition is left alone when it's done in a run of
any code of the pipeline (every mapped step succeeded for it; with no
mapped step, a run over it succeeded), when a live run has it, or when a
fill run of it was ever queued, so a fill never runs a partition twice:
one whose fill run failed past its retries, or was cancelled, is left to a
person (`morca backfill`, or resume in the UI). Running done partitions
again stays `morca backfill --rerun`. All of that is within the pipeline's
current data version, its steps' `version=` (#297): raising one makes every
partition fillable again, and the fill regenerates them within its limits.

**Limits**, each a reason the pipeline page gives for a fill being idle:
the pipeline paused (by a person or by the watchdog, `morca._internal.watchdog`), the
hour outside `fill_window`, the day's budget, the pipeline's other queued
runs (a scheduled or backfilled run starts first, so fills never starve
them), and `fill_max_runs`. Fill runs don't count against `max_runs`.

**On a worker pool** (`placement = "worker:<pool>"`) the scheduler queues
the fill runs the same way, in the same order and within the same limits,
and leaves them queued, held for a worker of the pool to claim
(`orca.workers`). `fill_max_runs` caps the pipeline's live fill runs
across the whole pool, queued ones included, so the fill never has more
than that many going whatever the number of workers; each worker's
`--max-runs` and its grants cap what one machine takes. A worker pool's
runs cost nothing more than its machines, which run anyway.

**The cost estimate** is conservative, and fails closed. A fill run's
cost is its instances' time (`orca.instances`) at `morca._internal.fleet`'s on-demand
price table, times `COST_MARGIN` for what the table leaves out (EBS,
transfer, requests). The day's spend is that over the fill runs' instances
since 00:00 UTC, up to now. Before starting a run, morca also counts what
the fill runs going and the new one may still cost: the pipeline's
hourly price (head plus its most workers) for the longest fill run of its
last `_HISTORY` (an hour if it has none, at least a minute, plus the warm
pool's idle time on EC2), less what each has run already. A run starts only
if the spend plus that stays within `fill_budget_per_day`. When a price
isn't known (an instance type not in the table, or Kubernetes, whose
cluster morca can't price), no fill run starts on a budget, and the reason
says so. A pipeline whose runs cost money (placed on EC2 or Kubernetes)
starts no fill run without a budget. Runs on the control host or local
processes cost nothing more than the machine already running.

Keyed pipelines and sensors don't fill: `morca register` refuses
`fills = "all"` for them (`fill_refusal`).
"""

from std.os import getenv

from postgres import Transaction

import morca._internal.db.fill as fill_db
from morca._internal.fill_requests import (
    RequestProgress,
    request_json,
    request_progress,
)

from morca.civil import Civil
from morca._internal.fleet import hourly_price
from morca._internal.json import quote
from morca._internal.db.live import (
    dead_sql,
    live_runs,
    stale_limit,
    start_grace,
)
from morca._internal.timekeys import (
    is_time_kind,
    parse_time_keys,
    containing_key,
    prev_key,
)
from morca.tz import Zone

comptime ALL = "all"
comptime SINCE_REGISTRATION = "since_registration"
"""The default of `fills`: a schedule fills from registration on."""
comptime FILL_TRIGGER = "fill"
"""`orca.runs.trigger` of a fill's runs."""
comptime COST_MARGIN = 1.2
"""What the estimate adds to the price table's prices: EBS volumes, data
transfer and requests aren't in it."""
comptime NO_HISTORY_SECONDS = 3600
"""How long a fill run is expected to take before one has ended."""
comptime MIN_SECONDS = 60
"""EC2 bills an instance for a minute at least."""
comptime _HISTORY = 20
"""The ended fill runs whose longest is the next one's expected time."""
comptime _RATE_HOURS = 6
"""The fill rate is over the fill runs that ended in this many hours."""


def parse_fills(v: String) raises -> String:
    if v == ALL or v == SINCE_REGISTRATION:
        return v
    raise Error('is "all" or "since_registration", not ', v)


def parse_fill_order(v: String) raises -> String:
    if v == "oldest" or v == "newest":
        return v
    raise Error('is "oldest" or "newest", not ', v)


comptime AUTO_FILL_MAX_RUNS = 64
"""`fill_max_runs = "auto"`'s ceiling when it names none."""


def fill_max_runs_auto(v: String) -> Bool:
    """Whether `fill_max_runs`' value is `auto` or `auto..N` (#322): as
    many fill runs at once as the host has room for, up to the ceiling."""
    return v == "auto" or v.startswith("auto..")


def parse_fill_max_runs(v: String) raises -> Int:
    """`fill_max_runs`' count, or for `auto` and `auto..N` its ceiling (64,
    or N): `fill_max_runs_auto` says which."""
    var t = v
    if v == "auto":
        return AUTO_FILL_MAX_RUNS
    if v.startswith("auto.."):
        t = String(v[byte = String("auto..").byte_length() :])
    try:
        var n = Int(t)
        if n >= 1 and n <= 10000:
            return n
    except:
        pass
    raise Error('is a count from 1 to 10000, "auto" or "auto..N", not ', v)


def fill_max_runs_text(n: Int, auto: Bool) -> String:
    """`fill_max_runs` as morca.toml writes it."""
    if not auto:
        return String(n)
    if n == AUTO_FILL_MAX_RUNS:
        return String("auto")
    return String("auto..", n)


def parse_fill_budget(v: String) raises -> Float64:
    """US dollars a day, from 0 to 100000."""
    var x: Float64
    try:
        x = Float64(v)
    except:
        raise Error("is US dollars a day, a number, not ", v)
    if not (x >= 0.0 and x <= 100000.0):
        raise Error("is US dollars a day from 0 to 100000, not ", v)
    return x


def parse_fill_window(v: String) raises -> Tuple[Int, Int]:
    """`A..B`: fill runs start from hour A up to (not at) hour B, UTC; A
    after B wraps past midnight (`22..6`); `0..24` is all day."""
    var dots = v.find("..")
    if dots > 0:
        try:
            var a = Int(v[byte=:dots])
            var b = Int(v[byte = dots + 2 :])
            if a >= 0 and a <= 23 and b >= 1 and b <= 24 and a != b:
                return (a, b)
        except:
            pass
    raise Error(
        'is UTC hours "A..B", A from 0 to 23 and B from 1 to 24, not ', v
    )


comptime MAX_LAG_SECONDS = 31 * 86400
"""The longest `fill_lag`: a month and a day."""


def parse_fill_lag(v: String) raises -> Int:
    """A duration in seconds: `0`, or a whole number of seconds, minutes,
    hours or days (`90s`, `90m`, `2h`, `1d`), up to `MAX_LAG_SECONDS`."""
    var t = String(v.strip())
    if t == "0":
        return 0
    var n = -1
    var scale = 0
    if t.byte_length() >= 2:
        var unit = String(t[byte = t.byte_length() - 1 :])
        if unit == "s":
            scale = 1
        elif unit == "m":
            scale = 60
        elif unit == "h":
            scale = 3600
        elif unit == "d":
            scale = 86400
        var digits = t[byte = : t.byte_length() - 1]
        for c in digits.codepoint_slices():
            if c < "0" or c > "9":
                scale = 0
        if scale > 0 and digits.byte_length() <= 9:
            try:
                n = Int(digits)
            except:
                n = -1
    if n < 0 or scale == 0:
        raise Error('is a duration like "2h", "90m" or "0", not ', v)
    if n * scale > MAX_LAG_SECONDS:
        raise Error("is at most 31d, not ", v)
    return n * scale


def lag_text(seconds: Int) -> String:
    """`seconds` as `fill_lag` keeps it: `0`, `2h`, `90m` or `45s`."""
    if seconds == 0:
        return "0"
    if seconds % 3600 == 0:
        return String(seconds // 3600, "h")
    if seconds % 60 == 0:
        return String(seconds // 60, "m")
    return String(seconds, "s")


def money(x: Float64) -> String:
    """`x` dollars as `$1.23`."""
    var cents = Int(max(x, 0.0) * 100.0 + 0.5)
    var c = cents % 100
    return String("$", cents // 100, ".", "0" if c < 10 else "", c)


def _hh(h: Int) -> String:
    return String("0" if h < 10 else "", h, ":00")


@fieldwise_init
struct Fill(Copyable, Movable):
    """A pipeline's fill settings, as registered."""

    var all: Bool
    """`fills = "all"`."""
    var newest_first: Bool
    var max_runs: Int
    var budget: Float64
    """US dollars a UTC day; -1 for none."""
    var window_from: Int
    var window_to: Int
    var lag: Int
    """`fill_lag` in seconds: how long after its end a partition fills."""
    var max_runs_auto: Bool
    """`fill_max_runs = "auto"`: `max_runs` is the ceiling, and the host's
    room decides how many (#322)."""

    @staticmethod
    def of(
        fills: String,
        order: String,
        max_runs: Int,
        budget: Float64,
        window: String,
        lag: String = "",
        max_runs_auto: Bool = False,
    ) raises -> Fill:
        """From the registration's columns: empty or negative for what
        wasn't set."""
        var w = parse_fill_window(window) if window else (0, 24)
        return Fill(
            fills == ALL,
            order == "newest",
            max_runs if max_runs > 0 else 1,
            budget,
            w[0],
            w[1],
            parse_fill_lag(lag) if lag else 0,
            max_runs_auto,
        )

    def in_window(self, hour: Int) -> Bool:
        if self.window_from < self.window_to:
            return hour >= self.window_from and hour < self.window_to
        return hour >= self.window_from or hour < self.window_to

    def window_text(self) -> String:
        if self.window_from == 0 and self.window_to == 24:
            return "all day"
        return String(
            _hh(self.window_from), "–", _hh(self.window_to % 24), " UTC"
        )


def fill_refusal(
    kind: String, start: String, sensor: Bool, pipeline: String
) -> String:
    """Why `fills = "all"` can't be registered for a pipeline, or empty."""
    if kind == "keyed":
        return String(
            pipeline,
            " is keyed: its keys come from its keys dataset, which its",
            " sensor or `morca backfill ",
            pipeline,
            " @all` runs; fills are for Hourly, Daily and Monthly partitions",
        )
    if sensor:
        return String(
            pipeline,
            " is a sensor: its runs follow its datasets' snapshots, so",
            " filling its range by itself would run partitions whose input",
            " may not be there; backfill it by hand",
        )
    if not is_time_kind(kind):
        return String(pipeline, " has no Hourly, Daily or Monthly partitions")
    if not start:
        return String(pipeline, " has no first partition to fill from")
    return ""


def _last_ended(kind: String, zone: Zone, now: Int64) raises -> String:
    var local = Civil.of(zone.to_local(now))
    return prev_key(
        kind,
        containing_key(kind, local.year, local.month, local.day, local.hour),
    )


def last_ended(
    kind: String, tz: String, now: Int64, lag: Int = 0
) raises -> String:
    """The latest partition that had ended `lag` seconds before `now` on
    the schedule's wall clock (UTC without one): the end of a fill's range.
    The partition still going is the schedule's; one that ended less than
    `lag` (`fill_lag`) ago waits."""
    return _last_ended(kind, Zone.load(tz if tz else "UTC"), now - Int64(lag))


def lag_wait(
    kind: String, tz: String, now: Int64, lag: Int
) raises -> Tuple[String, Int64]:
    """The partition that has ended by `now` but less than `lag` seconds
    ago, the oldest if several, and when it becomes fillable (its end plus
    `lag`, UTC seconds); `("", 0)` if none waits."""
    if lag <= 0 or not is_time_kind(kind):
        return (String(), Int64(0))
    var zone = Zone.load(tz if tz else "UTC")
    var fillable = _last_ended(kind, zone, now - Int64(lag))
    if _last_ended(kind, zone, now) == fillable:
        return (String(), Int64(0))
    # The next one ended in (now - lag, now]: the first second it had.
    var lo = now - Int64(lag)
    var hi = now
    while hi - lo > 1:
        var mid = lo + (hi - lo) // 2
        if _last_ended(kind, zone, mid) == fillable:
            lo = mid
        else:
            hi = mid
    return (_last_ended(kind, zone, hi), hi + Int64(lag))


def range_keys(
    kind: String, start: String, tz: String, now: Int64, lag: Int = 0
) raises -> List[String]:
    """Every partition from `start` through `last_ended`, oldest first."""
    var out = List[String]()
    if not start:
        return out^
    var last = last_ended(kind, tz, now, lag)
    if last < start:  # keys of one kind order as text
        return out^
    if not is_time_kind(kind):
        return out^
    return parse_time_keys(kind, String(start, "..", last))


def run_hourly(
    placed: String, head_type: String, worker_type: String, workers: Int
) -> Float64:
    """US dollars an hour of one of the pipeline's runs where it's `placed`:
    0 on the control host, as a local process or on a worker pool's
    machines (which run anyway), the head and its most
    workers at on-demand prices on EC2 (a type left empty is the runner's,
    `MORCA_EC2_HEAD_TYPE` / `MORCA_EC2_WORKER_TYPE`), and -1 for a price that
    isn't known (a type not in `morca._internal.fleet`'s table, or Kubernetes).
    """
    if placed == "control" or placed == "local" or placed.startswith("worker:"):
        return 0.0
    if placed != "ec2":
        return -1.0
    var head = head_type if head_type else getenv(
        "MORCA_EC2_HEAD_TYPE", "c7g.large"
    )
    var price = hourly_price(head)
    if price < 0:
        return -1.0
    if workers > 0:
        var worker = worker_type if worker_type else getenv(
            "MORCA_EC2_WORKER_TYPE", "c7g.xlarge"
        )
        var w = hourly_price(worker)
        if w < 0:
            return -1.0
        price += Float64(workers) * w
    return price


def unknown_type(
    placed: String, head_type: String, worker_type: String, workers: Int
) -> String:
    """The instance type `run_hourly` couldn't price, or empty."""
    if placed != "ec2":
        return ""
    var head = head_type if head_type else getenv(
        "MORCA_EC2_HEAD_TYPE", "c7g.large"
    )
    if hourly_price(head) < 0:
        return head
    var worker = worker_type if worker_type else getenv(
        "MORCA_EC2_WORKER_TYPE", "c7g.xlarge"
    )
    if workers > 0 and hourly_price(worker) < 0:
        return worker
    return ""


@fieldwise_init
struct FillPipeline(Copyable, Movable):
    """What `fill_status` needs of a registered pipeline."""

    var name: String
    var fill: Fill
    var kind: String
    var start: String
    var tz: String
    var paused: Bool
    var placed: String
    """Where its runs would start: `control`, `ec2`, `kubernetes`, `local`
    or `worker:<pool>`."""
    var head_type: String
    var worker_type: String
    var workers: Int
    var pool_seconds: Int
    """On EC2, how long an instance idles in the warm pool after a run."""
    var keys_per_run: Int
    """How many partitions a fill run takes (#240): 1 by default."""


struct FillStatus(Copyable, Movable):
    """Where a pipeline's fill is, and how many fill runs may start now."""

    var on: Bool
    var total: Int
    var done: Int
    var live: Int
    """Partitions of the range in a live run (of any trigger)."""
    var failed: Int
    """Partitions whose fill run was cancelled or failed past its retries,
    not done since: left to a person."""
    var retrying: Int
    """Partitions whose fill run failed and waits for a retry."""
    var left: Int
    """Partitions no run has taken yet."""
    var running: Int
    """Fill runs running now."""
    var queued: Int
    """Fill runs queued and not yet started: on a worker pool, those
    waiting for a worker to claim them. They count against
    `fill_max_runs` as the running ones do."""
    var rate: Float64
    """Partitions an hour the fill runs did lately; 0 for none."""
    var eta_seconds: Int
    """`left` at `rate`; -1 when there's no rate."""
    var spent: Float64
    """Today's (UTC) estimated spend of the fill runs; -1 if unknown."""
    var budget: Float64
    var hourly: Float64
    """A run's US dollars an hour; -1 if unknown."""
    var expected_seconds: Int
    """How long the next fill run is expected to take."""
    var next_cost: Float64
    """What the runs going and one more may still cost."""
    var idle: String
    """Why no more fill runs start, or empty."""
    var slots: Int
    """Fill runs that may start now, before the pipeline's own limits."""
    var next_keys: List[String]
    """The partitions of each of the next fill runs, comma-separated, in
    `fill_order`, up to `keys_per_run` to a run; at most `slots` runs."""
    var lag_key: String
    """The partition that has ended but waits for `fill_lag`, or empty."""
    var lag_until: Int64
    """When `lag_key` becomes fillable, UTC seconds; 0 for none."""
    var lag: Int
    """`fill_lag`, seconds."""
    var request: Optional[RequestProgress]
    """Its open fill request (`morca backfill --as-fill`, #465), if any."""
    var next_request: List[Int64]
    """For each of `next_keys`, the request it's of, or 0 for the fill's
    range."""

    def __init__(out self):
        self.on = False
        self.total = 0
        self.done = 0
        self.live = 0
        self.failed = 0
        self.retrying = 0
        self.left = 0
        self.running = 0
        self.queued = 0
        self.rate = 0.0
        self.eta_seconds = -1
        self.spent = 0.0
        self.budget = -1.0
        self.hourly = 0.0
        self.expected_seconds = 0
        self.next_cost = 0.0
        self.idle = String()
        self.slots = 0
        self.next_keys = List[String]()
        self.lag_key = String()
        self.lag_until = 0
        self.lag = 0
        self.request = None
        self.next_request = List[Int64]()


def fill_status(
    mut tx: Transaction, p: FillPipeline, now: Int64, run_retries: Int
) raises -> FillStatus:
    """`p`'s fill now: its progress, today's spend, whether fill runs may
    start and which partitions they'd take. Read in `tx`, which the
    scheduler holds with the pipeline's row locked."""
    var s = FillStatus()
    s.on = p.fill.all
    s.budget = p.fill.budget
    s.lag = p.fill.lag
    var keys = range_keys(p.kind, p.start, p.tz, now, p.fill.lag)
    s.total = len(keys)
    if p.start:
        var w = lag_wait(p.kind, p.tz, now, p.fill.lag)
        if w[0] >= p.start:
            s.lag_key = w[0]
            s.lag_until = w[1]
    var done = Dict[String, Bool]()
    for k in fill_db.done_any_code(tx, p.name):
        done[k] = True
    var live = live_runs(tx, p.name)
    # Each key's latest fill run: whether it gave up, or fails and waits
    # for a retry.
    var filled = Dict[String, Bool]()
    var given_up = Dict[String, Bool]()
    var retrying = Dict[String, Bool]()
    for r in fill_db.latest_fills(tx, p.name, run_retries):
        filled[r.key] = True
        if r.gone:
            given_up[r.key] = True
        elif r.again:
            retrying[r.key] = True
    s.request = request_progress(tx, p.name, run_retries, live, done)
    var todo = List[String]()
    for k in keys:
        if k in done:
            s.done += 1
        elif k in live:
            s.live += 1
        elif k in given_up:
            s.failed += 1
        elif k in retrying:
            s.retrying += 1
        elif k not in filled:
            todo.append(k)
    s.left = len(todo)
    if not s.on:
        todo.clear()  # only a request's keys
    if p.fill.newest_first:
        todo.reverse()
    # A request's keys go before the range's, each list in `fill_order`.
    var asked = List[String]()
    if s.request:
        asked = s.request.value().todo.copy()
        if p.fill.newest_first:
            asked.reverse()

    var stale = stale_limit()
    var dead = dead_sql(String("$2"), start_grace(stale))
    var elapsed = fill_db.running_fills(tx, p.name, stale, dead)
    s.running = len(elapsed)
    s.queued = fill_db.queued_fills(tx, p.name)

    # The rate: partitions of fill runs that succeeded lately, over the
    # time since the first of them started.
    var rate = fill_db.recent_fills(tx, p.name, _RATE_HOURS)
    var n = rate[0]
    if n > 0:
        var hours = max(rate[1], 600.0) / 3600.0
        s.rate = Float64(n) / hours
        s.eta_seconds = Int(Float64(s.left + s.live) / s.rate * 3600.0)

    # Spend: the fill runs' instances since 00:00 UTC.
    var day = now - now % 86400
    var unpriced = String()
    for r in fill_db.fill_instances(tx, p.name, now, day):
        var price = hourly_price(r.instance_type)
        if price < 0:
            unpriced = r.instance_type
            continue
        s.spent += COST_MARGIN * price * max(r.seconds, 0.0) / 3600.0
    if unpriced:
        s.spent = -1.0

    # What the runs going and one more may cost.
    s.hourly = run_hourly(p.placed, p.head_type, p.worker_type, p.workers)
    var longest = 0
    for secs in fill_db.fill_durations(tx, p.name, _HISTORY):
        longest = max(longest, secs)
    var expected = longest if longest > 0 else NO_HISTORY_SECONDS
    expected = max(expected, MIN_SECONDS)
    if p.placed == "ec2":
        expected += p.pool_seconds
    s.expected_seconds = expected
    if s.hourly >= 0:
        var secs = expected
        for e in elapsed:
            secs += max(expected - e, 0)
        s.next_cost = COST_MARGIN * s.hourly * Float64(secs) / 3600.0

    # Why no more may start, first reason first.
    var others = fill_db.queued_others(tx, p.name)
    var hour = Int((now % 86400) // 3600)
    var paid = p.placed == "ec2" or p.placed == "kubernetes"
    var req_going = 0
    if s.request:
        ref r = s.request.value()
        req_going = r.running + r.retrying + r.waiting
    if not s.on and not s.request:
        s.idle = String("off: fills is ", SINCE_REGISTRATION)
    elif not s.on and len(asked) == 0:
        s.idle = String(
            "the fill request's last runs are going" if req_going
            > 0 else "the fill request is complete"
        )
    elif len(todo) == 0 and len(asked) == 0 and s.retrying == 0:
        s.idle = String(
            "complete" if s.live == 0
            and req_going == 0 else "the last partitions are running"
        )
        if s.failed > 0:
            s.idle.write(
                "; ",
                s.failed,
                " failed for good, left for morca backfill or a resume",
            )
    elif p.paused:
        var by = fill_db.last_pause(tx, p.name)
        if by and by.value()[0] == "watchdog":
            s.idle = String("paused by the watchdog (", by.value()[1], ")")
        else:
            s.idle = "paused"
    elif not p.fill.in_window(hour):
        s.idle = String(
            "outside its window: fill runs start ", p.fill.window_text()
        )
    elif paid and s.budget < 0:
        s.idle = String(
            "no budget: its runs on ",
            p.placed,
            " cost money, and fill_budget_per_day isn't set",
        )
    elif s.budget >= 0 and s.hourly < 0:
        var t = unknown_type(p.placed, p.head_type, p.worker_type, p.workers)
        s.idle = String(
            "price unknown: ",
            String("no price for ", t, " in morca.fleet's table") if t else (
                String("morca can't price runs on ", p.placed)
            ),
            ", so it can't keep to a budget",
        )
    elif s.budget >= 0 and s.spent < 0:
        s.idle = String(
            "price unknown: today's fill runs ran on ",
            unpriced,
            ", which morca.fleet's table has no price for",
        )
    elif s.budget >= 0 and s.spent + s.next_cost > s.budget:
        s.idle = String(
            "budget: ",
            money(s.spent),
            " of ",
            money(s.budget),
            " spent today (UTC)",
        )
        if s.next_cost > 0:
            s.idle.write(
                ", and the runs going and one more may cost ",
                money(s.next_cost),
            )
    elif others > 0:
        s.idle = String(
            "waiting: ",
            others,
            " scheduled or backfill runs are queued, and start first",
        )
    elif s.running + s.queued >= p.fill.max_runs:
        s.idle = String(
            "at fill_max_runs: ",
            s.running + s.queued,
            " of ",
            p.fill.max_runs,
            " going",
        )
        if s.queued > 0:
            s.idle.write(
                " (",
                s.queued,
                " waiting for a worker)" if p.placed.startswith(
                    "worker:"
                ) else " queued)",
            )
    if not s.idle:
        s.slots = p.fill.max_runs - s.running - s.queued
        # On a budget, as many as it holds.
        if s.budget >= 0 and s.hourly > 0:
            var one = COST_MARGIN * s.hourly * Float64(expected) / 3600.0
            var room = s.budget - s.spent - s.next_cost
            s.slots = min(s.slots, 1 + Int(room / one))
    var k = max(p.keys_per_run, 1)
    if len(asked) > 0:
        s.request.value().next = _batch(asked, 0, k, p.fill.newest_first)
    if not s.idle:
        var id = s.request.value().id if s.request else Int64(0)
        var i = 0
        while len(s.next_keys) < s.slots and i < len(asked):
            s.next_keys.append(_batch(asked, i, k, p.fill.newest_first))
            s.next_request.append(id)
            i += k
        i = 0
        while len(s.next_keys) < s.slots and i < len(todo):
            s.next_keys.append(_batch(todo, i, k, p.fill.newest_first))
            s.next_request.append(0)
            i += k
    return s^


def _batch(keys: List[String], i: Int, k: Int, reversed: Bool) -> String:
    """`keys[i:i+k]` as one run's keys, comma-separated: ascending, since
    keys of one kind order as text, so reversed when `keys` is newest
    first."""
    var batch = List[String]()
    var j = i
    while j < len(keys) and len(batch) < k:
        batch.append(keys[j])
        j += 1
    if reversed:
        batch.reverse()
    var joined = String()
    for n in range(len(batch)):
        joined.write("," if n else "", batch[n])
    return joined^


def lag_note(s: FillStatus) -> String:
    """`2026-11-08 fills from 2026-11-09 02:00 UTC (fill_lag 2h)`, or empty
    when no partition waits for `fill_lag`."""
    if not s.lag_key:
        return String()
    var c = Civil.of(s.lag_until)
    return String(
        s.lag_key,
        " fills from ",
        c.year,
        "-",
        "0" if c.month < 10 else "",
        c.month,
        "-",
        "0" if c.day < 10 else "",
        c.day,
        " ",
        "0" if c.hour < 10 else "",
        c.hour,
        ":",
        "0" if c.minute < 10 else "",
        c.minute,
        " UTC (fill_lag ",
        lag_text(s.lag),
        ")",
    )


def eta_text(seconds: Int) -> String:
    if seconds < 0:
        return "unknown"
    if seconds < 3600:
        return String(max(seconds // 60, 1), "m")
    if seconds < 172800:
        return String(seconds // 3600, "h ", (seconds % 3600) // 60, "m")
    return String(seconds // 86400, "d ", (seconds % 86400) // 3600, "h")


def status_json(s: FillStatus) -> String:
    """The fill as `/api/pipelines/<name>` gives it."""
    var out = String('{"on": ', "true" if s.on else "false")
    out.write(
        ', "total": ',
        s.total,
        ', "done": ',
        s.done,
        ', "live": ',
        s.live,
        ', "failed": ',
        s.failed,
        ', "retrying": ',
        s.retrying,
        ', "left": ',
        s.left,
        ', "running": ',
        s.running,
        ', "queued": ',
        s.queued,
        ', "rate_per_hour": ',
        Float64(Int(s.rate * 100.0 + 0.5)) / 100.0,
        ', "eta_seconds": ',
        String(s.eta_seconds) if s.eta_seconds >= 0 else String("null"),
        ', "spent_today": ',
        String(Float64(Int(s.spent * 10000.0 + 0.5)) / 10000.0) if s.spent
        >= 0 else String("null"),
        ', "budget_per_day": ',
        String(s.budget) if s.budget >= 0 else String("null"),
        ', "price_per_hour": ',
        String(Float64(Int(s.hourly * 10000.0 + 0.5)) / 10000.0) if s.hourly
        >= 0 else String("null"),
        ', "expected_run_seconds": ',
        s.expected_seconds,
        ', "cost_is_estimate": true, "waits_for_lag": ',
    )
    if s.lag_key:
        out.write(
            '{"partition": ',
            quote(s.lag_key),
            ', "fillable_at": ',
            quote(String(Civil.of(s.lag_until), "Z")),
            "}",
        )
    else:
        out.write("null")
    out.write(', "request": ')
    if s.request:
        out.write(request_json(s.request.value()))
    else:
        out.write("null")
    out.write(', "idle": ')
    if s.idle:
        out.write(quote(s.idle))
    else:
        out.write("null")
    out.write("}")
    return out^
