"""The run page's queries (`morca._internal.views.runs`, `morca._internal.ui.run`,
`morca._internal.ui.attempt`): a run's steps, attempts, the tables they touched, its
machines, its dista cluster, its code's versions, who acted on it, and what
its cards show of its row of `orca.runs`.
"""

from postgres import Connection, Params

from morca._internal.db.runs_view import utc_sql

comptime _TS = '\'YYYY-MM-DD"T"HH24:MI:SS"Z"\''


def _int_or_zero(s: String) -> Int:
    try:
        return Int(s)
    except:
        return 0


# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------


@fieldwise_init
struct VersionRow(Copyable, Movable):
    """A version of a pipeline's code (`morca._internal.source`)."""

    var id: Int
    var registry_hash: String
    var source: String
    var commit: String
    var dirty: Bool
    var image: String
    var first_seen: String
    var last_seen: String
    var runs: Int
    var locations: String
    """Where its functions are (`morca._internal.locate`), as JSON, or empty."""


def version_rows(
    mut conn: Connection, pipeline: String = "", id: Int = 0
) raises -> List[VersionRow]:
    """A pipeline's versions newest first, or the one with `id`. A version
    with no locations of its own has those of the same code at the same
    source and commit: a run records its version with the image it runs
    in, which can differ from the one `morca register` mapped (#583)."""
    var rows = conn.query(
        String(
            "SELECT v.id, v.registry_hash, v.source, v.commit_sha, v.dirty,",
            " v.image, ",
            utc_sql("v.first_seen"),
            " AS first_seen, ",
            utc_sql("v.last_seen"),
            " AS last_seen, (SELECT count(*) FROM orca.runs r WHERE r.version",
            " = v.id) AS runs, coalesce(v.locations::text, (SELECT",
            " w.locations::text FROM orca.pipeline_versions w WHERE",
            " w.pipeline = v.pipeline AND w.registry_hash = v.registry_hash",
            " AND w.source = v.source AND w.commit_sha = v.commit_sha AND",
            " w.dirty = v.dirty AND w.locations IS NOT NULL ORDER BY w.id",
            " DESC LIMIT 1), '') AS locations",
            " FROM orca.pipeline_versions v WHERE ($1 = '' OR",
            " v.pipeline = $1) AND ($2 = 0 OR v.id = $2) ORDER BY v.id DESC",
        ),
        Params().text(pipeline).int64(Int64(id)),
    )
    var out = List[VersionRow]()
    for r in rows:
        out.append(
            VersionRow(
                Int(r.int64("id")),
                r.text("registry_hash"),
                r.text("source"),
                r.text("commit_sha"),
                r.bool("dirty"),
                r.text("image"),
                r.text("first_seen"),
                r.text("last_seen"),
                Int(r.int64("runs")),
                r.text("locations"),
            )
        )
    return out^


def run_version_id(mut conn: Connection, run: Int) raises -> Int:
    """The version a run ran, or 0 if it recorded none (or there's no such
    run)."""
    var rows = conn.query(
        "SELECT coalesce(version, 0) AS v FROM orca.runs WHERE id = $1",
        Params().int64(Int64(run)),
    )
    if len(rows) == 0:
        return 0
    return Int(rows.row(0).int64("v"))


# ---------------------------------------------------------------------------
# Machines and the cluster
# ---------------------------------------------------------------------------


@fieldwise_init
struct InstanceRow(Copyable, Movable):
    """An instance a run ran on (`orca.instances`)."""

    var id: String
    var start: Int
    var role: String
    var instance_type: String
    var market: String
    var launched: String
    var ended: String
    var why: String
    var from_start: Float64
    """Seconds from the run's start to its launch."""
    var to_end: Float64
    """Seconds from the run's start to its end, or to now."""
    var procs: Int
    """The dista worker processes it ran (`--worker-procs`)."""


