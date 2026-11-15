"""`/runs`, the runs list: newest first, filtered by pipeline, status
(any of several, each with its count), trigger, when it was created, a run
and its partitions, a page at a time (`morca._internal.views.runs.RunsPage`), and its
runs picked to cancel, retry or backfill again in one go
(`morca._internal.api.actions.bulk`); `/runs/table` is a list's page as the fragment
it refreshes from, for `/runs`, a pipeline's Runs tab and the home page.
"""

import morca._internal.db.runs_view as runs_db
from morca._internal.admission import held_warning, row_json, scheduler_pressure
from morca._internal.api.runs import (
    json_runs,
    json_runs_page,
    runs_filters_json,
)
from morca._internal.html import Html, query_param, url_encode
from morca._internal.json import quote
from morca._internal.state import State
from morca._internal.system import alert_html
from morca._internal.ui.layout import (
    HERE_SLOT,
    IDLE_EVERY,
    LIVE_EVERY,
    ask_attrs,
    page_html,
)
from morca._internal.ui.parts import runs_table_html
from morca._internal.ui.recent import recent_table
from morca._internal.views.code import runs_code
from morca._internal.views.runs import (
    BULK_MAX,
    RUNS_PAGE,
    RunsPage,
    RunsQuery,
    int_or_zero,
    runs_page,
    runs_query,
)
from morca._internal.web.page import Page


comptime RUN_STATUSES: List[String] = [
    "queued",
    "running",
    "deferred",
    "succeeded",
    "failed",
    "cancelled",
]
"""The statuses a run takes (`orca.runs.status`), in the order a run goes
through them; a deferred run waits for its `retry_at`."""


comptime RUN_TRIGGERS: List[String] = [
    "schedule",
    "sensor",
    "backfill",
    "manual",
    "ui",
    "rerun",
    "rebuild",
    "fill",
]
"""The triggers morca writes (`orca.runs.trigger`): the scheduler's fires and
sensors, `backfill`, a binary's `run`, the UI's start button, a rerun, a
rebuild and a fill (`morca._internal.fill`). The filter adds any others the table has."""


comptime _SUBMIT_ON_CHANGE = (
    "<script>for (const f of"
    ' document.querySelectorAll("form.filters")) f.addEventListener("change",'
    ' (e) => { if (e.target.matches("select, input[type=checkbox],'
    ' input[type=date]")) f.submit(); });</script>'
)
"""Filtering as soon as a choice changes (a dropdown, a status, a date);
the Filter button, or Enter in a field, does the same without
JavaScript."""


def grouped(n: Int) -> String:
    """`n` with commas between thousands: 1,234."""
    var digits = String(n if n >= 0 else -n)
    var out = String("-" if n < 0 else "")
    var first = digits.byte_length() % 3
    if first == 0:
        first = 3
    out.write(digits[byte=:first])
    var i = first
    while i < digits.byte_length():
        out.write(",", digits[byte = i : i + 3])
        i += 3
    return out^


def pager_link(mut h: Html, rel: StaticString, href: String, label: String):
    h.raw("<a")
    if rel:
        h.raw(' rel="', rel, '"')
    h.raw(' href="')
    h.text(href)
    h.raw('">', label, "</a>")


def _runs_pager(mut h: Html, p: RunsPage):
    """Newest, Newer and Older, and where the page is among the runs that
    match; nothing if it's all of them."""
    var newer = p.newer_href()
    var older = p.older_href()
    if not newer and not older:
        return
    h.raw('<nav class="pager" aria-label="Pages of runs">')
    if p.newer > p.q.size and len(p.rows) > 0:
        pager_link(h, "", p.q.href(), "« Newest")
    if newer:
        pager_link(h, "prev", newer, "← Newer")
    h.raw('<span class="pager__at">')
    if len(p.rows) > 0:
        h.text(
            grouped(p.newer + 1),
            "–",
            grouped(p.newer + len(p.rows)),
            " of ",
            grouped(p.total),
        )
    else:
        h.text("none here, of ", grouped(p.total))
    h.raw("</span>")
    if older:
        pager_link(h, "next", older, "Older →")
    h.raw("</nav>")


