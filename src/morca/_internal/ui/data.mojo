"""A dataset's Data tab (#435), `/datasets/<name>?tab=data`: its schema
and partition spec, its partitions from the manifests, a page of its rows
(filtered, picked, sorted and paged), a quick chart of them, and the rows
as CSV; the same as JSON at `/datasets/<name>/data.json`, and the download
at `/datasets/<name>/data.csv`.

The table is read by the project's `morca_maintain` (`morca._internal.views.data`),
within limits a public page keeps to; what stopped a read is shown. A
dataset morca.toml marks `public = false` (`morca._internal.dataset_config`)
shows its data only to those logged in, once login is on.
"""

from std.os import getenv, remove
from std.time import perf_counter_ns

from json import Value, loads

from morca._internal.auth import login_required
from morca._internal.dataset_config import dataset_public
from morca._internal.html import Html, url_encode
from morca._internal.json import quote
from morca._internal.lineage import datasets as dataset_rows
from morca._internal.metrics import bytes_text
from morca._internal.state import State
from morca._internal.ui.data_chart import Point, chart_svg
from morca._internal.ui.datasets import (
    dataset_href,
    dataset_tabs,
    snapshot_href,
)
from morca._internal.ui.layout import (
    HERE_SLOT,
    card_open,
    help_tip,
    not_found,
    page_html,
)
from morca._internal.ui.runs import grouped, pager_link
from morca._internal.lineage import SnapshotRef
from morca._internal.views.data import (
    DataLimits,
    DataQuery,
    DataRead,
    data_argv,
    data_binary,
    read_data,
)
from morca._internal.web.page import Page

comptime _OP_NAMES = [
    ("eq", "="),
    ("ne", "≠"),
    ("lt", "<"),
    ("le", "≤"),
    ("gt", ">"),
    ("ge", "≥"),
    ("in", "in"),
]

comptime _SCHEMA_HELP = (
    "The table's columns at the snapshot shown: each one's field id (how"
    " Iceberg knows it, whatever its name), type, whether it may be null and"
    " its doc string; then how the table is partitioned. schema and"
    " partition_spec in the JSON."
)
comptime _PARTITIONS_HELP = (
    "One row per partition of the snapshot: its rows, data files and bytes,"
    " and the snapshot that last added a file to it, read from the manifests"
    " without reading any data. A value links to the partition's rows."
    " partitions in the JSON."
)
comptime _ROWS_HELP = (
    "A page of the snapshot's rows. Filters on a partition's columns prune"
    " partitions and files before any is read. Without a sort the rows come"
    " in the table's order and only the page is read; a sort reads every"
    " filtered row, up to a limit. rows in the JSON; Download CSV has the"
    " filtered rows, up to a limit."
)
comptime _CHART_HELP = (
    "The filtered rows' y columns, averaged (or summed) for each value of x,"
    " in x's order. chart in the JSON."
)


def data_hidden(mut db: State, name: String, user: String) raises -> Bool:
    """Whether `name`'s data is hidden from this visitor: morca.toml says
    `public = false`, login is on and they aren't logged in."""
    return not user and not dataset_public(db, name) and login_required(db)


def _hidden_page(name: String) -> Page:
    var why = String("log in to see ", name, "'s data")
    var h = Html()
    _head(h, name)
    h.raw('<p class="notice">This dataset\'s data is shown to those logged')
    h.raw(' in. <a href="/login?next=', HERE_SLOT, '">Log in</a> to see it.')
    h.raw("</p>")
    return Page(
        401,
        String(
            '{"dataset": ',
            quote(name),
            ', "error": ',
            quote(why),
            ', "login": "/login"}',
        ),
        page_html(String(name, " · data"), "/datasets", h),
    )


def _head(mut h: Html, name: String):
    h.raw('<p class="crumb"><a href="/datasets">Datasets</a></p><h1>')
    h.text(name)
    h.raw("</h1>")
    dataset_tabs(h, name, "data")


def _qs(query: String) -> String:
    """`DataQuery.query`'s `&k=v...` as a query string's own: no `&`."""
    return String(query.removeprefix("&"))


def _href(name: String, q: DataQuery, cursor: Int = 0) -> String:
    return String(dataset_href(name), "?tab=data", q.query(cursor))


