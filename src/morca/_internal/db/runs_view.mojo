"""The runs lists' queries (`morca._internal.views.runs`): `/runs`, a pipeline's Runs
tab and the home page's recent runs read a page of `orca.runs` through a
`RunsFilter`, keyset by run id, and count what matches it.

`morca._internal.views.runs` parses a list's URL into its `RunsQuery` and hands its
filters over as a `RunsFilter`; `runs_where` turns those into the SQL
fragments and parameters each filter has always had, so nothing a URL says
reaches the SQL but as a bound parameter.
"""

from postgres import Connection, Params, Row

from morca._internal.db.live import stalled_sql


def utc_sql(col: StaticString) -> String:
    """SQL for a timestamptz as `YYYY-MM-DDTHH:MM:SSZ`, or `''`."""
    return String(
        "coalesce(to_char(",
        col,
        " AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), '')",
    )


def _int_or_zero(s: String) -> Int:
    try:
        return Int(s)
    except:
        return 0


@fieldwise_init
struct RunRecord(Copyable, Movable):
    """A run as the lists and its page read it (`morca._internal.views.runs.RunRow`):
    its row, what its attempts used and its latest start's request and
    grant."""

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
    var error: String
    var waiting: Int64
    """When a deferred run starts again (`retry_at`), 0 for others."""
    var seconds: Int
    var placement: String
    var held: String
    var peak: Int
    """Its attempts' largest peak resident bytes; -1 for none."""
    var cpu: Float64
    """Their CPU seconds summed; -1 for none."""
    var cpus: Float64
    """The most cores one kept busy; -1 for none."""
    var request_cpus: String
    var request_memory_gb: String
    var grant_cpus: Int
    var grant_memory_mb: Int
    var memory_limit_mb: Int
    var memory_max_mb: Int
    var memory_bytes: Int
    var request_source: String
    var request_runs: Int
    var waits_on: Int
    """The run whose concurrency key a queued one waits on (#397), or 0."""


comptime _WAITING = (
    "CASE WHEN status = 'deferred' THEN coalesce(retry_at, 0) ELSE 0 END"
)
"""SQL for when a deferred run starts again (`retry_at`), 0 for others."""


comptime _RUN_USAGE = (
    " LEFT JOIN LATERAL (SELECT max(a.peak_rss_bytes) AS peak,"
    " sum(a.cpu_seconds) AS cpu, max(a.peak_cpus) AS cpus FROM orca.attempts"
    " a JOIN orca.steps s ON s.id = a.step WHERE s.run = orca.runs.id) u ON"
    " true"
)
"""SQL joining a run (`orca.runs`) to what its attempts used, as `u`."""


comptime _USAGE_COLUMNS = (
    " coalesce(u.peak, -1) AS peak, coalesce(u.cpu, -1) AS cpu,"
    " coalesce(u.cpus, -1) AS cpus"
)


comptime _GRANT_COLUMNS = (
    " coalesce(request_cpus, '') AS request_cpus, coalesce(request_memory_gb,"
    " '') AS request_memory_gb, coalesce(grant_cpus, 0)::bigint AS"
    " grant_cpus, coalesce(grant_memory_mb, 0)::bigint AS grant_memory_mb,"
    " coalesce(memory_limit_mb, 0)::bigint AS memory_limit_mb,"
    " coalesce(memory_max_mb, 0)::bigint AS memory_max_mb, CASE WHEN status"
    " = 'running' THEN coalesce(memory_bytes, -1) ELSE -1 END::bigint AS"
    " memory_bytes, coalesce(request_source, '') AS request_source,"
    " coalesce(request_runs, 0)::bigint AS request_runs,"
)
"""SQL for a run's request and grant (`morca._internal.resources`), and where the
request came from (`morca._internal.recommend`)."""


comptime _SECONDS = (
    "coalesce(extract(epoch FROM coalesce(ended, now()) - started)::bigint, -1)"
)
"""SQL for how long a run ran, up to now if it hasn't ended; -1 before it
started."""


def _run_select() -> String:
    """`SELECT <a RunRecord's columns> FROM orca.runs <its usage>`."""
    return String(
        "SELECT id::text AS id, pipeline, partitions, trigger, status,",
        " starts::text AS starts, ",
        utc_sql("created"),
        " AS created, ",
        utc_sql("started"),
        " AS started, ",
        utc_sql("ended"),
        " AS ended, cancel_requested, coalesce(error, '') AS error, ",
        stalled_sql(),
        " AS stalled, ",
        _WAITING,
        " AS waiting, ",
        _SECONDS,
        " AS seconds, coalesce(placement, '') AS placement,",
        " coalesce(held, '') AS held, coalesce(waits_on, 0) AS waits_on,",
        _GRANT_COLUMNS,
        _USAGE_COLUMNS,
        " FROM orca.runs",
        _RUN_USAGE,
    )


