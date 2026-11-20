"""A run's machine metrics on its page: the samplers' files (`morca._internal.sample`)
read back, their peaks and warnings, and the charts, drawn as SVG on the
server like the DAG.

`read_metrics` reads every `<MORCA_LOGS>/<pipeline>/<run>/metrics/*.jsonl`,
local or in object storage, into one `InstanceMetrics` per file; a line it
can't read is skipped. `metrics_svg` draws them under a lane of the run's
steps, every row on the same time axis (wall-clock time, from the first
attempt or sample to the last), so a step that pegged a CPU or filled a disk
lines up with its bar:

- **cpu**: user and system time as an area, iowait above it, and steal as a
  line, in percent of all cores;
- **mem · disk**: memory used and the fullest disk's used space, in percent
  of the instance's;
- **io · net**: disk reads and writes and network traffic, in bytes per
  second, each scaled to the instance's highest rate, which the label says.

A **warning** is a stretch of samples where memory was over 90% of the
instance's, a disk was over 90% full or CPU steal was over 20%, since those
explain most slow or failed runs. Each is drawn as a band over the steps
lane and the instance's rows, and listed under the peaks.
"""

from std.os import listdir
from std.os.path import exists

from json import Value, loads
from objectstore.fileio import FileIOResolver

from morca._internal.html import Html, escape
from morca._internal.json import quote
from morca._internal.logs import is_remote, read_location, run_dir

comptime _LABEL = 150
comptime _WIDTH = 760
comptime _LANE = 14
comptime _STRIP = 30
comptime _HEAD = 18
comptime _GAP = 8
comptime _AXIS = 22
comptime MAX_SAMPLES = 50_000
"""Samples read per instance at most: 69 hours at 5 s."""

comptime MEMORY_WARN: Float64 = 90.0
comptime DISK_WARN: Float64 = 90.0
comptime STEAL_WARN: Float64 = 20.0


@fieldwise_init
struct Sample(Copyable, Movable):
    var t: Float64
    """Unix time."""
    var dt: Float64
    var user: Float64
    var system: Float64
    var iowait: Float64
    var steal: Float64
    var busiest: Float64
    var mem_total: Int
    var mem_used: Int
    var disk_total: Int
    """Of the fullest disk."""
    var disk_used: Int
    var io: Int
    """Disk bytes read and written per second; -1 where not measured."""
    var net: Int

    def cpu(self) -> Float64:
        return self.user + self.system

    def mem_pct(self) -> Float64:
        if self.mem_total <= 0:
            return 0.0
        return 100.0 * Float64(self.mem_used) / Float64(self.mem_total)

    def disk_pct(self) -> Float64:
        if self.disk_total <= 0:
            return 0.0
        return 100.0 * Float64(self.disk_used) / Float64(self.disk_total)


@fieldwise_init
struct Warning(Copyable, Movable):
    var kind: String
    """`memory`, `disk` or `steal`."""
    var start: Float64
    var end: Float64
    var peak: Float64
    """The highest percentage in it."""

    def what(self) -> String:
        if self.kind == "memory":
            return String("memory over ", Int(MEMORY_WARN), "%")
        if self.kind == "disk":
            return String("disk over ", Int(DISK_WARN), "% full")
        return String("CPU steal over ", Int(STEAL_WARN), "%")


@fieldwise_init
struct Peaks(Copyable, Movable):
    var cpu: Float64
    """User and system, percent of all cores."""
    var busiest: Float64
    var steal: Float64
    var mem_used: Int
    var mem_total: Int
    var mem_pct: Float64
    var disk_used: Int
    var disk_total: Int
    var disk_pct: Float64
    var io: Int
    var net: Int


