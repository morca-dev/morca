"""The Coverage card on a dated pipeline's Operate tab: its partitions'
states (`morca._internal.calendar`) as plain HTML, read-only.

A daily pipeline's card has two tabs, **Month** (a month of days) and
**Year** (twelve small months, each with how many of its days are done, and
a strip of every month of its range linking to their years). Both are in
the page; the links work without scripts (`?cov=month|year`, with `?cal=`
the month or year), and with them the tabs switch in place and the choice
is kept in `localStorage`, as the Steps tabs are. Year is the default. A
monthly pipeline's card is its year of months, as before, and an hourly
one's a day of hours (`?cal=YYYY-MM-DD`). For a sensor,
the days what it follows has but it hasn't done, failed or started are
`behind` (`morca._internal.follow`), and `follow_html` is its Progress card's
Following line.

One calendar is read for both tabs (`year_calendar`): the month is cut out
of the year, so the card costs the same three queries as a month did.
"""

from morca._internal.calendar import (
    Calendar,
    Year,
    calendar,
    month_of,
    year_calendar,
    year_of,
)
from morca.civil import Civil, now
from morca._internal.estimate import estimate_text
from morca._internal.follow import Follow, LISTED
from morca._internal.html import Html, url_encode
from morca._internal.ui.layout import act_button
from morca.day import Day
from morca.hour import Hour
from morca.month import Month, days_in
from morca._internal.views.commands import shell_quote
from morca._internal.state import State


def states() -> List[String]:
    """The states, in the legend's order."""
    return ["done", "failed", "live", "behind", "open", "outside"]


def month_name(month: Int) -> String:
    var names = [
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ]
    return String(names[month - 1])


def state_words(state: String) -> String:
    if state == "live":
        return "running or queued"
    if state == "open":
        return "not done"
    if state == "behind":
        return "behind what it follows"
    if state == "outside":
        return "outside the pipeline's range"
    return state


def _cal_title(c: Calendar) raises -> String:
    if c.kind == "monthly" or c.kind == "hourly":
        return c.period
    var y = c.period[byte=:4]
    var m = Int(c.period[byte=5:7])
    return String(month_name(m), " ", y)


def _nav(
    mut h: Html,
    base: String,
    prev: String,
    next: String,
    title: String,
    unit: String,
    view: String,
):
    """`‹ title ›`, the arrows linking `prev` and `next` (`?cal=`) when
    there are; `view` is the tab the links open (empty for none)."""
    h.raw('<div class="cal__head">')
    if prev:
        h.raw('<a rel="prev" href="')
        h.text(base, "?cal=", prev)
        if view:
            h.raw("&amp;cov=", view)
        h.raw('#coverage" aria-label="Previous ', unit, '">‹</a>')
    else:
        h.raw('<span aria-hidden="true">‹</span>')
    h.raw('<strong aria-live="polite">')
    h.text(title)
    h.raw("</strong>")
    if next:
        h.raw('<a rel="next" href="')
        h.text(base, "?cal=", next)
        if view:
            h.raw("&amp;cov=", view)
        h.raw('#coverage" aria-label="Next ', unit, '">›</a>')
    else:
        h.raw('<span aria-hidden="true">›</span>')
    h.raw("</div>")


def _cell(mut h: Html, key: String, state: String, label: String):
    h.raw('<li class="cal__day cal--', state, '" data-key="')
    h.text(key)
    h.raw('" title="')
    h.text(key, ": ", state_words(state))
    h.raw('">')
    h.text(label)
    h.raw('<span class="sr">')
    h.text(", ", key, " ", state_words(state))
    h.raw("</span></li>")


def _legend(mut h: Html, counts: List[Int], follows: List[String]):
    """The states with their counts; `behind` only for a sensor, with what
    it means under it."""
    h.raw('<p class="muted cal__legend">')
    var names = states()
    var first = True
    for i in range(len(names)):
        if names[i] == "behind" and len(follows) == 0:
            continue
        h.raw("" if first else " · ")
        first = False
        h.raw('<span class="cal__key cal--', names[i], '"></span> ')
        h.text(counts[i], " ", state_words(names[i]))
    h.raw("</p>")
    if len(follows) > 0:
        h.raw('<p class="muted cal__legend cov__help">')
        h.text(
            "Behind: ",
            _names(follows),
            (
                " has it, but no run of this pipeline has done it, failed on"
                " it or is going; a backfill queues it."
            ),
        )
        h.raw("</p>")


