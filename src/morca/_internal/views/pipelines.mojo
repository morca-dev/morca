"""Pipelines as the pages and their JSON read them: `PipelineRow` (a
registration with its schedule and live runs), its steps (`StepDef`), its
next fires, a keyed pipeline's counts (`KeyCounts`), its fill, and the
Resources card's summary of what its runs used (`UsageSummary`).
"""

from std.os import getenv

import morca._internal.db.pipelines_view as pipelines_db
from morca._internal.db.pipelines_view import (
    PipelineRow,
    StepDef,
    UsageSummary,
    comma_list,
)

from morca.civil import Civil, now
from morca._internal.config_show import (
    Shown,
    shown,
)
from morca._internal.coverage import Coverage, coverage
from morca.cron import CronExpr
from morca._internal.fill import FillStatus, fill_status
from morca._internal.follow import Follow, follow
from morca._internal.lineage import SnapshotRef
from morca._internal.db.fill_requests import requested
from morca._internal.db.live import live_runs
from morca._internal.recommend import Recommendation
from morca.schedule import Schedule
from morca._internal.queueing import (
    current_keys,
    done_keys,
    keep_keys,
    kept_keys,
)
from morca._internal.registered import (
    fill_key,
    fill_pipeline,
    registered,
)
from morca._internal.state import State
from morca.tz import Zone
from morca._internal.views.runs import (
    RunsPage,
    VersionRow,
    runs_page,
    runs_query,
    version_rows,
)
from morca._internal.views.start import StartPreview, start_preview


def utc_text(t: Int64) -> String:
    """Seconds since the epoch as `YYYY-MM-DDTHH:MM:SSZ`."""
    return String(Civil.of(t), "Z")


@fieldwise_init
struct Fire(Copyable, Movable):
    var at: String
    var local: String
    var partition: String


def next_fires(p: PipelineRow, after: Int64, count: Int) raises -> List[Fire]:
    var out = List[Fire]()
    if not p.cron:
        return out^
    var s = Schedule(CronExpr.parse(p.cron), Zone.load(p.tz))
    var t = after
    for _ in range(count):
        t = s.next_fire(t)
        var local = Civil.of(s.zone.to_local(t))
        var key = fill_key(p.kind, p.fills, local)
        out.append(Fire(utc_text(t), String(local), key))
    return out^


def pipeline_rows(mut db: State, name: String = "") raises -> List[PipelineRow]:
    """Every registered pipeline, or the one named."""
    var out = pipelines_db.pipeline_rows(db.conn, name)
    var t = now()
    for ref p in out:
        try:
            var f = next_fires(p, t, 1)
            if len(f) > 0:
                p.next_fire = f[0].at
                p.next_partition = f[0].partition
        except:
            pass
    return out^


def step_defs(mut db: State, name: String) raises -> List[StepDef]:
    return pipelines_db.step_defs(db.conn, name)


@fieldwise_init
struct KeyCounts(Copyable, Movable):
    """A keyed pipeline's keys and how far it is through them."""

    var dataset: String
    var snapshot: Int64
    var total: Int
    var done: Int
    var live: Int
    var failed: List[String]
    """Keys not done or in a live run, with a failed or skipped step."""
    var error: String
    """Why its keys couldn't be read, or empty."""
    var read_at: String
    """When `<binary> keys` printed them."""
    var note: String
    """Why they're older than they'd be, or empty."""


comptime _UI_KEYS_SECONDS = 10.0
"""How long the page waits for `<binary> keys` before showing the keys
last read, if any: it runs on the server's one thread."""


def _keys_seconds() -> Float64:
    """How old kept keys may be before the page reads them again: the
    scheduler's `MORCA_SENSE_SECONDS` (60)."""
    try:
        return Float64(getenv("MORCA_SENSE_SECONDS", "60"))
    except:
        return 60.0


def key_counts(mut db: State, name: String) raises -> KeyCounts:
    var ps = registered(db, name)
    if len(ps) == 0:
        return KeyCounts(
            "", -1, 0, 0, 0, List[String](), "not registered", "", ""
        )
    ref p = ps[0]
    # The keys last read (by the scheduler, or this page) while they're
    # fresh, so a view doesn't scan the keys column each time.
    var got: Tuple[Int64, List[String]]
    var note = String()
    var kept = kept_keys(db, name)
    if kept and kept.value().age < _keys_seconds():
        got = (kept.value().snapshot, kept.value().keys.copy())
    else:
        try:
            got = current_keys(p, _UI_KEYS_SECONDS)
            keep_keys(db, name, got)
            kept = kept_keys(db, name)
        except e:
            if not kept:
                return KeyCounts(
                    p.keys_dataset,
                    -1,
                    0,
                    0,
                    0,
                    List[String](),
                    String(e),
                    "",
                    "",
                )
            got = (kept.value().snapshot, kept.value().keys.copy())
            note = String("reading them again failed: ", e)
    var read_at = kept.value().read_at if kept else String()
    var done = done_keys(db, name, got[1])
    var live = live_runs(db.conn, name)
    var n_live = 0
    var open = String()
    for k in got[1]:
        if k in live:
            n_live += 1
        elif k not in done:
            open.write("," if open else "", k)
    var failed = List[String]()
    if open:
        failed = pipelines_db.failed_keys(db.conn, name, open)
    return KeyCounts(
        p.keys_dataset,
        got[0],
        len(got[1]),
        len(done),
        n_live,
        failed^,
        "",
        read_at,
        note,
    )


def pipeline_coverage(mut db: State, p: PipelineRow) -> Optional[Coverage]:
    """`p`'s coverage (`morca._internal.coverage`), None if it has none or it can't
    be read: a list of pipelines still shows the rest."""
    try:
        return coverage(db, p.name, p.kind, p.start, p.tz, p.fill_lag)
    except:
        return None


