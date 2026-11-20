"""Fills (`morca._internal.fill`): what the keys take, the window, the range a fill
covers, the price of a run, and which pipelines can't fill."""

from std.os import setenv, unsetenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from morca.civil import parse_time
from morca._internal.fill import (
    Fill,
    eta_text,
    FillStatus,
    COST_MARGIN,
    budget_slots,
    fill_refusal,
    lag_note,
    lag_text,
    lag_wait,
    last_ended,
    money,
    parse_fill_budget,
    parse_fill_lag,
    parse_fill_max_runs,
    parse_fill_order,
    parse_fill_window,
    parse_fills,
    range_keys,
    run_hourly,
    unknown_type,
)
from morca._internal.kube_price import (
    KubePrice,
    cost_text,
    kube_price,
    kube_requests,
    memory_mb,
    pods,
)


def test_values() raises:
    assert_equal(parse_fills("all"), "all")
    assert_equal(parse_fills("since_registration"), "since_registration")
    try:
        _ = parse_fills("everything")
        raise Error("accepted fills = everything")
    except e:
        assert_true("since_registration" in String(e), String(e))
    assert_equal(parse_fill_order("newest"), "newest")
    try:
        _ = parse_fill_order("random")
        raise Error("accepted fill_order = random")
    except e:
        assert_true("oldest" in String(e), String(e))
    assert_equal(parse_fill_max_runs("3"), 3)
    assert_equal(parse_fill_budget("2.5"), 2.5)
    assert_equal(parse_fill_budget("0"), 0.0)
    try:
        _ = parse_fill_budget("-1")
        raise Error("a negative budget")
    except e:
        assert_true("from 0" in String(e), String(e))
    var w = parse_fill_window("22..6")
    assert_equal(w[0], 22)
    assert_equal(w[1], 6)
    for bad in ["6", "6..6", "24..2", "1..25", "a..b", "-1..3"]:
        try:
            _ = parse_fill_window(bad)
            raise Error("accepted the window ", bad)
        except e:
            assert_true("UTC hours" in String(e), String(e))


def test_window() raises:
    var night = Fill.of("all", "", 0, -1.0, "22..6")
    assert_true(night.in_window(22))
    assert_true(night.in_window(0))
    assert_true(night.in_window(5))
    assert_false(night.in_window(6))
    assert_false(night.in_window(12))
    assert_equal(night.window_text(), "22:00–06:00 UTC")
    var day = Fill.of("all", "", 0, -1.0, "9..17")
    assert_true(day.in_window(9))
    assert_false(day.in_window(17))
    var always = Fill.of("all", "", 0, -1.0, "")
    for h in range(24):
        assert_true(always.in_window(h))
    assert_equal(always.window_text(), "all day")
    assert_equal(always.max_runs, 1)
    assert_false(always.newest_first)
    assert_false(Fill.of("", "", 0, -1.0, "").all)


def test_range() raises:
    var t = parse_time("2024-07-15T12:00Z")
    assert_equal(last_ended("monthly", "UTC", t), "2024-06")
    assert_equal(last_ended("daily", "UTC", t), "2024-07-14")
    var months = range_keys("monthly", "2024-01", "UTC", t)
    assert_equal(len(months), 6)
    assert_equal(months[0], "2024-01")
    assert_equal(months[5], "2024-06")
    # On the schedule's wall clock: 02:00Z on the 1st is still the 31st
    # in New York.
    var early = parse_time("2024-03-01T02:00Z")
    assert_equal(last_ended("daily", "America/New_York", early), "2024-02-28")
    assert_equal(last_ended("daily", "UTC", early), "2024-02-29")
    # Nothing has ended yet.
    assert_equal(len(range_keys("monthly", "2024-07", "UTC", t)), 0)
    assert_equal(len(range_keys("daily", "", "UTC", t)), 0)


def test_range_hourly() raises:
    var t = parse_time("2024-03-01T02:30Z")
    assert_equal(last_ended("hourly", "UTC", t), "2024-03-01T01")
    var hours = range_keys("hourly", "2024-02-29T22", "UTC", t)
    assert_equal(len(hours), 4)
    assert_equal(hours[0], "2024-02-29T22")
    assert_equal(hours[3], "2024-03-01T01")
    # A lag of 45 minutes: 01:00-02:00 ended 30 minutes ago and waits.
    assert_equal(last_ended("hourly", "UTC", t, 45 * 60), "2024-03-01T00")
    var w = lag_wait("hourly", "UTC", t, 45 * 60)
    assert_equal(w[0], "2024-03-01T01")
    assert_equal(w[1], parse_time("2024-03-01T02:45Z"))
    assert_equal(fill_refusal("hourly", "2024-01-01T00", False, "p"), "")