def _runs_list_html(mut h: Html, mut db: State, p: RunsPage):
    """A runs table and its pager: what `/runs/table` answers. Each row's
    pipeline and failed step show their code on hover (`runs_code`)."""
    runs_table_html(
        h,
        p.rows,
        p.q.view == "list",
        pick=p.q.view != "home",
        code=runs_code(db, p.rows),
    )
    if p.q.view != "home":
        _runs_pager(h, p)


def runs_list(mut h: Html, mut db: State, p: RunsPage):
    """A runs table and its pager, refreshed from `/runs/table` while a run
    on it is queued or running, and slowly while it's the newest page, so
    new runs join it; an older page with nothing going on stays as it is."""
    var live = p.live()
    if live or p.q.first():
        h.raw('<div data-poll="')
        h.text(p.q.fragment())
        h.raw(
            '" data-poll-every="',
            LIVE_EVERY if live else IDLE_EVERY,
            '">',
        )
    else:
        h.raw("<div>")
    _runs_list_html(h, db, p)
    h.raw("</div>")


def runs_fragment_query(url: String) -> RunsQuery:
    """The list a `/runs/table` URL names."""
    return runs_query(
        url, query_param(url, "view"), query_param(url, "pipeline")
    )


def runs_table(mut db: State, url: String) raises -> Page:
    """`/runs/table`: a runs list's page (`?view=list`, `pipeline` or
    `home`, its filters, `limit` and cursor) as an HTML fragment. While it
    has a run going on it says to ask again in `LIVE_EVERY` seconds; else
    the newest page says `IDLE_EVERY`, and an older one answers 286. The
    home page's is its Recent runs, a row per batch (`recent_table`)."""
    var q = runs_fragment_query(url)
    if q.view == "home":
        return recent_table(db, q.size)
    var p = runs_page(db, q^)
    var h = Html()
    _runs_list_html(h, db, p)
    var live = p.live()
    return Page(
        200 if live or p.q.first() else 286,
        String(),
        h^.finish(),
        "text/html; charset=utf-8",
        poll_every=LIVE_EVERY if live else IDLE_EVERY,
    )


def _select(
    mut h: Html, name: StaticString, options: List[String], current: String
):
    """A labelled `<select>` of `options` after "any", `current` selected;
    `current` is added if it isn't one of them, so the page says what it
    filters by."""
    h.raw("<label>", name, ' <select name="', name, '">')
    h.raw(
        '<option value=""', " selected" if not current else "", ">any</option>"
    )
    var found = False
    for o in options:
        h.raw('<option value="')
        h.text(o)
        h.raw('"')
        if o == current:
            h.raw(" selected")
            found = True
        h.raw(">")
        h.text(o)
        h.raw("</option>")
    if current and not found:
        h.raw('<option value="')
        h.text(current)
        h.raw('" selected>')
        h.text(current)
        h.raw("</option>")
    h.raw("</select></label>")


def _with_seen(known: List[String], seen: List[String]) -> List[String]:
    """`known`, then the values `seen` that aren't in it."""
    var out = known.copy()
    for v in seen:
        if v and v not in out:
            out.append(v)
    return out^


def _quick() -> List[Tuple[String, String]]:
    """The quick picks of when runs were created (`?since=`)."""
    return [
        (String("1h"), String("last hour")),
        (String("today"), String("today")),
        (String("24h"), String("24 h")),
        (String("7d"), String("7 days")),
    ]


def _hidden(mut h: Html, name: StaticString, value: String):
    h.raw('<input type="hidden" name="', name, '" value="')
    h.text(value)
    h.raw('">')


def _moment_input(
    mut h: Html, label: StaticString, name: StaticString, v: String
):
    """A date field, or a date and time one for a value with a time."""
    h.raw(
        "<label>",
        label,
        ' <input type="',
        "datetime-local" if v.byte_length() > 10 else "date",
        '" name="',
        name,
        '" value="',
    )
    h.text(v)
    h.raw('"></label>')


