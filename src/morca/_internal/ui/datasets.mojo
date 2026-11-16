"""`/datasets`, the datasets and the graph of pipelines and datasets;
`/datasets/<name>`, a dataset's writers, readers, snapshots and what a
rebuild of it runs; `/datasets/<name>/snapshots/<id>`, a snapshot's
lineage (`morca._internal.lineage`); `/rebuilds/<id>`, a rebuild's runs by level.
"""

import morca._internal.db.datasets_view as datasets_db

from morca._internal.api.datasets import json_made, json_rebuild
from morca._internal.api.pipelines import json_strings
from morca._internal.graph import Edge, Node, graph_svg
from morca._internal.html import Html, query_param, url_encode
from morca._internal.json import quote
from morca._internal.lineage import (
    back,
    commits,
    datasets as dataset_rows,
    flows,
    forward,
    latest as latest_snapshot,
)
from morca._internal.db.lineage import Commit, Made, SnapshotCursor, SnapshotRef
from morca._internal.sensors import Link, downstream, rebuilds
from morca._internal.db.rebuilds import Rebuild
from morca._internal.state import State
from morca._internal.ui.layout import (
    HERE_SLOT,
    ask_attrs,
    card_open,
    cmd_box,
    docs_link,
    help_tip,
    page_html,
)
from morca._internal.ui.errors import not_found
from morca._internal.dataset_config import private_datasets
from morca._internal.ui.parts import code_link, data_link
from morca._internal.ui.runs import pager_link
from morca._internal.views.code import CodeLinks, code_of
from morca._internal.views.commands import rebuild_cmd, remote_cmd
from morca._internal.views.datasets import (
    RebuildPreview,
    SNAPSHOTS_PAGE,
    dataset_steps,
    rebuild_preview,
    steps_using,
)
from morca._internal.web.page import Page


def dataset_href(name: String) -> String:
    return String("/datasets/", url_encode(name))


def snapshot_href(at: SnapshotRef) -> String:
    return String(dataset_href(at.dataset), "/snapshots/", at.snapshot)


def dataset_tabs(mut h: Html, name: String, tab: String):
    """A dataset page's tabs: Overview (its place in the graph, rebuilds and
    snapshots) and Data (`morca._internal.ui.data`), each a link."""
    var base = dataset_href(name)
    h.raw('<nav class="ptabs" aria-label="Dataset sections">')
    for t in [("overview", "Overview"), ("data", "Data")]:
        h.raw('<a class="ptabs__tab" href="')
        h.text(base if t[0] == "overview" else String(base, "?tab=", t[0]))
        h.raw('"', ' aria-current="page"' if t[0] == tab else "", ">")
        h.raw(t[1], "</a>")
    h.raw("</nav>")


def _flow_graph(mut db: State, mark: String) raises -> String:
    """The graph of every pipeline and the datasets it reads and writes,
    with the dataset `mark` (if any) marked."""
    var fs = flows(db)
    var nodes = List[Node]()
    var keys = List[String]()
    var edges = List[Edge]()
    for f in fs:
        var ends = List[Int]()
        for kind, name in [("pipeline", f.pipeline), ("dataset", f.dataset)]:
            var key = String(kind, ":", name)
            var at = -1
            for i in range(len(keys)):
                if keys[i] == key:
                    at = i
            if at < 0:
                at = len(nodes)
                keys.append(key)
                var is_pipeline = kind == "pipeline"
                nodes.append(
                    Node(
                        name,
                        String(kind),
                        String(kind),
                        String(
                            "/pipelines/", url_encode(name)
                        ) if is_pipeline else dataset_href(name),
                        "start" if (not is_pipeline and name == mark) else "",
                    )
                )
            ends.append(at)
        if f.writes:
            edges.append(Edge(ends[0], ends[1]))
        else:
            edges.append(Edge(ends[1], ends[0]))
    if len(nodes) == 0:
        return String()
    return graph_svg(
        nodes, edges, "Pipelines and the datasets they read and write"
    )


