"""A sensor over a dataset nothing writes: raw.other to lake.other."""

from morca import Ctx, Mapped, Month, Pipeline, Step, morca_main
from morca.tables import append, table
from rows import count, dataset, rows


def other(mut ctx: Ctx, m: Month) raises -> Int64:
    var n = count(ctx, table(ctx, "raw.other"))
    var t = dataset(ctx, "lake.other")
    return append(ctx, t, rows(String(m), n))


comptime Other = Step[
    "other",
    Month,
    Int64,
    other,
    Mapped,
    reads=["raw.other"],
    writes=["lake.other"],
]
comptime P = Pipeline["other", Other, sensor=True]


def main() raises:
    morca_main[P]()
