"""`/runs/<id>`, a run's page: its cards (Status, Partitions & trigger,
Code, Resources, Settings), its steps as a table, a timeline or a graph,
its machines, its snapshots and who acted on it; and its fragments and
files: `/live`, `/steps`, `/metrics`, `timeline.json`, `driver.log` and
each machine's log.
"""

import morca._internal.db.run_view as run_db

from morca._internal.ui.cluster import cluster_html
from morca._internal.views.cluster import cluster_rows
from morca._internal.dag import DagStep, aggregate, dag_svg
from morca._internal.html import Html, url_encode
from morca._internal.lineage import SnapshotRef
from morca._internal.logs import location_exists, read_location, run_dir
from morca._internal.metrics import InstanceMetrics, metrics_svg, read_metrics
from morca._internal.state import State
from morca._internal.ui.attempt import read_log
from morca._internal.ui.datasets import snapshot_href
from morca._internal.ui.layout import (
    act_button,
    ask_attrs,
    card_open,
    fact_item,
    fact_term,
    help_tip,
    page_html,
)
from morca._internal.ui.errors import not_found
from morca._internal.ui.machines import instances_html, machines_html
from morca._internal.dataset_config import private_datasets
from morca._internal.ui.parts import (
    TRIES,
    cancel_tell,
    data_link,
    grant_facts,
    named_code_link,
    partitions_fact,
    row_actions,
    source_html,
    step_cell,
    took_long,
    usage_cell,
    usage_facts,
)
from morca._internal.ui.step_cards import cards_script
from morca._internal.ui.viz import timeline_section
from morca._internal.usage import cpu_text
from morca._internal.views.code import code_links
from morca._internal.views.pipelines import StepDef, step_defs
from morca._internal.views.runs import (
    RunRow,
    RunView,
    StepRow,
    cluster_log_name,
    instance_rows,
    live_status,
    run_version,
    runs_one,
    step_rows,
    step_spans,
    timeline_path,
)
from morca._internal.views.steps import attempt_cards, step_cards_of
from morca._internal.web.page import Page
from morca._internal.workers import ran_on


