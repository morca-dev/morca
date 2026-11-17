"""Cron expressions, time zones, and the fires of a schedule.

The expected times were worked out by hand from each zone's rules (and
agree with `date` on macOS and Linux). Zones come from the system's
zoneinfo, or `MORCA_ZONEINFO`.
"""

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from morca import (
    Civil,
    Cron,
    CronExpr,
    Ctx,
    Current,
    Daily,
    Day,
    Mapped,
    Month,
    Monthly,
    Pipeline,
    PosixTZ,
    Previous,
    Step,
    Zone,
    parse_time,
    utc,
)


def _fires(expr: String, zone: String, after: String, n: Int) raises -> String:
    """The next `n` fires, as UTC times, comma-separated."""
    var c = CronExpr.parse(expr)
    var z = Zone.load(zone)
    var t = parse_time(after)
    var out = String()
    for i in range(n):
        t = c.next_fire(t, z)
        out.write("," if i > 0 else "", Civil.of(t))
    return out^


# --- cron expressions ---


def test_cron_parses() raises:
    var c = CronExpr.parse("*/15 9-17 * jan,Jul MON-fri")
    assert_equal(c.minutes, (1 << 0) | (1 << 15) | (1 << 30) | (1 << 45))
    assert_equal(c.hours, ((1 << 18) - 1) & ~((1 << 9) - 1))
    assert_equal(c.months, (1 << 1) | (1 << 7))
    assert_equal(c.weekdays, 0b0111110)
    assert_true(c.any_day)
    assert_true(not c.any_weekday)
    # 7 is Sunday too; a/step runs to the field's end.
    assert_equal(CronExpr.parse("0 0 * * 7").weekdays, 1)
    assert_equal(
        CronExpr.parse("10/20 * * * *").minutes,
        (1 << 10) | (1 << 30) | (1 << 50),
    )
    assert_equal(String(CronExpr.parse("  @daily ")), "@daily")


def test_cron_refuses() raises:
    for bad in [
        "",
        "* * * *",
        "* * * * * *",
        "60 * * * *",
        "* 24 * * *",
        "* * 0 * *",
        "* * 32 * *",
        "* * * 13 *",
        "* * * * 8",
        "5-1 * * * *",
        "*/0 * * * *",
        "1/2/3 * * * *",
        "a * * * *",
        "1,,2 * * * *",
        "* * * foo *",
        "@reboot",
        "0 0 30 2 *",
        "0 0 31 4,6,9,11 *",
    ]:
        with assert_raises(contains="cron:"):
            _ = CronExpr.parse(bad)
    # February 29 and a restricted weekday can both fire.
    _ = CronExpr.parse("0 0 29 2 *")
    _ = CronExpr.parse("0 0 30 2 1")


def test_fires_in_utc() raises:
    assert_equal(
        _fires("0 3 2 * *", "UTC", "2024-01-15T00:00Z", 3),
        "2024-02-02T03:00:00,2024-03-02T03:00:00,2024-04-02T03:00:00",
    )
    # Strictly after: a fire at `after` itself isn't the next one.
    assert_equal(
        _fires("0 3 2 * *", "UTC", "2024-02-02T03:00Z", 1),
        "2024-03-02T03:00:00",
    )
    assert_equal(
        _fires("*/20 * * * *", "UTC", "2024-12-31T23:30:10Z", 3),
        "2024-12-31T23:40:00,2025-01-01T00:00:00,2025-01-01T00:20:00",
    )
    # Day of month or day of week: the 13th, or any Friday.
    assert_equal(
        _fires("0 0 13 * 5", "UTC", "2024-09-01T00:00Z", 4),
        "2024-09-06T00:00:00,2024-09-13T00:00:00,2024-09-20T00:00:00,2024-09-27T00:00:00",
    )
    # Only the day of week restricted: Fridays only.
    assert_equal(
        _fires("0 0 * * fri", "UTC", "2024-09-01T00:00Z", 2),
        "2024-09-06T00:00:00,2024-09-13T00:00:00",
    )
    # February 29 skips 2100.
    assert_equal(
        _fires("0 0 29 2 *", "UTC", "2096-03-01T00:00Z", 1),
        "2104-02-29T00:00:00",
    )


