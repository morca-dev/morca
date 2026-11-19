"""`Day`: the partition key of a daily pipeline.

A day is written `YYYY-MM-DD`, and a range of them `2024-01-01..2024-01-31`,
both ends included.
"""

from morca.key import TimeKey
from morca.month import Month, days_in


@fieldwise_init
struct Day(TimeKey):
    """A day of the Gregorian calendar."""

    var year: Int
    var month: Int
    var day: Int

    @staticmethod
    def parse(s: StringSpan) raises -> Day:
        """Reads `YYYY-MM-DD`."""
        var parts = s.split("-")
        if (
            len(parts) != 3
            or parts[0].byte_length() != 4
            or parts[1].byte_length() != 2
            or parts[2].byte_length() != 2
        ):
            raise Error("not a day (YYYY-MM-DD): '", s, "'")
        var d = Day(Int(parts[0]), Int(parts[1]), Int(parts[2]))
        if d.year < 0 or d.month < 1 or d.month > 12:
            raise Error("not a day (YYYY-MM-DD): '", s, "'")
        if d.day < 1 or d.day > days_in(d.year, d.month):
            raise Error("not a day (YYYY-MM-DD): '", s, "'")
        return d^

    def next(self) -> Day:
        """The day after this one."""
        if self.day < days_in(self.year, self.month):
            return Day(self.year, self.month, self.day + 1)
        if self.month < 12:
            return Day(self.year, self.month + 1, 1)
        return Day(self.year + 1, 1, 1)

    def prev(self) -> Day:
        """The day before this one."""
        if self.day > 1:
            return Day(self.year, self.month, self.day - 1)
        var m = Month(self.year, self.month).prev()
        return Day(m.year, m.month, days_in(m.year, m.month))

    @staticmethod
    def containing(year: Int, month: Int, day: Int, hour: Int) -> Day:
        return Day(year, month, day)

    def month_of(self) -> Month:
        return Month(self.year, self.month)

    def __eq__(self, other: Self) -> Bool:
        return (
            self.year == other.year
            and self.month == other.month
            and self.day == other.day
        )

    def __lt__(self, other: Self) -> Bool:
        if self.year != other.year:
            return self.year < other.year
        if self.month != other.month:
            return self.month < other.month
        return self.day < other.day

    def write_to(self, mut writer: Some[Writer]):
        writer.write(Month(self.year, self.month), "-")
        if self.day < 10:
            writer.write("0")
        writer.write(self.day)
