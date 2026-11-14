"""The scheduler's queries on `orca.runs` (`morca._internal.scheduler`): retries,
runs whose process died, the processes it started, and the memory its
cgroups gave them."""

from postgres import Connection, Params, Transaction

from morca._internal.db.live import dead_sql, ordered_runs, stale_sql


comptime RETRIED = "trigger IN ('schedule', 'backfill', 'sensor', 'fill')"
"""SQL true for the runs the scheduler retries."""


def dead_except(stale_param: String, grace: Float64, ids: String) -> String:
    """SQL true for a running run whose process died (`dead_sql`, with the
    stale limit the parameter `stale_param`) but for the runs `ids`
    (comma-separated; none if empty): those whose process the scheduler
    started and hasn't reaped."""
    var dead = dead_sql(stale_param, grace)
    if not ids:
        return dead
    return String("(", dead, " AND orca.runs.id NOT IN (", ids, "))")


def stale_of(
    mut conn: Connection, stale: Float64, grace: Float64, ids: String
) raises -> List[Tuple[Int, String]]:
    """The runs of `ids` (comma-separated) still running whose process
    looks stopped (`stale_sql`), with their pipelines."""
    var out = List[Tuple[Int, String]]()
    for r in conn.query(
        String(
            "SELECT id, pipeline FROM orca.runs WHERE status = 'running'",
            " AND id::text = ANY (string_to_array($2, ',')) AND ",
            stale_sql("$1", grace),
        ),
        Params().float64(stale).text(ids),
    ):
        out.append((Int(r.int64("id")), r.text("pipeline")))
    return out^


def set_memory_limit(
    mut conn: Connection, run: Int, start: Int, limit_mb: Int, kill_mb: Int
) raises:
    """Records the cgroup limits `run`'s `start` was given."""
    _ = conn.execute(
        (
            "UPDATE orca.runs SET memory_limit_mb = $3, memory_max_mb"
            " = $4, memory_bytes = NULL WHERE id = $1 AND starts = $2"
        ),
        Params()
        .int64(Int64(run))
        .int64(Int64(start))
        .int64(Int64(limit_mb))
        .int64(Int64(kill_mb)),
    )


def raise_memory(
    mut conn: Connection, pipeline: String, mb: Int, run: Int
) raises:
    """Has `pipeline` ask for at least `mb` from now on, as `run` was
    killed for its memory."""
    _ = conn.execute(
        (
            "UPDATE orca.pipelines SET memory_raised_mb ="
            " greatest(coalesce(memory_raised_mb, 0), $2),"
            " memory_raised_run = $3 WHERE name = $1"
        ),
        Params().text(pipeline).int64(Int64(mb)).int64(Int64(run)),
    )


def attempts_memory(
    mut conn: Connection,
    run: Int,
    pid: Int,
    limit_mb: Int,
    grant_mb: Int,
    stall_ms: Int,
    stall_full_ms: Int,
) raises:
    """Gives `run`'s attempts made by process `pid` that have none their
    memory limit, grant (0: none) and stall times (-1: unknown)."""
    _ = conn.execute(
        (
            "UPDATE orca.attempts a SET memory_limit_mb = $3,"
            " grant_memory_mb = nullif($4, 0), memory_stall_ms ="
            " nullif($5, -1), memory_stall_full_ms = nullif($6, -1)"
            " FROM orca.steps st WHERE st.id = a.step AND st.run = $1"
            " AND a.host LIKE '%:' || $2 AND a.memory_limit_mb IS NULL"
        ),
        Params()
        .int64(Int64(run))
        .text(String(pid))
        .int64(Int64(limit_mb))
        .int64(Int64(grant_mb))
        .int64(Int64(stall_ms))
        .int64(Int64(stall_full_ms)),
    )


def clear_memory_bytes(mut conn: Connection, run: Int, start: Int) raises:
    _ = conn.execute(
        (
            "UPDATE orca.runs SET memory_bytes = NULL WHERE id = $1"
            " AND starts = $2"
        ),
        Params().int64(Int64(run)).int64(Int64(start)),
    )


