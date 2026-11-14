"""A pipeline's Data tab (#479), `/pipelines/<name>?tab=data`: each dataset
its steps write, with the first rows of its current snapshot, read as the
dataset's own Data tab reads them (`morca._internal.ui.data`: the same
`morca_maintain data`, within the same limits), and a link to that tab for
its partitions, filters, sorts, chart and download. A dataset whose data
is hidden from this visitor (`public = false`) says so instead."""

from json import loads

from morca._internal.db.pipelines_view import StepDef
from morca._internal.html import Html
from morca._internal.state import State
from morca._internal.ui.data import data_hidden, rows_table
from morca._internal.ui.datasets import dataset_href
from morca._internal.ui.layout import HERE_SLOT
from morca._internal.ui.runs import grouped
from morca._internal.views.data import (
    DataLimits,
    DataQuery,
    data_argv,
    data_binary,
    read_data,
)

comptime PIPELINE_ROWS = 20
"""Rows shown of each dataset, at most (and no more than
`MORCA_DATA_PAGE_ROWS`); its own Data tab pages through the rest."""


def written_datasets(steps: List[StepDef]) -> List[String]:
    """The datasets the steps write, each once, in the steps' order."""
    var out = List[String]()
    for s in steps:
        for d in s.writes:
            if d not in out:
                out.append(d)
    return out^


def pipeline_data_html(
    mut db: State, mut h: Html, steps: List[StepDef], user: String
) raises:
    """The tab's cards, one a dataset (the module doc)."""
    var names = written_datasets(steps)
    if len(names) == 0:
        h.raw(
            '<p class="card__none">Its steps write no datasets: the data a'
            " pipeline writes shows here.</p>"
        )
        return
    var limits = DataLimits.from_env()
    for i in range(len(names)):
        ref name = names[i]
        var tab = String(dataset_href(name), "?tab=data")
        h.raw('<section class="card pdata" id="data-', i, '"><h2>')
        h.link(dataset_href(name), name)
        h.raw('</h2><p class="card__sub">')
        if data_hidden(db, name, user):
            h.raw(
                'Its data is shown to those logged in. <a href="/login?next=',
                HERE_SLOT,
                '">Log in</a> to see it.</p></section>',
            )
            continue
        var q = DataQuery(String(), limits)
        q.n = min(PIPELINE_ROWS, limits.page_rows)
        var r = read_data(
            data_argv(data_binary(), name, q, limits, partitions=False),
            limits,
        )
        if r.error:
            h.text(r.error)
            h.raw(' <a href="')
            h.text(tab)
            h.raw('">Its Data tab</a></p></section>')
            continue
        var v = loads(r.json)
        var snap = v.at("/snapshot")
        if snap.is_null():
            h.raw("No snapshot yet.</p></section>")
            continue
        var total = v.at("/snapshots")
        var rows = Int(-1)
        if len(total.array_items()) > 0:
            rows = Int(total.array_items()[0].at("/total_records").int_value())
        h.raw("Snapshot ")
        h.text(snap.int_value())
        if rows >= 0:
            h.raw(" · ", grouped(rows), " rows")
        h.raw(
            " · ",
            grouped(Int(v.at("/rows/files").int_value())),
            " files · its first rows below · ",
            '<a class="data-link" href="',
        )
        h.text(tab)
        h.raw('">All its data</a></p>')
        rows_table(h, v.at("/rows"), False)
        h.raw("</section>")