def runs_filters_html(
    mut h: Html,
    mut db: State,
    p: RunsPage,
    pipelines: List[String] = [],
) raises:
    """The filter bar over a runs list: a GET form, so it works without
    JavaScript, that keeps the page size; pipeline (on `/runs`, from
    `pipelines`), status (any of them, each with its runs under the other
    filters), trigger, created from and to, a partition (a glob or a part
    of one) and a run; the quick picks of when, and a link that clears
    them."""
    ref q = p.q
    var action = String(
        "/pipelines/", url_encode(q.pipeline)
    ) if q.view == "pipeline" else String("/runs")
    h.raw('<form class="filters" method="get" action="')
    h.text(action)
    h.raw('" aria-label="Filter runs">')
    if q.view == "pipeline":
        _hidden(h, "tab", "runs")
    else:
        _select(h, "pipeline", pipelines, q.pipeline)
    # Status: checkboxes in a disclosure, each with its count.
    var picked = q.statuses()
    var shown = materialize[RUN_STATUSES]()
    for c in p.counts:
        if c[0] not in shown:
            shown.append(c[0])
    for s in picked:
        if s not in shown:
            shown.append(s)
    h.raw(
        '<details class="pick"><summary><span class="pick__name">status</span>',
        ' <span class="pick__value">',
    )
    h.text(String(", ").join(picked) if len(picked) > 0 else String("any"))
    h.raw('</span></summary><div class="pick__menu">')
    for s in shown:
        var n = p.count_of(s)
        h.raw(
            '<label class="pick__item"><input type="checkbox" name="status"'
            ' value="'
        )
        h.text(s)
        h.raw('"', " checked" if s in picked else "", "> ")
        h.status(s)
        h.raw(' <span class="pick__n">', grouped(n), "</span></label>")
    h.raw("</div></details>")
    var triggers = _with_seen(
        materialize[RUN_TRIGGERS](), runs_db.triggers_seen(db.conn)
    )
    _select(h, "trigger", triggers, q.trigger)
    _moment_input(h, "from", "from", q.start)
    _moment_input(h, "to", "to", q.end)
    h.raw(
        '<label>partitions <input type="search" name="key" size="14"',
        ' placeholder="2023-08-* or a name" value="',
    )
    h.text(q.key)
    h.raw(
        '"></label><label>run <input type="search" name="run" size="7"',
        ' inputmode="numeric" placeholder="id" value="',
    )
    if q.run > 0:
        h.text(q.run)
    h.raw('"></label>')
    if q.since:
        _hidden(h, "since", q.since)
    if q.batch > 0:
        _hidden(h, "batch", String(q.batch))
    if q.size != q.default_size():
        h.raw('<input type="hidden" name="limit" value="', q.size, '">')
    h.raw('<button type="submit">Filter</button>')
    # When: quick picks, as links that keep the other filters.
    h.raw('<span class="filters__quick" aria-label="Created">')
    for t in _quick():
        var c = q.at_newest()
        c.since = String(t[0])
        c.start = String()
        c.end = String()
        h.raw('<a href="')
        h.text(c.href())
        h.raw('"', ' aria-current="true"' if q.since == t[0] else "", ">")
        h.raw(t[1], "</a>")
    if q.since:
        var c = q.at_newest()
        c.since = String()
        h.raw('<a href="')
        h.text(c.href())
        h.raw('">any time</a>')
    h.raw("</span>")
    if q.filtered():
        h.raw('<a class="filters__clear" href="')
        h.text(q.unfiltered().href())
        h.raw('">Clear filters</a>')
    h.raw("</form>", _SUBMIT_ON_CHANGE)


def _runs_word(n: Int) -> String:
    return String(grouped(n), " run" if n == 1 else " runs")


