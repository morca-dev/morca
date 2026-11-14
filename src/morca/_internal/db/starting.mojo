"""The queries of a scheduler pass that starts a pipeline's runs
(`morca._internal.starting`): what is live, what the host and the budget have
granted, which runs to start, and starting them. `dead` in these is SQL
for a run whose process died, with the stale limit as the parameter
`morca._internal.starting` says (`Scheduler._dead`)."""

from postgres import Connection, Params, Transaction, is_retryable, sqlstate_of

from morca._internal.db.live import behind_sql, ordered_runs
from morca._internal.db.scheduler import RETRIED


def _which(fill: Bool) -> String:
    """SQL limiting a pass to the fill runs, or to all the others."""
    return String(" AND trigger = 'fill'") if fill else String(
        " AND trigger <> 'fill'"
    )


def xact_lock(mut tx: Transaction, key: Int64) raises:
    """Takes the transaction-scoped advisory lock `key`."""
    _ = tx.execute("SELECT pg_advisory_xact_lock($1)", Params().int64(key))


def lock_pipeline(mut tx: Transaction, pipeline: String) raises:
    """Locks `pipeline`'s row (`FOR UPDATE`) until `tx` ends."""
    _ = tx.query(
        "SELECT name FROM orca.pipelines WHERE name = $1 FOR UPDATE",
        Params().text(pipeline),
    )


def lock_runs(mut tx: Transaction, pipeline: String) raises:
    """Locks, in `id` order (`ordered_runs`), the runs of `pipeline` a
    scheduler pass may update: those queued, running or deferred, and
    those failed with a retry due. A pass updates them over several
    statements, so it takes them all at once first, after
    `lock_pipeline`; a statement that updates several runs elsewhere
    (cancelling, holding them for a worker) locks its own in `id` order
    too, and waits for the pass rather than deadlocking with it."""
    _ = tx.query(
        (
            "SELECT id FROM orca.runs WHERE pipeline = $1 AND (status IN"
            " ('queued', 'running', 'deferred') OR (status = 'failed' AND"
            " retry_at IS NOT NULL)) ORDER BY id FOR NO KEY UPDATE"
        ),
        Params().text(pipeline),
    )


def retryable(e: Error) -> Bool:
    """True if Postgres ended a transaction for a deadlock (SQLSTATE
    `40P01`) or a serialization failure (`40001`): it rolled back, and
    the same transaction tried again may well commit."""
    return is_retryable(sqlstate_of(e))


def live_count(
    mut tx: Transaction,
    pipeline: String,
    stale: Float64,
    dead: String,
    fill: Bool,
) raises -> Int:
    """`pipeline`'s running runs whose process is alive (`dead` with the
    stale limit as `$2`), of its fill runs or of the others."""
    return Int(
        tx.query(
            String(
                "SELECT count(*) AS n FROM orca.runs WHERE pipeline = $1",
                " AND status = 'running' AND NOT ",
                dead,
                _which(fill),
            ),
            Params().text(pipeline).float64(stale),
        )
        .row(0)
        .int64("n")
    )


def control_running(
    mut tx: Transaction, stale: Float64, dead: String
) raises -> Int:
    """The control-placed runs running with their process alive (`dead`
    with the stale limit as `$1`)."""
    return Int(
        tx.query(
            String(
                "SELECT count(*) AS n FROM orca.runs WHERE status",
                " = 'running' AND placement = 'control' AND NOT ",
                dead,
            ),
            Params().float64(stale),
        )
        .row(0)
        .int64("n")
    )


def granted(
    mut tx: Transaction, stale: Float64, dead: String
) raises -> Tuple[Int, Int]:
    """The CPUs and the MB of memory granted to the runs running on this
    host (local and control-placed) with their process alive (`dead` with
    the stale limit as `$1`)."""
    var g = tx.query(
        String(
            "SELECT coalesce(sum(grant_cpus), 0) AS cpus,",
            " coalesce(sum(grant_memory_mb), 0) AS mb FROM orca.runs",
            " WHERE status = 'running' AND placement IN ('local',",
            " 'control') AND NOT ",
            dead,
        ),
        Params().float64(stale),
    ).row(0)
    return (Int(g.int64("cpus")), Int(g.int64("mb")))


