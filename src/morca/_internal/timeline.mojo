"""A run's Dista timeline and its workers over time, drawn as SVG on the
server for the run's page.

The timeline is dista's, in Chrome's trace format: a `process_name` event
names each worker's lane (`pid`), and each task is an `X` event on thread 1
(running) or 2 (waiting for inputs), with `ts` and `dur` in microseconds.
Each worker is one lane; a task is a bar coloured by its name, and the time
a task waited for its inputs a thin bar under it. Perfetto shows the same
file in full; this is the glance.

The worker count comes from `orca.instances`, which an `ec2` run has: one
step per instance started or ended.
"""

from json import Value, loads

from morca._internal.html import escape

comptime _LABEL = 150
comptime _WIDTH = 760
comptime _LANE = 18
comptime _AXIS = 22
comptime _COLOURS = 6
comptime MAX_BARS = 20_000
"""Bars drawn at most; a timeline with more says how many it left out."""


@fieldwise_init
struct Bar(Copyable, Movable):
    var lane: Int
    var start: Float64
    """Seconds from the timeline's first event."""
    var length: Float64
    var name: String
    var waiting: Bool
    """Waiting for inputs, rather than running."""


@fieldwise_init
struct Timeline(Movable):
    var lanes: List[String]
    var bars: List[Bar]
    var end: Float64
    """Seconds from the first event to the last one's end."""
    var left_out: Int


def _text(v: Value, key: String) raises -> String:
    var got = v.get(key)
    return got.value().string_or("") if got else String()


def _number(v: Value, key: String) raises -> Float64:
    var got = v.get(key)
    return got.value().float_or(0) if got else Float64(0)


def read_timeline(text: String) raises -> Timeline:
    var events = loads(text).array_items()
    var pids = List[Int]()
    var names = List[String]()
    var raw = List[Tuple[Int, Float64, Float64, String, Bool]]()
    var first = Float64(0)
    var seen = False
    for e in events:
        var ph = _text(e, "ph")
        var pid = Int(_number(e, "pid"))
        if ph == "M" and _text(e, "name") == "process_name":
            var args = e.get("args")
            var label = _text(args.value(), "name") if args else String()
            if pid not in pids:
                pids.append(pid)
                names.append(label)
            else:
                for i in range(len(pids)):
                    if pids[i] == pid:
                        names[i] = label
            continue
        if ph != "X":
            continue
        var tid = Int(_number(e, "tid"))
        if tid != 1 and tid != 2:
            continue
        if pid not in pids:
            pids.append(pid)
            names.append(String("worker ", pid))
        var ts = _number(e, "ts")
        if not seen or ts < first:
            first = ts
            seen = True
        raw.append(
            (
                pid,
                ts,
                _number(e, "dur"),
                _text(e, "name"),
                tid == 2,
            )
        )
    # Lanes in the order of their workers' pids.
    var order = List[Int]()
    for i in range(len(pids)):
        order.append(i)
    for i in range(1, len(order)):
        var j = i
        while j > 0 and pids[order[j - 1]] > pids[order[j]]:
            var t = order[j - 1]
            order[j - 1] = order[j]
            order[j] = t
            j -= 1
    var lane_of = Dict[Int, Int]()
    var lanes = List[String]()
    for k in range(len(order)):
        lane_of[pids[order[k]]] = k
        lanes.append(names[order[k]])
    var bars = List[Bar]()
    var end = Float64(0)
    var left_out = 0
    for r in raw:
        var start = (r[1] - first) / 1e6
        var length = r[2] / 1e6
        end = max(end, start + length)
        if len(bars) >= MAX_BARS:
            left_out += 1
            continue
        bars.append(Bar(lane_of[r[0]], start, length, r[3], r[4]))
    return Timeline(lanes^, bars^, end, left_out)


def _colour(name: String) -> Int:
    """The same colour for a task's name every time."""
    var h = UInt64(14695981039346656037)
    # Only the function, not its arguments: `fanout::trips(…)`.
    var paren = name.find("(").or_else(-1)
    var fn_name = name if paren < 0 else String(name[byte=:paren])
    for b in fn_name.as_bytes():
        h = (h ^ UInt64(b)) * 1099511628211
    return Int(h % _COLOURS)


