"""Requests learned from the measured peaks (morca.recommend): the
percentiles, the margin and its rounding, too few runs, the floor an
out-of-memory raised, and the clamp to the declared range."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from morca._internal.recommend import (
    DECLARED,
    DEFAULT,
    LEARNED,
    MIN_RUNS,
    Recommendation,
    RunPeaks,
    memory_gb_text,
    percentile,
    recommend,
    resolve_request,
)
from morca._internal.resources import Request, Room, admit

comptime MB = 1048576.0


def _runs(mb: List[Int], cores: Float64 = 2.0) -> List[RunPeaks]:
    var out = List[RunPeaks]()
    for m in mb:
        out.append(RunPeaks(Float64(m) * MB, cores))
    return out^


def _none() -> Request:
    return Request(0, 0, 0, 0)


def test_percentile() raises:
    assert_equal(percentile(List[Float64](), 0.95), -1.0)
    assert_equal(percentile([5.0], 0.95), 5.0)
    # Nearest rank: of 20, p95 is the 19th, p90 the 18th.
    var xs = List[Float64]()
    for i in range(20, 0, -1):
        xs.append(Float64(i))
    assert_equal(percentile(xs.copy(), 0.95), 19.0)
    assert_equal(percentile(xs.copy(), 0.90), 18.0)
    assert_equal(percentile(xs.copy(), 0.5), 10.0)
    # Of 3, p95 is the largest.
    assert_equal(percentile([1.0, 3.0, 2.0], 0.95), 3.0)


def test_memory_gb_text() raises:
    assert_equal(memory_gb_text(3328), "3.25")
    assert_equal(memory_gb_text(3584), "3.5")
    assert_equal(memory_gb_text(4096), "4")
    assert_equal(memory_gb_text(256), "0.25")


def test_too_few_runs() raises:
    var r = recommend(_runs([1000, 1000]), 0, _none())
    assert_false(r.any())
    assert_equal(r.runs, 2)
    assert_equal(r.memory_mb, 0)
    assert_equal(r.cpus, 0)
    assert_true("2 of the 3" in r.text())
    assert_true('"memory_mb": null' in r.json())
    # Runs without a measured peak don't count.
    var p = _runs([1000, 1000])
    p.append(RunPeaks(-1, 2.0))
    assert_equal(recommend(p, 0, _none()).runs, 2)
    assert_equal(MIN_RUNS, 3)


def test_margin_and_rounding() raises:
    # 2000 MB × 1.15 = 2300 MB, up to 2304 (9 quarter GBs).
    var r = recommend(_runs([1000, 2000, 1500]), 0, _none())
    assert_equal(r.runs, 3)
    assert_equal(r.memory_mb, 2304)
    assert_equal(r.cpus, 2)
    assert_equal(r.clamped, "")
    assert_equal(r.text(), "learned from 3 runs: 2.25 GB, 2 CPUs")
    assert_equal(
        r.source,
        "p95 of the runs' peak memory × 1.15; p90 of their peak cores",
    )
    assert_true('"applied": false' in r.json())
    # p95 of 20 skips the one largest run: 19 runs of 1000 MB and one of
    # 9000 give 1000 × 1.15 = 1150, up to 1280.
    var mb = List[Int]()
    for _ in range(19):
        mb.append(1000)
    mb.append(9000)
    assert_equal(recommend(_runs(mb), 0, _none()).memory_mb, 1280)
    # Tiny runs get a quarter GB.
    assert_equal(recommend(_runs([1, 1, 1]), 0, _none()).memory_mb, 256)


def test_cpus() raises:
    # Rounded up, less the sampling's slack, at least 1.
    assert_equal(recommend(_runs([100, 100, 100], 2.05), 0, _none()).cpus, 2)
    assert_equal(recommend(_runs([100, 100, 100], 2.3), 0, _none()).cpus, 3)
    assert_equal(recommend(_runs([100, 100, 100], 0.2), 0, _none()).cpus, 1)
    # p90 of 10: the 9th.
    var p = List[RunPeaks]()
    for i in range(1, 11):
        p.append(RunPeaks(100 * MB, Float64(i)))
    assert_equal(recommend(p, 0, _none()).cpus, 9)
    # Not measured (macOS): memory only.
    var r = recommend(_runs([100, 100, 100], -1), 0, _none())
    assert_equal(r.cpus, 0)
    assert_equal(r.cpu_runs, 0)
    assert_equal(r.text(), "learned from 3 runs: 0.25 GB")


def test_never_below_the_oom_bump() raises:
    var r = recommend(_runs([1000, 1000, 1000]), 3072, _none())
    assert_equal(r.memory_mb, 3072)
    assert_true("out-of-memory" in r.source)
    # A bump below what the peaks give changes nothing.
    assert_equal(
        recommend(_runs([1000, 1000, 1000]), 512, _none()).memory_mb, 1280
    )


def test_clamped_to_the_declared_range() raises:
    var req = Request.of("1..2", "2..3")
    var r = recommend(_runs([4000, 4000, 4000], 6.0), 0, req)
    assert_equal(r.memory_mb, 3072)
    assert_equal(r.cpus, 2)
    assert_equal(r.clamped, "memory_gb's maximum and cpus' maximum")
    assert_equal(
        r.text(),
        (
            "learned from 3 runs: 3 GB, 2 CPUs (clamped to memory_gb's"
            " maximum and cpus' maximum)"
        ),
    )
    var low = recommend(_runs([100, 100, 100], 1.0), 0, Request.of("2..4", "2"))
    assert_equal(low.memory_mb, 2048)
    assert_equal(low.cpus, 2)
    assert_equal(low.clamped, "memory_gb's minimum and cpus' minimum")
    # Within the range, it isn't.
    assert_equal(recommend(_runs([2000, 2000, 2000]), 0, req).clamped, "")
    # The OOM bump is clamped too.
    assert_equal(recommend(_runs([100, 100, 100]), 9999, req).memory_mb, 3072)


def test_auto_is_learned() raises:
    var auto = Request.of("auto", "auto")
    var rec = recommend(_runs([1000, 2000, 1500], 2.3), 0, auto)
    var r = resolve_request(auto, rec, True)
    assert_equal(r.source, LEARNED)
    assert_equal(r.runs, 3)
    assert_false(r.request.auto())
    # 2000 MB × 1.15 in quarter GBs, and p90 of 2.3 cores: its min and max.
    assert_equal(r.request.memory_min_mb, 2304)
    assert_equal(r.request.memory_max_mb, 2304)
    assert_equal(r.request.cpus_min, 3)
    assert_equal(r.request.cpus_max, 3)
    assert_equal(r.memory_gb_text(), "2.25")
    assert_equal(r.text(), "learned from 3 runs")
    # Above an out-of-memory bump, at least the bump.
    var bumped = recommend(_runs([1000, 1000, 1000]), 4096, auto)
    assert_equal(
        resolve_request(auto, bumped, True).request.memory_min_mb, 4096
    )


def test_auto_range_is_clamped() raises:
    # `auto..2`: learned, at most 2 GB; granted up to the maximum.
    var req = Request.of("auto..2", "auto..2")
    var rec = recommend(_runs([4000, 4000, 4000], 6.0), 0, req)
    var r = resolve_request(req, rec, True)
    assert_equal(r.source, LEARNED)
    assert_equal(r.request.memory_min_mb, 2048)
    assert_equal(r.request.memory_max_mb, 2048)
    assert_equal(r.request.cpus_min, 2)
    assert_equal(rec.clamped, "memory_gb's maximum and cpus' maximum")
    # Below it, the learned minimum and the declared maximum.
    var small = recommend(_runs([500, 500, 500], 1.0), 0, req)
    var s = resolve_request(req, small, True)
    assert_equal(s.request.memory_min_mb, 768)
    assert_equal(s.request.memory_max_mb, 2048)
    assert_equal(s.request.cpus_min, 1)
    assert_equal(s.request.cpus_max, 2)
    assert_equal(s.memory_gb_text(), "0.75..2")


def test_learned_cpus_fit_the_host() raises:
    # Learned 3 CPUs on a host that grants a run at most 1: 1, not a wait.
    var auto = Request.of("auto", "auto")
    var rec = recommend(_runs([1000, 1000, 1000], 2.3), 0, auto)
    var r = resolve_request(auto, rec, True, 1)
    assert_equal(r.request.cpus_min, 1)
    assert_equal(r.request.cpus_max, 1)
    assert_equal(r.source, LEARNED)
    # Within it, as learned; memory isn't capped.
    assert_equal(resolve_request(auto, rec, True, 4).request.cpus_min, 3)
    assert_equal(r.request.memory_min_mb, 1280)
    # A declared range isn't capped: that's the pipeline's ask.
    var declared = Request.of("2..4", "")
    assert_equal(resolve_request(declared, rec, True, 1).request.cpus_min, 2)


def test_learned_memory_fits_the_host() raises:
    # #462: one run of 2046 MB × 1.15 learns 2.5 GB; a host that grants a
    # run at most 2.2 GB caps it there, so the run starts, saying so.
    var auto = Request.of("", "auto..4")
    var rec = recommend(_runs([2046, 2046, 2046]), 0, auto)
    assert_equal(rec.memory_mb, 2560)
    var r = resolve_request(auto, rec, True, 0, 2253)
    assert_equal(r.source, LEARNED)
    assert_equal(r.request.memory_min_mb, 2253)
    assert_equal(r.request.memory_max_mb, 2253)
    assert_equal(r.learned_mb, 2560)
    assert_equal(
        r.cap_text(), "learned 2.5 GB, capped at 2.2 GB, this host's most"
    )
    # It fits what the host grants: admitted, granted the cap.
    var fit = admit(r.request, Room(4, 2253, 4, 2253), 0, 0, 1)
    assert_equal(len(fit[0]), 1)
    assert_equal(fit[0][0].memory_mb, 2253)
    # Under the cap: as learned, up to auto..4's maximum, nothing said.
    var roomy = resolve_request(auto, rec, True, 0, 8192)
    assert_equal(roomy.request.memory_min_mb, 2560)
    assert_equal(roomy.request.memory_max_mb, 4096)
    assert_equal(roomy.cap_text(), "")
    # Within the host's most: auto..4's maximum, at most the host's.
    var tight = resolve_request(auto, rec, True, 0, 3072)
    assert_equal(tight.request.memory_min_mb, 2560)
    assert_equal(tight.request.memory_max_mb, 3072)
    # A pool's: its largest worker's, named.
    var pool = resolve_request(
        auto, rec, True, 0, 2048, "the most a worker of pool g grants"
    )
    assert_equal(
        pool.cap_text(),
        "learned 2.5 GB, capped at 2 GB, the most a worker of pool g grants",
    )
    # Shown with the recommendation once the scheduler keeps it.
    rec.capped = r.capped
    assert_equal(
        rec.text(),
        (
            "learned from 3 runs: 2.5 GB, 2 CPUs, capped at 2.2 GB, this host's"
            " most"
        ),
    )
    assert_true('"capped": "capped at 2.2 GB, this host' in rec.json())


def test_declared_over_the_host_is_not_capped() raises:
    # A fixed request over what the host grants stays as asked, and
    # admission refuses it as before.
    var fixed = Request.of("", "5")
    var rec = recommend(_runs([2046, 2046, 2046]), 0, fixed)
    var r = resolve_request(fixed, rec, True, 0, 1024)
    assert_equal(r.source, DECLARED)
    assert_equal(r.request.memory_min_mb, 5120)
    assert_equal(r.cap_text(), "")
    var fit = admit(r.request, Room(4, 1024, 4, 1024), 0, 0, 1)
    assert_equal(len(fit[0]), 0)
    assert_equal(
        fit[1],
        "waiting: needs 5 GB, more than the 1 GB this host grants at most",
    )


def test_auto_falls_back() raises:
    var auto = Request.of("", "auto")
    # Too few runs: no request, as without memory_gb.
    var few = recommend(_runs([1000, 1000]), 0, auto)
    var r = resolve_request(auto, few, True)
    assert_equal(r.source, DEFAULT)
    assert_false(r.request.any())
    assert_equal(r.runs, 0)
    assert_true("2 of the 3" in r.why)
    # Learning off: the same, though there's a recommendation.
    var rec = recommend(_runs([1000, 1000, 1000]), 0, auto)
    var off = resolve_request(auto, rec, False)
    assert_equal(off.source, DEFAULT)
    assert_false(off.request.any())
    assert_true("learn = false" in off.text())
    # CPUs with no peak cores (macOS): no CPU request; memory learned.
    var both = Request.of("auto", "auto")
    var mac = resolve_request(
        both, recommend(_runs([1000, 1000, 1000], -1), 0, both), True
    )
    assert_equal(mac.source, LEARNED)
    assert_equal(mac.request.cpus_min, 0)
    assert_equal(mac.request.memory_min_mb, 1280)
    var cpus = Request.of("auto", "")
    var none = resolve_request(
        cpus, recommend(_runs([1000, 1000, 1000], -1), 0, cpus), True
    )
    assert_equal(none.source, DEFAULT)
    assert_true("peak cores" in none.why)
    # The cache's recommendation (runs, memory, CPUs) resolves the same.
    var cached = Recommendation(3, 0, 1280, 0, "", "", False, "")
    assert_equal(
        resolve_request(auto, cached, True).request.memory_min_mb, 1280
    )
    assert_true(
        "2 of the 3"
        in resolve_request(
            auto, Recommendation(2, 0, 0, 0, "", "", False, ""), True
        ).why
    )


def test_declared_is_as_it_is() raises:
    var req = Request.of("1..4", "2..8")
    var r = resolve_request(
        req, Recommendation(20, 20, 1024, 1, "", "", False, ""), True
    )
    assert_equal(r.source, DECLARED)
    assert_equal(r.request.memory_min_mb, 2048)
    assert_equal(r.request.cpus_max, 4)
    assert_equal(r.text(), "")
    assert_equal(
        resolve_request(_none(), Recommendation.none(), True).source, ""
    )


def test_applied_json() raises:
    var r = recommend(_runs([1000, 1000, 1000]), 0, _none())
    assert_true('"applied": false' in r.json())
    r.applied = True
    assert_true('"applied": true' in r.json())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
