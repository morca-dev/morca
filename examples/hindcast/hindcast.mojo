"""Hindcast: how good were NOAA's GFS forecasts of 2 m temperature? A daily
pipeline whose first step is a Rust worker (src/lib.rs, through
`morca.rust_step`) and whose second scores the forecasts in Mojo
(skill.mojo). examples/hindcast/README.md has the whole story.

Partitions are forecast cycles, the 00z run of each day.

1. **`forecasts`** (mapped, Rust): the cycle's 2 m temperature at leads 0 to
   7 days, fetched by Range requests from NOAA's bucket and decoded, into
   `hindcast.t2m` (65,160 rows a lead), partitioned by cycle and lead. It
   replaces the cycle's partitions, so a rerun leaves one copy.
2. **`skill`** (gather, Mojo): scores every forecast this run's data can
   now be scored against. A forecast of cycle C at lead L is valid at
   V = C + L, and its analysis is the f000 of cycle V. So a cycle's
   analysis scores the forecasts *valid that day* (C = V - 1 ... V - 7),
   and a cycle's forecasts can be scored for each V already fetched. The
   step recomputes each such V whole from what's in `hindcast.t2m` and
   replaces its partition in `hindcast.skill` and `hindcast.cities`.

That makes the result independent of the order cycles arrive in: daily
runs, a backfill in any order, or a rerun all end with every (C, L) whose
two cycles are fetched. A cycle's scorecard fills in as its next seven days
are fetched, and is complete once it has all seven leads: `hindcast report`
says which are.

    hindcast report [cycle]   skill per lead, the cycles still waiting for
                              analyses, and the city scorecard of `cycle`

What the tests set: HINDCAST_LIB, the worker library (by default
`hindcast_worker`, found as `libhindcast_worker.so` the way morca finds
native libraries); HINDCAST_SOURCE, a base URL or a directory laid out as
NOAA's bucket (the fixtures); HINDCAST_LEADS, the leads in hours, comma
separated (default 0,24,...,168).
"""

from std.os import getenv
from std.sys import argv

from dista import Seq
from morca import (
    Cron,
    Ctx,
    Daily,
    Day,
    Gather,
    Mapped,
    Pipeline,
    Step,
    defer,
    morca_main,
)
from morca.civil import days_from_civil, now
from morca.rust_step import rust_step
from morca.tables import (
    PartitionField,
    PartitionSpec,
    Schema,
    append,
    ensure_table,
    load_dataset,
    parse_transform,
    scan,
    table,
)

from skill import (
    CITIES_SCHEMA,
    SKILL_SCHEMA,
    Scores,
    by_valid_date,
    date_text,
    read_field,
)
from t2m_schema import T2M_SCHEMA

comptime T2M = "hindcast.t2m"
comptime SKILL = "hindcast.skill"
comptime CITIES = "hindcast.cities"

comptime NOAA = "https://noaa-gfs-bdp-pds.s3.amazonaws.com"
comptime NOT_PUBLISHED = "not published yet"
"""What the worker's error says when a file isn't in the bucket."""


def leads() raises -> List[Int]:
    var out = List[Int]()
    var s = getenv("HINDCAST_LEADS", "0,24,48,72,96,120,144,168")
    for part in s.split(","):
        var h = Int(part.strip())
        if h < 0 or h % 24 != 0:
            raise Error("HINDCAST_LEADS: ", h, " isn't a whole number of days")
        out.append(h)
    return out^


def day_number(d: Day) -> Int64:
    return days_from_civil(d.year, d.month, d.day)


def by_cycle_and_lead() raises -> PartitionSpec:
    return PartitionSpec(
        0,
        [
            PartitionField.single(
                1, 1000, "cycle", parse_transform("identity")
            ),
            PartitionField.single(
                2, 1001, "lead_hours", parse_transform("identity")
            ),
        ],
    )


@fieldwise_init
struct Fetched(Copyable, Movable):
    var cycle: Int64
    """The cycle's day number, days from 1970-01-01."""
    var rows: Int
    var snapshot: Int64