def datasets_page(mut db: State) raises -> Page:
    var ds = dataset_rows(db)
    var j = String('{"datasets": [')
    for i in range(len(ds)):
        ref d = ds[i]
        j.write(", " if i else "", '{"name": ', quote(d.name), ', "writers": ')
        json_strings(j, d.writers)
        j.write(', "readers": ')
        json_strings(j, d.readers)
        j.write(
            ', "snapshots": ',
            d.commits,
            ', "latest": ',
            String(d.latest) if d.latest >= 0 else String("null"),
            ', "latest_run": ',
            d.latest_run,
            "}",
        )
    j.write("]}")

    var h = Html()
    h.raw("<h1>Datasets</h1>")
    if len(ds) == 0:
        h.raw(
            '<p class="empty">No datasets: no registered pipeline declares',
            " <code>reads=</code> or <code>writes=</code>.</p>",
        )
        return Page(200, j^, page_html("Datasets", "/datasets", h))
    h.raw('<div class="scroll">', _flow_graph(db, ""), "</div>")
    h.raw(
        '<div class="scroll"><table><thead><tr><th>Dataset</th>',
        "<th>Data</th>",
        '<th>Written by</th><th>Read by</th><th class="num">Snapshots</th>',
        "<th>Latest</th><th>By run</th></tr></thead><tbody>",
    )
    var private = private_datasets(db)
    for d in ds:
        h.raw("<tr><td>")
        h.link(dataset_href(d.name), d.name)
        h.raw("</td><td>")
        data_link(h, d.name, private)
        h.raw('</td><td class="names">')
        _pipeline_links(h, d.writers)
        h.raw('</td><td class="names">')
        _pipeline_links(h, d.readers)
        h.raw("</td>")
        h.num(d.commits)
        h.raw("<td>")
        if d.latest >= 0:
            h.link(
                snapshot_href(SnapshotRef(d.name, d.latest)), String(d.latest)
            )
        h.raw("</td><td>")
        if d.latest_run:
            h.chip(String("/runs/", d.latest_run), String(d.latest_run))
        h.raw("</td></tr>")
    h.raw("</tbody></table></div>")
    return Page(200, j^, page_html("Datasets", "/datasets", h))


def _pipeline_links(mut h: Html, names: List[String]):
    for i in range(len(names)):
        if i:
            h.raw(", ")
        h.link(String("/pipelines/", url_encode(names[i])), names[i])