def run_html(mut db: State, v: RunView, view: String = "") raises -> String:
    """A run's page; `view` (`?steps=`) is the Steps tab shown without
    scripts. Its cards' live part is `run_state`, which `/runs/<id>/live`
    refreshes."""
    ref r = v.run
    var h = Html()
    h.raw('<p class="crumb"><a href="/runs">Runs</a> · ')
    h.link(String("/pipelines/", url_encode(r.pipeline)), r.pipeline)
    h.raw(' <span class="muted">·</span> ')
    var prev = v.prev
    var next = v.next
    if prev:
        h.raw('<a rel="prev" href="/runs/', prev, '">← run ', prev, "</a>")
    else:
        h.raw('<span class="muted" aria-disabled="true">← run</span>')
    h.raw(" · ")
    if next:
        h.raw('<a rel="next" href="/runs/', next, '">run ', next, " →</a>")
    else:
        h.raw('<span class="muted" aria-disabled="true">run →</span>')
    h.raw("</p><h1>Run ")
    h.text(r.id)
    h.raw(" ")
    h.status(r.status)
    if r.status == "succeeded":
        var defs = step_defs(db, r.pipeline)
        if len(defs) > 0:
            act_button(
                h,
                String("/runs/", r.id, "/rerun"),
                "Rerun",
                "rerun",
                "no morca command for this yet: a new run of every step",
                danger=True,
                step=defs[0].name,
                ask=String("Rerun every step of run ", r.id, "?"),
                tell=String(
                    "A new run of ",
                    r.pipeline,
                    (
                        " over the same partitions starts from its first step;"
                        " run "
                    ),
                    r.id,
                    " is kept as it is.",
                ),
                harm=False,
            )
    else:
        row_actions(h, r)
    h.raw("</h1>")
    var timeline = timeline_path(db, r)
    # What changes while it goes on is one fragment, refreshed as a whole.
    if live_status(r.status):
        h.raw('<div data-poll="/runs/')
        h.text(r.id)
        h.raw('/live" data-poll-every="5">')
    else:
        h.raw("<div>")
    _run_state(h, db, r, view)
    h.raw("</div>")
    if timeline:
        # Drawn in the browser, from timeline.json once it's in view.
        timeline_section(h, r.id)
    # Who did what to it from the UI (morca.auth).
    if len(v.actions) > 0:
        card_open(
            h,
            "audit",
            "Actions",
            (
                "Who did what to this run, from the UI or the morca command,"
                " as the user they logged in as."
            ),
            facts=False,
        )
        h.raw(
            '<div class="scroll"><table><thead><tr>',
            "<th>At</th><th>By</th><th>Action</th><th>From</th></tr>",
            "</thead><tbody>",
        )
        for a in v.actions:
            h.raw("<tr>")
            h.mono(a.at)
            h.cell(a.user)
            h.cell(a.action)
            h.cell(a.source)
            h.raw("</tr>")
        h.raw("</tbody></table></div></section>")
    if len(v.touches) > 0:
        card_open(
            h,
            "tables",
            "Snapshots",
            (
                "The table snapshots each step read, and the ones it wrote"
                " (committed). A dataset's snapshot links to its lineage:"
                " upstream, what it was written from, and downstream, what"
                " was written from it."
            ),
            "tables",
            facts=False,
        )
        h.raw(
            '<div class="scroll"><table><thead><tr>',
            "<th>Step</th><th>Partition</th><th>Read or wrote</th>",
            "<th>Table</th><th>Snapshot</th></tr></thead><tbody>",
        )
        var private = private_datasets(db)
        for t in v.touches:
            h.raw("<tr>")
            h.cell(t.step)
            h.cell(t.partition)
            h.raw("<td>")
            h.term("touch", "wrote" if t.kind == "commit" else t.kind)
            h.raw("</td>")
            h.raw("<td>")
            if t.dataset:
                h.link(String("/datasets/", url_encode(t.dataset)), t.dataset)
            else:
                h.raw("<code>")
                h.text(t.table)
                h.raw("</code>")
            h.raw("</td><td>")
            if t.dataset and t.snapshot != "-1":
                h.link(
                    String(
                        "/datasets/",
                        url_encode(t.dataset),
                        "/snapshots/",
                        t.snapshot,
                    ),
                    t.snapshot,
                )
                h.raw(" ")
                data_link(h, t.dataset, private, snapshot=t.snapshot)
            else:
                h.text(t.snapshot)
            h.raw("</td></tr>")
        h.raw("</tbody></table></div></section>")
    return page_html(String("Run ", r.id), "/runs", h)


def _action(mut h: Html, run: Int, name: StaticString):
    """The start of a form that posts to one of a run's actions."""
    h.raw('<form class="action" method="post" action="/runs/')
    h.text(run)
    h.raw("/", name, '">')


def _run_actions(mut h: Html, r: RunRow, steps: List[StepDef]):
    """The forms for what can be done to the run as it is: resume, rerun
    from a step, cancel."""
    var resumable = (
        r.status == "failed"
        or r.status == "cancelled"
        or r.status == "deferred"
        or r.stalled
    )
    var cancellable = (
        r.status == "queued"
        or r.status == "failed"
        or r.status == "running"
        or r.status == "deferred"
    ) and not r.cancel_requested
    var ended = not live_status(r.status)
    if not (resumable or cancellable or ended):
        return
    h.raw('<div class="actions">')
    if resumable:
        _action(h, r.id, "resume")
        h.raw(
            '<button type="submit">Resume</button><span class="muted">',
            " what hasn't succeeded</span></form>",
        )
    if ended and len(steps) > 0:
        _action(h, r.id, "rerun")
        h.raw('<label>Rerun from <select name="step">')
        for s in steps:
            h.raw("<option>")
            h.text(s.name)
            h.raw("</option>")
        h.raw('</select></label><button type="submit">Rerun</button></form>')
    if cancellable:
        h.raw('<form class="action" method="post" action="/runs/')
        h.text(r.id)
        h.raw('/cancel"')
        ask_attrs(
            h,
            String("Cancel run ", r.id, "?"),
            cancel_tell(r),
            "Cancel run",
            "Keep it",
        )
        h.raw('><button type="submit" class="danger">Cancel</button></form>')
    h.raw("</div>")


