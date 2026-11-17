"""Months, weeks, days, pipelines, describe and the in-memory executor."""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from dista import Seq
from morca import (
    FAILED,
    SKIPPED,
    SUCCEEDED,
    Ctx,
    Daily,
    Day,
    Gather,
    Hour,
    Hourly,
    Mapped,
    Month,
    Monthly,
    Name,
    Pipeline,
    Step,
    Week,
    Weekly,
    parse_months,
    parse_names,
    parse_partitions,
)
from morca.name import path_segment
from morca.week import weeks_in


# --- names ---


def test_name_parse() raises:
    for ok in [
        "a",
        "log-0f3a",
        "315969629_00000000-0000-0000",
        "x.y:z_1",
        "modular/modular",
        "a/b/c",
        String("n") * 128,
    ]:
        assert_equal(String(Name.parse(ok)), ok)
    for bad in [
        "",
        String("n") * 129,
        "a b",
        "a,b",
        "a..b",
        "../a",
        "a/../b",
        "café",
        "a%2Fb",
        "a\\b",
        "/a",
        "a/",
        "a//b",
        "/",
    ]:
        with assert_raises(contains="not a name"):
            _ = Name.parse(bad)
    assert_true(Name.parse("a") < Name.parse("b"))
    assert_true(Name.parse("B") < Name.parse("a"))  # by bytes
    assert_true(Name.parse("x") == Name.parse("x"))


def test_path_segment() raises:
    assert_equal(path_segment("log-01"), "log-01")
    assert_equal(path_segment("modular/modular"), "modular%2Fmodular")
    assert_equal(path_segment("a/b/c"), "a%2Fb%2Fc")


def test_parse_names() raises:
    var ns = parse_names("log-2, log-1,log-3")
    assert_equal(len(ns), 3)
    assert_equal(String(ns[0]), "log-2")
    assert_equal(String(ns[1]), "log-1")
    with assert_raises(contains="not a range"):
        _ = parse_names("a..b")
    with assert_raises(contains="given twice"):
        _ = parse_names("a,b,a")
    with assert_raises(contains="not a name"):
        _ = parse_names("a,,b")
    var repos = parse_names("modular/modular,owner/name")
    assert_equal(String(repos[1]), "owner/name")


# --- months ---


def test_month_parse_and_write() raises:
    var m = Month.parse("2024-03")
    assert_equal(m.year, 2024)
    assert_equal(m.month, 3)
    assert_equal(String(m), "2024-03")
    assert_equal(String(Month(2024, 12).next()), "2025-01")
    with assert_raises(contains="not a month"):
        _ = Month.parse("2024-13")
    with assert_raises(contains="not a month"):
        _ = Month.parse("2024-3")
    with assert_raises(contains="not a month"):
        _ = Month.parse("24-03")


def test_month_ranges() raises:
    var ms = parse_months("2023-11..2024-02")
    assert_equal(len(ms), 4)
    assert_equal(String(ms[0]), "2023-11")
    assert_equal(String(ms[3]), "2024-02")
    ms = parse_months("2024-05,2024-01..2024-02")
    assert_equal(len(ms), 3)
    assert_equal(String(ms[0]), "2024-05")
    assert_equal(String(ms[2]), "2024-02")
    assert_equal(len(parse_months("2011-01..2024-12")), 168)
    with assert_raises(contains="backwards"):
        _ = parse_months("2024-03..2024-01")
    with assert_raises(contains="given twice"):
        _ = parse_months("2024-01..2024-03,2024-02")


# --- days ---


def test_day_parse_and_write() raises:
    var d = Day.parse("2024-02-29")
    assert_equal(d.year, 2024)
    assert_equal(d.month, 2)
    assert_equal(d.day, 29)
    assert_equal(String(d), "2024-02-29")
    assert_equal(String(d.next()), "2024-03-01")
    assert_equal(String(Day(2023, 12, 31).next()), "2024-01-01")
    assert_equal(String(Day(2023, 2, 28).next()), "2023-03-01")
    assert_equal(String(Day(2000, 2, 28).next()), "2000-02-29")
    assert_equal(String(Day(1900, 2, 28).next()), "1900-03-01")
    for bad in [
        "2023-02-29",
        "2024-04-31",
        "2024-01-00",
        "2024-1-01",
        "2024-01",
    ]:
        with assert_raises(contains="not a day"):
            _ = Day.parse(bad)


