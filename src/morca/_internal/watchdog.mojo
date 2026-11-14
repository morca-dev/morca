"""The watchdog: pauses pipelines when something leaves a sane range.

On 2026-11-05 nothing noticed ~360 EC2 launches in 38 minutes, or a run
waiting three hours for workers that never came. The scheduler evaluates
these rules every `MORCA_WATCHDOG_SECONDS` (60; 0 turns the watchdog off),
each from Postgres only (never object storage), with the thresholds below
(each rule's environment variable overrides its default):

| Rule | Trips when | Scope |
|---|---|---|
| `launches` | more than `MORCA_WATCHDOG_LAUNCHES` (200) instances were launched in the last hour (pool handovers aren't launches) | all pipelines |
| `cost` | the estimated cost of the instances up (`morca._internal.fleet`'s price table) stayed over `MORCA_WATCHDOG_COST_HOUR` ($3) an hour for `MORCA_WATCHDOG_COST_MINUTES` (15) minutes, or the last 24 hours cost over `MORCA_WATCHDOG_COST_DAY` ($25) | all pipelines |
| `idle` | at least `MORCA_WATCHDOG_IDLE_WORKERS` (4) workers, up for `MORCA_WATCHDOG_IDLE_MINUTES` (10, at most 30) minutes, averaged under `MORCA_WATCHDOG_IDLE_CPU` (15) percent CPU over them (pooled idle and draining workers aren't counted) | the pipelines owning those workers |
| `failing` | a pipeline had more than `MORCA_WATCHDOG_FAILED` (20) failed attempts in the last hour, or at least `MORCA_WATCHDOG_FAILED_MIN` (10) attempts ended and more than `MORCA_WATCHDOG_FAILED_PERCENT` (50) percent failed | each such pipeline |
| `stuck` | a run with a running attempt, on instances that are sampled, has had no attempt start or end, no instance launched or ended and no sampled host over `MORCA_WATCHDOG_STUCK_CPU` (5) percent CPU for `MORCA_WATCHDOG_STUCK_MINUTES` (30, at most 30, since samples are kept that long) minutes | that run's pipeline |
| `unmet` | a run has waited `MORCA_WATCHDOG_UNMET_MINUTES` (10) minutes for a request more than this host, or any worker of its pool, can grant at most (`morca._internal.resources`, #462): it would wait forever | that run's pipeline |
| `control` | the control instance's newest minute has memory over `MORCA_WATCHDOG_MEMORY` (90) percent or its fullest disk over `MORCA_WATCHDOG_DISK` (85) | all pipelines |

A tripped rule **pauses** its scope through `morca._internal.pause.set_paused`
(what the UI's Pause button does; pipelines already paused are left
alone), writes an `orca.audit` row per pipeline (user `watchdog`, the
rule's numbers), and a row of `orca.watchdog_trips`, which the banner on
`/`, `/ops/pools` and `/ops/control`, `/watchdog` and `/metrics` show for as long as any of its
pipelines is paused. It never resumes anything. A rule that is still over
its limit when a pipeline is unpaused trips again on the next pass, so
snooze it (`morca watchdog snooze <rule> 2h`, or on `/watchdog`) first;
that is stored in `orca.watchdog_rules` and audited.

A rule checks one threshold or more (`limits`: `control` checks memory
and disk, `cost` the sustained rate and the day, `failing` the count and
the share, `idle` the CPU and the number of workers). Each reading keeps
every check's value and limit and whether it is past it, and so does each
trip, so `morca watchdog status`, `/watchdog` and `/api/watchdog` show
every threshold and which one tripped.

Evaluation is pure (`eval_*`, over plain rows) apart from the gathering
(`gather_*`).
"""

from std.os import getenv

from json import Value, loads
import morca._internal.db.pipelines as pipelines_db
import morca._internal.db.watchdog as watchdog_db
from morca._internal.db.watchdog import Counts, Lease, Quiet, Unmet

from morca._internal.auth import audit
from morca._internal.fleet import hourly_price
from morca._internal.html import Html, url_encode
from morca._internal.json import quote
from morca._internal.notify import alert, ui_link
from morca._internal.pause import set_paused
from morca._internal.state import State
from morca._internal.system import system_now

comptime SAMPLE_MINUTES = 30
"""How long fleet samples are kept, which bounds `idle` and `stuck`."""


def rule_names() -> List[String]:
    return [
        String("launches"),
        String("cost"),
        String("idle"),
        String("failing"),
        String("stuck"),
        String("unmet"),
        String("control"),
    ]


def is_rule(name: String) -> Bool:
    for r in rule_names():
        if r == name:
            return True
    return False


# ---------------------------------------------------------------------------
# Thresholds
# ---------------------------------------------------------------------------


@fieldwise_init
struct Config(Copyable, Movable):
    var seconds: Float64
    var launches: Int
    var cost_hour: Float64
    var cost_minutes: Int
    var cost_day: Float64
    var idle_cpu: Float64
    var idle_minutes: Int
    var idle_workers: Int
    var failed: Int
    var failed_percent: Float64
    var failed_min: Int
    var stuck_minutes: Int
    var stuck_cpu: Float64
    var memory: Float64
    var disk: Float64
    var control_price: Float64
    """Dollars an hour of the control instance (`MORCA_CONTROL_TYPE`), or 0."""
    var fixed_price: Bool
    """The runner launches no instances (`MORCA_RUNNER=local`), so the cost
    rule has nothing to price: it reads "fixed price" and never trips."""
    var unmet_minutes: Int
    """How long a run waits for a request no host can grant before `unmet`
    trips."""