@fieldwise_init
struct InstanceMetrics(Copyable, Movable):
    var name: String
    """The file's name without `.jsonl`: `local`, `<role>-<instance id>` or
    a pod's name."""
    var samples: List[Sample]
    var skipped: Int
    """Lines that weren't samples."""

    def peaks(self) -> Peaks:
        var p = Peaks(0, 0, 0, 0, 0, 0, 0, 0, 0, -1, 0)
        for s in self.samples:
            p.cpu = max(p.cpu, s.cpu())
            p.busiest = max(p.busiest, s.busiest)
            p.steal = max(p.steal, s.steal)
            if s.mem_pct() >= p.mem_pct:
                p.mem_pct = s.mem_pct()
                p.mem_used = s.mem_used
                p.mem_total = s.mem_total
            if s.disk_pct() >= p.disk_pct:
                p.disk_pct = s.disk_pct()
                p.disk_used = s.disk_used
                p.disk_total = s.disk_total
            p.io = max(p.io, s.io)
            p.net = max(p.net, s.net)
        return p^

    def warnings(self) -> List[Warning]:
        """Stretches of samples over a threshold, each from the start of its
        first sample's interval to its last sample."""
        var out = List[Warning]()
        for kind in ["memory", "disk", "steal"]:
            var inside = False
            var w = Warning(String(kind), 0, 0, 0)
            for s in self.samples:
                var v = s.mem_pct() if kind == "memory" else (
                    s.disk_pct() if kind == "disk" else s.steal
                )
                var limit = MEMORY_WARN if kind == "memory" else (
                    DISK_WARN if kind == "disk" else STEAL_WARN
                )
                if v > limit:
                    if not inside:
                        w = Warning(String(kind), s.t - s.dt, s.t, v)
                        inside = True
                    else:
                        w.end = s.t
                        w.peak = max(w.peak, v)
                elif inside:
                    out.append(w.copy())
                    inside = False
            if inside:
                out.append(w^)
        return out^


@fieldwise_init
struct StepSpan(Copyable, Movable):
    """An attempt, as the steps lane draws it."""

    var step: String
    var partition: String
    var status: String
    var start: Float64
    var end: Float64
    var attempt: Int
    """Its ID, which shows its card (`morca._internal.ui.step_cards`), or 0."""


def _num(v: Value, ptr: String) -> Float64:
    try:
        var got = v.try_at(ptr)
        return got.value().float_or(0) if got else Float64(0)
    except:
        return 0.0


def parse_sample(line: String) raises -> Sample:
    """A sampler's line; raises if it isn't one."""
    var v = loads(line)
    if Int(v.at("/v").int_or(0)) != 1:
        raise Error("not a version 1 sample")
    var disk_total = 0
    var disk_used = 0
    var fullest = -1.0
    var disks = v.try_at("/disk")
    if disks and disks.value().is_array():
        for d in disks.value().array_items():
            var total = Int(_num(d, "/total"))
            var used = Int(_num(d, "/used"))
            if total > 0 and Float64(used) / Float64(total) > fullest:
                fullest = Float64(used) / Float64(total)
                disk_total = total
                disk_used = used
    var io = -1
    var got = v.try_at("/io")
    if got and not got.value().is_null():
        io = Int(_num(v, "/io/read") + _num(v, "/io/write"))
    return Sample(
        v.at("/t").float_or(0),
        _num(v, "/dt"),
        _num(v, "/cpu/user"),
        _num(v, "/cpu/system"),
        _num(v, "/cpu/iowait"),
        _num(v, "/cpu/steal"),
        _num(v, "/cpu/busiest"),
        Int(_num(v, "/mem/total")),
        Int(_num(v, "/mem/used")),
        disk_total,
        disk_used,
        io,
        Int(_num(v, "/net/in") + _num(v, "/net/out")),
    )


def parse_samples(name: String, text: String) -> InstanceMetrics:
    """A sampler's file, in time order; lines that aren't samples are
    counted and skipped."""
    var out = List[Sample]()
    var skipped = 0
    for line in text.splitlines():
        if not line.strip():
            continue
        if len(out) >= MAX_SAMPLES:
            skipped += 1
            continue
        try:
            out.append(parse_sample(String(line)))
        except:
            skipped += 1
    # Restarted samplers append; keep the lines in time order.
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1].t > out[j].t:
            out.swap_elements(j - 1, j)
            j -= 1
    return InstanceMetrics(name, out^, skipped)