def test_range_weekly() raises:
    # Wednesday 2026-11-18 is in 2026-W47: W46 is the last that ended.
    var t = parse_time("2026-11-18T10:00Z")
    assert_equal(last_ended("weekly", "UTC", t), "2026-W46")
    var weeks = range_keys("weekly", "2026-W44", "UTC", t)
    assert_equal(len(weeks), 3)
    assert_equal(weeks[0], "2026-W44")
    assert_equal(weeks[2], "2026-W46")
    # Across New Year, through a 53-week year.
    var ny = range_keys(
        "weekly", "2026-W52", "UTC", parse_time("2027-01-12T00:00Z")
    )
    assert_equal(len(ny), 3)
    assert_equal(ny[1], "2026-W53")
    assert_equal(ny[2], "2027-W01")
    # A week ends at Monday 00:00 on the schedule's clock: 03:00 UTC is
    # still Sunday in New York.
    var mon = parse_time("2026-11-16T03:00Z")
    assert_equal(last_ended("weekly", "UTC", mon), "2026-W46")
    assert_equal(last_ended("weekly", "America/New_York", mon), "2026-W45")
    # A lag of 2 hours: W46 ended an hour ago and waits until 02:00.
    var early = parse_time("2026-11-16T01:00Z")
    assert_equal(last_ended("weekly", "UTC", early, 7200), "2026-W45")
    var w = lag_wait("weekly", "UTC", early, 7200)
    assert_equal(w[0], "2026-W46")
    assert_equal(w[1], parse_time("2026-11-16T02:00Z"))
    assert_equal(fill_refusal("weekly", "2026-W01", False, "p"), "")


def test_lag_values() raises:
    assert_equal(parse_fill_lag("0"), 0)
    assert_equal(parse_fill_lag("2h"), 7200)
    assert_equal(parse_fill_lag("90m"), 5400)
    assert_equal(parse_fill_lag("45s"), 45)
    assert_equal(parse_fill_lag("1d"), 86400)
    assert_equal(parse_fill_lag("31d"), 31 * 86400)
    for bad in ["", "2", "h", "2w", "-1h", "1.5h", "32d", "2 h"]:
        try:
            _ = parse_fill_lag(bad)
            raise Error("accepted the lag ", bad)
        except e:
            assert_true(
                "duration" in String(e) or "at most" in String(e), String(e)
            )
    assert_equal(lag_text(0), "0")
    assert_equal(lag_text(7200), "2h")
    assert_equal(lag_text(5400), "90m")
    assert_equal(lag_text(45), "45s")
    assert_equal(Fill.of("all", "", 0, -1.0, "").lag, 0)
    assert_equal(Fill.of("all", "", 0, -1.0, "", "2h").lag, 7200)


def test_lag_daily() raises:
    """Day D fills from D+1 00:00 plus the lag: not a second before."""
    var lag = 7200
    var just_before = parse_time("2026-11-10T01:59:59Z")
    var at = parse_time("2026-11-10T02:00:00Z")
    assert_equal(last_ended("daily", "UTC", just_before, lag), "2026-11-08")
    assert_equal(last_ended("daily", "UTC", at, lag), "2026-11-09")
    var before = range_keys("daily", "2026-11-01", "UTC", just_before, lag)
    assert_equal(len(before), 8)
    assert_equal(before[7], "2026-11-08")
    var after = range_keys("daily", "2026-11-01", "UTC", at, lag)
    assert_equal(len(after), 9)
    assert_equal(after[8], "2026-11-09")
    # No lag: what it was, the day fills at 00:00.
    assert_equal(
        last_ended("daily", "UTC", parse_time("2026-11-10T00:00:00Z")),
        "2026-11-09",
    )
    # Which day waits, and until when.
    var w = lag_wait("daily", "UTC", just_before, lag)
    assert_equal(w[0], "2026-11-09")
    assert_equal(w[1], at)
    w = lag_wait("daily", "UTC", parse_time("2026-11-10T00:00:00Z"), lag)
    assert_equal(w[0], "2026-11-09")
    assert_equal(w[1], at)
    assert_equal(lag_wait("daily", "UTC", at, lag)[0], "")
    assert_equal(lag_wait("daily", "UTC", just_before, 0)[0], "")
    # On the schedule's clock: New York's midnight is 05:00Z in winter.
    var ny = "America/New_York"
    assert_equal(
        last_ended("daily", ny, parse_time("2026-11-10T06:59:59Z"), lag),
        "2026-11-08",
    )
    assert_equal(
        last_ended("daily", ny, parse_time("2026-11-10T07:00:00Z"), lag),
        "2026-11-09",
    )
    w = lag_wait("daily", ny, parse_time("2026-11-10T05:30:00Z"), lag)
    assert_equal(w[0], "2026-11-09")
    assert_equal(w[1], parse_time("2026-11-10T07:00:00Z"))
    # A lag longer than a day: the oldest that waits.
    w = lag_wait("daily", "UTC", parse_time("2026-11-10T12:00:00Z"), 2 * 86400)
    assert_equal(w[0], "2026-11-08")
    assert_equal(w[1], parse_time("2026-11-11T00:00:00Z"))


