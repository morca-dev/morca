"""Time keys by their partitions' kind (`monthly`, `weekly`, `daily`,
`hourly`), as
text: for code that has a pipeline's kind as a string, not its type."""

from morca.day import Day
from morca.hour import Hour
from morca.key import parse_keys
from morca.month import Month
from morca.week import Week


def is_time_kind(kind: StringSlice) -> Bool:
    """Whether `kind` is a calendar's: `monthly`, `weekly`, `daily` or
    `hourly`."""
    return (
        kind == "monthly"
        or kind == "weekly"
        or kind == "daily"
        or kind == "hourly"
    )


def unit_of(kind: StringSlice) -> String:
    """`month`, `week`, `day` or `hour`; `key` for any other kind."""
    if kind == "monthly":
        return "month"
    if kind == "weekly":
        return "week"
    if kind == "daily":
        return "day"
    if kind == "hourly":
        return "hour"
    return "key"


def example_of(kind: StringSlice) -> String:
    """A key of `kind`, for help texts."""
    if kind == "hourly":
        return "2024-01-01T00"
    if kind == "daily":
        return "2024-01-01"
    if kind == "weekly":
        return "2024-W01"
    return "2024-01"


def parse_time_keys(
    kind: StringSlice, s: StringSlice, first: StringSlice = ""
) raises -> List[String]:
    """`parse_keys` for the key type of `kind` (monthly for any other), as
    text."""
    var out = List[String]()
    if kind == "hourly":
        for k in parse_keys[Hour](s, first):
            out.append(String(k))
    elif kind == "daily":
        for k in parse_keys[Day](s, first):
            out.append(String(k))
    elif kind == "weekly":
        for k in parse_keys[Week](s, first):
            out.append(String(k))
    else:
        for k in parse_keys[Month](s, first):
            out.append(String(k))
    return out^


def containing_key(
    kind: StringSlice, year: Int, month: Int, day: Int, hour: Int
) -> String:
    """The key of `kind` (monthly for any other) a date and hour fall in."""
    if kind == "hourly":
        return String(Hour(year, month, day, hour))
    if kind == "daily":
        return String(Day(year, month, day))
    if kind == "weekly":
        return String(Week.containing(year, month, day, hour))
    return String(Month(year, month))


def prev_key(kind: StringSlice, key: StringSlice) raises -> String:
    """The key before `key`, of `kind` (monthly for any other)."""
    if kind == "hourly":
        return String(Hour.parse(key).prev())
    if kind == "daily":
        return String(Day.parse(key).prev())
    if kind == "weekly":
        return String(Week.parse(key).prev())
    return String(Month.parse(key).prev())
