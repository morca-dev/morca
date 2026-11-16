"""A dated pipeline's partitions on a calendar: what state each day (or, for
a monthly pipeline, month) is in, read from the database alone.

`morca ui` draws it twice, as the picker on the Start runs form and as the
read-only coverage on a pipeline's page, and serves it as JSON at
`/pipelines/<name>/calendar?month=2023-01`. Daily pipelines have a month of
days at a time; monthly ones a year of months; weekly ones an ISO year of
its 52 or 53 weeks (`?month=2026`); hourly ones a day of hours
(`?month=2023-01-31`). The states, in the order
they win:

- `outside`: before the pipeline's first partition, or after today.
- `live`: in a queued, deferred or running run (`live_sql`).
- `done`: what a backfill counts as done (`DONE_SQL`): every mapped step
  succeeded in a run of any code with the current data version (the same
  steps' `version=`), so new code that keeps them leaves days done.
- `failed`: not done, and the last run over it failed.
- `behind`: none of these, but a dataset the sensor pipeline follows has
  it (`morca._internal.follow`); only on the page's coverage.
- `open`: none of the above, so a backfill would queue it; shown as "not
  done", since it may have been done under an older data version.

Hourly, daily, weekly and monthly keys are zero-padded, so they compare as
text.
"""

from std.collections import Dict

import morca._internal.db.calendar as calendar_db
from morca._internal.db.live import live_runs

from morca.civil import Civil, now
from morca.day import Day
from morca.hour import Hour
from morca._internal.json import quote
from morca.month import Month, days_in
from morca.week import Week, weeks_in
from morca._internal.queueing import done_keys
from morca._internal.state import State
from morca._internal.timekeys import unit_of


@fieldwise_init
struct Cell(Copyable, Movable):
    var key: String
    var state: String


struct Calendar(Movable):
    var pipeline: String
    var kind: String
    """`daily` (cells are days of one month), `monthly` (months of one
    year), `weekly` (the weeks of one ISO year) or `hourly` (hours of one
    day)."""
    var period: String
    """`YYYY-MM` for days, `YYYY` for months and weeks, `YYYY-MM-DD` for
    hours."""
    var prev: String
    """The period before, empty if it ends before the pipeline starts."""
    var next: String
    """The period after, empty if it starts after today."""
    var start: String
    var today: String
    """Today's key: `YYYY-MM-DD`, `YYYY-MM`, this week's `YYYY-Www` or, for
    hours, this hour's `YYYY-MM-DDTHH`."""
    var weekday: Int
    """Of a month's first day, with Monday as 0."""
    var cells: List[Cell]

    def __init__(out self, pipeline: String, kind: String):
        self.pipeline = pipeline
        self.kind = kind
        self.period = String()
        self.prev = String()
        self.next = String()
        self.start = String()
        self.today = String()
        self.weekday = 0
        self.cells = List[Cell]()

    def count(self, state: String) -> Int:
        var n = 0
        for c in self.cells:
            if c.state == state:
                n += 1
        return n


def _pad(n: Int, width: Int) -> String:
    var s = String(n)
    while s.byte_length() < width:
        s = String("0", s)
    return s


def _period_of(
    kind: String, text: String, today: Civil
) raises -> Tuple[Int, Int]:
    """The year and month `text` names: `YYYY-MM`, or for a monthly
    pipeline `YYYY` too; today's if it's empty."""
    if not text:
        return (today.year, today.month)
    if kind == "monthly" and text.byte_length() == 4:
        var y = Int(text)
        if y < 0:
            raise Error("not a year (YYYY): '", text, "'")
        return (y, 1)
    var m = Month.parse(text)
    return (m.year, m.month)