comptime _CANCEL_HELP = (
    "Cancel was asked for: the run stops before its next attempt, and what"
    " is running finishes."
)


def _status_card(mut h: Html, r: RunRow, defs: List[StepDef]):
    """The Status card: how long it took and when, its tries, why it waits,
    is held or failed, and what can be done to it."""
    card_open(
        h,
        "status",
        "Status",
        (
            "Where the run is: queued, running, then succeeded, failed or"
            " cancelled. Refreshed every 5 s while it goes on."
        ),
        "runs",
    )
    h.raw('<dl class="facts">')
    if r.seconds >= 0:
        fact_term(
            h,
            "Duration",
            "run-duration",
            (
                "How long the run took, from its start to its end, or to now"
                " while it goes on. Hover for the times."
            ),
        )
        h.raw('<dd title="')
        h.text(
            "started ", r.started, "; ended " if r.ended else "; still going"
        )
        h.text(r.ended)
        h.raw('">')
        h.text(took_long(r.seconds))
        h.raw("</dd>")
    fact_item(
        h,
        "Created",
        "run-created",
        (
            "When the run was queued: by the schedule, a sensor, a backfill,"
            " a fill or a person."
        ),
    )
    h.text(r.created)
    h.raw("</dd>")
    fact_item(
        h,
        "Started",
        "run-started",
        (
            "When its process started, once its turn in the queue came and"
            " its placement had room. Empty while it waits."
        ),
    )
    h.text(r.started)
    h.raw("</dd>")
    fact_item(
        h,
        "Ended",
        "run-ended",
        "When it finished, whatever the outcome. Empty while it goes on.",
    )
    h.text(r.ended)
    h.raw("</dd>")
    fact_item(h, "Tries", "run-tries", TRIES)
    h.text(r.starts)
    h.raw("</dd>")
    if r.waiting_until:
        fact_item(
            h,
            "Waiting",
            "run-waiting",
            (
                "A step asked to run again later, so the run waits until"
                " then and goes on by itself."
            ),
        )
        h.text("until ", r.waiting_until, ", when a step asked to run again")
        h.raw("</dd>")
    if r.held and r.status == "queued":
        fact_term(
            h,
            "Held",
            "run-held",
            (
                "Why it is queued and not started: its placement is full or"
                " the host is short of memory or disk. It starts once that"
                " clears."
            ),
            "placement",
        )
        h.raw('<dd class="error">')
        h.text(r.held.removeprefix("held: "))
        if r.waits_on > 0:
            # The run holding the concurrency key it waits on (#397).
            h.raw(" ")
            h.chip(String("/runs/", r.waits_on), String("run ", r.waits_on))
        h.raw("</dd>")
    if r.error:
        fact_item(
            h,
            "Error",
            "run-error",
            (
                "Why the run failed, as its process or morca said. The"
                " failed step's attempt, under Steps, has its log."
            ),
        )
        h.text(r.error)
        h.raw("</dd>")
    if r.stalled:
        fact_item(
            h,
            "Process",
            "run-process",
            (
                "Its process stopped sending heartbeats: it died, or its"
                " machine went away. Resume starts what hadn't succeeded."
            ),
            "scheduler",
        )
        h.raw("stalled: its heartbeat stopped, so it can be resumed</dd>")
    elif r.cancel_requested and live_status(r.status):
        fact_item(h, "Cancel", "run-cancel", _CANCEL_HELP)
        h.raw("asked for; the run stops before its next attempt</dd>")
    if r.code_version or r.outdated:
        fact_item(
            h,
            "Version",
            "run-outdated",
            (
                "The version this run runs. Outdated: a newer version leads"
                " (registered, or its scheduler drains). Morca doesn't stop"
                " it; its code can ask morca.outdated() and end when it"
                " likes."
            ),
            "versions",
        )
        h.raw("<code>")
        h.text(r.code_version if r.code_version else String("unknown"))
        h.raw("</code>")
        if r.outdated:
            h.raw(" <strong>outdated</strong> ")
            h.text("(", r.outdated, ")")
        h.raw("</dd>")
    h.raw("</dl>")
    _run_actions(h, r, defs)
    h.raw("</section>")


