"""What a run's processes use: each attempt's peak memory and CPU.

Whoever starts a run's process measures it: the scheduler for a local or
control-placed run (`morca._internal.scheduler`), `morca worker` for a remote worker's
(`morca._internal.worker`). Each tick, at most every quarter of a second, it reads
the process's tree in /proc (`morca._internal.sample.tree_usage`: the driver and what
it started, dista's local workers among them) and keeps a `Meter` of it:
the resident bytes, the CPU seconds so far (utime + stime, with what the
tree's processes waited for), and the cores that kept busy since the
sample before. When the process is reaped, `wait4` adds its own word:
`ru_maxrss`, the largest single process (a lower bound on the tree's), and
its CPU seconds, which count descendants that ended after the last sample.

A process runs every attempt of a run's start, so its samples are shared
out among those attempts by time (`attribute`): an attempt's peak is the
largest sample taken while it ran (or, for one shorter than a tick, the
sample just after it), its CPU the meter's CPU at its end less at its
start, its peak cores the busiest interval it overlapped. `ru_maxrss`
raises the peak of a process's only attempt. A meter keeps at most
`MAX_MARKS` samples, merging neighbours as it fills (keeping their maximum
and the later total), so a long run's samples are coarser, not dropped.

On macOS, which has no /proc, there are no samples: a process's only
attempt gets `wait4`'s numbers, and none gets its peak cores; a process
of several attempts records none. Runs on EC2 or Kubernetes, and runs no
scheduler or worker started (`<binary> run` by hand), record nothing:
their columns stay NULL.

The numbers are `orca.attempts`' `peak_rss_bytes`, `cpu_seconds` and
`peak_cpus` (migration 35), written once, when the process ends: by the
scheduler over Postgres, and for a worker's run by `morca ui`, which the
worker sends its meter with `/api/worker/exited` (`marks_json`, ages in
seconds before the request, so neither clock needs to agree with the
database's).
"""

from std.ffi import c_int, external_call
from std.time import perf_counter_ns

from json import Value
import morca._internal.db.usage as usage_db
from morca._internal.db.usage import AttemptSpan

from morca._internal.sample import fixed1
from morca._internal.state import State
from morca._internal.db.run_rows import Usage

comptime MAX_MARKS = 1024
"""The most samples a meter keeps; past it, neighbours are merged."""

comptime MIN_SAMPLE_SECONDS = 0.25
"""The least time between two samples of one process."""


@fieldwise_init
struct Mark(ImplicitlyCopyable, Movable):
    """A sample of a process tree. `at` is seconds on the monotonic clock in
    a `Meter`, and seconds before now once `aged`."""

    var at: Float64
    var rss: Int
    """The most resident bytes sampled up to here since the mark before;
    -1 for none (the start, and the end)."""
    var cpu: Float64
    """The CPU seconds so far."""
    var cpus: Float64
    """The most cores busy over a sample's interval since the mark before;
    -1 for none."""


def _mono(now: Float64 = -1) -> Float64:
    """`now`, or if it's -1 the monotonic clock in seconds."""
    return now if now >= 0 else Float64(Int(perf_counter_ns())) / 1e9