def _wrap(
    name: String, q: DataQuery, limits: DataLimits, r: DataRead
) -> String:
    """The JSON of the tab: the read's, with the limits and the links."""
    var head = String(
        '{"limits": ',
        limits.json(),
        ', "csv_url": ',
        quote(
            String(
                dataset_href(name), "/data.csv?", _qs(q.query(with_chart=False))
            )
        ),
    )
    if r.error:
        return String(
            head,
            ', "dataset": ',
            quote(name),
            ', "error": ',
            quote(r.error),
            "}",
        )
    var next = String("null")
    try:
        var v = loads(r.json)
        var n = v.try_at("/rows/next")
        if n and not n.value().is_null():
            next = quote(
                String(
                    dataset_href(name),
                    "/data.json?",
                    _qs(q.query(Int(n.value().int_value()))),
                )
            )
    except:
        pass
    return String(head, ', "next_url": ', next, ", ", r.json[byte=1:])


def data_page(
    mut db: State, name: String, url: String, user: String
) raises -> Page:
    """The Data tab (the module doc); its JSON is `data.json`'s."""
    var ds = dataset_rows(db, name)
    if len(ds) == 0:
        return not_found(String("no dataset ", name))
    if data_hidden(db, name, user):
        return _hidden_page(name)
    var limits = DataLimits.from_env()
    var q = DataQuery(url, limits)
    var r: DataRead
    if q.problem:
        r = DataRead(String(), q.problem, 400)
    else:
        r = read_data(data_argv(data_binary(), name, q, limits), limits)
    var j = _wrap(name, q, limits, r)
    var status = r.status
    var title = String(name, " · data")
    var h = Html()
    _head(h, name)
    if r.error:
        h.raw('<p class="notice data__stop">')
        h.text(r.error)
        h.raw("</p>")
        if r.status != 400:
            return Page(status, j^, page_html(title, "/datasets", h))
        # A mistake in the filters: the forms, to fix it, read without them.
        q.filters = List[String]()
        q.problem = String()
        r = read_data(data_argv(data_binary(), name, q, limits), limits)
        if r.error:
            return Page(status, j^, page_html(title, "/datasets", h))
    var v = loads(r.json)
    _snapshot_form(h, name, q, v)
    _schema_card(h, v)
    _partitions_card(h, name, q, v)
    _rows_card(h, name, q, v, limits)
    _chart_card(h, name, q, v)
    return Page(status, j^, page_html(title, "/datasets", h))


def data_json(
    mut db: State, name: String, url: String, user: String
) raises -> Page:
    """`/datasets/<name>/data.json`: the Data tab's JSON, whatever is
    asked for."""
    var p = data_page(db, name, url, user)
    var out = Page(p.status, p.json.copy(), p.json.copy(), "application/json")
    return out^


def data_csv(
    mut db: State, name: String, url: String, user: String
) raises -> Page:
    """`/datasets/<name>/data.csv`: the filtered rows (sorted, if asked)
    as CSV, up to `MORCA_DATA_DOWNLOAD_ROWS`. Why it stopped, if it did,
    is its `X-Morca-Stopped` header."""
    var ds = dataset_rows(db, name)
    if len(ds) == 0:
        return not_found(String("no dataset ", name))
    if data_hidden(db, name, user):
        return _hidden_page(name)
    var limits = DataLimits.from_env()
    var q = DataQuery(url, limits)
    if q.problem:
        return Page(
            400,
            String('{"error": ', quote(q.problem), "}"),
            String(q.problem, "\n"),
            "text/plain; charset=utf-8",
        )
    var path = String(
        getenv("TMPDIR", "/tmp").rstrip("/"),
        "/morca-data-",
        Int(perf_counter_ns()),
        ".csv",
    )
    var r = read_data(
        data_argv(data_binary(), name, q, limits, csv=path), limits
    )
    if r.error:
        try:
            remove(path)
        except:
            pass
        return Page(
            r.status,
            String('{"error": ', quote(r.error), "}"),
            String(r.error, "\n"),
            "text/plain; charset=utf-8",
        )
    var text: String
    with open(path, "r") as f:
        text = f.read()
    try:
        remove(path)
    except:
        pass
    var p = Page(200, String(), text^, "text/csv; charset=utf-8")
    var file = String(name.replace(".", "_"), ".csv")
    p.headers.append(
        (
            String("Content-Disposition"),
            String('attachment; filename="', file, '"'),
        )
    )
    try:
        var v = loads(r.json)
        var n = v.try_at("/csv/rows")
        if n:
            p.headers.append(
                (String("X-Morca-Rows"), String(n.value().int_value()))
            )
        var s = v.try_at("/csv/stopped")
        if s and s.value().is_string():
            p.headers.append(
                (String("X-Morca-Stopped"), s.value().string_value())
            )
    except:
        pass
    return p^