def default_config() -> Config:
    return Config(
        60.0,
        200,
        3.0,
        15,
        25.0,
        15.0,
        10,
        4,
        20,
        50.0,
        10,
        30,
        5.0,
        90.0,
        85.0,
        0.0,
        False,
        10,
    )


def _number(name: String, default: Float64) raises -> Float64:
    var v = getenv(name)
    if not v:
        return default
    try:
        return Float64(v)
    except:
        raise Error("morca: ", name, " is a number, not ", v)


def config() raises -> Config:
    """The thresholds, from the environment."""
    var c = default_config()
    c.seconds = _number("MORCA_WATCHDOG_SECONDS", c.seconds)
    c.launches = Int(_number("MORCA_WATCHDOG_LAUNCHES", Float64(c.launches)))
    c.cost_hour = _number("MORCA_WATCHDOG_COST_HOUR", c.cost_hour)
    c.cost_minutes = Int(
        _number("MORCA_WATCHDOG_COST_MINUTES", Float64(c.cost_minutes))
    )
    c.cost_day = _number("MORCA_WATCHDOG_COST_DAY", c.cost_day)
    c.idle_cpu = _number("MORCA_WATCHDOG_IDLE_CPU", c.idle_cpu)
    c.idle_minutes = min(
        Int(_number("MORCA_WATCHDOG_IDLE_MINUTES", Float64(c.idle_minutes))),
        SAMPLE_MINUTES,
    )
    c.idle_workers = Int(
        _number("MORCA_WATCHDOG_IDLE_WORKERS", Float64(c.idle_workers))
    )
    c.failed = Int(_number("MORCA_WATCHDOG_FAILED", Float64(c.failed)))
    c.failed_percent = _number(
        "MORCA_WATCHDOG_FAILED_PERCENT", c.failed_percent
    )
    c.failed_min = Int(
        _number("MORCA_WATCHDOG_FAILED_MIN", Float64(c.failed_min))
    )
    c.stuck_minutes = min(
        Int(_number("MORCA_WATCHDOG_STUCK_MINUTES", Float64(c.stuck_minutes))),
        SAMPLE_MINUTES,
    )
    c.stuck_cpu = _number("MORCA_WATCHDOG_STUCK_CPU", c.stuck_cpu)
    c.unmet_minutes = Int(
        _number("MORCA_WATCHDOG_UNMET_MINUTES", Float64(c.unmet_minutes))
    )
    c.memory = _number("MORCA_WATCHDOG_MEMORY", c.memory)
    c.disk = _number("MORCA_WATCHDOG_DISK", c.disk)
    var control = getenv("MORCA_CONTROL_TYPE")
    if control:
        c.control_price = max(hourly_price(control), 0.0)
    c.fixed_price = getenv("MORCA_RUNNER") == "local"
    return c^


# ---------------------------------------------------------------------------
# Readings (pure)
# ---------------------------------------------------------------------------


@fieldwise_init
struct Check(Copyable, Movable):
    """One threshold a rule checks, and what it saw against it."""

    var name: String
    var value: Float64
    """-1 when there is nothing to judge."""
    var limit: Float64
    var unit: String
    var op: String
    """How the value trips it: `over`, `under` or `at least` the limit."""
    var past: Bool
    """The value is past the limit (the rule trips when all of its
    conditions are; for `idle` both checks must be past)."""


def limits(c: Config, rule: String) -> List[Check]:
    """The thresholds `rule` checks, with no values yet."""
    var out = List[Check]()
    if rule == "launches":
        out.append(
            Check(
                "launched", -1.0, Float64(c.launches), " in 1h", "over", False
            )
        )
    elif rule == "cost":
        out.append(
            Check(
                String("rate for ", c.cost_minutes, "m"),
                -1.0,
                c.cost_hour,
                " $/h",
                "over",
                False,
            )
        )
        out.append(Check("day", -1.0, c.cost_day, " $/24h", "over", False))
    elif rule == "idle":
        out.append(
            Check(
                String("cpu for ", c.idle_minutes, "m"),
                -1.0,
                c.idle_cpu,
                " %",
                "under",
                False,
            )
        )
        out.append(
            Check(
                "workers",
                -1.0,
                Float64(c.idle_workers),
                "",
                "at least",
                False,
            )
        )
    elif rule == "failing":
        out.append(
            Check("failed", -1.0, Float64(c.failed), " in 1h", "over", False)
        )
        out.append(
            Check(
                "failed share",
                -1.0,
                c.failed_percent,
                String(" % of ", c.failed_min, "+"),
                "over",
                False,
            )
        )
    elif rule == "stuck":
        out.append(
            Check(
                "quiet",
                -1.0,
                Float64(c.stuck_minutes),
                " min",
                "at least",
                False,
            )
        )
    elif rule == "unmet":
        out.append(
            Check(
                "waiting",
                -1.0,
                Float64(c.unmet_minutes),
                " min",
                "at least",
                False,
            )
        )
    elif rule == "control":
        out.append(Check("memory", -1.0, c.memory, " %", "over", False))
        out.append(Check("disk", -1.0, c.disk, " %", "over", False))
    return out^


