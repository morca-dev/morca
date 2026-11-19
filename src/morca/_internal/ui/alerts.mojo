"""Ops › Alerts (`/ops/alerts`): every alert `morca._internal.notify` sent or is
sending, newest first, from `orca.alerts`: when, its kind, its title and
message as sent, links to what it is about (the run, the pipelines, the
watchdog's rules, a worker, Control), whether ntfy took it, and for those
that resolve (a watchdog trip, a stalled fill, the disk, memory pressure,
an `morca notify` that was later `--resolved`) whether it is still open.

`?kind=` and `?state=open|resolved` filter it; `?before=<id>` and
`?after=<id>` page it, 50 to a page (`?limit=`, at most 500), keyset like
the runs list. The newest page refreshes from `/ops/alerts/live` every
30 s. `/api/alerts` is the same as JSON.
"""

import morca._internal.db.alerts_view as alerts_db
from morca._internal.db.alerts_view import AlertRow

from morca._internal.html import Html, query_param, url_encode
from morca._internal.json import quote
from morca._internal.notify import configured as notify_configured, min_seconds
from morca._internal.state import State
from morca._internal.ui.layout import IDLE_EVERY, page_html
from morca._internal.ui.runs import grouped, pager_link
from morca._internal.web.page import Page


comptime ALERTS_PAGE = 50
comptime _MOST = 500

comptime ALERT_KINDS: List[String] = [
    "run-failed",
    "watchdog",
    "fill-stalled",
    "disk",
    "worker-lost",
    "memory-pressure",
    "backup-failed",
]
"""The kinds morca raises (`orca.alerts`, `morca._internal.admission`) and the one the
Hetzner server's backup sends; the filter adds any others the table has."""


@fieldwise_init
struct AlertsAsk(Copyable, Movable):
    """What a page of alerts is asked for: its filters and its cursor."""

    var kind: String
    var state: String
    var before: Int
    var after: Int
    var size: Int

    def filters(self) -> String:
        """The query string of its filters and size, no cursor."""
        var out = String()
        if self.kind:
            out.write("&kind=", url_encode(self.kind))
        if self.state:
            out.write("&state=", self.state)
        if self.size != ALERTS_PAGE:
            out.write("&limit=", self.size)
        return out^

    def href(self, base: StaticString = "/ops/alerts") -> String:
        var f = self.filters()
        if not f:
            return String(base)
        return String(base, "?", f[byte=1:])

    def with_cursor(self, name: StaticString, id: Int) -> String:
        return String("/ops/alerts?", name, "=", id, self.filters())

    def first(self) -> Bool:
        """Whether it is the newest page."""
        return self.before == 0 and self.after == 0


def _int(s: String) -> Int:
    try:
        return Int(s)
    except:
        return 0


def alerts_ask(url: String) -> AlertsAsk:
    """The page `url` asks for; an unknown `state` is ignored."""
    var state = query_param(url, "state")
    if state != "open" and state != "resolved":
        state = String()
    var size = _int(query_param(url, "limit"))
    if size <= 0:
        size = ALERTS_PAGE
    return AlertsAsk(
        query_param(url, "kind"),
        state^,
        max(_int(query_param(url, "before")), 0),
        max(_int(query_param(url, "after")), 0),
        min(size, _MOST),
    )


struct AlertsPage(Movable):
    var q: AlertsAsk
    var rows: List[AlertRow]
    var total: Int
    var newer: Int
    """How many under the filters are newer than the page."""
    var older: Bool
    var open: Int
    """Open alerts, whatever the filters."""
    var kinds: List[Tuple[String, Int]]
    """Each kind's alerts under the state filter."""

    def __init__(out self, var q: AlertsAsk):
        self.q = q^
        self.rows = List[AlertRow]()
        self.total = 0
        self.newer = 0
        self.older = False
        self.open = 0
        self.kinds = List[Tuple[String, Int]]()

    def newer_href(self) -> String:
        if self.newer == 0 or len(self.rows) == 0:
            return String()
        return self.q.with_cursor("after", self.rows[0].id)

    def older_href(self) -> String:
        if not self.older or len(self.rows) == 0:
            return String()
        return self.q.with_cursor("before", self.rows[len(self.rows) - 1].id)

    def count_of(self, kind: String) -> Int:
        for k in self.kinds:
            if k[0] == kind:
                return k[1]
        return 0


