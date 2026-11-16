"""`/`, the home page: the pipelines, with their coverage
(`morca._internal.coverage`), schedules, next and last runs, the recent runs (a row
per batch, `morca._internal.ui.recent`), and
the Timeline tab (`morca._internal.ui.viz`);
`/home/pipelines` is its table of pipelines, as the fragment it refreshes
from.
"""

import morca._internal.db.home_view as home_db

from morca._internal.admission import held_warning, row_json, scheduler_pressure
from morca._internal.api.pipelines import json_pipeline
from morca._internal.api.runs import json_runs
from morca._internal.chart import DayRuns, runs_chart
from morca._internal.coverage import Coverage
from morca._internal.fleet import fleet_summary, summary_html, summary_json
from morca._internal.html import Html, url_encode
from morca._internal.json import quote
from morca._internal.run_cpu import CpuKnobs
from morca._internal.state import State
from morca._internal.system import (
    alert_html,
    system_now,
    warnings,
    warnings_json,
)
from morca._internal.ui.coverage import coverage_href
from morca._internal.ui.layout import IDLE_EVERY, LIVE_EVERY, page_html
from morca._internal.dataset_config import private_datasets
from morca._internal.lineage import flows
from morca._internal.ui.parts import data_line, pause_button
from morca._internal.ui.recent import recent_list
from morca._internal.ui.viz import gantt_panel, gantt_tabs
from morca._internal.views.code import pipeline_srcs
from morca._internal.views.pipelines import pipeline_coverage, pipeline_rows
from morca._internal.db.pipelines_view import PipelineRow
from morca._internal.views.recent import json_recent, recent_rows
from morca._internal.views.runs import HOME_RUNS, RunsQuery, run_rows
from morca._internal.watchdog import active_trips, banner_html, trips_json
from morca._internal.web.page import Page


def _runs_per_day(mut db: State, days: Int) raises -> List[DayRuns]:
    """Runs by the UTC day they started (or were made, if they haven't),
    for the last `days` days up to today."""
    var out = List[DayRuns]()
    for r in home_db.runs_per_day(db.conn, days):
        out.append(DayRuns(r.day, r.succeeded, r.failed, r.other))
    return out^


def _pipelines_live(ps: List[PipelineRow]) -> Bool:
    """Whether any of these pipelines has a run queued or running."""
    for p in ps:
        if p.running > 0 or p.queued > 0:
            return True
    return False


def _coverages(
    mut db: State, ps: List[PipelineRow]
) -> List[Optional[Coverage]]:
    """Each pipeline's coverage (`morca._internal.coverage`): a query each."""
    var out = List[Optional[Coverage]]()
    for p in ps:
        out.append(pipeline_coverage(db, p))
    return out^


def _coverage_cell(mut h: Html, p: PipelineRow, c: Optional[Coverage]):
    """A Coverage cell: the percent with a bar, the counts on hover, linking
    to the year calendar (a keyed pipeline's Keys); "—" for none."""
    if not c:
        h.raw('<td class="num muted">—</td>')
        return
    ref v = c.value()
    h.raw('<td class="num"><a class="covpct" href="')
    h.text(coverage_href(p.name, p.kind))
    h.raw('" title="')
    h.text(v.text())
    h.raw('">')
    h.text(v.pct(), "%")
    h.raw('<span class="covpct__bar" aria-hidden="true"><span style="width:')
    h.raw(String(v.pct()), '%"></span></span><span class="sr">')
    h.text(", ", v.done, " of ", v.total, " ", v.units(), " done")
    h.raw("</span></a></td>")


def _srcs(mut db: State, ps: List[PipelineRow]) -> Dict[String, String]:
    var names = List[String]()
    for p in ps:
        names.append(p.name)
    return pipeline_srcs(db, names)


def _writes(mut db: State) raises -> Dict[String, List[String]]:
    """Each pipeline's datasets it writes, as declared."""
    var out = Dict[String, List[String]]()
    for f in flows(db):
        if f.writes:
            if f.pipeline not in out:
                out[f.pipeline] = List[String]()
            if f.dataset not in out[f.pipeline]:
                out[f.pipeline].append(f.dataset)
    return out^


