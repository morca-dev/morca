"""Time zones, from the system's TZif files (RFC 8536).

```mojo
var ny = Zone.load("America/New_York")
var offset = ny.offset_at(utc(2024, 7, 1))   # -14400, EDT
```

A TZif file of version 2 or later lists the zone's transitions as 64-bit
times, each with the UTC offset in force from then on, and ends with a POSIX
`TZ` string (`EST5EDT,M3.2.0,M11.1.0`) that gives the rule after the last
transition. "Slim" files, which some systems install, list transitions only
up to when the current rule began and rely on that string for every year
since; "fat" ones list them to 2037. `Zone` reads both, and a version 1 file,
which has only 32-bit times and no rule. Leap-second records are skipped:
morca's times are POSIX times, as the `right/` zones' aren't.

Files are read from `MORCA_ZONEINFO`, default `/usr/share/zoneinfo`. `UTC`
needs no file.
"""

from std.os import getenv

from morca.civil import Civil, days_from_civil
from morca.month import days_in


def _digits(s: String, mut i: Int, max: Int) -> Int:
    """Reads up to `max` decimal digits at `i`; -1 if there are none."""
    var n = 0
    var got = 0
    while i < s.byte_length() and got < max:
        var c = Int(s.as_bytes()[i])
        if c < 48 or c > 57:
            break
        n = n * 10 + c - 48
        i += 1
        got += 1
    return n if got > 0 else -1


def _hms(s: String, mut i: Int, max_hours: Int) raises -> Int:
    """`[+-]hh[:mm[:ss]]` at `i`, in seconds."""
    var sign = 1
    if i < s.byte_length() and (s.as_bytes()[i] == 43 or s.as_bytes()[i] == 45):
        sign = -1 if s.as_bytes()[i] == 45 else 1
        i += 1
    var h = _digits(s, i, 3)
    if h < 0 or h > max_hours:
        raise Error("tz: bad hours in '", s, "'")
    var t = h * 3600
    for unit in [60, 1]:
        if i < s.byte_length() and s.as_bytes()[i] == 58:
            i += 1
            var n = _digits(s, i, 2)
            if n < 0 or n > 59:
                raise Error("tz: bad minutes or seconds in '", s, "'")
            t += n * unit
        else:
            break
    return sign * t


def _name(s: String, mut i: Int) raises:
    """Skips a zone abbreviation: three or more letters, or `<...>`."""
    var b = s.as_bytes()
    if i < s.byte_length() and b[i] == 60:
        var j = i + 1
        while j < s.byte_length() and b[j] != 62:
            j += 1
        if j >= s.byte_length() or j - i - 1 < 3:
            raise Error("tz: bad quoted name in '", s, "'")
        i = j + 1
        return
    var j = i
    while j < s.byte_length():
        var c = Int(b[j])
        if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122)):
            break
        j += 1
    if j - i < 3:
        raise Error("tz: bad name in '", s, "'")
    i = j


@fieldwise_init
struct _Rule(Copyable, Movable):
    """When daylight time starts or ends: `Mm.w.d`, `Jn` or `n`, and the
    local time of day of the change."""

    var kind: Int
    """0 for `Mm.w.d`, 1 for `Jn`, 2 for `n`."""
    var month: Int
    var week: Int
    var weekday: Int
    var day: Int
    var time: Int
    """Seconds after local midnight, possibly negative or past a day."""

    @staticmethod
    def parse(s: String, mut i: Int) raises -> _Rule:
        var b = s.as_bytes()
        var r = _Rule(0, 0, 0, 0, 0, 7200)
        if i < s.byte_length() and b[i] == 77:
            i += 1
            r.month = _digits(s, i, 2)
            if (
                r.month < 1
                or r.month > 12
                or i >= s.byte_length()
                or b[i] != 46
            ):
                raise Error("tz: bad M rule in '", s, "'")
            i += 1
            r.week = _digits(s, i, 1)
            if r.week < 1 or r.week > 5 or i >= s.byte_length() or b[i] != 46:
                raise Error("tz: bad M rule in '", s, "'")
            i += 1
            r.weekday = _digits(s, i, 1)
            if r.weekday < 0 or r.weekday > 6:
                raise Error("tz: bad M rule in '", s, "'")
        elif i < s.byte_length() and b[i] == 74:
            i += 1
            r.kind = 1
            r.day = _digits(s, i, 3)
            if r.day < 1 or r.day > 365:
                raise Error("tz: bad J rule in '", s, "'")
        else:
            r.kind = 2
            r.day = _digits(s, i, 3)
            if r.day < 0 or r.day > 365:
                raise Error("tz: bad rule in '", s, "'")
        if i < s.byte_length() and b[i] == 47:
            i += 1
            r.time = _hms(s, i, 167)
        return r^

    def local(self, year: Int) -> Int64:
        """The change's local time in `year`, in seconds since the epoch
        read on the wall clock."""
        var days: Int64
        if self.kind == 0:
            var first = days_from_civil(year, self.month, 1)
            var wd = Int((first + 4) % 7)
            var d = (self.weekday - wd + 7) % 7 + 1 + (self.week - 1) * 7
            var last = days_in(year, self.month)
            while d > last:
                d -= 7
            days = days_from_civil(year, self.month, d)
        elif self.kind == 1:
            # Day 1 to 365, never counting February 29.
            days = days_from_civil(year, 1, 1) + Int64(self.day - 1)
            if self.day >= 60 and days_in(year, 2) == 29:
                days += 1
        else:
            days = days_from_civil(year, 1, 1) + Int64(self.day)
        return days * 86400 + Int64(self.time)