def _trigger_card(mut h: Html, mut db: State, r: RunRow) raises:
    """The Partitions & trigger card: what the run does and what started
    it, with the rebuild or the snapshots a sensor saw, and the batch it
    was queued in (`morca._internal.batches`) with how many runs that has."""
    var row = run_db.run_batch(db.conn, r.id)
    var rebuild = row.rebuild
    var batch = row.batch
    var sensed = List[SnapshotRef]()
    for x in run_db.sensed(db.conn, r.id):
        sensed.append(SnapshotRef(x[0], x[1]))
    card_open(
        h,
        "trigger",
        "Partitions &amp; trigger",
        "What this run does, and what made it start.",
        "partitions",
    )
    h.raw('<dl class="facts">')
    fact_item(
        h,
        "Partitions",
        "run-partitions",
        (
            "The partitions this run does (months, days, hours or named"
            " keys): each step runs once per partition."
        ),
        "partitions",
    )
    partitions_fact(h, r.partitions)
    h.raw("</dd>")
    fact_item(
        h,
        "Trigger",
        "run-trigger",
        (
            "What started it: the schedule, a sensor (with the snapshots it"
            " saw), a rebuild, a backfill, a fill, or manual (a person, or a"
            " binary's run command)."
        ),
        "sensors",
    )
    h.term("trigger", r.trigger)
    if rebuild:
        h.raw(" ")
        h.link(String("/rebuilds/", rebuild), String("rebuild ", rebuild))
    if len(sensed) > 0:
        h.raw(" of ")
        for i in range(len(sensed)):
            if i:
                h.raw(", ")
            h.link(snapshot_href(sensed[i]), String(sensed[i]))
    if batch:
        h.raw(' <span class="muted">part of</span> ')
        h.link(String("/runs?batch=", batch), String(r.trigger, " ", batch))
        h.raw(' <span class="muted">(')
        h.text(row.batch_runs, " runs)")
        h.raw("</span>")
    h.raw("</dd></dl></section>")