def fill_of(mut db: State, name: String) raises -> Optional[FillStatus]:
    """`name`'s fill (`morca._internal.fill`), if it fills its range or has fill runs
    from when it did."""
    var regs = registered(db, name)
    if len(regs) == 0:
        return None
    if not regs[0].fill.all:
        if not pipelines_db.has_fill_runs(db.conn, name) and name not in (
            requested(db.conn)
        ):
            return None
    var tx = db.conn.begin()
    var s = fill_status(tx, fill_pipeline(regs[0]), now(), regs[0].run_retries)
    tx.rollback()
    return s^


comptime USAGE_RUNS = 20
"""How many of a pipeline's latest measured runs its Resources card
summarizes."""


def usage_summary(mut db: State, name: String) raises -> UsageSummary:
    """The pipeline's latest `USAGE_RUNS` runs that recorded what they used,
    summarized."""
    return pipelines_db.usage_summary(db.conn, name, USAGE_RUNS)


@fieldwise_init
struct PipelineAsk(Copyable, Movable):
    """What a pipeline's page was asked for, from its URL's query: which
    tab (`?tab=`); Start runs' preview over `partitions` (`?preview=1`,
    `&rerun=1`, `&allow_append=1`); the month or year its coverage shows
    (`?cal=`) and which of its tabs (`?cov=`); the view of its steps shown
    without scripts (`?steps=`); and, in `url`, the page of its runs."""

    var name: String
    var partitions: String
    var rerun: Bool
    var preview: Bool
    var cal: String
    var allow_append: Bool
    var steps: String
    var tab: String
    var cov: String
    var url: String

    def shown_tab(self) -> String:
        """`overview`, `runs` or `operate`: as asked, or Operate for a
        preview or a coverage month that names no tab."""
        if self.tab == "runs" or self.tab == "operate":
            return self.tab
        if not self.tab and (
            self.preview or self.cal or self.cov or self.partitions
        ):
            return "operate"
        return "overview"


@fieldwise_init
struct NotRun(Copyable, Movable):
    """A snapshot a pipeline's sensor saw and couldn't run, and why."""

    var snapshot: SnapshotRef
    var at: String
    var error: String


struct PipelineView(Movable):
    """A pipeline as its page and its JSON show it, read once:
    `pipeline_json` (`morca._internal.api.pipelines`) and `pipeline_html`
    (`morca._internal.ui.pipeline`) both draw this. The JSON is the same on every
    tab."""

    var pipeline: PipelineRow
    var steps: List[StepDef]
    var fires: List[Fire]
    """Its next five fires, if it's scheduled."""
    var runs: RunsPage
    """The page of its runs `url` asks for."""
    var fill: Optional[FillStatus]
    var following: Optional[Follow]
    """How far a sensor is behind what it follows (`morca._internal.follow`)."""
    var usage: UsageSummary
    var learned: Optional[Recommendation]
    """The request its runs' peaks suggest (`morca._internal.recommend`), from its
    `morca config show`, applied where it asks for `auto`."""
    var versions: List[VersionRow]
    """The code it's run, newest first."""
    var configs: List[Shown]
    """What `morca config show <name>` prints (`morca._internal.config`)."""
    var keys: Optional[KeyCounts]
    """A keyed pipeline's counts."""
    var coverage: Optional[Coverage]
    """Its partitions or keys done of those it has (`morca._internal.coverage`)."""
    var not_run: List[NotRun]
    """The snapshots its sensor saw and couldn't run, latest first."""
    var start: Optional[StartPreview]
    """What Start runs would queue, when a preview was asked for."""

    def __init__(
        out self,
        var pipeline: PipelineRow,
        var runs: RunsPage,
        var usage: UsageSummary,
    ):
        self.pipeline = pipeline^
        self.steps = List[StepDef]()
        self.fires = List[Fire]()
        self.runs = runs^
        self.fill = None
        self.following = None
        self.usage = usage^
        self.learned = None
        self.versions = List[VersionRow]()
        self.configs = List[Shown]()
        self.keys = None
        self.coverage = None
        self.not_run = List[NotRun]()
        self.start = None


def pipeline_view(
    mut db: State, ask: PipelineAsk
) raises -> Optional[PipelineView]:
    """The pipeline `ask` names as its page shows it, or None if there's no
    such pipeline."""
    ref name = ask.name
    var ps = pipeline_rows(db, name)
    if len(ps) == 0:
        return None
    var v = PipelineView(
        ps[0].copy(),
        runs_page(db, runs_query(ask.url, "pipeline", name)),
        usage_summary(db, name),
    )
    ref p = v.pipeline
    if ask.preview and ask.partitions.strip():
        v.start = start_preview(
            db, name, ask.partitions, ask.rerun, ask.allow_append
        )
    v.steps = step_defs(db, name)
    try:
        v.fires = next_fires(p, now(), 5)
    except:
        pass
    v.fill = fill_of(db, name)
    v.following = follow(db, name, p.kind, p.start)
    v.versions = version_rows(db, pipeline=name)
    v.configs = shown(db, name)
    if len(v.configs) > 0:
        v.learned = v.configs[0].learned.copy()
    if p.kind == "keyed":
        v.keys = key_counts(db, name)
    # After the keys: their read keeps them in orca.keys, which this counts.
    v.coverage = pipeline_coverage(db, p)
    for x in pipelines_db.sense_errors(db.conn, name):
        v.not_run.append(
            NotRun(SnapshotRef(x.dataset, x.snapshot), x.at, x.error)
        )
    return v^