struct PosixTZ(Copyable, Movable):
    """A POSIX `TZ` rule: a standard offset, and maybe a daylight one with
    the rules for when it starts and ends."""

    var std: Int
    """Seconds east of UTC."""
    var dst: Int
    var has_dst: Bool
    var start: _Rule
    var end: _Rule

    def __init__(out self, std: Int):
        self.std = std
        self.dst = std
        self.has_dst = False
        self.start = _Rule(0, 3, 2, 0, 0, 7200)
        self.end = _Rule(0, 11, 1, 0, 0, 7200)

    @staticmethod
    def parse(s: String) raises -> PosixTZ:
        """Reads `std offset [dst [offset] [,start[/time],end[/time]]]`.
        A daylight zone without rules gets the US ones, as glibc does."""
        var i = 0
        _name(s, i)
        # POSIX offsets count west of UTC.
        var tz = PosixTZ(-_hms(s, i, 24))
        if i == s.byte_length():
            return tz^
        _name(s, i)
        tz.has_dst = True
        tz.dst = tz.std + 3600
        var b = s.as_bytes()
        if i < s.byte_length() and b[i] != 44:
            tz.dst = -_hms(s, i, 24)
        if i < s.byte_length():
            if b[i] != 44:
                raise Error("tz: expected ',' in '", s, "'")
            i += 1
            tz.start = _Rule.parse(s, i)
            if i >= s.byte_length() or b[i] != 44:
                raise Error("tz: expected ',' in '", s, "'")
            i += 1
            tz.end = _Rule.parse(s, i)
        if i != s.byte_length():
            raise Error("tz: trailing text in '", s, "'")
        return tz^

    def _changes(self, year: Int) -> Tuple[Int64, Int64]:
        """When daylight time starts and ends in `year`, in UTC."""
        return (
            self.start.local(year) - Int64(self.std),
            self.end.local(year) - Int64(self.dst),
        )

    def offset_at(self, t: Int64) -> Int:
        if not self.has_dst:
            return self.std
        var year = Civil.of(t + Int64(self.std)).year
        var s, e = self._changes(year)
        if s < e:
            return self.dst if s <= t and t < e else self.std
        # Southern hemisphere: daylight time spans the new year.
        return self.std if e <= t and t < s else self.dst

    def last_change(self, t: Int64) -> Int64:
        """The latest change at or before `t`; `Int64.MIN` if none."""
        var best = Int64.MIN
        if not self.has_dst:
            return best
        var year = Civil.of(t + Int64(self.std)).year
        for y in range(year - 1, year + 2):
            var s, e = self._changes(y)
            if s <= t and s > best:
                best = s
            if e <= t and e > best:
                best = e
        return best