def _see(mut checks: List[Check], i: Int, value: Float64, past: Bool):
    checks[i].value = value
    checks[i].past = past


def checks_json(checks: List[Check]) -> String:
    var out = String("[")
    for i in range(len(checks)):
        ref k = checks[i]
        out.write(
            ", " if i else "",
            '{"name": ',
            quote(k.name),
            ', "value": ',
            _fx(k.value, 2) if k.value >= 0 else String("null"),
            ', "limit": ',
            _fx(k.limit, 2),
            ', "unit": ',
            quote(k.unit),
            ', "op": ',
            quote(k.op),
            ', "past": ',
            "true" if k.past else "false",
            "}",
        )
    out.write("]")
    return out^


def parse_checks(text: String) raises -> List[Check]:
    """`checks_json`'s text back (empty: none)."""
    var out = List[Check]()
    if not text:
        return out^
    var v = loads(text)
    for k in v.array_items():
        out.append(
            Check(
                k["name"].string_value(),
                k["value"].float_value() if not k["value"].is_null() else -1.0,
                k["limit"].float_value(),
                k["unit"].string_value(),
                k["op"].string_value(),
                k["past"].bool_value(),
            )
        )
    return out^


def past_names(checks: List[Check]) -> List[String]:
    var out = List[String]()
    for k in checks:
        if k.past:
            out.append(k.name)
    return out^


@fieldwise_init
struct Reading(Copyable, Movable):
    """What a rule saw: its current value against its threshold, and if
    that is a trip, why and which pipelines."""

    var rule: String
    var value: Float64
    """-1 when there is nothing to judge (no samples)."""
    var threshold: Float64
    """The limit of the check nearest it (`value` is that check's)."""
    var tripped: Bool
    var detail: String
    var pipelines: List[String]
    var checks: List[Check]
    """Every threshold the rule checks (`limits`), with its value."""