def _names(names: List[String]) -> String:
    var s = String()
    for i in range(len(names)):
        s.write(
            "" if i == 0 else (" and " if i == len(names) - 1 else ", "),
            names[i],
        )
    return s^


def _month_html(
    mut h: Html,
    base: String,
    c: Calendar,
    view: String,
    follows: List[String],
):
    """A month of days (a year of months for a monthly pipeline, a day of
    hours for an hourly one), as the card has always drawn it."""
    var daily = c.kind == "daily"
    var hourly = c.kind == "hourly"
    h.raw('<div class="cal cal--static" role="group" aria-label="')
    h.text(
        "Days" if daily else ("Hours" if hourly else "Months"),
        " of ",
        c.pipeline,
    )
    h.raw('">')
    try:
        _nav(
            h,
            base,
            c.prev,
            c.next,
            _cal_title(c),
            "month" if daily else ("day" if hourly else "year"),
            view,
        )
    except:
        pass
    h.raw('<ul class="cal__grid')
    h.raw(" cal__grid--days" if daily else " cal__grid--months", '">')
    if daily:
        for w in ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]:
            h.raw('<li class="cal__dow" aria-hidden="true">', w, "</li>")
        for _ in range(c.weekday):
            h.raw('<li class="cal__pad" aria-hidden="true"></li>')
    for i in range(len(c.cells)):
        ref cell = c.cells[i]
        _cell(
            h,
            cell.key,
            cell.state,
            String(i + 1) if daily else (
                String(cell.key[byte=11:]) if hourly else String(
                    month_name(i + 1)[byte=:3]
                )
            ),
        )
    h.raw("</ul>")
    var counts = List[Int]()
    for s in states():
        counts.append(c.count(s))
    _legend(h, counts, follows)
    h.raw("</div>")


def _summary(y: Year, month: Int) -> String:
    """`28/31 done`, of the month's days in the range, and its failures."""
    var outside = y.count("outside", month)
    var total = days_in(y.year, month) - outside
    if total == 0:
        return "not in range"
    var s = String(y.count("done", month), "/", total, " done")
    var failed = y.count("failed", month)
    if failed:
        s.write(", ", failed, " failed")
    return s^


