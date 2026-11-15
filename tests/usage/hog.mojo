"""The pipeline of tests/usage.sh: one step that holds a known amount of
memory and keeps two cores busy, so the test can check what morca recorded.

For any month, its step starts a copy of this binary (with `HOG_CHILD`
set), which holds `HOG_CHILD_MB` (100) MiB and burns a core for
`HOG_SECONDS` (4), while the step holds `HOG_MB` (200) MiB and burns
another itself; then it waits for the copy. The run's process tree so
holds about 300 MiB at once, its largest process about 200, and it uses
about twice `HOG_SECONDS` of CPU on about two cores.
"""

from std.ffi import c_int, external_call
from std.memory import stack_allocation
from std.os import getenv
from std.sys import argv
from std.time import perf_counter_ns

from morca import Ctx, Mapped, Month, Monthly, Pipeline, Step, morca_main
from morca._common.paths import absolute
from morca._internal.proc import spawn


def _hold(mb: Int, seconds: Float64) -> Int:
    """Holds `mb` MiB, every page written, rewriting a byte of each page
    until `seconds` have gone."""
    var b = List[UInt8](length=mb * 1024 * 1024, fill=1)
    var t0 = Int(perf_counter_ns())
    var x = 0
    while Float64(Int(perf_counter_ns()) - t0) / 1e9 < seconds:
        for i in range(0, len(b), 4096):
            x += Int(b[i])
            b[i] = UInt8(x & 0xFF)
    return x


def _env(name: String, default: String) -> String:
    var v = getenv(name)
    return v if v else default


def hog(mut ctx: Ctx, m: Month) raises -> Int:
    """Holds and burns, beside a copy of itself doing the same."""
    var seconds = Float64(_env("HOG_SECONDS", "4"))
    var child = spawn([absolute(String(argv()[0]))], env=["HOG_CHILD=1"])
    var x = _hold(Int(_env("HOG_MB", "200")), seconds)
    var status = stack_allocation[1, c_int]()
    _ = external_call["waitpid", c_int](c_int(child), status, c_int(0))
    ctx.log(String("held ", m, " for ", seconds, " s"))
    return x


comptime Hog = Step["hog", Month, Int, hog, Mapped]
comptime Hogs = Pipeline["hog", Hog, partitions=Monthly["2024-01"]]


def main() raises:
    if getenv("HOG_CHILD"):
        _ = _hold(
            Int(_env("HOG_CHILD_MB", "100")), Float64(_env("HOG_SECONDS", "4"))
        )
        return
    morca_main[Hogs]()
