"""Containment (morca.cgroup): the limit, margin and retry arithmetic, and
reading /proc/self/cgroup and memory.events."""

from std.os import getenv, makedirs, setenv, unsetenv
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from morca._internal.cgroup import (
    Cgroups,
    Contained,
    MemoryKnobs,
    avg10_of,
    ceiling_mb,
    event,
    full_avg10,
    growth_pct_of,
    has_word,
    stall_total_us,
    held,
    max_mb,
    oom_text,
    own_limit_pressure,
    own_path,
    owner_of,
    raised_mb,
    raised_request,
    run_name,
    start_limit_mb,
    swap_max_mb,
    swap_note,
    swap_pct_of,
)
from morca._internal.offload import Offload, OffloadWatch, stat_value
from morca._internal.run_cpu import CpuKnobs, cpu_max, status_text


def test_max_mb() raises:
    assert_equal(max_mb(1024, 25), 1280)
    assert_equal(max_mb(100, 25), 125)
    assert_equal(max_mb(101, 25), 127)  # 126.25, up
    assert_equal(max_mb(64, 0), 64)


def test_raised_mb() raises:
    assert_equal(raised_mb(1024, 150, 4096), 1536)
    assert_equal(raised_mb(3072, 150, 4096), 4096)  # at the ceiling
    assert_equal(raised_mb(4096, 150, 4096), 4096)  # nothing more
    assert_equal(raised_mb(101, 150, 0), 152)  # no ceiling, rounded up
    # Never down, though the ceiling is under the limit.
    assert_equal(raised_mb(2048, 150, 1024), 2048)


def test_start_limit_mb() raises:
    # The grant, else the request's maximum, else the default or what an
    # out-of-memory kill raised it to; at most the control cap.
    assert_equal(start_limit_mb(3000, 8192, 6000, 0, 0), 3000)
    assert_equal(start_limit_mb(0, 8192, 6000, 0, 0), 8192)
    assert_equal(start_limit_mb(0, 0, 6000, 0, 0), 6000)
    assert_equal(start_limit_mb(0, 0, 1000, 1500, 0), 1500)
    assert_equal(start_limit_mb(0, 0, 6000, 9000, 0), 9000)
    assert_equal(start_limit_mb(3000, 0, 0, 0, 1024), 1024)
    assert_equal(start_limit_mb(0, 0, 1024, 1536, 1024), 1024)


def test_ceiling_mb() raises:
    # At most what the host grants: a raise past it would wait forever.
    assert_equal(ceiling_mb(8192, 6000, 0), 6000)
    assert_equal(ceiling_mb(4096, 6000, 0), 4096)
    assert_equal(ceiling_mb(8192, 0, 0), 8192)
    assert_equal(ceiling_mb(0, 6000, 0), 6000)
    assert_equal(ceiling_mb(8192, 6000, 1024), 1024)
    assert_equal(ceiling_mb(0, 0, 1024), 1024)


def test_raised_request() raises:
    assert_equal(raised_request(2048, 8192, 0), 2048)
    assert_equal(raised_request(2048, 8192, 1024), 2048)
    assert_equal(raised_request(2048, 8192, 3072), 3072)
    assert_equal(raised_request(2048, 8192, 9000), 8192)


def test_retry_sequence() raises:
    # 64 MB, killed: 96, then 144, then the 200 MB maximum.
    var limit = 64
    var seen = List[Int]()
    for _ in range(4):
        limit = raised_mb(limit, 150, 200)
        seen.append(limit)
    assert_equal(seen[0], 96)
    assert_equal(seen[1], 144)
    assert_equal(seen[2], 200)
    assert_equal(seen[3], 200)


def test_oom_text() raises:
    var t = oom_text(1536, 1920, 2304)
    assert_true(t.startswith("out of memory at 1.5 GB"), t)
    assert_true("memory.max (1.9 GB)" in t, t)
    assert_true("its retry asks for 2.3 GB" in t, t)
    var top = oom_text(64, 80, 64)
    assert_true(top.startswith("out of memory at 64 MB"), top)
    assert_true("the most it may ask for" in top, top)


def test_own_path() raises:
    assert_equal(own_path("0::/\n"), "/")
    assert_equal(
        own_path("0::/system.slice/docker-abc.scope\n"),
        "/system.slice/docker-abc.scope",
    )
    # Hybrid: v1 controllers first, the unified line last.
    assert_equal(
        own_path("12:memory:/x\n11:cpu:/x\n0::/user.slice\n"), "/user.slice"
    )
    assert_equal(own_path("12:memory:/x\n11:cpu,cpuacct:/x\n"), "")
    assert_equal(own_path(""), "")