def test_day_ranges() raises:
    var ds = parse_partitions[Daily[]]("2024-02-27..2024-03-02")
    assert_equal(len(ds), 5)
    assert_equal(String(ds[2]), "2024-02-29")
    assert_equal(len(parse_partitions[Daily[]]("2011-01-01..2024-12-31")), 5114)
    with assert_raises(contains="given twice"):
        _ = parse_partitions[Daily[]]("2024-01-01..2024-01-03,2024-01-02")


# --- hours ---


def test_hour_parse_and_write() raises:
    var h = Hour.parse("2024-02-29T07")
    assert_equal(h.year, 2024)
    assert_equal(h.day, 29)
    assert_equal(h.hour, 7)
    assert_equal(String(h), "2024-02-29T07")
    assert_equal(String(h.next()), "2024-02-29T08")
    assert_equal(String(Hour(2023, 12, 31, 23).next()), "2024-01-01T00")
    assert_equal(String(Hour(2024, 3, 1, 0).prev()), "2024-02-29T23")
    assert_equal(String(Hour(2024, 1, 1, 0).prev()), "2023-12-31T23")
    assert_true(Hour.parse("2024-01-01T09") < Hour.parse("2024-01-01T10"))
    assert_equal(String(Hour.parse("2024-02-29T07").day_of()), "2024-02-29")
    for bad in [
        "2024-02-29T24",
        "2024-02-30T01",
        "2024-02-29T7",
        "2024-02-29",
        "2024-02-29 07",
        "2024-02-29T-1",
    ]:
        with assert_raises(contains="not an hour"):
            _ = Hour.parse(bad)


def test_hour_ranges_and_fills() raises:
    var hs = parse_partitions[Hourly[]]("2024-02-29T22..2024-03-01T01")
    assert_equal(len(hs), 4)
    assert_equal(String(hs[2]), "2024-03-01T00")
    assert_equal(
        len(parse_partitions[Hourly[]]("2024-01-01T00..2024-12-31T23")),
        366 * 24,
    )
    with assert_raises(contains="before the pipeline's first partition"):
        _ = parse_partitions[Hourly["2024-01-01T05"]](
            "2024-01-01T04..2024-01-01T06"
        )
    # A fire at 2024-03-01 00:05 runs that hour, or with fire=Previous
    # the one before.
    assert_equal(
        String(Hourly[].fill(2024, 3, 1, 0, previous=False)), "2024-03-01T00"
    )
    assert_equal(
        String(Hourly[].fill(2024, 3, 1, 0, previous=True)), "2024-02-29T23"
    )
    assert_equal(
        String(Daily[].fill(2024, 3, 1, 17, previous=False)), "2024-03-01"
    )


# --- weeks ---


def test_week_parse_and_write() raises:
    var w = Week.parse("2026-W46")
    assert_equal(w.year, 2026)
    assert_equal(w.week, 46)
    assert_equal(String(w), "2026-W46")
    assert_equal(String(w.monday()), "2026-11-09")
    assert_equal(String(w.next()), "2026-W47")
    assert_equal(String(w.prev()), "2026-W45")
    assert_true(Week.parse("2026-W09") < Week.parse("2026-W10"))
    assert_true(Week.parse("2025-W52") < Week.parse("2026-W01"))
    for bad in [
        "2026-W00",
        "2026-W54",
        "2024-W53",  # 2024 has 52 weeks
        "2026-W1",
        "2026W46",
        "2026-46",
        "2026-11",
        "26-W46",
        "2026-Wxx",
    ]:
        with assert_raises(contains="not a week"):
            _ = Week.parse(bad)


