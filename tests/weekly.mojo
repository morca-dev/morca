"""A weekly pipeline (ISO weeks) run at 06:00 every Monday, filling the week
that just ended (`fire=Previous`), the step returning its week number
(tests/weekly.sh).
"""

from morca import (
    Cron,
    Ctx,
    Mapped,
    Pipeline,
    Previous,
    Step,
    Week,
    Weekly,
    morca_main,
)


def count(mut ctx: Ctx, w: Week) raises -> Int:
    return w.week


comptime Count = Step["count", Week, Int, count, Mapped]
comptime Mondays = Pipeline[
    "weekly",
    Count,
    partitions=Weekly["2026-W40"],
    schedule=Cron["0 6 * * 1"],
    fire=Previous,
    catchup=False,
]


def main() raises:
    morca_main[Mondays]()
