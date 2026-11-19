"""Calendar arithmetic: dates to days since 1970-01-01 and back.

The algorithms are Howard Hinnant's (`days_from_civil`, and
`civil_from_days` in `Civil.of`), exact over the proleptic Gregorian calendar. Times are seconds since the
epoch; a *local* time is the same count read on a wall clock, as if the zone
were UTC, which is what cron matches against.
"""

from std.ffi import external_call
from std.os import getenv

from morca.month import days_in


def days_from_civil(year: Int, month: Int, day: Int) -> Int64:
    """Days from 1970-01-01 to the date."""
    var y = year - 1 if month <= 2 else year
    var era = (y if y >= 0 else y - 399) // 400
    var yoe = y - era * 400
    var mp = month - 3 if month > 2 else month + 9
    var doy = (153 * mp + 2) // 5 + day - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return Int64(era * 146097 + doe - 719468)


@fieldwise_init
struct Civil(Copyable, Movable, Writable):
    """A date and a time of day, on a wall clock."""

    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int

    @staticmethod
    def of(t: Int64) -> Civil:
        """The date and time `t` seconds after 1970-01-01T00:00."""
        var days = t // 86400
        var secs = Int(t - days * 86400)
        var z = Int(days) + 719468
        var era = (z if z >= 0 else z - 146096) // 146097
        var doe = z - era * 146097
        var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
        var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
        var mp = (5 * doy + 2) // 153
        var d = doy - (153 * mp + 2) // 5 + 1
        var m = mp + 3 if mp < 10 else mp - 9
        var y = yoe + era * 400 + (1 if m <= 2 else 0)
        return Civil(y, m, d, secs // 3600, secs // 60 % 60, secs % 60)

    def seconds(self) -> Int64:
        """The inverse of `of`."""
        return days_from_civil(self.year, self.month, self.day) * 86400 + Int64(
            self.hour * 3600 + self.minute * 60 + self.second
        )

    def weekday(self) -> Int:
        """0 for Sunday to 6 for Saturday."""
        return Int((days_from_civil(self.year, self.month, self.day) + 4) % 7)

    def write_to(self, mut writer: Some[Writer]):
        """`YYYY-MM-DDTHH:MM:SS`."""
        writer.write(self.year, "-")
        _two(writer, self.month)
        writer.write("-")
        _two(writer, self.day)
        writer.write("T")
        _two(writer, self.hour)
        writer.write(":")
        _two(writer, self.minute)
        writer.write(":")
        _two(writer, self.second)


def _two(mut writer: Some[Writer], n: Int):
    if n < 10:
        writer.write("0")
    writer.write(n)


def utc(
    year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0
) -> Int64:
    """Seconds since the epoch at a UTC date and time."""
    return Civil(year, month, day, hour, minute, 0).seconds()


def parse_time(s: StringSpan) raises -> Int64:
    """Reads `YYYY-MM-DDTHH:MM[:SS]Z`, a UTC time, or a number of seconds
    since the epoch."""
    var text = String(s)
    if text and "-" not in text:
        return Int64(Int(text))
    var bad = Error("not a time (YYYY-MM-DDTHH:MM[:SS]Z): '", s, "'")
    if not text.endswith("Z") or "T" not in text:
        raise bad^
    var halves = text.removesuffix("Z").split("T")
    if len(halves) != 2:
        raise bad^
    var date = halves[0].split("-")
    var time = halves[1].split(":")
    if len(date) != 3 or len(time) < 2 or len(time) > 3:
        raise bad^
    var c = Civil(
        Int(date[0]),
        Int(date[1]),
        Int(date[2]),
        Int(time[0]),
        Int(time[1]),
        Int(time[2]) if len(time) == 3 else 0,
    )
    if (
        date[0].byte_length() != 4
        or c.month < 1
        or c.month > 12
        or c.day < 1
        or c.day > days_in(c.year, c.month)
        or c.hour < 0
        or c.hour > 23
        or c.minute < 0
        or c.minute > 59
        or c.second < 0
        or c.second > 59
    ):
        raise bad^
    return c.seconds()


def now() raises -> Int64:
    """Seconds since the epoch: `MORCA_NOW` if it's set (a time `parse_time`
    reads), else the system clock. The scheduler's tests fix time with it."""
    var fixed = getenv("MORCA_NOW")
    if fixed:
        return parse_time(fixed)
    return external_call["time", Int64](Int(0))
