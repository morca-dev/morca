"""`Month`: the partition key of a monthly pipeline.

A month is written `YYYY-MM`, and a range of them `2024-01..2024-12`, both
ends included. A run is over a list of months; a mapped step runs once for
each.
"""

from morca.key import TimeKey, parse_keys


@fieldwise_init
struct Month(TimeKey):
    """A calendar month, `month` from 1 to 12."""

    var year: Int
    var month: Int

    @staticmethod
    def parse(s: StringSpan) raises -> Month:
        """Reads `YYYY-MM`."""
        var parts = s.split("-")
        if len(parts) != 2 or parts[0].byte_length() != 4:
            raise Error("not a month (YYYY-MM): '", s, "'")
        if parts[1].byte_length() != 2:
            raise Error("not a month (YYYY-MM): '", s, "'")
        var m = Month(Int(parts[0]), Int(parts[1]))
        if m.month < 1 or m.month > 12:
            raise Error("not a month (YYYY-MM): '", s, "'")
        return m^

    def next(self) -> Month:
        """The month after this one."""
        if self.month == 12:
            return Month(self.year + 1, 1)
        return Month(self.year, self.month + 1)

    def prev(self) -> Month:
        """The month before this one."""
        if self.month == 1:
            return Month(self.year - 1, 12)
        return Month(self.year, self.month - 1)

    @staticmethod
    def containing(year: Int, month: Int, day: Int, hour: Int) -> Month:
        return Month(year, month)

    def __eq__(self, other: Self) -> Bool:
        return self.year == other.year and self.month == other.month

    def __lt__(self, other: Self) -> Bool:
        if self.year != other.year:
            return self.year < other.year
        return self.month < other.month

    def write_to(self, mut writer: Some[Writer]):
        if self.year < 1000:
            writer.write("0")
        if self.year < 100:
            writer.write("0")
        if self.year < 10:
            writer.write("0")
        writer.write(self.year, "-")
        if self.month < 10:
            writer.write("0")
        writer.write(self.month)


def days_in(year: Int, month: Int) -> Int:
    """The number of days in a month of the Gregorian calendar."""
    if month == 2:
        var leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0
        return 29 if leap else 28
    if month == 4 or month == 6 or month == 9 or month == 11:
        return 30
    return 31


def parse_months(s: StringSpan) raises -> List[Month]:
    """Reads `YYYY-MM`, `YYYY-MM..YYYY-MM` (both ends included), or a
    comma-separated list of either, in the order given."""
    return parse_keys[Month](s)
