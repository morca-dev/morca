"""Schedules: when a pipeline runs by itself, and which partition each fire runs.

```mojo
comptime Taxi = Pipeline[
    "taxi", Download, Load, Compact,
    partitions=Monthly["2011-01"],
    schedule=Cron["0 3 2 * *", "America/New_York"],  # 03:00 on the 2nd
    fire=Previous,                                    # last month
]
```

A fire at some time runs the partition the time falls in on the schedule's
wall clock (`fire=Current`), or the one before it (`fire=Previous`, the
default): a monthly load that runs on the 2nd loads the month that just
ended. `fills=` is `fire=`'s old name, accepted for one more release; it
is unrelated to morca.toml's `fills`, which backfills a pipeline's range.
`catchup=False` tells the scheduler to start only the latest of the fires it
missed while it was down. The scheduler itself is phase 2's next PR; until
then a schedule is declared, checked, and shown by `describe` and `fires`.
"""

from morca.cron import CronExpr
from morca.tz import Zone


@fieldwise_init
struct Fill(Equatable, TrivialRegisterPassable, Writable):
    """Which partition a fire runs (`Pipeline[..., fire=]`)."""

    var value: Int

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def write_to(self, mut writer: Some[Writer]):
        writer.write("current" if self.value == 1 else "previous")


comptime Previous = Fill(0)
"""The partition before the one the fire's time falls in."""
comptime Current = Fill(1)
"""The partition the fire's time falls in."""
comptime _NoFill = Fill(-1)
"""`Pipeline`'s `fills=` when it isn't set: `fire=` decides."""


trait ScheduleLike:
    @staticmethod
    def expr() -> StaticString:
        """The cron expression; empty for no schedule."""
        ...

    @staticmethod
    def zone() -> StaticString:
        """The time zone's name, such as `America/New_York`."""
        ...


struct NoSchedule(ScheduleLike):
    """Runs only when started by hand or by a backfill."""

    @staticmethod
    def expr() -> StaticString:
        return ""

    @staticmethod
    def zone() -> StaticString:
        return ""


struct Cron[cron: StaticString, tz: StaticString = "UTC"](ScheduleLike):
    """Fires when `cron` matches on the wall clock of time zone `tz`."""

    @staticmethod
    def expr() -> StaticString:
        return Self.cron

    @staticmethod
    def zone() -> StaticString:
        return Self.tz


@fieldwise_init
struct Schedule(Copyable, Movable):
    """A pipeline's schedule, parsed and with its zone loaded."""

    var cron: CronExpr
    var zone: Zone

    @staticmethod
    def of[S: ScheduleLike]() raises -> Schedule:
        return Schedule(CronExpr.parse(S.expr()), Zone.load(S.zone()))

    def next_fire(self, after: Int64) raises -> Int64:
        return self.cron.next_fire(after, self.zone)
