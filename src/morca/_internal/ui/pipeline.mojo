"""`/pipelines/<name>`, a pipeline's page: Overview (its cards: Progress,
Steps, Code, Resources, Configuration), Runs and Operate (Start runs,
cancel, pause), each a tab of its own; `/progress`, the Progress card as
the fragment it refreshes from; and `/keys/<key>`, one key of a keyed
pipeline in every run it was in.
"""

import morca._internal.db.pipelines_view as pipelines_db

from morca.civil import now
from morca._internal.config_show import config_html
from morca._internal.coverage import Coverage
from morca._internal.dag import DagStep, dag_svg
from morca._internal.fill import FillStatus, eta_text, lag_note, money
from morca._internal.follow import Follow, follow
from morca._internal.html import Html, url_encode
from morca._internal.json import quote
from morca._internal.recommend import Recommendation
from morca._internal.sample import fixed1
from morca._internal.queueing import done_keys
from morca._internal.registered import registered
from morca._internal.source import web_url
from morca._internal.state import State
from morca._internal.ui.coverage import (
    coverage_href,
    coverage_html,
    follow_html,
)
from morca._internal.ui.datasets import dataset_href, snapshot_href
from morca._internal.ui.layout import (
    ask_attrs,
    docs_link,
    fact_item,
    help_tip,
    not_found,
    page_html,
)
from morca._internal.dataset_config import private_datasets
from morca._internal.ui.parts import (
    CPU_HELP,
    PEAK_HELP,
    dataset_links,
    datasets_with_data,
    named_code_link,
    pause_button,
    request_text,
    source_html,
    step_cell,
)
from morca._internal.ui.runs import (
    runs_bulk_html,
    runs_done_html,
    runs_filters_html,
    runs_list,
)
from morca._internal.ui.start import start_html
from morca._internal.ui.step_cards import AttemptCard, cards_script
from morca._internal.ui.terms import COVERAGE_HELP
from morca._internal.usage import bytes_text, cpu_text
from morca._internal.views.code import CodeLinks, code_links
from morca._internal.views.pipelines import (
    Fire,
    KeyCounts,
    PipelineAsk,
    PipelineRow,
    PipelineView,
    StepDef,
    UsageSummary,
    fill_of,
    next_fires,
    pipeline_coverage,
    pipeline_rows,
)
from morca._internal.views.runs import VersionRow
from morca._internal.views.steps import step_cards_of
from morca._internal.web.page import Page
from morca._internal.timekeys import is_time_kind


def _keys_html(mut h: Html, name: String, k: KeyCounts):
    h.raw('<h2 id="keys">Keys', docs_link("partitions"), "</h2>")
    if k.error:
        h.raw('<p class="empty">Its keys can\'t be read: ')
        h.text(k.error)
        h.raw("</p>")
        return
    h.raw('<dl class="facts"><dt>From</dt><dd>')
    h.link(dataset_href(k.dataset), k.dataset)
    h.raw(" @ ")
    h.text(k.snapshot)
    if k.read_at:
        h.raw(' <span class="muted">read ')
        h.text(k.read_at)
        h.raw("</span>")
    if k.note:
        h.raw(' <span class="error">')
        h.text(k.note)
        h.raw("</span>")
    h.raw("</dd><dt>Keys</dt><dd>")
    h.text(k.total)
    h.raw("</dd><dt>Done</dt><dd>")
    h.text(k.done)
    h.raw("</dd><dt>In live runs</dt><dd>")
    h.text(k.live)
    h.raw("</dd><dt>Failed</dt><dd>")
    h.text(len(k.failed))
    h.raw("</dd></dl>")
    if len(k.failed) == 0:
        return
    var base = String("/pipelines/", url_encode(name))
    h.raw('<p class="more">')
    for i in range(min(len(k.failed), 100)):
        if i:
            h.raw(", ")
        h.link(String(base, "/keys/", url_encode(k.failed[i])), k.failed[i])
    if len(k.failed) > 100:
        h.raw(" and ")
        h.text(len(k.failed) - 100)
        h.raw(" more")
    var all = String()
    for i in range(len(k.failed)):
        all.write("," if i else "", k.failed[i])
    h.raw(
        '</p><div class="actions"><form class="action" method="post" action="'
    )
    h.text(base, "/backfill")
    h.raw('"><input type="hidden" name="partitions" value="')
    h.text(all)
    h.raw(
        '"><button type="submit">Backfill the failed keys</button></form></div>'
    )