# ── the pieces ───────────────────────────────────────────────────────────────


def _hidden(mut h: Html, name: StaticString, value: String):
    h.raw('<input type="hidden" name="', name, '" value="')
    h.text(value)
    h.raw('">')


def _keep(
    mut h: Html,
    q: DataQuery,
    snapshot: Bool,
    filters: Bool,
    rows: Bool,
    chart: Bool,
):
    """Hidden inputs for what a form doesn't set itself, so it keeps it."""
    _hidden(h, "tab", "data")
    if snapshot and q.snapshot:
        _hidden(h, "snapshot", q.snapshot)
    if filters:
        for f in q.filters:
            _hidden(h, "f", f)
    if rows:
        for c in q.columns:
            _hidden(h, "c", c)
        if q.sort:
            _hidden(h, "sort", q.sort)
    if chart and q.charted():
        _hidden(h, "x", q.x)
        for y in q.y:
            _hidden(h, "y", y)
        _hidden(h, "agg", q.agg)
        _hidden(h, "chart", q.chart)


def _text_of(v: Value) -> String:
    """A cell as text: a string's text, any other value's JSON."""
    if v.is_string():
        return v.string_value()
    return v.to_json()


def _names(v: Value, ptr: String) raises -> List[String]:
    var out = List[String]()
    var got = v.try_at(ptr)
    if got:
        for c in got.value().array_items():
            out.append(c.at("/name").string_value())
    return out^


def _snapshot_form(mut h: Html, name: String, q: DataQuery, v: Value) raises:
    var current = v.at("/current")
    var at = v.at("/snapshot")
    h.raw('<form class="filters" method="get" action="')
    h.text(dataset_href(name))
    h.raw('" aria-label="Snapshot">')
    _keep(h, q, False, True, True, True)
    h.raw('<label>snapshot <select name="snapshot">')
    h.raw('<option value="">current')
    if not current.is_null():
        h.raw(" (")
        h.text(current.int_value())
        h.raw(")")
    h.raw("</option>")
    for s in v.at("/snapshots").array_items():
        var id = s.at("/snapshot").int_value()
        var picked = q.snapshot and not at.is_null() and at.int_value() == id
        h.raw('<option value="', id, '"', " selected" if picked else "", ">")
        h.text(
            id,
            " · ",
            s.at("/at").string_value(),
            " · ",
            s.at("/operation").string_value(),
            " +",
            s.at("/added_records").int_value(),
        )
        h.raw("</option>")
    h.raw('</select></label><button type="submit">Show</button>')
    if not at.is_null():
        h.raw('<span class="filters__quick">')
        h.link(
            snapshot_href(SnapshotRef(name, at.int_value())),
            String("Lineage of ", at.int_value()),
        )
        h.raw("</span>")
    h.raw("</form>")


def _schema_card(mut h: Html, v: Value) raises:
    card_open(h, "schema", "Schema", _SCHEMA_HELP, "ui", facts=False)
    h.raw(
        '<div class="scroll"><table><thead><tr><th class="num">Field id</th>',
        "<th>Column</th><th>Type</th><th>Required</th><th>Doc</th></tr>",
        "</thead><tbody>",
    )
    for c in v.at("/schema/columns").array_items():
        h.raw("<tr>")
        h.num(c.at("/id").int_value())
        h.raw("<td><code>")
        h.text(c.at("/name").string_value())
        h.raw("</code></td>")
        h.mono(c.at("/type").string_value())
        h.cell("yes" if c.at("/required").bool_value() else "no")
        var doc = c.at("/doc")
        h.cell(doc.string_value() if doc.is_string() else String())
        h.raw("</tr>")
    h.raw('</tbody></table></div><p class="card__sub">')
    var fields = v.at("/partition_spec/fields").array_items()
    if len(fields) == 0:
        h.raw("Not partitioned.")
    else:
        h.raw("Partitioned by ")
        for i in range(len(fields)):
            ref f = fields[i]
            h.raw(", " if i else "", "<code>")
            h.text(f.at("/name").string_value())
            h.raw("</code> (")
            h.text(f.at("/transform").string_value(), " of ")
            h.raw("<code>")
            h.text(f.at("/source").string_value())
            h.raw("</code>)")
        h.raw(", spec ")
        h.text(v.at("/partition_spec/spec_id").int_value())
        h.raw(".")
    h.raw("</p></section>")


