"""Fill requests' queries (`morca._internal.fill_requests`, #465):
`orca.fill_requests`, a pipeline's open request for keys to run as fill
runs, and `orca.runs.fill_request`, the request a fill run was queued for.
"""

from postgres import Connection, Params, Transaction
from morca._internal.db.actions import _cancel_set
from morca._internal.db.live import ordered_runs
from morca._internal.db.scheduler import RETRIED


@fieldwise_init
struct RequestRow(Copyable, Movable):
    """A pipeline's open fill request."""

    var id: Int64
    var keys: String
    """Its keys, comma-separated, ascending."""
    var spec: String
    """The keys as they were asked for (`2023-01-01..2026-11-13`), each
    request merged into it after a `+`."""
    var rerun: Bool
    """`--rerun`: keys that are done run again."""
    var created: String
    """When it was asked for, `2026-11-14T03:00:00Z`."""
    var requested_by: String


comptime _COLUMNS = (
    "id, keys, spec, rerun, to_char(created AT TIME ZONE 'UTC',"
    ' \'YYYY-MM-DD"T"HH24:MI:SS"Z"\') AS created, coalesce(requested_by,'
    " '') AS requested_by"
)


def open_request(
    mut tx: Transaction, pipeline: String
) raises -> Optional[RequestRow]:
    """`pipeline`'s open fill request, if it has one."""
    var rows = tx.query(
        String(
            "SELECT ",
            _COLUMNS,
            " FROM orca.fill_requests WHERE pipeline = $1 AND ended IS NULL",
            " ORDER BY id LIMIT 1",
        ),
        Params().text(pipeline),
    )
    if len(rows) != 1:
        return None
    var r = rows.row(0)
    return RequestRow(
        r.int64("id"),
        r.text("keys"),
        r.text("spec"),
        r.bool("rerun"),
        r.text("created"),
        r.text("requested_by"),
    )


def requested(mut conn: Connection) raises -> List[String]:
    """The pipelines with an open fill request."""
    var out = List[String]()
    for r in conn.query(
        "SELECT DISTINCT pipeline FROM orca.fill_requests WHERE ended IS NULL",
        Params(),
    ):
        out.append(r.text("pipeline"))
    return out^


def add_request(
    mut tx: Transaction,
    pipeline: String,
    keys: String,
    spec: String,
    rerun: Bool,
    requested_by: String,
) raises -> Int64:
    """A new open fill request of `pipeline`; its id."""
    return (
        tx.query(
            (
                "INSERT INTO orca.fill_requests (pipeline, keys, spec, rerun,"
                " requested_by) VALUES ($1, $2, $3, $4, NULLIF($5, ''))"
                " RETURNING id"
            ),
            Params()
            .text(pipeline)
            .text(keys)
            .text(spec)
            .bool(rerun)
            .text(requested_by),
        )
        .row(0)
        .int64("id")
    )


def merge_request(
    mut tx: Transaction, id: Int64, keys: String, spec: String
) raises:
    """Request `id`'s keys are now `keys`, with `spec` added to what was
    asked for."""
    _ = tx.execute(
        (
            "UPDATE orca.fill_requests SET keys = $2, spec = spec || ' + ' ||"
            " $3 WHERE id = $1"
        ),
        Params().int64(id).text(keys).text(spec),
    )


def end_request(mut tx: Transaction, id: Int64) raises:
    """Request `id` is done: each of its keys ran."""
    _ = tx.execute(
        (
            "UPDATE orca.fill_requests SET ended = now() WHERE id = $1 AND"
            " ended IS NULL"
        ),
        Params().int64(id),
    )


def cancel_request(mut tx: Transaction, pipeline: String) raises -> Int64:
    """Cancels `pipeline`'s open request; its id, or 0 for none."""
    var rows = tx.query(
        (
            "UPDATE orca.fill_requests SET ended = now(), cancelled = now()"
            " WHERE pipeline = $1 AND ended IS NULL RETURNING id"
        ),
        Params().text(pipeline),
    )
    if len(rows) == 0:
        return 0
    return rows.row(0).int64("id")


def cancel_request_runs(
    mut tx: Transaction, id: Int64, retries: Int, kill_seconds: Float64
) raises -> Int:
    """Cancels, as `morca cancel` does, request `id`'s runs that are
    queued, deferred, running and not stopping, or failed and due to be
    retried with starts left of `retries`. Returns how many."""
    return len(
        tx.query(
            String(
                _cancel_set("$3"),
                " WHERE ",
                ordered_runs(
                    String(
                        "fill_request = $1 AND (status IN ('queued',",
                        " 'deferred') OR (status = 'running' AND NOT",
                        " cancel_requested) OR (status = 'failed' AND ",
                        RETRIED,
                        " AND starts - deferrals <= $2))",
                    )
                ),
                " RETURNING id",
            ),
            Params().int64(id).int64(Int64(retries)).float64(kill_seconds),
        )
    )


@fieldwise_init
struct RequestKey(Copyable, Movable):
    """A key of a request, as its latest run of the request left it."""

    var key: String
    var live: Bool
    """Its run is queued, deferred or running."""
    var done: Bool
    """Its run succeeded."""
    var gone: Bool
    """Its run was cancelled, or failed for good."""
    var again: Bool
    """Its run failed and will be retried."""


def request_keys(
    mut tx: Transaction, id: Int64, run_retries: Int
) raises -> List[RequestKey]:
    """Each key request `id` has queued a run of, with its latest run's
    state, `run_retries` the starts a run may make."""
    var out = List[RequestKey]()
    for r in tx.query(
        (
            "SELECT DISTINCT ON (k.key) k.key, r.status IN ('queued',"
            " 'deferred', 'running') AS live, r.status = 'succeeded' AS done,"
            " r.status = 'cancelled' OR (r.status = 'failed' AND (r.starts -"
            " r.deferrals > $2 OR coalesce(r.error, '') LIKE 'not started:"
            " its code is %')) AS gone, r.status = 'failed' AND r.starts -"
            " r.deferrals <= $2 AS again FROM orca.runs r,"
            " unnest(string_to_array(r.partitions, ',')) AS k(key) WHERE"
            " r.fill_request = $1 ORDER BY k.key, r.id DESC"
        ),
        Params().int64(id).int64(Int64(run_retries)),
    ):
        out.append(
            RequestKey(
                r.text("key"),
                r.bool("live"),
                r.bool("done"),
                r.bool("gone"),
                r.bool("again"),
            )
        )
    return out^