def _run_code_card(mut h: Html, mut db: State, r: RunRow) raises:
    """The Code card: the pipeline, its steps and tasks on one line, each
    a name linked to its line; the commit and image; the driver log; then
    the code hash."""
    var current = run_db.pipeline_hash(db.conn, r.pipeline)
    var hash = run_db.run_hash(db.conn, r.id)
    var version = run_version(db, r.id)
    var links = code_links(db, r.pipeline, version)
    card_open(
        h,
        "code",
        "Code",
        (
            "The code this run ran, at the commit its binary was built from."
            " Hover a name to see its source; click it to open the file on"
            " its host."
        ),
        "versions",
    )
    h.raw('<dl class="facts">')
    var defs = step_defs(db, r.pipeline)
    var any = len(links.tasks) > 0
    if links.pipeline:
        any = True
    for s in defs:
        if links.step(s.name):
            any = True
    if any:
        fact_item(
            h,
            "Functions",
            "run-code",
            (
                "The pipeline, its steps in the order they run, and the dista"
                " tasks they fan out to, each linked to its line at the"
                " commit this run ran."
            ),
            "steps",
        )
        var first = True
        if links.pipeline:
            named_code_link(h, r.pipeline, links.pipeline)
            first = False
        for s in defs:
            var at = links.step(s.name)
            if not at:
                continue
            h.raw("" if first else " · ")
            first = False
            named_code_link(h, s.name, at)
        for t in links.tasks:
            h.raw("" if first else " · ")
            first = False
            named_code_link(h, t[0], t[1])
        h.raw("</dd>")
    if version:
        fact_item(
            h,
            "Source",
            "run-source",
            (
                "The commit its binary was built from (-D MORCA_COMMIT, or the"
                " image's MORCA_COMMIT), in"
                " which repository, and the image it ran in, if any."
            ),
            "versions",
        )
        source_html(h, version.value())
        if version.value().image:
            h.raw(' <span class="muted">in image</span> <code>')
            h.text(version.value().image)
            h.raw("</code>")
        h.raw("</dd>")
    var dir = run_dir(r.pipeline, r.id)
    if dir and location_exists(String(dir, "/driver.log")):
        fact_item(
            h,
            "Driver log",
            "run-driver",
            (
                "What the run's process printed: morca's lines and its steps'"
                " output, as the scheduler kept it. Each attempt under Steps"
                " has its own log too."
            ),
        )
        h.link(String("/runs/", r.id, "/driver.log"), "driver.log")
        h.raw("</dd>")
    h.raw("</dl>")
    if not any and not version:
        h.raw(
            '<p class="card__none">No links to the code: the binary records',
            " no source, or <code>morca locate</code> didn't map it.</p>",
        )
    h.raw('<p class="hash">Code hash <code>')
    h.text(hash)
    h.raw("</code>")
    help_tip(
        h,
        "run-hash",
        "Code hash",
        (
            "A hash of what the binary says about itself: its steps,"
            " partitions and schedule. It changes when they do, not on every"
            " build."
        ),
        "versions",
    )
    if hash != current:
        h.raw(' <span class="muted">(the pipeline has newer code)</span>')
    h.raw("</p></section>")


def _resources_card(mut h: Html, mut db: State, r: RunRow) raises:
    """The Resources card: what the run's own processes used, and on
    Kubernetes what its pods asked for."""
    var pods = run_db.run_pods(db.conn, r.id)
    var cpu = pods[0]
    var secs = pods[1]
    card_open(
        h,
        "resources",
        "Resources",
        (
            "What this run's own processes used: its process and the ones it"
            " started, dista's local workers too, measured by the scheduler"
            " or worker that started it. Not the rest of the machine: the"
            " machine's numbers, where they are recorded, are in their own"
            " card further down. With a request, what it asked for and was"
            " granted too."
        ),
        "runners",
    )
    h.raw('<dl class="facts">')
    grant_facts(h, r.resources)
    usage_facts(h, r.usage, live_status(r.status))
    if cpu:
        fact_item(
            h,
            "Pods asked",
            "run-pods",
            (
                "On Kubernetes, the CPU its pods asked for, times how long it"
                " ran: what the cluster set aside for it, not what it used."
            ),
            "runners",
        )
        h.text(
            cpu // 1000,
            ".",
            String(cpu % 1000 + 1000)[byte=1:],
            " vCPU for ",
            secs,
            " s, ",
            cpu * secs // 1000,
            " vCPU-seconds",
        )
        h.raw("</dd>")
    h.raw("</dl></section>")


def _run_state(mut h: Html, mut db: State, r: RunRow, view: String = "") raises:
    """What changes while a run goes on: its cards, the steps, the machines
    and who waits for what. The page and `/runs/<id>/live` both draw it."""
    var defs = step_defs(db, r.pipeline)
    h.raw('<div class="pcards">')
    _status_card(h, r, defs)
    _trigger_card(h, db, r)
    _run_code_card(h, db, r)
    _resources_card(h, db, r)
    _run_settings(h, db, r)
    h.raw("</div>")
    _run_live(h, db, r, step_rows(db, r.id), view)
    machines_html(h, db, r, read_metrics(r.pipeline, r.id))
    if live_status(r.status):
        var waiting = run_db.waiting_since(db.conn, r.id)
        if waiting:
            h.raw('<p class="muted">Waiting for workers since ')
            h.text(waiting.value())
            h.raw(
                ": its head has tasks and no worker; the attempt fails when"
                " that has lasted <code>MORCA_NO_WORKERS_SECONDS</code>.</p>"
            )
    var instances = instance_rows(db, r.id)
    if len(instances) > 0:
        instances_html(h, r.id, instances)
    cluster_html(h, cluster_rows(db, r.id))


