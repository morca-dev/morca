"""The actions' queries (`morca._internal.actions`): runs started, resumed, rerun
and cancelled from the UI and the command line."""

from postgres import Connection, Params, Transaction

from morca._internal.db.live import ordered_runs, stalled_sql
from morca._internal.db.scheduler import RETRIED


def _cancel_set(kill_seconds: StaticString) -> String:
    """`UPDATE orca.runs SET ...` for cancelling the runs its `WHERE` names:
    one not running is `cancelled` at once, a running one gets
    `cancel_requested` and, at `kill_seconds` (a parameter) from now, its
    `cancel_at`."""
    return String(
        "UPDATE orca.runs SET cancel_requested = true, status = CASE WHEN",
        " status = 'running' THEN status ELSE 'cancelled' END, ended = CASE",
        " WHEN status = 'running' THEN ended ELSE now() END, cancel_at = CASE",
        " WHEN status = 'running' THEN coalesce(cancel_at, now() +",
        " make_interval(secs => ",
        kill_seconds,
        ")) END",
    )


def add_started_run(
    mut tx: Transaction,
    pipeline: String,
    registry_hash: String,
    keys: String,
    trigger: String,
) raises -> Int64:
    """A new queued run of `pipeline` over `keys`, with `trigger` (`ui` or
    `cli`); its id."""
    return (
        tx.query(
            (
                "INSERT INTO orca.runs (pipeline, registry_hash, partitions,"
                " trigger, status) VALUES ($1, $2, $3, $4, 'queued')"
                " RETURNING id"
            ),
            Params()
            .text(pipeline)
            .text(registry_hash)
            .text(keys)
            .text(trigger),
        )
        .row(0)
        .int64("id")
    )


@fieldwise_init
struct Resumable(Copyable, Movable):
    """A run, as resuming it sees it."""

    var pipeline: String
    var status: String
    var registry_hash: String
    var current: String
    """Its pipeline's registration now."""
    var has_binary: Bool
    var stalled: Bool


def resumable(mut conn: Connection, run: Int) raises -> Optional[Resumable]:
    """`run`, with whether it stalled (`stalled_sql`); None if there's no
    such run."""
    var rows = conn.query(
        String(
            "SELECT r.pipeline, r.status, r.registry_hash, p.registry_hash AS",
            " current,",
            " p.binary_path IS NOT NULL AS has_binary, ",
            stalled_sql(),
            " AS stalled FROM orca.runs r JOIN orca.pipelines p ON p.name =",
            " r.pipeline WHERE r.id = $1",
        ),
        Params().int64(Int64(run)),
    )
    if len(rows) == 0:
        return None
    var r = rows.row(0)
    return Resumable(
        r.text("pipeline"),
        r.text("status"),
        r.text("registry_hash"),
        r.text("current"),
        r.bool("has_binary"),
        r.bool("stalled"),
    )


def requeue(mut conn: Connection, run: Int, allow_new_code: Bool) raises -> Int:
    """Queues `run` again if it's failed, cancelled, deferred or stalled
    (`stalled_sql`); returns how many runs (0 or 1)."""
    return conn.execute(
        String(
            "UPDATE orca.runs SET status = 'queued', owner = NULL, heartbeat =",
            " NULL, ended = NULL, retry_at = NULL, cancel_requested = false,",
            (
                " error = NULL, allow_new_code = $2 WHERE id = $1 AND (status"
                " IN ('failed',"
            ),
            " 'cancelled', 'deferred') OR ",
            stalled_sql(),
            ")",
        ),
        Params().int64(Int64(run)).bool(allow_new_code),
    )


@fieldwise_init
struct Rerunnable(Copyable, Movable):
    """A run, as rerunning it from a step sees it."""

    var pipeline: String
    var partitions: String
    var status: String
    var registry_hash: String
    var current: String
    """Its pipeline's registration now."""
    var ord: Int64
    """The step's place among its pipeline's, from 0; -1 for no such step."""


def rerunnable(
    mut conn: Connection, run: Int, step: String
) raises -> Optional[Rerunnable]:
    """`run`, with `step`'s place; None if there's no such run."""
    var rows = conn.query(
        (
            "SELECT r.pipeline, r.partitions, r.status, r.registry_hash,"
            " p.registry_hash AS current, (SELECT x.n - 1 FROM"
            " jsonb_array_elements(p.describe->'steps') WITH ORDINALITY AS"
            " x(s, n) WHERE x.s->>'name' = $2) AS ord FROM orca.runs r JOIN"
            " orca.pipelines p ON p.name = r.pipeline WHERE r.id = $1"
        ),
        Params().int64(Int64(run)).text(step),
    )
    if len(rows) == 0:
        return None
    var r = rows.row(0)
    return Rerunnable(
        r.text("pipeline"),
        r.text("partitions"),
        r.text("status"),
        r.text("registry_hash"),
        r.text("current"),
        Int64(-1) if r.is_null("ord") else r.int64("ord"),
    )


def add_rerun(
    mut tx: Transaction, pipeline: String, registry_hash: String, keys: String
) raises -> Int64:
    """A new queued run of `pipeline` over `keys`, trigger `rerun`; its id."""
    return (
        tx.query(
            (
                "INSERT INTO orca.runs (pipeline, registry_hash, partitions,"
                " trigger, status) VALUES ($1, $2, $3, 'rerun', 'queued')"
                " RETURNING id"
            ),
            Params().text(pipeline).text(registry_hash).text(keys),
        )
        .row(0)
        .int64("id")
    )


