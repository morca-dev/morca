"""The fleet: every machine morca is paying for, as Ops' Pools shows the
EC2 ones (`/ops/pools?kind=ec2`, `morca._internal.ui.pools`) and `/api/fleet` has them
as JSON.

What the page shows comes from three places, none of which reads the
samplers' files when a page is viewed:

- `orca.instances` says which hosts exist, since when, for which run;
- `orca.fleet_samples` holds each live host's last 30 minutes of samples,
  one row per sample;
- `orca.fleet_hourly` holds, per hour and role, what the 7-day charts add up
  (CPU seconds used and available, bytes in and out), kept 8 days.

The scheduler fills both tables (`ingest`, every `MORCA_FLEET_SECONDS`, 30; 0
turns it off). Run instances upload their samples to the run's `metrics/`
folder (`morca._internal.sample`) every `MORCA_CLUSTER_LOG_SECONDS`, so `ingest` reads
the last lines of each live instance's file from there, a few hundred bytes
of it per instance per pass in effect, and keeps those it hasn't got. The
control instance's sampler (`morca sample --out <file> --keep N`, started by
the stack's user data) writes a file `MORCA_CONTROL_SAMPLES` names, and
`MORCA_CONTROL_TYPE` says what the instance is. Without them the control
instance has no row, unless runs placed on it (`morca register --placement
control`, morca.control) are running, which its row lists; without
`MORCA_LOGS` no instance has one.

Prices are a small table of us-east-2 on-demand rates for the types morca
runs on: an estimate (Spot hosts cost less, and a stopped-and-started clock
isn't modelled). With `MORCA_RUNNER=local` no instance is launched, so the
cost tile says "fixed price" instead and shows `MORCA_FIXED_COST` (free text,
such as `€8.49/month`; "Fixed" when unset), with no region.
"""

from std.os import getenv

from json import Value, loads
import morca._internal.db.fleet as fleet_db

from morca._internal.html import Html, escape
from morca._internal.json import quote
from morca._internal.db.live import stale_limit, start_grace
from morca._internal.logs import read_location
from morca._internal.sample import metrics_location
from morca._internal.state import State

comptime SAMPLE_KEEP_MINUTES = 30
"""How long a host's samples are kept in `orca.fleet_samples`."""
comptime HOURLY_KEEP_DAYS = 8
comptime _TAIL = 120
"""Lines read from the end of a sampler's file on each pass."""
comptime _SPARK_SECONDS = 600
comptime _CONTROL = "control"
comptime _W = 760
comptime _H = 120
comptime _LEFT = 40
comptime _AXIS = 18


# ---------------------------------------------------------------------------
# Prices
# ---------------------------------------------------------------------------


def hourly_price(instance_type: String) -> Float64:
    """The us-east-2 on-demand price per hour in US dollars of an instance
    type morca runs on, or -1 for any other."""
    if instance_type == "c7g.large":
        return 0.0725
    if instance_type == "c7g.xlarge":
        return 0.145
    if instance_type == "c7g.2xlarge":
        return 0.29
    if instance_type == "c7g.4xlarge":
        return 0.58
    if instance_type == "t4g.medium":
        return 0.0336
    if instance_type == "t4g.large":
        return 0.0672
    return -1.0


