"""Runs as the pages and their JSON read them: `RunRow` with its grant
and what it used, its steps (`StepRow`), the tables they read and wrote
(`Touch`), its machines (`InstanceRow`) and code (`VersionRow`), a step's
attempts (`AttemptRow`), and a runs list's page (`RunsQuery`, `RunsPage`:
keyset by run id, so pages stay put as runs arrive).

The queries are `morca._internal.db.runs_view`'s (the lists) and
`morca._internal.db.run_view`'s (a run's page): a list's URL is parsed here into its
`RunsQuery`, whose filters go to the database as a `RunsFilter`.
"""

import morca._internal.db.run_view as run_db
import morca._internal.db.runs_view as runs_db
from morca._internal.db.run_view import (
    AttemptRecord,
    AuditRow,
    InstanceRow,
    StepRecord,
    Touch,
    VersionRow,
)
from morca._internal.db.runs_view import RunRecord, RunsFilter, utc_sql

from morca._internal.views.cluster import ClusterRow, cluster_rows
from morca._internal.handover import run_outdated
from morca._internal.html import (
    query_param,
    query_values,
    url_decode,
    url_encode,
)
from morca._internal.json import quote
from morca._internal.lineage import SnapshotRef
from morca._internal.logs import location_exists, run_dir
from morca._internal.metrics import InstanceMetrics, StepSpan, read_metrics
from morca._internal.resources import Grant
from morca._internal.state import State
from morca._internal.store import Usage
from morca.civil import Civil


def utc_text(t: Int64) -> String:
    """Seconds since the epoch as `YYYY-MM-DDTHH:MM:SSZ`."""
    return String(Civil.of(t), "Z")


@fieldwise_init
struct RunResources(Copyable, Movable):
    """What a run's latest start asked for and was granted
    (`morca._internal.resources`); empty and 0 for none."""

    var cpus: String
    var memory_gb: String
    var grant: Grant
    var limit_mb: Int
    """Its latest start's cgroup limit, `memory.high` (`morca._internal.cgroup`); 0
    for none."""
    var max_mb: Int
    """Its `memory.max`, past which the kernel kills its processes."""
    var memory_bytes: Int
    """Its cgroup's memory a few seconds ago while it runs; -1 else."""
    var source: String
    """Where its request came from (`morca._internal.recommend`): `declared`,
    `learned` or `default`; empty for none, or a start before morca kept
    it."""
    var runs: Int
    """Learned, how many runs it's from; else 0."""

    def any(self) -> Bool:
        return self.cpus != "" or self.memory_gb != ""

    def source_text(self) -> String:
        """`learned from 20 runs`, `default: auto, nothing learned`, or
        empty."""
        if self.source == "learned":
            return String(
                "learned from ",
                self.runs,
                " run" if self.runs == 1 else " runs",
            )
        if self.source == "default":
            return "default: auto, with nothing learned or learning off"
        return String()

    def limit_json(self) -> String:
        """`"memory_limit": {...}|null` for a run's JSON."""
        if self.limit_mb <= 0:
            return String('"memory_limit": null')
        return String(
            '"memory_limit": {"limit_mb": ',
            self.limit_mb,
            ', "max_mb": ',
            self.max_mb,
            ', "current_bytes": ',
            String(self.memory_bytes) if self.memory_bytes
            >= 0 else String("null"),
            "}",
        )

    def source_json(self) -> String:
        """`"request_source": {"source": .., "runs": ..}|null`."""
        if not self.source:
            return String('"request_source": null')
        return String(
            '"request_source": {"source": ',
            quote(self.source),
            ', "runs": ',
            String(self.runs) if self.runs > 0 else String("null"),
            ', "text": ',
            quote(self.source_text()),
            "}",
        )

    def json(self) -> String:
        """`"request": {...}|null, "grant": {...}|null, "request_source":
        ...` for a run's JSON."""
        if not self.any():
            return String(
                '"request": null, "grant": null, ', self.source_json()
            )
        return String(
            '"request": {"cpus": ',
            quote(self.cpus) if self.cpus else String("null"),
            ', "memory_gb": ',
            quote(self.memory_gb) if self.memory_gb else String("null"),
            "}, ",
            self.source_json(),
            ', "grant": {"cpus": ',
            String(self.grant.cpus) if self.grant.cpus else String("null"),
            ', "memory_mb": ',
            String(self.grant.memory_mb) if self.grant.memory_mb else String(
                "null"
            ),
            "}",
        )