def copy_steps(mut tx: Transaction, run: Int, to: Int64, ord: Int64) raises:
    """Copies into run `to` the steps of `run` before `ord` that succeeded,
    each naming the step it came from."""
    _ = tx.execute(
        (
            "INSERT INTO orca.steps (run, step, partition, ord, status, input,"
            " output, copied_from) SELECT $2, step, partition, ord,"
            " 'succeeded', input, output, coalesce(copied_from, id) FROM"
            " orca.steps WHERE run = $1 AND ord < $3 AND status = 'succeeded'"
        ),
        Params().int64(Int64(run)).int64(to).int64(ord),
    )


def cancel(
    mut conn: Connection, run: Int, kill_seconds: Float64
) raises -> Bool:
    """Cancels `run` if it's queued, running, failed or deferred (a running
    one is stopped `kill_seconds` from now if it hasn't); False if not."""
    var rows = conn.query(
        String(
            _cancel_set("$2"),
            " WHERE id = $1 AND status IN ('queued', 'running', 'failed',",
            " 'deferred') RETURNING id",
        ),
        Params().int64(Int64(run)).float64(kill_seconds),
    )
    return len(rows) == 1


def status_of(mut conn: Connection, run: Int) raises -> Optional[String]:
    """`run`'s status; None if there's no such run."""
    var st = conn.query(
        "SELECT status FROM orca.runs WHERE id = $1",
        Params().int64(Int64(run)),
    )
    if len(st) == 0:
        return None
    return st.row(0).text("status")


@fieldwise_init
struct Partitioning(Copyable, Movable):
    """A pipeline's partitions and retries, as cancelling its runs needs."""

    var kind: String
    var start: String
    var run_retries: Int64


def partitioning(
    mut conn: Connection, pipeline: String
) raises -> Optional[Partitioning]:
    """`pipeline`'s partition kind, first partition and `run_retries`; None
    if there's no such pipeline."""
    var rows = conn.query(
        (
            "SELECT coalesce(describe->'partitions'->>'kind', 'monthly') AS"
            " kind, coalesce(describe->'partitions'->>'start', '') AS start,"
            " coalesce((describe->>'run_retries')::bigint, 3) AS run_retries"
            " FROM orca.pipelines WHERE name = $1"
        ),
        Params().text(pipeline),
    )
    if len(rows) == 0:
        return None
    var r = rows.row(0)
    return Partitioning(r.text("kind"), r.text("start"), r.int64("run_retries"))


def cancel_over(
    mut conn: Connection,
    pipeline: String,
    all: Bool,
    keys: String,
    retries: Int64,
    kill_seconds: Float64,
) raises -> Int:
    """Cancels, as `cancel` does, `pipeline`'s runs over any of `keys`
    (comma-separated), or all of them: those queued, deferred, running and
    not stopping, or failed and due to be retried with starts left of
    `retries`. Returns how many."""
    var done = conn.query(
        String(
            _cancel_set("$5"),
            " WHERE ",
            ordered_runs(
                String(
                    "pipeline = $1 AND ($2 OR string_to_array(partitions,",
                    " ',') && string_to_array($3, ',')) AND (status IN",
                    " ('queued', 'deferred') OR (status = 'running' AND NOT",
                    " cancel_requested) OR (status = 'failed' AND ",
                    RETRIED,
                    " AND starts - deferrals <= $4))",
                )
            ),
            " RETURNING id",
        ),
        Params()
        .text(pipeline)
        .bool(all)
        .text(keys)
        .int64(retries)
        .float64(kill_seconds),
    )
    return len(done)


def cancel_picked(
    mut conn: Connection, ids: String, kill_seconds: Float64
) raises -> List[Int]:
    """Cancels, as `cancel` does, those of the runs `ids` (`1,2,3`) queued,
    deferred, or running and not stopping; returns them, in `id` order."""
    var out = List[Int]()
    for r in conn.query(
        String(
            "WITH c AS (",
            _cancel_set("$2"),
            " WHERE ",
            ordered_runs(
                "id = ANY(string_to_array($1, ',')::bigint[]) AND (status IN"
                " ('queued', 'deferred') OR (status = 'running' AND NOT"
                " cancel_requested))"
            ),
            " RETURNING id) SELECT id::bigint AS id FROM c ORDER BY id",
        ),
        Params().text(ids).float64(kill_seconds),
    ):
        out.append(Int(r.int64("id")))
    return out^


def failed_or_stalled(mut conn: Connection, ids: String) raises -> List[Int]:
    """Those of the runs `ids` (`1,2,3`) that failed, or stalled
    (`stalled_sql`)."""
    var out = List[Int]()
    for r in conn.query(
        String(
            "SELECT id::bigint AS id FROM orca.runs WHERE id =",
            " ANY(string_to_array($1, ',')::bigint[]) AND (status = 'failed'",
            " OR ",
            stalled_sql(),
            ")",
        ),
        Params().text(ids),
    ):
        out.append(Int(r.int64("id")))
    return out^


@fieldwise_init
struct RunKeys(Copyable, Movable):
    var id: Int
    var pipeline: String
    var partitions: String


def runs_keys(mut conn: Connection, ids: String) raises -> List[RunKeys]:
    """The pipeline and partitions of each of the runs `ids` (`1,2,3`), by
    id."""
    var out = List[RunKeys]()
    for r in conn.query(
        (
            "SELECT id::bigint AS id, pipeline, partitions FROM orca.runs"
            " WHERE id = ANY(string_to_array($1, ',')::bigint[]) ORDER BY id"
        ),
        Params().text(ids),
    ):
        out.append(
            RunKeys(
                Int(r.int64("id")), r.text("pipeline"), r.text("partitions")
            )
        )
    return out^