def _fx(x: Float64, digits: Int = 1) -> String:
    var scale = 1
    for _ in range(digits):
        scale *= 10
    var n = Int(max(x, 0.0) * Float64(scale) + 0.5)
    var s = String(n // scale)
    if digits > 0:
        var f = String(n % scale)
        while f.byte_length() < digits:
            f = String("0", f)
        s.write(".", f)
    return s^


def _ok(
    rule: String, value: Float64, threshold: Float64, var checks: List[Check]
) -> Reading:
    return Reading(
        rule, value, threshold, False, String(), List[String](), checks^
    )


def eval_launches(
    c: Config, launched: Int, everything: List[String]
) -> Reading:
    """`launched` instances in the last hour against the limit."""
    var k = limits(c, "launches")
    _see(k, 0, Float64(launched), launched > c.launches)
    if launched <= c.launches:
        return _ok("launches", Float64(launched), Float64(c.launches), k^)
    return Reading(
        "launches",
        Float64(launched),
        Float64(c.launches),
        True,
        String(
            launched,
            " instances launched in the last hour (limit ",
            c.launches,
            ")",
        ),
        everything.copy(),
        k^,
    )


def cost_rate(leases: List[Lease], ago: Float64, control: Float64) -> Float64:
    """Dollars an hour being spent `ago` seconds ago (unpriced types cost
    nothing here, as in `morca._internal.fleet`)."""
    var total = control
    for l in leases:
        if l.start_ago >= ago and (l.end_ago < 0 or l.end_ago <= ago):
            total += max(hourly_price(l.instance_type), 0.0)
    return total


def cost_spent(
    leases: List[Lease], window: Float64, control: Float64
) -> Float64:
    """Dollars spent over the last `window` seconds."""
    var total = control * window / 3600.0
    for l in leases:
        var from_ = min(l.start_ago, window)
        var to = max(l.end_ago, 0.0)
        if from_ > to:
            total += (
                max(hourly_price(l.instance_type), 0.0) * (from_ - to) / 3600.0
            )
    return total


def eval_cost(
    c: Config, leases: List[Lease], everything: List[String]
) -> Reading:
    """The rate now (the reading's value), the lowest it was at each minute
    of the sustain period, and the last 24 hours' spend. On the local
    runner (`fixed_price`) there is nothing to price: no reading, no trip."""
    var k = limits(c, "cost")
    if c.fixed_price:
        return Reading(
            "cost",
            -1.0,
            c.cost_hour,
            False,
            "fixed price",
            List[String](),
            k^,
        )
    var now_rate = cost_rate(leases, 0.0, c.control_price)
    var lowest = now_rate
    for m in range(1, c.cost_minutes + 1):
        lowest = min(
            lowest, cost_rate(leases, Float64(m * 60), c.control_price)
        )
    var day = cost_spent(leases, 86400.0, c.control_price)
    _see(k, 0, lowest, lowest > c.cost_hour)
    _see(k, 1, day, day > c.cost_day)
    var detail = String()
    if lowest > c.cost_hour:
        detail = String(
            "estimated $",
            _fx(now_rate, 2),
            "/h, over $",
            _fx(c.cost_hour, 2),
            "/h for ",
            c.cost_minutes,
            " minutes",
        )
    if day > c.cost_day:
        detail.write(
            ", " if detail else "",
            "estimated $",
            _fx(day, 2),
            " in the last 24 hours (limit $",
            _fx(c.cost_day, 2),
            ")",
        )
    if not detail:
        return _ok("cost", now_rate, c.cost_hour, k^)
    return Reading(
        "cost", now_rate, c.cost_hour, True, detail, everything.copy(), k^
    )


def eval_idle(
    c: Config, workers: Int, cpu: Float64, pipelines: List[String]
) -> Reading:
    """`workers` up for the whole window, averaging `cpu` percent over it
    (-1: no samples)."""
    var k = limits(c, "idle")
    _see(k, 0, cpu, cpu >= 0 and cpu < c.idle_cpu)
    _see(k, 1, Float64(workers), workers >= c.idle_workers)
    if workers < c.idle_workers or cpu < 0 or cpu >= c.idle_cpu:
        return _ok("idle", cpu, c.idle_cpu, k^)
    return Reading(
        "idle",
        cpu,
        c.idle_cpu,
        True,
        String(
            workers,
            " workers averaged ",
            _fx(cpu),
            "% CPU for ",
            c.idle_minutes,
            " minutes (limit ",
            _fx(c.idle_cpu, 0),
            "%)",
        ),
        pipelines.copy(),
        k^,
    )


def eval_failing(c: Config, counts: List[Counts]) -> Reading:
    """Pipelines over either failure limit; the value is the most failed
    attempts any had; the share check's, the highest share of a pipeline
    with at least `failed_min` attempts ended."""
    var worst = 0
    var share = -1.0
    var detail = String()
    var out = List[String]()
    var checks = limits(c, "failing")
    for k in counts:
        worst = max(worst, k.failed)
        var many = k.failed > c.failed
        var half = k.total >= c.failed_min and Float64(
            k.failed
        ) * 100.0 > c.failed_percent * Float64(k.total)
        if k.total >= c.failed_min and k.total > 0:
            share = max(share, Float64(k.failed) * 100.0 / Float64(k.total))
        if many:
            checks[0].past = True
        if half:
            checks[1].past = True
        if many or half:
            out.append(k.pipeline)
            detail.write(
                ", " if detail else "",
                k.pipeline,
                ": ",
                k.failed,
                " of ",
                k.total,
                " attempts failed in the last hour",
            )
    checks[0].value = Float64(worst)
    checks[1].value = share
    if len(out) == 0:
        return _ok("failing", Float64(worst), Float64(c.failed), checks^)
    return Reading(
        "failing",
        Float64(worst),
        Float64(c.failed),
        True,
        detail,
        out^,
        checks^,
    )


def eval_stuck(c: Config, runs: List[Quiet]) -> Reading:
    var worst = 0.0
    var detail = String()
    var out = List[String]()
    for r in runs:
        worst = max(worst, r.minutes)
        if r.minutes >= Float64(c.stuck_minutes):
            var seen = False
            for p in out:
                if p == r.pipeline:
                    seen = True
            if not seen:
                out.append(r.pipeline)
            detail.write(
                ", " if detail else "",
                r.pipeline,
                " run ",
                r.run,
                ": no progress for ",
                _fx(r.minutes, 0),
                " minutes",
            )
    var k = limits(c, "stuck")
    _see(k, 0, worst, worst >= Float64(c.stuck_minutes))
    if len(out) == 0:
        return _ok("stuck", worst, Float64(c.stuck_minutes), k^)
    return Reading(
        "stuck", worst, Float64(c.stuck_minutes), True, detail, out^, k^
    )


def eval_unmet(c: Config, runs: List[Unmet]) -> Reading:
    """Runs waiting for a request no host can grant (`Unmet`), for at
    least `unmet_minutes`: their pipelines."""
    var worst = 0.0
    var detail = String()
    var out = List[String]()
    for r in runs:
        worst = max(worst, r.minutes)
        if r.minutes >= Float64(c.unmet_minutes):
            var seen = False
            for p in out:
                if p == r.pipeline:
                    seen = True
            if not seen:
                out.append(r.pipeline)
            detail.write(
                ", " if detail else "",
                r.pipeline,
                " run ",
                r.run,
                " ",
                r.held,
                ", for ",
                _fx(r.minutes, 0),
                " minutes",
            )
    var k = limits(c, "unmet")
    _see(k, 0, worst, worst >= Float64(c.unmet_minutes))
    if len(out) == 0:
        return _ok("unmet", worst, Float64(c.unmet_minutes), k^)
    return Reading(
        "unmet", worst, Float64(c.unmet_minutes), True, detail, out^, k^
    )


def eval_control(
    c: Config, have: Bool, mem: Float64, disk: Float64, everything: List[String]
) -> Reading:
    """The newest minute's memory and fullest disk (`have` false: no fresh
    samples). The value is whichever is nearer its limit, in percent; the
    checks have both."""
    var k = limits(c, "control")
    if not have:
        return _ok("control", -1.0, c.memory, k^)
    _see(k, 0, mem, mem > c.memory)
    _see(k, 1, disk, disk > c.disk)
    var by_disk = disk / c.disk > mem / c.memory
    var value = disk if by_disk else mem
    var limit = c.disk if by_disk else c.memory
    if mem <= c.memory and disk <= c.disk:
        return _ok("control", value, limit, k^)
    var detail = String()
    if mem > c.memory:
        detail = String(
            "control instance memory ",
            _fx(mem),
            "% (limit ",
            _fx(c.memory, 0),
            "%)",
        )
    if disk > c.disk:
        detail.write(
            ", " if detail else "",
            "control instance disk ",
            _fx(disk),
            "% (limit ",
            _fx(c.disk, 0),
            "%)",
        )
    return Reading("control", value, limit, True, detail, everything.copy(), k^)


# ---------------------------------------------------------------------------
# Gathering (Postgres only)
# ---------------------------------------------------------------------------


def all_pipelines(mut db: State) raises -> List[String]:
    return pipelines_db.names(db.conn)


def gather_launches(mut db: State) raises -> Int:
    return watchdog_db.launches_last_hour(db.conn)


def gather_leases(mut db: State) raises -> List[Lease]:
    return watchdog_db.leases(db.conn)


def gather_idle(
    mut db: State, c: Config
) raises -> Tuple[Int, Float64, List[String]]:
    """The workers up the whole window that were sampled, their average
    CPU (-1 if none), and the pipelines that own them."""
    return watchdog_db.idle_workers(db.conn, c.idle_minutes)


def gather_failing(mut db: State) raises -> List[Counts]:
    return watchdog_db.failing_counts(db.conn)


def gather_stuck(mut db: State, c: Config) raises -> List[Quiet]:
    return watchdog_db.quiet_runs(db.conn, c.stuck_cpu)


def gather_unmet(mut db: State) raises -> List[Unmet]:
    return watchdog_db.unmet_runs(db.conn)


def evaluate(mut db: State, c: Config) raises -> List[Reading]:
    """Every rule's reading now."""
    var everything = all_pipelines(db)
    var out = List[Reading]()
    out.append(eval_launches(c, gather_launches(db), everything))
    out.append(eval_cost(c, gather_leases(db), everything))
    var idle = gather_idle(db, c)
    out.append(eval_idle(c, idle[0], idle[1], idle[2]))
    out.append(eval_failing(c, gather_failing(db)))
    out.append(eval_stuck(c, gather_stuck(db, c)))
    out.append(eval_unmet(c, gather_unmet(db)))
    var now = system_now(db)
    if now and not now.value().stale():
        ref n = now.value()
        out.append(eval_control(c, True, n.mem_pct, n.disk_pct, everything))
    else:
        out.append(eval_control(c, False, 0.0, 0.0, everything))
    return out^


# ---------------------------------------------------------------------------
# Tripping
# ---------------------------------------------------------------------------


def snoozed(mut db: State, rule: String) raises -> Bool:
    return watchdog_db.is_snoozed(db.conn, rule)


def _record(mut db: State, r: Reading) raises:
    watchdog_db.record_reading(
        db.conn, r.rule, r.value, r.threshold, r.detail, checks_json(r.checks)
    )


def trip(mut db: State, r: Reading) raises -> List[String]:
    """Pauses the unpaused pipelines in `r`'s scope and records why. Returns
    the ones it paused; none, and no record, if all were paused already."""
    var unpaused = pipelines_db.unpaused(db.conn)
    var paused = List[String]()
    var joined = String()
    for p in r.pipelines:
        var live = False
        for u in unpaused:
            if u == p:
                live = True
        if not live:
            continue
        if set_paused(db, p, True):
            continue
        paused.append(p)
        joined.write("," if joined else "", p)
        audit(
            db,
            "watchdog",
            String("/pipelines/", url_encode(p), "/pause"),
            0,
            String("watchdog rule ", r.rule, ": ", r.detail),
            "watchdog",
        )
    if len(paused) > 0:
        watchdog_db.insert_trip(
            db.conn,
            r.rule,
            r.value,
            r.threshold,
            r.detail,
            joined,
            checks_json(r.checks),
        )
        print(
            "morca: watchdog rule",
            r.rule,
            "tripped:",
            r.detail,
            "- paused",
            joined,
        )
        try:
            _ = alert(
                db,
                "watchdog",
                r.rule,
                "high",
                "rotating_light,warning",
                String("morca watchdog: ", r.rule, " tripped"),
                String(
                    "Rule ",
                    r.rule,
                    ": ",
                    _fx(r.value),
                    " against a limit of ",
                    _fx(r.threshold),
                    ". ",
                    r.detail,
                    "\nPaused: ",
                    joined.replace(",", ", "),
                ),
                ui_link("/ops/control"),
                pipelines=joined,
            )
        except e:
            print("morca: notify: can't record the watchdog alert:", e)
    return paused^


def check(mut db: State, c: Config) raises -> Int:
    """One pass: evaluates the rules, keeps their readings, and trips those
    over their limits that aren't snoozed. Returns the pipelines paused."""
    var paused = 0
    for r in evaluate(db, c):
        _record(db, r)
        if r.tripped and not snoozed(db, r.rule):
            paused += len(trip(db, r))
    watchdog_db.prune_trips(db.conn)
    return paused


# ---------------------------------------------------------------------------
# Snoozing
# ---------------------------------------------------------------------------

comptime MAX_SNOOZE_SECONDS = 30 * 86400


def parse_duration(text: String) raises -> Int:
    """`90s`, `30m`, `2h` or `1d` in seconds; `off` is 0 (end a snooze)."""
    var t = String(text.strip())
    if t == "off":
        return 0
    if t.byte_length() < 2:
        raise Error("morca: not a duration (30m, 2h, 1d or off): ", text)
    var unit = String(t[byte = t.byte_length() - 1 :])
    var n: Int
    try:
        n = Int(t[byte = : t.byte_length() - 1])
    except:
        raise Error("morca: not a duration (30m, 2h, 1d or off): ", text)
    var scale: Int
    if unit == "s":
        scale = 1
    elif unit == "m":
        scale = 60
    elif unit == "h":
        scale = 3600
    elif unit == "d":
        scale = 86400
    else:
        raise Error("morca: not a duration (30m, 2h, 1d or off): ", text)
    if n <= 0 or n * scale > MAX_SNOOZE_SECONDS:
        raise Error("morca: a snooze is from 1s to 30d: ", text)
    return n * scale


def snooze(
    mut db: State, rule: String, duration: String, by: String
) raises -> Int:
    """Silences `rule` for `duration` (`off` ends it). Returns the seconds."""
    if not is_rule(rule):
        var names = String()
        for n in rule_names():
            names.write(", " if names else "", n)
        raise Error("morca: no rule ", rule, " (", names, ")")
    var secs = parse_duration(duration)
    if secs == 0:
        watchdog_db.end_snooze(db.conn, rule)
        return 0
    watchdog_db.set_snooze(db.conn, rule, secs, by)
    return secs


# ---------------------------------------------------------------------------
# What the pages show
# ---------------------------------------------------------------------------


@fieldwise_init
struct Trip(Copyable, Movable):
    var rule: String
    var ago: Float64
    var at: String
    var value: Float64
    var threshold: Float64
    var detail: String
    var pipelines: List[String]
    """The pipelines it paused that are still paused."""
    var id: Int
    var acked_by: String
    """Who kept it paused (acknowledged it), or empty."""
    var checks: List[Check]
    """The checks as the trip saw them (empty for a trip from before they
    were kept)."""


def active_trips(mut db: State) raises -> List[Trip]:
    """The trips with a pipeline still paused that nobody has acknowledged,
    newest first: what the banner shows."""
    return _trips(db, False)


def listed_trips(mut db: State) raises -> List[Trip]:
    """Like `active_trips`, with the acknowledged ones: what status lists."""
    return _trips(db, True)


def acknowledge(mut db: State, trip: Int, by: String) raises -> Int:
    """Keeps the pipelines of the unacknowledged trips (all of them if `trip`
    is 0) paused, and stops the banner showing them. Returns how many."""
    var n = 0
    for t in active_trips(db):
        if trip != 0 and t.id != trip:
            continue
        watchdog_db.acknowledge_trip(db.conn, t.id, by if by else String("ui"))
        n += 1
    return n


def _trips(mut db: State, acknowledged: Bool) raises -> List[Trip]:
    var out = List[Trip]()
    for r in watchdog_db.trip_rows(db.conn):
        if r.is_acked and not acknowledged:
            continue
        var ps = List[String]()
        for p in r.paused.split(","):
            ps.append(String(p))
        out.append(
            Trip(
                r.rule,
                r.ago,
                r.at,
                r.value,
                r.threshold,
                r.detail,
                ps^,
                r.id,
                r.acked_by,
                parse_checks(r.checks),
            )
        )
    return out^


@fieldwise_init
struct RuleRow(Copyable, Movable):
    var rule: String
    var value: Float64
    var threshold: Float64
    var checked: Bool
    var snoozed_until: String
    """UTC, or empty."""
    var snoozed_by: String
    var tripped: Bool
    var note: String
    """Why the rule has no reading ("fixed price"), or empty."""
    var checks: List[Check]
    """Each threshold with its last value (-1 before the first check)."""
    var tripped_on: List[String]
    """The checks its unacknowledged trips tripped on (what `tripped`
    shows)."""


def rule_rows(mut db: State, c: Config) raises -> List[RuleRow]:
    """Each rule's last reading and snooze; thresholds from `c` where the
    scheduler hasn't read it yet."""
    var trips = active_trips(db)
    var out = List[RuleRow]()
    for name in rule_names():
        var tripped = False
        var on = List[String]()
        for t in trips:
            if t.rule == name:
                tripped = True
                for n in past_names(t.checks):
                    var seen = False
                    for o in on:
                        if o == n:
                            seen = True
                    if not seen:
                        on.append(n)
        var note = String()
        if name == "cost" and c.fixed_price:
            note = "fixed price"
        var r = watchdog_db.rule_reading(db.conn, name)
        if not r.seen:
            out.append(
                RuleRow(
                    name,
                    -1.0,
                    _limit(c, name),
                    False,
                    String(),
                    String(),
                    tripped,
                    note,
                    limits(c, name),
                    on^,
                )
            )
            continue
        var checks = parse_checks(r.checks)
        if len(checks) == 0:
            checks = limits(c, name)
        out.append(
            RuleRow(
                name,
                r.value,
                r.threshold,
                True,
                r.until if r.live else String(),
                r.by if r.live else String(),
                tripped,
                note,
                checks^,
                on^,
            )
        )
    return out^


def _limit(c: Config, rule: String) -> Float64:
    if rule == "launches":
        return Float64(c.launches)
    if rule == "cost":
        return c.cost_hour
    if rule == "idle":
        return c.idle_cpu
    if rule == "failing":
        return Float64(c.failed)
    if rule == "stuck":
        return Float64(c.stuck_minutes)
    if rule == "unmet":
        return Float64(c.unmet_minutes)
    return c.memory


def unit_of(rule: String) -> String:
    if rule == "launches":
        return " launches/h"
    if rule == "cost":
        return " $/h"
    if rule == "idle":
        return " % CPU"
    if rule == "failing":
        return " failed attempts/h"
    if rule == "stuck":
        return " minutes quiet"
    if rule == "unmet":
        return " minutes waiting"
    return " %"


def _ago(seconds: Float64) -> String:
    var s = Int(seconds)
    if s < 90:
        return String(s, "s ago")
    if s < 5400:
        return String(s // 60, "m ago")
    return String(s // 3600, "h ago")


def _rule_link(t: Trip) -> String:
    if t.rule == "launches" or t.rule == "cost" or t.rule == "idle":
        return "/ops/pools?kind=ec2"
    if t.rule == "control":
        return "/ops/control"
    var status = "failed" if t.rule == "failing" else "running"
    if len(t.pipelines) > 0:
        return String(
            "/runs?pipeline=", url_encode(t.pipelines[0]), "&status=", status
        )
    return "/runs"


def banner_html(mut h: Html, trips: List[Trip]):
    """A red box listing the trips with a pipeline still paused, or
    nothing."""
    if len(trips) == 0:
        return
    h.raw('<div class="alert alert--trip" role="alert" id="watchdog">')
    for t in trips:
        h.raw("<div><strong>Watchdog paused pipelines: ")
        h.text(t.rule)
        h.raw("</strong> ")
        h.text(t.detail, " (", _ago(t.ago), ", ", t.at, "). Paused: ")
        for i in range(len(t.pipelines)):
            h.raw(", " if i else "")
            h.link(
                String("/pipelines/", url_encode(t.pipelines[i])),
                t.pipelines[i],
            )
        h.raw(". ")
        h.link(_rule_link(t), "See why")
        h.raw("</div>")
    h.raw(
        '<div>Unpause a pipeline to clear its trip, or <form method="post"'
        ' action="/watchdog/all/ack" class="inline"><button type="submit">'
        "Keep paused</button></form> to leave them paused and hide this; <a"
        ' href="/watchdog">Watchdog</a> snoozes a rule.</div></div>'
    )


def _names_json(names: List[String]) -> String:
    var out = String("[")
    for i in range(len(names)):
        out.write(", " if i else "", quote(names[i]))
    out.write("]")
    return out^


def check_text(k: Check, digits: Int = 2) -> String:
    """`memory 10.60 % (trips over 90.00)`, and `, past` when it is."""
    return String(
        k.name,
        " ",
        _fx(k.value, digits) if k.value >= 0 else String("-"),
        k.unit,
        " (trips ",
        k.op,
        " ",
        _fx(k.limit, digits),
        ", past)" if k.past else ")",
    )


def _joined(names: List[String]) -> String:
    var text = String()
    for n in names:
        text.write(", " if text else "", n)
    return text^


def trips_json(trips: List[Trip]) -> String:
    var out = String("[")
    for i in range(len(trips)):
        ref t = trips[i]
        out.write(
            ", " if i else "",
            '{"rule": ',
            quote(t.rule),
            ', "at": ',
            quote(t.at),
            ', "seconds_ago": ',
            Int(t.ago),
            ', "value": ',
            _fx(t.value, 2),
            ', "threshold": ',
            _fx(t.threshold, 2),
            ', "detail": ',
            quote(t.detail),
            ', "id": ',
            t.id,
            ', "acknowledged_by": ',
            quote(t.acked_by) if t.acked_by else String("null"),
            ', "checks": ',
            checks_json(t.checks),
            ', "tripped_on": ',
            _names_json(past_names(t.checks)),
            ', "pipelines": [',
        )
        for k in range(len(t.pipelines)):
            out.write(", " if k else "", quote(t.pipelines[k]))
        out.write("]}")
    out.write("]")
    return out^


def rules_json(rows: List[RuleRow]) -> String:
    var out = String("[")
    for i in range(len(rows)):
        ref r = rows[i]
        out.write(
            ", " if i else "",
            '{"rule": ',
            quote(r.rule),
            ', "value": ',
            _fx(r.value, 2) if r.value >= 0 else String("null"),
            ', "threshold": ',
            _fx(r.threshold, 2),
            ', "note": ',
            quote(r.note) if r.note else String("null"),
            ', "tripped": ',
            "true" if r.tripped else "false",
            ', "tripped_on": ',
            _names_json(r.tripped_on),
            ', "checks": ',
            checks_json(r.checks),
            ', "snoozed_until": ',
            quote(r.snoozed_until) if r.snoozed_until else String("null"),
            "}",
        )
    out.write("]")
    return out^


def watchdog_json(mut db: State, c: Config) raises -> String:
    return String(
        '{"rules": ',
        rules_json(rule_rows(db, c)),
        ', "trips": ',
        trips_json(listed_trips(db)),
        "}",
    )


def watchdog_html(mut h: Html, rows: List[RuleRow], trips: List[Trip]):
    """The `/watchdog` page's body: the rules, with a snooze form each."""
    h.raw("<h1>Watchdog</h1>")
    banner_html(h, trips)
    h.raw(
        '<p class="muted">Pauses pipelines when a rule leaves its range;',
        " never resumes them. Checked by the scheduler every",
        " <code>MORCA_WATCHDOG_SECONDS</code>.</p>",
        '<section class="card"><div class="scroll"><table><thead><tr>',
        "<th>Rule</th><th>Checks</th><th>State</th><th>Snooze</th>",
        "</tr></thead><tbody>",
    )
    for r in rows:
        h.raw("<tr><td><code>")
        h.text(r.rule)
        h.raw("</code></td><td>")
        for i in range(len(r.checks)):
            ref k = r.checks[i]
            h.raw("<br>" if i else "")
            if k.past:
                h.raw('<span class="error">')
            h.text(check_text(k, 1))
            if k.past:
                h.raw("</span>")
        h.raw("</td><td>")
        if r.tripped:
            h.raw('<span class="error">tripped</span>')
            if len(r.tripped_on) > 0:
                h.text(" on ", _joined(r.tripped_on))
        elif r.note:
            h.text(r.note)
        elif r.snoozed_until:
            h.text("snoozed until ", r.snoozed_until)
            if r.snoozed_by:
                h.text(" by ", r.snoozed_by)
        elif r.checked:
            h.raw("ok")
        else:
            h.raw("not checked yet")
        h.raw('</td><td><form method="post" action="/watchdog/')
        h.text(r.rule)
        h.raw(
            '/snooze"><input name="duration" value="2h" size="4"> <button'
            ' type="submit">Snooze</button></form></td></tr>'
        )
    h.raw("</tbody></table></div></section>")


def _label(s: String) -> String:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def prometheus(mut db: State, c: Config) raises -> String:
    """`morca_watchdog_tripped{rule}` (1 while a trip of the rule has a
    pipeline paused), and the rule's last value and threshold."""
    var rows = rule_rows(db, c)
    var out = String(
        "# HELP morca_watchdog_tripped 1 while a trip of the rule has a",
        " pipeline still paused.\n# TYPE morca_watchdog_tripped gauge\n",
    )
    for r in rows:
        out.write(
            'morca_watchdog_tripped{rule="',
            r.rule,
            '"} ',
            1 if r.tripped else 0,
            "\n",
        )
    out.write(
        "# HELP morca_watchdog_value The rule's value at its last check (see",
        " /watchdog for units).\n# TYPE morca_watchdog_value gauge\n",
    )
    for r in rows:
        if r.value >= 0:
            out.write(
                'morca_watchdog_value{rule="',
                r.rule,
                '"} ',
                _fx(r.value, 3),
                "\n",
            )
    out.write(
        "# HELP morca_watchdog_threshold The rule's limit.\n",
        "# TYPE morca_watchdog_threshold gauge\n",
    )
    for r in rows:
        out.write(
            'morca_watchdog_threshold{rule="',
            r.rule,
            '"} ',
            _fx(r.threshold, 3),
            "\n",
        )
    return out^


def status_lines(json: String) raises -> List[String]:
    """`morca watchdog status`'s lines from `/api/watchdog`'s JSON."""
    var v = loads(json)
    var out = List[String]()
    for r in v["rules"].array_items():
        var line = String(r["rule"].string_value())
        while line.byte_length() < 10:
            line.write(" ")
        var checks = List[String]()
        if "checks" in r:
            for k in parse_checks(r["checks"].raw_json()):
                checks.append(check_text(k))
        if len(checks) > 0:
            line.write(_joined(checks), "  ")
        else:  # an older server
            line.write(
                "now ",
                _num_text(r["value"]),
                unit_of(r["rule"].string_value()),
                "  limit ",
                _num_text(r["threshold"]),
                "  ",
            )
        if r["tripped"].bool_value():
            line.write("TRIPPED")
            if "tripped_on" in r:
                var on = List[String]()
                for n in r["tripped_on"].array_items():
                    on.append(n.string_value())
                if len(on) > 0:
                    line.write(" on ", _joined(on))
        elif not r["note"].is_null():
            line.write(r["note"].string_value())
        elif not r["snoozed_until"].is_null():
            line.write("snoozed until ", r["snoozed_until"].string_value())
        else:
            line.write("ok")
        out.append(line^)
    for t in v["trips"].array_items():
        var line = String(
            "trip ",
            t["rule"].string_value(),
            " at ",
            t["at"].string_value(),
            ": ",
            t["detail"].string_value(),
            "; paused",
        )
        for p in t["pipelines"].array_items():
            line.write(" ", p.string_value())
        if not t["acknowledged_by"].is_null():
            line.write(
                " (acknowledged by ", t["acknowledged_by"].string_value(), ")"
            )
        out.append(line^)
    return out^


def _num_text(v: Value) -> String:
    if v.is_null():
        return "-"
    return _fx(v.float_value(), 2)
