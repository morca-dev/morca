"""Cron expressions, and when they next fire in a time zone.

```mojo
var c = CronExpr.parse("0 3 2 * *")          # 03:00 on the 2nd
var t = c.next_fire(now(), Zone.load("America/New_York"))
```

Five fields: minute (0-59), hour (0-23), day of month (1-31), month (1-12
or `jan`-`dec`) and day of week (0-7 or `sun`-`sat`, 0 and 7 both Sunday).
A field is a list of `*`, `a`, `a-b`, each with an optional `/step`
(`a/step` runs from `a` to the field's end). `@yearly`, `@annually`,
`@monthly`, `@weekly`, `@daily`, `@midnight` and `@hourly` stand for the
usual expressions.

As in Vixie cron, when both the day of month and the day of week are
restricted (neither starts with `*`), a day matches if either does.

Times are matched on the zone's wall clock. A time that a spring-forward
skips fires at the first moment after the gap, and a time that a fall-back
repeats fires once, at its first occurrence, as Vixie cron and systemd
timers do. An expression that can never match, such as `0 0 30 2 *`, is
refused when it's parsed.
"""

from morca.civil import Civil
from morca.month import days_in
from morca.tz import Zone

comptime _MONTHS = "jan feb mar apr may jun jul aug sep oct nov dec"
comptime _DAYS = "sun mon tue wed thu fri sat"


def _number(s: StringSpan, names: StaticString, first: Int) raises -> Int:
    """A field value: digits, or a three-letter name (`names` lists them in
    order, from `first`)."""
    if s.byte_length() == 0:
        raise Error("cron: an empty value")
    var c = Int(s.as_bytes()[0])
    if c >= 48 and c <= 57:
        var n = 0
        for b in s.as_bytes():
            if b < 48 or b > 57 or n > 1000:
                raise Error("cron: not a number: '", s, "'")
            n = n * 10 + Int(b) - 48
        return n
    if names:
        var lower = String(s).lower()
        var k = first
        for name in names.split(" "):
            if lower == name:
                return k
            k += 1
    raise Error("cron: not a value: '", s, "'")


def _field(
    text: StringSpan, lo: Int, hi: Int, names: StaticString = ""
) raises -> UInt64:
    """The values a field allows, as bits `lo` to `hi`."""
    var bits = UInt64(0)
    for item in text.split(","):
        var step = 1
        var base = item
        var slash = item.split("/")
        if len(slash) > 2:
            raise Error("cron: two steps in '", item, "'")
        if len(slash) == 2:
            base = slash[0]
            step = _number(slash[1], "", 0)
            if step < 1 or step > hi:
                raise Error("cron: bad step in '", item, "'")
        var a: Int
        var b: Int
        if base == "*":
            a = lo
            b = hi
        else:
            var dash = base.split("-")
            if len(dash) > 2:
                raise Error("cron: bad range '", item, "'")
            a = _number(dash[0], names, lo)
            if len(dash) == 2:
                b = _number(dash[1], names, lo)
            elif len(slash) == 2:
                b = hi
            else:
                b = a
        if a < lo or b > hi or a > b:
            raise Error("cron: '", item, "' is outside ", lo, "-", hi)
        var v = a
        while v <= b:
            bits |= UInt64(1) << UInt64(v)
            v += step
    return bits


def _has(bits: UInt64, v: Int) -> Bool:
    return (bits >> UInt64(v)) & 1 == 1


