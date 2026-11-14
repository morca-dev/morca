"""Remote workers' queries (`morca._internal.workers`): worker tokens in
`orca.workers`, what a worker says of itself, its claims of a pool's runs,
and the ends of those runs. `dead` in these is SQL for a run whose process
died, with the stale limit as `$2`."""

from postgres import Connection, Params, Transaction

from morca._internal.db.live import behind_sql, ordered_runs
from morca._internal.db.run_cluster import MEMBER_GRANTS_SQL, MEMBER_MB_SQL


# ── tokens ───────────────────────────────────────────────────────────────────


def add_token(
    mut conn: Connection,
    token_hash: String,
    pool: String,
    label: String,
    by: String,
    days: Int,
) raises -> String:
    """Records a worker token of `pool`, by its hash, lasting `days`;
    returns when it expires, as UTC ISO 8601."""
    return (
        conn.query(
            (
                "INSERT INTO orca.workers (token_hash, pool, label, created_by,"
                " expires) VALUES ($1, $2, $3, $4, now() + make_interval(days"
                " => $5)) RETURNING to_char(expires AT TIME ZONE 'UTC',"
                ' \'YYYY-MM-DD"T"HH24:MI:SS"Z"\') AS expires'
            ),
            Params()
            .text(token_hash)
            .text(pool)
            .text(label)
            .text(by)
            .int32(Int32(days)),
        )
        .row(0)
        .text("expires")
    )


def revoke(mut conn: Connection, id: Int) raises -> Bool:
    """Revokes worker token `id`; False if it's no live one."""
    return (
        conn.execute(
            (
                "UPDATE orca.workers SET revoked = now() WHERE id = $1 AND"
                " revoked IS NULL"
            ),
            Params().int64(Int64(id)),
        )
        == 1
    )


@fieldwise_init
struct Seen(Copyable, Movable):
    """A live worker token, as a request presents it."""

    var id: Int
    var pool: String
    var label: String


def seen(mut conn: Connection, token_hash: String) raises -> Optional[Seen]:
    """The live worker token whose hash is `token_hash`, marked seen now;
    None for any other."""
    var rows = conn.query(
        (
            "UPDATE orca.workers SET last_seen = now() WHERE token_hash = $1"
            " AND revoked IS NULL AND expires > now() RETURNING id, pool, label"
        ),
        Params().text(token_hash),
    )
    if len(rows) != 1:
        return None
    var r = rows.row(0)
    return Seen(Int(r.int64("id")), r.text("pool"), r.text("label"))


@fieldwise_init
struct Token(Copyable, Movable):
    """A worker token, and what its worker last said of itself."""

    var id: Int
    var pool: String
    var label: String
    var state: String
    """`live`, `revoked` or `expired`."""
    var name: String
    var image: String
    var last_seen: String
    var seen_ago: Int
    """Seconds since it was last seen; -1 if never."""
    var cpus: Int
    var memory_mb: Int
    var running: String
    var expires: String


def tokens(mut conn: Connection) raises -> List[Token]:
    """Every worker token, newest first."""
    comptime ts = '\'YYYY-MM-DD"T"HH24:MI:SS"Z"\''
    var out = List[Token]()
    for r in conn.query(
        String(
            "SELECT id, pool, label, CASE WHEN revoked IS NOT NULL THEN",
            " 'revoked' WHEN expires <= now() THEN 'expired' ELSE 'live' END",
            " AS state, coalesce(name, '') AS name, coalesce(image, '') AS",
            " image, coalesce(to_char(last_seen AT TIME ZONE 'UTC', ",
            ts,
            "), '') AS last_seen, coalesce(extract(epoch FROM now() -",
            " last_seen)::bigint, -1) AS ago, coalesce(cpus, 0) AS cpus,",
            " coalesce(memory_mb, 0) AS mem, coalesce(running, '') AS running,",
            " to_char(expires AT TIME ZONE 'UTC', ",
            ts,
            ") AS expires FROM orca.workers ORDER BY id DESC",
        )
    ):
        out.append(
            Token(
                Int(r.int64("id")),
                r.text("pool"),
                r.text("label"),
                r.text("state"),
                r.text("name"),
                r.text("image"),
                r.text("last_seen"),
                Int(r.int64("ago")),
                Int(r.int64("cpus")),
                Int(r.int64("mem")),
                r.text("running"),
                r.text("expires"),
            )
        )
    return out^