def test_lag_monthly() raises:
    var lag = 5400
    var just_before = parse_time("2026-12-01T01:29:59Z")
    var at = parse_time("2026-12-01T01:30:00Z")
    assert_equal(last_ended("monthly", "UTC", just_before, lag), "2026-10")
    assert_equal(last_ended("monthly", "UTC", at, lag), "2026-11")
    assert_equal(
        len(range_keys("monthly", "2026-01", "UTC", just_before, lag)), 10
    )
    assert_equal(len(range_keys("monthly", "2026-01", "UTC", at, lag)), 11)
    var w = lag_wait("monthly", "UTC", just_before, lag)
    assert_equal(w[0], "2026-11")
    assert_equal(w[1], at)
    # Keyed pipelines have no calendar: nothing waits.
    assert_equal(lag_wait("keyed", "UTC", at, lag)[0], "")


def test_lag_note() raises:
    var s = FillStatus()
    assert_equal(lag_note(s), "")
    s.lag_key = "2026-11-09"
    s.lag_until = parse_time("2026-11-10T02:00:00Z")
    s.lag = 7200
    assert_equal(
        lag_note(s), "2026-11-09 fills from 2026-11-10 02:00 UTC (fill_lag 2h)"
    )


def test_prices() raises:
    assert_equal(run_hourly("control", "x9g.huge", "", 4), 0.0)
    assert_equal(run_hourly("local", "", "", 4), 0.0)
    # A worker pool's machines run anyway.
    assert_equal(run_hourly("worker:gharchive", "x9g.huge", "", 4), 0.0)
    _unset_kube()
    assert_true(run_hourly("kubernetes", "", "", 0) < 0)
    # A head and its most workers.
    var p = run_hourly("ec2", "t4g.medium", "c7g.xlarge", 4)
    assert_true(p > 0.6133 and p < 0.6137, String(p))
    assert_equal(run_hourly("ec2", "c7g.large", "x9g.huge", 0), 0.0725)
    assert_true(run_hourly("ec2", "c7g.large", "x9g.huge", 2) < 0)
    assert_true(run_hourly("ec2", "x9g.huge", "", 0) < 0)
    assert_equal(unknown_type("ec2", "x9g.huge", "", 0), "x9g.huge")
    assert_equal(unknown_type("ec2", "c7g.large", "x9g.huge", 2), "x9g.huge")
    assert_equal(unknown_type("ec2", "c7g.large", "c7g.xlarge", 2), "")
    assert_equal(money(0.0), "$0.00")
    assert_equal(money(1.006), "$1.01")
    assert_equal(money(12.3), "$12.30")
    assert_equal(eta_text(-1), "unknown")
    assert_equal(eta_text(30), "1m")
    assert_equal(eta_text(7260), "2h 1m")
    assert_equal(eta_text(3 * 86400 + 7200), "3d 2h")


def _near(got: Float64, want: Float64) raises:
    assert_true(abs(got - want) < 1e-9, String(got, " is not ", want))


def _unset_kube():
    for n in [
        "MORCA_KUBE_PRICE_VCPU_HOUR",
        "MORCA_KUBE_PRICE_GB_HOUR",
        "MORCA_DRIVER_CPU",
        "MORCA_HEAD_CPU",
        "MORCA_WORKER_CPU",
        "MORCA_POD_MEMORY",
    ]:
        _ = unsetenv(n)