def _rank(name: String) -> Int:
    if "head" in name:
        return 1
    if "worker" in name:
        return 2
    return 0


def read_metrics(pipeline: String, run: Int) -> List[InstanceMetrics]:
    """Every instance's samples for the run under `MORCA_LOGS`; none without
    it, or if the directory can't be listed."""
    var out = List[InstanceMetrics]()
    var dir = run_dir(pipeline, run)
    if not dir:
        return out^
    dir.write("/metrics")
    var files = List[String]()
    try:
        if is_remote(dir):
            for loc in FileIOResolver().list(String(dir, "/")):
                files.append(loc)
        elif exists(dir):
            for n in listdir(dir):
                files.append(String(dir, "/", n))
    except:
        return out^
    for f in files:
        if not f.endswith(".jsonl"):
            continue
        var base = String(f[byte = f.rfind("/").or_else(-1) + 1 :])
        var name = String(base[byte = : base.byte_length() - 6])
        try:
            var text = String(from_utf8_lossy=Span(read_location(f)))
            out.append(parse_samples(name, text))
        except:
            pass
    # Local first, then heads, then workers; by name within each.
    for i in range(1, len(out)):
        var j = i
        while j > 0 and (
            _rank(out[j - 1].name) > _rank(out[j].name)
            or (
                _rank(out[j - 1].name) == _rank(out[j].name)
                and out[j - 1].name > out[j].name
            )
        ):
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


# ---------------------------------------------------------------------------
# Numbers as people read them
# ---------------------------------------------------------------------------