def test_iso_week_year_boundaries() raises:
    # 53 weeks in a year that starts on a Thursday (2015, 2026), or a leap
    # year that starts on a Wednesday (2020); 52 otherwise.
    assert_equal(weeks_in(2015), 53)
    assert_equal(weeks_in(2020), 53)
    assert_equal(weeks_in(2026), 53)
    assert_equal(weeks_in(2024), 52)
    assert_equal(weeks_in(2025), 52)
    assert_equal(weeks_in(2027), 52)
    # Days near New Year in the other ISO year's weeks.
    assert_equal(String(Week.containing(2024, 12, 30, 0)), "2025-W01")
    assert_equal(String(Week.containing(2024, 12, 29, 23)), "2024-W52")
    assert_equal(String(Week.containing(2021, 1, 3, 0)), "2020-W53")
    assert_equal(String(Week.containing(2021, 1, 4, 0)), "2021-W01")
    assert_equal(String(Week.containing(2026, 1, 1, 0)), "2026-W01")
    assert_equal(String(Week.containing(2027, 1, 1, 0)), "2026-W53")
    assert_equal(String(Week.containing(2027, 1, 3, 0)), "2026-W53")
    assert_equal(String(Week.containing(2027, 1, 4, 0)), "2027-W01")
    assert_equal(String(Week.containing(2010, 1, 3, 0)), "2009-W53")
    assert_equal(String(Week.containing(2008, 12, 29, 0)), "2009-W01")
    assert_equal(String(Week.containing(1970, 1, 1, 0)), "1970-W01")
    assert_equal(String(Week.parse("2026-W01").monday()), "2025-12-29")
    assert_equal(String(Week.parse("2026-W53").monday()), "2026-12-28")
    assert_equal(String(Week.parse("2020-W53").next()), "2021-W01")
    assert_equal(String(Week.parse("2024-W52").next()), "2025-W01")
    assert_equal(String(Week.parse("2021-W01").prev()), "2020-W53")
    assert_equal(String(Week.parse("2025-W01").prev()), "2024-W52")
    # Every day of 2000-2040 is in the week its Monday is, and consecutive
    # weeks' Mondays are seven days apart.
    var d = Day(2000, 1, 1)
    var last = Week.containing(2000, 1, 1, 0)
    while d.year < 2041:
        var wk = Week.containing(d.year, d.month, d.day, 0)
        if not (wk == last):
            assert_equal(String(last.next()), String(wk))
            assert_equal(String(wk.monday()), String(d))
            last = wk.copy()
        d = d.next()
    var ms = Week.parse("2026-W53").months()
    assert_equal(len(ms), 2)
    assert_equal(String(ms[0]), "2026-12")
    assert_equal(String(ms[1]), "2027-01")


def test_week_ranges_and_fills() raises:
    var ws = parse_partitions[Weekly[]]("2020-W52..2021-W02")
    assert_equal(len(ws), 4)
    assert_equal(String(ws[1]), "2020-W53")
    assert_equal(String(ws[2]), "2021-W01")
    assert_equal(len(parse_partitions[Weekly[]]("2024-W01..2024-W52")), 52)
    assert_equal(len(parse_partitions[Weekly[]]("2015-W01..2015-W53")), 53)
    with assert_raises(contains="before the pipeline's first partition"):
        _ = parse_partitions[Weekly["2026-W40"]]("2026-W39..2026-W41")
    # A fire on Monday 2026-11-16 06:00 runs the week that just ended
    # with fire=Previous, the one it falls in with Current.
    assert_equal(
        String(Weekly[].fill(2026, 11, 16, 6, previous=True)), "2026-W46"
    )
    assert_equal(
        String(Weekly[].fill(2026, 11, 16, 6, previous=False)), "2026-W47"
    )
    assert_equal(
        String(Weekly[].fill(2026, 11, 15, 23, previous=False)), "2026-W46"
    )
    assert_equal(
        String(Weekly[].fill(2027, 1, 4, 0, previous=True)), "2026-W53"
    )


def test_keys_before_the_start_are_refused() raises:
    assert_equal(
        len(parse_partitions[Monthly["2011-01"]]("2011-01..2011-03")), 3
    )
    with assert_raises(
        contains="before the pipeline's first partition, 2011-01"
    ):
        _ = parse_partitions[Monthly["2011-01"]]("2010-12..2011-01")
    with assert_raises(contains="before the pipeline's first partition"):
        _ = parse_partitions[Daily["2024-01-02"]]("2024-01-01")


# --- a pipeline: key -> label -> total, plus a gather over the gather ---


@fieldwise_init
struct Labeled(Copyable, Movable):
    var key: String
    var n: Int


def key(mut ctx: Ctx, m: Month) raises -> Int:
    return m.year * 100 + m.month


def label(mut ctx: Ctx, n: Int) raises -> Labeled:
    if n % 100 == 2:
        raise Error("February is broken")
    return Labeled(ctx.partition, n)


def total(mut ctx: Ctx, xs: Seq[Labeled]) raises -> Int:
    var t = 0
    for i in range(len(xs)):
        t += xs[i].n
    return t


def twice(mut ctx: Ctx, t: Int) raises -> Int:
    return t * 2


def count(mut ctx: Ctx, ms: Seq[Month]) raises -> Int:
    return len(ms)


comptime Key = Step["key", Month, Int, key, Mapped]
comptime Label = Step["label", Int, Labeled, label, Mapped, after=Key]
comptime Total = Step["total", Seq[Labeled], Int, total, Gather, after=Label]
comptime Twice = Step["twice", Int, Int, twice, Gather, after=Total]
comptime Labels = Pipeline["labels", Key, Label, Total, Twice]