def _fixed(x: Float64, digits: Int) -> String:
    """`x` (zero if negative) with `digits` decimals."""
    var scale = 1
    for _ in range(digits):
        scale *= 10
    var n = Int(max(x, 0.0) * Float64(scale) + 0.5)
    if digits == 0:
        return String(n)
    var frac = String(n % scale)
    while frac.byte_length() < digits:
        frac = String("0", frac)
    return String(n // scale, ".", frac)


def _age(seconds: Float64) -> String:
    """A time span as `45s`, `12m`, `3h 05m` or `2d 4h`."""
    var s = Int(max(seconds, 0.0))
    if s < 90:
        return String(s, "s")
    if s < 3600:
        return String(s // 60, "m")
    if s < 86400:
        var m = (s % 3600) // 60
        return String(s // 3600, "h ", "0" if m < 10 else "", m, "m")
    return String(s // 86400, "d ", (s % 86400) // 3600, "h")


# ---------------------------------------------------------------------------
# Reading samples (pure)
# ---------------------------------------------------------------------------


@fieldwise_init
struct FleetSample(Copyable, Movable):
    """What the fleet keeps of a sampler's line."""

    var t: Float64
    """Unix time."""
    var dt: Float64
    var cores: Float64
    var cpu: Float64
    """User and system, percent of all cores."""
    var busiest: Float64
    var mem: Float64
    """Percent of memory used."""
    var disk: Float64
    """Percent used of the fullest disk."""
    var net_in: Float64
    """Bytes per second."""
    var net_out: Float64


def _num(v: Value, ptr: String) -> Float64:
    try:
        var got = v.try_at(ptr)
        return got.value().float_or(0) if got else Float64(0)
    except:
        return 0.0


def parse_fleet_sample(line: String) raises -> FleetSample:
    """A sampler's line; raises if it isn't one."""
    var v = loads(line)
    if Int(v.at("/v").int_or(0)) != 1:
        raise Error("not a version 1 sample")
    var disk = 0.0
    var disks = v.try_at("/disk")
    if disks and disks.value().is_array():
        for d in disks.value().array_items():
            var total = _num(d, "/total")
            if total > 0:
                disk = max(disk, 100.0 * _num(d, "/used") / total)
    var mem_total = _num(v, "/mem/total")
    return FleetSample(
        v.at("/t").float_or(0),
        _num(v, "/dt"),
        _num(v, "/cores"),
        _num(v, "/cpu/user") + _num(v, "/cpu/system"),
        _num(v, "/cpu/busiest"),
        100.0 * _num(v, "/mem/used") / mem_total if mem_total > 0 else 0.0,
        disk,
        _num(v, "/net/in"),
        _num(v, "/net/out"),
    )


def tail_samples(text: String, n: Int = _TAIL) -> List[FleetSample]:
    """The samples among the last `n` lines of a sampler's file, oldest
    first; lines that aren't samples are skipped."""
    var lines = List[String]()
    for line in text.splitlines():
        if line.strip():
            lines.append(String(line))
    var out = List[FleetSample]()
    for i in range(max(len(lines) - n, 0), len(lines)):
        try:
            out.append(parse_fleet_sample(lines[i]))
        except:
            pass
    return out^


# ---------------------------------------------------------------------------
# Ingesting (the scheduler)
# ---------------------------------------------------------------------------


def _keep(
    mut db: State, host: String, role: String, text: String
) raises -> Int:
    """Stores the samples in `text` that `host` hasn't got and aren't
    older than the keep window, and adds them to the hour's totals."""
    var before = fleet_db.sample_count(db.conn, host)
    for s in tail_samples(text):
        fleet_db.keep_sample(
            db.conn,
            host,
            role,
            s.t,
            s.dt,
            s.cores,
            s.cpu,
            s.busiest,
            s.mem,
            s.disk,
            s.net_in,
            s.net_out,
            SAMPLE_KEEP_MINUTES,
        )
    return fleet_db.sample_count(db.conn, host) - before


def ingest(mut db: State) raises -> Int:
    """One pass: the new samples of every live instance (and of the control
    instance), kept; old ones dropped. Returns the samples added. An
    instance whose file can't be read is skipped, since it may not have
    uploaded yet."""
    var added = 0
    # An instance that just ended uploaded its last lines as it did.
    for row in fleet_db.sampled_instances(db.conn):
        var loc = metrics_location(
            row.pipeline, row.run, String(row.role, "-", row.id)
        )
        if not loc:
            continue
        var text: String
        try:
            text = String(from_utf8_lossy=Span(read_location(loc)))
        except:
            continue
        added += _keep(db, row.id, row.role, text)
    var control = getenv("MORCA_CONTROL_SAMPLES")
    if control:
        try:
            var text = String(from_utf8_lossy=Span(read_location(control)))
            added += _keep(db, _CONTROL, _CONTROL, text)
        except:
            pass
    fleet_db.prune(db.conn, SAMPLE_KEEP_MINUTES, HOURLY_KEEP_DAYS)
    return added


# ---------------------------------------------------------------------------
# What the page shows
# ---------------------------------------------------------------------------


@fieldwise_init
struct Host(Copyable, Movable):
    var id: String
    var role: String
    """`head`, `worker` or `control`."""
    var instance_type: String
    var run: Int
    """The run it serves; 0 for the control instance."""
    var uptime: Float64
    var state: String
    """`starting`, `running`, `draining`, `idle (pooled)` (its run ended,
    and it waits in the EC2 runner's warm pool for another) or
    `control`."""
    var sampled: Bool
    var age: Float64
    """Seconds since its last sample."""
    var cpu: Float64
    var busiest: Float64
    var mem: Float64
    var disk: Float64
    var net_in: Float64
    var net_out: Float64
    var spark_x: List[Float64]
    """Its CPU over the last 10 minutes, as (0 = then, 1 = now) and percent."""
    var spark_y: List[Float64]
    var idle: Float64
    """Seconds it has been idle in the pool; 0 when it isn't."""
    var runs: List[Int]
    """The runs it serves: its `run`, or for the control instance the
    control-placed runs running there (`morca register --placement
    control`)."""


def _control_type() -> String:
    return getenv("MORCA_CONTROL_TYPE")


def fleet_hosts(mut db: State) raises -> List[Host]:
    """One host per live instance, with its last sample, then the control
    instance if it is sampled."""
    var out = List[Host]()
    var sparks_x = Dict[String, List[Float64]]()
    var sparks_y = Dict[String, List[Float64]]()
    for r in fleet_db.spark_points(db.conn, _SPARK_SECONDS):
        var h = r.host
        if h not in sparks_x:
            sparks_x[h] = List[Float64]()
            sparks_y[h] = List[Float64]()
        sparks_x[h].append(1.0 - r.ago / Float64(_SPARK_SECONDS))
        sparks_y[h].append(r.cpu)
    for r in fleet_db.live_instances(db.conn):
        var id = r.id
        var sampled = Bool(r.sample)
        var s = r.sample.value().copy() if sampled else fleet_db.LastSample(
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
        )
        out.append(
            Host(
                id,
                r.role,
                r.instance_type,
                r.run,
                r.up,
                "idle (pooled)" if r.idle else (
                    "draining" if r.draining else (
                        "running" if sampled else "starting"
                    )
                ),
                sampled,
                s.ago,
                s.cpu,
                s.busiest,
                s.mem,
                s.disk,
                s.net_in,
                s.net_out,
                sparks_x.pop(id, List[Float64]()),
                sparks_y.pop(id, List[Float64]()),
                r.idle_for if r.idle else 0.0,
                [r.run],
            )
        )
    # Runs placed on the control instance, live: running with a process
    # that hasn't gone stale.
    var stale = stale_limit()
    var runs = fleet_db.control_runs(db.conn, stale, start_grace(stale))
    var c = fleet_db.last_sample(db.conn, _CONTROL)
    if c or len(runs) > 0:
        var sampled = Bool(c)
        var ago = 0.0
        var cpu = 0.0
        var busiest = 0.0
        var mem = 0.0
        var disk = 0.0
        var net_in = 0.0
        var net_out = 0.0
        if sampled:
            ref r = c.value()
            ago = r.ago
            cpu = r.cpu
            busiest = r.busiest
            mem = r.mem
            disk = r.disk
            net_in = r.net_in
            net_out = r.net_out
        out.append(
            Host(
                _CONTROL,
                _CONTROL,
                _control_type(),
                0,
                0.0,
                _CONTROL,
                sampled,
                ago,
                cpu,
                busiest,
                mem,
                disk,
                net_in,
                net_out,
                sparks_x.pop(_CONTROL, List[Float64]()),
                sparks_y.pop(_CONTROL, List[Float64]()),
                0.0,
                runs^,
            )
        )
    return out^


@fieldwise_init
struct TypeCount(Copyable, Movable):
    var instance_type: String
    var n: Int


@fieldwise_init
struct Summary(Copyable, Movable):
    var heads: Int
    var workers: Int
    var control: Bool
    var types: List[TypeCount]
    var cost: Float64
    """US dollars an hour at on-demand prices."""
    var unpriced: Int
    """Hosts whose type isn't in the price table."""
    var running: Int
    var queued: Int
    var runs_hour: Int
    """Runs started in the last 60 minutes."""
    var runs_spark: List[Float64]
    """Per hour over the last 24, the last one the current hour."""
    var failed_attempts_hour: Int
    var failed_runs_hour: Int
    var errors_spark: List[Float64]
    """Failed attempts and failed runs per hour."""

    def hosts(self) -> Int:
        return self.heads + self.workers + (1 if self.control else 0)


def _bump(mut types: List[TypeCount], t: String, n: Int = 1):
    for i in range(len(types)):
        if types[i].instance_type == t:
            types[i].n += n
            return
    types.append(TypeCount(t, n))


def fleet_summary(mut db: State) raises -> Summary:
    var s = Summary(
        0,
        0,
        False,
        List[TypeCount](),
        0.0,
        0,
        0,
        0,
        0,
        List[Float64](),
        0,
        0,
        List[Float64](),
    )
    for r in fleet_db.live_type_counts(db.conn):
        if r.role == "head":
            s.heads += r.n
        else:
            s.workers += r.n
        _bump(s.types, r.instance_type, r.n)
    if fleet_db.sampled_lately(db.conn, _CONTROL):
        s.control = True
        if _control_type():
            _bump(s.types, _control_type())
    for t in s.types:
        var p = hourly_price(t.instance_type)
        if p < 0:
            s.unpriced += t.n
        else:
            s.cost += p * Float64(t.n)
    var counts = fleet_db.running_and_queued(db.conn)
    s.running = counts[0]
    s.queued = counts[1]
    var hour = fleet_db.last_hour(db.conn)
    s.runs_hour = hour.runs
    s.failed_attempts_hour = hour.attempts
    s.failed_runs_hour = hour.failed
    for r in fleet_db.hourly_sparks(db.conn, 24):
        s.runs_spark.append(r[0])
        s.errors_spark.append(r[1])
    return s^


struct Series(Copyable, Movable):
    var name: String
    var cls: String
    var values: List[Float64]
    var over: Bool
    """Drawn over the series before it, as a bar of the same place."""
    var area: Bool

    def __init__(
        out self,
        name: String,
        cls: String,
        var values: List[Float64],
        over: Bool = False,
        area: Bool = False,
    ):
        self.name = name
        self.cls = cls
        self.values = values^
        self.over = over
        self.area = area


@fieldwise_init
struct Charts(Copyable, Movable):
    var hours: Int
    var labels: List[String]
    """`MM-DD HH:00` (UTC) of each hour."""
    var hosts: List[Series]
    var runs: List[Series]
    var cpu: List[Series]
    var net: List[Series]


def fleet_charts(mut db: State, hours: Int) raises -> Charts:
    var labels = List[String]()
    var heads = List[Float64]()
    var workers = List[Float64]()
    var control = List[Float64]()
    var self_hosted = List[Float64]()
    var started = List[Float64]()
    var finished = List[Float64]()
    var failed = List[Float64]()
    var attempts = List[Float64]()
    var busy = List[Float64]()
    var capacity = List[Float64]()
    var net_in = List[Float64]()
    var net_out = List[Float64]()
    for r in fleet_db.chart_hours(db.conn, hours):
        labels.append(r.label)
        heads.append(r.heads)
        workers.append(r.workers)
        control.append(r.control)
        self_hosted.append(r.self_hosted)
        started.append(r.started)
        finished.append(r.finished)
        failed.append(r.failed + r.attempts)
        attempts.append(r.attempts)
        busy.append(r.busy)
        capacity.append(r.capacity)
        net_in.append(r.nin / 1e6)
        net_out.append(r.nout / 1e6)
    return Charts(
        hours,
        labels^,
        [
            Series("heads", "fl--0", heads^),
            Series("workers", "fl--1", workers^),
            Series("control", "fl--2", control^),
            Series("self-hosted", "fl--3", self_hosted^),
        ],
        [
            Series("started", "fl--live", started^),
            Series("finished", "fl--0", finished^),
            Series(
                "failures (runs and attempts)", "fl--bad", failed^, over=True
            ),
        ],
        [
            Series("vCPUs busy", "fl--0", busy^, area=True),
            Series("vCPUs available", "fl--faint", capacity^),
        ],
        [
            Series("in (MB/s)", "fl--0", net_in^, area=True),
            Series("out (MB/s)", "fl--1", net_out^),
        ],
    )


# ---------------------------------------------------------------------------
# SVG
# ---------------------------------------------------------------------------


def sparkline(
    xs: List[Float64], ys: List[Float64], top: Float64, label: String
) -> String:
    """A small line of `ys` (0 to `top`) at `xs` (0 to 1) as an inline SVG;
    an empty box without points."""
    var out = String(
        (
            '<svg class="spark" viewBox="0 0 80 22" width="80" height="22"'
            ' role="img" aria-label="'
        ),
        escape(label),
        '">',
    )
    if len(xs) > 0:
        out.write('<polyline points="')
        for i in range(len(xs)):
            var y = 20.5 - min(max(ys[i] / max(top, 1e-9), 0.0), 1.0) * 19.0
            out.write(
                "" if i == 0 else " ",
                _fixed(1.0 + xs[i] * 78.0, 1),
                ",",
                _fixed(y, 1),
            )
        if len(xs) == 1:
            out.write(" ", _fixed(1.0 + xs[0] * 78.0 + 1.0, 1), ",")
            out.write(
                _fixed(
                    20.5 - min(max(ys[0] / max(top, 1e-9), 0.0), 1.0) * 19.0, 1
                )
            )
        out.write('"/>')
    out.write("</svg>")
    return out^


def _hourly_spark(values: List[Float64], label: String) -> String:
    var xs = List[Float64]()
    var top = 1.0
    for i in range(len(values)):
        xs.append(Float64(i) / Float64(max(len(values) - 1, 1)))
        top = max(top, values[i])
    return sparkline(xs, values, top, label)


def _nice(x: Float64) -> Float64:
    """A scale's top: 1, 2 or 5 times a power of ten, at least `x`."""
    if x <= 0:
        return 1.0
    var p = 1.0
    while p > x:
        p /= 10.0
    while p * 10.0 <= x:
        p *= 10.0
    for m in [1.0, 2.0, 5.0, 10.0]:
        if p * m >= x:
            return p * m
    return p * 10.0


def _top_text(top: Float64) -> String:
    if top >= 10:
        return String(Int(top))
    return _fixed(top, 2 if top < 1 else 1)


def _short(label: String, hours: Int) -> String:
    """`HH:00` for a day's chart, `MM-DD` for a week's."""
    if label.byte_length() < 11:
        return label
    return String(label[byte=6:]) if hours <= 24 else String(label[byte=:5])


def _chart(
    title: String,
    unit: String,
    labels: List[String],
    series: List[Series],
    hours: Int,
    stacked: Bool = False,
    bars: Bool = False,
    fixed_top: Float64 = 0.0,
) -> String:
    """A card holding a chart of `series` over the hours: bars side by side
    (or stacked), or lines, with the series' names as a key under it. The
    scale's top is the highest value, rounded up, or `fixed_top`."""
    var n = max(len(labels), 1)
    var top = 0.0
    for i in range(len(labels)):
        var stack = 0.0
        for s in series:
            if i < len(s.values):
                if stacked:
                    stack += s.values[i]
                else:
                    top = max(top, s.values[i])
        top = max(top, stack)
    top = fixed_top if fixed_top > 0 else _nice(top)
    var slot = Float64(_W - _LEFT - 6) / Float64(n)
    var base = _H
    var out = String(
        '<div class="scroll"><svg class="fl" viewBox="0 0 ',
        _W,
        " ",
        _H + _AXIS,
        '" role="img" aria-label="',
        escape(title),
        '"><line class="tl__tick" x1="',
        _LEFT,
        '" x2="',
        _W - 6,
        '" y1="',
        base,
        '" y2="',
        base,
        '"/><text class="tl__time" x="0" y="10">',
        _top_text(top),
        "</text>",
        '<text class="tl__time" x="0" y="',
        base,
        '">0</text>',
    )
    if bars:
        var visible = 0
        for s in series:
            if not s.over:
                visible += 1
        var width = max(Float64(1), (slot - 1.5) / Float64(max(visible, 1)))
        for i in range(len(labels)):
            out.write("<g><title>", escape(labels[i]), " UTC")
            for s in series:
                if i < len(s.values):
                    out.write("; ", escape(s.name), " ", _fixed(s.values[i], 0))
            out.write("</title>")
            var k = 0
            var yoff = 0.0
            for s in series:
                if i >= len(s.values):
                    continue
                var x0 = Float64(_LEFT) + slot * Float64(i)
                var h = s.values[i] / top * Float64(_H - 12)
                var x = x0
                var w = width
                if stacked:
                    w = max(Float64(1), slot - 1.5)
                elif s.over:
                    x = x0 + Float64(max(k - 1, 0)) * width
                else:
                    x = x0 + Float64(k) * width
                    k += 1
                var y = Float64(base) - h - yoff
                if stacked:
                    yoff += h
                if h > 0:
                    out.write(
                        '<rect class="',
                        s.cls,
                        '" x="',
                        _fixed(x, 1),
                        '" y="',
                        _fixed(y, 1),
                        '" width="',
                        _fixed(w, 1),
                        '" height="',
                        _fixed(h, 1),
                        '"/>',
                    )
            out.write(
                '<rect class="runs--none" x="',
                _fixed(Float64(_LEFT) + slot * Float64(i), 1),
                '" y="0" width="',
                _fixed(slot, 1),
                '" height="',
                base,
                '"/></g>',
            )
    else:
        for s in series:
            var d = String()
            for i in range(len(s.values)):
                var x = Float64(_LEFT) + slot * (Float64(i) + 0.5)
                var y = Float64(base) - s.values[i] / top * Float64(_H - 12)
                d.write(
                    "M" if i == 0 else "L", _fixed(x, 1), " ", _fixed(y, 1), " "
                )
            if len(s.values) == 0:
                continue
            if s.area:
                out.write(
                    '<path class="fl__area ',
                    s.cls,
                    '" d="',
                    d,
                    "L",
                    _fixed(Float64(_LEFT) + slot * (Float64(n) - 0.5), 1),
                    " ",
                    base,
                    "L",
                    _fixed(Float64(_LEFT) + slot * 0.5, 1),
                    " ",
                    base,
                    'Z"/>',
                )
            out.write('<path class="fl__line ', s.cls, '" d="', d, '"/>')
        # Hover: the hour's values.
        for i in range(len(labels)):
            out.write("<g><title>", escape(labels[i]), " UTC")
            for s in series:
                if i < len(s.values):
                    out.write("; ", escape(s.name), " ", _fixed(s.values[i], 2))
            out.write(
                '</title><rect class="runs--none" x="',
                _fixed(Float64(_LEFT) + slot * Float64(i), 1),
                '" y="0" width="',
                _fixed(slot, 1),
                '" height="',
                base,
                '"/></g>',
            )
    var step = max(n // 4, 1)
    for i in range(0, len(labels), step):
        out.write(
            '<text class="tl__time" x="',
            _fixed(Float64(_LEFT) + slot * (Float64(i) + 0.5) - 14.0, 0),
            '" y="',
            _H + 13,
            '">',
            escape(_short(labels[i], hours)),
            "</text>",
        )
    out.write('</svg></div><p class="fl__keys">')
    for s in series:
        out.write(
            '<span class="fl__key ',
            s.cls,
            '"></span>',
            escape(s.name),
            " &nbsp; ",
        )
    out.write(escape(unit), "</p>")
    return out^


# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------


def _type_text(types: List[TypeCount]) -> String:
    var out = String()
    for i in range(len(types)):
        out.write(", " if i else "", types[i].instance_type, " x", types[i].n)
    return out^


def summary_html(mut h: Html, s: Summary, compact: Bool):
    """The summary cards; each links to where its detail is."""
    h.raw('<div class="stats', " stats--compact" if compact else "", '">')
    # Hosts.
    h.raw(
        '<a class="stat" href="/ops/pools?kind=ec2#machines"><span'
        ' class="stat__k">Hosts'
    )
    h.raw('</span><span class="stat__v">', s.hosts(), "</span>")
    h.raw('<span class="stat__s">')
    h.text(
        s.heads,
        " head",
        "" if s.heads == 1 else "s",
        ", ",
        s.workers,
        " worker",
        "" if s.workers == 1 else "s",
        ", control" if s.control else ", no control sampler",
    )
    if not compact and len(s.types) > 0:
        h.raw("<br>")
        h.text(_type_text(s.types))
    h.raw("</span></a>")
    # Cost.
    if getenv("MORCA_RUNNER") == "local":
        # The local runner launches no instances: the server's price is fixed.
        h.raw(
            '<a class="stat" href="/ops/pools?kind=ec2#machines"><span'
            ' class="stat__k">Cost'
        )
        h.raw('</span><span class="stat__v">')
        h.text(getenv("MORCA_FIXED_COST", "Fixed"))
        h.raw('</span><span class="stat__s">fixed price: the local runner')
        h.raw(" launches no instances</span></a>")
    else:
        h.raw(
            '<a class="stat" href="/ops/pools?kind=ec2#machines"><span'
            ' class="stat__k">Cost now'
        )
        h.raw('</span><span class="stat__v">~$', _fixed(s.cost, 2), "/h</span>")
        h.raw('<span class="stat__s">estimate, on-demand us-east-2')
        if s.unpriced > 0:
            h.raw("; ", s.unpriced, " unpriced")
        h.raw("</span></a>")
    # Runs.
    h.raw('<a class="stat" href="/runs?status=running">')
    h.raw('<span class="stat__k">Runs now</span><span class="stat__v">')
    h.raw(s.running, " <small>running</small></span>")
    h.raw('<span class="stat__s">', s.queued, " queued</span></a>")
    # Runs and errors per hour.
    h.raw(
        '<a class="stat" href="/ops/pools?kind=ec2#runs"><span class="stat__k">'
    )
    h.raw('Runs per hour</span><span class="stat__v">', s.runs_hour, "</span>")
    h.raw(
        '<span class="stat__s">',
        _hourly_spark(s.runs_spark, "Runs started per hour, last 24 hours"),
        "</span></a>",
    )
    h.raw('<a class="stat stat--errors" href="/runs?status=failed">')
    h.raw('<span class="stat__k">Errors per hour</span>')
    h.raw(
        '<span class="stat__v">',
        s.failed_attempts_hour + s.failed_runs_hour,
        "</span>",
    )
    h.raw(
        '<span class="stat__s">',
        s.failed_attempts_hour,
        " step attempts, ",
        s.failed_runs_hour,
        " runs ",
        _hourly_spark(
            s.errors_spark, "Failed attempts and runs per hour, last 24 hours"
        ),
        "</span></a></div>",
    )


def _rank(role: String) -> Int:
    if role == "control":
        return 0
    return 1 if role == "head" else 2


def _less(a: Host, b: Host, sort: String) -> Bool:
    """Whether `a` sorts before `b` ascending by column `sort`."""
    if sort == "type":
        if a.instance_type != b.instance_type:
            return a.instance_type < b.instance_type
    elif sort == "run":
        if a.run != b.run:
            return a.run < b.run
    elif sort == "uptime":
        if a.uptime != b.uptime:
            return a.uptime < b.uptime
    elif sort == "cpu":
        if a.cpu != b.cpu:
            return a.cpu < b.cpu
    elif sort == "busiest":
        if a.busiest != b.busiest:
            return a.busiest < b.busiest
    elif sort == "mem":
        if a.mem != b.mem:
            return a.mem < b.mem
    elif sort == "net":
        if a.net_in + a.net_out != b.net_in + b.net_out:
            return a.net_in + a.net_out < b.net_in + b.net_out
    elif sort == "disk":
        if a.disk != b.disk:
            return a.disk < b.disk
    elif sort == "state":
        if a.state != b.state:
            return a.state < b.state
    if _rank(a.role) != _rank(b.role):
        return _rank(a.role) < _rank(b.role)
    return a.id < b.id


def sort_hosts(mut hosts: List[Host], sort: String, desc: Bool):
    """Orders the hosts by a column, as `?sort=` and `&dir=desc` say; an
    unknown column is the default (role, then id)."""
    for i in range(1, len(hosts)):
        var j = i
        while j > 0:
            var before = _less(hosts[j], hosts[j - 1], sort)
            var swap = _less(hosts[j - 1], hosts[j], sort) if desc else before
            if not swap:
                break
            hosts.swap_elements(j - 1, j)
            j -= 1


def charts_html(mut h: Html, c: Charts, range: String, base: String):
    """The cards of charts, and the choice of range, links to `base` (a
    path and maybe a query) with `range=` added."""
    var sep = "&amp;" if "?" in base else "?"
    h.raw('<p class="range">Range: ')
    for r in ["24h", "7d"]:
        if r == range:
            h.raw("<strong>", r, "</strong> ")
        else:
            h.raw('<a href="', escape(base), sep, "range=", r, '">', r, "</a> ")
    h.raw("(UTC, by the hour)</p>")
    h.raw(
        '<section class="card" id="hours"><h2><a class="anchor"'
        ' href="#hours">Hosts over time</a></h2>'
    )
    h.raw(
        (
            '<p class="muted">Hosts that ran during each hour, by role: EC2'
            " heads and workers, the control host, and self-hosted workers"
            " (morca worker) that ran a run or were seen that hour.</p>"
        ),
        _chart(
            "Hosts over time",
            "",
            c.labels,
            c.hosts,
            c.hours,
            stacked=True,
            bars=True,
        ),
        "</section>",
    )
    h.raw(
        '<section class="card" id="runs"><h2><a class="anchor"'
        ' href="#runs">Runs per hour</a></h2>'
    )
    h.raw(
        '<p class="muted">Runs started and runs that ended each hour; failures',
        " (failed runs, and every failed step attempt, even one a retry",
        " fixed) are overlaid on the finished bar.</p>",
        _chart("Runs per hour", "", c.labels, c.runs, c.hours, bars=True),
        "</section>",
    )
    h.raw(
        '<section class="card" id="fleet-cpu"><h2><a class="anchor"'
        ' href="#fleet-cpu">Fleet CPU</a></h2>'
    )
    h.raw(
        (
            '<p class="muted">The vCPUs of all sampled hosts: busy, and'
            " available.</p>"
        ),
        _chart("Fleet CPU", "vCPUs", c.labels, c.cpu, c.hours),
        "</section>",
    )
    h.raw(
        '<section class="card" id="fleet-network"><h2><a class="anchor"'
        ' href="#fleet-network">Fleet network</a></h2>'
    )
    h.raw(
        '<p class="muted">Throughput summed over all sampled hosts.</p>',
        _chart("Fleet network", "MB/s", c.labels, c.net, c.hours),
        "</section>",
    )


# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------


def _f(x: Float64, digits: Int = 2) -> String:
    return _fixed(x, digits)


def summary_json(s: Summary) -> String:
    var out = String(
        '{"hosts": ',
        s.hosts(),
        ', "heads": ',
        s.heads,
        ', "workers": ',
        s.workers,
        ', "control": ',
        "true" if s.control else "false",
        ', "types": [',
    )
    for i in range(len(s.types)):
        out.write(
            ", " if i else "",
            '{"type": ',
            quote(s.types[i].instance_type),
            ', "count": ',
            s.types[i].n,
            ', "price_per_hour": ',
            _f(
                max(hourly_price(s.types[i].instance_type), 0.0), 4
            ) if hourly_price(s.types[i].instance_type)
            >= 0 else String("null"),
            "}",
        )
    out.write(
        '], "cost_per_hour": ',
        _f(s.cost, 4),
        ', "cost_is_estimate": ',
        "false" if getenv("MORCA_RUNNER") == "local" else "true",
        ', "unpriced_hosts": ',
        s.unpriced,
        ', "runs_running": ',
        s.running,
        ', "runs_queued": ',
        s.queued,
        ', "runs_per_hour": ',
        s.runs_hour,
        ', "failed_attempts_per_hour": ',
        s.failed_attempts_hour,
        ', "failed_runs_per_hour": ',
        s.failed_runs_hour,
        ', "runs_per_hour_24h": [',
    )
    for i in range(len(s.runs_spark)):
        out.write(", " if i else "", Int(s.runs_spark[i]))
    out.write('], "errors_per_hour_24h": [')
    for i in range(len(s.errors_spark)):
        out.write(", " if i else "", Int(s.errors_spark[i]))
    out.write("]}")
    return out^


def hosts_json(hosts: List[Host]) -> String:
    var out = String("[")
    for i in range(len(hosts)):
        ref x = hosts[i]
        out.write(
            ", " if i else "",
            '{"id": ',
            quote(x.id),
            ', "role": ',
            quote(x.role),
            ', "type": ',
            quote(x.instance_type),
            ', "run": ',
            String(x.run) if x.run > 0 else String("null"),
            ', "runs": [',
        )
        var first = True
        for r in x.runs:
            if r > 0:
                out.write("" if first else ", ", r)
                first = False
        out.write(
            "]",
            ', "uptime_seconds": ',
            Int(x.uptime) if x.role != _CONTROL else 0,
            ', "state": ',
            quote(x.state),
            ', "idle_seconds": ',
            Int(x.idle),
            ', "sampled": ',
            "true" if x.sampled else "false",
        )
        if x.sampled:
            out.write(
                ', "sample_age_seconds": ',
                Int(x.age),
                ', "cpu": ',
                _f(x.cpu, 1),
                ', "busiest_core": ',
                _f(x.busiest, 1),
                ', "mem_pct": ',
                _f(x.mem, 1),
                ', "disk_pct": ',
                _f(x.disk, 1),
                ', "net_in_bytes_per_second": ',
                Int(x.net_in),
                ', "net_out_bytes_per_second": ',
                Int(x.net_out),
                ', "cpu_last_10_min": [',
            )
            for k in range(len(x.spark_y)):
                out.write(", " if k else "", _f(x.spark_y[k], 1))
            out.write("]")
        out.write("}")
    out.write("]")
    return out^


def _series_json(s: List[Series]) -> String:
    var out = String("{")
    for i in range(len(s)):
        out.write(", " if i else "", quote(s[i].name), ": [")
        for k in range(len(s[i].values)):
            out.write(", " if k else "", _f(s[i].values[k], 2))
        out.write("]")
    out.write("}")
    return out^


def charts_json(c: Charts) -> String:
    var out = String('{"hours": ', c.hours, ', "labels_utc": [')
    for i in range(len(c.labels)):
        out.write(", " if i else "", quote(c.labels[i]))
    out.write(
        '], "hosts": ',
        _series_json(c.hosts),
        ', "runs": ',
        _series_json(c.runs),
        ', "cpu": ',
        _series_json(c.cpu),
        ', "network": ',
        _series_json(c.net),
        "}",
    )
    return out^
