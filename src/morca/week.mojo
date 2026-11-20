"""`Week`: the partition key of a weekly pipeline.

A week is an ISO 8601 week, Monday to Sunday, written `YYYY-Www`
(`2026-W46`, the week from Monday 2026-11-09 to Sunday 2026-11-15), and a
range of them `2026-W01..2026-W52`, both ends included. `YYYY` is the ISO
week-numbering year, the year of the week's Thursday: week 1 is the week
with the year's first Thursday (the one with January 4th), so 2024-12-30 is
in `2025-W01` and 2021-01-03 in `2020-W53`. A year has 52 weeks, or 53 when
it starts on a Thursday, or is a leap year starting on a Wednesday. The year
and week are zero-padded, so weeks order as text.
"""

from morca.civil import Civil, days_from_civil
from morca.day import Day
from morca.key import TimeKey
from morca.month import Month


def _iso_weekday(days: Int64) -> Int:
    """0 for Monday to 6 for Sunday, of a day `days` after 1970-01-01 (a
    Thursday)."""
    return Int((days + 3) % 7)


def weeks_in(year: Int) -> Int:
    """The number of ISO weeks in the ISO year `year`: 52 or 53."""
    # December 28th is always in the year's last week.
    return Week.containing(year, 12, 28, 0).week


@fieldwise_init
struct Week(TimeKey):
    """An ISO week, `week` from 1 to `weeks_in(year)` of ISO year `year`."""

    var year: Int
    var week: Int

    @staticmethod
    def parse(s: StringSpan) raises -> Week:
        """Reads `YYYY-Www`."""
        var parts = s.split("-W")
        if (
            len(parts) != 2
            or parts[0].byte_length() != 4
            or parts[1].byte_length() != 2
        ):
            raise Error("not a week (YYYY-Www): '", s, "'")
        var w: Week
        try:
            w = Week(Int(parts[0]), Int(parts[1]))
        except:
            raise Error("not a week (YYYY-Www): '", s, "'")
        if w.year < 0 or w.week < 1 or w.week > weeks_in(w.year):
            raise Error("not a week (YYYY-Www): '", s, "'")
        return w^

    def next(self) -> Week:
        """The week after this one."""
        if self.week < weeks_in(self.year):
            return Week(self.year, self.week + 1)
        return Week(self.year + 1, 1)

    def prev(self) -> Week:
        """The week before this one."""
        if self.week > 1:
            return Week(self.year, self.week - 1)
        return Week(self.year - 1, weeks_in(self.year - 1))

    @staticmethod
    def containing(year: Int, month: Int, day: Int, hour: Int) -> Week:
        var days = days_from_civil(year, month, day)
        # The week's Thursday: its ISO year is the week's.
        var thursday = days - Int64(_iso_weekday(days)) + 3
        var y = Civil.of(thursday * 86400).year
        var w = Int((thursday - days_from_civil(y, 1, 1)) // 7) + 1
        return Week(y, w)

    def monday(self) -> Day:
        """The week's first day."""
        var jan4 = days_from_civil(self.year, 1, 4)
        var d = jan4 - Int64(_iso_weekday(jan4)) + Int64(7 * (self.week - 1))
        var c = Civil.of(d * 86400)
        return Day(c.year, c.month, c.day)

    def days(self) -> List[Day]:
        """The week's seven days, Monday first."""
        var out = List[Day]()
        var d = self.monday()
        for _ in range(7):
            out.append(d.copy())
            d = d.next()
        return out^

    def months(self) -> List[Month]:
        """The one or two months the week's days fall in, in order."""
        var out = List[Month]()
        for d in self.days():
            var m = d.month_of()
            if len(out) == 0 or not (out[len(out) - 1] == m):
                out.append(m^)
        return out^

    def __eq__(self, other: Self) -> Bool:
        return self.year == other.year and self.week == other.week

    def __lt__(self, other: Self) -> Bool:
        if self.year != other.year:
            return self.year < other.year
        return self.week < other.week

    def write_to(self, mut writer: Some[Writer]):
        if self.year < 1000:
            writer.write("0")
        if self.year < 100:
            writer.write("0")
        if self.year < 10:
            writer.write("0")
        writer.write(self.year, "-W")
        if self.week < 10:
            writer.write("0")
        writer.write(self.week)