@fieldwise_init
struct RunRow(Copyable, Movable):
    var id: Int
    var pipeline: String
    var partitions: String
    var trigger: String
    var status: String
    var starts: Int
    var created: String
    var started: String
    var ended: String
    var cancel_requested: Bool
    var stalled: Bool
    """`running` with no live process (`morca._internal.db.live.stalled_sql`)."""
    var error: String
    """Why the run ended without its steps saying so (`runs.error`)."""
    var waiting_until: String
    """When a deferred run starts again; empty for any other."""
    var seconds: Int
    """How long it ran (so far, if it's running); -1 before it started."""
    var placement: String
    """Where its latest start ran: `control` (the scheduler's host), `ec2`,
    `kubernetes` or `local`; empty before its first."""
    var held: String
    """Why the scheduler keeps it queued (`morca._internal.control`), or empty."""
    var usage: Usage
    """What its attempts used (`morca._internal.usage`): the largest peak, the CPU
    seconds summed and the most cores."""
    var resources: RunResources
    """What its latest start asked for and was granted (`morca._internal.resources`)."""
    var code_version: String
    """While it runs, the version it runs (`morca._internal.handover.version_label`);
    else empty."""
    var desired_code_version: String
    """While it runs, the version its pipeline is registered with now."""
    var outdated: String
    """While it runs on outdated code (`morca._internal.handover`), why: "newer
    version X is leading"; else empty."""
    var waits_on: Int
    """While it's queued, the run holding the concurrency key it waits on
    (#397); else 0."""


@fieldwise_init
struct StepRow(Copyable, Movable):
    var step: String
    var partition: String
    var status: String
    var attempts: Int
    var error: String
    var log: String
    var started: String
    var ended: String
    var attempt_id: Int
    """The latest attempt's ID, 0 before the first."""
    var from_run: Int
    """The run a rerun copied this step from, or 0."""
    var usage: Usage
    """What the latest attempt used."""
    var limit_mb: Int
    """The latest attempt's memory limit (`morca._internal.cgroup`); 0 for none."""
    var grant_mb: Int
    """Its start's memory grant (`morca._internal.resources`); 0 for none."""


def int_or_zero(s: String) -> Int:
    try:
        return Int(s)
    except:
        return 0


def _waiting(t: Int64) -> String:
    return utc_text(t) if t > 0 else String()


def _run_row(r: RunRecord) -> RunRow:
    """The row the pages show of `r`; its versions come after
    (`with_versions`)."""
    return RunRow(
        r.id,
        r.pipeline,
        r.partitions,
        r.trigger,
        r.status,
        r.starts,
        r.created,
        r.started,
        r.ended,
        r.cancel_requested,
        r.stalled,
        r.error,
        _waiting(r.waiting),
        r.seconds,
        r.placement,
        r.held,
        Usage(r.peak, r.cpu, r.cpus),
        RunResources(
            r.request_cpus,
            r.request_memory_gb,
            Grant(r.grant_cpus, r.grant_memory_mb),
            r.memory_limit_mb,
            r.memory_max_mb,
            r.memory_bytes,
            r.request_source,
            r.request_runs,
        ),
        String(),
        String(),
        String(),
        r.waits_on if r.status == "queued" else 0,
    )


