"""A long run that polls, for tests/outdated.sh and tests/concurrency.sh
(#397): its one step loops,
a unit of work every 0.2 s, and appends to OUTDATED_OUT each time what
`morca.outdated()` says changes, with `code_version()`,
`desired_code_version()` and `outdated_why()`.

For a month in OUTDATED_HANDOVER it returns once it's outdated, as a
pipeline that hands over does; for the others it ignores it, the default,
and returns only once the file OUTDATED_STOP/<month> exists.
"""

from std.os import getenv
from std.os.path import exists
from std.time import sleep

from morca import (
    Ctx,
    Mapped,
    Month,
    Monthly,
    Pipeline,
    Step,
    code_version,
    desired_code_version,
    morca_main,
    outdated,
    outdated_why,
)


def _say(line: String) raises:
    with open(getenv("OUTDATED_OUT"), "a") as f:
        f.write(line, "\n")


def follow(mut ctx: Ctx, m: Month) raises -> Int:
    var handover = String(m) in getenv("OUTDATED_HANDOVER")
    var stop = String(getenv("OUTDATED_STOP"), "/", m)
    _say(String("run ", ctx.run, " started on ", code_version()))
    var was = False
    var polls = 0
    while True:
        var now = outdated()
        if now != was:
            _say(
                String(
                    "run ",
                    ctx.run,
                    " outdated=",
                    now,
                    " code=",
                    code_version(),
                    " desired=",
                    desired_code_version(),
                    " why=",
                    outdated_why(),
                )
            )
            was = now
        if now and handover:
            _say(String("run ", ctx.run, " hands over"))
            return polls
        if exists(stop):
            return polls
        sleep(0.2)
        polls += 1


comptime Follow = Step["follow", Month, Int, follow, Mapped]


def run[name: StaticString]() raises:
    """The pipeline as `name`: longpoll, and longpoll2 beside it for
    tests/concurrency.sh's key shared by two pipelines (#397)."""
    morca_main[
        Pipeline[name, Follow, partitions=Monthly["2024-01"], max_runs=4]
    ]()


def main() raises:
    run["longpoll"]()