def instance_rows(mut conn: Connection, run: Int) raises -> List[InstanceRow]:
    var rows = conn.query(
        String(
            "SELECT i.id, i.start, i.role, i.instance_type, i.market, ",
            utc_sql("i.launched"),
            " AS launched, ",
            utc_sql("i.ended"),
            " AS ended, coalesce(i.why, '') AS why,",
            " coalesce(i.procs, 1) AS procs,",
            " extract(epoch FROM i.launched - coalesce(r.started,",
            " i.launched))::float8 AS from_start, extract(epoch FROM",
            " coalesce(i.ended, now()) - coalesce(r.started,",
            " i.launched))::float8 AS to_end FROM orca.instances i JOIN",
            " orca.runs r ON r.id = i.run WHERE i.run = $1 ORDER BY",
            " i.launched, i.role, i.id",
        ),
        Params().int64(Int64(run)),
    )
    var out = List[InstanceRow]()
    for r in rows:
        out.append(
            InstanceRow(
                r.text("id"),
                Int(r.int64("start")),
                r.text("role"),
                r.text("instance_type"),
                r.text("market"),
                r.text("launched"),
                r.text("ended"),
                r.text("why"),
                r.float64("from_start"),
                r.float64("to_end"),
                Int(r.int64("procs")),
            )
        )
    return out^


def shared_runs(mut conn: Connection, run: Int) raises -> Int:
    """The scheduler's own runs (local and control-placed) that ran at the
    same time as `run`."""
    return Int(
        conn.query(
            (
                "SELECT count(*) AS n FROM orca.runs o JOIN orca.runs r ON"
                " r.id = $1 WHERE o.id <> r.id AND o.started IS NOT NULL"
                " AND r.started IS NOT NULL AND o.started < coalesce("
                "r.ended, now()) AND coalesce(o.ended, now()) > r.started"
                " AND coalesce(o.placement, '') IN ('local', 'control')"
            ),
            Params().int64(Int64(run)),
        )
        .row(0)
        .int64("n")
    )


@fieldwise_init
struct ClusterRow(Copyable, Movable):
    var role: String
    """`head` (the worker that started the run) or `member`."""
    var start: Int
    var worker: String
    """The worker's name, else its token's label."""
    var address: String
    """The head's `host:port`; empty for a member."""
    var grant_cpus: Int
    var grant_memory_mb: Int
    var joined: String
    var ended: String
    var why: String


def cluster_rows(mut conn: Connection, run: Int) raises -> List[ClusterRow]:
    """Run `run`'s cluster: its head at its current start, if it spread,
    then every member it had, each start's, in the order they joined. Empty
    for a run on one machine."""
    var out = List[ClusterRow]()
    var head = conn.query(
        String(
            "SELECT r.starts, coalesce(w.name, w.label, '') AS worker,",
            " r.cluster_head, coalesce(r.grant_cpus, 0) AS cpus,",
            " coalesce(r.grant_memory_mb, 0) AS mb, coalesce(to_char(r.started",
            " AT TIME ZONE 'UTC', ",
            _TS,
            "), '') AS joined, coalesce(to_char(r.ended AT TIME ZONE 'UTC', ",
            _TS,
            "), '') AS ended FROM orca.runs r LEFT JOIN orca.workers w ON w.id",
            " = r.worker WHERE r.id = $1 AND r.cluster_head IS NOT NULL",
        ),
        Params().int64(Int64(run)),
    )
    for r in head:
        out.append(
            ClusterRow(
                "head",
                Int(r.int64("starts")),
                r.text("worker"),
                r.text("cluster_head"),
                Int(r.int64("cpus")),
                Int(r.int64("mb")),
                r.text("joined"),
                r.text("ended"),
                "",
            )
        )
    for r in conn.query(
        String(
            "SELECT m.start, coalesce(w.name, w.label, '') AS worker,",
            " coalesce(m.grant_cpus, 0) AS cpus, coalesce(m.grant_memory_mb,",
            " 0) AS mb, to_char(m.joined AT TIME ZONE 'UTC', ",
            _TS,
            ") AS joined, coalesce(to_char(m.ended AT TIME ZONE 'UTC', ",
            _TS,
            "), '') AS ended, coalesce(m.why, '') AS why FROM",
            " orca.run_members m LEFT JOIN orca.workers w ON w.id = m.worker",
            " WHERE m.run = $1 ORDER BY m.id",
        ),
        Params().int64(Int64(run)),
    ):
        out.append(
            ClusterRow(
                "member",
                Int(r.int64("start")),
                r.text("worker"),
                "",
                Int(r.int64("cpus")),
                Int(r.int64("mb")),
                r.text("joined"),
                r.text("ended"),
                r.text("why"),
            )
        )
    return out^