def set_memory_bytes(
    mut conn: Connection, run: Int, start: Int, bytes: Int
) raises:
    """Records the memory `run`'s `start` uses now."""
    _ = conn.execute(
        "UPDATE orca.runs SET memory_bytes = $3 WHERE id = $1 AND starts = $2",
        Params().int64(Int64(run)).int64(Int64(start)).int64(Int64(bytes)),
    )


def fail_unclaimed(
    mut conn: Connection, run: Int, start: Int, why: String
) raises -> Int:
    """Fails `run` with `why` if it is still the scheduler's at `start`
    (its process never claimed it); 1 if it did, else 0."""
    return conn.execute(
        (
            "UPDATE orca.runs SET status = 'failed', ended = now(),"
            " heartbeat = NULL, error = $3 WHERE id = $1 AND status ="
            " 'running' AND owner = 'scheduler' AND starts = $2"
        ),
        Params().int64(Int64(run)).int64(Int64(start)).text(why),
    )


def fail_unretried(
    mut conn: Connection, run: Int, start: Int, why: String
) raises -> Int:
    """Fails `run`, running at `start`, with `why`, and not to be retried
    at this start; 1 if it did, else 0."""
    return conn.execute(
        (
            "UPDATE orca.runs SET status = 'failed', ended = now(),"
            " heartbeat = NULL, retry_at = NULL, error = $3,"
            " unretried_start = starts WHERE id = $1 AND status ="
            " 'running' AND starts = $2"
        ),
        Params().int64(Int64(run)).int64(Int64(start)).text(why),
    )


def held_by_pid(
    mut conn: Connection, run: Int, start: Int, pid: Int
) raises -> Bool:
    """Whether `run` is running at `start` with an owner that is process
    `pid`."""
    return (
        len(
            conn.query(
                (
                    "SELECT id FROM orca.runs WHERE id = $1 AND status ="
                    " 'running' AND starts = $2 AND owner LIKE '%:' || $3"
                ),
                Params()
                .int64(Int64(run))
                .int64(Int64(start))
                .text(String(pid)),
            )
        )
        > 0
    )


def schedule_retries(
    mut conn: Connection,
    pipeline: String,
    now: Int64,
    base: Int64,
    retries: Int,
    max_retry_seconds: Int,
    registry_hash: String,
) raises:
    """Gives `pipeline`'s failed runs that may be retried their
    `retry_at`: `base` seconds after `now`, doubling with each start that
    wasn't after a deferral, up to `max_retry_seconds` (0: no limit), plus
    up to a tenth as jitter."""
    _ = conn.execute(
        String(
            (
                "UPDATE orca.runs SET retry_at = $2 + (SELECT CASE WHEN $5"
                " > 0 THEN least(w, $5) ELSE w END FROM (SELECT least($3 *"
                " power(2, least(starts - deferrals - 1, 60)),"
                " 1e15)::bigint AS w) AS x) + (id * 7919 % 1000) * least($3"
                " * power(2, least(starts - deferrals - 1, 60)), CASE WHEN"
                " $5 > 0 THEN $5 ELSE 1e15 END)::bigint / 10000 WHERE "
            ),
            ordered_runs(
                String(
                    "pipeline = $1 AND status = 'failed' AND ",
                    RETRIED,
                    " AND retry_at IS NULL AND starts - deferrals BETWEEN 1",
                    " AND $4 AND (registry_hash = $6 OR allow_new_code) AND",
                    " unretried_start IS DISTINCT FROM starts",
                )
            ),
        ),
        Params()
        .text(pipeline)
        .int64(now)
        .int64(base)
        .int64(Int64(retries))
        .int64(Int64(max_retry_seconds))
        .text(registry_hash),
    )