def ahead_on_host(
    mut tx: Transaction,
    priority: Int,
    control: Bool,
    stale: Float64,
    dead: String,
) raises -> Optional[Tuple[String, Int]]:
    """The pipeline of the highest `priority` above `priority` (then the
    first by name) with a run running on this host with its process alive
    (`dead` with the stale limit as `$1`), and its priority: of the
    control-placed runs with `control`, else of those holding a grant. None
    if there is none (#421)."""
    var rows = tx.query(
        String(
            "SELECT name, priority FROM orca.pipelines WHERE priority > $2",
            " AND name IN (SELECT pipeline FROM orca.runs WHERE status =",
            " 'running' AND CASE WHEN $3 THEN placement = 'control' ELSE",
            " placement IN ('local', 'control') AND (grant_cpus IS NOT NULL",
            " OR grant_memory_mb IS NOT NULL) END AND NOT ",
            dead,
            ") ORDER BY priority DESC, name LIMIT 1",
        ),
        Params().float64(stale).int64(Int64(priority)).bool(control),
    )
    if len(rows) == 0:
        return None
    var r = rows.row(0)
    return (r.text("name"), Int(r.int64("priority")))


def say_held(
    mut tx: Transaction, pipeline: String, hold: String, fill: Bool
) raises:
    """Has `pipeline`'s queued runs that aren't behind an older live run
    (`behind_sql`) say `hold` as why they wait, or nothing if it's
    empty."""
    _ = tx.execute(
        String(
            "UPDATE orca.runs SET held = nullif($2, '') WHERE pipeline = $1",
            " AND status = 'queued' AND held IS DISTINCT FROM nullif($2,",
            " '') AND NOT ",
            behind_sql(),
            _which(fill),
        ),
        Params().text(pipeline).text(hold),
    )


def cpu_in_use(mut tx: Transaction, stale: Float64, dead: String) raises -> Int:
    """The CPU millis of the runs running with their process alive (`dead`
    with the stale limit as `$1`)."""
    return Int(
        tx.query(
            String(
                "SELECT coalesce(sum(cpu_millis), 0) AS n FROM",
                " orca.runs WHERE status = 'running' AND NOT ",
                dead,
            ),
            Params().float64(stale),
        )
        .row(0)
        .int64("n")
    )


def pool_cpu(
    mut tx: Transaction, a: String, b: String
) raises -> Tuple[Int, Int]:
    """The CPU millis of the pool's instances not serving a running run:
    all of them, and those of key `a` or `b`."""
    var pr = tx.query(
        (
            "SELECT coalesce(sum(i.cpu_millis), 0) AS n,"
            " coalesce(sum(i.cpu_millis) FILTER (WHERE i.pool_key"
            " IN ($1, $2)), 0) AS mine FROM orca.instances i JOIN"
            " orca.runs r ON r.id = i.run WHERE i.ended IS NULL AND"
            " i.pool_key IS NOT NULL AND NOT (r.status = 'running'"
            " AND r.starts = i.start)"
        ),
        Params().text(a).text(b),
    ).row(0)
    return (Int(pr.int64("n")), Int(pr.int64("mine")))