def alerts_page(mut db: State, var q: AlertsAsk) raises -> AlertsPage:
    """A page of alerts, newest first, with its counts."""
    var p = AlertsPage(q^)
    var got = alerts_db.alert_rows(
        db.conn, p.q.kind, p.q.state, p.q.before, p.q.after, p.q.size + 1
    )
    var more = len(got) > p.q.size
    if more:
        _ = got.pop()
    if p.q.after > 0:
        got.reverse()
        p.older = True
    else:
        p.older = more
    p.rows = got^
    var counts = alerts_db.alerts_counted(
        db.conn,
        p.q.kind,
        p.q.state,
        p.rows[0].id if len(p.rows) > 0 else 1 << 62,
    )
    p.total = counts[0]
    p.newer = counts[1]
    if p.q.after > 0 and p.newer == 0:
        p.older = p.total > len(p.rows)
    p.open = alerts_db.open_alerts(db.conn)
    p.kinds = alerts_db.alert_kinds(db.conn, p.q.state)
    return p^


# ---------------------------------------------------------------------------
# What a row says
# ---------------------------------------------------------------------------


def kind_label(kind: String, event: String) -> String:
    """A kind as the page names it: run failed, watchdog trip, memory
    pressure resolved."""
    var base: String
    if kind == "watchdog":
        base = "watchdog trip" if event == "raised" else "watchdog"
    else:
        base = kind.replace("-", " ")
    if event == "resolved":
        return String(base, " resolved")
    return base^


@fieldwise_init
struct Link(Copyable, Movable):
    var href: String
    var label: String


def links(a: AlertRow) -> List[Link]:
    """Where in the UI an alert points: its run, its pipelines, the
    watchdog's rule, the worker, Control; else the link it was sent with."""
    var out = List[Link]()
    if a.run > 0:
        out.append(Link(String("/runs/", a.run), String("run ", a.run)))
    if a.pipelines:
        for p in a.pipelines.split(","):
            var name = String(p.strip())
            if name:
                out.append(Link(String("/pipelines/", url_encode(name)), name))
    if a.kind == "run-failed" and a.run == 0:
        # Recorded before its run was: the subject is `<run>/<start>`.
        var slash = a.subject.find("/").or_else(-1)
        if slash > 0:
            var id = _int(String(a.subject[byte=:slash]))
            if id > 0:
                out.append(Link(String("/runs/", id), String("run ", id)))
    elif a.kind == "fill-stalled" and not a.pipelines:
        out.append(
            Link(String("/pipelines/", url_encode(a.subject)), a.subject)
        )
    elif a.kind == "watchdog":
        out.append(Link("/watchdog", String("rule ", a.subject)))
    elif a.kind == "worker-lost":
        var slash = a.subject.find("/").or_else(-1)
        if slash > 0:
            out.append(
                Link(
                    String("/ops/pools/self-hosted/", a.subject[byte=:slash]),
                    "worker",
                )
            )
    elif a.kind == "disk" or a.kind == "memory-pressure":
        out.append(Link("/ops/control", "Control"))
    if len(out) == 0 and (
        a.url.startswith("https://") or a.url.startswith("http://")
    ):
        out.append(Link(a.url, "link"))
    return out^


def _delivery_text(a: AlertRow) -> String:
    if a.delivery == "sent":
        return "sent"
    if a.delivery == "dropped":
        return String("not sent: ", a.error) if a.error else "not sent"
    if a.error:
        return String("failed, retrying: ", a.error)
    return "waiting"


# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------


def _q_or_null(s: String) -> String:
    return quote(s) if s else String("null")


def alerts_json(on: Bool, p: AlertsPage) -> String:
    var out = String('{"configured": ', "true" if on else "false")
    out.write(
        ', "min_seconds": ',
        min_seconds(),
        ', "open": ',
        p.open,
        ', "total": ',
        p.total,
        ', "filters": {"kind": ',
        quote(p.q.kind),
        ', "state": ',
        quote(p.q.state),
        ', "limit": ',
        p.q.size,
        '}, "kinds": {',
    )
    for i in range(len(p.kinds)):
        out.write(", " if i else "", quote(p.kinds[i][0]), ": ", p.kinds[i][1])
    out.write('}, "alerts": [')
    for i in range(len(p.rows)):
        ref a = p.rows[i]
        out.write(
            ", " if i else "",
            '{"id": ',
            a.id,
            ', "kind": ',
            quote(a.kind),
            ', "event": ',
            quote(a.event),
            ', "subject": ',
            quote(a.subject),
            ', "title": ',
            quote(a.title),
            ', "body": ',
            quote(a.body),
            ', "priority": ',
            quote(a.priority),
            ', "url": ',
            quote(a.url),
            ', "created": ',
            quote(a.created),
            ', "run": ',
            String(a.run) if a.run > 0 else String("null"),
            ', "pipelines": [',
        )
        var first = True
        if a.pipelines:
            for name in a.pipelines.split(","):
                out.write("" if first else ", ", quote(String(name.strip())))
                first = False
        out.write('], "links": [')
        var ls = links(a)
        for j in range(len(ls)):
            out.write(
                ", " if j else "",
                '{"href": ',
                quote(ls[j].href),
                ', "label": ',
                quote(ls[j].label),
                "}",
            )
        out.write(
            '], "delivery": ',
            quote(a.delivery),
            ', "attempts": ',
            a.attempts,
            ', "sent": ',
            _q_or_null(a.sent),
            ', "error": ',
            _q_or_null(a.error),
            ', "resolves": ',
            "true" if a.resolvable else "false",
            ', "state": ',
            _q_or_null(a.state()),
            ', "resolved": ',
            _q_or_null(a.resolved),
            ', "resolved_by": ',
            String(a.resolved_by) if a.resolved_by > 0 else String("null"),
            "}",
        )
    out.write(
        '], "next": ',
        String(p.rows[len(p.rows) - 1].id) if p.older_href() else String(
            "null"
        ),
        ', "prev": ',
        String(p.rows[0].id) if p.newer_href() else String("null"),
        ', "next_url": ',
        _q_or_null(p.older_href()),
        ', "prev_url": ',
        _q_or_null(p.newer_href()),
        "}",
    )
    return out^


# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------


def _time(mut h: Html, utc: String):
    h.raw('<time class="rel" datetime="')
    h.text(utc)
    h.raw('">')
    h.text(utc)
    h.raw("</time>")


def _chip(mut h: Html, cls: StaticString, text: String, title: String = ""):
    h.raw('<span class="status status--', cls, '"')
    if title:
        h.raw(' title="')
        h.text(title)
        h.raw('"')
    h.raw(">")
    h.text(text)
    h.raw("</span>")


def _pager(mut h: Html, p: AlertsPage):
    var newer = p.newer_href()
    var older = p.older_href()
    if not newer and not older:
        return
    h.raw('<nav class="pager" aria-label="Pages of alerts">')
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


def alerts_table_html(mut h: Html, p: AlertsPage):
    """The table of a page of alerts and its pager: what `/ops/alerts/live`
    answers. An open alert's row is marked (`alerts__open`)."""
    if p.open > 0:
        h.raw('<p class="alerts__summary">')
        if p.q.state == "open":
            h.raw(
                "<strong>",
                p.open,
                " open</strong>",
                ' · <a href="/ops/alerts">',
            )
            h.raw("all alerts</a>")
        else:
            h.raw('<a href="/ops/alerts?state=open"><strong>', p.open)
            h.raw(" open</strong></a>")
        h.raw(
            " (still firing: a watchdog trip with a pipeline paused, a stalled",
            " fill, the disk or memory pressure)</p>",
        )
    if len(p.rows) == 0:
        h.raw('<p class="empty">No alerts')
        if p.q.kind or p.q.state:
            h.raw(' here; <a href="/ops/alerts">see them all</a>')
        h.raw(".</p>")
        _pager(h, p)
        return
    h.raw(
        '<div class="scroll"><table class="alerts"><thead><tr>',
        '<th data-help="alerts">When</th><th data-help="alerts">Kind</th>',
        '<th data-help="alerts">Alert</th><th data-help="alerts">Links</th>',
        '<th data-help="alerts">Delivered</th>',
        '<th data-help="alerts">State</th></tr></thead><tbody>',
    )
    for a in p.rows:
        var state = a.state()
        h.raw('<tr id="alert-', a.id, '"')
        if state == "open":
            h.raw(' class="alerts__open"')
        h.raw('><td class="mono">')
        _time(h, a.created)
        h.raw('</td><td><span class="alerts__kind" title="')
        h.text(a.kind, " · ", a.priority, " priority")
        h.raw('">')
        h.text(kind_label(a.kind, a.event))
        h.raw('</span></td><td class="alerts__msg"><strong>')
        h.text(a.title)
        h.raw("</strong>")
        if a.body:
            h.raw('<span class="alerts__body">')
            h.text(a.body)
            h.raw("</span>")
        h.raw('</td><td class="alerts__links">')
        var ls = links(a)
        for j in range(len(ls)):
            if j:
                h.raw(" · ")
            if ls[j].href.startswith("http"):
                h.link_out(ls[j].href, ls[j].label)
            else:
                h.link(ls[j].href, ls[j].label)
        h.raw('</td><td class="alerts__delivery">')
        var said = _delivery_text(a)
        if a.delivery == "sent":
            _chip(
                h,
                "succeeded",
                said,
                String("Sent ", a.sent) if a.sent else String(),
            )
        elif a.delivery == "dropped":
            _chip(h, "skipped", "not sent", said)
        elif a.error:
            _chip(h, "failed", "failed, retrying", said)
        else:
            _chip(h, "pending", said)
        if a.delivery != "sent" and a.error:
            h.raw('<span class="alerts__err">')
            h.text(a.error)
            h.raw("</span>")
        h.raw('</td><td class="alerts__state">')
        if state == "open":
            _chip(h, "failed", "open")
        elif state == "resolved":
            _chip(h, "succeeded", "resolved")
            h.raw("<br>")
            _time(h, a.resolved)
        elif state == "repeated":
            h.raw('<a class="muted" href="#alert-', a.resolved_by, '">')
            h.raw("raised again</a>")
        h.raw("</td></tr>")
    h.raw("</tbody></table></div>")
    _pager(h, p)