def test_fires_across_new_york_dst() raises:
    # 2024-03-10: 02:00 EST becomes 03:00 EDT; 02:30 doesn't happen, so it
    # fires at the end of the gap, 03:00 EDT (07:00Z).
    assert_equal(
        _fires("30 2 * * *", "America/New_York", "2024-03-09T12:00Z", 3),
        "2024-03-10T07:00:00,2024-03-11T06:30:00,2024-03-12T06:30:00",
    )
    # Every 5 minutes of a skipped hour fires once, at the gap's end.
    assert_equal(
        _fires("*/5 2 * * *", "America/New_York", "2024-03-10T06:50Z", 2),
        "2024-03-10T07:00:00,2024-03-11T06:00:00",
    )
    assert_equal(
        _fires("*/5 2,3 * * *", "America/New_York", "2024-03-10T07:00Z", 1),
        "2024-03-10T07:05:00",
    )
    # 2024-11-03: 02:00 EDT becomes 01:00 EST; 01:30 happens twice and fires
    # once, at the first (05:30Z), then at 01:30 EST the next day.
    assert_equal(
        _fires("30 1 * * *", "America/New_York", "2024-11-02T12:00Z", 2),
        "2024-11-03T05:30:00,2024-11-04T06:30:00",
    )
    # Every 30 minutes through the repeated hour: 01:00 and 01:30 EDT, not
    # again in EST; then 02:00 EST.
    assert_equal(
        _fires("*/30 * * * *", "America/New_York", "2024-11-03T04:45Z", 4),
        "2024-11-03T05:00:00,2024-11-03T05:30:00,2024-11-03T07:00:00,2024-11-03T07:30:00",
    )
    # Starting inside the second 01:xx doesn't fire its repeat either.
    assert_equal(
        _fires("30 1 * * *", "America/New_York", "2024-11-03T06:10Z", 1),
        "2024-11-04T06:30:00",
    )


def test_fires_across_london_dst() raises:
    # 2024-03-31: 01:00 GMT becomes 02:00 BST, so 01:00 is skipped.
    assert_equal(
        _fires("0 1 * * *", "Europe/London", "2024-03-30T12:00Z", 2),
        "2024-03-31T01:00:00,2024-04-01T00:00:00",
    )
    # 2024-10-27: 02:00 BST becomes 01:00 GMT, so 01:15 happens twice.
    assert_equal(
        _fires("15 1 * * *", "Europe/London", "2024-10-26T12:00Z", 2),
        "2024-10-27T00:15:00,2024-10-28T01:15:00",
    )


def test_fires_in_other_zones() raises:
    # India: +05:30, no daylight time.
    assert_equal(
        _fires("0 9 * * *", "Asia/Kolkata", "2024-06-01T00:00Z", 1),
        "2024-06-01T03:30:00",
    )
    # Sydney: daylight time spans the new year (AEDT +11 in January).
    assert_equal(
        _fires("0 9 1 * *", "Australia/Sydney", "2023-12-15T00:00Z", 2),
        "2023-12-31T22:00:00,2024-01-31T22:00:00",
    )
    # 2040 is past a fat file's last transition: the footer's rule applies.
    assert_equal(
        _fires("0 12 1 7 *", "America/New_York", "2040-01-01T00:00Z", 1),
        "2040-07-01T16:00:00",
    )


# --- time zones ---


def test_posix_tz() raises:
    var ny = PosixTZ.parse("EST5EDT,M3.2.0,M11.1.0")
    assert_equal(ny.offset_at(utc(2024, 3, 10, 6, 59)), -18000)
    assert_equal(ny.offset_at(utc(2024, 3, 10, 7, 0)), -14400)
    assert_equal(ny.offset_at(utc(2024, 11, 3, 5, 59)), -14400)
    assert_equal(ny.offset_at(utc(2024, 11, 3, 6, 0)), -18000)
    var uk = PosixTZ.parse("GMT0BST,M3.5.0/1,M10.5.0")
    assert_equal(uk.offset_at(utc(2024, 3, 31, 0, 59)), 0)
    assert_equal(uk.offset_at(utc(2024, 3, 31, 1, 0)), 3600)
    assert_equal(uk.offset_at(utc(2024, 10, 27, 0, 59)), 3600)
    assert_equal(uk.offset_at(utc(2024, 10, 27, 1, 0)), 0)
    var syd = PosixTZ.parse("AEST-10AEDT,M10.1.0,M4.1.0/3")
    assert_equal(syd.offset_at(utc(2024, 1, 1)), 39600)
    assert_equal(syd.offset_at(utc(2024, 7, 1)), 36000)
    assert_equal(PosixTZ.parse("<+0530>-5:30").offset_at(0), 19800)
    assert_equal(PosixTZ.parse("<-03>3").offset_at(0), -10800)
    # Julian days, without and with February 29, and an explicit DST offset.
    var j = PosixTZ.parse("AAA0BBB-2,J60/0,300/0")
    assert_equal(j.offset_at(utc(2024, 3, 1, 0, 0)), 7200)
    assert_equal(j.offset_at(utc(2024, 2, 29, 23, 59)), 0)
    # A daylight zone without rules gets the US ones.
    assert_equal(PosixTZ.parse("EST5EDT").offset_at(utc(2024, 7, 1)), -14400)
    for bad in [
        "",
        "E5",
        "EST",
        "EST25",
        "EST5EDT,M3.2.0",
        "EST5EDT,M13.1.0,M11.1.0",
        "EST5EDT,M3.6.0,M11.1.0",
        "EST5x",
    ]:
        with assert_raises(contains="tz:"):
            _ = PosixTZ.parse(bad)


def test_zone_files() raises:
    var ny = Zone.load("America/New_York")
    assert_true(len(ny.times) > 100)
    assert_equal(ny.offset_at(utc(2024, 1, 1)), -18000)
    assert_equal(ny.offset_at(utc(2024, 7, 1)), -14400)
    # Before standard time: local mean time, -4:56:02.
    assert_equal(ny.offset_at(utc(1800, 1, 1)), -17762)
    assert_equal(Zone.load("UTC").offset_at(utc(2024, 7, 1)), 0)
    for bad in [
        "",
        "/etc/passwd",
        "../etc/passwd",
        "America/../../etc",
        "No/Such_Zone",
    ]:
        with assert_raises(contains="tz:"):
            _ = Zone.load(bad)