# ---------------------------------------------------------------------------
# Steps and attempts
# ---------------------------------------------------------------------------


@fieldwise_init
struct AttemptSpan(Copyable, Movable):
    """An attempt on the wall clock (`morca._internal.metrics.StepSpan`)."""

    var step: String
    var partition: String
    var status: String
    var start: Float64
    var end: Float64
    var attempt: Int


def step_spans(mut conn: Connection, run: Int) raises -> List[AttemptSpan]:
    """The run's attempts on the wall clock, for the machines' steps lane."""
    var out = List[AttemptSpan]()
    for r in conn.query(
        (
            "SELECT s.step, s.partition, a.status, a.id::text AS id,"
            " extract(epoch FROM a.started)::float8 AS t0, extract(epoch FROM"
            " coalesce(a.ended, now()))::float8 AS t1 FROM orca.attempts a JOIN"
            " orca.steps s ON s.id = a.step WHERE s.run = $1 ORDER BY s.ord,"
            " a.started"
        ),
        Params().int64(Int64(run)),
    ):
        out.append(
            AttemptSpan(
                r.text("step"),
                r.text("partition"),
                r.text("status"),
                r.float64("t0"),
                r.float64("t1"),
                _int_or_zero(r.text("id")),
            )
        )
    return out^


@fieldwise_init
struct StepRecord(Copyable, Movable):
    """A run's step as `morca._internal.views.runs.StepRow` shows it, with its latest
    attempt's usage as columns (-1 where unknown)."""

    var step: String
    var partition: String
    var status: String
    var attempts: Int
    var error: String
    var log: String
    var started: String
    var ended: String
    var attempt_id: Int
    var from_run: Int
    var peak: Int
    var cpu: Float64
    var cpus: Float64
    var limit_mb: Int
    var grant_mb: Int
    var swap: Int
    """Its latest attempt's swap peak (#282), and of it in zswap; -1 for
    unknown."""
    var zswapped: Int
    var working_set_mb: Int
    """What a probe measured (#281); 0 for none."""