def cancel_dead(
    mut tx: Transaction, pipeline: String, stale: Float64, dead: String
) raises:
    """Cancels `pipeline`'s runs asked to cancel whose process died; `dead`
    is SQL for that, with the stale limit as `$2`."""
    _ = tx.execute(
        String(
            "UPDATE orca.runs SET status = 'cancelled', ended = now(),",
            " heartbeat = NULL WHERE pipeline = $1 AND status = 'running'",
            " AND cancel_requested AND ",
            dead,
        ),
        Params().text(pipeline).float64(stale),
    )


def fail_old_code(
    mut tx: Transaction,
    pipeline: String,
    stale: Float64,
    retries: Int,
    registry_hash: String,
    dead: String,
) raises:
    """Fails `pipeline`'s runs of code other than `registry_hash` that the
    scheduler would start again, saying how to resume them; `dead` is SQL
    for a run whose process died, with the stale limit as `$2`."""
    _ = tx.execute(
        String(
            "UPDATE orca.runs SET status = 'failed', ended =",
            " coalesce(ended, now()), heartbeat = NULL, retry_at = NULL,",
            " error = 'not started: its code is ' || registry_hash || ',",
            " and the pipeline''s binary is now ' || $4 || '; resume it",
            " with the new code from morca ui, or with <binary> resume",
            " ' || id || ' --allow-new-code' WHERE pipeline = $1 AND",
            " registry_hash <> $4 AND NOT allow_new_code AND error IS NULL",
            " AND (status IN ('queued', 'deferred') OR (status = 'failed'",
            " AND ",
            RETRIED,
            " AND starts - deferrals BETWEEN 1 AND $3) OR (status =",
            " 'running' AND ",
            RETRIED,
            " AND NOT cancel_requested AND ",
            dead,
            "))",
        ),
        Params()
        .text(pipeline)
        .float64(stale)
        .int64(Int64(retries))
        .text(registry_hash),
    )


def fail_dead(
    mut tx: Transaction,
    pipeline: String,
    stale: Float64,
    retries: Int,
    fills: Bool,
    dead: String,
) raises:
    """Fails `pipeline`'s runs whose process died with no retries left
    (over `retries` starts), that the scheduler doesn't retry, or that are
    fill runs while fills are off (`fills`), but those of a fill request
    (#465)."""
    _ = tx.execute(
        String(
            "UPDATE orca.runs SET status = 'failed', ended = now(),",
            " heartbeat = NULL, error = CASE WHEN ",
            RETRIED,
            " THEN 'interrupted: its process stopped, and its retries are",
            " spent' ELSE 'interrupted: its process stopped' END WHERE",
            " pipeline = $1 AND status = 'running' AND NOT",
            " cancel_requested AND ",
            dead,
            " AND (starts - deferrals > $3 OR NOT ",
            RETRIED,
            " OR (trigger = 'fill' AND fill_request IS NULL AND NOT $4))",
        ),
        Params()
        .text(pipeline)
        .float64(stale)
        .int64(Int64(retries))
        .bool(fills),
    )


def requeue_dead(
    mut tx: Transaction, pipeline: String, stale: Float64, dead: String
) raises -> Int:
    """Queues again `pipeline`'s running runs whose process died that
    weren't asked to cancel; returns how many."""
    return tx.execute(
        String(
            "UPDATE orca.runs SET status = 'queued', owner = NULL,",
            " heartbeat = NULL, retry_at = NULL, held = NULL, instance",
            " = NULL WHERE pipeline = $1 AND status = 'running' AND",
            " NOT cancel_requested AND ",
            dead,
        ),
        Params().text(pipeline).float64(stale),
    )


def local_running(
    mut conn: Connection, stale: Float64, dead: String
) raises -> Int:
    """The runs running on this host (local and control-placed) whose
    process is alive (`dead`, with the stale limit as `$1`)."""
    return Int(
        conn.query(
            String(
                "SELECT count(*) AS n FROM orca.runs WHERE status",
                " = 'running' AND placement IN ('local',",
                " 'control') AND NOT ",
                dead,
            ),
            Params().float64(stale),
        )
        .row(0)
        .int64("n")
    )