def _partitions_card(mut h: Html, name: String, q: DataQuery, v: Value) raises:
    var got = v.try_at("/partitions")
    if not got:
        return
    var fields = v.at("/partition_spec/fields").array_items()
    if len(fields) == 0:
        return
    card_open(
        h, "partitions", "Partitions", _PARTITIONS_HELP, "ui", facts=False
    )
    var parts = got.value().array_items()
    if len(parts) == 0:
        h.raw(
            '<p class="card__none">No data files at this'
            " snapshot.</p></section>"
        )
        return
    h.raw('<div class="scroll"><table><thead><tr>')
    for f in fields:
        h.raw("<th>")
        h.text(f.at("/name").string_value())
        h.raw("</th>")
    h.raw(
        '<th class="num">Rows</th><th class="num">Files</th>',
        '<th class="num">Size</th><th>Last snapshot</th><th>Written</th>',
        "</tr></thead><tbody>",
    )
    for p in parts:
        h.raw("<tr>")
        for f in fields:
            var key = f.at("/name").string_value()
            var val = p.at(String("/partition/", key))
            var text = _text_of(val)
            if (
                f.at("/transform").string_value() == "identity"
                and not val.is_null()
            ):
                var q2 = q.copy()
                q2.filters.append(
                    String(f.at("/source").string_value(), ":eq:", text)
                )
                h.raw('<td class="mono">')
                h.link(String(_href(name, q2), "#rows"), text)
                h.raw("</td>")
            else:
                h.mono(text)
        h.num(grouped(Int(p.at("/rows").int_value())))
        h.num(grouped(Int(p.at("/files").int_value())))
        h.num(bytes_text(Int(p.at("/bytes").int_value())))
        h.raw("<td>")
        var last = p.at("/last_snapshot").int_value()
        if last >= 0:
            h.link(snapshot_href(SnapshotRef(name, last)), String(last))
        h.raw("</td>")
        var when = p.at("/last_at")
        h.mono(when.string_value() if when.is_string() else String())
        h.raw("</tr>")
    h.raw("</tbody></table></div>")
    var total = Int(v.at("/partitions_total").int_value())
    if total > len(parts):
        h.raw(
            '<p class="card__sub">The first ',
            grouped(len(parts)),
            " of ",
            grouped(total),
            " partitions.</p>",
        )
    h.raw("</section>")


def _op_name(op: String) -> String:
    for o in materialize[_OP_NAMES]():
        if o[0] == op:
            return String(o[1])
    return op