def step_records(mut conn: Connection, run: Int) raises -> List[StepRecord]:
    """A run's steps in run order: what `status <run>` shows, with times."""
    var rows = conn.query(
        String(
            "SELECT s.step, s.partition, s.status, coalesce(s.error, '') AS",
            " error, (SELECT count(*) FROM orca.attempts a WHERE a.step =",
            " s.id)::text AS attempts, coalesce((SELECT a.log FROM",
            " orca.attempts a WHERE a.step = s.id ORDER BY a.attempt DESC",
            " LIMIT 1), '') AS log, ",
            utc_sql(
                "(SELECT min(a.started) FROM orca.attempts a WHERE a.step ="
                " s.id)"
            ),
            " AS started, ",
            utc_sql(
                "(SELECT max(a.ended) FROM orca.attempts a WHERE a.step = s.id)"
            ),
            " AS ended, coalesce((SELECT a.id FROM orca.attempts a WHERE",
            " a.step = s.id ORDER BY a.attempt DESC LIMIT 1), 0)::text AS",
            " attempt_id, coalesce((SELECT c.run FROM orca.steps c WHERE c.id",
            " = s.copied_from), 0)::text AS from_run, coalesce(u.peak, -1) AS",
            " peak, coalesce(u.cpu, -1) AS cpu, coalesce(u.cpus, -1) AS cpus,",
            " coalesce(u.limit_mb, 0) AS limit_mb, coalesce(u.grant_mb, 0) AS",
            " grant_mb, coalesce(u.swap, -1) AS swap, coalesce(u.zswapped, -1)",
            " AS zswapped, coalesce(u.ws, 0) AS ws FROM orca.steps s LEFT JOIN",
            " LATERAL (SELECT a.peak_rss_bytes AS peak, a.cpu_seconds AS cpu,",
            " a.peak_cpus AS cpus, a.memory_limit_mb AS limit_mb,",
            " a.grant_memory_mb AS grant_mb, a.memory_swap_peak_bytes AS swap,",
            " a.memory_zswapped_peak_bytes AS zswapped, a.working_set_mb AS ws",
            " FROM orca.attempts a WHERE a.step = s.id ORDER BY",
            " a.attempt DESC",
            " LIMIT 1) u ON true WHERE s.run = $1 ORDER BY s.ord, s.id",
        ),
        Params().int64(Int64(run)),
    )
    var out = List[StepRecord]()
    for r in rows:
        out.append(
            StepRecord(
                r.text("step"),
                r.text("partition"),
                r.text("status"),
                _int_or_zero(r.text("attempts")),
                r.text("error"),
                r.text("log"),
                r.text("started"),
                r.text("ended"),
                _int_or_zero(r.text("attempt_id")),
                _int_or_zero(r.text("from_run")),
                Int(r.int64("peak")),
                r.float64("cpu"),
                r.float64("cpus"),
                Int(r.int64("limit_mb")),
                Int(r.int64("grant_mb")),
                Int(r.int64("swap")),
                Int(r.int64("zswapped")),
                Int(r.int64("ws")),
            )
        )
    return out^


@fieldwise_init
struct Touch(Copyable, Movable):
    """A table a step read or committed to."""

    var step: String
    var partition: String
    var kind: String
    """`read` or `commit`."""
    var table: String
    var snapshot: String
    var dataset: String
    """Empty for a table outside the warehouse."""


def touch_rows(mut conn: Connection, run: Int) raises -> List[Touch]:
    var rows = conn.query(
        (
            "SELECT st.step, st.partition, x.kind, x.table_name,"
            " x.snapshot_id::text AS snapshot, coalesce(x.dataset, '') AS"
            " dataset FROM (SELECT attempt, 'read' AS kind, table_name,"
            " snapshot_id, dataset FROM orca.reads UNION ALL SELECT attempt,"
            " 'commit', table_name, snapshot_id, dataset FROM orca.commits) x"
            " JOIN orca.attempts a ON a.id = x.attempt JOIN orca.steps st ON"
            " st.id = a.step WHERE st.run = $1 ORDER BY st.ord, st.id, a.id"
        ),
        Params().int64(Int64(run)),
    )
    var out = List[Touch]()
    for r in rows:
        out.append(
            Touch(
                r.text("step"),
                r.text("partition"),
                r.text("kind"),
                r.text("table_name"),
                r.text("snapshot"),
                r.text("dataset"),
            )
        )
    return out^


def first_log(mut conn: Connection, run: Int) raises -> Optional[String]:
    """An attempt's log of the run, if one left a log."""
    var rows = conn.query(
        (
            "SELECT a.log FROM orca.attempts a JOIN orca.steps s ON s.id ="
            " a.step WHERE s.run = $1 AND a.log IS NOT NULL AND a.log <> ''"
            " LIMIT 1"
        ),
        Params().int64(Int64(run)),
    )
    if len(rows) == 0:
        return None
    return rows.row(0).text("log")


