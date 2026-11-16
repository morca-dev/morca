"""Partition sets: which keys a pipeline is partitioned by, from when.

```mojo
comptime Taxi = Pipeline[
    "taxi", Download, Load, Compact, partitions=Monthly["2011-01"]
]
comptime Weather = Pipeline["weather", Fetch, partitions=Daily["2020-01-01"]]
comptime Stats = Pipeline["stats", Count, partitions=Weekly["2026-W40"]]
comptime Poll = Pipeline["poll", Poll, partitions=Hourly["2026-11-11T00"]]
comptime Labels = Pipeline["labels", Label, partitions=Keyed["av2.logs", "log_id"]]
```

A pipeline's first step takes its key (`Month` for `Monthly`, `Week` for
`Weekly` (ISO weeks, `2026-W46`), `Day` for `Daily`, `Hour` for `Hourly`, `Name` for `morca.keyed.Keyed`), or a `Seq` of them for a first
gather step. `start` is the first partition: keys before it are refused,
and phase 2's scheduler and backfills count from it. A pipeline without
`partitions=` is `Monthly[]`, with no start.

Each set reads `--partitions` itself (`parse`): time keys take keys and
ranges, keyed partitions lists of names. Only time keys have a calendar, so
only they `fill` a schedule's partition, and only keyed partitions have
current `keys`, read from their dataset.
"""

from morca.day import Day
from morca.hour import Hour
from morca.key import Key, TimeKey, parse_keys
from morca.month import Month
from morca.week import Week


trait Partitions:
    comptime K: Key
    """The partition key."""

    @staticmethod
    def kind() -> StaticString:
        """`monthly`, `weekly`, `daily`, `hourly` or `keyed`, as `describe` writes it.
        """
        ...

    @staticmethod
    def start() -> StaticString:
        """The first partition, as text; empty for none."""
        ...

    @staticmethod
    def dataset() -> StaticString:
        """The dataset keyed partitions' keys come from; empty for time."""
        ...

    @staticmethod
    def column() -> StaticString:
        ...

    @staticmethod
    def parse(s: StringSlice, check: Bool) raises -> List[Self.K]:
        """The keys `s` names, as `run --partitions` takes them. With
        `check`, keyed partitions refuse a name their dataset doesn't have
        now; a resume doesn't check, as the run's keys were checked when it
        was made."""
        ...

    @staticmethod
    def fill(
        year: Int, month: Int, day: Int, hour: Int, previous: Bool
    ) raises -> Self.K:
        """The key a date and hour fall in, or the one before it; raises for
        keys that aren't dates."""
        ...

    @staticmethod
    def keys() raises -> Tuple[Int64, List[String]]:
        """The keys dataset's current snapshot and its keys, sorted; raises
        for time keys."""
        ...


def _fill[
    K: TimeKey
](year: Int, month: Int, day: Int, hour: Int, previous: Bool) -> K:
    var k = K.containing(year, month, day, hour)
    return k.prev() if previous else k^


struct Monthly[first: StaticString = ""](Partitions):
    """A partition per month, from `first` (`YYYY-MM`) if given."""

    comptime K = Month

    @staticmethod
    def kind() -> StaticString:
        return "monthly"

    @staticmethod
    def start() -> StaticString:
        return Self.first

    @staticmethod
    def dataset() -> StaticString:
        return ""

    @staticmethod
    def column() -> StaticString:
        return ""

    @staticmethod
    def parse(s: StringSlice, check: Bool) raises -> List[Month]:
        return parse_keys[Month](s, Self.first)

    @staticmethod
    def fill(
        year: Int, month: Int, day: Int, hour: Int, previous: Bool
    ) raises -> Month:
        return _fill[Month](year, month, day, hour, previous)

    @staticmethod
    def keys() raises -> Tuple[Int64, List[String]]:
        raise Error("morca: monthly partitions have no keys dataset")


struct Weekly[first: StaticString = ""](Partitions):
    """A partition per ISO week, Monday to Sunday, from `first` (`YYYY-Www`)
    if given."""

    comptime K = Week

    @staticmethod
    def kind() -> StaticString:
        return "weekly"

    @staticmethod
    def start() -> StaticString:
        return Self.first

    @staticmethod
    def dataset() -> StaticString:
        return ""

    @staticmethod
    def column() -> StaticString:
        return ""

    @staticmethod
    def parse(s: StringSlice, check: Bool) raises -> List[Week]:
        return parse_keys[Week](s, Self.first)

    @staticmethod
    def fill(
        year: Int, month: Int, day: Int, hour: Int, previous: Bool
    ) raises -> Week:
        return _fill[Week](year, month, day, hour, previous)

    @staticmethod
    def keys() raises -> Tuple[Int64, List[String]]:
        raise Error("morca: weekly partitions have no keys dataset")


struct Daily[first: StaticString = ""](Partitions):
    """A partition per day, from `first` (`YYYY-MM-DD`) if given."""

    comptime K = Day

    @staticmethod
    def kind() -> StaticString:
        return "daily"

    @staticmethod
    def start() -> StaticString:
        return Self.first

    @staticmethod
    def dataset() -> StaticString:
        return ""

    @staticmethod
    def column() -> StaticString:
        return ""

    @staticmethod
    def parse(s: StringSlice, check: Bool) raises -> List[Day]:
        return parse_keys[Day](s, Self.first)

    @staticmethod
    def fill(
        year: Int, month: Int, day: Int, hour: Int, previous: Bool
    ) raises -> Day:
        return _fill[Day](year, month, day, hour, previous)

    @staticmethod
    def keys() raises -> Tuple[Int64, List[String]]:
        raise Error("morca: daily partitions have no keys dataset")


struct Hourly[first: StaticString = ""](Partitions):
    """A partition per hour, from `first` (`YYYY-MM-DDTHH`) if given, on the
    schedule's wall clock (UTC without a zone)."""

    comptime K = Hour

    @staticmethod
    def kind() -> StaticString:
        return "hourly"

    @staticmethod
    def start() -> StaticString:
        return Self.first

    @staticmethod
    def dataset() -> StaticString:
        return ""

    @staticmethod
    def column() -> StaticString:
        return ""

    @staticmethod
    def parse(s: StringSlice, check: Bool) raises -> List[Hour]:
        return parse_keys[Hour](s, Self.first)

    @staticmethod
    def fill(
        year: Int, month: Int, day: Int, hour: Int, previous: Bool
    ) raises -> Hour:
        return _fill[Hour](year, month, day, hour, previous)

    @staticmethod
    def keys() raises -> Tuple[Int64, List[String]]:
        raise Error("morca: hourly partitions have no keys dataset")


def parse_partitions[P: Partitions](s: StringSlice) raises -> List[P.K]:
    """The keys of `P` that `s` names, as `run --partitions` takes them: for
    time keys a key, `A..B`, or a comma-separated list of either; for keyed
    partitions a list of names, `@all` or `@file:<path>`."""
    return P.parse(s, check=True)