@fieldwise_init
struct RanOn(Copyable, Movable):
    """The worker that claimed a run's latest start."""

    var id: Int
    var label: String
    var name: String
    """Its host name, or empty."""


def ran_on(mut conn: Connection, run: Int) raises -> Optional[RanOn]:
    """The worker that claimed `run`'s latest start; None for a run no
    worker claimed."""
    var rows = conn.query(
        (
            "SELECT w.id, w.label, coalesce(w.name, '') AS name FROM orca.runs"
            " r JOIN orca.workers w ON w.id = r.worker WHERE r.id = $1 AND"
            " r.placement LIKE 'worker:%'"
        ),
        Params().int64(Int64(run)),
    )
    if len(rows) == 0:
        return None
    var r = rows.row(0)
    return RanOn(Int(r.int64("id")), r.text("label"), r.text("name"))


# ── what a worker says of itself ─────────────────────────────────────────────


def set_seen(
    mut conn: Connection,
    id: Int,
    name: String,
    image: String,
    cpus: Int,
    memory_mb: Int,
    running: String,
    room_cpus: Int = -1,
    room_memory_mb: Int = -1,
) raises:
    """Keeps what worker `id` says of itself (empty or 0 for unsaid; -1
    for the room it can grant a run)."""
    _ = conn.execute(
        (
            "UPDATE orca.workers SET name = nullif($2, ''), image ="
            " nullif($3, ''), cpus = nullif($4, 0), memory_mb = nullif($5, 0),"
            " running = nullif($6, ''), room_cpus = nullif($7, -1),"
            " room_memory_mb = nullif($8, -1) WHERE id = $1"
        ),
        Params()
        .int64(Int64(id))
        .text(name)
        .text(image)
        .int32(Int32(cpus))
        .int64(Int64(memory_mb))
        .text(running)
        .int32(Int32(room_cpus))
        .int64(Int64(room_memory_mb)),
    )


def pool_room(
    mut conn: Connection, pool: String, seconds: Int
) raises -> Tuple[Int, Int]:
    """The most CPUs and MB of memory a worker of `pool` seen in the last
    `seconds` said it can grant a run; 0 for none said."""
    var rows = conn.query(
        (
            "SELECT coalesce(max(room_cpus), 0)::bigint AS cpus,"
            " coalesce(max(room_memory_mb), 0)::bigint AS mb FROM"
            " orca.workers WHERE pool = $1 AND revoked IS NULL AND expires >"
            " now() AND last_seen > now() - make_interval(secs => $2)"
        ),
        Params().text(pool).float64(Float64(seconds)),
    )
    var r = rows.row(0)
    return (Int(r.int64("cpus")), Int(r.int64("mb")))


def hold_for_pressure(
    mut conn: Connection, placement: String, held: String, suffix: String
) raises:
    """Has the queued runs placed `placement`, but fill runs, that wait for
    a worker of the pool, say nothing, or say memory pressure on the same
    worker (ending `suffix`), say `held` instead."""
    _ = conn.execute(
        String(
            "UPDATE orca.runs SET held = $2 WHERE ",
            ordered_runs(
                (
                    "p.name = r.pipeline AND p.placement = $1 AND r.status ="
                    " 'queued' AND r.trigger <> 'fill' AND (r.held IS NULL OR"
                    " starts_with(r.held, 'held: waiting for a worker of pool"
                    " ') OR (starts_with(r.held, 'waiting: memory pressure ')"
                    " AND right(r.held, length($3)) = $3)) AND r.held IS"
                    " DISTINCT FROM $2"
                ),
                "orca.runs r JOIN orca.pipelines p ON p.name = r.pipeline",
            ),
        ),
        Params().text(placement).text(held).text(suffix),
    )