struct Meter(Copyable, Movable):
    """One run process's samples, from its start to its end."""

    var marks: List[Mark]
    var max_rss: Int
    """`wait4`'s `ru_maxrss` in bytes once it has ended, else -1."""

    def __init__(out self, now: Float64 = -1):
        self.marks = [Mark(_mono(now), -1, 0.0, -1.0)]
        self.max_rss = -1

    def sample(mut self, rss: Int, cpu: Float64, now_in: Float64 = -1):
        """Adds a reading of the tree: its resident bytes and CPU seconds."""
        var now = _mono(now_in)
        ref last = self.marks[len(self.marks) - 1]
        var dt = now - last.at
        if dt < MIN_SAMPLE_SECONDS:
            return
        # A tree's CPU only grows; a child that ended unwaited takes its
        # time with it, which the next readings make up.
        var c = max(cpu, last.cpu)
        self.marks.append(Mark(now, rss, c, (c - last.cpu) / dt))
        if len(self.marks) > MAX_MARKS:
            self._squeeze()

    def end(mut self, max_rss: Int, cpu: Float64, now_in: Float64 = -1):
        """The process ended, `wait4` says having used `cpu` seconds with
        `max_rss` bytes its largest process."""
        var now = _mono(now_in)
        ref last = self.marks[len(self.marks) - 1]
        var dt = now - last.at
        var c = max(cpu, last.cpu)
        # Cores over the last stretch, if samples were taken: the start to
        # the end alone is an average, not a peak.
        var cpus = (c - last.cpu) / dt if (
            len(self.marks) > 1 and dt >= MIN_SAMPLE_SECONDS
        ) else -1.0
        self.marks.append(Mark(now, -1, c, cpus))
        self.max_rss = max_rss

    def _squeeze(mut self):
        """Merges each pair of marks after the start into one."""
        var kept: List[Mark] = [self.marks[0]]
        var i = 1
        while i < len(self.marks):
            var a = self.marks[i]
            if i + 1 < len(self.marks):
                ref b = self.marks[i + 1]
                kept.append(
                    Mark(b.at, max(a.rss, b.rss), b.cpu, max(a.cpus, b.cpus))
                )
            else:
                kept.append(a)
            i += 2
        self.marks = kept^

    def aged(self, now_in: Float64 = -1) -> List[Mark]:
        """The marks with `at` seconds before now, oldest first."""
        var now = _mono(now_in)
        var out = List[Mark](capacity=len(self.marks))
        for m in self.marks:
            out.append(Mark(now - m.at, m.rss, m.cpu, m.cpus))
        return out^


def _cpu_at(marks: List[Mark], age: Float64) -> Float64:
    """The CPU seconds so far at `age`, between the marks around it."""
    if age >= marks[0].at:
        return marks[0].cpu
    for i in range(1, len(marks)):
        ref b = marks[i]
        if b.at <= age:
            ref a = marks[i - 1]
            var span = a.at - b.at
            if span <= 0:
                return b.cpu
            return a.cpu + (b.cpu - a.cpu) * (a.at - age) / span
    return marks[len(marks) - 1].cpu


def attribute(
    marks: List[Mark], max_rss: Int, attempts: List[AttemptSpan]
) -> List[Usage]:
    """Each attempt's share of a process's `marks` (aged, oldest first, the
    start first and the end last), as described above."""
    var out = List[Usage]()
    if len(marks) < 2:
        for _ in attempts:
            out.append(Usage.unknown())
        return out^
    var sampled = False
    for m in marks:
        if m.rss >= 0:
            sampled = True
    var first = marks[0].at
    var last = marks[len(marks) - 1].at
    var alone = len(attempts) == 1
    for a in attempts:
        if not sampled:
            # Only wait4's numbers, which are the whole process's.
            if alone:
                out.append(
                    Usage(
                        max_rss if max_rss > 0 else -1,
                        marks[len(marks) - 1].cpu,
                        -1.0,
                    )
                )
            else:
                out.append(Usage.unknown())
            continue
        var s = min(a.started, first)
        var e = max(a.ended if a.ended >= 0 else last, last)
        if e > s:
            e = s
        var peak = -1
        var cpus = -1.0
        for i in range(1, len(marks)):
            ref m = marks[i]
            if m.rss >= 0 and m.at <= s and m.at >= e:
                peak = max(peak, m.rss)
            # The interval from the mark before to this one overlaps it.
            if m.cpus >= 0 and m.at < s and marks[i - 1].at > e:
                cpus = max(cpus, m.cpus)
        if peak < 0:
            # Shorter than a tick: the sample just after it, else the one
            # just before.
            for i in range(1, len(marks)):
                if marks[i].rss >= 0 and marks[i].at < e:
                    peak = marks[i].rss
                    break
            if peak < 0:
                var i = len(marks) - 1
                while i > 0:
                    if marks[i].rss >= 0 and marks[i].at > s:
                        peak = marks[i].rss
                        break
                    i -= 1
        if alone and max_rss > peak:
            peak = max_rss
        var cpu = max(_cpu_at(marks, e) - _cpu_at(marks, s), 0.0)
        out.append(Usage(peak, cpu, cpus))
    return out^


def record(
    mut db: State,
    run: Int,
    pid: Int,
    marks: List[Mark],
    max_rss: Int,
    worker: Int = 0,
    start: Int = 0,
) raises -> Int:
    """Writes each attempt's share of the process `pid`'s `marks` (aged at
    about the database's now) to the attempts of `run` that it made, and
    returns how many. With `worker`, only while the run's start `start` is
    that worker's."""
    if len(marks) < 2:
        return 0
    var spans = usage_db.unmeasured(
        db.conn, run, pid, marks[0].at + 60.0, worker, start
    )
    var got = attribute(marks, max_rss, spans)
    var n = 0
    for i in range(len(spans)):
        ref u = got[i]
        if not u.known():
            continue
        n += usage_db.set_usage(
            db.conn, spans[i].id, u.peak_rss_bytes, u.cpu_seconds, u.peak_cpus
        )
    return n


