"""The watchdog's rules (`morca._internal.watchdog`) over made-up rows: what trips,
what each rule's scope is, and the arithmetic of the cost estimate and of
the durations a snooze takes."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from morca._internal.watchdog import (
    Counts,
    Lease,
    Quiet,
    Unmet,
    check_text,
    checks_json,
    cost_rate,
    cost_spent,
    default_config,
    eval_control,
    eval_cost,
    eval_failing,
    eval_idle,
    eval_launches,
    eval_stuck,
    eval_unmet,
    limits,
    parse_checks,
    parse_duration,
    past_names,
)


def _all() -> List[String]:
    var out: List[String] = [String("a"), String("b")]
    return out^


def test_launches() raises:
    var c = default_config()
    var ok = eval_launches(c, 200, _all())
    assert_false(ok.tripped)
    assert_equal(len(ok.pipelines), 0)
    var bad = eval_launches(c, 201, _all())
    assert_true(bad.tripped)
    assert_equal(bad.rule, "launches")
    assert_equal(len(bad.pipelines), 2)
    assert_equal(
        bad.detail, "201 instances launched in the last hour (limit 200)"
    )


def test_cost_rate_and_spend() raises:
    # c7g.4xlarge is $0.58/h: started 2 h ago and still up, one that ended
    # 30 minutes ago after running from 90 to 30 minutes ago.
    var leases: List[Lease] = [
        Lease("c7g.4xlarge", 7200.0, -1.0),
        Lease("c7g.4xlarge", 5400.0, 1800.0),
        Lease("m7g.large", 100.0, -1.0),  # unpriced
    ]
    assert_equal(Int(cost_rate(leases, 0.0, 0.0) * 1000), 580)
    assert_equal(Int(cost_rate(leases, 3600.0, 0.0) * 1000), 1160)
    assert_equal(Int(cost_rate(leases, 3600.0, 0.5) * 1000), 1660)
    # 2 h + 1 h of $0.58.
    assert_equal(Int(cost_spent(leases, 86400.0, 0.0) * 100 + 0.5), 174)
    # Only the last hour: 1 h + 30 minutes.
    assert_equal(Int(cost_spent(leases, 3600.0, 0.0) * 100 + 0.5), 87)


def test_cost_sustained_and_day() raises:
    var c = default_config()
    # 6 x $0.58 = $3.48/h, up for 20 minutes: sustained over 15 minutes.
    var up = List[Lease]()
    for _ in range(6):
        up.append(Lease("c7g.4xlarge", 1200.0, -1.0))
    var r = eval_cost(c, up, _all())
    assert_true(r.tripped)
    assert_equal(len(r.pipelines), 2)
    # The same instances up for 5 minutes are a spike, not sustained.
    var spike = List[Lease]()
    for _ in range(6):
        spike.append(Lease("c7g.4xlarge", 300.0, -1.0))
    assert_false(eval_cost(c, spike, _all()).tripped)
    # Under the rate but over $25 in 24 hours: 2 x $0.58 for 24 h = $27.84.
    var steady: List[Lease] = [
        Lease("c7g.4xlarge", 90000.0, -1.0),
        Lease("c7g.4xlarge", 90000.0, -1.0),
    ]
    var day = eval_cost(c, steady, _all())
    assert_true(day.tripped)
    assert_true("last 24 hours" in day.detail)
    assert_false("/h, over" in day.detail)
    # Nothing up: nothing to trip.
    assert_false(eval_cost(c, List[Lease](), _all()).tripped)


def test_cost_fixed_price_on_local() raises:
    var c = default_config()
    c.fixed_price = True
    var up = List[Lease]()
    for _ in range(6):
        up.append(Lease("c7g.4xlarge", 1200.0, -1.0))
    var r = eval_cost(c, up, _all())
    assert_false(r.tripped)
    assert_equal(r.detail, "fixed price")
    assert_true(r.value < 0)


def test_idle() raises:
    var c = default_config()
    var owners: List[String] = [String("a")]
    var r = eval_idle(c, 4, 9.5, owners)
    assert_true(r.tripped)
    assert_equal(r.pipelines[0], "a")
    assert_equal(len(r.pipelines), 1)
    # Too few workers, busy enough, or no samples.
    assert_false(eval_idle(c, 3, 1.0, owners).tripped)
    assert_false(eval_idle(c, 8, 15.0, owners).tripped)
    assert_false(eval_idle(c, 8, -1.0, owners).tripped)


def test_failing_is_per_pipeline() raises:
    var c = default_config()
    var counts: List[Counts] = [
        Counts("many", 21, 400),  # over 20 failed
        Counts("half", 6, 11),  # over half of at least 10
        Counts("few", 4, 5),  # all but too few attempts to judge
        Counts("fine", 3, 100),
        Counts("exact", 20, 100),  # not more than 20
        Counts("exactly-half", 5, 10),  # not more than half
    ]
    var r = eval_failing(c, counts)
    assert_true(r.tripped)
    assert_equal(len(r.pipelines), 2)
    assert_equal(r.pipelines[0], "many")
    assert_equal(r.pipelines[1], "half")
    assert_equal(Int(r.value), 21)
    assert_false(eval_failing(c, List[Counts]()).tripped)


def test_stuck_scopes_to_the_pipeline() raises:
    var c = default_config()
    var runs: List[Quiet] = [
        Quiet("a", 7, 31.0),
        Quiet("a", 8, 45.0),
        Quiet("b", 9, 29.9),
    ]
    var r = eval_stuck(c, runs)
    assert_true(r.tripped)
    assert_equal(len(r.pipelines), 1)
    assert_equal(r.pipelines[0], "a")
    assert_equal(Int(r.value), 45)
    var calm: List[Quiet] = [Quiet("b", 9, 29.9)]
    assert_false(eval_stuck(c, calm).tripped)


def test_unmet_scopes_to_the_pipeline() raises:
    # A run waiting for more than the host can grant at all (#462): its
    # pipeline, once it has waited unmet_minutes.
    var c = default_config()
    var why = "needs 64 GB, more than the 2.5 GB this host grants at most"
    var runs: List[Unmet] = [
        Unmet("a", 7, 12.0, why),
        Unmet("b", 9, 3.0, why),
    ]
    var r = eval_unmet(c, runs)
    assert_true(r.tripped)
    assert_equal(len(r.pipelines), 1)
    assert_equal(r.pipelines[0], "a")
    assert_equal(r.detail, String("a run 7 ", why, ", for 12 minutes"))
    var soon: List[Unmet] = [Unmet("b", 9, 9.9, why)]
    assert_false(eval_unmet(c, soon).tripped)
    assert_false(eval_unmet(c, List[Unmet]()).tripped)


def test_control() raises:
    var c = default_config()
    assert_false(eval_control(c, True, 89.0, 84.0, _all()).tripped)
    var mem = eval_control(c, True, 91.0, 10.0, _all())
    assert_true(mem.tripped)
    assert_true("memory" in mem.detail and "disk" not in mem.detail)
    assert_equal(len(mem.pipelines), 2)
    var disk = eval_control(c, True, 10.0, 86.0, _all())
    assert_true(disk.tripped and "disk" in disk.detail)
    assert_equal(Int(disk.threshold), 85)
    # No fresh samples: nothing to judge.
    var none = eval_control(c, False, 0.0, 0.0, _all())
    assert_false(none.tripped)
    assert_true(none.value < 0)
    assert_equal(len(none.checks), 2)
    assert_true(none.checks[0].value < 0 and none.checks[1].value < 0)


def test_control_checks_both_thresholds() raises:
    # Memory past 90 while disk, nearer its 85 relatively, is fine: both
    # thresholds are kept, and memory is the one past.
    var c = default_config()
    var r = eval_control(c, True, 98.3, 10.6, _all())
    assert_equal(len(r.checks), 2)
    assert_equal(r.checks[0].name, "memory")
    assert_equal(Int(r.checks[0].limit), 90)
    assert_true(r.checks[0].past)
    assert_equal(r.checks[1].name, "disk")
    assert_equal(Int(r.checks[1].limit), 85)
    assert_false(r.checks[1].past)
    var on = past_names(r.checks)
    assert_equal(len(on), 1)
    assert_equal(on[0], "memory")
    assert_equal(
        check_text(r.checks[0]), "memory 98.30 % (trips over 90.00, past)"
    )
    assert_equal(check_text(r.checks[1]), "disk 10.60 % (trips over 85.00)")
    # What the tables keep reads back the same.
    var back = parse_checks(checks_json(r.checks))
    assert_equal(len(back), 2)
    assert_equal(back[0].name, "memory")
    assert_true(back[0].past and not back[1].past)
    assert_equal(Int(back[1].limit), 85)
    assert_equal(back[1].unit, " %")
    assert_equal(back[1].op, "over")
    assert_equal(len(parse_checks("")), 0)


def test_checks_of_each_rule() raises:
    var c = default_config()
    var cost = eval_cost(c, List[Lease](), _all())
    assert_equal(len(cost.checks), 2)
    assert_equal(cost.checks[0].name, "rate for 15m")
    assert_equal(Int(cost.checks[1].limit), 25)
    var many: List[Counts] = [Counts("a", 21, 100), Counts("b", 6, 10)]
    var f = eval_failing(c, many)
    assert_true(f.checks[0].past)  # a: 21 failed
    assert_true(f.checks[1].past)  # b: 60%
    assert_equal(Int(f.checks[1].value), 60)
    var few: List[Counts] = [Counts("a", 2, 3)]
    var g = eval_failing(c, few)
    assert_true(g.checks[1].value < 0)  # under failed_min: no share
    var idle = eval_idle(c, 3, 4.0, _all())
    assert_true(idle.checks[0].past and not idle.checks[1].past)
    assert_false(idle.tripped)
    assert_equal(idle.checks[1].op, "at least")
    for rule in [
        "launches",
        "cost",
        "idle",
        "failing",
        "stuck",
        "unmet",
        "control",
    ]:
        assert_true(len(limits(c, String(rule))) > 0)


def test_durations() raises:
    assert_equal(parse_duration("90s"), 90)
    assert_equal(parse_duration("30m"), 1800)
    assert_equal(parse_duration("2h"), 7200)
    assert_equal(parse_duration("1d"), 86400)
    assert_equal(parse_duration("off"), 0)
    for bad in ["", "h", "2", "0h", "-1h", "2x", "31d", "xh"]:
        var raised = False
        try:
            _ = parse_duration(String(bad))
        except:
            raised = True
        assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