def test_zone_rejects_bad_files() raises:
    var good: List[UInt8]
    with open("/usr/share/zoneinfo/America/New_York", "r") as f:
        good = f.read_bytes()
    _ = Zone.parse("ny", good)
    for cut in [0, 10, 44, 100, len(good) - 5]:
        var short = List[UInt8]()
        for k in range(cut):
            short.append(good[k])
        with assert_raises(contains="tz:"):
            _ = Zone.parse("ny", short)
    var wrong = good.copy()
    wrong[0] = 0
    with assert_raises(contains="not a TZif file"):
        _ = Zone.parse("ny", wrong)


# --- schedules on pipelines ---


def day_size(mut ctx: Ctx, d: Day) raises -> Int:
    return d.day


def month_size(mut ctx: Ctx, m: Month) raises -> Int:
    return m.month


comptime DaySize = Step["size", Day, Int, day_size, Mapped]
comptime MonthSize = Step["size", Month, Int, month_size, Mapped]
comptime Nightly = Pipeline[
    "nightly",
    DaySize,
    partitions=Daily[],
    schedule=Cron["30 2 * * *", "America/New_York"],
]
comptime Monthly2nd = Pipeline[
    "monthly",
    MonthSize,
    partitions=Monthly["2011-01"],
    schedule=Cron["0 3 2 * *"],
    fire=Current,
    catchup=False,
]
# `fills=` is `fire=`'s old name (#370): the same schedule.
comptime Monthly2ndOld = Pipeline[
    "monthly",
    MonthSize,
    partitions=Monthly["2011-01"],
    schedule=Cron["0 3 2 * *"],
    fills=Current,
    catchup=False,
]
comptime NightlyOld = Pipeline[
    "nightly",
    DaySize,
    partitions=Daily[],
    schedule=Cron["30 2 * * *", "America/New_York"],
    fills=Previous,
]
comptime Unscheduled = Pipeline["unscheduled", MonthSize]


def test_fire() raises:
    var s = Nightly.load_schedule()
    # 02:30 in New York on the 2nd runs the 1st; a fire at 03:00 UTC on
    # March 1 is still February 29 in New York, so it runs the 28th.
    var t = s.next_fire(utc(2024, 3, 2, 0, 0))
    assert_equal(String(Civil.of(t)), "2024-03-02T07:30:00")
    assert_equal(String(Nightly.fills_for(t, s)), "2024-03-01")
    assert_equal(
        String(Nightly.fills_for(utc(2024, 3, 1, 3, 0), s)), "2024-02-28"
    )
    var m = Monthly2nd.load_schedule()
    assert_equal(
        String(Monthly2nd.fills_for(m.next_fire(utc(2024, 1, 5)), m)), "2024-02"
    )
    with assert_raises(contains="no schedule"):
        _ = Unscheduled.load_schedule()


def test_fills_is_fire() raises:
    # A pipeline with `fills=` describes and fires as one with `fire=`.
    assert_equal(Monthly2ndOld.describe(), Monthly2nd.describe())
    assert_equal(NightlyOld.describe(), Nightly.describe())
    assert_equal(Monthly2ndOld.registry_hash(), Monthly2nd.registry_hash())
    var m = Monthly2nd.load_schedule()
    var n = Nightly.load_schedule()
    var t = utc(2024, 1, 5)
    for _ in range(30):
        t = m.next_fire(t)
        assert_equal(
            String(Monthly2ndOld.fills_for(t, m)),
            String(Monthly2nd.fills_for(t, m)),
        )
        assert_equal(
            String(NightlyOld.fills_for(t, n)), String(Nightly.fills_for(t, n))
        )


def test_describe_schedules() raises:
    assert_true(
        '"schedule": {"cron": "30 2 * * *", "tz": "America/New_York",'
        ' "fire": "previous", "fills": "previous", "catchup": true}'
        in Nightly.describe()
    )
    assert_true(
        '"schedule": {"cron": "0 3 2 * *", "tz": "UTC", "fire": "current",'
        ' "fills": "current", "catchup": false}'
        in Monthly2nd.describe()
    )
    assert_true('"schedule": null' in Unscheduled.describe())


def test_parse_time() raises:
    assert_equal(parse_time("2024-03-10T07:00Z"), utc(2024, 3, 10, 7, 0))
    assert_equal(parse_time("2024-03-10T07:00:05Z"), utc(2024, 3, 10, 7, 0) + 5)
    assert_equal(parse_time("1710054000"), utc(2024, 3, 10, 7, 0))
    for bad in [
        "2024-03-10",
        "2024-03-10T07:00",
        "2024-02-30T00:00Z",
        "2024-03-10T24:00Z",
    ]:
        with assert_raises(contains="not a time"):
            _ = parse_time(bad)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