def _rebuild_html(
    mut h: Html,
    dataset: String,
    chain: List[Link],
    keys: String,
    preview: Optional[RebuildPreview],
):
    """The dataset page's Rebuild section: what it does, the chain of
    pipelines it runs, a preview over a range, the button and the same from
    the command line."""
    h.raw("<h2>Rebuild", docs_link("sensors"), "</h2>")
    h.raw(
        "<p>Rebuild reruns everything downstream of this dataset for the",
        " partitions you give, in dependency order. Use it after this",
        " dataset's data was fixed or reloaded, so the tables built from it",
        " catch up.</p>",
    )
    if len(chain) == 0:
        h.raw('<p class="empty">Nothing reads this dataset.</p>')
        return
    h.raw('<ol class="chain" aria-label="What a rebuild runs, in order">')
    var at = -1
    for i in range(len(chain)):
        ref c = chain[i]
        if c.level != at:
            if at >= 0:
                h.raw("</li>")
            at = c.level
            h.raw('<li class="chain__level">')
        else:
            h.raw('<span class="chain__and"> and </span>')
        h.raw('<span class="chain__step">')
        h.link(String("/pipelines/", url_encode(c.pipeline)), c.pipeline)
        h.raw(' <span class="muted">(reads ')
        for k in range(len(c.reads)):
            if k:
                h.raw(", ")
            h.raw("<code>")
            h.text(c.reads[k])
            h.raw("</code>")
        h.raw(")</span></span>")
    h.raw("</li></ol>")
    var href = dataset_href(dataset)
    h.raw('<form class="start" id="rebuild" method="post" action="', href)
    h.raw('/rebuild"')
    ask_attrs(
        h,
        String("Rebuild what reads ", dataset, " over {partitions}?"),
        (
            "This plans a run of each pipeline above over those partitions;"
            " each level is queued once the one before it has succeeded."
        ),
        "Rebuild downstream",
        danger=False,
    )
    h.raw('><label class="start__range">')
    h.raw('Partitions <input name="partitions" required')
    h.raw(' placeholder="2024-01..2024-03" value="')
    h.text(keys)
    h.raw('"></label><div class="start__choices"><div class="start__choice">')
    h.raw('<button type="submit" class="primary act__need" title="')
    h.text(rebuild_cmd(dataset, keys))
    h.raw('">Rebuild downstream</button><a class="act__login" href="/login')
    h.raw("?next=", HERE_SLOT, '">Log in to rebuild</a><p class="muted">')
    h.raw("Plans a run of each")
    h.raw(" pipeline above over those partitions; each level is queued once")
    h.raw(" the one before it has succeeded.</p></div></div>")
    h.raw('<button type="submit" formmethod="get" formaction="', href)
    h.raw('#rebuild" formnovalidate name="preview" value="1">Preview</button>')
    h.raw('<div class="start__preview">')
    if preview:
        ref v = preview.value()
        if v.refused:
            h.raw('<p class="refused">')
            h.text(v.refused)
            h.raw("</p>")
        else:
            var runs = 0
            for l in v.levels:
                runs += len(l)
            h.raw('<p data-preview="rebuild">')
            h.text(
                "This queues ",
                runs,
                " run" if runs == 1 else " runs",
                " in ",
                len(v.levels),
                " level" if len(v.levels) == 1 else " levels",
                ", over ",
                len(v.partitions),
                " partition" if len(v.partitions) == 1 else " partitions",
                ":",
            )
            h.raw("</p><ol>")
            for l in range(len(v.levels)):
                h.raw("<li>")
                h.text(
                    len(v.levels[l]),
                    " run: " if len(v.levels[l]) == 1 else " runs: ",
                )
                for k in range(len(v.levels[l])):
                    if k:
                        h.raw(", ")
                    h.text(v.levels[l][k][0], " over ", v.levels[l][k][1])
                h.raw("</li>")
            h.raw("</ol>")
    h.raw('</div><p class="muted start__cli">From the command line:</p>')
    cmd_box(h, "rebuild", remote_cmd(rebuild_cmd(dataset, keys)))
    h.raw("</form>")