def forecasts(mut ctx: Ctx, d: Day) raises -> Fetched:
    var t = ensure_table(
        ctx, T2M, Schema.parse(T2M_SCHEMA), by_cycle_and_lead()
    )
    var hours = String()
    for h in leads():
        hours += String("," if hours else "", h)
    var params = String(
        '{"cycle": "',
        d,
        '", "leads": [',
        hours,
        '], "source": "',
        getenv("HINDCAST_SOURCE", NOAA),
        '"}',
    )
    try:
        var r = rust_step(
            ctx, getenv("HINDCAST_LIB", "hindcast_worker"), t, params=params
        )
        ctx.log(String("forecasts: ", r.rows, " rows of cycle ", d))
        if r.stopped:
            ctx.log("stopped early: a rerun of the cycle replaces it")
        return Fetched(day_number(d), r.rows, r.snapshot_id)
    except e:
        # GFS's 00z run is in the bucket by about 05:00 UTC. A recent cycle
        # that isn't there yet is waited for; an old one is gone.
        var msg = String(e)
        var age = now() // 86400 - day_number(d)
        if NOT_PUBLISHED in msg and age <= 2:
            raise defer(1800, msg)
        raise e^


@fieldwise_init
struct Scored(Copyable, Movable):
    var days: Int
    """The valid dates with forecasts scored."""
    var forecasts: Int
    """The (cycle, lead) pairs scored."""