def test_kube_cost() raises:
    """A Kubernetes run's cost: its pods' requests and how long it ran, at
    the stack's prices (#564)."""
    assert_equal(memory_mb("512Mi"), 512)
    assert_equal(memory_mb("2Gi"), 2048)
    assert_equal(memory_mb("1G"), 954)  # 10^9 bytes, rounded up
    assert_equal(memory_mb("1048576"), 1)
    assert_equal(pods(0), 1)
    assert_equal(pods(3), 5)
    # A vCPU at 4 cents and a GiB at half a cent an hour.
    var p = KubePrice(0.04, 0.005)
    _near(p.hourly(2000, 4096), 0.08 + 0.02)
    _near(p.cost(2000, 4096, 1800.0), 0.05)
    # One price set: the other counts nothing.
    _near(KubePrice(0.04, -1.0).cost(1000, 1024, 3600.0), 0.04)
    # Neither: unpriced.
    assert_true(KubePrice(-1.0, -1.0).cost(1000, 1024, 3600.0) < 0)
    assert_equal(cost_text(0.05), "$0.0500")
    assert_equal(cost_text(12.345), "$12.35")
    _unset_kube()
    assert_false(kube_price().priced())
    # Unset, Kubernetes runs have no price, as before.
    assert_true(run_hourly("kubernetes", "", "", 3) < 0)
    _ = setenv("MORCA_KUBE_PRICE_VCPU_HOUR", "0.04", True)
    _ = setenv("MORCA_KUBE_PRICE_GB_HOUR", "0.005", True)
    # The runner's defaults: a driver of 500m and 512Mi alone, or with a
    # head (250m) and 3 workers (1 each), 5 pods of 512Mi.
    var q = kube_requests(0)
    assert_equal(q.cpu_millis, 500)
    assert_equal(q.memory_mb, 512)
    q = kube_requests(3)
    assert_equal(q.cpu_millis, 3750)
    assert_equal(q.memory_mb, 2560)
    _near(run_hourly("kubernetes", "", "", 3), 3.75 * 0.04 + 2.5 * 0.005)
    _ = setenv("MORCA_POD_MEMORY", "1Gi", True)
    _ = setenv("MORCA_DRIVER_CPU", "2", True)
    _near(run_hourly("kubernetes", "", "", 0), 2 * 0.04 + 0.005)
    # A price that isn't a number fails closed.
    _ = setenv("MORCA_KUBE_PRICE_VCPU_HOUR", "four cents", True)
    _ = unsetenv("MORCA_KUBE_PRICE_GB_HOUR")
    assert_true(run_hourly("kubernetes", "", "", 0) < 0)
    _unset_kube()


def test_kube_fill_on_budget() raises:
    """With a price set, a budgeted fill on Kubernetes starts, and stops
    once its runs have spent the day's budget."""
    _unset_kube()
    _ = setenv("MORCA_KUBE_PRICE_VCPU_HOUR", "0.04", True)
    _ = setenv("MORCA_KUBE_PRICE_GB_HOUR", "0.005", True)
    var hourly = run_hourly("kubernetes", "", "", 3)  # $0.1625
    assert_true(hourly > 0)
    var q = kube_requests(3)
    var price = kube_price()
    var budget = 0.5
    var expected = 3600
    var spent = 0.0
    var started = 0
    # Each pass: a run of an hour may start if one more fits; once it has
    # run, its pods' hour is spent.
    while True:
        var next_cost = COST_MARGIN * hourly * Float64(expected) / 3600.0
        var slots = budget_slots(1, budget, spent, next_cost, hourly, expected)
        if slots == 0:
            break
        started += 1
        spent += COST_MARGIN * price.cost(
            q.cpu_millis, q.memory_mb, Float64(expected)
        )
        assert_true(started < 10, "never stopped")
    # $0.195 a run with the margin: two fit in $0.50, a third doesn't.
    assert_equal(started, 2)
    assert_true(spent <= budget, String(spent))
    # The slots a budget holds: room for two more after none spent.
    assert_equal(budget_slots(4, budget, 0.0, 0.195, hourly, expected), 2)
    _unset_kube()


def test_who_fills() raises:
    assert_equal(fill_refusal("daily", "2023-01-01", False, "gharchive"), "")
    assert_equal(fill_refusal("monthly", "2024-01", False, "toy"), "")
    assert_true("keyed" in fill_refusal("keyed", "", False, "labels"))
    assert_true("sensor" in fill_refusal("daily", "2024-01-01", True, "s"))
    assert_true("first partition" in fill_refusal("daily", "", False, "d"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