@fieldwise_init
struct AttemptRecord(Copyable, Movable):
    """An attempt as `morca._internal.views.runs.AttemptRow` shows it, with its usage
    as columns (-1 where unknown)."""

    var id: Int
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
    var peak: Int
    var cpu: Float64
    var cpus: Float64
    var limit_mb: Int
    var grant_mb: Int
    var swap: Int
    """Its swap peak (#282), and of it in zswap; -1 for unknown."""
    var zswapped: Int
    var working_set_mb: Int
    """What a probe measured (#281); 0 for none."""


def _attempts(
    mut conn: Connection, run: Int, cond: StaticString, arg: Int
) raises -> List[AttemptRecord]:
    var rows = conn.query(
        String(
            "SELECT a.id::text AS id, r.pipeline, s.step, s.partition,",
            " a.attempt::text AS attempt, a.status, a.host, ",
            utc_sql("a.started"),
            " AS started, ",
            utc_sql("a.ended"),
            " AS ended, coalesce(a.error, '') AS error, coalesce(a.log, '')",
            " AS log, coalesce(a.peak_rss_bytes, -1) AS peak,",
            " coalesce(a.cpu_seconds, -1) AS cpu, coalesce(a.peak_cpus, -1)",
            " AS cpus, coalesce(a.memory_limit_mb, 0) AS limit_mb,",
            " coalesce(a.grant_memory_mb, 0) AS grant_mb,",
            " coalesce(a.memory_swap_peak_bytes, -1) AS swap,",
            " coalesce(a.memory_zswapped_peak_bytes, -1) AS zswapped,",
            " coalesce(a.working_set_mb, 0) AS ws FROM orca.attempts a",
            " JOIN orca.steps s ON s.id = a.step",
            " JOIN orca.runs r ON r.id = s.run WHERE s.run = $1 AND ",
            cond,
            " ORDER BY a.attempt",
        ),
        Params().int64(Int64(run)).int64(Int64(arg)),
    )
    var out = List[AttemptRecord]()
    for r in rows:
        out.append(
            AttemptRecord(
                _int_or_zero(r.text("id")),
                r.text("pipeline"),
                r.text("step"),
                r.text("partition"),
                _int_or_zero(r.text("attempt")),
                r.text("status"),
                r.text("host"),
                r.text("started"),
                r.text("ended"),
                r.text("error"),
                r.text("log"),
                Int(r.int64("peak")),
                r.float64("cpu"),
                r.float64("cpus"),
                Int(r.int64("limit_mb")),
                Int(r.int64("grant_mb")),
                Int(r.int64("swap")),
                Int(r.int64("zswapped")),
                Int(r.int64("ws")),
            )
        )
    return out^


def attempt_record(
    mut conn: Connection, run: Int, id: Int
) raises -> List[AttemptRecord]:
    """Attempt `id` of run `run`: one, or none if the run has no such
    attempt."""
    return _attempts(conn, run, "a.id = $2", id)


def step_attempt_records(
    mut conn: Connection, run: Int, id: Int
) raises -> List[AttemptRecord]:
    """Every attempt of attempt `id`'s step in run `run`, in order."""
    return _attempts(
        conn, run, "a.step = (SELECT step FROM orca.attempts WHERE id = $2)", id
    )


@fieldwise_init
struct AttemptCardRecord(Copyable, Movable):
    """What a run's attempt adds to its step's card
    (`morca._internal.views.steps.attempt_cards`)."""

    var id: Int
    var step: String
    var partition: String
    var attempt: Int
    var status: String
    var started: String
    var ended: String
    var took: Float64
    var error: String
    var peak: Int
    var cpu: Float64
    var cpus: Float64