def run_rows(
    mut db: State,
    q: RunsQuery,
    limit: Int = 100,
    before: Int = 0,
    after: Int = 0,
) raises -> List[RunRow]:
    """The runs `q`'s filters let through (`morca._internal.db.runs_view.runs_where`),
    newest first, with ids under `before` if it's over 0; with `after` over
    0, the `limit` runs just above it, oldest first."""
    var out = List[RunRow]()
    for r in runs_db.run_records(db.conn, q.filter(), limit, before, after):
        out.append(_run_row(r))
    for i in range(len(out)):
        with_versions(db, out[i])
    return out^


def with_versions(mut db: State, mut r: RunRow) raises:
    """Fills a running run's versions, and whether it's outdated
    (`morca._internal.handover`): one query per running run."""
    if r.status != "running":
        return
    var o = run_outdated(db.conn, r.id)
    r.code_version = o.mine
    r.desired_code_version = o.desired
    r.outdated = o.why


def version_rows(
    mut db: State, pipeline: String = "", id: Int = 0
) raises -> List[VersionRow]:
    """A pipeline's versions newest first, or the one with `id`."""
    return run_db.version_rows(db.conn, pipeline, id)


def run_version(mut db: State, run: Int) raises -> Optional[VersionRow]:
    """The version a run ran, if it recorded one."""
    var v = run_db.run_version_id(db.conn, run)
    if not v:
        return None
    var vs = version_rows(db, id=v)
    if len(vs) == 0:
        return None
    return vs[0].copy()


def instance_rows(mut db: State, run: Int) raises -> List[InstanceRow]:
    return run_db.instance_rows(db.conn, run)


def cluster_log_name(i: InstanceRow) -> String:
    """The instance's log's name under its run's `cluster/`."""
    return String(i.role, "-", i.id, ".log")


def step_spans(mut db: State, run: Int) raises -> List[StepSpan]:
    """The run's attempts on the wall clock, for the machines' steps lane."""
    var out = List[StepSpan]()
    for s in run_db.step_spans(db.conn, run):
        out.append(
            StepSpan(s.step, s.partition, s.status, s.start, s.end, s.attempt)
        )
    return out^


def step_rows(mut db: State, run: Int) raises -> List[StepRow]:
    """A run's steps in run order: what `status <run>` shows, with times."""
    var out = List[StepRow]()
    for s in run_db.step_records(db.conn, run):
        out.append(
            StepRow(
                s.step,
                s.partition,
                s.status,
                s.attempts,
                s.error,
                s.log,
                s.started,
                s.ended,
                s.attempt_id,
                s.from_run,
                Usage(s.peak, s.cpu, s.cpus),
                s.limit_mb,
                s.grant_mb,
            )
        )
    return out^


def touch_rows(mut db: State, run: Int) raises -> List[Touch]:
    return run_db.touch_rows(db.conn, run)


comptime RUNS_PAGE = 50
"""Runs to a page of `/runs`, unless `?limit=` (or the older `?n=`) says, at
most `_RUNS_PAGE_MAX`."""


comptime _RUNS_PAGE_MAX = 500


comptime _PIPELINE_RUNS_PAGE = 20
"""Runs to a page of a pipeline's Runs tab."""


comptime HOME_RUNS = 10
"""Recent runs on the home page."""