def startable(
    mut tx: Transaction,
    pipeline: String,
    stale: Float64,
    retries: Int,
    now: Int64,
    limit: Int,
    dead: String,
    fill: Bool,
) raises -> List[Tuple[Int64, Bool]]:
    """Up to `limit` of `pipeline`'s runs to start, oldest first, each with
    its `allow_new_code`: queued ones not behind an older live run,
    deferred and retried failed ones due by `now`, and retried running
    ones whose process died (`dead`, the stale limit `$2`) with starts
    left of `retries`."""
    var out = List[Tuple[Int64, Bool]]()
    for r in tx.query(
        String(
            (
                "SELECT id, allow_new_code FROM orca.runs WHERE"
                " pipeline = $1 AND ((status"
            ),
            " = 'queued' AND NOT ",
            behind_sql(),
            ") OR (status = 'deferred' AND retry_at <= $4) OR",
            " (status = 'failed' AND ",
            RETRIED,
            " AND retry_at <= $4) OR (status = 'running' AND ",
            RETRIED,
            " AND ",
            dead,
            " AND starts - deferrals <= $3))",
            _which(fill),
            " ORDER BY id LIMIT $5",
        ),
        Params()
        .text(pipeline)
        .float64(stale)
        .int64(Int64(retries))
        .int64(now)
        .int64(Int64(limit)),
    ):
        out.append((r.int64("id"), r.bool("allow_new_code")))
    return out^


def queue_fill(
    mut tx: Transaction,
    pipeline: String,
    registry_hash: String,
    key: String,
    request: Int64 = 0,
) raises -> Int64:
    """A new queued fill run of `pipeline` over `key`, of the fill request
    `request` (0 for the fill's range)."""
    return (
        tx.query(
            (
                "INSERT INTO orca.runs (pipeline,"
                " registry_hash, partitions, trigger, status, fill_request)"
                " VALUES ($1, $2, $3, 'fill', 'queued', NULLIF($4, 0))"
                " RETURNING id"
            ),
            Params()
            .text(pipeline)
            .text(registry_hash)
            .text(key)
            .int64(request),
        )
        .row(0)
        .int64("id")
    )


def mark_started(
    mut tx: Transaction,
    run: Int64,
    cpu_millis: Int,
    placement: String,
    request_cpus: String,
    request_memory_gb: String,
    grant_cpus: Int,
    grant_memory_mb: Int,
    instance: Int,
    request_source: String,
    request_runs: Int,
) raises -> Int:
    """Starts `run` as the scheduler's, with what it was given (empty
    texts and zeros recorded as none), and returns its new start. Its
    `started` is the clock's now, not the transaction's."""
    return Int(
        tx.query(
            (
                "UPDATE orca.runs SET status = 'running', owner"
                " = 'scheduler', heartbeat = NULL, started ="
                " clock_timestamp(), ended = NULL, starts ="
                " starts + 1,"
                " retry_at = NULL, error = NULL, waiting_since"
                " = NULL, cpu_millis = $2, placement = $3, held"
                " = NULL, request_cpus = nullif($4, ''),"
                " request_memory_gb = nullif($5, ''),"
                " grant_cpus = nullif($6, 0), grant_memory_mb ="
                " nullif($7, 0), memory_limit_mb = NULL,"
                " memory_max_mb = NULL, memory_bytes = NULL,"
                " instance = nullif($8, 0), request_source ="
                " nullif($9, ''), request_runs = nullif($10,"
                " 0) WHERE id = $1 RETURNING starts"
            ),
            Params()
            .int64(run)
            .int64(Int64(cpu_millis))
            .text(placement)
            .text(request_cpus)
            .text(request_memory_gb)
            .int64(Int64(grant_cpus))
            .int64(Int64(grant_memory_mb))
            .int64(Int64(instance))
            .text(request_source)
            .int64(Int64(request_runs)),
        )
        .row(0)
        .int64("starts")
    )


def fail_start(mut conn: Connection, run: Int64, why: String) raises:
    """Fails `run`, which couldn't start, with `why`, if it is still
    running without a heartbeat."""
    _ = conn.execute(
        (
            "UPDATE orca.runs SET status = 'failed', ended ="
            " now(), error = $2 WHERE id = $1 AND status ="
            " 'running' AND heartbeat IS NULL"
        ),
        Params().int64(run).text(why),
    )