def attempt_card_records(
    mut conn: Connection, run: Int
) raises -> List[AttemptCardRecord]:
    """Each of a run's attempts, in step order then as they started."""
    var rows = conn.query(
        String(
            "SELECT a.id::text AS id, s.step, s.partition, a.attempt::text AS",
            " attempt, a.status, ",
            utc_sql("a.started"),
            " AS started, ",
            utc_sql("a.ended"),
            " AS ended, coalesce(extract(epoch FROM coalesce(a.ended, now())",
            " - a.started)::float8, -1) AS took, coalesce(a.error, '') AS",
            " error, coalesce(a.peak_rss_bytes, -1) AS peak,",
            " coalesce(a.cpu_seconds, -1) AS cpu, coalesce(a.peak_cpus, -1)",
            " AS cpus FROM orca.attempts a JOIN orca.steps s ON s.id = a.step",
            " WHERE s.run = $1 ORDER BY s.ord, a.started",
        ),
        Params().int64(Int64(run)),
    )
    var out = List[AttemptCardRecord]()
    for r in rows:
        out.append(
            AttemptCardRecord(
                _int_or_zero(r.text("id")),
                r.text("step"),
                r.text("partition"),
                _int_or_zero(r.text("attempt")),
                r.text("status"),
                r.text("started"),
                r.text("ended"),
                r.float64("took"),
                r.text("error"),
                Int(r.int64("peak")),
                r.float64("cpu"),
                r.float64("cpus"),
            )
        )
    return out^


def run_ended(mut conn: Connection, run: Int) raises -> Bool:
    """Whether run `run` is there and neither queued nor running."""
    var ended = conn.query(
        (
            "SELECT status NOT IN ('queued', 'running') AS ended FROM orca.runs"
            " WHERE id = $1"
        ),
        Params().int64(Int64(run)),
    )
    return len(ended) > 0 and ended.row(0).bool("ended")


# ---------------------------------------------------------------------------
# The run's row, for its cards
# ---------------------------------------------------------------------------


def pipeline_hash(mut conn: Connection, pipeline: String) raises -> String:
    """The code `pipeline` is registered with now (`registry_hash`)."""
    return (
        conn.query(
            "SELECT registry_hash FROM orca.pipelines WHERE name = $1",
            Params().text(pipeline),
        )
        .row(0)
        .text("registry_hash")
    )


def run_hash(mut conn: Connection, run: Int) raises -> String:
    """The code run `run` ran (its pipeline's `registry_hash` then)."""
    return (
        conn.query(
            "SELECT registry_hash FROM orca.runs WHERE id = $1",
            Params().int64(Int64(run)),
        )
        .row(0)
        .text("registry_hash")
    )


@fieldwise_init
struct RunFacts(Copyable, Movable):
    """What a run's page shows of its row beside its `RunRecord`."""

    var registry_hash: String
    var rebuild: Int
    var batch: Int
    var batch_runs: Int
    var version: Int
    var cpu_millis: Int
    var pod_memory_mb: Int
    var seconds: Int


def run_facts(mut conn: Connection, run: Int) raises -> RunFacts:
    var row = conn.query(
        (
            "SELECT registry_hash, coalesce(rebuild, 0) AS rebuild,"
            " coalesce(batch, 0) AS batch, (SELECT count(*) FROM orca.runs b"
            " WHERE b.batch = r.batch) AS batch_runs,"
            " coalesce(version, 0) AS version,"
            " coalesce(cpu_millis, 0) AS cpu, coalesce(pod_memory_mb, 0) AS"
            " mem, coalesce(extract(epoch FROM coalesce(ended, now()) -"
            " started)::bigint, 0) AS secs FROM orca.runs r WHERE id = $1"
        ),
        Params().int64(Int64(run)),
    ).row(0)
    return RunFacts(
        row.text("registry_hash"),
        Int(row.int64("rebuild")),
        Int(row.int64("batch")),
        Int(row.int64("batch_runs")),
        Int(row.int64("version")),
        Int(row.int64("cpu")),
        Int(row.int64("mem")),
        Int(row.int64("secs")),
    )