@fieldwise_init
struct RunsQuery(Copyable, Movable):
    """Which runs a list shows: its filters, how many to a page, and where
    the page is (keyset, by run id: under `before`, or the page just above
    `after`; neither is the newest page)."""

    var view: String
    """`list` (`/runs`), `pipeline` (a pipeline's Runs tab) or `home`."""
    var pipeline: String
    var status: String
    """A status, or several comma-separated (`?status=` given more than once
    is joined so): runs with any of them."""
    var trigger: String
    var size: Int
    var before: Int
    var after: Int
    var since: String
    """`?since=`: created in the last `<n>h` or `<n>d` (`1h`, `24h`, `7d`),
    or `today` (since midnight UTC)."""
    var start: String
    """`?from=`: created at or after it, `YYYY-MM-DD` or
    `YYYY-MM-DDTHH:MM[:SS]`, UTC."""
    var end: String
    """`?to=`: created by the end of that day (or at or before that time)."""
    var run: Int
    """`?run=`: only that run."""
    var key: String
    """`?key=`: runs with a partition that matches it: a glob (`2023-08-*`,
    `?` for one character) matched against each of its partitions, or else
    any part of them (`modular/` for a keyed pipeline's repositories)."""
    var batch: Int
    """`?batch=`: the runs queued together in that batch
    (`morca._internal.batches`)."""

    @staticmethod
    def newest(view: String, size: Int) -> Self:
        """The newest page of `view`'s runs, unfiltered."""
        return Self(view, "", "", "", size, 0, 0, "", "", "", 0, "", 0)

    def first(self) -> Bool:
        """Whether this is the newest page, which new runs join."""
        return self.before <= 0 and self.after <= 0

    def default_size(self) -> Int:
        if self.view == "pipeline":
            return _PIPELINE_RUNS_PAGE
        if self.view == "home":
            return HOME_RUNS
        return RUNS_PAGE

    def statuses(self) -> List[String]:
        """The statuses asked for, each once."""
        var out = List[String]()
        for s in self.status.split(","):
            var t = String(s.strip())
            if t and t not in out:
                out.append(t^)
        return out^

    def filtered(self) -> Bool:
        """Whether a filter is set (a pipeline's tab's own pipeline isn't
        one)."""
        return (
            (self.view != "pipeline" and self.pipeline != "")
            or self.status != ""
            or self.trigger != ""
            or self.since != ""
            or self.start != ""
            or self.end != ""
            or self.run > 0
            or self.key != ""
            or self.batch > 0
        )

    def unfiltered(self) -> Self:
        """The same list with no filters, at its newest page."""
        var q = Self.newest(self.view, self.size)
        if self.view == "pipeline":
            q.pipeline = self.pipeline
        return q^

    def at_newest(self) -> Self:
        """The same filters, at the newest page."""
        var q = self.copy()
        q.before = 0
        q.after = 0
        return q^

    def _filters(self, mut q: String):
        for f in [
            (
                String("pipeline"),
                self.pipeline if self.view != "pipeline" else String(),
            ),
            (String("status"), self.status),
            (String("trigger"), self.trigger),
            (String("from"), self.start),
            (String("to"), self.end),
            (String("since"), self.since),
            (String("key"), self.key),
            (
                String("run"),
                String(self.run) if self.run > 0 else String(),
            ),
            (
                String("batch"),
                String(self.batch) if self.batch > 0 else String(),
            ),
        ]:
            if f[1]:
                q.write("&" if q else "?", f[0], "=", url_encode(f[1]))

    def href(self, before: Int = 0, after: Int = 0) -> String:
        """This list's page under `before`, above `after`, or (neither) the
        newest, with its filters and page size (unless the default)."""
        var q = String("?tab=runs") if self.view == "pipeline" else String()
        self._filters(q)
        if self.size != self.default_size():
            q.write("&" if q else "?", "limit=", self.size)
        if before > 0:
            q.write("&" if q else "?", "before=", before)
        elif after > 0:
            q.write("&" if q else "?", "after=", after)
        if self.view == "pipeline":
            return String("/pipelines/", url_encode(self.pipeline), q)
        return String("/runs", q)

    def here(self) -> String:
        """The page this list is on: where its "Log in to ..." links come
        back to."""
        if self.view == "home":
            return String("/")
        return self.href(self.before, self.after)

    def fragment(self) -> String:
        """`/runs/table`: this page of the list, as the fragment it
        refreshes from, with its filters."""
        var q = String("?view=", self.view)
        if self.view == "pipeline":
            q.write("&pipeline=", url_encode(self.pipeline))
        self._filters(q)
        q.write("&limit=", self.size)
        if self.before > 0:
            q.write("&before=", self.before)
        elif self.after > 0:
            q.write("&after=", self.after)
        return String("/runs/table", q)

    def fields(self) -> List[Tuple[String, String]]:
        """The list as form fields (`view`, `pipeline`, the filters and
        `limit`), for a form that acts on the runs it shows."""
        var out: List[Tuple[String, String]] = [
            (String("view"), self.view),
            (String("pipeline"), self.pipeline),
        ]
        var q = String()
        self._filters(q)
        for pair in q.split("&"):
            var p = String(pair.removeprefix("?"))
            var eq = p.find("=")
            if eq > 0 and String(p[byte=:eq]) != "pipeline":
                out.append(
                    (String(p[byte=:eq]), url_decode(p[byte = eq + 1 :]))
                )
        if self.size != self.default_size():
            out.append((String("limit"), String(self.size)))
        return out^

    def filter(self) -> RunsFilter:
        """Its filters as the database binds them
        (`morca._internal.db.runs_view.runs_where`)."""
        return RunsFilter(
            self.pipeline,
            self.status,
            self.statuses(),
            self.trigger,
            self.run,
            self.batch,
            self.since,
            since_interval(self.since) if self.since != "today" else String(),
            self.start,
            self.end,
            self.key,
            key_like(self.key) if self.key else String(),
        )