def dataset_page(
    mut db: State,
    name: String,
    keys: String = "",
    preview: Bool = False,
    url: String = "",
) raises -> Page:
    """A dataset's page; with `preview` and `keys`, what a rebuild over them
    would queue (`?preview=1&partitions=...`). Its snapshots are paged
    newest first by `url`'s `?before=` or `?after=` (`SnapshotCursor`)."""
    var ds = dataset_rows(db, name)
    if len(ds) == 0:
        return not_found(String("no dataset ", name))
    ref d = ds[0]
    var page = SNAPSHOTS_PAGE
    var before = SnapshotCursor.parse(query_param(url, "before"))
    var after = SnapshotCursor(0, 0)
    if not before.attempt:
        after = SnapshotCursor.parse(query_param(url, "after"))
    var cs = List[Commit]()
    var newer = before.attempt > 0
    var older = False
    if after.attempt:
        cs = commits(db, name, page + 1, after=after)
        if len(cs) > page:
            _ = cs.pop()
            cs.reverse()
            newer = True
            older = True
        else:
            after = SnapshotCursor(0, 0)
    if not after.attempt:
        cs = commits(db, name, page + 1, before=before)
        older = len(cs) > page
        if older:
            _ = cs.pop()
    var base = String("/datasets/", url_encode(name))
    var newer_href = String()
    var older_href = String()
    if newer and len(cs) > 0:
        newer_href = String(base, "?after=", cs[0].cursor())
    elif newer:
        newer_href = base.copy()
    if older:
        older_href = String(base, "?before=", cs[len(cs) - 1].cursor())
    var rbs = rebuilds(db, dataset=name, limit=10)
    var chain = downstream(db, name)
    var rp = Optional[RebuildPreview](None)
    if preview and keys.strip() and len(chain) > 0:
        rp = rebuild_preview(db, name, keys)
    var j = String('{"dataset": ', quote(d.name), ', "latest": ')
    var newest = latest_snapshot(db, name)
    j.write(String(newest) if newest >= 0 else String("null"), ', "writers": ')
    json_strings(j, d.writers)
    j.write(', "readers": ')
    json_strings(j, d.readers)
    j.write(', "downstream": [')
    for i in range(len(chain)):
        j.write(
            ", " if i else "",
            '{"pipeline": ',
            quote(chain[i].pipeline),
            ', "level": ',
            chain[i].level,
            ', "reads": ',
        )
        json_strings(j, chain[i].reads)
        j.write("}")
    j.write("]")
    if rp:
        ref v = rp.value()
        j.write(
            ', "preview": {"partitions": ',
            quote(keys),
            ', "refused": ',
            quote(v.refused) if v.refused else String("null"),
            ', "levels": [',
        )
        for l in range(len(v.levels)):
            j.write(", " if l else "", "[")
            for k in range(len(v.levels[l])):
                j.write(
                    ", " if k else "",
                    '{"pipeline": ',
                    quote(v.levels[l][k][0]),
                    ', "partitions": ',
                    quote(v.levels[l][k][1]),
                    "}",
                )
            j.write("]")
        j.write('], "command": ', quote(rebuild_cmd(name, keys)), "}")
    j.write(', "rebuilds": [')
    for i in range(len(rbs)):
        if i:
            j.write(", ")
        json_rebuild(j, rbs[i])
    j.write('], "snapshots": [')
    for i in range(len(cs)):
        ref c = cs[i]
        j.write(
            ", " if i else "",
            '{"snapshot": ',
            c.snapshot,
            ', "pipeline": ',
            quote(c.pipeline),
            ', "run": ',
            c.run,
            ', "step": ',
            quote(c.step),
            ', "partition": ',
            quote(c.partition),
            ', "ended": ',
            quote(c.ended),
            "}",
        )
    j.write(
        '], "snapshots_page": {"n": ',
        page,
        ', "before": ',
        quote(String(before)) if before.attempt else String("null"),
        ', "after": ',
        quote(String(after)) if after.attempt else String("null"),
        ', "next": ',
        quote(String(cs[len(cs) - 1].cursor())) if older else String("null"),
        ', "prev": ',
        quote(String(cs[0].cursor())) if newer
        and len(cs) > 0 else String("null"),
        ', "next_url": ',
        quote(older_href) if older_href else String("null"),
        ', "prev_url": ',
        quote(newer_href) if newer_href else String("null"),
        "}}",
    )

    var h = Html()
    h.raw('<p class="crumb"><a href="/datasets">Datasets</a></p><h1>')
    h.text(d.name)
    var cache = Dict[String, CodeLinks]()
    h.raw("</h1>")
    dataset_tabs(h, d.name, "overview")
    h.raw('<dl class="facts"><dt>Written by</dt><dd>')
    steps_using(h, db, cache, dataset_steps(db, name, writes=True))
    h.raw("</dd><dt>Read by</dt><dd>")
    steps_using(h, db, cache, dataset_steps(db, name, writes=False))
    h.raw("</dd></dl>")
    h.raw('<div class="scroll">', _flow_graph(db, d.name), "</div>")
    _rebuild_html(h, d.name, chain, keys, rp)
    if len(rbs) > 0:
        h.raw("<h2>Rebuilds", docs_link("sensors"), "</h2>")
        _rebuilds_table(h, rbs)
    h.raw("<h2>Snapshots", docs_link("datasets"), "</h2>")
    if len(cs) == 0:
        h.raw('<p class="empty">No morca run has committed to it.</p>')
    else:
        h.raw(
            '<div class="scroll"><table><thead><tr><th>Snapshot</th>',
            "<th>Pipeline</th><th>Run</th><th>Step</th><th>Partition</th>",
            "<th>Committed</th></tr></thead><tbody>",
        )
        for c in cs:
            h.raw("<tr><td>")
            h.link(
                snapshot_href(SnapshotRef(d.name, c.snapshot)),
                String(c.snapshot),
            )
            h.raw("</td><td>")
            h.link(String("/pipelines/", url_encode(c.pipeline)), c.pipeline)
            h.raw("</td><td>")
            h.chip(String("/runs/", c.run), String(c.run))
            h.raw("</td><td>")
            h.text(c.step)
            var at = code_of(db, cache, c.pipeline, c.run).step(c.step)
            if at:
                h.raw(" ")
                code_link(h, at)
            h.raw("</td>")
            h.mono(c.partition)
            h.mono(c.ended)
            h.raw("</tr>")
        h.raw("</tbody></table></div>")
    if newer_href or older_href:
        h.raw('<nav class="pager" aria-label="Pages of snapshots">')
        if newer_href:
            pager_link(h, "", base, "« Newest")
            pager_link(h, "prev", newer_href, "← Newer")
        h.raw('<span class="pager__at">', len(cs), " shown</span>")
        if older_href:
            pager_link(h, "next", older_href, "Older →")
        h.raw("</nav>")
    return Page(200, j^, page_html(d.name, "/datasets", h))