comptime Count = Step["count", Seq[Month], Int, count, Gather]
comptime Counts = Pipeline["counts", Count]


# A daily pipeline: per-day sizes, then their sum.


def day_size(mut ctx: Ctx, d: Day) raises -> Int:
    return d.day


def day_total(mut ctx: Ctx, sizes: Seq[Int]) raises -> Int:
    var t = 0
    for i in range(len(sizes)):
        t += sizes[i]
    return t


comptime DaySize = Step["size", Day, Int, day_size, Mapped]
comptime DayTotal = Step[
    "total", Seq[Int], Int, day_total, Gather, after=DaySize
]
comptime Days = Pipeline[
    "days", DaySize, DayTotal, partitions=Daily["2024-01-01"]
]

comptime DayCount = Step["count", Seq[Day], Int, count_days, Gather]
comptime DayCounts = Pipeline["day_counts", DayCount, partitions=Daily[]]


def count_days(mut ctx: Ctx, days: Seq[Day]) raises -> Int:
    return len(days)


def hour_of(mut ctx: Ctx, h: Hour) raises -> Int:
    return h.hour


comptime HourOf = Step["hour", Hour, Int, hour_of, Mapped]
comptime Hours = Pipeline["hours", HourOf, partitions=Hourly["2024-01-01T00"]]


def test_an_hourly_pipeline() raises:
    var res = Hours.run(
        parse_partitions[Hours.partitions]("2024-01-01T21..2024-01-02T02")
    )
    assert_true(res.succeeded())
    assert_equal(len(res.steps), 6)
    assert_equal(res.output[Int]("hour", "2024-01-01T23"), 23)
    assert_equal(res.output[Int]("hour", "2024-01-02T01"), 1)
    var d = Hours.describe()
    assert_true(
        '"partitions": {"kind": "hourly", "start": "2024-01-01T00"}' in d, d
    )
    assert_true('"input": "morca.hour.Hour"' in d, d)


def week_of(mut ctx: Ctx, w: Week) raises -> Int:
    return w.week


comptime WeekOf = Step["week", Week, Int, week_of, Mapped]
comptime Weeks = Pipeline["weeks", WeekOf, partitions=Weekly["2024-W01"]]


def test_a_weekly_pipeline() raises:
    var res = Weeks.run(
        parse_partitions[Weeks.partitions]("2024-W51..2025-W02")
    )
    assert_true(res.succeeded())
    assert_equal(len(res.steps), 4)
    assert_equal(res.output[Int]("week", "2024-W52"), 52)
    assert_equal(res.output[Int]("week", "2025-W01"), 1)
    var d = Weeks.describe()
    assert_true('"partitions": {"kind": "weekly", "start": "2024-W01"}' in d, d)
    assert_true('"input": "morca.week.Week"' in d, d)


def test_a_daily_pipeline() raises:
    var ds = parse_partitions[Days.partitions]("2024-02-27..2024-03-02")
    var res = Days.run(ds)
    assert_true(res.succeeded())
    assert_equal(res.steps[0].partition, "2024-02-27")
    assert_equal(res.output[Int]("size", "2024-02-29"), 29)
    assert_equal(res.output[Int]("total"), 27 + 28 + 29 + 1 + 2)
    assert_equal(
        DayCounts.run(
            parse_partitions[Daily[]]("2024-01-01..2024-12-31")
        ).output[Int]("count"),
        366,
    )
    var d = Days.describe()
    assert_true(
        '"partitions": {"kind": "daily", "start": "2024-01-01"},'
        ' "schedule": null, "max_runs": 1, "run_retries": 3, "sensor": false,'
        ' "keys_per_run": 1, "workers": 2,'
        ' "steps"'
        in d
    )
    assert_true('"input": "morca.day.Day"' in d)
    assert_true(
        '"partitions": {"kind": "monthly", "start": null}' in Labels.describe()
    )


def test_runs_in_order() raises:
    var res = Labels.run(parse_months("2024-03..2024-04,2024-01"))
    assert_true(res.succeeded())
    # Mapped steps run once per partition, in the run's order, step by step.
    assert_equal(len(res.steps), 3 + 3 + 1 + 1)
    assert_equal(res.steps[0].step, "key")
    assert_equal(res.steps[0].partition, "2024-03")
    assert_equal(res.steps[2].partition, "2024-01")
    assert_equal(res.steps[3].step, "label")
    assert_equal(res.steps[6].step, "total")
    assert_equal(res.steps[6].partition, "")
    var l = res.output[Labeled]("label", "2024-04")
    assert_equal(l.key, "2024-04")
    assert_equal(l.n, 202404)
    assert_equal(res.output[Int]("total"), 202403 + 202404 + 202401)
    assert_equal(res.output[Int]("twice"), 2 * (202403 + 202404 + 202401))