def bytes_text(n: Int) -> String:
    """`n` bytes as `512 B`, `3.2 MB`, `12 GB`."""
    var units: List[String] = ["B", "kB", "MB", "GB", "TB"]
    var v = Float64(n)
    var u = 0
    while v >= 1000 and u < len(units) - 1:
        v /= 1000
        u += 1
    if u == 0 or v >= 10:
        return String(Int(v + 0.5), " ", units[u])
    var tenths = Int(v * 10 + 0.5)
    return String(tenths // 10, ".", tenths % 10, " ", units[u])


def pct_text(p: Float64) -> String:
    return String(Int(p + 0.5), "%")


def _fixed1(x: Float64) -> String:
    var n = Int(x * 10.0 + 0.5)
    return String(n // 10, ".", n % 10)


def _clock(t: Float64, t0: Float64) -> String:
    """Seconds after the axis's start, as the timeline writes them."""
    var s = t - t0
    if s >= 3600:
        return String(Int(s / 3600), "h", Int(s / 60) % 60, "m")
    if s >= 60:
        return String(Int(s / 60), "m", Int(s) % 60, "s")
    return String(Int(s), "s")


# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------


def peaks_json(m: InstanceMetrics) -> String:
    """An instance's peaks and warnings, for the run's JSON."""
    var p = m.peaks()
    var out = String(
        '{"samples": ',
        len(m.samples),
        ', "cpu": ',
        _fixed1(p.cpu),
        ', "busiest_core": ',
        _fixed1(p.busiest),
        ', "steal": ',
        _fixed1(p.steal),
        ', "mem_used": ',
        p.mem_used,
        ', "mem_total": ',
        p.mem_total,
        ', "mem_pct": ',
        _fixed1(p.mem_pct),
        ', "disk_used": ',
        p.disk_used,
        ', "disk_total": ',
        p.disk_total,
        ', "disk_pct": ',
        _fixed1(p.disk_pct),
        ', "io": ',
        String(p.io) if p.io >= 0 else String("null"),
        ', "net": ',
        p.net,
        ', "warnings": [',
    )
    var ws = m.warnings()
    for i in range(len(ws)):
        out.write(
            ", " if i else "",
            '{"kind": ',
            quote(ws[i].kind),
            ', "start": ',
            _fixed1(ws[i].start),
            ', "end": ',
            _fixed1(ws[i].end),
            ', "peak": ',
            _fixed1(ws[i].peak),
            "}",
        )
    out.write("]}")
    return out^


# ---------------------------------------------------------------------------
# SVG
# ---------------------------------------------------------------------------


struct _Axis(Copyable, Movable):
    var t0: Float64
    var span: Float64

    def __init__(out self, t0: Float64, t1: Float64):
        self.t0 = t0
        self.span = max(t1 - t0, 1.0)

    def x(self, t: Float64) -> Int:
        var f = (t - self.t0) / self.span
        return _LABEL + Int(min(max(f, 0.0), 1.0) * _WIDTH)


def _ticks(span: Float64) -> Float64:
    var steps: List[Float64] = [
        1,
        2,
        5,
        10,
        15,
        30,
        60,
        120,
        300,
        600,
        900,
        1800,
        3600,
        7200,
        14400,
    ]
    for s in steps:
        if span / s <= 10:
            return s
    return 3600 * Float64(Int(span / 36000) + 1)


def axis_of(
    instances: List[InstanceMetrics], steps: List[StepSpan]
) -> Tuple[Float64, Float64]:
    """The axis's start and end: the first attempt or sample to the last."""
    var t0 = Float64(0)
    var t1 = Float64(0)
    var seen = False
    for m in instances:
        for s in m.samples:
            var a = s.t - s.dt
            if not seen or a < t0:
                t0 = a
            if not seen or s.t > t1:
                t1 = s.t
            seen = True
    for s in steps:
        if not seen or s.start < t0:
            t0 = s.start
        if not seen or s.end > t1:
            t1 = s.end
        seen = True
    return (t0, t1)


def _y(v: Float64, scale: Float64, base: Int, high: Int) -> Int:
    var f = min(max(v / scale, 0.0), 1.0)
    return base - Int(f * Float64(high - 2))


def _path(
    samples: List[Sample],
    ax: _Axis,
    top: Int,
    high: Int,
    which: Int,
    scale: Float64,
    area: Bool,
) -> String:
    """A strip's line (or area) of one value: the highest in each pixel, a
    break wherever samples stop for more than three intervals."""
    var d = String()
    var last_x = -1
    var last_t = Float64(0)
    var best = Float64(0)
    var started = False
    var base = top + high

    # (x, y, whether it starts a new piece)
    var points = List[Tuple[Int, Int, Bool]]()
    for s in samples:
        var v: Float64
        if which == 0:
            v = s.cpu()
        elif which == 1:
            v = s.cpu() + s.iowait
        elif which == 2:
            v = s.steal
        elif which == 3:
            v = s.mem_pct()
        elif which == 4:
            v = s.disk_pct()
        elif which == 5:
            if s.io < 0:
                continue
            v = Float64(s.io)
        else:
            v = Float64(s.net)
        var x = ax.x(s.t)
        var gap = started and s.t - last_t > max(3.0 * s.dt, 10.0)
        if started and x == last_x and not gap:
            best = max(best, v)
            points[len(points) - 1] = (
                x,
                _y(best, scale, base, high),
                points[len(points) - 1][2],
            )
        else:
            best = v
            points.append((x, _y(v, scale, base, high), gap or not started))
            started = True
        last_x = x
        last_t = s.t
    if len(points) == 0:
        return ""
    for i in range(len(points)):
        var p = points[i]
        if p[2]:
            if area and i > 0:
                d.write(" L", points[i - 1][0], " ", base, " Z")
            if area:
                d.write(" M", p[0], " ", base, " L", p[0], " ", p[1])
            else:
                d.write(" M", p[0], " ", p[1])
        else:
            d.write(" L", p[0], " ", p[1])
    if area:
        d.write(" L", points[len(points) - 1][0], " ", base, " Z")
    return String(d[byte=1:])


def _strip_label(mut out: String, y: Int, text: String):
    out.write(
        '<text class="tl__lane" x="12" y="', y, '">', escape(text), "</text>"
    )


def metrics_svg(
    instances: List[InstanceMetrics],
    steps: List[StepSpan],
    live: Bool,
    label: String = "The run's machines over time",
) -> String:
    """The steps lane, then three strips per instance, on one time axis,
    with the warnings as bands; without instances, the steps lane alone.
    `label` names it for screen readers."""
    var t = axis_of(instances, steps)
    var ax = _Axis(t[0], t[1])
    var names = List[String]()
    for s in steps:
        if s.step not in names:
            names.append(s.step)
    var lanes_h = len(names) * _LANE
    var per = _HEAD + 3 * _STRIP + _GAP
    var height = lanes_h + len(instances) * per + _AXIS
    var width = _LABEL + _WIDTH + 30
    var out = String(
        '<svg class="tl mx" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ',
        width,
        " ",
        height,
        '" width="',
        width,
        '" height="',
        height,
        '" role="img" aria-label="',
        escape(label),
        '">',
    )
    # The axis, its ticks through every row.
    var bottom = height - _AXIS
    var step = _ticks(ax.span)
    var at = Float64(0)
    while at <= ax.span + 1e-6:
        var x = ax.x(ax.t0 + at)
        out.write(
            '<line class="tl__tick" x1="',
            x,
            '" x2="',
            x,
            '" y1="0" y2="',
            bottom,
            '"/><text class="tl__time" x="',
            x,
            '" y="',
            bottom + 14,
            '">',
            _clock(ax.t0 + at, ax.t0),
            "</text>",
        )
        at += step
    # The steps lane: one row per step, a bar per attempt.
    for i in range(len(names)):
        out.write(
            '<text class="tl__lane" x="0" y="',
            i * _LANE + 11,
            '" data-step="',
            escape(names[i]),
            '">',
            escape(names[i]),
            "</text>",
        )
    for s in steps:
        var lane = 0
        for i in range(len(names)):
            if names[i] == s.step:
                lane = i
        var x = ax.x(s.start)
        out.write(
            '<rect class="tl__bar tl--',
            lane % 6 if s.status != "failed" else -1,
            '" x="',
            x,
            '" y="',
            lane * _LANE + 2,
            '" width="',
            max(1, ax.x(s.end) - x),
            '" height="10"',
        )
        if s.attempt > 0:
            out.write(
                ' data-step="',
                escape(s.step),
                '" data-attempt="',
                s.attempt,
                '" tabindex="0"',
            )
        out.write(
            "><title>",
            escape(s.step),
            " " if s.partition else "",
            escape(s.partition),
            " ",
            escape(s.status),
            ": ",
            _clock(s.end, s.start),
            "</title></rect>",
        )
    # Each instance: its name, then cpu, mem · disk, io · net.
    for k in range(len(instances)):
        ref m = instances[k]
        var y = lanes_h + k * per
        var p = m.peaks()
        out.write(
            '<text class="mx__name" x="0" y="',
            y + 13,
            '">',
            escape(m.name),
            "</text>",
        )
        var y1 = y + _HEAD
        var y2 = y1 + _STRIP
        var y3 = y2 + _STRIP
        for top in [y1, y2, y3]:
            out.write(
                '<rect class="mx__strip" x="',
                _LABEL,
                '" y="',
                top,
                '" width="',
                _WIDTH,
                '" height="',
                _STRIP - 3,
                '"/>',
            )
        _strip_label(out, y1 + 17, String("cpu ", pct_text(p.cpu)))
        _strip_label(
            out,
            y2 + 17,
            String(
                "mem ", pct_text(p.mem_pct), " · disk ", pct_text(p.disk_pct)
            ),
        )
        var rate = max(p.io, p.net)
        _strip_label(out, y3 + 17, String("io · net ", bytes_text(rate), "/s"))
        var hi = _STRIP - 3
        var rate_scale = Float64(max(rate, 1))
        var parts: List[Tuple[String, Int, Int, Float64, Bool]] = [
            (String("mx__wait"), y1, 1, 100.0, True),
            (String("mx__cpu"), y1, 0, 100.0, True),
            (String("mx__steal"), y1, 2, 100.0, False),
            (String("mx__mem"), y2, 3, 100.0, False),
            (String("mx__disk"), y2, 4, 100.0, False),
            (String("mx__io"), y3, 5, rate_scale, False),
            (String("mx__net"), y3, 6, rate_scale, False),
        ]
        for part in parts:
            if part[2] == 2 and p.steal <= 0:
                continue  # no steal: no line along the bottom
            var d = _path(m.samples, ax, part[1], hi, part[2], part[3], part[4])
            if d:
                out.write('<path class="', part[0], '" d="', d, '"/>')
        # Warnings: over this instance's rows and the steps lane.
        for w in m.warnings():
            var x = ax.x(w.start)
            out.write(
                '<rect class="mx__warn" x="',
                x,
                '" y="0" width="',
                max(2, ax.x(w.end) - x),
                '" height="',
                y3 + _STRIP - 3,
                '"><title>',
                escape(m.name),
                ": ",
                w.what(),
                ", up to ",
                pct_text(w.peak),
                ", ",
                _clock(w.start, ax.t0),
                " to ",
                _clock(w.end, ax.t0),
                "</title></rect>",
            )
    if live:
        out.write(
            '<line class="mx__now" x1="',
            ax.x(t[1]),
            '" x2="',
            ax.x(t[1]),
            '" y1="0" y2="',
            bottom,
            '"/>',
        )
    out.write("</svg>")
    return out^


def metrics_html(
    mut h: Html,
    instances: List[InstanceMetrics],
    steps: List[StepSpan],
    live: Bool,
):
    """The charts, a legend, then each instance's peaks and warnings."""
    if len(instances) == 0:
        return
    h.raw(
        '<p class="muted mx__legend"><span class="mx__key mx__key--cpu">',
        '</span>user + system <span class="mx__key mx__key--wait"></span>',
        'iowait <span class="mx__key mx__key--steal"></span>steal',
        ' <span class="mx__key mx__key--mem"></span>memory',
        ' <span class="mx__key mx__key--disk"></span>fullest disk',
        ' <span class="mx__key mx__key--io"></span>disk io',
        ' <span class="mx__key mx__key--net"></span>network',
        ' <span class="mx__key mx__key--warn"></span>warning</p>',
    )
    h.raw('<div class="scroll">', metrics_svg(instances, steps, live), "</div>")
    h.raw(
        '<div class="scroll"><table class="mx__peaks"><thead><tr>',
        "<th>Instance</th>",
        '<th class="num">Samples</th><th class="num">CPU</th>',
        '<th class="num">Busiest core</th><th class="num">Steal</th>',
        '<th class="num">Memory</th><th class="num">Disk</th>',
        '<th class="num">Disk io</th><th class="num">Network</th>',
        "<th>Warnings</th></tr></thead><tbody>",
    )
    for m in instances:
        var p = m.peaks()
        h.raw("<tr><td><code>")
        h.text(m.name)
        h.raw("</code></td>")
        h.num(len(m.samples))
        h.num(pct_text(p.cpu))
        h.num(pct_text(p.busiest))
        h.num(pct_text(p.steal))
        h.num(
            bytes_text(p.mem_used),
            " of ",
            bytes_text(p.mem_total),
            " (",
            pct_text(p.mem_pct),
            ")",
        )
        h.num(
            bytes_text(p.disk_used),
            " of ",
            bytes_text(p.disk_total),
            " (",
            pct_text(p.disk_pct),
            ")",
        )
        if p.io >= 0:
            h.num(bytes_text(p.io), "/s")
        else:
            h.raw('<td class="num muted">n/a</td>')
        h.num(bytes_text(p.net), "/s")
        h.raw("<td>")
        var ws = m.warnings()
        for i in range(len(ws)):
            h.raw(
                '<span class="status status--failed">' if i
                == 0 else '<br><span class="status status--failed">'
            )
            h.text(ws[i].what(), ", up to ", pct_text(ws[i].peak))
            h.raw("</span>")
        h.raw("</td></tr>")
    h.raw("</tbody></table></div>")