def _rebuilds_table(mut h: Html, rbs: List[Rebuild]):
    h.raw(
        '<div class="scroll"><table><thead><tr><th>Rebuild</th>',
        "<th>Partitions</th><th>Status</th><th>Pipelines</th>",
        "<th>Created</th></tr></thead><tbody>",
    )
    for r in rbs:
        h.raw("<tr><td>")
        h.chip(String("/rebuilds/", r.id), String(r.id))
        h.raw("</td>")
        h.mono(r.partitions)
        h.raw("<td>")
        h.status(r.status)
        h.raw('</td><td class="names">')
        for i in range(len(r.plan)):
            if i:
                h.raw(", ")
            h.link(
                String("/pipelines/", url_encode(r.plan[i].pipeline)),
                r.plan[i].pipeline,
            )
        h.raw("</td>")
        h.mono(r.created)
        h.raw("</tr>")
    h.raw("</tbody></table></div>")


def rebuild_page(mut db: State, id: Int) raises -> Page:
    var rbs = rebuilds(db, id=id)
    if len(rbs) == 0:
        return not_found(String("no rebuild ", id))
    ref r = rbs[0]
    var j = String('{"rebuild": ')
    json_rebuild(j, r)
    j.write("}")

    var h = Html()
    h.raw('<p class="crumb"><a href="/datasets">Datasets</a> · ')
    h.link(dataset_href(r.dataset), r.dataset)
    h.raw("</p><h1>Rebuild ")
    h.text(r.id)
    h.raw(" ")
    h.status(r.status)
    h.raw('</h1><dl class="facts"><dt>Downstream of</dt><dd>')
    h.link(dataset_href(r.dataset), r.dataset)
    h.raw("</dd><dt>Partitions</dt><dd>")
    h.text(r.partitions)
    h.raw("</dd><dt>Created</dt><dd>")
    h.text(r.created)
    h.raw("</dd><dt>Ended</dt><dd>")
    h.text(r.ended)
    h.raw(
        '</dd></dl><p class="muted">Each level runs once every run before it',
        " has succeeded. A run that fails stops the rebuild; resuming it",
        " carries on.</p>",
    )
    h.raw(
        '<div class="scroll"><table><thead><tr><th>Level</th>',
        "<th>Pipeline</th><th>Partitions</th><th>Run</th><th>Status</th>",
        "</tr></thead><tbody>",
    )
    for p in r.plan:
        h.raw("<tr>")
        h.cell(p.level)
        h.raw("<td>")
        h.link(String("/pipelines/", url_encode(p.pipeline)), p.pipeline)
        h.raw("</td>")
        h.mono(p.partitions)
        h.raw("<td>")
        if p.run:
            h.chip(String("/runs/", p.run), String(p.run))
        h.raw("</td><td>")
        if p.status:
            h.status(p.status)
        else:
            h.raw('<span class="muted">waiting</span>')
        h.raw("</td></tr>")
    h.raw("</tbody></table></div>")
    return Page(200, j^, page_html(String("Rebuild ", r.id), "/datasets", h))


