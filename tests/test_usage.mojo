"""What morca.usage does: a meter's samples shared out among a process's
attempts, the meter over the worker API, and the reading of /proc it is
fed from."""

from std.ffi import c_int, external_call
from std.sys.info import CompilationTarget
from std.testing import (
    TestSuite,
    assert_almost_equal,
    assert_equal,
    assert_false,
    assert_true,
)

from json import loads

from morca._internal.sample import parse_pid_usage, tree_usage
from morca._internal.db.run_rows import Usage
from morca._internal.usage import (
    MAX_MARKS,
    Mark,
    Meter,
    attribute,
    bytes_text,
    cpu_text,
    marks_json,
    marks_of,
    usage_json,
    usage_of,
    usage_text,
)
from morca._internal.db.usage import AttemptSpan

comptime MB = 1024 * 1024


def _meter() -> Meter:
    """A process that ran 10 s: 100 MB and 1 core for 4 s, then 300 MB and
    2 cores for 6 s, sampled each second; `wait4` says 250 MB at most for
    one process, and 16.5 s of CPU, half a second after the last sample."""
    var m = Meter(now=1000.0)
    for t in range(1, 11):
        var rss = 100 * MB if t <= 4 else 300 * MB
        var cpu = Float64(t) if t <= 4 else 4.0 + 2.0 * Float64(t - 4)
        m.sample(rss, cpu, now_in=1000.0 + Float64(t))
    m.end(250 * MB, 16.5, now_in=1010.5)
    return m^


def test_one_attempt() raises:
    var m = _meter()
    var marks = m.aged(now_in=1010.5)
    assert_equal(len(marks), 12)
    assert_almost_equal(marks[0].at, 10.5)
    assert_almost_equal(marks[11].at, 0.0)
    var got = attribute(marks, m.max_rss, [AttemptSpan(1, 10.5, 0.0)])
    assert_equal(got[0].peak_rss_bytes, 300 * MB)
    # All its CPU, wait4's last half second included.
    assert_almost_equal(got[0].cpu_seconds, 16.5)
    assert_almost_equal(got[0].peak_cpus, 2.0)
    # The last stretch's cores: 0.5 s of CPU in 0.5 s.
    assert_almost_equal(marks[11].cpus, 1.0)
    # Its only attempt's peak is at least wait4's largest process.
    var low = Meter(now=0.0)
    low.sample(100 * MB, 1.0, now_in=1.0)
    low.end(250 * MB, 1.5, now_in=1.5)
    var lone = attribute(
        low.aged(now_in=1.5), low.max_rss, [AttemptSpan(1, 1.5, 0)]
    )
    assert_equal(lone[0].peak_rss_bytes, 250 * MB)


def test_attempts_share_by_time() raises:
    var m = _meter()
    var marks = m.aged(now_in=1010.5)
    # The first ran from 0.2 s in to 4 s in, the second from 4.2 s in to
    # nearly the end; a third (left running by a crash) has no end.
    var got = attribute(
        marks,
        m.max_rss,
        [AttemptSpan(1, 10.3, 6.5), AttemptSpan(2, 6.3, 0.2)],
    )
    assert_equal(got[0].peak_rss_bytes, 100 * MB)
    assert_almost_equal(got[0].cpu_seconds, 3.8, atol=1e-9)
    assert_almost_equal(got[0].peak_cpus, 1.0)
    assert_equal(got[1].peak_rss_bytes, 300 * MB)
    assert_almost_equal(got[1].peak_cpus, 2.0)
    # wait4's peak isn't anyone's when there are two.
    assert_true(got[1].peak_rss_bytes != 250 * MB)
    var open = attribute(marks, m.max_rss, [AttemptSpan(3, 5.0, -1)])
    assert_almost_equal(open[0].cpu_seconds, 16.5 - 7.0)


def test_short_attempt() raises:
    """An attempt between two samples gets the sample just after it."""
    var m = _meter()
    var marks = m.aged(now_in=1010.5)
    var got = attribute(
        marks, m.max_rss, [AttemptSpan(1, 7.4, 7.2), AttemptSpan(2, 3, 1)]
    )
    assert_equal(got[0].peak_rss_bytes, 100 * MB)
    assert_almost_equal(got[0].cpu_seconds, 0.2, atol=1e-9)
    assert_almost_equal(got[0].peak_cpus, 1.0)