def _rows_card(
    mut h: Html, name: String, q: DataQuery, v: Value, limits: DataLimits
) raises:
    var cols = List[String]()
    for c in v.at("/schema/columns").array_items():
        cols.append(c.at("/name").string_value())
    h.raw('<section class="card data__rows" id="rows"><h2>Rows')
    help_tip(h, "card-rows", "Rows", _ROWS_HELP, "ui")
    h.raw("</h2>")
    # The filters, each with a link that drops it.
    if len(q.filters):
        h.raw('<ul class="data__chips" aria-label="Filters">')
        for i in range(len(q.filters)):
            ref f = q.filters[i]
            var a = f.find(":")
            var b = f.find(":", a + 1)
            h.raw("<li><code>")
            h.text(f[byte=:a])
            h.raw("</code> ")
            h.text(
                _op_name(String(f[byte = a + 1 : b])), " ", f[byte = b + 1 :]
            )
            h.raw('<a href="')
            h.text(
                String(
                    dataset_href(name),
                    "?tab=data",
                    q.query(drop_filter=i),
                    "#rows",
                )
            )
            h.raw('" aria-label="Remove this filter">×</a></li>')
        h.raw("</ul>")
    h.raw('<form class="filters" method="get" action="')
    h.text(dataset_href(name))
    h.raw('#rows" aria-label="Filter rows">')
    _keep(h, q, True, True, False, True)
    h.raw('<label>column <select name="fc"><option value=""></option>')
    for c in cols:
        h.raw('<option value="')
        h.text(c)
        h.raw('">')
        h.text(c)
        h.raw("</option>")
    h.raw('</select></label><label>is <select name="fo">')
    for o in materialize[_OP_NAMES]():
        h.raw('<option value="', o[0], '">', o[1], "</option>")
    h.raw(
        '</select></label><label>value <input name="fv" size="12"',
        ' placeholder="a, or a,b for in"></label>',
    )
    var shown = q.columns.copy() if len(q.columns) else cols.copy()
    h.raw(
        (
            '<details class="pick"><summary><span'
            ' class="pick__name">columns</span>'
        ),
        ' <span class="pick__value">',
    )
    h.text(String(len(shown)) if len(q.columns) else String("all"))
    h.raw('</span></summary><div class="pick__menu">')
    for c in cols:
        h.raw(
            '<label class="pick__item"><input type="checkbox" name="c" value="'
        )
        h.text(c)
        h.raw(
            '"', " checked" if len(q.columns) and c in q.columns else "", "> "
        )
        h.text(c)
        h.raw("</label>")
    h.raw(
        '</div></details><label>sort <select name="sort"><option value="">table'
        " order</option>"
    )
    for c in cols:
        for d in [("", " ↑"), ("-", " ↓")]:
            var key = String(d[0], c)
            h.raw('<option value="')
            h.text(key)
            h.raw('"', " selected" if q.sort == key else "", ">")
            h.text(c, d[1])
            h.raw("</option>")
    h.raw('</select></label><button type="submit">Apply</button></form>')
    var rows = v.try_at("/rows")
    if not rows:
        h.raw("</section>")
        return
    ref r = rows.value()
    rows_table(h, r, len(q.filters) > 0)
    var list = r.at("/rows").array_items()
    var offset = Int(r.at("/offset").int_value())
    var next = r.at("/next")
    h.raw('<nav class="pager" aria-label="Pages of rows">')
    if offset > 0:
        pager_link(h, "", String(_href(name, q), "#rows"), "« First")
        pager_link(
            h,
            "prev",
            String(_href(name, q, max(0, offset - q.n)), "#rows"),
            "← Previous",
        )
    h.raw('<span class="pager__at">')
    if len(list):
        h.raw("rows ", grouped(offset + 1), "–", grouped(offset + len(list)))
    h.raw(" · ", grouped(Int(r.at("/files").int_value())), " files planned · ")
    h.raw(grouped(Int(r.at("/scanned").int_value())), " rows read</span>")
    if not next.is_null():
        pager_link(
            h,
            "next",
            String(_href(name, q, Int(next.int_value())), "#rows"),
            "Next →",
        )
    h.raw('<a href="')
    h.text(
        String(dataset_href(name), "/data.csv?", _qs(q.query(with_chart=False)))
    )
    h.raw(
        '" download>Download CSV</a><span class="muted">(up to ',
        grouped(limits.download_rows),
        " rows)</span>",
    )
    h.raw('<a href="')
    h.text(String(dataset_href(name), "/data.json?", _qs(q.query(offset))))
    h.raw('">JSON</a></nav></section>')


def rows_table(mut h: Html, r: Value, filtered: Bool) raises:
    """A read's `rows`: why it stopped, if it did, and the table of them
    (or that there are none), each column titled with its type."""
    var stopped = r.at("/stopped")
    if stopped.is_string():
        h.raw('<p class="card__warn">')
        h.text("Stopped: ", stopped.string_value(), ".")
        h.raw("</p>")
    var names = _names(r, "/columns")
    var list = r.at("/rows").array_items()
    if len(list) == 0:
        h.raw('<p class="card__none">No rows')
        h.raw(" match the filters." if filtered else ".")
        h.raw("</p>")
    else:
        h.raw('<div class="scroll"><table><thead><tr>')
        var types = List[String]()
        for c in r.at("/columns").array_items():
            types.append(c.at("/type").string_value())
        for k in range(len(names)):
            h.raw("<th")
            var num = types[k] in ["int", "long", "float", "double"] or types[
                k
            ].startswith("decimal")
            if num:
                h.raw(' class="num"')
            h.raw(' title="')
            h.text(types[k])
            h.raw('">')
            h.text(names[k])
            h.raw("</th>")
        h.raw("</tr></thead><tbody>")
        for row in list:
            h.raw("<tr>")
            var cells = row.array_items()
            for k in range(len(cells)):
                ref c = cells[k]
                if c.is_null():
                    h.raw('<td class="null">null</td>')
                elif c.is_number():
                    h.num(c.to_json())
                else:
                    h.mono(_text_of(c))
            h.raw("</tr>")
        h.raw("</tbody></table></div>")