def run_live(mut db: State, id: Int) raises -> Page:
    """The changing part of a run's page, as a fragment; 286 once it's ended."""
    var found = runs_one(db, id)
    if not found:
        return not_found(String("no run ", id))
    var r = found.take()
    var h = Html()
    _run_state(h, db, r)
    return Page(
        200 if live_status(r.status) else 286,
        String(),
        h^.finish(),
        "text/html; charset=utf-8",
    )


def _setting_help(key: String) -> StaticString:
    """The "?" text of one of a run's settings."""
    if key == "Max runs":
        return (
            "The most runs of this pipeline the scheduler starts at once"
            " (max_runs); the others wait in the queue."
        )
    if key == "Placement":
        return (
            "Where its runs start (placement): default (the scheduler's"
            " runner), control, ec2, or a remote worker's pool."
        )
    if key == "Head type":
        return "The EC2 instance type of the run's dista head."
    if key == "Worker type":
        return "The EC2 instance type of each of its dista workers."
    if key == "Workers":
        return "How many dista workers the run asks for."
    if key == "Min workers":
        return "The fewest workers it starts with; more join as they boot."
    if key == "Spot":
        return (
            "Whether its EC2 instances are Spot: cheaper, and AWS can take"
            " them back."
        )
    return "Dista worker processes on each worker instance."


def _run_settings(mut h: Html, mut db: State, r: RunRow) raises:
    """The Settings card: where the run ran, and what it was set up with:
    its environment as it was after morca.toml and the flags (what its start
    recorded, else what the pipeline is registered with), and the limits
    and machines. Secrets by name only."""
    var found = run_db.run_settings(db.conn, r.id)
    if not found:
        return
    ref s = found.value()
    card_open(
        h,
        "settings",
        "Settings",
        (
            "What the run was set up with, morca.toml and the flags applied:"
            " as its start recorded them, or else as the pipeline is"
            " registered. The pipeline's Config card says where each value"
            " came from."
        ),
        "placement",
    )
    h.raw('<p class="card__sub">')
    if s.recorded:
        h.raw("As this run was started.")
    else:
        h.raw("As the pipeline is registered.")
    h.raw(' <a href="/pipelines/')
    h.text(url_encode(r.pipeline))
    h.raw('#config">Where each value came from</a></p>')
    h.raw('<dl class="facts">')
    if r.placement:
        fact_item(
            h,
            "Placed",
            "run-placed",
            (
                "Where it ran: local (beside the scheduler, on its machine),"
                " control (on the control host, within its limits), ec2"
                " (instances of its own), or a remote worker's pool."
            ),
            "placement",
        )
        h.term("placement", r.placement)
        if r.placement == "control":
            h.raw(' <span class="muted">(on the control host)</span>')
        h.raw("</dd>")
        var on = ran_on(db, r.id)
        if on:
            fact_item(
                h,
                "Ran on",
                "run-ran-on",
                "The remote worker that claimed and ran it, and its token.",
                "placement",
            )
            h.text(on)
            h.raw("</dd>")
    var pairs = [
        ("Max runs", s.max_runs),
        ("Placement", s.placement if not r.placement else String()),
        ("Head type", s.head),
        ("Worker type", s.worker),
        ("Workers", s.workers),
        ("Min workers", s.min_workers),
        ("Spot", s.spot),
        ("Procs per worker", s.procs),
    ]
    for p in pairs:
        if p[1]:
            h.raw("<dt>")
            h.text(p[0])
            help_tip(
                h,
                String("run-set-", String(p[0]).lower().replace(" ", "-")),
                p[0],
                _setting_help(p[0]),
            )
            h.raw("</dt><dd>")
            h.text(p[1])
            h.raw("</dd>")
    var env = run_db.env_pairs(db.conn, s.env)
    var names = run_db.object_keys(db.conn, s.secrets)
    if len(env) > 0:
        fact_item(
            h,
            "Environment",
            "run-env",
            (
                "The variables morca.toml's env and the flags set in the run's"
                " environment."
            ),
        )
        for i in range(len(env)):
            h.raw("<br>" if i else "", '<code class="env">')
            h.text(env[i][0])
            h.raw('</code>=<code class="env">')
            h.text(env[i][1])
            h.raw("</code>")
        h.raw("</dd>")
    if len(names) > 0:
        fact_item(
            h,
            "Secrets",
            "run-secrets",
            (
                "The secrets put in its environment, by name. Their values"
                " are never shown, here or in its logs."
            ),
        )
        for i in range(len(names)):
            h.raw(", " if i else "", "<code>")
            h.text(names[i])
            h.raw("</code>")
        h.raw("</dd>")
    h.raw("</dl></section>")