def test_unsampled() raises:
    """On macOS: no samples, only wait4's numbers, for an only attempt."""
    var m = Meter(now=50.0)
    m.end(200 * MB, 8.25, now_in=60.0)
    var marks = m.aged(now_in=60.0)
    var one = attribute(marks, m.max_rss, [AttemptSpan(1, 9.9, 0.1)])
    assert_equal(one[0].peak_rss_bytes, 200 * MB)
    assert_almost_equal(one[0].cpu_seconds, 8.25)
    assert_equal(one[0].peak_cpus, -1.0)
    var two = attribute(
        marks, m.max_rss, [AttemptSpan(1, 9.9, 5), AttemptSpan(2, 5, 0.1)]
    )
    assert_false(two[0].known())
    assert_false(two[1].known())
    assert_equal(len(attribute(marks, m.max_rss, List[AttemptSpan]())), 0)


def test_samples_too_close() raises:
    var m = Meter(now=0.0)
    m.sample(MB, 0.1, now_in=0.1)
    assert_equal(len(m.marks), 1)
    m.sample(MB, 0.3, now_in=0.3)
    assert_equal(len(m.marks), 2)
    # CPU only grows.
    m.sample(MB, 0.2, now_in=1.0)
    assert_almost_equal(m.marks[2].cpu, 0.3)
    assert_almost_equal(m.marks[2].cpus, 0.0)


def test_squeeze() raises:
    """A long run's samples merge, keeping the peaks and the total."""
    var m = Meter(now=0.0)
    for t in range(1, 3 * MAX_MARKS):
        var rss = 900 * MB if t == 777 else 10 * MB
        # 4 cores' worth in the second before t = 1500, 1 in the others.
        var cpu = Float64(t) + (3.0 if t >= 1500 else 0.0)
        m.sample(rss, cpu, now_in=Float64(t))
    assert_true(len(m.marks) <= MAX_MARKS)
    assert_almost_equal(m.marks[0].at, 0.0)
    var top = 0
    var cores = 0.0
    for k in m.marks:
        top = max(top, k.rss)
        cores = max(cores, k.cpus)
    assert_equal(top, 900 * MB)
    assert_almost_equal(cores, 4.0)
    assert_almost_equal(
        m.marks[len(m.marks) - 1].cpu, Float64(3 * MAX_MARKS - 1) + 3.0
    )


def test_marks_json() raises:
    var m = _meter()
    var marks = m.aged(now_in=1010.5)
    var back = marks_of(loads(marks_json(marks)))
    assert_equal(len(back), len(marks))
    for i in range(len(marks)):
        assert_almost_equal(back[i].at, marks[i].at, atol=1e-3)
        assert_equal(back[i].rss, marks[i].rss)
        assert_almost_equal(back[i].cpu, marks[i].cpu, atol=1e-3)
        assert_almost_equal(back[i].cpus, marks[i].cpus, atol=1e-3)
    assert_equal(len(marks_of(loads("[]"))), 0)


def test_usage_json() raises:
    var u = Usage(312 * MB, 41.2, 3.9)
    var back = usage_of(loads(usage_json(u)))
    assert_equal(back.peak_rss_bytes, 312 * MB)
    assert_almost_equal(back.cpu_seconds, 41.2)
    assert_almost_equal(back.peak_cpus, 3.9)
    assert_equal(
        usage_json(Usage.unknown()),
        '{"peak_rss_bytes": null, "cpu_seconds": null, "peak_cpus": null}',
    )
    assert_false(usage_of(loads(usage_json(Usage.unknown()))).known())
    assert_equal(usage_text(u), "peak 312 MB, CPU 41.2 s on up to 3.9 cores")
    assert_equal(usage_text(Usage(5 * MB, 2.0, -1)), "peak 5 MB, CPU 2.0 s")
    assert_equal(usage_text(Usage.unknown()), "")


def test_texts() raises:
    assert_equal(bytes_text(200 * MB), "200 MB")
    assert_equal(bytes_text(12 * 1024 * MB), "12.0 GB")
    assert_equal(cpu_text(41.2), "41.2 s")
    assert_equal(cpu_text(900), "15.0 min")
    assert_equal(cpu_text(9000), "2.5 h")


def test_parse_pid_usage() raises:
    var line = String(
        "4242 (dista worker) S 4200 4242 4242 0 -1 4194560 100 0 0 0 150 30",
        " 12 8 20 0 4 0 999 123456789 2560 18446744073709551615",
    )
    var u = parse_pid_usage(line)
    assert_equal(u.parent, 4200)
    assert_equal(u.rss_pages, 2560)
    assert_equal(u.cpu_ticks, 150 + 30 + 12 + 8)
    assert_equal(parse_pid_usage("garbage").parent, -1)


def test_tree_usage() raises:
    var me = Int(external_call["getpid", c_int]())
    var got = tree_usage([me, 999999999])
    comptime if CompilationTarget.is_linux():
        assert_true(me in got)
        assert_true(got[me][0] > MB)
        assert_true(got[me][1] >= 0.0)
        # A process that isn't there has no reading.
        assert_false(999999999 in got)
    else:
        assert_equal(len(got), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
