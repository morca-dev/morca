"""Concurrency keys' queries (`morca._internal.concurrency`, #397): the lock
a start takes on a key, the live runs holding one, and the queued runs that
wait on it, say so, and time out.

A run holds the key it recorded as it started (`runs.concurrency_key`), or,
for one started before it recorded any (by an older morca), its pipeline's
(`pipelines.concurrency_key`). `dead` in these is SQL for a run whose
process died, over `orca.runs` unaliased, with the stale limit as `$2`.
"""

from postgres import Connection, Params, Transaction

from morca._internal.db.handover import differs_sql, draining_sql, label_sql
from morca._internal.db.live import behind_sql

comptime _KEY_LOCKS = 0x6B657973  # "keys"
"""The first key of the two-key advisory locks on concurrency keys: their
own space, apart from the one-key locks morca takes elsewhere."""

comptime OTHERS = 0
"""A pipeline's runs but its fill runs."""
comptime FILLS = 1
"""Its fill runs only."""
comptime ALL = 2
"""All of them (a worker pool's pass)."""


def _which(which: Int) -> String:
    if which == OTHERS:
        return " AND trigger <> 'fill'"
    if which == FILLS:
        return " AND trigger = 'fill'"
    return ""


def lock_key(mut tx: Transaction, key: String) raises:
    """Takes the transaction-scoped advisory lock on `key`: one start at a
    time counts its holders, across pipelines, schedulers and workers."""
    _ = tx.execute(
        "SELECT pg_advisory_xact_lock($1::integer, hashtext($2))",
        Params().int64(Int64(_KEY_LOCKS)).text(key),
    )


@fieldwise_init
struct Holder(Copyable, Movable):
    """A live run holding a key."""

    var run: Int
    var pipeline: String
    var version: String
    """Its code version (`version_label`), or empty if it recorded none."""
    var outdated: Bool
    """Whether a newer version leads (`morca._internal.handover`)."""


def holders(
    mut tx: Transaction, key: String, stale: Float64, dead: String
) raises -> List[Holder]:
    """The runs running with their process alive (`dead`) that hold `key`,
    oldest first."""
    var out = List[Holder]()
    for r in tx.query(
        String(
            "SELECT orca.runs.id, orca.runs.pipeline, ",
            label_sql("rv"),
            " AS version, (",
            differs_sql("rv", "pv"),
            " OR ",
            draining_sql("s", "orca.runs"),
            ") AS outdated FROM orca.runs JOIN orca.pipelines p ON p.name =",
            " orca.runs.pipeline LEFT JOIN orca.pipeline_versions rv ON rv.id",
            " = orca.runs.version LEFT JOIN orca.pipeline_versions pv ON",
            " pv.id = p.version LEFT JOIN orca.schedulers s ON s.id =",
            " orca.runs.instance WHERE orca.runs.status = 'running' AND",
            " coalesce(orca.runs.concurrency_key, p.concurrency_key) = $1",
            " AND NOT ",
            dead,
            " ORDER BY orca.runs.id",
        ),
        Params().text(key).float64(stale),
    ):
        out.append(
            Holder(
                Int(r.int64("id")),
                r.text("pipeline"),
                r.text("version"),
                r.bool("outdated"),
            )
        )
    return out^


def record_start(mut tx: Transaction, run: Int64, key: String) raises:
    """`run`, just started, holds `key`, and waits on nothing."""
    _ = tx.execute(
        (
            "UPDATE orca.runs SET concurrency_key = $2, waits_on = NULL,"
            " key_wait_since = NULL WHERE id = $1"
        ),
        Params().int64(run).text(key),
    )


def _waiting(which: Int) raises -> String:
    """SQL for `pipeline = $1`'s queued runs that aren't behind an older
    live run of their keys (those wait for it, `behind_sql`)."""
    return String(
        "pipeline = $1 AND status = 'queued' AND NOT ",
        behind_sql(),
        _which(which),
    )


def hold_on(
    mut tx: Transaction,
    pipeline: String,
    holder: Int,
    outdated: Bool,
    held: String,
    which: Int,
) raises:
    """Has `pipeline`'s queued runs say `held`, waiting on run `holder`;
    since when they wait on one of an older version, if it's `outdated`."""
    _ = tx.execute(
        String(
            "UPDATE orca.runs SET held = $2, waits_on = $3, key_wait_since",
            " = CASE WHEN $4 THEN coalesce(key_wait_since, now()) END WHERE ",
            _waiting(which),
            " AND (held IS DISTINCT FROM $2 OR waits_on IS DISTINCT FROM $3",
            " OR (key_wait_since IS NULL) = $4)",
        ),
        Params().text(pipeline).text(held).int64(Int64(holder)).bool(outdated),
    )


def time_out(
    mut tx: Transaction,
    pipeline: String,
    limit: Float64,
    error: String,
    which: Int,
) raises -> List[Int]:
    """Fails, with `error` and unretried, `pipeline`'s queued runs that have
    waited `limit` seconds on a run of an older version; their ids."""
    var out = List[Int]()
    for r in tx.query(
        String(
            "UPDATE orca.runs SET status = 'failed', ended = now(), error =",
            " $3, held = NULL, retry_at = NULL, unretried_start = starts,",
            " key_wait_since = NULL WHERE ",
            _waiting(which),
            " AND key_wait_since <= now() - make_interval(secs => $2)",
            " RETURNING id",
        ),
        Params().text(pipeline).float64(limit).text(error),
    ):
        out.append(Int(r.int64("id")))
    return out^


def release(
    mut tx: Transaction, pipeline: String, after: String, which: Int
) raises:
    """`pipeline`'s queued runs no longer wait on a key: those that did say
    `after` instead (left as they are when it's empty)."""
    _ = tx.execute(
        String(
            "UPDATE orca.runs SET waits_on = NULL, key_wait_since = NULL,",
            " held = CASE WHEN $2 = '' THEN held ELSE $2 END WHERE pipeline",
            " = $1 AND status = 'queued' AND waits_on IS NOT NULL",
            _which(which),
        ),
        Params().text(pipeline).text(after),
    )


def set_key(
    mut conn: Connection, pipeline: String, key: String, limit: Int
) raises:
    """Registers `pipeline`'s key and limit (none for an empty `key`)."""
    _ = conn.execute(
        (
            "UPDATE orca.pipelines SET concurrency_key = nullif($2, ''),"
            " concurrency_limit = CASE WHEN $2 = '' THEN NULL ELSE $3 END"
            " WHERE name = $1"
        ),
        Params().text(pipeline).text(key).int64(Int64(limit)),
    )


def any_key(mut conn: Connection) raises -> String:
    """A registered pipeline that declares a key, or empty if none does."""
    var rows = conn.query(
        "SELECT name FROM orca.pipelines WHERE concurrency_key IS NOT"
        " NULL AND binary_path IS NOT NULL AND retired IS NULL ORDER BY"
        " name LIMIT 1"
    )
    if len(rows) == 0:
        return String()
    return rows.row(0).text("name")