def _record(r: Row, id: Int) raises -> RunRecord:
    return RunRecord(
        id,
        r.text("pipeline"),
        r.text("partitions"),
        r.text("trigger"),
        r.text("status"),
        _int_or_zero(r.text("starts")),
        r.text("created"),
        r.text("started"),
        r.text("ended"),
        r.bool("cancel_requested"),
        r.bool("stalled"),
        r.text("error"),
        r.int64("waiting"),
        Int(r.int64("seconds")),
        r.text("placement"),
        r.text("held"),
        Int(r.int64("peak")),
        r.float64("cpu"),
        r.float64("cpus"),
        r.text("request_cpus"),
        r.text("request_memory_gb"),
        Int(r.int64("grant_cpus")),
        Int(r.int64("grant_memory_mb")),
        Int(r.int64("memory_limit_mb")),
        Int(r.int64("memory_max_mb")),
        Int(r.int64("memory_bytes")),
        r.text("request_source"),
        Int(r.int64("request_runs")),
        Int(r.int64("waits_on")),
    )


@fieldwise_init
struct RunsFilter(Copyable, Movable):
    """A runs list's filters (`morca._internal.views.runs.RunsQuery.filter`), each
    empty or 0 when it isn't set, as `runs_where` binds them."""

    var pipeline: String
    var status: String
    """The statuses asked for, comma-separated."""
    var statuses: List[String]
    """`status`, each once."""
    var trigger: String
    var run: Int
    var batch: Int
    var since: String
    """`today`, or `<n>h` / `<n>d`, whose interval is `interval`."""
    var interval: String
    """`since` as a Postgres interval (`24 hours`)."""
    var start: String
    """Created at or after it, `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM[:SS]`."""
    var end: String
    """Created by the end of that day (or at or before that time)."""
    var key: String
    var key_like: String
    """`key` as a `LIKE` pattern when it is a glob, else empty."""


struct RunsWhere(Movable):
    """A runs list's filters as SQL over `orca.runs`: `sql` (` WHERE ...`)
    and its `params`, numbered in order, so a filter that isn't set adds
    nothing to the plan."""

    var sql: String
    var params: Params

    def __init__(out self):
        self.sql = String(" WHERE true")
        self.params = Params()

    def text(mut self, clause: StaticString, v: String):
        """`AND clause`, its `?` the next parameter, `v`."""
        self.sql.write(
            " AND ",
            String(clause).replace("?", String("$", len(self.params) + 1)),
        )
        self.params = self.params.copy().text(v)

    def int(mut self, clause: StaticString, v: Int):
        self.sql.write(
            " AND ",
            String(clause).replace("?", String("$", len(self.params) + 1)),
        )
        self.params = self.params.copy().int64(Int64(v))

    def next(self) -> String:
        """The next parameter's placeholder."""
        return String("$", len(self.params) + 1)


def runs_where(f: RunsFilter, with_status: Bool = True) -> RunsWhere:
    """The runs `f` lets through, with its statuses unless not
    `with_status` (for the counts of each)."""
    var w = RunsWhere()
    if f.pipeline:
        w.text("pipeline = ?", f.pipeline)
    if with_status and f.status:
        if len(f.statuses) == 1:
            w.text("status = ?", f.statuses[0])
        else:
            w.text("status = ANY(string_to_array(?, ','))", f.status)
    if f.trigger:
        w.text("trigger = ?", f.trigger)
    if f.run > 0:
        w.int("id = ?", f.run)
    if f.batch > 0:
        w.int("batch = ?", f.batch)
    if f.since == "today":
        w.sql.write(
            " AND created >= date_trunc('day', now() AT TIME ZONE 'UTC') AT"
            " TIME ZONE 'UTC'"
        )
    elif f.since:
        w.text("created >= now() - ?::interval", f.interval)
    if f.start:
        w.text("created >= (?::timestamp AT TIME ZONE 'UTC')", f.start)
    if f.end:
        if f.end.byte_length() == 10:
            w.text(
                "created < ((?::date + 1)::timestamp AT TIME ZONE 'UTC')", f.end
            )
        else:
            w.text("created <= (?::timestamp AT TIME ZONE 'UTC')", f.end)
    if f.key:
        if f.key_like:
            w.text(
                (
                    "EXISTS (SELECT 1 FROM unnest(string_to_array(partitions,"
                    " ',')) k WHERE k LIKE ?)"
                ),
                f.key_like,
            )
        else:
            w.text("strpos(lower(partitions), lower(?)) > 0", f.key)
    return w^