def _digits(s: StringSlice, start: Int, n: Int) -> Bool:
    var b = s.as_bytes()
    if start + n > len(b):
        return False
    for i in range(start, start + n):
        if b[i] < 48 or b[i] > 57:
            return False
    return True


def _number(s: StringSlice, start: Int, n: Int) -> Int:
    """The `n` digits at `start` as a number (`_digits` says they are)."""
    var b = s.as_bytes()
    var v = 0
    for i in range(start, min(start + n, len(b))):
        v = v * 10 + Int(b[i]) - 48
    return v


def moment(s: String) -> String:
    """`s` as a UTC time the filters take, `YYYY-MM-DD` or
    `YYYY-MM-DDTHH:MM[:SS]` (a space for the `T`, a `Z` at the end and
    `HH:MM:SS` all allowed), or empty if it's neither."""
    var t = String(s.strip().removesuffix("Z").removesuffix("z"))
    var b = t.as_bytes()
    var n = len(b)
    if not (
        n >= 10
        and _digits(t, 0, 4)
        and b[4] == 45
        and _digits(t, 5, 2)
        and b[7] == 45
        and _digits(t, 8, 2)
    ):
        return String()
    var month = _number(t, 5, 2)
    var day = _number(t, 8, 2)
    if month < 1 or month > 12 or day < 1 or day > 31:
        return String()
    if n == 10:
        return t^
    if not (
        (n == 16 or n == 19)
        and (b[10] == 84 or b[10] == 32)
        and _digits(t, 11, 2)
        and b[13] == 58
        and _digits(t, 14, 2)
    ):
        return String()
    if n == 19 and not (b[16] == 58 and _digits(t, 17, 2)):
        return String()
    var hour = _number(t, 11, 2)
    var minute = _number(t, 14, 2)
    if hour > 23 or minute > 59:
        return String()
    return String(t[byte=:10], "T", t[byte=11:])


def since_interval(since: String) -> String:
    """`?since=`'s `<n>h` or `<n>d` as a Postgres interval (`24 hours`), or
    empty if it isn't one (`today` is its own)."""
    var b = since.as_bytes()
    var n = len(b)
    if n < 2 or n > 5 or not _digits(since, 0, n - 1):
        return String()
    var count = _number(since, 0, n - 1)
    if count <= 0:
        return String()
    if b[n - 1] == 104 and count <= 24 * 366:
        return String(count, " hours")
    if b[n - 1] == 100 and count <= 3660:
        return String(count, " days")
    return String()