def skill(mut ctx: Ctx, fetched: Seq[Fetched]) raises -> Scored:
    var hs = leads()
    var t2m = table(ctx, T2M)
    var s = scan(ctx, t2m)
    # The valid dates this run's cycles can score or be scored at.
    var valid = List[Int64]()
    for i in range(len(fetched)):
        for h in hs:
            var v = fetched[i].cycle + Int64(h // 24)
            if v not in valid:
                valid.append(v)
    sort(valid)
    var out = Scores()
    var days = 0
    for v in valid:
        var analysis = read_field(s, v, 0)
        if analysis.n == 0:
            continue  # not fetched yet: a later run scores it
        var before = out.rows
        for h in hs:
            if h == 0:
                continue
            var c = v - Int64(h // 24)
            var f = read_field(s, c, h)
            if f.n == 0:
                continue
            var k = out.add(v, c, h, f, analysis)
            ctx.log(
                String(
                    date_text(c),
                    " +",
                    h,
                    "h, valid ",
                    date_text(v),
                    ": bias ",
                    k.bias,
                    " K, MAE ",
                    k.mae,
                    " K, RMSE ",
                    k.rmse,
                    " K",
                )
            )
        if out.rows > before:
            days += 1
    if out.rows == 0:
        ctx.log("nothing to score yet")
        return Scored(days, 0)
    var st = ensure_table(
        ctx, SKILL, Schema.parse(SKILL_SCHEMA), by_valid_date()
    )
    _ = append(ctx, st, out.skill_batches())
    var ct = ensure_table(
        ctx, CITIES, Schema.parse(CITIES_SCHEMA), by_valid_date()
    )
    _ = append(ctx, ct, out.city_batches())
    ctx.log(String(out.rows, " forecasts scored, valid on ", days, " days"))
    return Scored(days, out.rows)


comptime Forecasts = Step[
    "forecasts", Day, Fetched, forecasts, Mapped, retries=2, replaces=[T2M]
]
comptime Skill = Step[
    "skill",
    Seq[Fetched],
    Scored,
    skill,
    Gather,
    after=Forecasts,
    reads=[T2M],
    replaces=[SKILL, CITIES],
]
comptime Hindcast = Pipeline[
    "hindcast",
    Forecasts,
    Skill,
    partitions=Daily["2021-03-23"],
    schedule=Cron["0 6 * * *"],
]


# --- hindcast report ---


@fieldwise_init
struct _Row(Copyable, Movable):
    var cycle: Int64
    var lead: Int
    var valid: Int64
    var points: Int64
    var bias: Float64
    var mae: Float64
    var rmse: Float64


def _fmt(x: Float64) -> String:
    """`x` to 4 decimals, rounded: what the tests compare."""
    var neg = x < 0
    var n = Int(abs(x) * 10000.0 + 0.5)
    var frac = String(n % 10000)
    while frac.byte_length() < 4:
        frac = "0" + frac
    return String("-" if neg and n > 0 else "", n // 10000, ".", frac)


def _pad(s: String, n: Int) -> String:
    var out = s
    while out.byte_length() < n:
        out += " "
    return out^


def _col(names: List[String], name: String) raises -> Int:
    for i in range(len(names)):
        if names[i] == name:
            return i
    raise Error("no column ", name)


def _count(dataset: String) raises -> Int:
    var n = 0
    for task in load_dataset(dataset).scan().plan_files():
        n += Int(task.data_file.record_count)
    return n


def report(cycle: String) raises:
    var rows = List[_Row]()
    for b in load_dataset(SKILL).scan().to_batches():
        var names = List[String]()
        for i in range(b.num_columns()):
            names.append(b.name(i))
        var cy = b.column_i64(_col(names, "cycle"))[0].copy()
        var ld = b.column_i64(_col(names, "lead_hours"))[0].copy()
        var va = b.column_i64(_col(names, "valid_date"))[0].copy()
        var pt = b.column_i64(_col(names, "points"))[0].copy()
        var bi = b.column_f64(_col(names, "bias_k"))[0].copy()
        var ma = b.column_f64(_col(names, "mae_k"))[0].copy()
        var rm = b.column_f64(_col(names, "rmse_k"))[0].copy()
        for r in range(b.num_rows):
            rows.append(
                _Row(cy[r], Int(ld[r]), va[r], pt[r], bi[r], ma[r], rm[r])
            )
    var hs = leads()
    # Per lead, over the cycles scored: mean bias and MAE, and the RMSE of
    # them all (the root of the mean square).
    print("lead  cycles  bias_k   mae_k    rmse_k")
    for h in hs:
        if h == 0:
            continue
        var n = 0
        var b = 0.0
        var m = 0.0
        var r2 = 0.0
        for r in rows:
            if r.lead == h:
                n += 1
                b += r.bias
                m += r.mae
                r2 += r.rmse * r.rmse
        if n > 0:
            print(
                _pad(String(h, "h"), 5),
                _pad(String(n), 7),
                _pad(_fmt(b / Float64(n)), 8),
                _pad(_fmt(m / Float64(n)), 8),
                _fmt((r2 / Float64(n)) ** 0.5),
            )
    # Each cycle fetched, and its leads scored: complete once every lead
    # has its analysis.
    var t2m = load_dataset(T2M)
    var t2m_rows = 0
    for task in t2m.scan().plan_files():
        t2m_rows += Int(task.data_file.record_count)
    var cycles = List[Int64]()
    var q = t2m.scan().filter('["=", "lead_hours", 0]').select(["cycle"])
    for b in q.to_batches():
        for c in b.column_i64(0)[0]:
            if c not in cycles:
                cycles.append(c)
    sort(cycles)
    var want = len(hs) - (1 if 0 in hs else 0)
    var complete = 0
    for c in cycles:
        var got = 0
        for r in rows:
            if r.cycle == c:
                got += 1
        if got == want:
            complete += 1
        else:
            print("cycle", date_text(c), "has", got, "of", want, "leads scored")
    print(complete, "of", len(cycles), "cycles complete")
    print("rows: t2m", t2m_rows, "skill", len(rows), "cities", _count(CITIES))
    if not cycle:
        return
    for r in rows:
        if date_text(r.cycle) == cycle:
            print(
                "skill",
                cycle,
                String("+", r.lead, "h"),
                "valid",
                date_text(r.valid),
                "points",
                r.points,
                "bias",
                _fmt(r.bias),
                "mae",
                _fmt(r.mae),
                "rmse",
                _fmt(r.rmse),
            )
    for b in load_dataset(CITIES).scan().to_batches():
        var names = List[String]()
        for i in range(b.num_columns()):
            names.append(b.name(i))
        var cy = b.column_i64(_col(names, "cycle"))[0].copy()
        var ld = b.column_i64(_col(names, "lead_hours"))[0].copy()
        var city = b.column_str(_col(names, "city"))[0].copy()
        var la = b.column_f64(_col(names, "lat"))[0].copy()
        var lo = b.column_f64(_col(names, "lon"))[0].copy()
        var fc = b.column_f64(_col(names, "forecast_k"))[0].copy()
        var an = b.column_f64(_col(names, "analysis_k"))[0].copy()
        var er = b.column_f64(_col(names, "error_k"))[0].copy()
        for r in range(b.num_rows):
            if date_text(cy[r]) != cycle:
                continue
            print(
                "city",
                String("+", ld[r], "h"),
                city[r].replace(" ", "_"),
                Int(la[r]),
                Int(lo[r]),
                "forecast",
                _fmt(fc[r]),
                "analysis",
                _fmt(an[r]),
                "error",
                _fmt(er[r]),
            )


def main() raises:
    var args = argv()
    if len(args) >= 2 and String(args[1]) == "report":
        report(String(args[2]) if len(args) >= 3 else String())
        return
    morca_main[Hindcast]()