def _year_html(mut h: Html, base: String, y: Year, follows: List[String]):
    """Twelve small months, the year's legend, and the range strip."""
    _nav(
        h,
        base,
        y.prev,
        y.next,
        String(y.year),
        "year",
        "year",
    )
    h.raw('<ol class="cov__months" aria-label="Months of ')
    h.text(y.year)
    h.raw('">')
    for m in range(1, 13):
        var key = String(y.cells[y.first(m)].key[byte=:7])
        h.raw('<li class="cov__month"><a class="cov__name" href="')
        h.text(base, "?cal=", key)
        h.raw('&amp;cov=month#coverage">')
        h.text(month_name(m))
        h.raw('</a><span class="cov__sum">')
        h.text(_summary(y, m))
        h.raw(
            '</span><ul class="cal__grid cal__grid--days cov__grid"',
            ' role="group" aria-label="',
        )
        h.text("Days of ", month_name(m), " ", y.year)
        h.raw('">')
        for w in ["M", "T", "W", "T", "F", "S", "S"]:
            h.raw('<li class="cal__dow" aria-hidden="true">', w, "</li>")
        var pad = (Civil(y.year, m, 1, 0, 0, 0).weekday() + 6) % 7
        for _ in range(pad):
            h.raw('<li class="cal__pad" aria-hidden="true"></li>')
        var lo = y.first(m)
        for i in range(lo, lo + days_in(y.year, m)):
            _cell(h, y.cells[i].key, y.cells[i].state, String())
        h.raw("</ul></li>")
    h.raw("</ol>")
    var counts = List[Int]()
    for s in states():
        counts.append(y.count(s))
    _legend(h, counts, follows)
    if len(y.strip) < 2:
        return
    h.raw(
        '<div class="cov__range"><p class="muted cal__legend">Each month of',
        " its range, by how many of its days are done:</p>",
        '<ol class="cov__strip">',
    )
    for s in y.strip:
        var pct = s.done * 100 // s.total if s.total else 0
        var year = String(s.key[byte=:4])
        var tone = "cov--all" if s.total and s.done == s.total else (
            "cov--none" if s.done == 0 else String("cov--", pct // 25)
        )
        h.raw('<li><a class="cov__bar ', tone)
        if year == String(y.year):
            h.raw(" cov--here")
        h.raw('" href="')
        h.text(base, "?cal=", year)
        h.raw('&amp;cov=year#coverage" title="')
        h.text(s.key, ": ", s.done, "/", s.total, " done (", pct, "%)")
        h.raw('"><span class="sr">')
        h.text(s.key, ": ", pct, "% done")
        h.raw("</span></a></li>")
    var first = String(y.strip[0].key[byte=:4])
    var last = String(y.strip[len(y.strip) - 1].key[byte=:4])
    h.raw('</ol><p class="cov__ends muted"><span>')
    h.text(first)
    h.raw("</span><span>")
    h.text(last)
    h.raw("</span></p></div>")


def coverage_html(
    mut h: Html,
    mut db: State,
    name: String,
    kind: String,
    start: String,
    cal: String,
    view: String,
    f: Optional[Follow] = None,
) raises:
    """The pipeline page's Coverage card; `cal` is the month or year to
    show (`?cal=`, today's if empty) and `view` the tab (`?cov=`). With `f`
    (a sensor's `follow`), what it follows has but it hasn't done is
    `behind`."""
    var base = String("/pipelines/", url_encode(name))
    var upstream = Dict[String, Bool]()
    var follows = List[String]()
    if f:
        upstream = f.value().keys.copy()
        follows = f.value().datasets.copy()
    if kind != "daily":
        h.raw(
            '<section class="card cov" id="coverage"><div class="steps__head">',
            '<h2>Coverage</h2></div><div class="cov__body">',
        )
        try:
            var c = calendar(db, name, kind, start, cal, upstream)
            _month_html(h, base, c, "", follows)
        except e:
            h.raw('<p class="refused">')
            h.text(String(e))
            h.raw("</p>")
        h.raw("</div></section>")
        return
    var year = view != "month"
    h.raw(
        '<section class="card cov" id="coverage"><div class="steps__head">',
        '<h2>Coverage</h2><div class="vtabs"><div role="tablist"',
        ' aria-label="How much to show">',
    )
    var ym: Tuple[Int, Int]
    try:
        ym = year_of(cal, Civil.of(now()))
    except e:
        h.raw('</div></div></div><div class="cov__body"><p class="refused">')
        h.text(String(e))
        h.raw("</p></div></section>")
        return
    var y = year_calendar(db, name, start, ym[0], upstream)
    var c = month_of(y, ym[1])
    for v in [("month", "Month"), ("year", "Year")]:
        var on = (v[0] == "year") == year
        h.raw('<a role="tab" class="vtabs__tab" data-view="', v[0], '" href="')
        h.text(base, "?cal=", c.period if v[0] == "month" else String(y.year))
        h.raw("&amp;cov=", v[0], '#coverage" aria-selected="')
        h.raw("true" if on else "false", '" aria-controls="coverage-', v[0])
        h.raw('">', v[1], "</a>")
    h.raw(
        '</div></div></div><div id="coverage-month" role="tabpanel"',
        ' class="cov__body"',
        " hidden" if year else "",
        ">",
    )
    _month_html(h, base, c, "month", follows)
    h.raw(
        '</div><div id="coverage-year" role="tabpanel" class="cov__body"',
        "" if year else " hidden",
        ">",
    )
    _year_html(h, base, y, follows)
    h.raw("</div></section><script>", _COVERAGE_JS, "</script>")


def coverage_href(name: String, kind: String) -> String:
    """Where a pipeline's coverage number links (`morca._internal.coverage`): its
    Coverage card, a daily one's on the Year tab, or a keyed one's Keys
    on the Overview."""
    var href = String("/pipelines/", url_encode(name))
    if kind == "keyed":
        href.write("#keys")
    elif kind == "daily":
        href.write("?tab=operate&cov=year#coverage")
    else:
        href.write("?tab=operate#coverage")
    return href^


def _key_links(
    mut h: Html, base: String, unit: String, what: String, keys: List[String]
):
    """`what: 2023-08-17, 2023-08-18 and 9 more`, each linking its month (a
    monthly pipeline's year) on the coverage calendar."""
    if len(keys) == 0:
        return
    h.raw('<span class="follow__keys">')
    h.text(what, ": ")
    for i in range(min(len(keys), LISTED)):
        h.raw(", " if i else "", '<a href="')
        var period = String(keys[i][byte=:7]) if unit == "day" else (
            String(keys[i][byte=:10]) if unit
            == "hour" else String(keys[i][byte=:4])
        )
        h.text(base, "?cal=", period)
        if unit == "day":
            h.raw("&amp;cov=month")
        h.raw('#coverage">')
        h.text(keys[i])
        h.raw("</a>")
    if len(keys) > LISTED:
        h.text(" and ", len(keys) - LISTED, " more")
    h.raw("</span>")


def key_ranges(keys: List[String], unit: String) raises -> String:
    """Sorted day (month) keys as `morca backfill` takes them, each run of
    consecutive ones as `FIRST..LAST`: `2023-01-01..2023-01-31,2023-03-04`."""
    var out = String()
    var i = 0
    while i < len(keys):
        var j = i
        while j + 1 < len(keys):
            var nxt: String
            if unit == "day":
                nxt = String(Day.parse(keys[j]).next())
            elif unit == "hour":
                nxt = String(Hour.parse(keys[j]).next())
            else:
                nxt = String(Month.parse(keys[j]).next())
            if nxt != keys[j + 1]:
                break
            j += 1
        if out:
            out.write(",")
        out.write(keys[i])
        if j > i:
            out.write("..", keys[j])
        i = j + 1
    return out^


def _queue_waiting(mut h: Html, name: String, f: Follow, max_runs: Int):
    """A button that backfills the keys in no run yet: a run for each, as
    `morca backfill` over them would queue."""
    var n = len(f.waiting)
    var units = String(f.unit, "" if n == 1 else "s")
    var keys: String
    try:
        keys = key_ranges(f.waiting, f.unit)
    except:
        keys = String(",").join(f.waiting)
    var tell = String(
        "This queues ",
        n,
        " run" if n == 1 else " runs",
        ", one per ",
        f.unit,
        ": ",
        f.waiting[0],
    )
    if n > 1:
        tell.write(" … ", f.waiting[n - 1])
    tell.write(
        ". ",
        estimate_text(
            f.pace, f.pace.backfill(n, n, max_runs), f.unit, min(max_runs, n)
        ),
    )
    h.raw('<span class="follow__queue">')
    act_button(
        h,
        String("/pipelines/", url_encode(name), "/backfill"),
        "Queue them",
        "queue them",
        String("morca backfill ", shell_quote(name), " ", shell_quote(keys)),
        ask=String("Queue the ", units, " not queued yet?"),
        tell=tell,
        yes=String("Queue ", n, " run" if n == 1 else " runs"),
        harm=False,
        partitions=keys,
    )
    h.raw("</span>")


def follow_html(mut h: Html, name: String, f: Follow, max_runs: Int = 1):
    """The Progress card's Following line: what the sensor follows, how
    many of its days (months) are done, and what's behind, by state, with
    the first of each linked, and a button that queues the ones in no run
    yet."""
    var base = String("/pipelines/", url_encode(name))
    var unit = String(f.unit, "" if f.available == 1 else "s")
    if f.upstream:
        h.text(_names(f.upstream), " (", _names(f.datasets), "): ")
    else:
        h.text(_names(f.datasets), ": ")
    if f.available == 0:
        h.text("nothing to follow yet")
        return
    h.text(f.done, " of ", f.available, " ", unit, " done")
    if f.behind() == 0:
        h.text(", none behind")
        return
    h.raw('; <span class="warn">')
    h.text(f.behind(), " behind")
    h.raw("</span>")
    var parts = List[String]()
    if f.live:
        parts.append(String(len(f.live), " running or queued"))
    if f.failed:
        parts.append(String(len(f.failed), " failed"))
    if f.waiting:
        parts.append(String(len(f.waiting), " not queued yet"))
    h.text(": ", _names(parts))
    _key_links(h, base, f.unit, "Running or queued", f.live)
    _key_links(h, base, f.unit, "Failed", f.failed)
    _key_links(h, base, f.unit, "Not queued", f.waiting)
    if f.waiting:
        _queue_waiting(h, name, f, max_runs)


comptime _COVERAGE_JS = """
(() => {
  const sec = document.getElementById("coverage");
  if (!sec || !sec.querySelector("[role=tablist]")) return;
  const get = (k) => { try { return localStorage.getItem(k); } catch (e) { return null; } };
  const put = (k, v) => { try { localStorage.setItem(k, v); } catch (e) {} };
  const show = (v, save) => {
    if (v !== "month" && v !== "year") return;
    for (const a of sec.querySelectorAll("[data-view]")) {
      a.setAttribute("aria-selected", String(a.dataset.view === v));
      document.getElementById("coverage-" + a.dataset.view).hidden = a.dataset.view !== v;
    }
    if (save) put("morca.coverage.view", v);
  };
  sec.querySelector("[role=tablist]").addEventListener("click", (e) => {
    const a = e.target.closest("a[data-view]");
    if (!a) return;
    e.preventDefault();
    show(a.dataset.view, true);
  });
  const q = new URLSearchParams(location.search);
  if (!q.has("cov")) show(get("morca.coverage.view"), false);
})();
"""
"""The Coverage tabs: switch without loading the page, and remember the
choice for every daily pipeline's page; a `?cov=` link still says which."""


comptime COVERAGE_STYLE = """
.cov__body { padding: 0.75rem 1.1rem 0.9rem; display: grid; gap: 0.6rem; }
.cov__body[hidden] { display: none; }
.cov__body > .cal { margin: 0; }
.cov .cal__key { border: 1px solid var(--border-strong); }
.cov__body > .cal__head { max-width: 22rem; }
.cov__months { list-style: none; margin: 0; padding: 0; display: grid; gap: 0.9rem 1.1rem;
  grid-template-columns: repeat(auto-fill, minmax(9.5rem, 1fr)); }
.cov__month { min-width: 0; display: grid; gap: 0.15rem; align-content: start; }
.cov__name { font-size: 0.8125rem; font-weight: 600; color: var(--text); text-decoration: none; }
.cov__name:hover { color: var(--lake); text-decoration: underline; }
.cov__sum { font-size: 0.7rem; color: var(--muted); font-variant-numeric: tabular-nums; }
.cov__grid { gap: 2px; }
.cov__grid .cal__dow { font-size: 0.6rem; line-height: 1.2; }
.cov__grid .cal__day { min-height: 0; aspect-ratio: 1; border-radius: 2px; font-size: 0; }
.cov__grid .cal__day::after { content: none; }
.cov__grid .cal--open { border-color: var(--border-strong); }
.cov__range { display: grid; gap: 0.25rem; }
.cov__strip { list-style: none; margin: 0; padding: 0; display: flex; gap: 1px; }
.cov__strip li { flex: 1 1 0; min-width: 0; }
.cov__bar { display: block; height: 1.1rem; border-radius: 1px; background: var(--surface-2);
  border: 1px solid var(--border); }
.cov__bar:hover, .cov__bar:focus-visible { outline: 2px solid var(--lake); outline-offset: 0; }
.cov--0 { background: color-mix(in srgb, var(--ok) 12%, var(--surface)); }
.cov--1 { background: color-mix(in srgb, var(--ok) 30%, var(--surface)); }
.cov--2 { background: color-mix(in srgb, var(--ok) 50%, var(--surface)); }
.cov--3 { background: color-mix(in srgb, var(--ok) 70%, var(--surface)); }
.cov--all { background: var(--ok); border-color: var(--ok); }
.cov--here { border-color: var(--ember); border-bottom-width: 3px; }
.cal--behind { background: color-mix(in srgb, var(--warn) 18%, var(--surface)); border-color: var(--warn); }
.cal--behind::after { content: "\\2026"; color: var(--warn); }
.cov__grid .cal--behind { border-color: var(--warn); }
.cal__key.cal--behind::after { content: none; }
.follow__keys { display: block; font-size: 0.8125rem; color: var(--muted); }
.follow__queue { display: block; margin-top: 0.35rem; }
.cov__ends { display: flex; justify-content: space-between; margin: 0; font-size: 0.7rem; }
@media (max-width: 640px) {
  .cov__months { grid-template-columns: repeat(auto-fill, minmax(8rem, 1fr)); gap: 0.75rem; }
  .cov__body { padding: 0.6rem 0.75rem 0.75rem; }
}
"""
"""The Coverage card's rules, served after `morca._internal.ui.style.STYLE`."""