def key_like(key: String) -> String:
    """A glob of partitions (`*` any characters, `?` one) as a `LIKE`
    pattern, with `%`, `_` and `\\` taken as themselves; empty if it has no
    `*` or `?`."""
    if "*" not in key and "?" not in key:
        return String()
    var out = String()
    for c in key.codepoint_slices():
        if c == "*":
            out.write("%")
        elif c == "?":
            out.write("_")
        elif c == "%" or c == "_" or c == "\\":
            out.write("\\", c)
        else:
            out.write(c)
    return out^


def runs_query(url: String, view: String, pipeline: String = "") -> RunsQuery:
    """The list `url` asks for: `view`'s, filtered by `?pipeline=` (or, for a
    pipeline's tab, `pipeline`), `?status=` (one or more), `?trigger=`,
    `?since=`, `?from=`, `?to=`, `?run=`, `?key=` and `?batch=`, `?limit=` (or `?n=`)
    to a page, at `?before=` or `?after=`. A time or `since` that isn't one
    is left out."""
    var v = view if (view == "pipeline" or view == "home") else String("list")
    var q = RunsQuery.newest(v, 0)
    q.pipeline = pipeline if v == "pipeline" else query_param(url, "pipeline")
    if v != "home":
        var statuses = String()
        for s in query_values(url, "status"):
            if s.strip():
                statuses.write("," if statuses else "", s.strip())
        q.status = statuses^
        q.status = String(",").join(q.statuses())
        q.trigger = query_param(url, "trigger")
        var since = String(query_param(url, "since").strip())
        if since == "today" or since_interval(since):
            q.since = since^
        q.start = moment(query_param(url, "from"))
        q.end = moment(query_param(url, "to"))
        q.run = max(
            0, int_or_zero(String(query_param(url, "run").strip().lstrip("#")))
        )
        q.key = String(query_param(url, "key").strip())
        q.batch = max(0, int_or_zero(String(query_param(url, "batch").strip())))
    var n = int_or_zero(query_param(url, "limit"))
    if n <= 0:
        n = int_or_zero(query_param(url, "n"))
    q.size = q.default_size() if n <= 0 else min(n, _RUNS_PAGE_MAX)
    if v != "home":
        q.before = max(0, int_or_zero(query_param(url, "before")))
        q.after = 0 if q.before > 0 else max(
            0, int_or_zero(query_param(url, "after"))
        )
    return q^


struct RunsPage(Movable):
    """A page of a runs list, newest first, with how many runs that match
    are newer and older than it, and how many of each status match its
    other filters."""

    var q: RunsQuery
    """As asked, but with no `after` when the page above it is the newest."""
    var rows: List[RunRow]
    var total: Int
    var newer: Int
    var older: Int
    var counts: List[Tuple[String, Int]]
    """Each status's runs under the list's other filters, most first; empty
    for the home page's."""

    def __init__(
        out self,
        var q: RunsQuery,
        var rows: List[RunRow],
        total: Int,
        newer: Int,
        older: Int,
        var counts: List[Tuple[String, Int]],
    ):
        self.q = q^
        self.rows = rows^
        self.total = total
        self.newer = newer
        self.older = older
        self.counts = counts^

    def count_of(self, status: String) -> Int:
        for c in self.counts:
            if c[0] == status:
                return c[1]
        return 0

    def live(self) -> Bool:
        """Whether a run on it is queued or running."""
        for r in self.rows:
            if live_status(r.status):
                return True
        return False

    def newer_href(self) -> String:
        """The page above this one (the newest, if that's within a page),
        or empty if this is the newest."""
        if self.newer <= 0:
            return String()
        if self.newer <= self.q.size or len(self.rows) == 0:
            return self.q.href()
        return self.q.href(after=self.rows[0].id)

    def older_href(self) -> String:
        """The page under this one, or empty if this is the last."""
        if self.older <= 0 or len(self.rows) == 0:
            return String()
        return self.q.href(before=self.rows[len(self.rows) - 1].id)


