"""A three-step pipeline over months: the one tests/cli.sh drives.

    pixi run toy
    ./build/toy describe
    ./build/toy run --partitions 2024-01..2024-03

It's scheduled at 03:00 UTC on the 2nd of each month, for the month before,
from 2024-01, with at most two runs at once: tests/scheduler.sh drives it
through the `morca` scheduler.

A partition whose month is in MORCA_TOY_FAIL (e.g. `2024-02`) fails its
`measure` step, to show the rest of the run carrying on; one in
MORCA_TOY_CRASH aborts the process there, as a crash would (tests/crash.sh).
MORCA_TOY_SLEEP makes
every step take that many seconds, so a test has time to kill it. A month in
MORCA_TOY_GROW has its `days` step's first attempt hold MORCA_TOY_GROW_MB
(200) MiB for a second, so a run under that memory limit is killed for it
(tests/kind.sh) and its retry isn't.
"""

from std.os import abort, getenv
from std.time import perf_counter_ns, sleep

from dista import Seq
from morca import (
    Cron,
    Ctx,
    Gather,
    Mapped,
    Month,
    Monthly,
    Pipeline,
    Step,
    morca_main,
)


def _nap() raises:
    var s = getenv("MORCA_TOY_SLEEP")
    if s:
        sleep(Float64(s))


@fieldwise_init
struct Measured(Copyable, Movable):
    var month: Month
    var days: Int


def _grow(ctx: Ctx, m: Month) raises:
    if ctx.attempt != 1 or String(m) not in getenv("MORCA_TOY_GROW"):
        return
    var b = List[UInt8](
        length=Int(getenv("MORCA_TOY_GROW_MB", "200")) * 1024 * 1024, fill=1
    )
    var t0 = Int(perf_counter_ns())
    var x = 0
    while Int(perf_counter_ns()) - t0 < 1_000_000_000:
        for i in range(0, len(b), 4096):
            x += Int(b[i])
            b[i] = UInt8(x & 0xFF)
    ctx.log(String("held ", len(b) // (1024 * 1024), " MiB (", x, ")"))


def days(mut ctx: Ctx, m: Month) raises -> Measured:
    """The number of days in the month."""
    _nap()
    _grow(ctx, m)
    var n = 31
    if m.month == 2:
        var leap = (m.year % 4 == 0 and m.year % 100 != 0) or m.year % 400 == 0
        n = 29 if leap else 28
    elif m.month in (4, 6, 9, 11):
        n = 30
    return Measured(m.copy(), n)


def measure(mut ctx: Ctx, m: Measured) raises -> Measured:
    """Hours in the month; fails for the months in MORCA_TOY_FAIL."""
    _nap()
    if String(m.month) in getenv("MORCA_TOY_FAIL"):
        raise Error("failing ", m.month, " as asked")
    if String(m.month) in getenv("MORCA_TOY_CRASH"):
        abort(String("crashing ", m.month, " as asked"))
    ctx.log(String(m.month, " has ", m.days, " days"))
    return Measured(m.month.copy(), m.days * 24)


def total(mut ctx: Ctx, ms: Seq[Measured]) raises -> Int:
    _nap()
    var t = 0
    for i in range(len(ms)):
        t += ms[i].days
    ctx.log(String(len(ms), " months, ", t, " hours"))
    return t


comptime Days = Step["days", Month, Measured, days, Mapped]
comptime Measure = Step[
    "measure", Measured, Measured, measure, Mapped, after=Days
]
comptime Total = Step["total", Seq[Measured], Int, total, Gather, after=Measure]
comptime Toy = Pipeline[
    "toy",
    Days,
    Measure,
    Total,
    partitions=Monthly["2024-01"],
    schedule=Cron["0 3 2 * *"],
    max_runs=2,
]


def main() raises:
    morca_main[Toy]()