def _control_html(mut h: Html, p: PipelineRow):
    """The forms that cancel a pipeline's runs in bulk and pause it."""
    var base = String("/pipelines/", url_encode(p.name))
    h.raw(
        "<h2>Stop runs</h2>",
        '<div class="actions"><form class="action" method="post" action="',
    )
    h.text(base, "/cancel")
    h.raw('"')
    ask_attrs(
        h,
        String("Cancel the runs of ", p.name, " over {partitions}?"),
        (
            "Runs that are queued or waiting to be retried are cancelled, and"
            " running ones are asked to stop before their next step. Finished"
            " runs are left as they are."
        ),
        "Cancel runs",
        "Keep them",
    )
    h.raw('><label>Of <input name="partitions" placeholder="')
    h.text("@all, or names" if p.kind == "keyed" else "@all, or a range")
    h.raw(
        '"></label><button type="submit">Cancel queued runs</button></form>',
        '<form class="action" method="post" action="',
    )
    if p.paused:
        h.text(base, "/unpause")
        h.raw('"><button type="submit">Unpause</button></form></div>')
    else:
        h.text(base, "/pause")
        h.raw('"><button type="submit">Pause</button></form></div>')
    h.raw(
        '<p class="muted more">Cancelling stops runs that are queued or',
        " waiting to be retried, and asks running ones to stop before their",
        " next step. ",
    )
    if p.paused:
        h.raw(
            "Paused: the scheduler starts none of its runs; fires, sensors,",
            " retries and backfills queue theirs until it's unpaused.</p>",
        )
    else:
        h.raw(
            "Pausing stops the scheduler starting its runs, which stay",
            " queued; runs already going go on.</p>",
        )


def key_page(mut db: State, name: String, key: String) raises -> Page:
    """One key of a keyed pipeline: its steps in every run it was in."""
    var ps = pipeline_rows(db, name)
    if len(ps) == 0:
        return not_found(String("no pipeline ", name))
    var rows = pipelines_db.key_steps(db.conn, name, key)
    var done = done_keys(db, name, [key])
    var j = String(
        '{"pipeline": ',
        quote(name),
        ', "key": ',
        quote(key),
        ', "done": ',
        "true" if key in done else "false",
        ', "steps": [',
    )
    var h = Html()
    h.raw('<p class="crumb"><a href="/">Pipelines</a> · ')
    h.link(String("/pipelines/", url_encode(name)), name)
    h.raw("</p><h1>")
    h.text(key)
    h.raw(" ")
    h.status("succeeded" if key in done else "not done")
    h.raw("</h1>")
    if len(rows) == 0:
        h.raw('<p class="empty">No run has had this key.</p>')
    else:
        h.raw(
            '<div class="scroll"><table><thead><tr><th>Run</th><th>Step</th>',
            "<th>Status</th><th>Attempts</th><th>Code</th><th>Error</th>",
            "</tr></thead><tbody>",
        )
    var i = 0
    for r in rows:
        j.write(
            ", " if i else "",
            '{"run": ',
            r.run,
            ', "step": ',
            quote(r.step),
            ', "status": ',
            quote(r.status),
            ', "attempts": ',
            r.attempts,
            ', "current_code": ',
            "true" if r.current else "false",
            ', "error": ',
            quote(r.error),
            "}",
        )
        i += 1
        h.raw("<tr><td>")
        h.chip(String("/runs/", r.run), String(r.run))
        h.raw("</td>")
        h.cell(r.step)
        h.raw("<td>")
        h.status(r.status)
        h.raw("</td>")
        h.num(r.attempts)
        h.cell("current" if r.current else "older")
        h.cell(r.error)
        h.raw("</tr>")
    if len(rows) > 0:
        h.raw("</tbody></table></div>")
    j.write("]}")
    return Page(200, j^, page_html(String(name, " · ", key), "/", h))