def unhold_pressure(
    mut conn: Connection, placement: String, held: String, suffix: String
) raises:
    """Has the queued runs placed `placement` that say memory pressure on
    the worker (ending `suffix`) say `held` instead."""
    _ = conn.execute(
        String(
            "UPDATE orca.runs SET held = $2 WHERE ",
            ordered_runs(
                (
                    "p.placement = $1 AND r.status = 'queued' AND"
                    " starts_with(r.held, 'waiting: memory pressure ') AND"
                    " right(r.held, length($3)) = $3"
                ),
                "orca.runs r JOIN orca.pipelines p ON p.name = r.pipeline",
            ),
        ),
        Params().text(placement).text(held).text(suffix),
    )


# ── claims ───────────────────────────────────────────────────────────────────


def granted(mut conn: Connection, worker: Int) raises -> Tuple[Int, Int]:
    """The CPUs and the MB of memory granted to `worker`'s running runs and
    its live members (`morca._internal.run_cluster`)."""
    var g = conn.query(
        String(
            "SELECT coalesce(sum(grant_cpus), 0)",
            MEMBER_GRANTS_SQL,
            " AS cpus, coalesce(sum(grant_memory_mb), 0)",
            MEMBER_MB_SQL,
            " AS mb FROM orca.runs WHERE worker = $1 AND status =",
            " 'running'",
        ),
        Params().int64(Int64(worker)),
    ).row(0)
    return (Int(g.int64("cpus")), Int(g.int64("mb")))


def granted_live(
    mut tx: Transaction, worker: Int, stale: Float64, dead: String
) raises -> Tuple[Int, Int]:
    """`granted`, of the runs whose process is alive (`dead`), in `tx`."""
    var g = tx.query(
        String(
            "SELECT coalesce(sum(grant_cpus), 0)",
            MEMBER_GRANTS_SQL,
            " AS cpus, coalesce(sum(grant_memory_mb), 0)",
            MEMBER_MB_SQL,
            " AS mb FROM orca.runs",
            " WHERE worker = $1 AND status = 'running' AND NOT ",
            dead,
        ),
        Params().int64(Int64(worker)).float64(stale),
    ).row(0)
    return (Int(g.int64("cpus")), Int(g.int64("mb")))


@fieldwise_init
struct Candidate(Copyable, Movable):
    """A queued run a worker might claim."""

    var id: Int64
    var pipeline: String
    var trigger: String


def candidates(
    mut conn: Connection, placement: String
) raises -> List[Candidate]:
    """The oldest queued run of each of the unpaused, registered pipelines
    placed `placement`, and of its fill runs (with fills on), but those
    behind an older run of their keys: the highest `priority` first
    (#421), and within one, the others first, then the fill runs, each
    oldest first."""
    var out = List[Candidate]()
    for c in conn.query(
        "SELECT id, pipeline, trigger FROM (SELECT DISTINCT ON"
        " (r.pipeline, r.trigger = 'fill') r.id, r.pipeline, r.trigger,"
        " p.priority FROM orca.runs r JOIN orca.pipelines p ON p.name ="
        " r.pipeline"
        " WHERE r.status = 'queued' AND p.placement = $1 AND NOT p.paused"
        " AND p.binary_path IS NOT NULL AND (r.trigger <> 'fill' OR"
        " p.fills = 'all' OR r.fill_request IS NOT NULL) AND NOT "
        + behind_sql("r")
        + " ORDER BY r.pipeline, r.trigger = 'fill', r.id) AS c ORDER BY"
        " priority DESC, trigger = 'fill', id",
        Params().text(placement),
    ):
        out.append(
            Candidate(c.int64("id"), c.text("pipeline"), c.text("trigger"))
        )
    return out^