def calendar(
    mut db: State,
    pipeline: String,
    kind: String,
    start: String,
    period: String,
    upstream: Dict[String, Bool] = {},
) raises -> Calendar:
    """`pipeline`'s calendar of `period` (see `Calendar.period`; today's if
    empty), with `start` its first partition (or empty); keys in `upstream`
    that are only open are `behind`."""
    if kind == "hourly":
        return _hours(db, pipeline, start, period, upstream)
    if kind == "weekly":
        return _weeks(db, pipeline, start, period, upstream)
    if kind != "daily" and kind != "monthly":
        raise Error(pipeline, " has ", kind, " partitions, not dated ones")
    var t = Civil.of(now())
    var ym = _period_of(kind, period, t)
    var cal = Calendar(pipeline, kind)
    cal.start = start
    var daily = kind == "daily"
    cal.today = String(Day(t.year, t.month, t.day)) if daily else String(
        Month(t.year, t.month)
    )
    var keys = List[String]()
    if daily:
        keys = _frame_month(cal, ym[0], ym[1])
    else:
        cal.period = _pad(ym[0], 4)
        for m in range(1, 13):
            keys.append(String(Month(ym[0], m)))
        cal.prev = _pad(ym[0] - 1, 4) if (
            ym[0] > 0 and (not start or String(Month(ym[0] - 1, 12)) >= start)
        ) else String()
        cal.next = (
            _pad(ym[0] + 1, 4) if String(Month(ym[0] + 1, 1))
            <= cal.today else String()
        )
    cal.cells = _cells(
        db,
        pipeline,
        start,
        cal.today,
        keys,
        done_keys(db, pipeline, keys),
        upstream,
    )
    return cal^


def _hours(
    mut db: State,
    pipeline: String,
    start: String,
    period: String,
    upstream: Dict[String, Bool],
) raises -> Calendar:
    """An hourly pipeline's calendar: the 24 hours of the day `period`
    (`YYYY-MM-DD`; today's, UTC, if empty)."""
    var t = Civil.of(now())
    var cal = Calendar(pipeline, "hourly")
    cal.start = start
    cal.today = String(Hour(t.year, t.month, t.day, t.hour))
    var d = Day(t.year, t.month, t.day) if not period else (
        Day.parse(period) if period.byte_length()
        == 10 else Day.parse(String(period, "-01"))
    )
    cal.period = String(d)
    var keys = List[String]()
    for h in range(24):
        keys.append(String(Hour(d.year, d.month, d.day, h)))
    var before = d.prev()
    var after = d.next()
    cal.prev = String(before) if (
        not start
        or String(Hour(before.year, before.month, before.day, 23)) >= start
    ) else String()
    cal.next = (
        String(after) if String(Hour(after.year, after.month, after.day, 0))
        <= cal.today else String()
    )
    cal.cells = _cells(
        db,
        pipeline,
        start,
        cal.today,
        keys,
        done_keys(db, pipeline, keys),
        upstream,
    )
    return cal^


def _weeks(
    mut db: State,
    pipeline: String,
    start: String,
    period: String,
    upstream: Dict[String, Bool],
) raises -> Calendar:
    """A weekly pipeline's calendar: the weeks of the ISO year `period`
    (`YYYY`, or the ISO year of a `YYYY-MM` month's first day or a
    `YYYY-Www` week; this week's if empty)."""
    var t = Civil.of(now())
    var cal = Calendar(pipeline, "weekly")
    cal.start = start
    var today = Week.containing(t.year, t.month, t.day, t.hour)
    cal.today = String(today)
    var y: Int
    if not period:
        y = today.year
    elif period.byte_length() == 4:
        try:
            y = Int(period)
        except:
            raise Error("not a year (YYYY): '", period, "'")
        if y < 0:
            raise Error("not a year (YYYY): '", period, "'")
    elif period.byte_length() == 8:
        y = Week.parse(period).year
    else:
        var m = Month.parse(period)
        y = Week.containing(m.year, m.month, 1, 0).year
    cal.period = _pad(y, 4)
    var keys = List[String]()
    for w in range(1, weeks_in(y) + 1):
        keys.append(String(Week(y, w)))
    cal.prev = _pad(y - 1, 4) if (
        y > 0 and (not start or String(Week(y - 1, weeks_in(y - 1))) >= start)
    ) else String()
    cal.next = (
        _pad(y + 1, 4) if String(Week(y + 1, 1)) <= cal.today else String()
    )
    cal.cells = _cells(
        db,
        pipeline,
        start,
        cal.today,
        keys,
        done_keys(db, pipeline, keys),
        upstream,
    )
    return cal^


