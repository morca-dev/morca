"""The Data tab's quick chart (#435): up to three series over one x, as a
line or a bar chart, drawn as SVG on the server as the UI's other charts
are (`morca._internal.metrics`, `morca._internal.chart`).

A numeric x is placed by its value; any other (a date, a name) is placed
in order, evenly, which for dates is time order since they sort as text.
"""

from morca._internal.html import escape

comptime _LEFT = 56
comptime _WIDTH = 720
comptime _HIGH = 200
comptime _TOP = 8
comptime _AXIS = 22
comptime _POINT_TITLES = 400
"""Points up to which each gets a hover title; past it, only the series."""


@fieldwise_init
struct Point(Copyable, Movable):
    var label: String
    """The x value as text."""
    var x: Float64
    """Where it goes: its value for a numeric x, its place otherwise."""
    var y: List[Optional[Float64]]


@fieldwise_init
struct _Scale(Copyable, Movable):
    """Where a value goes: x across the plot (a bar's slot in from each
    end), y up it."""

    var x0: Float64
    var x1: Float64
    var y0: Float64
    var y1: Float64
    var slot: Float64

    def x(self, v: Float64) -> Int:
        var f = (v - self.x0) / (self.x1 - self.x0)
        return _LEFT + Int(f * (Float64(_WIDTH) - self.slot) + self.slot / 2)

    def y(self, v: Float64) -> Int:
        var f = (v - self.y0) / (self.y1 - self.y0)
        return _TOP + _HIGH - Int(f * Float64(_HIGH))


def _nice_step(span: Float64) -> Float64:
    """A tick step of 1, 2 or 5 times a power of ten, about five ticks."""
    if span <= 0:
        return 1.0
    var raw = span / 5.0
    var p = 1.0
    while p * 10 <= raw:
        p *= 10
    while p > raw:
        p /= 10
    for m in [1.0, 2.0, 5.0, 10.0]:
        if p * m >= raw:
            return p * m
    return p * 10


def number_text(v: Float64) -> String:
    """A number for an axis or a title: whole numbers without a point,
    others to three significant decimals or so."""
    if v == Float64(Int(v)) and abs(v) < 1e15:
        return String(Int(v))
    var a = abs(v)
    var scale = 1000.0 if a < 10 else (100.0 if a < 100 else 10.0)
    var r = Float64(Int(v * scale + (0.5 if v >= 0 else -0.5))) / scale
    var s = String(r)
    return s^


