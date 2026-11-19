"""`Hour`: the partition key of an hourly pipeline.

An hour is written `YYYY-MM-DDTHH` (`2024-01-31T07`, the hour from 07:00 to
08:00 on the schedule's wall clock, UTC without a zone), and a range of them
`2024-01-31T00..2024-01-31T23`, both ends included.
"""

from morca.day import Day
from morca.key import TimeKey
from morca.month import Month


@fieldwise_init
struct Hour(TimeKey):
    """An hour of a day of the Gregorian calendar, `hour` from 0 to 23."""

    var year: Int
    var month: Int
    var day: Int
    var hour: Int

    @staticmethod
    def parse(s: StringSpan) raises -> Hour:
        """Reads `YYYY-MM-DDTHH`."""
        var parts = s.split("T")
        if len(parts) != 2 or parts[1].byte_length() != 2:
            raise Error("not an hour (YYYY-MM-DDTHH): '", s, "'")
        var d: Day
        var h: Int
        try:
            d = Day.parse(parts[0])
            h = Int(parts[1])
        except:
            raise Error("not an hour (YYYY-MM-DDTHH): '", s, "'")
        if h < 0 or h > 23:
            raise Error("not an hour (YYYY-MM-DDTHH): '", s, "'")
        return Hour(d.year, d.month, d.day, h)

    def next(self) -> Hour:
        """The hour after this one."""
        if self.hour < 23:
            return Hour(self.year, self.month, self.day, self.hour + 1)
        var d = self.day_of().next()
        return Hour(d.year, d.month, d.day, 0)

    def prev(self) -> Hour:
        """The hour before this one."""
        if self.hour > 0:
            return Hour(self.year, self.month, self.day, self.hour - 1)
        var d = self.day_of().prev()
        return Hour(d.year, d.month, d.day, 23)

    @staticmethod
    def containing(year: Int, month: Int, day: Int, hour: Int) -> Hour:
        return Hour(year, month, day, hour)

    def day_of(self) -> Day:
        return Day(self.year, self.month, self.day)

    def month_of(self) -> Month:
        return Month(self.year, self.month)

    def __eq__(self, other: Self) -> Bool:
        return (
            self.year == other.year
            and self.month == other.month
            and self.day == other.day
            and self.hour == other.hour
        )

    def __lt__(self, other: Self) -> Bool:
        if self.year != other.year:
            return self.year < other.year
        if self.month != other.month:
            return self.month < other.month
        if self.day != other.day:
            return self.day < other.day
        return self.hour < other.hour

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.day_of(), "T")
        if self.hour < 10:
            writer.write("0")
        writer.write(self.hour)
