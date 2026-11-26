"""The control instance's own health: `/ops/control`, the gauges on `/metrics`,
and the warning on the home page.

The control instance (Postgres, the scheduler, the UI, Caddy, the apps) runs
a sampler of its own: a container the stack's user data starts beside the
scheduler, with the host's process and network namespaces and the host's
cgroup files and Docker's config files mounted read-only (`morca._internal.sample`
`--cgroup` and `--names`). It keeps its last hour of lines in the file
`MORCA_CONTROL_SAMPLES` names. Every `MORCA_FLEET_SECONDS` the scheduler reads
the file (`morca._internal.fleet.ingest`) and, here:

- rolls the lines it hasn't seen into one row a minute in
  `orca.system_minutes` (CPU, memory, the fullest disk, network: sums to
  average over, and peaks), and one row per container and minute in
  `orca.system_containers` (its peak memory), kept `KEEP_DAYS` (14) days.
  "Hasn't seen" is the newest sample already in a row (`last_t`), so a pass
  again adds nothing;
- appends those lines, as they are, to a file per UTC day,
  `<MORCA_LOGS>/control/<date>.jsonl`, so the history outlives the database
  and can be read back whole. In object storage a file is uploaded whole,
  every `MORCA_CONTROL_UPLOAD_SECONDS` (300) and once its day is over; the
  stack's bucket expires `logs/control/` after 14 days, and a local
  `MORCA_LOGS` has files older than that removed.

A page view reads only those two tables: no file, no bucket. The gauges on
`/metrics` are the newest minute's, left out once it is older than ten
minutes, since a gauge that stays at its last value is worse than none.
"""

from std.ffi import external_call
from std.os import getenv, listdir, makedirs, remove
from std.os.path import exists
from std.time import perf_counter_ns

from json import Value, loads
import morca._internal.db.system as system_db
from morca._internal.db.system import Container, Minute

from morca.civil import Civil
from morca._internal.fleet import Series, Summary, _chart, _fixed
from morca._internal.html import Html
from morca._internal.json import quote
from morca._internal.logs import (
    is_remote,
    location_exists,
    logs_dir,
    publish,
    read_location,
    stage_of,
)
from morca._internal.metrics import bytes_text
from morca._internal.sample import append_line
from morca._internal.state import State

comptime KEEP_DAYS = 14
"""How long the minutes, the containers' and the day files are kept."""
comptime DISK_WARN: Float64 = 85.0
"""The fullest disk's percent over which the home page warns."""
comptime MEMORY_WARN: Float64 = 90.0
"""Memory's percent over which the home page warns."""
comptime FRESH_SECONDS = 600
"""How old the newest sample may be and still be what's happening now."""
comptime _TAIL = 800
"""Lines read from the end of the control file: its `--keep 720`, and more."""


# ---------------------------------------------------------------------------
# Reading samples (pure)
# ---------------------------------------------------------------------------


@fieldwise_init
struct ControlSample(Copyable, Movable):
    var line: String
    var t: Float64
    var cpu: Float64
    """User and system, percent of all cores."""
    var mem_pct: Float64
    var mem_used: Int
    var mem_total: Int
    var disk_pct: Float64
    """Of the fullest disk."""
    var disk_used: Int
    var disk_total: Int
    var disk_path: String
    var net_in: Float64
    """Bytes per second."""
    var net_out: Float64
    var containers: List[Container]


def _num(v: Value, ptr: String) -> Float64:
    try:
        var got = v.try_at(ptr)
        return got.value().float_or(0) if got else Float64(0)
    except:
        return 0.0