def _home_pipelines(
    mut h: Html,
    mut db: State,
    ps: List[PipelineRow],
    covs: List[Optional[Coverage]],
    srcs: Dict[String, String],
) raises:
    """The home page's table of pipelines: after each name its state at a
    glance (coverage, running and queued runs), then its partitions,
    schedule, next and last runs. A pipeline's name shows its declaration
    on hover (`data-src`, the page's `_PEEK`), at the registered code;
    under it, a link to the data of each dataset it writes."""
    var writes = _writes(db)
    var private = private_datasets(db)
    h.raw(
        '<section class="card"><div class="scroll"><table><thead><tr>',
        '<th>Pipeline</th><th class="num">Coverage</th>',
        "<th>Running</th><th>Queued</th><th>Partitions</th><th>Schedule</th>",
        "<th>Next run</th><th>Last run</th>",
        "</tr></thead><tbody>",
    )
    for i in range(len(ps)):
        ref p = ps[i]
        h.raw('<tr><td><a href="')
        h.text(String("/pipelines/", url_encode(p.name)))
        h.raw('"')
        var src = srcs.get(p.name)
        if src:
            h.raw(' data-src="')
            h.text(src.value())
            h.raw('"')
        h.raw(">")
        h.text(p.name)
        h.raw("</a>")
        if p.paused:
            h.raw(" ")
            h.status("paused")
        pause_button(h, p.name, p.paused)
        var w = writes.get(p.name)
        if w:
            data_line(h, w.value(), private)
        h.raw("</td>")
        _coverage_cell(h, p, covs[i])
        # The counts as badges, lit while they're not zero.
        h.raw(
            '<td><span class="badge',
            " badge--running" if p.running > 0 else "",
            '">',
        )
        h.text(p.running, " / ", p.max_runs)
        h.raw(
            '</span></td><td><span class="badge',
            " badge--queued" if p.queued > 0 else "",
            '">',
        )
        h.text(p.queued)
        h.raw("</span></td>")
        h.cell(p.kind, " from ", p.start if p.start else String("the start"))
        if p.cron:
            h.raw("<td><code>")
            h.text(p.cron)
            h.raw("</code> ")
            h.text(p.tz)
            h.raw("</td>")
            h.mono(p.next_fire, " → ", p.next_partition)
        else:
            h.raw('<td class="muted">none</td><td></td>')
        h.raw("<td>")
        if p.last_run:
            h.chip(String("/runs/", p.last_run), String(p.last_run))
            h.raw(" ")
            h.status(p.last_status)
            h.raw(' <span class="mono muted">')
            h.text(p.last_partitions)
            h.raw("</span>")
        h.raw("</td></tr>")
    h.raw("</tbody></table></div></section>")


def home_pipelines(mut db: State) raises -> Page:
    """`/home/pipelines`: the home page's table of pipelines, as the
    fragment it refreshes from; ask again in `LIVE_EVERY` seconds while a
    run is queued or running, else `IDLE_EVERY`."""
    var ps = pipeline_rows(db)
    var h = Html()
    _home_pipelines(h, db, ps, _coverages(db, ps), _srcs(db, ps))
    return Page(
        200,
        String(),
        h^.finish(),
        "text/html; charset=utf-8",
        poll_every=LIVE_EVERY if _pipelines_live(ps) else IDLE_EVERY,
    )


def home(mut db: State) raises -> Page:
    var ps = pipeline_rows(db)
    var covs = _coverages(db, ps)
    var newest = run_rows(db, RunsQuery.newest("home", HOME_RUNS), HOME_RUNS)
    var recent = recent_rows(db, HOME_RUNS)
    var per_day = _runs_per_day(db, 30)
    var fleet = fleet_summary(db)
    var alerts = warnings(system_now(db))
    var pressure = scheduler_pressure(db)
    var held = held_warning(pressure)
    if held:
        alerts.append(held)
    var trips = active_trips(db)
    var j = String(
        '{"warnings": ',
        warnings_json(alerts),
        ', "memory_pressure": ',
        row_json(pressure),
        ', "run_cpu": ',
        CpuKnobs.settings().json(),
        ', "watchdog": ',
        trips_json(trips),
        ', "pipelines": [',
    )
    for i in range(len(ps)):
        if i:
            j.write(", ")
        json_pipeline(j, ps[i], covs[i])
    j.write('], "runs": ')
    json_runs(j, newest)
    j.write(', "recent": ')
    json_recent(j, recent)
    j.write(', "runs_per_day": [')
    for i in range(len(per_day)):
        ref d = per_day[i]
        j.write(
            ", " if i else "",
            '{"day": ',
            quote(d.day),
            ', "succeeded": ',
            d.succeeded,
            ', "failed": ',
            d.failed,
            ', "other": ',
            d.other,
            "}",
        )
    j.write('], "fleet": ', summary_json(fleet), "}")

    var h = Html()
    h.raw("<h1>Pipelines</h1>")
    banner_html(h, trips)
    alert_html(h, alerts)
    summary_html(h, fleet, True)
    if len(ps) == 0:
        h.raw(
            '<p class="empty">No pipelines yet: <code>morca register',
            " &lt;binary&gt;</code> adds one.</p>",
        )
    else:
        # List and Timeline tabs over the table (morca.ui.viz).
        gantt_tabs(h)
        # Refreshed while the page is open: often while a run is going on.
        var live = _pipelines_live(ps)
        h.raw(
            '<div data-poll="/home/pipelines" data-poll-every="',
            LIVE_EVERY if live else IDLE_EVERY,
            '">',
        )
        _home_pipelines(h, db, ps, covs, _srcs(db, ps))
        h.raw("</div>")
        gantt_panel(h)
    h.raw(
        '<section class="card"><h2>Runs per day</h2>',
        '<p class="muted">The last 30 days, by the day each run started',
        " (UTC).</p>",
        '<div class="scroll">',
        runs_chart(per_day),
        "</div></section>",
    )
    h.raw('<section class="card"><h2>Recent runs</h2>')
    recent_list(h, db, recent, HOME_RUNS)
    h.raw('<p class="more"><a href="/runs">All runs</a></p></section>')
    return Page(200, j^, page_html("Pipelines", "/", h))