def hold_queued(
    mut conn: Connection, pipeline: String, why: String, fill: Bool
) raises:
    """Has `pipeline`'s queued fill runs, or its others, say `why`."""
    _ = conn.execute(
        String(
            "UPDATE orca.runs SET held = $2 WHERE ",
            ordered_runs(
                "pipeline = $1 AND status = 'queued' AND (trigger = 'fill') ="
                " $3 AND held IS DISTINCT FROM $2"
            ),
        ),
        Params().text(pipeline).text(why).bool(fill),
    )


@fieldwise_init
struct Claimed(Copyable, Movable):
    """A run a worker claimed, as it started."""

    var start: Int
    var allow_new_code: Bool
    var partitions: String


def start_claimed(
    mut tx: Transaction,
    run: Int64,
    owner: String,
    placement: String,
    worker: Int,
    request_cpus: String,
    request_memory_gb: String,
    grant_cpus: Int,
    grant_memory_mb: Int,
    request_source: String,
    request_runs: Int,
) raises -> Optional[Claimed]:
    """Starts queued run `run` on `worker`, owned by `owner`, with what it
    asked for and was granted (empty or 0 for none); None if it isn't
    queued any more."""
    var got = tx.query(
        (
            "UPDATE orca.runs SET status = 'running', owner = $2, heartbeat"
            " = NULL, started = clock_timestamp(), ended = NULL, starts ="
            " starts + 1,"
            " retry_at = NULL, error = NULL, waiting_since = NULL,"
            " cpu_millis = 0, placement = $3, held = NULL, worker = $4,"
            " request_cpus = nullif($5, ''), request_memory_gb ="
            " nullif($6, ''), grant_cpus = nullif($7, 0), grant_memory_mb"
            " = nullif($8, 0), request_source = nullif($9, ''),"
            " request_runs = nullif($10, 0) WHERE id = $1 AND status ="
            " 'queued' RETURNING starts, allow_new_code, partitions"
        ),
        Params()
        .int64(run)
        .text(owner)
        .text(placement)
        .int64(Int64(worker))
        .text(request_cpus)
        .text(request_memory_gb)
        .int64(Int64(grant_cpus))
        .int64(Int64(grant_memory_mb))
        .text(request_source)
        .int64(Int64(request_runs)),
    )
    if len(got) != 1:
        return None
    var r = got.row(0)
    return Claimed(
        Int(r.int64("starts")), r.bool("allow_new_code"), r.text("partitions")
    )


def give_back(
    mut conn: Connection,
    run: Int64,
    start: Int64,
    worker: Int,
    held: String,
    owner: String,
) raises -> Int:
    """Queues again, saying `held`, `run` that `worker` claimed at `start`
    (owner `owner`) and didn't start, its start given back; returns how
    many runs (0 or 1)."""
    return conn.execute(
        (
            "UPDATE orca.runs SET status = 'queued', owner = NULL, heartbeat ="
            " NULL, starts = starts - 1, worker = NULL, held = $4 WHERE id ="
            " $1 AND status = 'running' AND owner = $5 AND starts = $2 AND"
            " worker = $3"
        ),
        Params()
        .int64(run)
        .int64(start)
        .int64(Int64(worker))
        .text(held)
        .text(owner),
    )


# ── a run's end ──────────────────────────────────────────────────────────────


@fieldwise_init
struct Contained(Copyable, Movable):
    """A worker's run, as its cgroup's end sees it."""

    var pipeline: String
    var grant_mb: Int64
    var memory_gb: String
    """Its pipeline's request, or empty."""
    var running: Bool