def parse_control_sample(line: String) raises -> ControlSample:
    """A sampler's line; raises if it isn't one."""
    var v = loads(line)
    if Int(v.at("/v").int_or(0)) != 1:
        raise Error("not a version 1 sample")
    var pct = -1.0
    var used = 0
    var total = 0
    var path = String()
    var disks = v.try_at("/disk")
    if disks and disks.value().is_array():
        for d in disks.value().array_items():
            var size = _num(d, "/total")
            if size > 0 and 100.0 * _num(d, "/used") / size > pct:
                pct = 100.0 * _num(d, "/used") / size
                used = Int(_num(d, "/used"))
                total = Int(size)
                var p = d.try_at("/path")
                path = String(p.value().string_or("")) if p else String()
    var mem_total = Int(_num(v, "/mem/total"))
    var mem_used = Int(_num(v, "/mem/used"))
    var containers = List[Container]()
    var list = v.try_at("/containers")
    if list and list.value().is_array():
        for c in list.value().array_items():
            var n = c.try_at("/name")
            if n:
                containers.append(
                    Container(
                        String(n.value().string_or("")), Int(_num(c, "/mem"))
                    )
                )
    return ControlSample(
        line,
        v.at("/t").float_or(0),
        _num(v, "/cpu/user") + _num(v, "/cpu/system"),
        100.0 * Float64(mem_used) / Float64(mem_total) if mem_total
        > 0 else 0.0,
        mem_used,
        mem_total,
        max(pct, 0.0),
        used,
        total,
        path^,
        _num(v, "/net/in"),
        _num(v, "/net/out"),
        containers^,
    )


def samples_after(
    text: String, after: Float64, n: Int = _TAIL
) -> List[ControlSample]:
    """The samples among the last `n` lines of the control instance's file
    that are newer than `after` (Unix time), oldest first; lines that aren't
    samples are skipped."""
    var lines = List[String]()
    for line in text.splitlines():
        if line.strip():
            lines.append(String(line))
    var out = List[ControlSample]()
    for i in range(max(len(lines) - n, 0), len(lines)):
        try:
            var s = parse_control_sample(lines[i])
            # `after` came back from a timestamp, to the microsecond.
            if s.t > after + 0.001:
                out.append(s^)
        except:
            pass
    # A file is in time order; a clock that stepped back is not trusted.
    var sorted = List[ControlSample]()
    for s in out:
        if len(sorted) == 0 or s.t > sorted[len(sorted) - 1].t:
            sorted.append(s.copy())
    return sorted^