def run_records(
    mut conn: Connection,
    f: RunsFilter,
    limit: Int,
    before: Int = 0,
    after: Int = 0,
) raises -> List[RunRecord]:
    """The runs `f` lets through (`runs_where`), newest first, with ids
    under `before` if it's over 0; with `after` over 0, the `limit` runs
    just above it, oldest first."""
    var w = runs_where(f)
    if before > 0:
        w.int("orca.runs.id < ?", before)
    if after > 0:
        w.int("orca.runs.id > ?", after)
    var rows = conn.query(
        String(
            _run_select(),
            w.sql,
            " ORDER BY orca.runs.id ",
            "ASC" if after > 0 else "DESC",
            " LIMIT ",
            w.next(),
        ),
        w.params.copy().int64(Int64(limit)),
    )
    var out = List[RunRecord]()
    for r in rows:
        out.append(_record(r, _int_or_zero(r.text("id"))))
    return out^


def run_record(mut conn: Connection, id: Int) raises -> Optional[RunRecord]:
    """Run `id`, if there's one."""
    var rows = conn.query(
        String(_run_select(), " WHERE id = $1"),
        Params().int64(Int64(id)),
    )
    if len(rows) == 0:
        return None
    return _record(rows.row(0), id)


def runs_counted(
    mut conn: Connection, f: RunsFilter, top: Int
) raises -> Tuple[Int, Int]:
    """How many runs `f` lets through, and how many of them have an id of
    `top` or over (none when `top` isn't over 0)."""
    var w = runs_where(f)
    var counted = conn.query(
        String(
            "SELECT count(*) AS total, count(*) FILTER (WHERE ",
            w.next(),
            " > 0 AND id >= ",
            w.next(),
            ") AS newer FROM orca.runs",
            w.sql,
        ),
        w.params.copy().int64(Int64(top)),
    )
    return (
        Int(counted.row(0).int64("total")),
        Int(counted.row(0).int64("newer")),
    )


def status_counts(
    mut conn: Connection, f: RunsFilter
) raises -> List[Tuple[String, Int]]:
    """Each status's runs under `f`'s other filters, most first."""
    var ws = runs_where(f, with_status=False)
    var counts = List[Tuple[String, Int]]()
    for r in conn.query(
        String(
            "SELECT status, count(*) AS n FROM orca.runs",
            ws.sql,
            " GROUP BY status ORDER BY n DESC, status",
        ),
        ws.params.copy(),
    ):
        counts.append((r.text("status"), Int(r.int64("n"))))
    return counts^


def run_ids(
    mut conn: Connection, f: RunsFilter, limit: Int
) raises -> List[Int]:
    """The ids of the runs `f` lets through, newest first, at most
    `limit`."""
    var w = runs_where(f)
    var out = List[Int]()
    for r in conn.query(
        String(
            "SELECT id::bigint AS id FROM orca.runs",
            w.sql,
            " ORDER BY id DESC LIMIT ",
            w.next(),
        ),
        w.params.copy().int64(Int64(limit)),
    ):
        out.append(Int(r.int64("id")))
    return out^


def count_runs(mut conn: Connection, f: RunsFilter) raises -> Int:
    """How many runs `f` lets through."""
    var w = runs_where(f)
    return Int(
        conn.query(
            String("SELECT count(*) AS n FROM orca.runs", w.sql),
            w.params.copy(),
        )
        .row(0)
        .int64("n")
    )


def triggers_seen(mut conn: Connection) raises -> List[String]:
    """Every trigger a run has, by name: the trigger filter's options."""
    var out = List[String]()
    for r in conn.query(
        "SELECT DISTINCT trigger AS v FROM orca.runs ORDER BY v"
    ):
        out.append(r.text("v"))
    return out^


def pipeline_names(mut conn: Connection) raises -> List[String]:
    """Every registered pipeline's name, by name: the pipeline filter's
    options."""
    var out = List[String]()
    for r in conn.query("SELECT name FROM orca.pipelines ORDER BY name"):
        out.append(r.text("name"))
    return out^