def _fill_html(mut h: Html, s: FillStatus):
    """The pipeline page's fill line: done of total, what's going, the
    rate and ETA, today's spend against the budget, and why it's idle."""
    var pct = (s.done * 100 // s.total) if s.total > 0 else 100
    h.text(s.done, " / ", s.total, " done (", pct, "%)")
    if s.running > 0:
        h.text(", ", s.running, " fill runs going")
    if s.queued > 0:
        h.text(", ", s.queued, " fill runs queued")
    if s.live > 0:
        h.text(", ", s.live, " in live runs")
    if s.retrying > 0:
        h.text(", ", s.retrying, " waiting for a retry")
    if s.failed > 0:
        h.text(", ", s.failed, " failed")
    if s.rate > 0:
        h.text(
            "; ",
            Float64(Int(s.rate * 10.0 + 0.5)) / 10.0,
            " an hour, ETA ",
            eta_text(s.eta_seconds),
        )
    h.text("; today ")
    if s.spent < 0:
        h.text("unknown")
    else:
        h.text(money(s.spent))
    if s.budget >= 0:
        h.text(" of ", money(s.budget))
    else:
        h.text(", no budget")
    h.raw(' <span class="muted">(estimated)</span>')
    if s.request:
        # morca backfill --as-fill (#465): cancelled with --cancel.
        h.raw("<br>")
        h.text(s.request.value().text())
    if s.idle:
        h.raw('<br><span class="muted">Idle: ')
        h.text(s.idle)
        h.raw("</span>")
    if s.lag_key:
        h.raw('<br><span class="muted">Next: ')
        h.text(lag_note(s))
        h.raw("</span>")


comptime _FILLS_DOCS = (
    "https://github.com/morca-dev/morca/blob/main/docs/morca-toml.md#fills"
)
"""Fills are documented in morca.toml's reference, not on the docs page."""


def _progress_html(
    mut h: Html,
    p: PipelineRow,
    fill: Optional[FillStatus],
    fires: List[Fire],
    cov: Optional[Coverage],
    f: Optional[Follow] = None,
):
    """The Progress card's facts: the runs going, the fill, a failing
    sensor, the next fire, the coverage. Its own fragment too, which the page refreshes
    (`/pipelines/<name>/progress`)."""
    h.raw('<dl class="facts">')
    fact_item(
        h,
        "Runs at once",
        "runs",
        (
            "Runs of this pipeline going now, out of the most the scheduler"
            " starts at once (max_runs); the others wait in the queue. Fill"
            " runs come on top, up to fill_max_runs."
        ),
        "scheduler",
    )
    h.text(p.running, " running of ", p.max_runs, ", ", p.queued, " queued")
    h.raw("</dd>")
    if p.waiting:
        fact_item(
            h,
            "Waiting",
            "waiting",
            (
                "Its next run waits on its host: for room, when what it asks"
                " for at least (cpus, memory_gb in morca.toml) is more than the"
                " running runs weren't granted, less the host's reserve; or"
                " for the host's memory pressure to ease"
                " (MORCA_ADMIT_MEMORY_PRESSURE)."
            ),
            "runners",
        )
        h.raw('<span class="warn">')
        h.text(p.waiting.removeprefix("waiting: "))
        h.raw("</span></dd>")
    if fill:
        fact_item(
            h,
            "Fill",
            "fill",
            (
                'With fills = "all" in morca.toml the scheduler works through'
                " the whole range by itself, one partition per fill run,"
                " within a daily budget and a window. This is how far it got,"
                " how fast, and what it spent today."
            ),
            _FILLS_DOCS,
        )
        _fill_html(h, fill.value())
        h.raw("</dd>")
    if f:
        fact_item(
            h,
            "Following",
            "following",
            (
                "A sensor runs the partitions of the tables it reads as they"
                " get snapshots. This is how many of those partitions it has"
                " done, and the ones it hasn't: going, failed, or not queued"
                " yet (a backfill queues them). They are behind on Coverage."
            ),
            "sensors",
        )
        follow_html(h, p.name, f.value(), p.max_runs)
        h.raw("</dd>")
    if p.sense_error:
        fact_item(
            h,
            "Sensing",
            "sensing",
            (
                "The pipeline's sensor watches its input tables for new"
                " snapshots. It has been failing with this error since the"
                " time shown."
            ),
            "sensors",
        )
        h.raw('<span class="error">Failing since ')
        h.text(p.sense_error_at, ": ", p.sense_error)
        h.raw("</span></dd>")
    if len(fires) > 0:
        fact_item(
            h,
            "Next run",
            "next",
            (
                "When the schedule fires next, in UTC, and the partition that"
                " run fills. Next runs, further down, lists the next five."
            ),
            "partitions",
        )
        h.raw("<code>")
        h.text(fires[0].at)
        h.raw("</code>")
        h.text(", fills ", fires[0].partition)
        h.raw("</dd>")
    _coverage_fact(h, p, cov)
    h.raw("</dl>")


def _coverage_fact(mut h: Html, p: PipelineRow, cov: Optional[Coverage]):
    """The Progress card's Coverage (`morca._internal.coverage`): done of total and
    the percent, linking to the year calendar (a monthly pipeline's year,
    a keyed one's Keys); "—" when there's nothing to count."""
    var dated = is_time_kind(p.kind)
    if not dated and p.kind != "keyed":
        return
    fact_item(h, "Coverage", "coverage", COVERAGE_HELP, "partitions")
    var href = coverage_href(p.name, p.kind)
    if cov:
        h.raw('<a href="')
        h.text(href)
        h.raw('">')
        h.text(cov.value().text())
        h.raw("</a>")
    else:
        h.raw('<span class="muted">—</span>')
        if dated:
            h.raw(' · <a href="')
            h.text(href)
            h.raw('">The calendar</a>')
    h.raw("</dd>")


def pipeline_progress_here(name: String, tab: String) -> String:
    """Where the Progress fragment's "Log in to ..." links come back to: the
    pipeline's page, on `tab` (as the poll URL gives it) if that is one of
    its tabs other than the overview."""
    var base = String("/pipelines/", url_encode(name))
    if tab == "runs" or tab == "operate":
        return String(base, "?tab=", tab)
    return base


def pipeline_progress(mut db: State, name: String) raises -> Page:
    """The Progress card of a pipeline's page, as a fragment."""
    var ps = pipeline_rows(db, name)
    if len(ps) == 0:
        return not_found(String("no pipeline ", name))
    var fires = List[Fire]()
    try:
        fires = next_fires(ps[0], now(), 1)
    except:
        pass
    var h = Html()
    _progress_html(
        h,
        ps[0],
        fill_of(db, name),
        fires,
        pipeline_coverage(db, ps[0]),
        follow(db, name, ps[0].kind, ps[0].start),
    )
    return Page(200, String(), h^.finish(), "text/html; charset=utf-8")


def _config_html(mut h: Html, p: PipelineRow):
    """The Config card's facts: how the pipeline is set up."""
    h.raw('<dl class="facts">')
    fact_item(
        h,
        "Partitions",
        "partitions",
        (
            "How the work is split: each run does some partitions (months,"
            " days, hours or named keys), from the first one on. Backfills"
            " and the coverage calendar count in partitions."
        ),
        "partitions",
    )
    h.text(p.kind, " from ", p.start if p.start else String("the start"))
    h.raw("</dd>")
    fact_item(
        h,
        "Schedule",
        "schedule",
        (
            "The cron line the scheduler fires on, in its time zone, and the"
            " partition each fire runs. None means runs start only from a"
            " sensor, a backfill or a person."
        ),
        "scheduler",
    )
    if p.cron:
        h.raw("<code>")
        h.text(p.cron)
        h.raw("</code> ")
        h.text(p.tz, ", fills the ", p.fills, " partition")
    else:
        h.raw('<span class="muted">none</span>')
    h.raw("</dd>")
    fact_item(
        h,
        "Run retries",
        "retries",
        (
            "How many more times the scheduler starts a run that failed"
            " before leaving it failed for a person. A step's own retries,"
            " inside a run, come first."
        ),
        "failures",
    )
    h.text(p.run_retries)
    h.raw("</dd>")
    fact_item(
        h,
        "Placement",
        "placement",
        (
            "Where its runs go: control is the scheduler's own host, ec2 an"
            " instance launched for the run, worker:&lt;pool&gt; a remote morca"
            " worker of that pool, and default the scheduler's runner"
            " (MORCA_RUNNER)."
        ),
        "runners",
    )
    if p.placement == "control":
        h.term("placement", "control")
        h.raw(' <span class="muted">(on the scheduler\'s host)</span>')
    elif p.placement.startswith("worker:"):
        h.term("placement", p.placement)
        h.raw(' <span class="muted">(its runs wait for a worker of pool ')
        h.text(p.placement.removeprefix("worker:"))
        h.raw(', <a href="/ops/pools?pool=')
        h.text(url_encode(p.placement))
        h.raw('">Pools</a>)</span>')
    elif p.placement:
        h.term("placement", p.placement)
    else:
        h.raw('<span class="muted">default (the scheduler\'s runner)</span>')
    h.raw("</dd>")
    fact_item(
        h,
        "Binary",
        "binary",
        (
            "The program each run starts: the pipeline's Mojo code built into"
            " one executable, as morca register recorded it."
        ),
        "build",
    )
    # A long path breaks after a slash, not inside a name.
    h.raw("<code>")
    var parts = p.binary.split("/")
    for i in range(len(parts)):
        if i:
            h.raw("/<wbr>")
        h.text(parts[i])
    h.raw("</code></dd></dl>")


def _code_card(
    mut h: Html, p: PipelineRow, steps: List[StepDef], links: CodeLinks
):
    """The Code card: the pipeline's declaration, its steps' and its dista
    tasks' functions, each a name linked to its line, then the code's
    hash."""
    var any_step = False
    for s in steps:
        if links.step(s.name):
            any_step = True
    if not links.pipeline and not any_step and len(links.tasks) == 0:
        h.raw(
            '<p class="muted">No links to the code: the registered binary',
            " has no source, or <code>morca locate</code> didn't map it.</p>",
        )
    else:
        h.raw('<dl class="facts">')
        if links.pipeline:
            fact_item(
                h,
                "Pipeline",
                "code-pipeline",
                "Where the pipeline is declared: its Pipeline[...] line.",
                "pipelines",
            )
            named_code_link(h, p.name, links.pipeline)
            h.raw("</dd>")
        if any_step:
            fact_item(
                h,
                "Steps",
                "code-steps",
                (
                    "Each step's function, in the order the steps run. The"
                    " Steps table below has what each reads and writes."
                ),
                "steps",
            )
            var first = True
            for s in steps:
                var at = links.step(s.name)
                if not at:
                    continue
                h.raw("" if first else " · ")
                first = False
                named_code_link(h, s.name, at)
            h.raw("</dd>")
        if len(links.tasks) > 0:
            fact_item(
                h,
                "Tasks",
                "code-tasks",
                "The dista tasks its steps fan out to, each a function.",
                "dista",
            )
            for i in range(len(links.tasks)):
                h.raw(" · " if i else "")
                named_code_link(h, links.tasks[i][0], links.tasks[i][1])
            h.raw("</dd>")
        h.raw("</dl>")
    h.raw('<p class="hash">Code hash <code>')
    h.text(p.registry_hash)
    h.raw("</code>")
    help_tip(
        h,
        "code-hash",
        "Code hash",
        (
            "A hash of what the binary says about itself: its steps,"
            " partitions and schedule. It changes when they do, not on every"
            " build."
        ),
        "versions",
    )
    h.raw("</p>")


def _steps_html(
    mut h: Html,
    name: String,
    steps: List[StepDef],
    links: CodeLinks,
    view: String,
    cards: String,
    private: List[String],
):
    """The Steps card: Graph and Table tabs, links that work without
    scripts (`?steps=`); with them, the choice is kept in `localStorage`.
    Without one, a pipeline of one step shows its table and others their
    graph. `cards` is its steps' cards' `<script>` (`morca._internal.ui.step_cards`).
    """
    var graph = view == "graph" or (view != "table" and len(steps) > 1)
    var base = String("/pipelines/", url_encode(name))
    h.raw(
        '<section class="card steps" id="steps" data-tabs="orca.steps.view"',
        ' data-tabs-param="steps" data-step-cards><div class="steps__head">',
        "<h2>Steps",
        docs_link("steps"),
        '</h2><div class="vtabs"><div role="tablist"',
        ' aria-label="How to show the steps">',
    )
    for v in [("graph", "Graph"), ("table", "Table")]:
        var on = (v[0] == "graph") == graph
        h.raw('<a role="tab" class="vtabs__tab" data-view="', v[0], '" href="')
        h.text(base, "?steps=", v[0], "#steps")
        h.raw(
            '" aria-selected="',
            "true" if on else "false",
            '" aria-controls="steps-',
            v[0],
            '">',
            v[1],
            "</a>",
        )
    var dag = List[DagStep]()
    for d in steps:
        dag.append(DagStep(d.name, d.kind, d.after, "", links.step(d.name).url))
    h.raw(
        '</div></div></div><div id="steps-graph" role="tabpanel"',
        ' class="scroll steps__graph"',
        "" if graph else " hidden",
        ">",
        dag_svg(dag),
        '</div><div id="steps-table" role="tabpanel" class="scroll"',
        " hidden" if graph else "",
        "><table><thead><tr><th>Step</th><th>Kind</th>",
        "<th>After</th><th>Reads</th><th>Writes</th></tr></thead><tbody>",
    )
    for s in steps:
        h.raw("<tr>")
        step_cell(h, s.name, links, 0)
        h.raw("<td>")
        h.term("kind", s.kind)
        h.raw("</td>")
        h.cell(s.after)
        h.raw('<td class="names">')
        datasets_with_data(h, s.reads, private)
        h.raw('</td><td class="names">')
        datasets_with_data(h, s.writes, private)
        h.raw("</td></tr>")
    h.raw("</tbody></table></div>", cards, "</section>")


def pipeline_html(
    mut db: State, v: PipelineView, ask: PipelineAsk
) raises -> String:
    """A pipeline's page, the tab `ask` names (`overview`, `runs` or
    `operate`): the Overview's cards and steps, the Runs tab's page of runs
    and versions, or Operate's coverage, Start runs and controls."""
    ref p = v.pipeline
    var tab = ask.shown_tab()
    var h = Html()
    h.raw('<p class="crumb"><a href="/">Pipelines</a></p><h1>')
    h.text(p.name)
    if p.paused:
        h.raw(" ")
        h.status("paused")
    pause_button(h, p.name, p.paused)
    h.raw("</h1>")
    var links = code_links(
        db,
        p.name,
        v.versions[0].copy() if len(v.versions)
        > 0 else Optional[VersionRow](None),
    )
    var base = String("/pipelines/", url_encode(p.name))
    _tabs_html(h, base, tab)
    var private = private_datasets(db)
    _datasets_line(h, v.steps, private)
    _cards_html(
        h,
        p,
        tab,
        v.fill,
        v.fires,
        v.coverage,
        v.steps,
        links,
        v.usage,
        v.learned,
        v.following,
    )
    if tab == "overview":
        _steps_html(
            h,
            p.name,
            v.steps,
            links,
            ask.steps,
            cards_script(
                step_cards_of(db, p.name, v.steps, links, True),
                List[AttemptCard](),
            ),
            private,
        )
        if v.keys:
            _keys_html(h, p.name, v.keys.value())
        if len(v.not_run) > 0:
            h.raw(
                "<h2>Snapshots not run",
                docs_link("sensors"),
                (
                    '</h2><p class="muted">Seen by its sensor, but holding keys'
                    " that"
                ),
                (
                    " aren't its partitions. A backfill runs what they should"
                    " have."
                ),
                '</p><div class="scroll"><table><thead><tr><th>Snapshot</th>',
                "<th>Seen</th><th>Why</th></tr></thead><tbody>",
            )
            for u in v.not_run:
                h.raw("<tr><td>")
                h.link(snapshot_href(u.snapshot), String(u.snapshot))
                h.raw("</td>")
                h.cell(u.at)
                h.cell(u.error)
                h.raw("</tr>")
            h.raw("</tbody></table></div>")
        if len(v.fires) > 0:
            h.raw(
                "<h2>Next runs",
                docs_link("partitions"),
                '</h2><div class="scroll"><table><thead><tr>',
                (
                    "<th>UTC</th><th>Wall"
                    " clock</th><th>Fills</th></tr></thead><tbody>"
                ),
            )
            for f in v.fires:
                h.raw("<tr>")
                h.mono(f.at)
                h.mono(f.local)
                h.mono(f.partition)
                h.raw("</tr>")
            h.raw("</tbody></table></div>")
        if len(v.configs) > 0:
            var repo = String()
            if len(v.versions) > 0:
                repo = web_url(v.versions[0].source)
            config_html(h, v.configs[0], repo, links.pipeline.url)
    elif tab == "operate":
        if is_time_kind(p.kind):
            coverage_html(
                h, db, p.name, p.kind, p.start, ask.cal, ask.cov, v.following
            )
        if p.binary:
            var regs = registered(db, p.name)
            start_html(
                h,
                p,
                ask.partitions,
                ask.rerun,
                v.start,
                regs[0].keys_per_run if len(regs) > 0 else 1,
            )
        _control_html(h, p)
    else:
        h.raw("<h2>Runs</h2>")
        runs_filters_html(h, db, v.runs)
        runs_done_html(h, ask.url)
        runs_bulk_html(h, v.runs)
        runs_list(h, db, v.runs)
        h.raw('<p class="more"><a href="/runs?pipeline=')
        h.text(url_encode(p.name))
        h.raw('">All its runs</a></p>')
        if len(v.versions) > 0:
            h.raw(
                "<h2>Versions",
                docs_link("build"),
                '</h2><div class="scroll"><table><thead><tr>',
                "<th>Commit</th><th>Image</th><th>Code</th><th>First seen</th>",
                (
                    "<th>Last seen</th><th"
                    ' class="num">Runs</th></tr></thead><tbody>'
                ),
            )
            for ver in v.versions:
                h.raw("<tr><td>")
                source_html(h, ver)
                h.raw("</td>")
                h.mono(ver.image)
                h.raw("<td><code>")
                h.text(ver.registry_hash)
                h.raw("</code></td>")
                h.mono(ver.first_seen)
                h.mono(ver.last_seen)
                h.num(ver.runs)
                h.raw("</tr>")
            h.raw("</tbody></table></div>")
    h.raw("<script>", _TAB_JS, "</script>")
    return page_html(p.name, "/", h)


def _datasets_line(mut h: Html, steps: List[StepDef], private: List[String]):
    """Under the tabs: the datasets the pipeline writes and reads, each
    linked to its page and to its data."""
    var writes = List[String]()
    var reads = List[String]()
    for s in steps:
        for d in s.writes:
            if d not in writes:
                writes.append(d)
    for s in steps:
        for d in s.reads:
            if d not in reads and d not in writes:
                reads.append(d)
    if len(writes) == 0 and len(reads) == 0:
        return
    h.raw('<p class="data-line pipeline__datasets">')
    if len(writes):
        h.raw("Writes ")
        datasets_with_data(h, writes, private)
    if len(reads):
        h.raw("; reads " if len(writes) else "Reads ")
        datasets_with_data(h, reads, private)
    h.raw("</p>")


def _tabs_html(mut h: Html, base: String, tab: String):
    """The pipeline page's tabs, each a link to its own page."""
    h.raw('<nav class="ptabs" aria-label="Pipeline sections">')
    for t in [
        ("overview", "Overview"),
        ("runs", "Runs"),
        ("operate", "Operate"),
    ]:
        h.raw('<a class="ptabs__tab" href="')
        h.text(base if t[0] == "overview" else String(base, "?tab=", t[0]))
        h.raw('"', ' aria-current="page"' if t[0] == tab else "", ">")
        h.raw(t[1], "</a>")
    h.raw("</nav>")


comptime _TAB_JS = """
(() => {
  // An old link to a section that moved to Operate (#coverage, #start,
  // #stop) lands there.
  const moved = ["#coverage", "#start", "#stop"];
  if (moved.includes(location.hash) && !document.querySelector(location.hash)) {
    const q = new URLSearchParams(location.search);
    q.set("tab", "operate");
    location.replace(location.pathname + "?" + q + location.hash);
  }
})();
"""
"""Sends a link to a section of another tab to that tab."""


def _cards_html(
    mut h: Html,
    p: PipelineRow,
    tab: String,
    fill: Optional[FillStatus],
    fires: List[Fire],
    cov: Optional[Coverage],
    steps: List[StepDef],
    links: CodeLinks,
    usage: UsageSummary,
    learned: Optional[Recommendation],
    f: Optional[Follow] = None,
):
    """The pipeline page's cards: what's going on (refreshed while the page
    is open), and on the Overview tab how it's set up, its code and what
    its runs used."""
    var base = String("/pipelines/", url_encode(p.name))
    h.raw(
        '<div class="pcards',
        "" if tab == "overview" else " pcards--one",
        '"><section class="card card--facts" id="progress">',
        '<h2>Progress</h2><div data-poll="',
    )
    # The tab rides along, so the fragment's "Log in to ..." links come back
    # to this page and tab (pipeline_progress_here), not to the fragment.
    h.text(base, "/progress", "" if tab == "overview" else String("?tab=", tab))
    h.raw('" data-poll-every="5">')
    _progress_html(h, p, fill, fires, cov, f)
    h.raw("</div></section>")
    if tab != "overview":
        h.raw("</div>")
        return
    h.raw('<section class="card card--facts" id="config"><h2>Config</h2>')
    _config_html(h, p)
    h.raw('</section><section class="card card--facts" id="code"><h2>Code')
    help_tip(
        h,
        "code",
        "Code",
        (
            "The functions this pipeline is made of, at the commit it's"
            " registered with. Hover a name to see its source; click it to"
            " open the file on its host."
        ),
        "versions",
    )
    h.raw("</h2>")
    _code_card(h, p, steps, links)
    h.raw('</section><section class="card card--facts" id="resources">')
    h.raw("<h2>Resources")
    help_tip(
        h,
        "resources",
        "Resources",
        (
            "What its latest runs used, as the median (p50) and the most of"
            " them: what a run of it needs. A run's peak is its attempts'"
            " largest, its CPU their sum."
        ),
        "runners",
    )
    h.raw("</h2>")
    _usage_card(h, usage)
    # What its runs suggest, once any is measured.
    var learn = Bool(learned) and usage.runs > 0
    if p.cpus or p.memory_gb or learn:
        h.raw('<dl class="facts">')
    if p.cpus or p.memory_gb:
        fact_item(
            h,
            "Requested",
            "usage-request",
            (
                "What it asks for (cpus and memory_gb in morca.toml): its runs"
                " start once the least of it fits on their host, each granted"
                " up to the most. Set it from the peaks above."
            ),
            "runners",
        )
        h.text(request_text(p.cpus, p.memory_gb))
        h.raw("</dd>")
    if learn:
        ref l = learned.value()
        fact_item(
            h,
            "Learned",
            "usage-learned",
            (
                "The request its latest successful runs' peaks suggest: the"
                " 95th percentile of their peak memory plus 15%, at least what"
                " an out-of-memory raised it to, and the 90th percentile of"
                " their peak cores, within its request's range. Applied where"
                " cpus or memory_gb is auto, unless learn = false."
            ),
            "runners",
        )
        if l.any():
            h.text(l.text())
            h.raw(' <span class="muted">')
            h.text("· applied" if l.applied else "· not applied")
            h.raw("</span>")
        else:
            h.raw('<span class="muted">')
            h.text(l.text())
            h.raw("</span>")
        h.raw("</dd>")
    if p.cpus or p.memory_gb or learn:
        h.raw("</dl>")
    h.raw("</section></div>")


def _usage_card(mut h: Html, u: UsageSummary):
    """The Resources card's facts."""
    if u.runs == 0:
        h.raw(
            '<p class="card__none">None of its runs has been measured'
            " yet: the scheduler measures the runs it starts here (local and"
            " control-placed), a worker the ones it runs; runs on EC2 and"
            " Kubernetes aren't.</p>"
        )
        return
    h.raw('<dl class="facts">')
    fact_item(
        h,
        "Measured",
        "usage-runs",
        (
            "How many of its latest runs these are: the last 20 that"
            " recorded what they used."
        ),
    )
    h.text("its last ", u.runs, " run" if u.runs == 1 else " runs")
    h.raw("</dd>")
    fact_item(h, "Peak memory", "usage-peak", PEAK_HELP, "runners")
    if u.peak_max >= 0:
        h.text("p50 ", bytes_text(Int(u.peak_p50)))
        h.text(" · max ", bytes_text(Int(u.peak_max)))
    else:
        h.raw('<span class="muted">not measured</span>')
    h.raw("</dd>")
    fact_item(h, "CPU used", "usage-cpu", CPU_HELP, "runners")
    if u.cpu_max >= 0:
        h.text("p50 ", cpu_text(u.cpu_p50), " · max ", cpu_text(u.cpu_max))
    else:
        h.raw('<span class="muted">not measured</span>')
    h.raw("</dd>")
    fact_item(
        h,
        "Peak cores",
        "usage-cores",
        (
            "The most cores a run's processes kept busy over one sample's"
            " second: the CPUs to ask for. Not measured on macOS."
        ),
        "runners",
    )
    if u.cpus_max >= 0:
        h.text("p50 ", fixed1(u.cpus_p50), " · max ", fixed1(u.cpus_max))
    else:
        h.raw('<span class="muted">not measured</span>')
    h.raw("</dd></dl>")