def test_events() raises:
    var text = "low 0\nhigh 1520\nmax 27\noom 1\noom_kill 4\noom_group_kill 1\n"
    assert_equal(event(text, "oom_kill"), 4)
    assert_equal(event(text, "oom_group_kill"), 1)
    assert_equal(event(text, "high"), 1520)
    assert_equal(event(text, "nope"), 0)
    assert_equal(event("", "oom_kill"), 0)
    assert_equal(event("oom_kill x\n", "oom_kill"), 0)


def test_pressure() raises:
    var text = (
        "some avg10=93.60 avg60=87.14 avg300=86.19 total=3235372442\n"
        "full avg10=91.25 avg60=87.13 avg300=86.18 total=3233770492\n"
    )
    assert_equal(full_avg10(text), 91.25)
    assert_equal(full_avg10("some avg10=1.00 avg60=0 avg300=0 total=1\n"), -1.0)
    assert_equal(full_avg10(""), -1.0)


def _fake_cgroup(dir: String, current_mb: Int, some: String) raises:
    _ = makedirs(dir, exist_ok=True)
    with open(String(dir, "/memory.current"), "w") as f:
        f.write(current_mb * 1024 * 1024, "\n")
    with open(String(dir, "/memory.pressure"), "w") as f:
        f.write(
            "some avg10=",
            some,
            " avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00",
            " avg300=0.00 total=1\n",
        )


def test_own_limit_pressure() raises:
    """What runs held at their own limits explain of the host's pressure:
    the most of their `some avg10`; a run under its limit explains none."""
    assert_equal(
        avg10_of("some avg10=81.27 avg60=0 avg300=0 total=1\n", "some"), 81.27
    )
    var base = String(getenv("TMPDIR", "/tmp"), "/morca-test-own-limit")
    _fake_cgroup(String(base, "/held"), 510, "81.50")
    _fake_cgroup(String(base, "/also"), 1000, "40.00")
    _fake_cgroup(String(base, "/easy"), 100, "90.00")
    var c = Dict[Int, Contained]()
    c[1] = Contained(1, 1, "p", String(base, "/held"), 512, 640, 1024, 512)
    c[2] = Contained(2, 1, "p", String(base, "/also"), 1024, 1280, 2048, 1024)
    assert_equal(own_limit_pressure(c), 81.5)
    _ = c.pop(1)
    assert_equal(own_limit_pressure(c), 40.0)
    c[3] = Contained(3, 1, "p", String(base, "/easy"), 512, 640, 1024, 512)
    _ = c.pop(2)
    assert_equal(own_limit_pressure(c), 0.0)
    assert_equal(own_limit_pressure(Dict[Int, Contained]()), 0.0)


def test_stall_totals() raises:
    var text = (
        "some avg10=0.00 avg60=0.00 avg300=0.00 total=3235372442\n"
        "full avg10=0.00 avg60=0.00 avg300=0.00 total=3233770492\n"
    )
    assert_equal(stall_total_us(text, "some"), 3235372442)
    assert_equal(stall_total_us(text, "full"), 3233770492)
    assert_equal(stall_total_us("", "some"), -1)
    assert_equal(stall_total_us("some avg10=0.00\n", "some"), -1)


def test_held() raises:
    var mb = 1024 * 1024
    # Run 23 on beta: 595 MB of anonymous memory at a 512 MB limit, every
    # task stalled ~90% of the time.
    assert_true(held(595 * mb, 512, 93.6))
    # At the limit but making progress (page cache being reclaimed).
    assert_false(held(510 * mb, 512, 3.0))
    # Stalled, but well under the limit: the host's pressure, not its own.
    assert_false(held(200 * mb, 512, 93.6))
    # No PSI to read.
    assert_false(held(595 * mb, 512, -1.0))


def test_controllers() raises:
    assert_true(has_word("cpuset cpu io memory pids\n", "memory"))
    assert_false(has_word("cpuset cpu io pids\n", "memory"))
    assert_false(has_word("", "memory"))


def test_names() raises:
    assert_equal(run_name(42, 3, 1234), "orca-run-42-3-1234")
    assert_equal(owner_of("orca-run-42-3-1234"), 1234)
    assert_equal(owner_of("morca"), -1)
    assert_equal(owner_of("orca-run-x"), -1)