def _frame_month(mut cal: Calendar, year: Int, month: Int) -> List[String]:
    """Sets `cal`'s period, neighbours and weekday for the days of `month`
    of `year`, from its `start` and `today`, and returns their keys."""
    cal.period = String(Month(year, month))
    var before = Month(year, month).prev()
    var after = Month(year, month).next()
    var keys = List[String]()
    for d in range(1, days_in(year, month) + 1):
        keys.append(String(Day(year, month, d)))
    var before_last = String(
        Day(before.year, before.month, days_in(before.year, before.month))
    )
    cal.prev = String(before) if (
        not cal.start or before_last >= cal.start
    ) else String()
    cal.next = (
        String(after) if String(Day(after.year, after.month, 1))
        <= cal.today else String()
    )
    cal.weekday = (Civil(year, month, 1, 0, 0, 0).weekday() + 6) % 7
    return keys^


def _cells(
    mut db: State,
    pipeline: String,
    start: String,
    today: String,
    keys: List[String],
    done: Dict[String, Bool],
    upstream: Dict[String, Bool] = {},
) raises -> List[Cell]:
    """Each of `keys` with its state, given which are `done` and which the
    datasets a sensor follows have (`upstream`, `morca._internal.follow`): the live
    runs and the last run of each key are a query each, whatever the
    keys."""
    var joined = String()
    for i in range(len(keys)):
        joined.write("," if i else "", keys[i])
    var live = Dict[String, Bool]()
    for e in live_runs(db.conn, pipeline).items():
        live[e.key] = True
    var failed = Dict[String, Bool]()
    for k in calendar_db.failed_keys(db.conn, pipeline, joined):
        failed[k] = True
    var cells = List[Cell]()
    for k in keys:
        var state: String
        if (start and k < start) or k > today:
            state = "outside"
        elif k in live:
            state = "live"
        elif k in done:
            state = "done"
        elif k in failed:
            state = "failed"
        elif k in upstream:
            state = "behind"
        else:
            state = "open"
        cells.append(Cell(k, state))
    return cells^


@fieldwise_init
struct Share(Copyable, Movable):
    """Of one month in a daily pipeline's range, how many days are done."""

    var key: String
    """`YYYY-MM`."""
    var done: Int
    var total: Int
    """Its days in the range: from the start to today."""


comptime STRIP_YEARS = 10
"""The range strip's most years, ending at today's."""


struct Year(Movable):
    """A daily pipeline's days of one year, and how done each month of its
    range is."""

    var pipeline: String
    var start: String
    var today: String
    var year: Int
    var prev: String
    """The year before (`YYYY`), empty if it ends before the start."""
    var next: String
    """The year after, empty if it starts after today."""
    var cells: List[Cell]
    """Each day of the year, January 1 first."""
    var strip: List[Share]
    """Each month from the start's (at most `STRIP_YEARS` back) to today's,
    empty for a pipeline without a start."""

    def __init__(out self, pipeline: String, start: String):
        self.pipeline = pipeline
        self.start = start
        self.today = String()
        self.year = 0
        self.prev = String()
        self.next = String()
        self.cells = List[Cell]()
        self.strip = List[Share]()

    def first(self, month: Int) -> Int:
        """The index in `cells` of `month`'s first day."""
        var i = 0
        for m in range(1, month):
            i += days_in(self.year, m)
        return i

    def count(self, state: String, month: Int = 0) -> Int:
        """The days in `state`, of `month` (1 to 12) or of the year (0)."""
        var lo = 0 if month == 0 else self.first(month)
        var hi = len(self.cells) if month == 0 else lo + days_in(
            self.year, month
        )
        var n = 0
        for i in range(lo, hi):
            if self.cells[i].state == state:
                n += 1
        return n


def year_of(text: String, today: Civil) raises -> Tuple[Int, Int]:
    """The year and month a coverage link names: `YYYY-MM`, or `YYYY` with
    today's month in today's year, December before it and January after;
    today's if `text` is empty."""
    if not text:
        return (today.year, today.month)
    if text.byte_length() == 4:
        var y: Int
        try:
            y = Int(text)
        except:
            raise Error("not a year (YYYY) or month (YYYY-MM): '", text, "'")
        if y < 0:
            raise Error("not a year (YYYY) or month (YYYY-MM): '", text, "'")
        var m = today.month if y == today.year else (
            12 if y < today.year else 1
        )
        return (y, m)
    var m = Month.parse(text)
    return (m.year, m.month)


