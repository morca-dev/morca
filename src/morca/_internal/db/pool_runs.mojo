"""The scheduler's queries for runs on a worker pool (`morca._internal.pool_runs`):
runs queued again for a worker, lost workers' and gone instances' runs,
and fill runs queued for the pool. `dead` is SQL for a run whose process
died, with the stale limit as `$2`."""

from postgres import Params, Transaction

from morca._internal.db.live import dead_sql, stale_sql
from morca._internal.db.scheduler import RETRIED


def hold_fills(mut tx: Transaction, pipeline: String, why: String) raises:
    """Has `pipeline`'s queued fill runs say `why` they wait."""
    _ = tx.execute(
        (
            "UPDATE orca.runs SET held = $2 WHERE pipeline = $1 AND"
            " status = 'queued' AND trigger = 'fill' AND fill_request IS"
            " NULL AND held IS DISTINCT FROM $2"
        ),
        Params().text(pipeline).text(why),
    )


def requeue_due(
    mut tx: Transaction,
    pipeline: String,
    stale: Float64,
    retries: Int,
    now: Int64,
    held: String,
    dead: String,
) raises -> Int:
    """Queues again, saying `held`, `pipeline`'s runs but fill runs that
    are due by `now`: deferred ones, retried failed ones, and retried
    running ones whose process died with starts left of `retries`.
    Returns how many."""
    return tx.execute(
        String(
            "UPDATE orca.runs SET status = 'queued', owner = NULL,",
            " heartbeat = NULL, retry_at = NULL, held = $5 WHERE pipeline",
            " = $1 AND trigger <> 'fill' AND ((status = 'deferred' AND",
            " retry_at <= $4) OR (status = 'failed' AND ",
            RETRIED,
            " AND retry_at <= $4) OR (status = 'running' AND ",
            RETRIED,
            " AND ",
            dead,
            " AND starts - deferrals <= $3))",
        ),
        Params()
        .text(pipeline)
        .float64(stale)
        .int64(Int64(retries))
        .int64(now)
        .text(held),
    )


def hold_unheld(mut tx: Transaction, pipeline: String, why: String) raises:
    """Has `pipeline`'s queued runs that say nothing say `why`."""
    _ = tx.execute(
        (
            "UPDATE orca.runs SET held = $2 WHERE pipeline = $1 AND status"
            " = 'queued' AND held IS NULL"
        ),
        Params().text(pipeline).text(why),
    )


@fieldwise_init
struct Requeued(Copyable, Movable):
    """A run queued again, and why."""

    var run: Int
    var why: String
    var unstarted: Bool
    """Its worker claimed it but never started it: its start was given
    back."""


def requeue_lost(
    mut tx: Transaction,
    pipeline: String,
    stale: Float64,
    grace: Float64,
    retries: Int,
    held: String,
    worker_owner: String,
) raises -> List[Requeued]:
    """Queues again, saying `held`, `pipeline`'s running runs on a pool
    whose worker is gone: not seen for half the stale limit, with the run
    claimed (owner `worker_owner`) for the stale limit or its process
    dead, or seen since without it. One claimed but never started has its
    start given back; the others need starts left of `retries`. Locks
    them (`FOR UPDATE`)."""
    # In this query orca.runs is `r` (`dead` names it by the table).
    var gone = dead_sql("$2", grace, "r")
    var out = List[Requeued]()
    for r in tx.query(
        String(
            "WITH lost AS (SELECT r.id, r.owner = '",
            worker_owner,
            "' AS unstarted, CASE WHEN w.last_seen IS NULL OR w.last_seen",
            " <= now() - make_interval(secs => $2 / 2) THEN 'worker ' ||",
            " w.label || ' (token ' || w.id || ') stopped: not seen for '",
            " || coalesce(extract(epoch FROM now() -",
            " w.last_seen)::bigint::text || ' s', 'ever') ELSE 'worker '",
            " || w.label || ' (token ' || w.id || ') no longer runs it'",
            " END AS why FROM orca.runs r JOIN orca.workers w ON w.id =",
            " r.worker WHERE r.pipeline = $1 AND r.status = 'running' AND",
            " r.placement LIKE 'worker:%' AND NOT r.cancel_requested AND",
            " (r.owner = '",
            worker_owner,
            "' OR r.starts - r.deferrals <= $3) AND (((w.last_seen IS NULL",
            " OR w.last_seen <= now() - make_interval(secs => $2 / 2)) AND",
            " ((r.owner = '",
            worker_owner,
            "' AND r.started <= now() - make_interval(secs => $2)) OR ",
            gone,
            ")) OR (",
            gone,
            " AND NOT (r.id::text = ANY (string_to_array(coalesce(",
            "w.running, ''), ','))))) FOR UPDATE OF r) UPDATE orca.runs u",
            " SET status = 'queued', owner = NULL, heartbeat = NULL,",
            " retry_at = NULL, held = $4, starts = CASE WHEN",
            " lost.unstarted THEN u.starts - 1 ELSE u.starts END FROM lost",
            " WHERE u.id = lost.id RETURNING u.id, lost.why,",
            " lost.unstarted",
        ),
        Params().text(pipeline).float64(stale).int64(Int64(retries)).text(held),
    ):
        out.append(
            Requeued(Int(r.int64("id")), r.text("why"), r.bool("unstarted"))
        )
    return out^