def test_knobs() raises:
    _ = unsetenv("MORCA_RUN_MEMORY_MB")
    _ = unsetenv("MORCA_RUN_MEMORY_MARGIN")
    _ = unsetenv("MORCA_RUN_MEMORY_GROWTH")
    _ = unsetenv("MORCA_RUN_MEMORY_HELD_SECONDS")
    _ = unsetenv("MORCA_RUN_SWAP_PCT")
    var k = MemoryKnobs.from_env()
    assert_equal(k.default_mb, 0)
    assert_equal(k.margin_pct, 25)
    assert_equal(k.growth_pct, 150)
    assert_equal(k.held_s, 120)
    # No swap unless asked for (#282): memory.swap.max 0, as before.
    assert_equal(k.swap_pct, 0)
    _ = setenv("MORCA_RUN_MEMORY_GROWTH", "2", True)
    _ = setenv("MORCA_RUN_MEMORY_MARGIN", "10", True)
    _ = setenv("MORCA_RUN_MEMORY_MB", "512", True)
    k = MemoryKnobs.from_env()
    assert_equal(k.growth_pct, 200)
    assert_equal(k.margin_pct, 10)
    assert_equal(k.default_mb, 512)
    assert_equal(growth_pct_of("1.25"), 125)
    for bad in ["0.5", "x", "-1"]:
        with assert_raises(contains="MORCA_RUN_MEMORY_GROWTH"):
            _ = growth_pct_of(bad)
    _ = setenv("MORCA_RUN_MEMORY_MARGIN", "-3", True)
    with assert_raises(contains="MORCA_RUN_MEMORY_MARGIN"):
        _ = MemoryKnobs.from_env()
    _ = unsetenv("MORCA_RUN_MEMORY_MB")
    _ = unsetenv("MORCA_RUN_MEMORY_MARGIN")
    _ = unsetenv("MORCA_RUN_MEMORY_GROWTH")


def test_swap_knob() raises:
    """`MORCA_RUN_SWAP_PCT` (#282): a whole percent of the limit, 0 to 100;
    anything else is refused, as the other knobs are."""
    _ = setenv("MORCA_RUN_SWAP_PCT", "20", True)
    assert_equal(MemoryKnobs.from_env().swap_pct, 20)
    assert_equal(swap_pct_of("0"), 0)
    assert_equal(swap_pct_of("100"), 100)
    for bad in ["-1", "101", "x", "12.5", "20%"]:
        with assert_raises(contains="MORCA_RUN_SWAP_PCT"):
            _ = swap_pct_of(bad)
    _ = setenv("MORCA_RUN_SWAP_PCT", "150", True)
    with assert_raises(contains="from 0 to 100, not 150"):
        _ = MemoryKnobs.from_env()
    _ = unsetenv("MORCA_RUN_SWAP_PCT")


def test_swap_max_mb() raises:
    # 20% of a 512 MB limit, rounded up to a whole MB; 0 without swap.
    assert_equal(swap_max_mb(512, 20), 103)
    assert_equal(swap_max_mb(1500, 10), 150)
    assert_equal(swap_max_mb(512, 0), 0)
    assert_equal(swap_max_mb(512, 100), 512)


def test_swap_note() raises:
    var header = "Filename\tType\tSize\tUsed\tPriority\n"
    var one = String(header, "/swapfile file 4194300 0 -2\n")
    assert_equal(
        swap_note(20, one, "Y"),
        (
            "memory.swap.max at 20% of each run's limit (MORCA_RUN_SWAP_PCT),"
            " zswap on"
        ),
    )
    assert_true("uncompressed" in swap_note(20, one, "N"))
    assert_true(
        "no swap, so nothing is offloaded" in swap_note(20, header, "Y")
    )
    assert_true("no swap" in swap_note(20, "", ""))
    var off = Cgroups.off("off")
    assert_equal(off.swap_text(), "none (no run cgroups)")
    var on = Cgroups("/sys/fs/cgroup/x", "on", MemoryKnobs(0, 25, 150, 120, 0))
    assert_true("MORCA_RUN_SWAP_PCT=0" in on.swap_text())


def _offload_files(dir: String, swap_mb: Int, zswapped_mb: Int) raises:
    var mb = 1024 * 1024
    with open(String(dir, "/memory.swap.current"), "w") as f:
        f.write(swap_mb * mb, "\n")
    with open(String(dir, "/memory.stat"), "w") as f:
        f.write("anon 1\nzswapped ", zswapped_mb * mb, "\n")