def contained(
    mut conn: Connection, run: Int64, worker: Int, start: Int64
) raises -> Optional[Contained]:
    """`run`, if `worker` claimed it at `start`."""
    var rows = conn.query(
        (
            "SELECT r.pipeline, coalesce(r.grant_memory_mb, 0) AS grant_mb,"
            " coalesce(p.memory_gb, '') AS memory_gb, r.status = 'running' AS"
            " running FROM orca.runs r JOIN orca.pipelines p ON p.name ="
            " r.pipeline WHERE r.id = $1 AND r.worker = $2 AND r.starts = $3"
        ),
        Params().int64(run).int64(Int64(worker)).int64(start),
    )
    if len(rows) != 1:
        return None
    var r = rows.row(0)
    return Contained(
        r.text("pipeline"),
        r.int64("grant_mb"),
        r.text("memory_gb"),
        r.bool("running"),
    )


def set_attempt_limits(
    mut conn: Connection,
    run: Int64,
    pid: String,
    limit_mb: Int,
    grant_mb: Int64,
    stall_ms: Int64,
    stall_full_ms: Int64,
) raises:
    """Keeps, on `run`'s attempts by process `pid` that have none yet, the
    cgroup's memory limit, the grant, and the stall times (-1 for
    unmeasured)."""
    _ = conn.execute(
        (
            "UPDATE orca.attempts a SET memory_limit_mb = $3, grant_memory_mb"
            " = nullif($4, 0), memory_stall_ms = nullif($5, -1),"
            " memory_stall_full_ms = nullif($6, -1) FROM orca.steps st WHERE"
            " st.id = a.step AND st.run = $1 AND a.host LIKE '%:' || $2 AND"
            " a.memory_limit_mb IS NULL"
        ),
        Params()
        .int64(run)
        .text(pid)
        .int64(Int64(limit_mb))
        .int64(grant_mb)
        .int64(stall_ms)
        .int64(stall_full_ms),
    )


def fail_killed(
    mut conn: Connection, run: Int64, worker: Int, start: Int64, why: String
) raises:
    """Fails `run`, unretried, with `why`, if it's running at `start` on
    `worker`."""
    _ = conn.execute(
        (
            "UPDATE orca.runs SET status = 'failed', ended = now(),"
            " heartbeat = NULL, retry_at = NULL, error = $4,"
            " unretried_start = starts WHERE id = $1"
            " AND status = 'running' AND worker = $2 AND starts = $3"
        ),
        Params().int64(run).int64(Int64(worker)).int64(start).text(why),
    )


def fail_unclaimed(
    mut conn: Connection,
    run: Int64,
    start: Int64,
    worker: Int,
    why: String,
    owner: String,
) raises -> Int:
    """Fails `run` with `why` if `worker` claimed it at `start` and its
    process never did (owner still `owner`); returns how many runs."""
    return conn.execute(
        (
            "UPDATE orca.runs SET status = 'failed', ended = now(), heartbeat ="
            " NULL, error = $4 WHERE id = $1 AND status = 'running' AND owner"
            " = $5 AND starts = $2 AND worker = $3"
        ),
        Params()
        .int64(run)
        .int64(start)
        .int64(Int64(worker))
        .text(why)
        .text(owner),
    )


# ── store calls ──────────────────────────────────────────────────────────────


def claimed_pipeline(
    mut conn: Connection, run: Int64, worker: Int, placement: String
) raises -> Optional[String]:
    """`run`'s pipeline, if `worker` (placed `placement`) claimed its latest
    start."""
    var rows = conn.query(
        (
            "SELECT pipeline FROM orca.runs WHERE id = $1 AND worker = $2 AND"
            " placement = $3"
        ),
        Params().int64(run).int64(Int64(worker)).text(placement),
    )
    if len(rows) != 1:
        return None
    return rows.row(0).text("pipeline")


def attempt_of(mut conn: Connection, attempt: Int64, run: Int64) raises -> Bool:
    """Whether `attempt` is one of `run`'s."""
    return (
        len(
            conn.query(
                (
                    "SELECT 1 FROM orca.attempts a JOIN orca.steps s ON s.id ="
                    " a.step WHERE a.id = $1 AND s.run = $2"
                ),
                Params().int64(attempt).int64(run),
            )
        )
        == 1
    )