def _ticks(total: Float64) -> Float64:
    """A tick spacing giving four to ten ticks over `total` seconds."""
    var steps: List[Float64] = [
        0.001,
        0.002,
        0.005,
        0.01,
        0.02,
        0.05,
        0.1,
        0.2,
        0.5,
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
    ]
    for s in steps:
        if total / s <= 10:
            return s
    return 3600 * Float64(Int(total / 36000) + 1)


def _seconds(t: Float64) -> String:
    if t >= 3600:
        return String(Int(t / 3600), "h", Int(t / 60) % 60, "m")
    if t >= 60:
        return String(Int(t / 60), "m", Int(t) % 60, "s")
    if t >= 1 or t == 0:
        return String(Int(t), "s")
    return String(Int(t * 1000), "ms")


def _axis(mut out: String, total: Float64, y: Int):
    var step = _ticks(total)
    var t = Float64(0)
    while t <= total + step / 1000:
        var x = _LABEL + Int(t / total * _WIDTH)
        out.write(
            '<line class="tl__tick" x1="',
            x,
            '" x2="',
            x,
            '" y1="0" y2="',
            y,
            '"/><text class="tl__time" x="',
            x,
            '" y="',
            y + 14,
            '">',
            _seconds(t),
            "</text>",
        )
        t += step


def timeline_svg(t: Timeline) -> String:
    """One lane per worker, its tasks as bars, under a time axis."""
    var total = t.end if t.end > 0 else Float64(1)
    var height = len(t.lanes) * _LANE + _AXIS
    var width = _LABEL + _WIDTH + 30
    var out = String(
        '<svg class="tl" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ',
        width,
        " ",
        height,
        '" width="',
        width,
        '" height="',
        height,
        '" role="img" aria-label="The run\'s tasks on its workers">',
    )
    _axis(out, total, len(t.lanes) * _LANE)
    for i in range(len(t.lanes)):
        out.write(
            '<text class="tl__lane" x="0" y="',
            i * _LANE + 13,
            '">',
            escape(t.lanes[i]),
            "</text>",
        )
    for b in t.bars:
        var x = _LABEL + Int(b.start / total * _WIDTH)
        var w = max(1, Int(b.length / total * _WIDTH))
        var y = b.lane * _LANE + (13 if b.waiting else 2)
        out.write(
            '<rect class="tl__bar tl--',
            _colour(b.name) if not b.waiting else -1,
            '" x="',
            x,
            '" y="',
            y,
            '" width="',
            w,
            '" height="',
            3 if b.waiting else 11,
            '"><title>',
            escape(b.name),
            " (waiting for inputs)" if b.waiting else "",
            ": ",
            _seconds(b.length),
            "</title></rect>",
        )
    out.write("</svg>")
    return out^


def workers_svg(changes: List[Tuple[Float64, Int]], total: Float64) -> String:
    """The number of workers over a run, from `changes` (seconds from the
    run's start, and +1 or -1), as a step line."""
    var span = total if total > 0 else Float64(1)
    var most = 1
    var n = 0
    for c in changes:
        n += c[1]
        most = max(most, n)
    comptime high = 60
    var width = _LABEL + _WIDTH + 30
    var out = String(
        '<svg class="tl" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ',
        width,
        " ",
        high + _AXIS,
        '" width="',
        width,
        '" height="',
        high + _AXIS,
        '" role="img" aria-label="The run\'s workers over time">',
    )
    _axis(out, span, high)
    out.write(
        '<text class="tl__lane" x="0" y="14">',
        most,
        " workers</text>",
        '<text class="tl__lane" x="0" y="',
        high - 2,
        '">0</text><path class="tl__count" d="M',
        _LABEL,
        " ",
        high,
    )
    n = 0
    for c in changes:
        var x = _LABEL + Int(min(c[0], span) / span * _WIDTH)
        out.write(" H", x)
        n += c[1]
        out.write(" V", high - n * (high - 4) // most)
    out.write(" H", _LABEL + _WIDTH, '"/></svg>')
    return out^
