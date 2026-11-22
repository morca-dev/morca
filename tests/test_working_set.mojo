"""The working-set probe (morca.working_set): the controller, which runs it
probes, and the arithmetic, without cgroups (tests/cgroups.sh probes a run
on Linux)."""

from std.os import setenv, unsetenv
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from morca._internal.cgroup import max_mb
from morca._internal.working_set import (
    MIN_SAMPLES,
    Probe,
    ProbeKnobs,
    limit_of_max,
    pressure_pct,
    probed,
)


def _k() -> ProbeKnobs:
    # Target 0.1%, steps of 2%, floor 50%.
    return ProbeKnobs.defaults()


def _low() -> ProbeKnobs:
    # The same with a floor of 10%.
    return ProbeKnobs(5.0, 0.1, 2, 10)


def test_lowers_a_step_at_a_time() raises:
    # A 1000 MB limit, the run at 300 MB, no pressure: down 20 MB a step.
    var p = Probe.of(1000)
    p = p.next(300, 0.0, _k())
    assert_equal(p.high_mb, 980)
    p = p.next(300, 0.0, _k())
    assert_equal(p.high_mb, 960)
    # At the limit it measured nothing; lowered, it does.
    assert_equal(p.samples, 1)
    assert_equal(p.lowest_mb, 980)


def test_never_under_the_floor() raises:
    # Half the limit, though the run uses less.
    var p = Probe.at(1000, 510)
    p = p.next(100, 0.0, _k())
    assert_equal(p.high_mb, 500)
    p = p.next(100, 0.0, _k())
    assert_equal(p.high_mb, 500)
    # Nor more than a step under what the run uses now.
    var q = Probe.at(1000, 800)
    q = q.next(790, 0.0, _k())
    assert_equal(q.high_mb, 780)
    q = q.next(780, 0.0, _k())
    assert_equal(q.high_mb, 760)


def test_backs_off_on_pressure() raises:
    # Over the target: up four steps, and the wall where it was.
    var p = Probe.at(1000, 700)
    p = p.next(700, 0.5, _k())
    assert_equal(p.high_mb, 780)
    assert_equal(p.wall_mb, 700)
    # It needed more than 700: a step more is its working set so far.
    assert_equal(p.need_mb, 720)
    assert_equal(p.working_set_mb(), 720)
    # Then it goes down no further than a step over the wall.
    p = p.next(600, 0.0, _k())
    assert_equal(p.high_mb, 760)
    p = p.next(600, 0.0, _k())
    assert_equal(p.high_mb, 740)
    p = p.next(600, 0.0, _k())
    assert_equal(p.high_mb, 720)
    p = p.next(600, 0.0, _k())
    assert_equal(p.high_mb, 720)


def test_panic_gives_the_limit_back() raises:
    # Ten times the target: the limit at once.
    var p = Probe.at(1000, 600)
    p = p.next(600, 1.0, _k())
    assert_equal(p.high_mb, 1000)
    assert_equal(p.wall_mb, 600)
    # Near the limit already, four steps don't pass it.
    var q = Probe.at(1000, 960)
    q = q.next(960, 0.5, _k())
    assert_equal(q.high_mb, 1000)


def test_at_its_limit_is_not_probed() raises:
    # A run using 95% of its limit gets all of it: lower would throttle it,
    # and the held check (#279) looks at the limit.
    var p = Probe.at(1000, 990)
    p = p.next(960, 0.0, _k())
    assert_equal(p.high_mb, 1000)
    # Never over the limit, and never lowered when it's there.
    p = p.next(990, 0.0, _k())
    assert_equal(p.high_mb, 1000)


def test_unreadable_gives_the_limit_back() raises:
    var p = Probe(1000, 600, 0, 600, 0, 4)
    assert_equal(p.next(-1, 0.0, _k()).high_mb, 1000)
    assert_equal(p.next(500, -1.0, _k()).high_mb, 1000)
    # What it measured stays.
    assert_equal(p.next(500, -1.0, _k()).result_mb(), 600)


def test_at_the_target_is_lowered() raises:
    # At the target exactly is within it; just over is pressure.
    var p = Probe.at(1000, 800)
    assert_equal(p.next(500, 0.1, _k()).high_mb, 780)
    assert_equal(p.next(500, 0.11, _k()).high_mb, 880)


def test_working_set_is_the_lowest_held() raises:
    # Lowered at the target, the lowest it held is its working set, not
    # the most it touched.
    var p = Probe.at(1000, 500)
    p = p.next(500, 0.0, _low())  # to 480
    p = p.next(480, 0.0, _low())  # to 460
    assert_equal(p.lowest_mb, 480)
    assert_equal(p.working_set_mb(), 480)