@fieldwise_init
struct RunBatch(Copyable, Movable):
    """The rebuild a run is part of, the batch it was queued in and how
    many runs that has; 0 for none."""

    var rebuild: Int
    var batch: Int
    var batch_runs: Int


def run_batch(mut conn: Connection, run: Int) raises -> RunBatch:
    var row = conn.query(
        (
            "SELECT coalesce(rebuild, 0) AS rebuild, coalesce(batch, 0) AS"
            " batch, (SELECT count(*) FROM orca.runs b WHERE b.batch ="
            " r.batch) AS batch_runs FROM orca.runs r WHERE id = $1"
        ),
        Params().int64(Int64(run)),
    ).row(0)
    return RunBatch(
        Int(row.int64("rebuild")),
        Int(row.int64("batch")),
        Int(row.int64("batch_runs")),
    )


def run_pods(mut conn: Connection, run: Int) raises -> Tuple[Int, Int, Int]:
    """What run `run`'s pods asked for (`cpu_millis`, 0 off Kubernetes, and
    `pod_memory_mb`, MiB), and how long it ran (or has so far), in
    seconds."""
    var row = conn.query(
        (
            "SELECT coalesce(cpu_millis, 0) AS cpu, coalesce(pod_memory_mb, 0)"
            " AS mem, coalesce(extract(epoch FROM coalesce(ended, now()) -"
            " started)::bigint, 0) AS secs FROM orca.runs WHERE id = $1"
        ),
        Params().int64(Int64(run)),
    ).row(0)
    return (
        Int(row.int64("cpu")),
        Int(row.int64("mem")),
        Int(row.int64("secs")),
    )


def sensed(mut conn: Connection, run: Int) raises -> List[Tuple[String, Int64]]:
    """The snapshots (dataset, snapshot id) that started a sensor's run."""
    var out = List[Tuple[String, Int64]]()
    for x in conn.query(
        (
            "SELECT dataset, snapshot_id FROM orca.sensed WHERE run = $1"
            " ORDER BY dataset, snapshot_id"
        ),
        Params().int64(Int64(run)),
    ):
        out.append((x.text("dataset"), x.int64("snapshot_id")))
    return out^


def neighbours(
    mut conn: Connection, pipeline: String, run: Int
) raises -> Tuple[Int64, Int64]:
    """The pipeline's runs before and after `run` (all triggers, fills too),
    or 0."""
    var nb = conn.query(
        (
            "SELECT coalesce((SELECT max(id) FROM orca.runs WHERE pipeline = $1"
            " AND id < $2), 0) AS prev, coalesce((SELECT min(id) FROM"
            " orca.runs WHERE pipeline = $1 AND id > $2), 0) AS next"
        ),
        Params().text(pipeline).int64(Int64(run)),
    ).row(0)
    return (nb.int64("prev"), nb.int64("next"))


@fieldwise_init
struct AuditRow(Copyable, Movable):
    """Who did something to a run, from the UI or the `morca` command
    (`morca._internal.auth`)."""

    var at: String
    var user: String
    var action: String
    var source: String


def audit_rows(mut conn: Connection, run: Int) raises -> List[AuditRow]:
    """What was done to run `run`, in order."""
    var out = List[AuditRow]()
    for a in conn.query(
        (
            "SELECT to_char(at AT TIME ZONE 'UTC',"
            ' \'YYYY-MM-DD"T"HH24:MI:SS"Z"\') AS at, username, action,'
            " coalesce(source, '') AS source FROM orca.audit WHERE run = $1"
            " ORDER BY id"
        ),
        Params().int64(Int64(run)),
    ):
        out.append(
            AuditRow(
                a.text("at"),
                a.text("username"),
                a.text("action"),
                a.text("source"),
            )
        )
    return out^