def requeue_orphans(
    mut tx: Transaction,
    pipeline: String,
    stale: Float64,
    grace: Float64,
    retries: Int,
) raises -> List[Requeued]:
    """Queues again `pipeline`'s local and control-placed running runs
    with starts left of `retries` whose scheduler instance is gone (ended,
    or not seen for the stale limit) and whose heartbeat is stale. Locks
    them (`FOR UPDATE`)."""
    var out = List[Requeued]()
    for r in tx.query(
        String(
            "WITH lost AS (SELECT r.id, 'scheduler instance ' || s.id ||",
            " ' on ' || s.host || CASE WHEN s.ended IS NOT NULL THEN",
            " ' ended' ELSE ' stopped: not seen for ' || extract(epoch",
            " FROM now() - s.last_seen)::bigint || ' s' END AS why FROM",
            " orca.runs r JOIN orca.schedulers s ON s.id = r.instance WHERE",
            " r.pipeline = $1 AND r.status = 'running' AND r.placement IN",
            " ('local', 'control') AND NOT r.cancel_requested AND",
            " r.starts - r.deferrals <= $3 AND (s.ended IS NOT NULL OR",
            " s.last_seen <= now() - make_interval(secs => $2)) AND ",
            stale_sql("$2", grace, "r"),
            " FOR UPDATE OF r) UPDATE orca.runs u SET status = 'queued',",
            " owner = NULL, heartbeat = NULL, retry_at = NULL, held = NULL,",
            " instance = NULL FROM lost WHERE u.id = lost.id RETURNING",
            " u.id, lost.why",
        ),
        Params().text(pipeline).float64(stale).int64(Int64(retries)),
    ):
        out.append(Requeued(Int(r.int64("id")), r.text("why"), False))
    return out^


def requeue_fills(
    mut tx: Transaction,
    pipeline: String,
    stale: Float64,
    retries: Int,
    now: Int64,
    held: String,
    limit: Int,
    dead: String,
) raises -> Int:
    """Queues again, saying `held`, up to `limit` of `pipeline`'s fill runs
    that are due by `now` (deferred, failed with starts left of `retries`,
    or running with their process dead), oldest first; returns how
    many."""
    return tx.execute(
        String(
            "UPDATE orca.runs SET status = 'queued', owner = NULL,",
            " heartbeat = NULL, retry_at = NULL, held = $5 WHERE id IN",
            " (SELECT id FROM orca.runs WHERE pipeline = $1 AND",
            " trigger = 'fill' AND ((status = 'deferred' AND retry_at",
            " <= $4) OR (status = 'failed' AND retry_at <= $4 AND",
            " starts - deferrals BETWEEN 1 AND $3) OR (status =",
            " 'running' AND ",
            dead,
            " AND starts - deferrals <= $3)) ORDER BY id LIMIT $6)",
        ),
        Params()
        .text(pipeline)
        .float64(stale)
        .int64(Int64(retries))
        .int64(now)
        .text(held)
        .int64(Int64(limit)),
    )


def queue_fill(
    mut tx: Transaction,
    pipeline: String,
    registry_hash: String,
    key: String,
    held: String,
    request: Int64 = 0,
) raises -> Int64:
    """A new fill run of `pipeline` over `key`, queued for the pool and
    saying `held`, of the fill request `request` (0 for the fill's
    range)."""
    return (
        tx.query(
            (
                "INSERT INTO orca.runs (pipeline, registry_hash,"
                " partitions, trigger, status, held, fill_request) VALUES"
                " ($1, $2, $3, 'fill', 'queued', $4, NULLIF($5, 0))"
                " RETURNING id"
            ),
            Params()
            .text(pipeline)
            .text(registry_hash)
            .text(key)
            .text(held)
            .int64(request),
        )
        .row(0)
        .int64("id")
    )