def year_calendar(
    mut db: State,
    pipeline: String,
    start: String,
    year: Int,
    upstream: Dict[String, Bool] = {},
) raises -> Year:
    """The days of `year` of the daily `pipeline` that starts at `start`
    (or has no start), and its range strip. Three queries, as for a month:
    which days are done (of the year and the strip's range together), the
    live runs, and each of the year's days' last run."""
    var t = Civil.of(now())
    var y = Year(pipeline, start)
    y.year = year
    y.today = String(Day(t.year, t.month, t.day))
    y.prev = _pad(year - 1, 4) if (
        year > 0 and (not start or String(Day(year - 1, 12, 31)) >= start)
    ) else String()
    y.next = (
        _pad(year + 1, 4) if String(Day(year + 1, 1, 1))
        <= y.today else String()
    )
    var keys = List[String]()
    for m in range(1, 13):
        for d in range(1, days_in(year, m) + 1):
            keys.append(String(Day(year, m, d)))
    # The strip's days, from the start (or STRIP_YEARS back) to today; the
    # year's own are asked for once.
    var asked = keys.copy()
    var months = List[Month]()
    if start:
        var first = Day.parse(start)
        var lo = Month(first.year, first.month)
        if lo.year < t.year - STRIP_YEARS + 1:
            lo = Month(t.year - STRIP_YEARS + 1, 1)
        var m = lo.copy()
        var last = Month(t.year, t.month)
        while not (last < m):
            months.append(m.copy())
            if m.year != year:
                for d in range(1, days_in(m.year, m.month) + 1):
                    var k = String(Day(m.year, m.month, d))
                    if k >= start and k <= y.today:
                        asked.append(k)
            m = m.next()
    var done = done_keys(db, pipeline, asked)
    y.cells = _cells(db, pipeline, start, y.today, keys, done, upstream)
    for m in months:
        var n = 0
        var total = 0
        for d in range(1, days_in(m.year, m.month) + 1):
            var k = String(Day(m.year, m.month, d))
            if k < start or k > y.today:
                continue
            total += 1
            if k in done:
                n += 1
        y.strip.append(Share(String(m), n, total))
    return y^


def month_of(y: Year, month: Int) -> Calendar:
    """The month view of `month` (1 to 12) of `y`, from its cells."""
    var cal = Calendar(y.pipeline, "daily")
    cal.start = y.start
    cal.today = y.today
    _ = _frame_month(cal, y.year, month)
    var lo = y.first(month)
    for i in range(lo, lo + days_in(y.year, month)):
        cal.cells.append(y.cells[i].copy())
    return cal^


def calendar_json(c: Calendar) -> String:
    """`c` as JSON, with each state's count."""
    var j = String('{"pipeline": ', quote(c.pipeline))
    j.write(
        ', "kind": ',
        quote(c.kind),
        ', "unit": ',
        quote(unit_of(c.kind)),
        ', "period": ',
        quote(c.period),
        ', "prev": ',
        quote(c.prev) if c.prev else String("null"),
        ', "next": ',
        quote(c.next) if c.next else String("null"),
        ', "start": ',
        quote(c.start) if c.start else String("null"),
        ', "today": ',
        quote(c.today),
        ', "weekday": ',
        c.weekday,
        ', "cells": [',
    )
    for i in range(len(c.cells)):
        j.write(
            ", " if i else "",
            '{"key": ',
            quote(c.cells[i].key),
            ', "state": ',
            quote(c.cells[i].state),
            "}",
        )
    j.write('], "counts": {')
    var states = ["done", "failed", "live", "open", "outside"]
    for i in range(len(states)):
        j.write(
            ", " if i else "",
            quote(states[i]),
            ": ",
            c.count(String(states[i])),
        )
    j.write("}}")
    return j^


def states_of(
    mut db: State,
    pipeline: String,
    start: String,
    today: String,
    keys: List[String],
) raises -> List[Cell]:
    """Each of `keys` with its state, as on the calendar: three queries."""
    return _cells(
        db, pipeline, start, today, keys, done_keys(db, pipeline, keys)
    )