def _run_live(
    mut h: Html,
    mut db: State,
    r: RunRow,
    steps: List[StepRow],
    view: String = "",
) raises:
    """The Steps card: its tabs (`?steps=table|timeline|graph`, the table
    without one; with scripts the choice is kept in `localStorage`), the
    table of steps by partition, their attempts on the clock, and the DAG
    in their colours."""
    var defs = step_defs(db, r.pipeline)
    var links = code_links(db, r.pipeline, run_version(db, r.id))
    var shown = String("table")
    if view == "timeline" or view == "graph":
        shown = view
    var dag = List[DagStep]()
    for d in defs:
        var st = List[String]()
        for s in steps:
            if s.step == d.name:
                st.append(s.status)
        dag.append(
            DagStep(
                d.name,
                d.kind,
                d.after,
                aggregate(st),
                links.step(d.name).url,
            )
        )
    h.raw(
        '<section class="card steps" id="steps" data-tabs="morca.run.steps"',
        ' data-tabs-param="steps" data-step-cards><div class="steps__head">',
        "<h2>Steps",
    )
    help_tip(
        h,
        "card-steps",
        "Steps",
        (
            "Each step of each partition. Table: its status, attempts, times,"
            " what its latest attempt used, and its log. Timeline: the"
            " attempts on the clock, a row per step. Graph: the steps in the"
            " order they run, in this run's colours."
        ),
        "steps",
    )
    h.status(r.status)
    h.raw(
        '</h2><div class="vtabs"><div role="tablist"',
        ' aria-label="How to show the steps">',
    )
    for v in [("table", "Table"), ("timeline", "Timeline"), ("graph", "Graph")]:
        h.raw('<a role="tab" class="vtabs__tab" data-view="', v[0], '" href="')
        h.text("/runs/", r.id, "?steps=", v[0], "#steps")
        h.raw(
            '" aria-selected="',
            "true" if shown == v[0] else "false",
            '" aria-controls="steps-',
            v[0],
            '">',
            v[1],
            "</a>",
        )
    h.raw(
        '</div></div></div><div id="steps-table" role="tabpanel"',
        ' class="scroll"',
        "" if shown == "table" else " hidden",
        "><table><thead><tr><th>Step</th>",
        '<th>Partition</th><th>Status</th><th class="num">Attempts</th>',
        "<th>Started</th><th>Ended</th>",
        '<th class="num"><abbr title="',
        _STEP_PEAK,
        '" aria-label="Peak memory: ',
        _STEP_PEAK,
        '">Peak</abbr></th><th class="num">CPU</th>',
        "<th>Log</th><th>Error</th></tr></thead><tbody>",
    )
    for s in steps:
        h.raw("<tr>")
        step_cell(h, s.step, links, s.attempt_id)
        h.mono(s.partition)
        h.raw("<td>")
        h.status(s.status)
        h.raw("</td>")
        h.num(s.attempts)
        h.mono(s.started)
        h.mono(s.ended)
        usage_cell(h, s.usage, s.limit_mb, s.grant_mb)
        if s.usage.cpu_seconds >= 0:
            h.num(cpu_text(s.usage.cpu_seconds))
        else:
            h.raw('<td class="num"></td>')
        h.raw("<td>")
        if s.attempt_id:
            h.link(
                String("/runs/", r.id, "/attempts/", s.attempt_id),
                String("attempt ", s.attempts),
            )
        elif s.from_run:
            h.raw('<span class="muted">from </span>')
            h.link(String("/runs/", s.from_run), String("run ", s.from_run))
        h.raw('</td><td class="error">')
        h.text(s.error)
        h.raw("</td></tr>")
    h.raw(
        '</tbody></table></div><div id="steps-timeline" role="tabpanel"',
        ' class="scroll steps__graph"',
        "" if shown == "timeline" else " hidden",
        ">",
    )
    var spans = step_spans(db, r.id)
    if len(spans) > 0:
        h.raw(
            metrics_svg(
                List[InstanceMetrics](),
                spans,
                live_status(r.status),
                "The run's attempts over time",
            )
        )
    else:
        h.raw('<p class="muted">No attempt has started yet.</p>')
    h.raw(
        '</div><div id="steps-graph" role="tabpanel" class="scroll',
        ' steps__graph"',
        "" if shown == "graph" else " hidden",
        ">",
        dag_svg(dag),
        "</div>",
        cards_script(
            step_cards_of(db, r.pipeline, defs, links, False),
            attempt_cards(db, r.id),
        ),
        "</section>",
    )