def runs_page(mut db: State, var q: RunsQuery) raises -> RunsPage:
    """The page of runs `q` asks for, and the counts around it. Paged by id
    (keyset), so a page stays put while new runs arrive and each query reads
    one range of an index (`orca.runs` by id, `runs_pipeline_id`, or with
    a status `runs_status_id` and `runs_pipeline_status_id`)."""
    var rs: List[RunRow]
    if q.after > 0:
        # The `size` runs just above `after`, read upwards; if there aren't
        # more than that, the page is the newest one.
        rs = run_rows(db, q, limit=q.size + 1, after=q.after)
        if len(rs) > q.size:
            _ = rs.pop()
            rs.reverse()
        else:
            q.after = 0
            rs = run_rows(db, q, limit=q.size)
    else:
        rs = run_rows(db, q, limit=q.size, before=q.before)
    if q.view == "home":
        return RunsPage(q^, rs^, len(rs), 0, 0, [])
    # How many match, and how many of them are above this page.
    var top = rs[0].id + 1 if len(rs) > 0 else q.before
    var f = q.filter()
    var counted = runs_db.runs_counted(db.conn, f, top)
    var total = counted[0]
    var newer = counted[1]
    var older = max(0, total - newer - len(rs))
    # Each status's, under the other filters.
    var counts = runs_db.status_counts(db.conn, f)
    return RunsPage(q^, rs^, total, newer, older, counts^)


comptime BULK_MAX = 2000
"""The most runs one action from a list does: more is refused, to be
narrowed with the filters."""


def run_ids(mut db: State, q: RunsQuery, limit: Int) raises -> List[Int]:
    """The ids of the runs `q`'s filters let through, newest first, at most
    `limit` (its page and size aside)."""
    return runs_db.run_ids(db.conn, q.filter(), limit)


def count_runs(mut db: State, q: RunsQuery) raises -> Int:
    """How many runs `q`'s filters let through."""
    return runs_db.count_runs(db.conn, q.filter())


def live_status(status: String) -> Bool:
    """Whether a run or attempt with this status can still change."""
    return status == "queued" or status == "running"


def timeline_path(mut db: State, r: RunRow) raises -> String:
    """The run's Dista timeline, if it left one: beside its attempts' logs,
    or in its directory under this process's MORCA_LOGS."""
    var dirs = List[String]()
    var found = run_db.first_log(db.conn, r.id)
    if found:
        # <dir>/<step>/<partition>/<attempt>.log
        var log = found.value()
        var d = log
        for _ in range(3):
            var at = d.rfind("/")
            if at < 0:
                break
            var up = String(d[byte=:at])
            d = up^
        dirs.append(d)
    var own = run_dir(r.pipeline, r.id)
    if own:
        dirs.append(own)
    for d in dirs:
        var path = String(d, "/timeline.json")
        if location_exists(path):
            return path
    return ""


@fieldwise_init
struct AttemptRow(Copyable, Movable):
    var id: Int
    var run: Int
    var pipeline: String
    var step: String
    var partition: String
    var attempt: Int
    var status: String
    var host: String
    var started: String
    var ended: String
    var error: String
    var log: String
    var usage: Usage
    var limit_mb: Int
    """Its memory limit (`morca._internal.cgroup`); 0 for none."""
    var grant_mb: Int
    """Its start's memory grant (`morca._internal.resources`); 0 for none."""


def _attempt_rows(run: Int, rs: List[AttemptRecord]) -> List[AttemptRow]:
    var out = List[AttemptRow]()
    for r in rs:
        out.append(
            AttemptRow(
                r.id,
                run,
                r.pipeline,
                r.step,
                r.partition,
                r.attempt,
                r.status,
                r.host,
                r.started,
                r.ended,
                r.error,
                r.log,
                Usage(r.peak, r.cpu, r.cpus),
                r.limit_mb,
                r.grant_mb,
            )
        )
    return out^


def attempt_rows(mut db: State, run: Int, id: Int) raises -> List[AttemptRow]:
    """Attempt `id` of run `run`, or none if the run has no such attempt."""
    return _attempt_rows(run, run_db.attempt_record(db.conn, run, id))