def waiting_since(mut conn: Connection, run: Int) raises -> Optional[String]:
    """Since when run `run` has waited for workers, if it does."""
    var waiting = conn.query(
        (
            "SELECT to_char(waiting_since AT TIME ZONE 'UTC',"
            ' \'YYYY-MM-DD"T"HH24:MI:SS"Z"\') AS since FROM orca.runs'
            " WHERE id = $1 AND waiting_since IS NOT NULL"
        ),
        Params().int64(Int64(run)),
    )
    if len(waiting) == 0:
        return None
    return waiting.row(0).text("since")


@fieldwise_init
struct RunSettings(Copyable, Movable):
    """What a run was set up with: as its start recorded it, else as its
    pipeline is registered; empty for what neither has."""

    var env: String
    """Its environment, as a JSON object."""
    var secrets: String
    """Its secrets, as a JSON object."""
    var recorded: Bool
    """Whether its start recorded them."""
    var max_runs: String
    var placement: String
    var head: String
    var worker: String
    var workers: String
    var min_workers: String
    var spot: String
    var procs: String


def run_settings(
    mut conn: Connection, run: Int
) raises -> Optional[RunSettings]:
    """Run `run`'s settings, if there's such a run of a registered
    pipeline."""
    var rows = conn.query(
        (
            "SELECT coalesce(r.spec->'env', p.env, '{}'::jsonb)::text AS env,"
            " coalesce(r.spec->'secrets', p.secrets, '{}'::jsonb)::text AS"
            " secrets, (r.spec->'env' IS NOT NULL) AS recorded,"
            " coalesce(p.max_runs::text, '') AS max_runs,"
            " coalesce(r.placement, p.placement, '') AS placement,"
            " coalesce(r.spec->>'head_type', p.head_type, '') AS head,"
            " coalesce(r.spec->>'worker_type', p.worker_type, '') AS worker,"
            " coalesce(r.spec->>'workers', p.ec2_workers::text, '') AS workers,"
            " coalesce(r.spec->>'min_workers', p.ec2_min_workers::text, '')"
            " AS min_workers, coalesce(r.spec->>'spot', p.spot::text, '') AS"
            " spot, coalesce(r.spec->>'worker_procs', p.worker_procs::text,"
            " '') AS procs FROM orca.runs r JOIN orca.pipelines p ON p.name ="
            " r.pipeline WHERE r.id = $1"
        ),
        Params().int64(Int64(run)),
    )
    if len(rows) == 0:
        return None
    var s = rows.row(0)
    return RunSettings(
        s.text("env"),
        s.text("secrets"),
        s.text("recorded") == "true" or s.text("recorded") == "t",
        s.text("max_runs"),
        s.text("placement"),
        s.text("head"),
        s.text("worker"),
        s.text("workers"),
        s.text("min_workers"),
        s.text("spot"),
        s.text("procs"),
    )


def env_pairs(
    mut conn: Connection, env: String
) raises -> List[Tuple[String, String]]:
    """A JSON object's keys and values as text, by key."""
    var out = List[Tuple[String, String]]()
    for r in conn.query(
        (
            "SELECT e.key AS name, e.value AS value FROM jsonb_each_text("
            "coalesce($1::text::jsonb, '{}'::jsonb)) e ORDER BY e.key"
        ),
        Params().text(env),
    ):
        out.append((r.text("name"), r.text("value")))
    return out^


def object_keys(mut conn: Connection, json: String) raises -> List[String]:
    """A JSON object's keys, in order; none for anything else."""
    var out = List[String]()
    for r in conn.query(
        (
            "SELECT k AS name FROM jsonb_object_keys(CASE WHEN"
            " jsonb_typeof($1::text::jsonb) = 'object' THEN $1::text::jsonb"
            " ELSE '{}'::jsonb END) k ORDER BY k"
        ),
        Params().text(json),
    ):
        out.append(r.text("name"))
    return out^