# ── the worker's meter over the API ─────────────────────────────────────────


def marks_json(marks: List[Mark]) -> String:
    """Aged marks as `[[age, rss, cpu, cpus], ...]`."""
    var out = String("[")
    for i in range(len(marks)):
        ref m = marks[i]
        out.write(
            ", " if i else "",
            "[",
            _num(m.at),
            ", ",
            m.rss,
            ", ",
            _num(m.cpu),
            ", ",
            _num(m.cpus),
            "]",
        )
    out.write("]")
    return out^


def _num(x: Float64) -> String:
    """`x` as a JSON number, to the millisecond."""
    var n = Int(x * 1000.0 + (0.5 if x >= 0 else -0.5))
    var sign = String("-") if n < 0 else String()
    n = abs(n)
    var frac = String(n % 1000)
    while frac.byte_length() < 3:
        frac = String("0", frac)
    return String(sign, n // 1000, ".", frac)


def _float(v: Value) -> Float64:
    return Float64(v.int_value()) if v.is_int() else v.float_value()


def marks_of(v: Value) raises -> List[Mark]:
    """`marks_json`'s marks back."""
    var out = List[Mark]()
    if not v.is_array():
        return out^
    for m in v.array_items():
        var f = m.array_items()
        if len(f) != 4:
            raise Error("morca: a mark is [age, rss, cpu, cpus]")
        out.append(
            Mark(_float(f[0]), Int(_float(f[1])), _float(f[2]), _float(f[3]))
        )
    return out^


# ── how it's shown ──────────────────────────────────────────────────────────


def bytes_text(n: Int) -> String:
    """Resident bytes as MB (MiB, as `MORCA_CONTROL_MEMORY_MB` counts them),
    or GB from 10 GB."""
    var mb = Float64(n) / (1024.0 * 1024.0)
    if mb >= 10240.0:
        return String(fixed1(mb / 1024.0), " GB")
    return String(Int(mb + 0.5), " MB")


def cpu_text(s: Float64) -> String:
    """CPU seconds, as seconds, minutes or hours."""
    if s < 600:
        return String(fixed1(s), " s")
    if s < 7200:
        return String(fixed1(s / 60.0), " min")
    return String(fixed1(s / 3600.0), " h")


def usage_text(u: Usage) -> String:
    """`peak 812 MB, CPU 41.2 s on up to 3.9 cores`, as much as is known;
    empty for nothing."""
    var text = String()
    if u.peak_rss_bytes >= 0:
        text.write("peak ", bytes_text(u.peak_rss_bytes))
    if u.cpu_seconds >= 0:
        text.write(", " if text else "", "CPU ", cpu_text(u.cpu_seconds))
        if u.peak_cpus >= 0:
            text.write(" on up to ", fixed1(u.peak_cpus), " cores")
    return text^


def usage_of(v: Value) raises -> Usage:
    """`usage_json`'s usage back; -1 for what's null or missing."""
    var u = Usage.unknown()
    if not v.is_object():
        return u
    if String("peak_rss_bytes") in v and not v["peak_rss_bytes"].is_null():
        u.peak_rss_bytes = Int(_float(v["peak_rss_bytes"]))
    if String("cpu_seconds") in v and not v["cpu_seconds"].is_null():
        u.cpu_seconds = _float(v["cpu_seconds"])
    if String("peak_cpus") in v and not v["peak_cpus"].is_null():
        u.peak_cpus = _float(v["peak_cpus"])
    return u


def usage_json(u: Usage) -> String:
    """`{"peak_rss_bytes": ..., "cpu_seconds": ..., "peak_cpus": ...}`, null
    for what isn't known."""
    return String(
        '{"peak_rss_bytes": ',
        String(u.peak_rss_bytes) if u.peak_rss_bytes >= 0 else String("null"),
        ', "cpu_seconds": ',
        _num(u.cpu_seconds) if u.cpu_seconds >= 0 else String("null"),
        ', "peak_cpus": ',
        _num(u.peak_cpus) if u.peak_cpus >= 0 else String("null"),
        "}",
    )