def step_attempt_rows(
    mut db: State, run: Int, id: Int
) raises -> List[AttemptRow]:
    """Every attempt of the step attempt `id` is of, in run `run`, in
    order."""
    return _attempt_rows(run, run_db.step_attempt_records(db.conn, run, id))


def runs_one(mut db: State, id: Int) raises -> Optional[RunRow]:
    var found = runs_db.run_record(db.conn, id)
    if not found:
        return None
    var row = _run_row(found.value())
    with_versions(db, row)
    return row^


struct RunView(Movable):
    """A run as its page and its JSON show it, read once: `run_json`
    (`morca._internal.api.runs`) and `run_html` (`morca._internal.ui.run`) both draw this.
    """

    var run: RunRow
    var registry_hash: String
    """The code it ran (its pipeline's registration then)."""
    var current_code: Bool
    """Whether its pipeline is still registered with that code."""
    var rebuild: Int
    """The rebuild it's part of, or 0."""
    var batch: Int
    """The batch it was queued in (`morca._internal.batches`), or 0."""
    var batch_runs: Int
    """How many runs that batch has."""
    var version: Optional[VersionRow]
    var cpu_millis: Int
    """What its pods asked for, on Kubernetes (0 elsewhere)."""
    var seconds: Int
    """How long it ran, or has run so far."""
    var sensed: List[SnapshotRef]
    """The snapshots that started it, for a sensor's run."""
    var steps: List[StepRow]
    var touches: List[Touch]
    var instances: List[InstanceRow]
    var cluster: List[ClusterRow]
    """The workers its dista cluster spread over (`morca._internal.views.cluster`)."""
    var metrics: List[InstanceMetrics]
    var prev: Int64
    """The pipeline's run before it, or 0."""
    var next: Int64
    """The pipeline's run after it, or 0."""
    var actions: List[AuditRow]

    def __init__(out self, var run: RunRow):
        self.run = run^
        self.registry_hash = String()
        self.current_code = False
        self.rebuild = 0
        self.batch = 0
        self.batch_runs = 0
        self.version = None
        self.cpu_millis = 0
        self.seconds = 0
        self.sensed = List[SnapshotRef]()
        self.steps = List[StepRow]()
        self.touches = List[Touch]()
        self.instances = List[InstanceRow]()
        self.cluster = List[ClusterRow]()
        self.metrics = List[InstanceMetrics]()
        self.prev = 0
        self.next = 0
        self.actions = List[AuditRow]()


def run_view(mut db: State, id: Int) raises -> Optional[RunView]:
    """Run `id` as its page shows it, or None if there's no such run."""
    var found = runs_one(db, id)
    if not found:
        return None
    var v = RunView(found.take())
    ref r = v.run
    v.steps = step_rows(db, id)
    v.touches = touch_rows(db, id)
    var current = run_db.pipeline_hash(db.conn, r.pipeline)
    var row = run_db.run_facts(db.conn, id)
    v.registry_hash = row.registry_hash
    v.current_code = v.registry_hash == current
    v.rebuild = row.rebuild
    v.batch = row.batch
    v.batch_runs = row.batch_runs
    if row.version:
        var vs = version_rows(db, id=row.version)
        if len(vs) > 0:
            v.version = vs[0].copy()
    v.cpu_millis = row.cpu_millis
    v.seconds = row.seconds
    for x in run_db.sensed(db.conn, id):
        v.sensed.append(SnapshotRef(x[0], x[1]))
    v.instances = instance_rows(db, id)
    v.cluster = cluster_rows(db, id)
    v.metrics = read_metrics(r.pipeline, id)
    # The pipeline's runs in order (all triggers, fills too).
    var nb = run_db.neighbours(db.conn, r.pipeline, r.id)
    v.prev = nb[0]
    v.next = nb[1]
    v.actions = run_db.audit_rows(db.conn, id)
    return v^