def test_failed_partition_skips_downstream() raises:
    var res = Labels.run(parse_months("2024-01..2024-03"))
    assert_false(res.succeeded())
    assert_equal(res.status("key", "2024-02"), SUCCEEDED)
    assert_equal(res.status("label", "2024-02"), FAILED)
    assert_equal(
        res.steps[res.find("label", "2024-02")].error, "February is broken"
    )
    # The other partitions carry on.
    assert_equal(res.status("label", "2024-01"), SUCCEEDED)
    assert_equal(res.status("label", "2024-03"), SUCCEEDED)
    # A gather over a failed partition is skipped, and so is what follows it.
    assert_equal(res.status("total", ""), SKIPPED)
    assert_true("label 2024-02" in res.steps[res.find("total", "")].error)
    assert_equal(res.status("twice", ""), SKIPPED)
    with assert_raises(contains="skipped"):
        _ = res.output[Int]("total")


def test_first_gather_takes_partitions() raises:
    var res = Counts.run(parse_months("2011-01..2024-12"))
    assert_true(res.succeeded())
    assert_equal(res.output[Int]("count"), 168)


def test_describe() raises:
    var d = Labels.describe()
    assert_true(d.startswith('{"pipeline": "labels", "registry_hash": "0x'))
    assert_true('"name": "key", "kind": "mapped", "after": null' in d)
    assert_true('"name": "total", "kind": "gather", "after": "label"' in d)
    assert_true('"input": "dista.seq.Seq[test_steps.Labeled]"' in d)
    assert_true('"function": "test_steps::label(morca::ctx::Ctx,' in d)


def test_registry_hash() raises:
    # Stable within a binary, and different for a different DAG.
    assert_equal(Labels.registry_hash(), Labels.registry_hash())
    assert_true(Labels.registry_hash() != Counts.registry_hash())
    comptime Fewer = Pipeline["labels", Key, Label, Total]
    assert_true(Labels.registry_hash() != Fewer.registry_hash())
    assert_true(hex(Labels.registry_hash()) in Labels.describe())


def test_registry_hash_replaces() raises:
    # writes= and replaces= of the same dataset hash alike, so switching a
    # step to replaces= keeps its pipeline's done keys; another dataset, or
    # a read, is a different DAG.
    comptime Writes = Pipeline[
        "p", Step["key", Month, Int, key, Mapped, writes=["lake.a"]]
    ]
    comptime Replaces = Pipeline[
        "p", Step["key", Month, Int, key, Mapped, replaces=["lake.a"]]
    ]
    comptime Both = Pipeline[
        "p",
        Step[
            "key",
            Month,
            Int,
            key,
            Mapped,
            writes=["lake.a"],
            replaces=["lake.a"],
        ],
    ]
    comptime Other = Pipeline[
        "p", Step["key", Month, Int, key, Mapped, replaces=["lake.b"]]
    ]
    comptime Reads = Pipeline[
        "p",
        Step[
            "key",
            Month,
            Int,
            key,
            Mapped,
            reads=["lake.c"],
            replaces=["lake.a"],
        ],
    ]
    assert_equal(Writes.registry_hash(), Replaces.registry_hash())
    assert_equal(Writes.registry_hash(), Both.registry_hash())
    assert_true(Replaces.registry_hash() != Other.registry_hash())
    assert_true(Replaces.registry_hash() != Reads.registry_hash())
    assert_true('"replaces": ["lake.a"]' in Replaces.describe())


def test_registry_hash_version() raises:
    # No version= keeps the hash it had; setting or raising one changes it,
    # so the pipeline's keys are no longer done.
    comptime Unset = Pipeline["p", Step["key", Month, Int, key, Mapped]]
    comptime Zero = Pipeline[
        "p", Step["key", Month, Int, key, Mapped, version=0]
    ]
    comptime One = Pipeline[
        "p", Step["key", Month, Int, key, Mapped, version=1]
    ]
    comptime Two = Pipeline[
        "p", Step["key", Month, Int, key, Mapped, version=2]
    ]
    assert_equal(Unset.registry_hash(), Zero.registry_hash())
    assert_true(Unset.registry_hash() != One.registry_hash())
    assert_true(One.registry_hash() != Two.registry_hash())
    assert_true('"version": 2' in Two.describe())
    assert_false('"version"' in Unset.describe())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