def _select(mut h: Html, p: AlertsPage):
    var kinds = materialize[ALERT_KINDS]()
    for k in p.kinds:
        if k[0] not in kinds:
            kinds.append(k[0])
    if p.q.kind and p.q.kind not in kinds:
        kinds.append(p.q.kind)
    h.raw('<label>kind <select name="kind"><option value=""')
    h.raw(" selected" if not p.q.kind else "", ">any</option>")
    for k in kinds:
        h.raw('<option value="')
        h.text(k)
        h.raw('"', " selected" if k == p.q.kind else "", ">")
        h.text(k.replace("-", " "), " (", grouped(p.count_of(k)), ")")
        h.raw("</option>")
    h.raw("</select></label>")
    h.raw('<label>state <select name="state">')
    for s in [
        (String(""), String("any")),
        (String("open"), String("open")),
        (String("resolved"), String("resolved")),
    ]:
        h.raw('<option value="', s[0], '"')
        h.raw(" selected" if s[0] == p.q.state else "", ">", s[1], "</option>")
    h.raw("</select></label>")


comptime _SUBMIT_ON_CHANGE = (
    "<script>for (const f of"
    ' document.querySelectorAll("form.filters")) f.addEventListener("change",'
    ' (e) => { if (e.target.matches("select")) f.submit(); });</script>'
)


def _filters_html(mut h: Html, p: AlertsPage):
    h.raw(
        '<form class="filters" method="get" action="/ops/alerts"',
        ' aria-label="Filter alerts">',
    )
    _select(h, p)
    if p.q.size != ALERTS_PAGE:
        h.raw('<input type="hidden" name="limit" value="', p.q.size, '">')
    h.raw('<button type="submit">Filter</button>')
    if p.q.kind or p.q.state:
        h.raw('<a class="filters__clear" href="/ops/alerts">clear</a>')
    h.raw("</form>", _SUBMIT_ON_CHANGE)


def alerts_html(mut h: Html, on: Bool, p: AlertsPage):
    h.raw("<h1>Alerts</h1>")
    h.raw('<p class="muted">')
    if on:
        h.raw(
            "What morca pushed to the ntfy topic (not shown: anyone who knows",
            " it can read it), newest first; the same alert is sent at most",
            " once every ",
            min_seconds() // 60,
            " minutes. ",
        )
    else:
        h.raw(
            "Alerts aren't configured: set <code>MORCA_NOTIFY_URL</code> (an",
            " ntfy topic URL) to get a push when the watchdog trips, a run",
            " fails, a fill stalls, the disk fills, memory pressure holds",
            " runs or a worker is lost, and they are listed here. ",
        )
    h.raw(
        '<a href="/watchdog">Watchdog</a> has the rules that pause pipelines;',
        " <code>morca notify test</code> sends a test message.</p>",
    )
    _filters_html(h, p)
    if p.q.first():
        h.raw('<div data-poll="')
        h.text(p.q.href("/ops/alerts/live"))
        h.raw('" data-poll-every="', IDLE_EVERY, '">')
    else:
        h.raw("<div>")
    alerts_table_html(h, p)
    h.raw("</div>")


def alerts(mut db: State, url: String) raises -> Page:
    """`/ops/alerts`: the alerts, a page of them."""
    var p = alerts_page(db, alerts_ask(url))
    var on = notify_configured()
    var h = Html()
    alerts_html(h, on, p)
    return Page(200, alerts_json(on, p), page_html("Alerts", "/ops/alerts", h))


def alerts_live(mut db: State, url: String) raises -> Page:
    """`/ops/alerts/live`: the newest page's table, as the fragment it
    refreshes from every `IDLE_EVERY` seconds; an older page answers 286."""
    var p = alerts_page(db, alerts_ask(url))
    var h = Html()
    alerts_table_html(h, p)
    return Page(
        200 if p.q.first() else 286,
        String(),
        h^.finish(),
        "text/html; charset=utf-8",
        poll_every=IDLE_EVERY,
    )


def alerts_api(mut db: State, url: String) raises -> Page:
    """`/api/alerts`: the alerts as JSON, whatever is asked for."""
    var j = alerts_json(notify_configured(), alerts_page(db, alerts_ask(url)))
    return Page(200, j.copy(), j^, "application/json")