def roll(samples: List[ControlSample]) -> List[Minute]:
    """The samples, in time order, as one `Minute` each."""
    var out = List[Minute]()
    for s in samples:
        var at = Int(s.t // 60.0) * 60
        if len(out) == 0 or out[len(out) - 1].minute != at:
            out.append(
                Minute(
                    at,
                    0,
                    s.t,
                    0.0,
                    0.0,
                    0.0,
                    0.0,
                    0,
                    0,
                    0.0,
                    0,
                    0,
                    String(),
                    0.0,
                    0.0,
                    List[String](),
                    List[Int](),
                )
            )
        ref m = out[len(out) - 1]
        m.n += 1
        m.last_t = s.t
        m.cpu_sum += s.cpu
        m.cpu_max = max(m.cpu_max, s.cpu)
        m.mem_sum += s.mem_pct
        m.mem_max = max(m.mem_max, s.mem_pct)
        m.mem_used = max(m.mem_used, s.mem_used)
        m.mem_total = s.mem_total
        m.disk_max = max(m.disk_max, s.disk_pct)
        m.disk_used = s.disk_used
        m.disk_total = s.disk_total
        m.disk_path = s.disk_path
        m.net_in_sum += s.net_in
        m.net_out_sum += s.net_out
        for c in s.containers:
            var found = False
            for k in range(len(m.names)):
                if m.names[k] == c.name:
                    m.peaks[k] = max(m.peaks[k], c.mem)
                    found = True
            if not found:
                m.names.append(c.name)
                m.peaks.append(c.mem)
    return out^


# ---------------------------------------------------------------------------
# Keeping them (the scheduler)
# ---------------------------------------------------------------------------


struct Archive(Movable):
    """The day files, between passes: which ones have lines not yet uploaded,
    and when the last upload was."""

    var dirty: List[String]
    var next: Int
    """When the next upload may start, on the monotonic clock."""
    var seconds: Float64

    def __init__(out self):
        self.dirty = List[String]()
        self.next = 0
        try:
            self.seconds = Float64(
                getenv("MORCA_CONTROL_UPLOAD_SECONDS", "300")
            )
        except:
            self.seconds = 300.0


def _two(n: Int) -> String:
    return String("0", n) if n < 10 else String(n)


def day_of(t: Float64) -> String:
    """The UTC date of Unix time `t`, `YYYY-MM-DD`."""
    var c = Civil.of(Int64(t))
    return String(c.year, "-", _two(c.month), "-", _two(c.day))


def day_file(date: String) -> String:
    """Where the day's lines go, or "" without `MORCA_LOGS`."""
    var root = logs_dir()
    if not root:
        return ""
    return String(root.rstrip("/"), "/control/", date, ".jsonl")


def _archive(
    samples: List[ControlSample], mut archive: Archive, final: Bool = False
) raises:
    """Appends the samples' lines to their days' files and uploads the files
    that are due."""
    for s in samples:
        var loc = day_file(day_of(s.t))
        if not loc:
            return
        var path = stage_of(loc)
        if not exists(path):
            makedirs(path[byte = : path.rfind("/").or_else(-1)], exist_ok=True)
            # A new machine, or a cleaned stage: what is there is kept.
            if is_remote(loc) and location_exists(loc):
                var before = read_location(loc)
                with open(path, "w") as f:
                    f.write_bytes(Span(before))
        append_line(path, s.line)
        var date = day_of(s.t)
        var known = False
        for d in archive.dirty:
            if d == date:
                known = True
        if not known:
            archive.dirty.append(date)
    var t = Int(perf_counter_ns())
    # A day that has ended is uploaded whole at once; today's, now and then.
    var today = day_of(Float64(Int(external_time())))
    var due = t >= archive.next
    var keep = List[String]()
    for date in archive.dirty:
        if not due and date == today:
            keep.append(date)
            continue
        var loc = day_file(date)
        try:
            publish(loc)
        except e:
            print("morca: can't upload", loc, ":", e)
            keep.append(date)
    if due:
        archive.next = t + Int(archive.seconds * 1e9)
    archive.dirty = keep^


def external_time() -> Int:
    """Unix time now."""
    return Int(external_call["time", Int64](Int(0)))


def _expire_local() raises:
    """Removes the local day files older than `KEEP_DAYS`; the bucket's own
    lifecycle rule does it in object storage."""
    var root = logs_dir()
    if not root or is_remote(root):
        return
    var dir = String(root.rstrip("/"), "/control")
    if not exists(dir):
        return
    var oldest = day_of(Float64(external_time() - KEEP_DAYS * 86400))
    for name in listdir(dir):
        # `YYYY-MM-DD.jsonl` sorts by date.
        if name.endswith(".jsonl") and name.byte_length() == 16:
            if String(name[byte=:10]) < oldest:
                remove(String(dir, "/", name))


def keep(mut db: State, text: String, mut archive: Archive) raises -> Int:
    """Rolls the new samples in `text` (the control instance's file) into
    the database and the day files; returns how many were new."""
    var fresh = samples_after(text, system_db.last_kept(db.conn))
    for m in roll(fresh):
        system_db.keep_minute(db.conn, m)
    try:
        _archive(fresh, archive)
    except e:
        print("morca: can't keep the control instance's day files:", e)
    return len(fresh)


def trim(mut db: State) raises:
    """Drops what is older than `KEEP_DAYS`, in the database and in a local
    `MORCA_LOGS`."""
    system_db.trim(db.conn, KEEP_DAYS)
    try:
        _expire_local()
    except:
        pass


# ---------------------------------------------------------------------------
# What the page shows
# ---------------------------------------------------------------------------


@fieldwise_init
struct Now(Copyable, Movable):
    """The newest minute."""

    var age: Float64
    """Seconds since its last sample."""
    var cpu: Float64
    var cpu_peak: Float64
    var mem_pct: Float64
    var mem_used: Int
    var mem_total: Int
    var disk_pct: Float64
    var disk_used: Int
    var disk_total: Int
    var disk_path: String
    var net_in: Float64
    var net_out: Float64
    var containers: List[Container]

    def stale(self) -> Bool:
        return self.age > Float64(FRESH_SECONDS)


def system_now(mut db: State) raises -> Optional[Now]:
    """The newest minute the control instance sampled, or None if it never
    has. Check `stale()`: it may be long ago."""
    var got = system_db.newest_minute(db.conn)
    guard case .Some(r) = got else:
        return None
    return Now(
        r.age,
        r.cpu,
        r.cpu_max,
        r.mem,
        r.mem_used,
        r.mem_total,
        r.disk_max,
        r.disk_used,
        r.disk_total,
        r.disk_path,
        r.nin,
        r.nout,
        r.containers.copy(),
    )


def warnings(now: Optional[Now]) -> List[String]:
    """What is wrong with the control instance now, in words: a disk over
    `DISK_WARN` percent or memory over `MEMORY_WARN`, since a full disk
    stops every run. Nothing for samples that are old or missing."""
    var out = List[String]()
    if not now or now.value().stale():
        return out^
    ref n = now.value()
    if n.disk_pct > DISK_WARN:
        out.append(
            String(
                "The control instance's disk is ",
                _fixed(n.disk_pct, 0),
                "% full (",
                bytes_text(n.disk_used),
                " of ",
                bytes_text(n.disk_total),
                "): when it fills, Postgres and every run stop.",
            )
        )
    if n.mem_pct > MEMORY_WARN:
        out.append(
            String(
                "The control instance's memory is ",
                _fixed(n.mem_pct, 0),
                "% used (",
                bytes_text(n.mem_used),
                " of ",
                bytes_text(n.mem_total),
                "): the scheduler or Postgres may be killed.",
            )
        )
    return out^


def alert_html(mut h: Html, w: List[String]):
    """The warnings as a box linking to `/ops/control`, or nothing."""
    if len(w) == 0:
        return
    h.raw('<div class="alert" role="alert">')
    for text in w:
        h.raw("<div>")
        h.text(text)
        h.raw("</div>")
    h.raw('<div><a href="/ops/control">Control health</a></div></div>')


def warnings_json(w: List[String]) -> String:
    var out = String("[")
    for i in range(len(w)):
        out.write(", " if i else "", quote(w[i]))
    out.write("]")
    return out^


struct Charts(Copyable, Movable):
    var hours: Int
    var bucket: Int
    """Seconds in a point."""
    var labels: List[String]
    """`MM-DD HH:MM` (UTC) of each point."""
    var cpu: List[Series]
    var mem: List[Series]
    var disk: List[Series]
    var net: List[Series]
    var containers: List[Series]
    """Each container's highest memory in MB."""

    def __init__(
        out self,
        hours: Int,
        bucket: Int,
        var labels: List[String],
        var cpu: List[Series],
        var mem: List[Series],
        var disk: List[Series],
        var net: List[Series],
        var containers: List[Series],
    ):
        self.hours = hours
        self.bucket = bucket
        self.labels = labels^
        self.cpu = cpu^
        self.mem = mem^
        self.disk = disk^
        self.net = net^
        self.containers = containers^


def range_hours(range: String) -> Int:
    """The hours `?range=` asks for: 24, 168 (`7d`) or 336 (`14d`)."""
    if range == "14d":
        return 336
    if range == "7d":
        return 168
    return 24


def _label(t: Int) -> String:
    var c = Civil.of(Int64(t))
    return String(
        _two(c.month), "-", _two(c.day), " ", _two(c.hour), ":", _two(c.minute)
    )


def system_charts(mut db: State, hours: Int) raises -> Charts:
    """The minutes in the last `hours`, in at most 336 points: every 5
    minutes for a day, 30 for a week, an hour for two weeks. A point with no
    samples is 0."""
    var bucket = 300 if hours <= 24 else (1800 if hours <= 168 else 3600)
    var n = hours * 3600 // bucket
    var current = Int(system_db.now_epoch(db.conn)) // bucket
    var first = current - n + 1
    var labels = List[String]()
    for i in range(n):
        labels.append(_label((first + i) * bucket))
    var cpu = List[Float64](length=n, fill=0.0)
    var cpu_peak = List[Float64](length=n, fill=0.0)
    var mem = List[Float64](length=n, fill=0.0)
    var mem_peak = List[Float64](length=n, fill=0.0)
    var disk = List[Float64](length=n, fill=0.0)
    var net_in = List[Float64](length=n, fill=0.0)
    var net_out = List[Float64](length=n, fill=0.0)
    for r in system_db.points(db.conn, bucket, first):
        var i = r.i
        if i < 0 or i >= n:
            continue
        cpu[i] = r.cpu
        cpu_peak[i] = r.cpu_max
        mem[i] = r.mem
        mem_peak[i] = r.mem_max
        disk[i] = r.disk
        net_in[i] = r.nin / 1e6
        net_out[i] = r.nout / 1e6
    var names = List[String]()
    var series = List[List[Float64]]()
    for r in system_db.container_points(db.conn, bucket, first):
        var name = r[0]
        var at = -1
        for k in range(len(names)):
            if names[k] == name:
                at = k
        if at < 0:
            names.append(name)
            series.append(List[Float64](length=n, fill=0.0))
            at = len(names) - 1
        var i = r[1]
        if i >= 0 and i < n:
            series[at][i] = Float64(r[2]) / 1e6
    var by = List[Series]()
    var classes: List[String] = [
        "fl--0",
        "fl--1",
        "fl--2",
        "fl--live",
        "fl--bad",
        "fl--faint",
    ]
    for k in range(len(names)):
        by.append(Series(names[k], classes[k % len(classes)], series[k].copy()))
    return Charts(
        hours,
        bucket,
        labels^,
        [
            Series("average", "fl--0", cpu^, area=True),
            Series("peak", "fl--1", cpu_peak^),
        ],
        [
            Series("average", "fl--0", mem^, area=True),
            Series("peak", "fl--1", mem_peak^),
        ],
        [Series("fullest disk", "fl--0", disk^, area=True)],
        [
            Series("in (MB/s)", "fl--0", net_in^, area=True),
            Series("out (MB/s)", "fl--1", net_out^),
        ],
        by^,
    )


# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------


def _stat(
    mut h: Html, key: String, value: String, sub: String, bad: Bool = False
):
    h.raw('<div class="stat', " stat--errors" if bad else "", '">')
    h.raw('<span class="stat__k">', key, "</span>")
    h.raw('<span class="stat__v">', value, "</span>")
    h.raw('<span class="stat__s">')
    h.text(sub)
    h.raw("</span></div>")


def system_html(mut h: Html, now: Optional[Now], c: Charts, range: String):
    """The cards, the containers' table and the charts."""
    guard case .Some(n) = now else:
        h.raw(
            '<p class="empty">The control instance has not been sampled yet.',
            " Its sampler (<code>morca sample --cgroup ...</code>, started by",
            " the stack's user data) writes the file",
            " <code>MORCA_CONTROL_SAMPLES</code> names, which the scheduler",
            " reads.</p>",
        )
        return
    alert_html(h, warnings(now))
    if n.stale():
        h.raw('<p class="alert">The newest sample is ')
        h.text(Int(n.age // 60), " minutes old: the sampler or the scheduler")
        h.raw(" has stopped.</p>")
    h.raw('<div class="stats">')
    _stat(
        h,
        "CPU",
        String(_fixed(n.cpu, 0), "%"),
        String("peak ", _fixed(n.cpu_peak, 0), "% in the last minute"),
    )
    _stat(
        h,
        "Memory",
        String(_fixed(n.mem_pct, 0), "%"),
        String(bytes_text(n.mem_used), " of ", bytes_text(n.mem_total)),
        n.mem_pct > MEMORY_WARN,
    )
    _stat(
        h,
        "Disk",
        String(_fixed(n.disk_pct, 0), "%"),
        String(
            bytes_text(n.disk_used),
            " of ",
            bytes_text(n.disk_total),
            ", under ",
            n.disk_path,
        ),
        n.disk_pct > DISK_WARN,
    )
    _stat(
        h,
        "Network",
        String(_fixed(n.net_in / 1e6, 2), " MB/s"),
        String("in; out ", _fixed(n.net_out / 1e6, 2), " MB/s"),
    )
    h.raw("</div>")
    if len(n.containers) > 0:
        h.raw(
            '<section class="card" id="containers"><h2><a class="anchor"'
            ' href="#containers">Containers</a></h2>'
        )
        h.raw('<div class="scroll"><table><thead><tr><th>Container</th>')
        h.raw('<th class="num">Memory now</th>')
        h.raw('<th class="num">Peak in range</th></tr></thead><tbody>')
        for k in n.containers:
            var peak = 0.0
            for s in c.containers:
                if s.name == k.name:
                    for v in s.values:
                        peak = max(peak, v)
            h.raw("<tr><td>")
            h.text(k.name)
            h.raw('</td><td class="num">', bytes_text(k.mem))
            h.raw('</td><td class="num">', bytes_text(Int(peak * 1e6)))
            h.raw("</td></tr>")
        h.raw("</tbody></table></div></section>")
    h.raw('<p class="range">Range: ')
    for r in ["24h", "7d", "14d"]:
        if r == range:
            h.raw("<strong>", r, "</strong> ")
        else:
            h.raw('<a href="/ops/control?range=', r, '">', r, "</a> ")
    h.raw(
        "(UTC, every ",
        c.bucket // 60,
        " minutes; a point with no samples is 0)</p>",
    )
    h.raw(
        '<section class="card" id="cpu"><h2><a class="anchor"'
        ' href="#cpu">CPU</a></h2>'
    )
    h.raw(
        '<p class="muted">Percent of all cores, user and system.</p>',
        _chart("CPU", "%", c.labels, c.cpu, c.hours, fixed_top=100.0),
        "</section>",
    )
    h.raw(
        '<section class="card" id="memory"><h2><a class="anchor"'
        ' href="#memory">Memory</a></h2>'
    )
    h.raw(
        '<p class="muted">Percent of memory in use (not counting the page',
        " cache).</p>",
        _chart("Memory", "%", c.labels, c.mem, c.hours, fixed_top=100.0),
        "</section>",
    )
    h.raw(
        '<section class="card" id="disk"><h2><a class="anchor"'
        ' href="#disk">Disk</a></h2>'
    )
    h.raw(
        '<p class="muted">Percent used of the file system under ',
        "<code>/var/lib/orca</code>, which holds Postgres' data and the",
        " staged logs.</p>",
        _chart("Disk", "%", c.labels, c.disk, c.hours, fixed_top=100.0),
        "</section>",
    )
    h.raw(
        '<section class="card" id="network"><h2><a class="anchor"'
        ' href="#network">Network</a></h2>'
    )
    h.raw(
        '<p class="muted">Throughput over all interfaces but loopback.</p>',
        _chart("Network", "MB/s", c.labels, c.net, c.hours),
        "</section>",
    )
    if len(c.containers) > 0:
        h.raw(
            '<section class="card" id="container-memory"><h2><a class="anchor"'
            ' href="#container-memory">Container memory</a></h2>'
        )
        h.raw(
            '<p class="muted">Each container&rsquo;s highest memory in the',
            " point, as <code>docker stats</code> counts it.</p>",
            _chart("Container memory", "MB", c.labels, c.containers, c.hours),
            "</section>",
        )


# ---------------------------------------------------------------------------
# JSON and Prometheus
# ---------------------------------------------------------------------------


def _f(x: Float64, digits: Int = 2) -> String:
    return _fixed(x, digits)


def _list(values: List[Float64], digits: Int = 2) -> String:
    var out = String("[")
    for i in range(len(values)):
        out.write(", " if i else "", _f(values[i], digits))
    out.write("]")
    return out^


def _series_json(s: List[Series]) -> String:
    var out = String("{")
    for i in range(len(s)):
        out.write(", " if i else "", quote(s[i].name), ": ", _list(s[i].values))
    out.write("}")
    return out^


def now_json(now: Optional[Now]) -> String:
    guard case .Some(n) = now else:
        return String("null")
    var out = String(
        '{"age_seconds": ',
        _f(n.age, 0),
        ', "cpu_pct": ',
        _f(n.cpu, 1),
        ', "cpu_peak_pct": ',
        _f(n.cpu_peak, 1),
        ', "mem_pct": ',
        _f(n.mem_pct, 1),
        ', "mem_used_bytes": ',
        n.mem_used,
        ', "mem_total_bytes": ',
        n.mem_total,
        ', "disk_pct": ',
        _f(n.disk_pct, 1),
        ', "disk_used_bytes": ',
        n.disk_used,
        ', "disk_total_bytes": ',
        n.disk_total,
        ', "disk_path": ',
        quote(n.disk_path),
        ', "net_in_bytes_per_second": ',
        _f(n.net_in, 0),
        ', "net_out_bytes_per_second": ',
        _f(n.net_out, 0),
        ', "containers": {',
    )
    for i in range(len(n.containers)):
        out.write(
            ", " if i else "",
            quote(n.containers[i].name),
            ": ",
            n.containers[i].mem,
        )
    out.write("}}")
    return out^


def system_json(now: Optional[Now], c: Charts) -> String:
    return String(
        '{"now": ',
        now_json(now),
        ', "warnings": ',
        warnings_json(warnings(now)),
        ', "charts": {"hours": ',
        c.hours,
        ', "bucket_seconds": ',
        c.bucket,
        ', "labels_utc": [',
        _quoted(c.labels),
        '], "cpu_pct": ',
        _series_json(c.cpu),
        ', "mem_pct": ',
        _series_json(c.mem),
        ', "disk_pct": ',
        _series_json(c.disk),
        ', "network_mb_per_second": ',
        _series_json(c.net),
        ', "container_mem_mb": ',
        _series_json(c.containers),
        "}}",
    )


def _quoted(values: List[String]) -> String:
    var out = String()
    for i in range(len(values)):
        out.write(", " if i else "", quote(values[i]))
    return out^


def _gauge(
    mut out: String,
    name: String,
    help: String,
    value: String,
    labels: String = "",
):
    out.write("# HELP ", name, " ", help, "\n# TYPE ", name, " gauge\n")
    out.write(name, labels, " ", value, "\n")


def _label_value(s: String) -> String:
    """`s` as a Prometheus label value's contents."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def prometheus(now: Optional[Now], f: Summary) -> String:
    """The gauges, in Prometheus' text format: the fleet's (`f`, from
    `morca._internal.fleet`) and the control instance's, which are left out while its
    samples are stale or missing."""
    var out = String()
    if now and not now.value().stale():
        ref n = now.value()
        _gauge(
            out,
            "morca_control_cpu_percent",
            "Control instance CPU, percent of all cores, minute average.",
            _f(n.cpu, 2),
        )
        _gauge(
            out,
            "morca_control_memory_used_bytes",
            "Control instance memory in use.",
            String(n.mem_used),
        )
        _gauge(
            out,
            "morca_control_memory_total_bytes",
            "Control instance memory.",
            String(n.mem_total),
        )
        _gauge(
            out,
            "morca_control_memory_percent",
            "Control instance memory in use, percent.",
            _f(n.mem_pct, 2),
        )
        _gauge(
            out,
            "morca_control_disk_used_bytes",
            "Used space on the control instance's fullest disk.",
            String(n.disk_used),
        )
        _gauge(
            out,
            "morca_control_disk_total_bytes",
            "Size of the control instance's fullest disk.",
            String(n.disk_total),
        )
        _gauge(
            out,
            "morca_control_disk_percent",
            "Control instance's fullest disk, percent used.",
            _f(n.disk_pct, 2),
        )
        _gauge(
            out,
            "morca_control_network_in_bytes_per_second",
            "Control instance network in, bytes a second.",
            _f(n.net_in, 0),
        )
        _gauge(
            out,
            "morca_control_network_out_bytes_per_second",
            "Control instance network out, bytes a second.",
            _f(n.net_out, 0),
        )
        _gauge(
            out,
            "morca_control_sample_age_seconds",
            "Seconds since the control instance's newest sample.",
            _f(n.age, 0),
        )
        out.write(
            "# HELP morca_control_container_memory_bytes A container's memory,",
            " as docker stats counts it.\n",
            "# TYPE morca_control_container_memory_bytes gauge\n",
        )
        for c in n.containers:
            out.write(
                'morca_control_container_memory_bytes{container="',
                _label_value(c.name),
                '"} ',
                c.mem,
                "\n",
            )
    _gauge(
        out,
        "morca_runs",
        "Runs by status, now.",
        String(f.running),
        '{status="running"}',
    )
    out.write('morca_runs{status="queued"} ', f.queued, "\n")
    _gauge(
        out,
        "morca_fleet_hosts",
        "Hosts running, by role.",
        String(f.heads),
        '{role="head"}',
    )
    out.write('morca_fleet_hosts{role="worker"} ', f.workers, "\n")
    out.write('morca_fleet_hosts{role="control"} ', 1 if f.control else 0, "\n")
    _gauge(
        out,
        "morca_runs_started_last_hour",
        "Runs started in the last 60 minutes.",
        String(f.runs_hour),
    )
    _gauge(
        out,
        "morca_errors_last_hour",
        (
            "Failures in the last 60 minutes: step attempts (including ones a"
            " retry fixed) and runs."
        ),
        String(f.failed_attempts_hour),
        '{kind="step_attempts"}',
    )
    out.write('morca_errors_last_hour{kind="runs"} ', f.failed_runs_hour, "\n")
    return out^