def runs_done_html(mut h: Html, url: String):
    """What a bulk action did (`morca._internal.api.actions.bulk`, which sends the
    browser back with `?did=` and its counts), said over the list."""
    var did = query_param(url, "did")
    if did != "cancel" and did != "retry" and did != "backfill":
        return
    var done = int_or_zero(query_param(url, "done"))
    var skipped = int_or_zero(query_param(url, "skipped"))
    var refused = int_or_zero(query_param(url, "refused"))
    var queued = int_or_zero(query_param(url, "queued"))
    var t = String()
    if did == "cancel":
        t.write("Cancelled ", _runs_word(done))
        if skipped:
            t.write(", ", grouped(skipped), " already finished")
        t.write(". Running ones stop before their next step.")
    elif did == "retry":
        t.write("Queued ", _runs_word(done), " again")
        if skipped:
            t.write(", ", grouped(skipped), " not failed")
        if refused:
            t.write(
                ", ",
                grouped(refused),
                " ran older code (resume each from its page)",
            )
        t.write(".")
    else:
        t.write(
            "Queued ",
            _runs_word(queued),
            " over the partitions of ",
            _runs_word(done),
        )
        if skipped:
            t.write(", ", grouped(skipped), " with none")
        if refused:
            t.write(", ", grouped(refused), " pipelines refused")
        t.write(".")
    h.raw('<p class="notice" role="status">')
    h.text(t)
    h.raw("</p>")


def runs_bulk_html(mut h: Html, p: RunsPage):
    """The form the runs list's checkboxes belong to (`form="bulk-runs"`):
    cancel, retry or backfill again the runs ticked, or every run that
    matches the filters, its number on the box that picks them, which the
    action checks is still so. Hidden until logged in, where login is on
    (`act__need`)."""
    if p.total == 0:
        return
    h.raw(
        '<form id="bulk-runs" class="bulk act__need" method="post"',
        ' action="/runs/bulk" aria-label="Act on runs">',
    )
    for f in p.q.fields():
        h.raw('<input type="hidden" name="')
        h.text(f[0])
        h.raw('" value="')
        h.text(f[1])
        h.raw('">')
    h.raw('<span class="bulk__what">The ticked runs')
    if p.total > len(p.rows) and p.total <= BULK_MAX:
        h.raw(
            '</span><label class="bulk__all"><input type="checkbox" name="all"',
            ' value="1"> or all ',
            grouped(p.total),
            " that match",
            "</label>",
        )
        h.raw('<input type="hidden" name="expect" value="', p.total, '">')
    else:
        h.raw("</span>")
        h.raw('<input type="hidden" name="expect" value="', p.total, '">')
    h.raw('<button type="submit" name="do" value="cancel" class="danger"')
    ask_attrs(
        h,
        "Cancel {runs}?",
        (
            "Queued and deferred ones won't start, and running ones stop before"
            " their next step. Runs that already finished are left as they are."
        ),
        "Cancel runs",
        "Keep them",
    )
    h.raw(
        ">Cancel</button>",
        '<button type="submit" name="do" value="retry">Retry failed</button>',
        '<button type="submit" name="do" value="backfill">Backfill again',
        "</button></form>",
        '<p class="act__login bulk__login"><a href="/login?next=',
        HERE_SLOT,
        '">Log in</a> to cancel, retry or backfill runs from here.</p>',
    )


def runs(mut db: State, var q: RunsQuery, url: String = "") raises -> Page:
    """`/runs`: a page of runs newest first, filtered, by id under
    `q.before` or just above `q.after` (`runs_page`); with how many match
    and links to the newest, newer and older pages, and refreshed while it
    can change (`runs_list`). `?run=` a run that's there goes to its
    page."""
    var p = runs_page(db, q^)
    var j = String('{"runs": ')
    json_runs(j, p.rows)
    j.write(", ")
    runs_filters_json(j, p)
    j.write(", ")
    json_runs_page(j, p)
    var pressure = scheduler_pressure(db)
    j.write(', "memory_pressure": ', row_json(pressure), "}")

    var pipelines = runs_db.pipeline_names(db.conn)

    var h = Html()
    h.raw("<h1>Runs</h1>")
    var held = held_warning(pressure)
    if held:
        alert_html(h, [held])
    runs_filters_html(h, db, p, pipelines)
    runs_done_html(h, url)
    runs_bulk_html(h, p)
    runs_list(h, db, p)
    if jumped(p):
        return Page(
            303,
            j^,
            page_html("Runs", "/runs", h),
            location=String("/runs/", p.q.run),
        )
    return Page(200, j^, page_html("Runs", "/runs", h))


def jumped(p: RunsPage) -> Bool:
    """Whether the list was asked for one run (`?run=`) and has it: the
    page goes to the run's own."""
    return p.q.run > 0 and len(p.rows) == 1 and p.rows[0].id == p.q.run