def test_a_later_phase_raises_it() raises:
    # Held at 300 in a small phase, then a larger one stalls it at 280,
    # 360 and 440: it needed more than 440.
    var p = Probe.at(1000, 300)
    p = p.next(290, 0.0, _low())
    assert_equal(p.lowest_mb, 300)
    assert_equal(p.high_mb, 280)
    p = p.next(280, 0.5, _low())
    p = p.next(360, 0.5, _low())
    p = p.next(440, 0.5, _low())
    assert_equal(p.wall_mb, 440)
    assert_equal(p.high_mb, 520)
    assert_equal(p.working_set_mb(), 460)


def test_pressure_at_the_limit_needs_the_limit() raises:
    # A grant already too small: it's no working set under it.
    var p = Probe.of(1000)
    for _ in range(MIN_SAMPLES):
        p = p.next(990, 0.5, _k())
    assert_equal(p.high_mb, 1000)
    assert_equal(p.result_mb(), 1000)


def test_too_few_samples_is_none() raises:
    var p = Probe.of(1000)
    assert_equal(p.result_mb(), -1)
    for _ in range(MIN_SAMPLES):
        p = p.next(300, 0.0, _k())
    # The first interval was at the limit: one short.
    assert_equal(p.samples, MIN_SAMPLES - 1)
    assert_equal(p.result_mb(), -1)
    p = p.next(300, 0.0, _k())
    assert_equal(p.result_mb(), 940)


def test_converges_on_a_run() raises:
    # A run with 400 MB it needs (more stalls it) and 300 MB of cache it
    # doesn't, at a 1000 MB limit (a floor of 10%): the probe settles over 400 MB, never
    # holding the run under it for more than an interval, and learns 400.
    var p = Probe.of(1000)
    var stalled = 0
    for _ in range(200):
        var usage = min(700, p.high_mb)
        var pressure = 5.0 if p.high_mb < 400 else 0.0
        if p.high_mb < 400:
            stalled += 1
        p = p.next(usage, pressure, _low())
    assert_true(p.high_mb >= 400 and p.high_mb <= 440, String(p.high_mb))
    assert_true(stalled <= 1, String(stalled))
    assert_equal(p.result_mb(), 400)


def test_pressure_pct() raises:
    # 5 ms of 5 s is 0.1%.
    assert_equal(pressure_pct(5000, 5_000_000_000), 0.1)
    assert_equal(pressure_pct(0, 5_000_000_000), 0.0)
    assert_equal(pressure_pct(-1, 5_000_000_000), -1.0)
    assert_equal(pressure_pct(10, 0), -1.0)


def test_limit_of_max() raises:
    for m in [0, 25, 33, 100]:
        for l in [1, 64, 100, 101, 1000, 2047, 3000]:
            assert_equal(limit_of_max(max_mb(l, m), m), l)


def test_probed() raises:
    assert_false(probed(7, 1, 0))
    assert_true(probed(7, 1, 1))
    # Never a retry.
    assert_false(probed(7, 2, 1))
    # About one in four, and not one remainder for runs four apart.
    var n = 0
    var apart = 0
    for run in range(1, 4001):
        if probed(run, 1, 4):
            n += 1
    for run in range(3, 4003, 4):
        if probed(run, 1, 4):
            apart += 1
    assert_true(n > 850 and n < 1150, String(n))
    assert_true(apart > 200 and apart < 300, String(apart))


def test_knobs_from_env() raises:
    var k = ProbeKnobs.from_env()
    assert_equal(k.every_s, 5.0)
    assert_equal(k.target_pct, 0.1)
    assert_equal(k.step_pct, 2)
    assert_equal(k.floor_pct, 50)
    _ = setenv("MORCA_RUN_PROBE_FLOOR", "5")
    with assert_raises(contains="MORCA_RUN_PROBE_FLOOR"):
        _ = ProbeKnobs.from_env()
    _ = setenv("MORCA_RUN_PROBE_FLOOR", "70")
    _ = setenv("MORCA_RUN_PROBE_SECONDS", "1")
    k = ProbeKnobs.from_env()
    assert_equal(k.floor_pct, 70)
    assert_equal(k.every_s, 1.0)
    _ = unsetenv("MORCA_RUN_PROBE_FLOOR")
    _ = unsetenv("MORCA_RUN_PROBE_SECONDS")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