def chart_svg(
    points: List[Point],
    names: List[String],
    bar: Bool,
    label: String,
) -> String:
    """`points`' series (`names`) as a line chart, or grouped bars; `label`
    names it for screen readers."""
    var lo = Float64(0)
    var hi = Float64(0)
    var seen = False
    for p in points:
        for v in p.y:
            if v:
                var y = v.value()
                if not seen or y < lo:
                    lo = y
                if not seen or y > hi:
                    hi = y
                seen = True
    if bar or lo > 0:
        lo = min(lo, 0.0)
    if hi < 0:
        hi = 0.0
    var step = _nice_step(hi - lo)
    var y0 = (
        Float64(
            Int(lo / step)
            - (1 if lo < 0 and lo / step != Float64(Int(lo / step)) else 0)
        )
        * step
    )
    var y1 = y0
    while y1 < hi:
        y1 += step
    if y1 == y0:
        y1 = y0 + step
    var x0 = points[0].x if len(points) else 0.0
    var x1 = points[len(points) - 1].x if len(points) else 1.0
    if x1 == x0:
        x1 = x0 + 1
    var n = max(len(points), 1)
    var slot = Float64(_WIDTH) / Float64(n)

    var sc = _Scale(x0, x1, y0, y1, slot if bar else 0.0)

    var width = _LEFT + _WIDTH + 16
    var height = _TOP + _HIGH + _AXIS
    var out = String(
        '<svg class="tl dc" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ',
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
    # The y axis: a line and a value at each tick.
    var t = y0
    while t <= y1 + step / 1e6:
        var y = sc.y(t)
        out.write(
            '<line class="tl__tick" x1="',
            _LEFT,
            '" x2="',
            _LEFT + _WIDTH,
            '" y1="',
            y,
            '" y2="',
            y,
            '"/><text class="tl__time dc__y" x="',
            _LEFT - 6,
            '" y="',
            y + 4,
            '">',
            escape(number_text(t)),
            "</text>",
        )
        t += step
    # The x axis: up to six labels, evenly over the points.
    var labels = min(6, len(points))
    for k in range(labels):
        var i = k * (len(points) - 1) // max(labels - 1, 1) if labels > 1 else 0
        var x = sc.x(points[i].x)
        out.write(
            '<text class="tl__time dc__x" x="',
            x,
            '" y="',
            _TOP + _HIGH + 16,
            '" text-anchor="',
            "start" if k == 0
            and labels
            > 1 else ("end" if k == labels - 1 and labels > 1 else "middle"),
            '">',
            escape(points[i].label),
            "</text>",
        )
    var series = len(names)
    if bar:
        var w = max(1, Int(slot * 0.8) // max(series, 1))
        var base = sc.y(max(y0, min(0.0, y1)))
        for i in range(len(points)):
            ref p = points[i]
            var left = sc.x(p.x) - (w * series) // 2
            for s in range(min(series, len(p.y))):
                if not p.y[s]:
                    continue
                var v = p.y[s].value()
                var y = sc.y(v)
                out.write(
                    '<rect class="dc__bar dc--',
                    s,
                    '" x="',
                    left + s * w,
                    '" y="',
                    min(y, base),
                    '" width="',
                    max(1, w - 1),
                    '" height="',
                    max(1, abs(base - y)),
                    '"><title>',
                    escape(names[s]),
                    " at ",
                    escape(p.label),
                    ": ",
                    escape(number_text(v)),
                    "</title></rect>",
                )
    else:
        for s in range(series):
            var d = String()
            var pen = False
            for p in points:
                if s >= len(p.y) or not p.y[s]:
                    pen = False
                    continue
                d.write(
                    " L" if pen else " M", sc.x(p.x), " ", sc.y(p.y[s].value())
                )
                pen = True
            if d:
                out.write(
                    '<path class="dc__line dc--',
                    s,
                    '" d="',
                    String(d[byte=1:]),
                    '"/>',
                )
            if len(points) <= _POINT_TITLES:
                for p in points:
                    if s >= len(p.y) or not p.y[s]:
                        continue
                    var v = p.y[s].value()
                    out.write(
                        '<circle class="dc__dot dc--',
                        s,
                        '" cx="',
                        sc.x(p.x),
                        '" cy="',
                        sc.y(v),
                        '" r="2.5"><title>',
                        escape(names[s]),
                        " at ",
                        escape(p.label),
                        ": ",
                        escape(number_text(v)),
                        "</title></circle>",
                    )
    out.write("</svg>")
    return out^


comptime CHART_STYLE = """
.dc__y { text-anchor: end; }
.dc__line { fill: none; stroke-width: 1.75; }
.dc__line.dc--0, .dc__dot.dc--0 { stroke: var(--lake); }
.dc__line.dc--1, .dc__dot.dc--1 { stroke: var(--ember); }
.dc__line.dc--2, .dc__dot.dc--2 { stroke: #7a5af8; }
.dc__dot { fill: var(--surface); stroke-width: 1.5; }
.dc__bar.dc--0, .dc__key--0 { fill: var(--lake); background: var(--lake); }
.dc__bar.dc--1, .dc__key--1 { fill: var(--ember); background: var(--ember); }
.dc__bar.dc--2, .dc__key--2 { fill: #7a5af8; background: #7a5af8; }
.dc__key { display: inline-block; width: 0.9em; height: 0.55em; margin: 0 0.3em 0 0.7em; border-radius: 2px; }
.data__stop { color: var(--warn); }
a.data-link { font-size: 0.75rem; padding: 0 0.4em; border: 1px solid var(--border-strong);
  border-radius: 999px; text-decoration: none; white-space: nowrap; }
a.data-link:hover { border-color: var(--lake); }
.data-line { font-size: 0.8125rem; color: var(--muted); margin-top: 0.15rem; }
.data-line a.data-link { font-size: inherit; border: 0; padding: 0; text-decoration: underline; }
body.anon .data-link--private, body.anon .data-link--private + .data-line__sep { display: none; }
.data__chart form.filters { padding: 0.75rem 1.1rem 0; margin: 0; }
.dview .pager, .dview__panel > p { padding: 0 1.1rem 0.8rem; }
td.null { color: var(--faint); font-style: italic; }
.data__chips { display: flex; flex-wrap: wrap; gap: 0.4rem; margin: 0; padding: 0; list-style: none; font-size: 0.8125rem; }
/* The commit bar (morca._internal.ui.data_bar): one line above the tabs. */
.dbar { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem 0.6rem; margin: 0 0 0.75rem; font-size: 0.875rem; }
.dbar__step { display: inline-grid; place-items: center; width: 2rem; height: 2rem; border: 1px solid var(--border-strong);
  border-radius: var(--radius-sm); background: var(--surface); color: var(--text); text-decoration: none; font-size: 1.1rem; }
a.dbar__step:hover { border-color: var(--lake); }
.dbar__step[aria-disabled] { color: var(--faint); border-color: var(--border); }
.dpick > summary .pick__value { max-width: none; height: 2rem; line-height: calc(2rem - 2px); padding-top: 0; padding-bottom: 0; }
.dpick > summary code { border: 0; background: none; padding: 0; }
.dpick__latest { font-size: 0.75rem; color: var(--ok); margin-left: 0.3rem; }
.dpick__menu { width: min(34rem, calc(100vw - 2rem)); max-height: 60vh; overflow: auto; }
.dpick__search { width: 100%; margin-bottom: 0.3rem; }
.dpick__list { list-style: none; margin: 0; padding: 0; }
.dpick__item { display: flex; gap: 0.6rem; align-items: baseline; padding: 0.3rem 0.4rem; border-radius: 4px;
  color: var(--text); text-decoration: none; }
.dpick__item:hover, .dpick__item:focus-visible { background: var(--surface-2); }
.dpick__item[aria-current] { background: var(--lake-wash); font-weight: 600; }
.dpick__msg { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--muted); }
.dpick__when { font-family: var(--mono); font-size: 0.75rem; color: var(--faint); white-space: nowrap; }
.dbar__rows { color: var(--muted); font-variant-numeric: tabular-nums; }
.dbar__rows strong { color: var(--text); }
.dbar__more { margin-left: auto; font-size: 0.8125rem; }
/* Data | Schema, and the rows filling what's left of the window. */
.dview__head { display: flex; flex-wrap: wrap; gap: 0.5rem 1rem; align-items: center; padding: 0.55rem 1.1rem;
  border-bottom: 1px solid var(--border); background: var(--surface-2); }
.dview__head .vtabs { margin: 0; }
.dview__tools { display: flex; flex-wrap: wrap; gap: 0.4rem 1rem; align-items: center; padding: 0.5rem 1.1rem; }
details.dfilter > summary { cursor: pointer; color: var(--muted); font-size: 0.8125rem; }
details.dfilter[open] { flex-basis: 100%; }
details.dfilter form.filters { margin: 0.6rem 0 0.2rem; }
.dview__panel > .dtable { max-height: max(18rem, calc(100vh - 17rem)); overflow: auto; border-top: 1px solid var(--border); }
.dtable thead th { position: sticky; top: 0; z-index: 1; }
.dview__panel > .dtable > table, .dview__panel > .scroll > table { border: 0; border-radius: 0; overflow: visible; }
.dtype { display: block; margin-top: 0.1rem; font-size: 0.625rem; text-transform: none; letter-spacing: 0;
  color: var(--faint); font-weight: 400; opacity: 0.85; }
.dschema__name code { border: 0; background: none; padding: 0; }
.data__chips li { border: 1px solid var(--border-strong); border-radius: 999px; padding: 0.1rem 0.6rem; }
.data__chips a { margin-left: 0.4rem; text-decoration: none; }
"""
"""The Data tab's own styles; the stylesheet has them (`morca._internal.ui.style`)."""