struct Zone(Copyable, Movable):
    """A time zone: its transitions, and the rule after the last one."""

    var name: String
    var times: List[Int64]
    """Transition times, ascending."""
    var offsets: List[Int]
    """The offset (seconds east of UTC) from each transition on."""
    var first: Int
    """The offset before the first transition."""
    var footer: Optional[PosixTZ]

    def __init__(out self, name: String, offset: Int = 0):
        """A fixed offset, such as UTC."""
        self.name = name
        self.times = List[Int64]()
        self.offsets = List[Int]()
        self.first = offset
        self.footer = None

    @staticmethod
    def load(name: String) raises -> Zone:
        """The zone `name`, such as `America/New_York`, from the TZif file
        under `MORCA_ZONEINFO` (default `/usr/share/zoneinfo`)."""
        if name == "UTC" or name == "Etc/UTC":
            return Zone(name)
        if not name or name.startswith("/") or ".." in name or "\\" in name:
            raise Error("tz: not a zone name: '", name, "'")
        var dir = getenv("MORCA_ZONEINFO", "/usr/share/zoneinfo")
        var data: List[UInt8]
        try:
            with open(String(dir, "/", name), "r") as f:
                data = f.read_bytes()
        except e:
            raise Error("tz: can't read zone ", name, " from ", dir, ": ", e)
        return Zone.parse(name, data)

    @staticmethod
    def parse(name: String, data: List[UInt8]) raises -> Zone:
        """Reads a TZif file."""
        var z = Zone(name)
        var r = _Reader(data.copy())
        var version = r.header()
        var counts = r.counts()
        var width = 4
        if version >= 2:
            # Skip the 32-bit block; the 64-bit one follows.
            r.skip(counts.v1_size())
            _ = r.header()
            counts = r.counts()
            width = 8
        var times = List[Int64]()
        for _ in range(counts.time):
            times.append(r.i64() if width == 8 else Int64(r.i32()))
        var idx = List[Int]()
        for _ in range(counts.time):
            var k = Int(r.u8())
            if k >= counts.type:
                raise Error(
                    "tz: ", name, ": a transition's type is out of range"
                )
            idx.append(k)
        var offs = List[Int]()
        for _ in range(counts.type):
            var o = Int(r.i32())
            if o <= -86400 or o >= 86400:
                raise Error("tz: ", name, ": an offset is out of range")
            offs.append(o)
            _ = r.u8()  # is DST
            _ = r.u8()  # abbreviation index
        r.skip(counts.char + counts.leap * (width + 4) + counts.std + counts.ut)
        for k in range(len(times)):
            if k > 0 and times[k] <= times[k - 1]:
                raise Error("tz: ", name, ": transitions aren't ascending")
            z.times.append(times[k])
            z.offsets.append(offs[idx[k]])
        z.first = offs[0]
        if version >= 2:
            var footer = r.footer()
            if footer:
                z.footer = PosixTZ.parse(footer)
        return z^

    def offset_at(self, t: Int64) -> Int:
        """The offset in seconds east of UTC at `t`."""
        var n = len(self.times)
        if n == 0 or t >= self.times[n - 1]:
            if self.footer:
                return self.footer.value().offset_at(t)
            return self.offsets[n - 1] if n > 0 else self.first
        if t < self.times[0]:
            return self.first
        # The last transition at or before t.
        var lo = 0
        var hi = n - 1
        while lo < hi:
            var mid = (lo + hi + 1) // 2
            if self.times[mid] <= t:
                lo = mid
            else:
                hi = mid - 1
        return self.offsets[lo]

    def last_change(self, t: Int64) -> Int64:
        """The latest transition at or before `t`; `Int64.MIN` if none."""
        var best = Int64.MIN
        var n = len(self.times)
        if self.footer and (n == 0 or t >= self.times[n - 1]):
            best = self.footer.value().last_change(t)
        for k in range(n - 1, -1, -1):
            if self.times[k] <= t:
                if self.times[k] > best:
                    best = self.times[k]
                break
        return best

    def to_local(self, t: Int64) -> Int64:
        """`t` read on this zone's wall clock."""
        return t + Int64(self.offset_at(t))


@fieldwise_init
struct _Counts(Copyable, Movable):
    var ut: Int
    var std: Int
    var leap: Int
    var time: Int
    var type: Int
    var char: Int

    def v1_size(self) -> Int:
        return (
            self.time * 5
            + self.type * 6
            + self.char
            + self.leap * 8
            + self.std
            + self.ut
        )


struct _Reader(Movable):
    var data: List[UInt8]
    var pos: Int

    def __init__(out self, var data: List[UInt8]):
        self.data = data^
        self.pos = 0

    def _need(self, n: Int) raises:
        if n < 0 or self.pos + n > len(self.data):
            raise Error("tz: TZif file is truncated")

    def skip(mut self, n: Int) raises:
        self._need(n)
        self.pos += n

    def u8(mut self) raises -> UInt8:
        self._need(1)
        self.pos += 1
        return self.data[self.pos - 1]

    def i32(mut self) raises -> Int32:
        self._need(4)
        var v = UInt32(0)
        for k in range(4):
            v = (v << 8) | UInt32(self.data[self.pos + k])
        self.pos += 4
        return Int32(v)

    def i64(mut self) raises -> Int64:
        self._need(8)
        var v = UInt64(0)
        for k in range(8):
            v = (v << 8) | UInt64(self.data[self.pos + k])
        self.pos += 8
        return Int64(v)

    def header(mut self) raises -> Int:
        """Reads the magic and version: 1, 2, 3 or 4."""
        self._need(20)
        ref d = self.data
        var p = self.pos
        if d[p] != 84 or d[p + 1] != 90 or d[p + 2] != 105 or d[p + 3] != 102:
            raise Error("tz: not a TZif file")
        var v = d[p + 4]
        self.pos += 20
        if v == 0:
            return 1
        if v < 50 or v > 57:
            raise Error("tz: unknown TZif version")
        return Int(v) - 48

    def counts(mut self) raises -> _Counts:
        var c = List[Int]()
        for _ in range(6):
            var n = Int(self.i32())
            if n < 0 or n > 1 << 20:
                raise Error("tz: a TZif count is out of range")
            c.append(n)
        if c[4] == 0:
            raise Error("tz: a TZif file needs a local time type")
        return _Counts(c[0], c[1], c[2], c[3], c[4], c[5])

    def footer(mut self) raises -> String:
        """The POSIX TZ string between two newlines; empty if absent."""
        if self.pos >= len(self.data) or self.data[self.pos] != 10:
            return String()
        var start = self.pos + 1
        var end = start
        while end < len(self.data) and self.data[end] != 10:
            end += 1
        if end >= len(self.data):
            raise Error("tz: the TZif footer has no closing newline")
        var out = String(
            StringSpan(unsafe_from_utf8=Span(self.data)[start:end])
        )
        self.pos = end + 1
        for b in out.as_bytes():
            if b < 32 or b > 126:
                raise Error("tz: the TZif footer isn't ASCII")
        return out^