struct CronExpr(Copyable, Movable, Writable):
    """A parsed cron expression."""

    var text: String
    var minutes: UInt64
    var hours: UInt64
    var days: UInt64
    var months: UInt64
    var weekdays: UInt64
    var any_day: Bool
    """The day-of-month field starts with `*`."""
    var any_weekday: Bool
    """The day-of-week field starts with `*`."""

    def __init__(out self, text: String):
        self.text = text
        self.minutes = 0
        self.hours = 0
        self.days = 0
        self.months = 0
        self.weekdays = 0
        self.any_day = True
        self.any_weekday = True

    @staticmethod
    def parse(text: StringSpan) raises -> CronExpr:
        var s = String(text.strip())
        if s.startswith("@"):
            if s == "@yearly" or s == "@annually":
                s = "0 0 1 1 *"
            elif s == "@monthly":
                s = "0 0 1 * *"
            elif s == "@weekly":
                s = "0 0 * * 0"
            elif s == "@daily" or s == "@midnight":
                s = "0 0 * * *"
            elif s == "@hourly":
                s = "0 * * * *"
            else:
                raise Error("cron: unknown '", text, "'")
        var fields = List[String]()
        for f in s.split():
            fields.append(String(f))
        if len(fields) != 5:
            raise Error("cron: '", text, "' doesn't have five fields")
        var c = CronExpr(String(text.strip()))
        c.minutes = _field(fields[0], 0, 59)
        c.hours = _field(fields[1], 0, 23)
        c.days = _field(fields[2], 1, 31)
        c.months = _field(fields[3], 1, 12, _MONTHS)
        c.weekdays = _field(fields[4], 0, 7, _DAYS)
        if _has(c.weekdays, 7):
            c.weekdays = (c.weekdays | 1) & ~(UInt64(1) << 7)
        c.any_day = fields[2].startswith("*")
        c.any_weekday = fields[4].startswith("*")
        if not c._can_fire():
            raise Error("cron: '", text, "' never fires")
        return c^

    def _can_fire(self) -> Bool:
        """Whether some month has some day of the month allowed. With the day
        of week also restricted, any month has a matching weekday."""
        if self.any_day or not self.any_weekday:
            return True
        for m in range(1, 13):
            if not _has(self.months, m):
                continue
            # February 29 counts: a leap year comes.
            var longest = 29 if m == 2 else days_in(2001, m)
            for d in range(1, longest + 1):
                if _has(self.days, d):
                    return True
        return False

    def matches_day(self, c: Civil) -> Bool:
        if not _has(self.months, c.month):
            return False
        var dom = _has(self.days, c.day)
        var dow = _has(self.weekdays, c.weekday())
        if self.any_day and self.any_weekday:
            return True
        if self.any_day:
            return dow
        if self.any_weekday:
            return dom
        return dom or dow

    def next_fire(self, after: Int64, zone: Zone) raises -> Int64:
        """The first time after `after` (seconds since the epoch) that the
        expression fires on `zone`'s wall clock."""
        var local = (zone.to_local(after) // 60 + 1) * 60
        # Steps are a minute at most, a day at least once the day is wrong;
        # a matching day comes within eight years (February 29 skips 1900
        # and 2100), so this bound is never reached by an expression that
        # parsed.
        for _ in range(4000 * 24 * 60):
            var c = Civil.of(local)
            if not _has(self.months, c.month):
                var y = c.year + (1 if c.month == 12 else 0)
                var m = 1 if c.month == 12 else c.month + 1
                local = Civil(y, m, 1, 0, 0, 0).seconds()
                continue
            if not self.matches_day(c):
                local = Civil(c.year, c.month, c.day, 0, 0, 0).seconds() + 86400
                continue
            if not _has(self.hours, c.hour):
                local = (local // 3600 + 1) * 3600
                continue
            if not _has(self.minutes, c.minute):
                local += 60
                continue
            var t = _resolve(local, zone, after)
            if t:
                return t.value()
            local += 60
        raise Error("cron: '", self.text, "' found no fire")

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.text)


def _resolve(local: Int64, zone: Zone, after: Int64) -> Optional[Int64]:
    """The instant the wall clock reads `local`, if it's after `after`: its
    first occurrence when a fall-back repeats it, or the end of the gap when
    a spring-forward skips it."""
    # The instants within a day of `local` whose offset would put the wall
    # clock there. Offsets are under a day, so those are all of them.
    var offsets = List[Int]()
    for probe in [local - 86400, local, local + 86400]:
        var o = zone.offset_at(probe)
        if o not in offsets:
            offsets.append(o)
        var o2 = zone.offset_at(local - Int64(o))
        if o2 not in offsets:
            offsets.append(o2)
    var first = Optional[Int64](None)
    var latest = Int64.MIN
    for o in offsets:
        var t = local - Int64(o)
        if t > latest:
            latest = t
        if zone.offset_at(t) == o and (not first or t < first.value()):
            first = t
    if first:
        return first if first.value() > after else None
    # In a gap: the clock jumped past `local` at the transition before the
    # latest candidate.
    var t = zone.last_change(latest)
    return Optional[Int64](t) if t > after else None