def _chart_card(mut h: Html, name: String, q: DataQuery, v: Value) raises:
    var cols = List[String]()
    var numeric = List[String]()
    for c in v.at("/schema/columns").array_items():
        var n = c.at("/name").string_value()
        var t = c.at("/type").string_value()
        cols.append(n)
        if t in ["int", "long", "float", "double"] or t.startswith("decimal"):
            numeric.append(n)
    h.raw('<section class="card data__chart" id="chart"><h2>Chart')
    help_tip(h, "card-chart", "Chart", _CHART_HELP, "ui")
    h.raw('</h2><form class="filters" method="get" action="')
    h.text(dataset_href(name))
    h.raw('#chart" aria-label="Chart">')
    _keep(h, q, True, True, True, False)
    h.raw('<label>x <select name="x"><option value=""></option>')
    for c in cols:
        h.raw('<option value="')
        h.text(c)
        h.raw('"', " selected" if c == q.x else "", ">")
        h.text(c)
        h.raw("</option>")
    h.raw("</select></label>")
    for k in range(3):
        h.raw("<label>y", k + 1, ' <select name="y"><option value=""></option>')
        for c in numeric:
            h.raw('<option value="')
            h.text(c)
            h.raw('"', " selected" if k < len(q.y) and q.y[k] == c else "", ">")
            h.text(c)
            h.raw("</option>")
        h.raw("</select></label>")
    h.raw('<label>of each x <select name="agg">')
    for a in ["avg", "sum"]:
        h.raw(
            '<option value="',
            a,
            '"',
            " selected" if q.agg == a else "",
            ">",
            "average" if a == "avg" else "sum",
            "</option>",
        )
    h.raw('</select></label><label>as <select name="chart">')
    for a in ["line", "bar"]:
        h.raw(
            '<option value="',
            a,
            '"',
            " selected" if q.chart == a else "",
            ">",
            a,
            "</option>",
        )
    h.raw('</select></label><button type="submit">Draw</button></form>')
    var got = v.try_at("/chart")
    if not got:
        h.raw(
            '<p class="card__sub">Pick an x and up to three numbers to chart'
            " the filtered rows.</p></section>"
        )
        return
    ref c = got.value()
    var err = c.try_at("/error")
    if err:
        h.raw('<p class="card__warn">')
        h.text(err.value().string_value())
        h.raw("</p></section>")
        return
    var ys = List[String]()
    for y in c.at("/y").array_items():
        ys.append(y.string_value())
    var numeric_x = c.at("/numeric_x").bool_value()
    var points = List[Point]()
    var list = c.at("/points").array_items()
    for i in range(len(list)):
        ref p = list[i]
        var xv = p.at("/x")
        var vals = List[Optional[Float64]]()
        for y in p.at("/y").array_items():
            if y.is_null():
                vals.append(None)
            else:
                vals.append(y.float_or(0))
        points.append(
            Point(
                _text_of(xv),
                xv.float_or(Float64(i)) if numeric_x else Float64(i),
                vals^,
            )
        )
    var stopped = c.at("/stopped")
    if stopped.is_string():
        h.raw('<p class="card__warn">')
        h.text("Stopped: ", stopped.string_value(), ".")
        h.raw("</p>")
    if len(points) == 0:
        h.raw('<p class="card__none">No rows to chart.</p></section>')
        return
    h.raw('<p class="muted mx__legend">')
    for k in range(len(ys)):
        h.raw('<span class="dc__key dc__key--', k, '"></span>')
        h.text(ys[k])
    h.raw(" by ")
    h.text(c.at("/x").string_value())
    h.raw(
        ", ",
        "averaged" if q.agg == "avg" else "summed",
        " over ",
        grouped(Int(c.at("/scanned").int_value())),
        " rows</p>",
    )
    var label = String(", ".join(ys), " by ", c.at("/x").string_value())
    h.raw(
        '<div class="scroll">',
        chart_svg(points, ys, q.chart == "bar", label),
        "</div></section>",
    )