def _made_table(mut h: Html, ms: List[Made]):
    h.raw(
        '<div class="scroll"><table><thead><tr><th>Snapshot</th>',
        "<th>Written by</th><th>Run</th><th>Step</th><th>Partition</th>",
        "<th>Code</th><th>Committed</th><th>Read</th></tr></thead><tbody>",
    )
    for m in ms:
        h.raw("<tr><td>")
        h.link(snapshot_href(m.at), String(m.at))
        h.raw("</td><td>")
        h.link(String("/pipelines/", url_encode(m.pipeline)), m.pipeline)
        h.raw("</td><td>")
        h.link(String("/runs/", m.run), String(m.run))
        h.raw("</td>")
        h.cell(m.step)
        h.cell(m.partition)
        h.raw("<td><code>")
        h.text(m.code)
        h.raw("</code></td>")
        h.cell(m.ended)
        h.raw('<td class="names">')
        for k in range(len(m.inputs)):
            if k:
                h.raw(", ")
            h.link(snapshot_href(m.inputs[k]), String(m.inputs[k]))
        h.raw("</td></tr>")
    h.raw("</tbody></table></div>")


def _index_of(refs: List[SnapshotRef], at: SnapshotRef) -> Int:
    for i in range(len(refs)):
        if refs[i] == at:
            return i
    return -1


def _lineage_graph(start: SnapshotRef, b: List[Made], f: List[Made]) -> String:
    """The snapshots of both walks, each from the inputs it was made of."""
    var nodes = List[Node]()
    var refs = List[SnapshotRef]()
    var edges = List[Edge]()

    var all = List[Made]()
    for m in b:
        all.append(m.copy())
    for m in f:
        all.append(m.copy())
    # Inputs nobody here made first, then the made, back to front. An input
    # upstream that no morca run made is a source (the back walk would have
    # it otherwise); one only a downstream step read is another input of
    # that step, whose own lineage isn't drawn.
    for k in range(len(all)):
        var inputs = all[k].inputs.copy()
        for i in inputs:
            var made = False
            for o in all:
                made = made or o.at == i
            if not made and _index_of(refs, i) < 0:
                var source = k < len(b)
                refs.append(i.copy())
                nodes.append(
                    Node(
                        i.dataset,
                        "source" if source else "also read",
                        "snapshot",
                        snapshot_href(i),
                        "start" if i
                        == start else ("source" if source else "other"),
                        String(
                            i,
                            ": a source, written by no morca run" if source else (
                                ": also read by a step downstream; open it"
                                " for its own lineage"
                            ),
                        ),
                    )
                )
    if _index_of(refs, start) < 0:
        var made_here = False
        for m in all:
            made_here = made_here or m.at == start
        if not made_here:
            refs.append(start.copy())
            nodes.append(
                Node(
                    start.dataset,
                    "source",
                    "snapshot",
                    snapshot_href(start),
                    "start",
                    String(start, ": a source, written by no morca run"),
                )
            )
    for m in all:
        if _index_of(refs, m.at) >= 0:
            continue
        refs.append(m.at.copy())
        var sub = String(m.pipeline)
        if m.partition:
            sub.write(" ", m.partition)
        var title = String(
            m.at, ": written by ", m.pipeline, " run ", m.run, ", step ", m.step
        )
        if m.partition:
            title.write(" ", m.partition)
        nodes.append(
            Node(
                m.at.dataset,
                sub,
                "snapshot",
                snapshot_href(m.at),
                "start" if m.at == start else "",
                title,
            )
        )
    for m in all:
        var dst = _index_of(refs, m.at)
        for i in m.inputs:
            var src = _index_of(refs, i)
            if src >= 0 and dst >= 0:
                var dup = False
                for e in edges:
                    dup = dup or (e.src == src and e.dst == dst)
                if not dup:
                    edges.append(Edge(src, dst))
    return graph_svg(nodes, edges, String("The lineage of ", start))