comptime _STEP_PEAK = (
    "The most memory the step's latest attempt held at once; its page has"
    " each attempt's."
)


def run_steps(mut db: State, id: Int) raises -> Page:
    """The live part of a run's page, as a fragment; 286 once it's ended."""
    var found = runs_one(db, id)
    if not found:
        return not_found(String("no run ", id))
    var r = found.take()
    var h = Html()
    _run_live(h, db, r, step_rows(db, id))
    return Page(
        200 if live_status(r.status) else 286,
        String(),
        h^.finish(),
        "text/html; charset=utf-8",
    )


def run_metrics(mut db: State, id: Int) raises -> Page:
    """The run's machines, as a fragment; 286 once it's ended."""
    var found = runs_one(db, id)
    if not found:
        return not_found(String("no run ", id))
    var r = found.take()
    var h = Html()
    machines_html(h, db, r, read_metrics(r.pipeline, id))
    return Page(
        200 if live_status(r.status) else 286,
        String(),
        h^.finish(),
        "text/html; charset=utf-8",
    )


def timeline(mut db: State, id: Int) raises -> Page:
    var found = runs_one(db, id)
    if not found:
        return not_found(String("no run ", id))
    var path = timeline_path(db, found.value())
    if not path:
        return not_found(String("run ", id, " has no timeline"))
    var body = String(from_utf8_lossy=Span(read_location(path)))
    return Page(200, String(), body^, "application/json")


def driver_log(mut db: State, id: Int) raises -> Page:
    """The run's driver log, as the scheduler kept it under MORCA_LOGS."""
    var found = runs_one(db, id)
    if not found:
        return not_found(String("no run ", id))
    var dir = run_dir(found.value().pipeline, id)
    var got = read_log(String(dir, "/driver.log")) if dir else (
        String(),
        False,
    )
    if not got[0]:
        return not_found(String("run ", id, " has no driver log"))
    return Page(200, String(), got[0], "text/plain; charset=utf-8")


def cluster_log(mut db: State, id: Int, name: String) raises -> Page:
    """An instance's log, as its script kept it under MORCA_LOGS: only the
    names of the run's own instances are served."""
    var found = runs_one(db, id)
    if not found:
        return not_found(String("no run ", id))
    var known = False
    for i in instance_rows(db, id):
        if cluster_log_name(i) == name:
            known = True
    var dir = run_dir(found.value().pipeline, id)
    if not known or not dir:
        return not_found(String("run ", id, " has no log ", name))
    var path = String(dir, "/cluster/", name)
    var got = read_log(path)
    if not got[0] and not location_exists(path):
        return not_found(String("run ", id, " has no log ", name, " yet"))
    return Page(200, String(), got[0], "text/plain; charset=utf-8")