def test_offload() raises:
    """A run's offload peaks (`morca._internal.offload`): sampled from its
    cgroup's memory.swap.current and memory.stat's zswapped, the larger of
    each kept, with memory.swap.peak at the end; nothing with swap off."""
    var stat = String(
        "anon 594137088\nfile 0\nzswap 31457280\nzswapped 104857600\n",
        "zswpout 25600\n",
    )
    assert_equal(stat_value(stat, "zswapped"), 104857600)
    assert_equal(stat_value(stat, "zswap"), 31457280)
    assert_equal(stat_value("anon 1\nfile 0\n", "zswapped"), -1)
    var m = Offload(10, -1).merge(Offload(5, 3))
    assert_equal(m.swap_bytes, 10)
    assert_equal(m.zswapped_bytes, 3)

    var mb = 1024 * 1024
    var dir = String(getenv("TMPDIR", "/tmp"), "/morca-test-offload/run")
    _ = makedirs(dir, exist_ok=True)
    # No peak yet (as a kernel before 6.5 has none), even after a test before.
    with open(String(dir, "/memory.swap.peak"), "w") as f:
        f.write("0\n")
    var c = Dict[Int, Contained]()
    c[7] = Contained(1, 1, "p", dir, 512, 640, 1024, 512)
    var w = OffloadWatch()
    _offload_files(dir, 120, 80)
    w.sample(c, 20)
    _offload_files(dir, 40, 30)
    w.sample(c, 20)
    # The peaks, not the last sample.
    var got = w.take(7, dir, 20)
    assert_equal(got.swap_bytes, 120 * mb)
    assert_equal(got.zswapped_bytes, 80 * mb)
    # memory.swap.peak (kernel 6.5+) catches what the samples missed.
    with open(String(dir, "/memory.swap.peak"), "w") as f:
        f.write(200 * mb, "\n")
    w.sample(c, 20)
    assert_equal(w.take(7, dir, 20).swap_bytes, 200 * mb)
    # Forgotten once taken; a process that's gone is dropped at a sample.
    w.sample(c, 20)
    _ = c.pop(7)
    w.sample(c, 20)
    assert_equal(len(w.peaks), 0)
    # Swap off: nothing sampled, nothing known.
    c[8] = Contained(2, 1, "p", dir, 512, 640, 1024, 512)
    w.sample(c, 0)
    assert_equal(len(w.peaks), 0)
    var none = w.take(8, dir, 0)
    assert_equal(none.swap_bytes, -1)
    assert_equal(none.zswapped_bytes, -1)


def test_cpu_knobs() raises:
    _ = unsetenv("MORCA_RUN_NICE")
    _ = unsetenv("MORCA_RUN_CPU_WEIGHT")
    var k = CpuKnobs.from_env()
    assert_equal(k.nice, 10)
    assert_equal(k.weight, 20)
    _ = setenv("MORCA_RUN_NICE", "0", True)
    _ = setenv("MORCA_RUN_CPU_WEIGHT", "50", True)
    k = CpuKnobs.from_env()
    assert_equal(k.nice, 0)
    assert_equal(k.weight, 50)
    _ = setenv("MORCA_RUN_NICE", "20", True)
    with assert_raises(contains="MORCA_RUN_NICE"):
        _ = CpuKnobs.from_env()
    assert_equal(CpuKnobs.settings().nice, 10)
    _ = setenv("MORCA_RUN_NICE", "5", True)
    _ = setenv("MORCA_RUN_CPU_WEIGHT", "0", True)
    with assert_raises(contains="MORCA_RUN_CPU_WEIGHT"):
        _ = CpuKnobs.from_env()
    _ = unsetenv("MORCA_RUN_NICE")
    _ = unsetenv("MORCA_RUN_CPU_WEIGHT")
    assert_equal(CpuKnobs(10, 20).json(), '{"cpu_weight": 20, "nice": 10}')
    assert_equal(
        status_text(20, 10),
        "run CPU priority: cpu.weight 20 in a cgroup, else nice 10",
    )
    assert_equal(
        status_text(20, 0),
        (
            "run CPU priority: cpu.weight 20 in a cgroup, else not lowered"
            " (MORCA_RUN_NICE=0)"
        ),
    )


def test_cpu_max() raises:
    assert_equal(cpu_max(0), "max")
    assert_equal(cpu_max(2), "200000 100000")


def test_nice_for() raises:
    var off = Cgroups.off("off")
    assert_equal(off.nice_for(""), 10)
    var on = Cgroups(
        "/sys/fs/cgroup/x", "on", MemoryKnobs(0, 25, 150, 120, 0), True
    )
    assert_equal(on.nice_for("/sys/fs/cgroup/x/orca-run-1-1-1"), 0)
    # Started without a cgroup after all: the nice instead.
    assert_equal(on.nice_for(""), 10)
    var no_cpu = Cgroups(
        "/sys/fs/cgroup/x", "on", MemoryKnobs(0, 25, 150, 120, 0)
    )
    assert_equal(no_cpu.nice_for("/sys/fs/cgroup/x/orca-run-1-1-1"), 10)
    on.cpu_knobs = CpuKnobs(0, 20)
    assert_equal(on.nice_for(""), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