comptime _LINEAGE_HELP = (
    "Each box is a snapshot of a dataset, an arrow a step that read the"
    " snapshot it starts at and wrote the one it points to, so data flows"
    " down: what this snapshot was written from is above it, what was"
    " written from it below, up to 20 steps away. A box's"
    " second line is the pipeline and partition that wrote it; hover for"
    " the run and step, click to open that snapshot's lineage."
)


comptime _UPSTREAM_HELP = (
    "This snapshot, if a morca run wrote it, and every snapshot it was"
    " written from, directly or not: for each, the run and step that wrote"
    " it and the snapshots that step read. A source, written by something"
    " other than morca, is only in the Read column. back in the JSON."
)


comptime _DOWNSTREAM_HELP = (
    "Every snapshot a step wrote after reading this one, then what steps"
    " wrote after reading those, and so on: what a change to it reaches."
    " forward in the JSON."
)


def snapshot_page(mut db: State, name: String, id: Int64) raises -> Page:
    var start = SnapshotRef(name, id)
    if not datasets_db.snapshot_known(db.conn, name, id):
        return not_found(String("no snapshot ", start, " that morca knows of"))
    var b = back(db, start)
    var f = forward(db, start)
    var j = String(
        '{"dataset": ', quote(name), ', "snapshot": ', id, ', "back": '
    )
    json_made(j, b)
    j.write(', "forward": ')
    json_made(j, f)
    j.write("}")

    var h = Html()
    h.raw('<p class="crumb"><a href="/datasets">Datasets</a> · ')
    h.link(dataset_href(name), name)
    h.raw("</p><h1>")
    h.text(name, " @ ", id)
    h.raw("</h1>")
    card_open(h, "lineage", "Lineage", _LINEAGE_HELP, "datasets", facts=False)
    h.raw(
        '<p class="muted graph__legend"><span class="graph__key',
        ' graph__key--start"></span>this snapshot <span class="graph__key">',
        '</span>written by a morca run <span class="graph__key',
        ' graph__key--source"></span>a source, written by something else',
        ' <span class="graph__key graph__key--other"></span>another input of',
        ' a step downstream <span class="graph__arrow">↓</span> read, to',
        " write</p>",
        '<div class="scroll">',
        _lineage_graph(start, b, f),
        "</div></section>",
    )
    h.raw('<h2 id="upstream">Upstream')
    help_tip(h, "upstream", "Upstream", _UPSTREAM_HELP, "datasets")
    h.raw("</h2>")
    if len(b) == 0:
        h.raw(
            '<p class="empty">No morca run wrote this snapshot: it is a'
            " source.</p>"
        )
    else:
        _made_table(h, b)
    h.raw('<h2 id="downstream">Downstream')
    help_tip(h, "downstream", "Downstream", _DOWNSTREAM_HELP, "datasets")
    h.raw("</h2>")
    if len(f) == 0:
        h.raw('<p class="empty">No morca run has read it yet.</p>')
    else:
        _made_table(h, f)
    return Page(200, j^, page_html(String(name, " @ ", id), "/datasets", h))
