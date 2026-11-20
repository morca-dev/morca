"""The SQLite run store's queries (`morca._internal.sqlite_store`): the dialect of
`morca._internal.db.runs` and `morca._internal.db.steps` for a file, function for function,
over the same rows (`morca._internal.db.run_rows`).

**Why a module of its own.** The two dialects share no statement text: the
tables have no `orca.` schema here, parameters are `?1`, not `$1`, and the
clock is `NOW` (Unix seconds from `julianday`), not `now()`. Past those,
the differences are the substance of each query, and stay written out in
it rather than substituted into one text:

- times are Unix seconds, so an age is `NOW - ?3`, not
  `now() - make_interval(secs => $3)`;
- a step's input and output are hex text (`to_hex`, which the caller applies
  once before its retries, and `from_hex`), not `bytea`, and booleans are
  integers;
- a run's token is made in SQL here (`UUID7`), where Postgres's default
  `orca.uuidv7()` makes it;
- `version` reads the describe with `json_extract`, where Postgres uses
  `->>` and `data_version_sql`; `register` sets `first_seen` and
  `last_seen` itself, where Postgres has defaults;
- `runs` matches a status list with `instr`, not `ANY(string_to_array())`;
  `steps` joins the latest attempt by a subquery, not `LATERAL`; and
  `fail_running_attempts` uses `step IN (...)`, not `UPDATE ... FROM`;
- a NULL error is `nullif(?4, '')` in the SQL, where Postgres binds a null.

Locking is the caller's, as on Postgres: `morca._internal.sqlite_store` brackets each
change in `BEGIN IMMEDIATE` ... `COMMIT`, which takes the file's write lock
up front, where Postgres takes its row locks in the transaction. A claim
is a single guarded `UPDATE`, as there.
"""

from sqlite import Database, Statement

from morca._internal.db.run_rows import (
    Fence,
    Owned,
    RunInfo,
    StepInfo,
    Succeeded,
    Usage,
)

comptime NOW = "((julianday('now') - 2440587.5) * 86400.0)"
"""Unix seconds, to the millisecond, in SQL."""

# SQL for a new UUID version 7, as text: the milliseconds since 1970 in its
# first 48 bits, then the version, the variant and random bits. A run's
# token, as Postgres's `orca.uuidv7()` makes it.
comptime UUID7 = (
    "(SELECT lower(substr(t.ms, 1, 8) || '-' || substr(t.ms, 9, 4) || '-7' ||"
    " substr(hex(randomblob(2)), 2, 3) || '-' || substr('89ab', 1 + (random()"
    " & 3), 1) || substr(hex(randomblob(2)), 2, 3) || '-' ||"
    " hex(randomblob(6))) FROM (SELECT printf('%012x', CAST((julianday('now')"
    " - 2440587.5) * 86400000 AS INTEGER)) AS ms) t)"
)


comptime _HEX = "0123456789abcdef"


def to_hex(b: Span[UInt8, _]) -> String:
    """`b` as lowercase hex: how a step's input and output are kept here,
    where Postgres keeps `bytea`."""
    var out = String(capacity_bytes=2 * len(b))
    for x in b:
        out.write(_HEX[byte=Int(x >> 4)], _HEX[byte=Int(x & 15)])
    return out^


def _nibble(c: UInt8) raises -> UInt8:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    raise Error("morca: not hex in the SQLite store")


def from_hex(s: String) raises -> List[UInt8]:
    """The bytes of `to_hex`'s text `s`."""
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b) // 2)
    for i in range(0, len(b) - 1, 2):
        out.append(_nibble(b[i]) << 4 | _nibble(b[i + 1]))
    return out^


# --- Pipelines, as a pipeline binary registers itself ---


def register(
    db: Database, pipeline: String, registry_hash: String, describe: String
) raises:
    """Records a pipeline, or updates it to this binary's DAG."""
    var st = db.prepare(
        String(
            "INSERT INTO pipelines (name, registry_hash, describe,",
            " first_seen, last_seen) VALUES (?1, ?2, ?3, ",
            NOW,
            ", ",
            NOW,
            ") ON CONFLICT (name) DO UPDATE SET registry_hash =",
            " excluded.registry_hash, describe = excluded.describe,",
            " last_seen = excluded.last_seen",
        )
    )
    st.bind_text(1, pipeline)
    st.bind_text(2, registry_hash)
    st.bind_text(3, describe)
    _ = st.step()


def set_version(db: Database, pipeline: String, version: Int) raises:
    """Records that `pipeline`'s code now is `version`."""
    var up = db.prepare("UPDATE pipelines SET version = ?2 WHERE name = ?1")
    up.bind_text(1, pipeline)
    up.bind_int(2, version)
    _ = up.step()


def scheduled_hash(db: Database, pipeline: String) raises -> String:
    """The registry hash `morca register` gave `pipeline`, or empty."""
    var st = db.prepare(
        "SELECT registry_hash FROM pipelines WHERE name = ?1 AND"
        " binary_path IS NOT NULL"
    )
    st.bind_text(1, pipeline)
    var r = st.step()
    return r.value().text_val(0) if r else String()


def version(
    db: Database,
    pipeline: String,
    registry_hash: String,
    describe: String,
    image: String,
) raises -> Int:
    """The `pipeline_versions` row of `pipeline`'s code `registry_hash`,
    from the source `describe` names, in `image`; recorded the first time
    it's seen."""
    var st = db.prepare(
        String(
            "INSERT INTO pipeline_versions (pipeline, registry_hash,",
            " source, commit_sha, dirty, image, first_seen, last_seen)",
            " VALUES (?1, ?2, coalesce(json_extract(?3,",
            " '$.source.repo'), ''), coalesce(json_extract(?3,",
            " '$.source.commit'), ''), coalesce(json_extract(?3,",
            " '$.source.dirty'), 0), ?4, ",
            NOW,
            ", ",
            NOW,
            ") ON CONFLICT (pipeline, registry_hash, source, commit_sha,",
            " dirty, image) DO UPDATE SET last_seen = excluded.last_seen",
            " RETURNING id",
        )
    )
    st.bind_text(1, pipeline)
    st.bind_text(2, registry_hash)
    st.bind_text(3, describe)
    st.bind_text(4, image)
    return st.step().value().int_val(0)


# --- Runs ---


def create(
    db: Database,
    pipeline: String,
    registry_hash: String,
    partitions: String,
    trigger: String,
    owner: String,
) raises -> Int:
    """A new run, already claimed by `owner`, with a new token; its id."""
    var st = db.prepare(
        String(
            "INSERT INTO runs (pipeline, registry_hash, partitions,",
            " trigger, status, owner, heartbeat, created, started, token)",
            " VALUES (?1, ?2, ?3, ?4, 'running', ?5, ",
            NOW,
            ", ",
            NOW,
            ", ",
            NOW,
            ", ",
            UUID7,
            ") RETURNING id",
        )
    )
    st.bind_text(1, pipeline)
    st.bind_text(2, registry_hash)
    st.bind_text(3, partitions)
    st.bind_text(4, trigger)
    st.bind_text(5, owner)
    return st.step().value().int_val(0)


def claim(
    db: Database, run: Int, owner: String, stale_seconds: Float64
) raises -> Bool:
    """Makes `owner` the run's writer if it's `queued`, `failed`,
    `deferred`, or `running` with a heartbeat older than `stale_seconds`
    or cleared, in one guarded `UPDATE`; whether it did."""
    var st = db.prepare(
        String(
            "UPDATE runs SET status = 'running', owner = ?2, heartbeat = ",
            NOW,
            ", ended = NULL, error = NULL WHERE id = ?1 AND status IN",
            (
                " ('queued', 'running', 'failed', 'deferred') AND"
                " (heartbeat IS NULL OR"
            ),
            " heartbeat < ",
            NOW,
            " - ?3) RETURNING id",
        )
    )
    st.bind_int(1, run)
    st.bind_text(2, owner)
    st.bind_float(3, stale_seconds)
    if st.step():
        return True
    return False


def ran_version(db: Database, run: Int, version: Int) raises:
    """Records that `run` is running `version`'s code."""
    var st = db.prepare("UPDATE runs SET version = ?2 WHERE id = ?1")
    st.bind_int(1, run)
    st.bind_int(2, version)
    _ = st.step()


def _run_infos(mut st: Statement) raises -> List[RunInfo]:
    var out = List[RunInfo]()
    while True:
        var r = st.step()
        if not r:
            break
        ref row = r.value()
        out.append(
            RunInfo(
                row.int_val(0),
                row.text_val(1),
                row.text_val(2),
                row.text_val(3),
                row.text_val(4),
                row.text_val(5),
                row.text_val(6),
            )
        )
    return out^


comptime _RUN_COLUMNS = (
    "SELECT id, pipeline, registry_hash, partitions, status,"
    " coalesce(owner, ''), coalesce(error, '') FROM runs"
)


def info(db: Database, run: Int) raises -> Optional[RunInfo]:
    """Run `run`'s row, or none if there's no such run."""
    var st = db.prepare(String(_RUN_COLUMNS, " WHERE id = ?1"))
    st.bind_int(1, run)
    var got = _run_infos(st)
    if len(got) == 0:
        return None
    return got[0].copy()


def latest(
    db: Database, limit: Int, before: Int, statuses: String
) raises -> List[RunInfo]:
    """The latest `limit` runs, newest first; those under `before` if it
    isn't 0, and with a status of `statuses` (comma-separated) unless it's
    empty."""
    # By the rowid, a range of the table's own b-tree.
    var st = db.prepare(
        String(
            _RUN_COLUMNS,
            " WHERE (?2 = 0 OR id < ?2) AND (?3 = '' OR instr(',' || ?3",
            " || ',', ',' || status || ',') > 0) ORDER BY id DESC LIMIT ?1",
        )
    )
    st.bind_int(1, limit)
    st.bind_int(2, before)
    st.bind_text(3, statuses)
    return _run_infos(st)


def finish(db: Database, run: Int, owner: String, status: String) raises:
    """Ends the run as `status` and clears its heartbeat, if `owner` holds
    it."""
    var st = db.prepare(
        String(
            "UPDATE runs SET status = ?2, ended = ",
            NOW,
            ", heartbeat = NULL WHERE id = ?1 AND owner = ?3",
        )
    )
    st.bind_int(1, run)
    st.bind_text(2, status)
    st.bind_text(3, owner)
    _ = st.step()


def defer_run(db: Database, run: Int, owner: String, until: Int64) raises:
    """Ends the run `deferred`, to start again at `until`, and counts the
    deferral, if `owner` holds it."""
    var st = db.prepare(
        String(
            "UPDATE runs SET status = 'deferred', ended = ",
            NOW,
            ", heartbeat = NULL, retry_at = ?3, deferrals =",
            " deferrals + 1 WHERE id = ?1 AND owner = ?2",
        )
    )
    st.bind_int(1, run)
    st.bind_text(2, owner)
    st.bind_int(3, Int(until))
    _ = st.step()


def cancel_requested(db: Database, run: Int) raises -> Bool:
    """Whether the run was asked to cancel."""
    var st = db.prepare("SELECT cancel_requested FROM runs WHERE id = ?1")
    st.bind_int(1, run)
    return st.step().value().int_val(0) != 0


def cancel_due(db: Database, run: Int, owner: String) raises -> Bool:
    """Whether `owner` holds the run running and it was asked to cancel
    with a `cancel_at` that has passed: the watchdog then stops it."""
    var st = db.prepare(
        String(
            "SELECT 1 FROM runs WHERE id = ?1 AND owner = ?2 AND status =",
            " 'running' AND cancel_requested <> 0 AND cancel_at <= ",
            NOW,
        )
    )
    st.bind_int(1, run)
    st.bind_text(2, owner)
    if st.step():
        return True
    return False


def cancel(db: Database, run: Int, owner: String) raises:
    """Ends the run `cancelled`, in the caller's transaction, if `owner`
    holds it."""
    var st = db.prepare(
        String(
            "UPDATE runs SET status = 'cancelled', ended = ",
            NOW,
            ", heartbeat = NULL WHERE id = ?1 AND owner = ?2",
        )
    )
    st.bind_int(1, run)
    st.bind_text(2, owner)
    _ = st.step()


def token(db: Database, run: Int) raises -> String:
    """The run's token, empty for none or no run."""
    var st = db.prepare("SELECT coalesce(token, '') FROM runs WHERE id = ?1")
    st.bind_int(1, run)
    var got = st.step()
    if not got:
        return String()
    return got.value().text_val(0)


def fence(
    db: Database, run: Int, fresh_seconds: Float64
) raises -> Optional[Fence]:
    """Who holds the run, its status, and whether its heartbeat is younger
    than `fresh_seconds`; none if there's no such run."""
    var st = db.prepare(
        String(
            "SELECT coalesce(owner, ''), status, coalesce(",
            "heartbeat > ",
            NOW,
            " - ?2, 0) FROM runs WHERE id = ?1",
        )
    )
    st.bind_int(1, run)
    st.bind_float(2, fresh_seconds)
    var got = st.step()
    if not got:
        return None
    ref row = got.value()
    return Fence(row.text_val(0), row.text_val(1), row.int_val(2) != 0)


def still_owner(db: Database, run: Int, owner: String) raises -> Owned:
    """Refreshes the run's heartbeat if `owner` still holds it running, in
    the caller's transaction; whether it did, and whether the run was asked
    to cancel."""
    var st = db.prepare(
        String(
            "UPDATE runs SET heartbeat = ",
            NOW,
            " WHERE id = ?1 AND owner = ?2 AND status = 'running'",
            " RETURNING cancel_requested",
        )
    )
    st.bind_int(1, run)
    st.bind_text(2, owner)
    var r = st.step()
    if not r:
        return Owned(False, False)
    return Owned(True, r.value().int_val(0) != 0)


def beat(db: Database, run: Int, owner: String) raises:
    """One beat of the run's heartbeat, if `owner` holds it running."""
    var st = db.prepare(
        String(
            "UPDATE runs SET heartbeat = ",
            NOW,
            " WHERE id = ?1 AND owner = ?2 AND status = 'running'",
        )
    )
    st.bind_int(1, run)
    st.bind_text(2, owner)
    _ = st.step()


def fail(db: Database, run: Int, owner: String, why: String) raises:
    """Ends the run `failed` with `why`, if `owner` holds it."""
    var r = db.prepare(
        String(
            "UPDATE runs SET status = 'failed', ended = ",
            NOW,
            ", heartbeat = NULL, error = ?3 WHERE id = ?1 AND",
            " owner = ?2",
        )
    )
    r.bind_int(1, run)
    r.bind_text(2, owner)
    r.bind_text(3, why)
    _ = r.step()


# --- Steps and attempts ---


@fieldwise_init
struct TimedOut(Copyable, Movable):
    """A running attempt past its step's timeout: its `attempts` id and its
    step's partition."""

    var attempt: Int
    var partition: String


def timed_out(
    db: Database, run: Int, step: String, owner: String, secs: Float64
) raises -> Optional[TimedOut]:
    """An attempt of the run's `step` still running after `secs`, while
    `owner` holds the run running, or none."""
    var st = db.prepare(
        String(
            "SELECT a.id, s.partition FROM attempts a JOIN steps s ON",
            " s.id = a.step JOIN runs r ON r.id = s.run WHERE s.run =",
            " ?1 AND s.step = ?2 AND r.owner = ?3 AND r.status =",
            " 'running' AND a.status = 'running' AND a.started <= ",
            NOW,
            " - ?4 LIMIT 1",
        )
    )
    st.bind_int(1, run)
    st.bind_text(2, step)
    st.bind_text(3, owner)
    st.bind_float(4, secs)
    var got = st.step()
    if not got:
        return None
    return TimedOut(got.value().int_val(0), got.value().text_val(1))


def fail_attempt(db: Database, attempt: Int, why: String) raises -> Bool:
    """Fails attempt `attempt` (its `attempts` id) with `why`, and its
    step, in the caller's transaction, if it's still `running`; whether it
    was."""
    var a = db.prepare(
        String(
            "UPDATE attempts SET status = 'failed', ended = ",
            NOW,
            ", error = ?2 WHERE id = ?1 AND status = 'running'",
        )
    )
    a.bind_int(1, attempt)
    a.bind_text(2, why)
    _ = a.step()
    if db.changes() != 1:
        return False
    var s = db.prepare(
        "UPDATE steps SET status = 'failed', error = ?2 WHERE id ="
        " (SELECT step FROM attempts WHERE id = ?1)"
    )
    s.bind_int(1, attempt)
    s.bind_text(2, why)
    _ = s.step()
    return True


def fail_running_attempts(db: Database, run: Int, why: String) raises -> Int:
    """Fails the run's attempts still `running` with `why`, in the caller's
    transaction; how many there were."""
    var st = db.prepare(
        String(
            "UPDATE attempts SET status = 'failed', ended = ",
            NOW,
            ", error = ?2 WHERE status = 'running' AND step IN",
            " (SELECT id FROM steps WHERE run = ?1)",
        )
    )
    st.bind_int(1, run)
    st.bind_text(2, why)
    _ = st.step()
    return db.changes()


def fail_running_steps(db: Database, run: Int, why: String) raises:
    """Fails the run's steps still `running` with `why`, in the caller's
    transaction."""
    var steps = db.prepare(
        "UPDATE steps SET status = 'failed', error = ?2"
        " WHERE run = ?1 AND status = 'running'"
    )
    steps.bind_int(1, run)
    steps.bind_text(2, why)
    _ = steps.step()


def succeeded(db: Database, run: Int) raises -> List[Succeeded]:
    """The run's succeeded steps, with their outputs decoded, for resuming
    it."""
    var out = List[Succeeded]()
    var st = db.prepare(
        "SELECT step, partition, coalesce(output, '') FROM steps WHERE"
        " run = ?1 AND status = 'succeeded' ORDER BY id"
    )
    st.bind_int(1, run)
    while True:
        var r = st.step()
        if not r:
            break
        ref row = r.value()
        out.append(
            Succeeded(
                row.text_val(0),
                row.text_val(1),
                from_hex(row.text_val(2)),
            )
        )
    return out^


def of_run(db: Database, run: Int) raises -> List[StepInfo]:
    """A run's steps in run order, with their attempt counts and their
    latest attempts' logs and usage."""
    var out = List[StepInfo]()
    var st = db.prepare(
        "SELECT s.step, s.partition, s.status, coalesce(s.error, ''),"
        " (SELECT count(*) FROM attempts a WHERE a.step = s.id),"
        " coalesce(l.log, ''), coalesce(l.peak_rss_bytes, -1),"
        " coalesce(l.cpu_seconds, -1.0), coalesce(l.peak_cpus, -1.0)"
        " FROM steps s LEFT JOIN attempts l ON l.id = (SELECT a.id FROM"
        " attempts a WHERE a.step = s.id ORDER BY a.attempt DESC LIMIT 1)"
        " WHERE s.run = ?1 ORDER BY s.ord, s.id"
    )
    st.bind_int(1, run)
    while True:
        var r = st.step()
        if not r:
            break
        ref row = r.value()
        out.append(
            StepInfo(
                row.text_val(0),
                row.text_val(1),
                row.text_val(2),
                row.int_val(4),
                row.text_val(3),
                row.text_val(5),
                Usage(row.int_val(6), row.float_val(7), row.float_val(8)),
            )
        )
    return out^


def start(
    db: Database,
    run: Int,
    step: String,
    partition: String,
    ord: Int,
    input: String,
) raises -> Int:
    """Marks the step `running` with `input` (hex), adding its row if it
    has none, in the caller's transaction; its `steps` id."""
    var up = db.prepare(
        "INSERT INTO steps (run, step, partition, ord, status, input)"
        " VALUES (?1, ?2, ?3, ?4, 'running', ?5) ON CONFLICT (run,"
        " step, partition) DO UPDATE SET status = 'running', input ="
        " excluded.input, error = NULL RETURNING id"
    )
    up.bind_int(1, run)
    up.bind_text(2, step)
    up.bind_text(3, partition)
    up.bind_int(4, ord)
    up.bind_text(5, input)
    return up.step().value().int_val(0)


def next_attempt(db: Database, step: Int) raises -> Int:
    """The number of step `step`'s next attempt."""
    var nq = db.prepare(
        "SELECT coalesce(max(attempt), 0) + 1 FROM attempts WHERE step = ?1"
    )
    nq.bind_int(1, step)
    return nq.step().value().int_val(0)


def add_attempt(
    db: Database, step: Int, attempt: Int, host: String, registry_hash: String
) raises -> Int:
    """Adds attempt `attempt` of step `step`, `running` on `host`, in the
    caller's transaction; its `attempts` id."""
    var ins = db.prepare(
        String(
            "INSERT INTO attempts (step, attempt, status, host,",
            " registry_hash, started) VALUES (?1, ?2, 'running', ?3,",
            " ?4, ",
            NOW,
            ") RETURNING id",
        )
    )
    ins.bind_int(1, step)
    ins.bind_int(2, attempt)
    ins.bind_text(3, host)
    ins.bind_text(4, registry_hash)
    return ins.step().value().int_val(0)


def step_id(
    db: Database, run: Int, step: String, partition: String
) raises -> Int:
    """The `steps` id of the run's `step` for `partition`."""
    var q = db.prepare(
        "SELECT id FROM steps WHERE run = ?1 AND step = ?2 AND partition = ?3"
    )
    q.bind_int(1, run)
    q.bind_text(2, step)
    q.bind_text(3, partition)
    return q.step().value().int_val(0)


def finish_attempt(
    db: Database, step: Int, attempt: Int, status: String, error: String
) raises:
    """Ends attempt `attempt` of step `step` as `status`, with `error` (null
    when empty), in the caller's transaction."""
    var a = db.prepare(
        String(
            "UPDATE attempts SET status = ?3, ended = ",
            NOW,
            ", error = nullif(?4, '') WHERE step = ?1 AND attempt = ?2",
        )
    )
    a.bind_int(1, step)
    a.bind_int(2, attempt)
    a.bind_text(3, status)
    a.bind_text(4, error)
    _ = a.step()


def finish(
    db: Database,
    step: Int,
    status: String,
    output: String,
    keep_output: Bool,
    error: String,
) raises:
    """Settles step `step` as `status`, with `output` (hex) if
    `keep_output` (it succeeded) and `error` (null when empty), in the
    caller's transaction."""
    var s = db.prepare(
        "UPDATE steps SET status = ?2, output = ?3, error = nullif(?4,"
        " '') WHERE id = ?1"
    )
    s.bind_int(1, step)
    s.bind_text(2, status)
    if keep_output:
        s.bind_text(3, output)
    else:
        s.bind_null(3)
    s.bind_text(4, error)
    _ = s.step()


def skip(
    db: Database,
    run: Int,
    step: String,
    partition: String,
    ord: Int,
    reason: String,
) raises:
    """Marks the step `skipped` for `reason`, adding its row if it has
    none, in the caller's transaction."""
    var st = db.prepare(
        "INSERT INTO steps (run, step, partition, ord, status, error)"
        " VALUES (?1, ?2, ?3, ?4, 'skipped', ?5) ON CONFLICT (run,"
        " step, partition) DO UPDATE SET status = 'skipped', error ="
        " excluded.error, output = NULL"
    )
    st.bind_int(1, run)
    st.bind_text(2, step)
    st.bind_text(3, partition)
    st.bind_int(4, ord)
    st.bind_text(5, reason)
    _ = st.step()


def set_log(db: Database, attempt: Int, path: String) raises:
    """Records attempt `attempt`'s (its `attempts` id) log file."""
    var st = db.prepare("UPDATE attempts SET log = ?2 WHERE id = ?1")
    st.bind_int(1, attempt)
    st.bind_text(2, path)
    _ = st.step()


def pinned_reads(
    db: Database, run: Int, step: String, partition: String
) raises -> Dict[String, Int64]:
    """The snapshot each table was read at by the run's `step` for
    `partition`, in its first attempt that read it."""
    var out = Dict[String, Int64]()
    var st = db.prepare(
        "SELECT r.table_name, r.snapshot_id FROM reads r JOIN"
        " attempts a ON a.id = r.attempt JOIN steps s ON s.id ="
        " a.step WHERE s.run = ?1 AND s.step = ?2 AND s.partition"
        " = ?3 ORDER BY a.attempt DESC"
    )
    st.bind_int(1, run)
    st.bind_text(2, step)
    st.bind_text(3, partition)
    # Newest first, so the first attempt's snapshot is the one left.
    while True:
        var row = st.step()
        if not row:
            break
        out[row.value().text_val(0)] = Int64(row.value().int_val(1))
    return out^


def record(
    db: Database,
    commit: Bool,
    attempt: Int,
    table: String,
    snapshot_id: Int64,
    dataset: String,
) raises:
    """Records that attempt `attempt` committed (or read) `table` at
    `snapshot_id`, of `dataset` (none when empty)."""
    var st = db.prepare(
        String(
            "INSERT INTO ",
            "commits" if commit else "reads",
            " (attempt, table_name, snapshot_id, dataset) VALUES",
            " (?1, ?2, ?3, nullif(?4, ''))",
        )
    )
    st.bind_int(1, attempt)
    st.bind_text(2, table)
    st.bind_int(3, Int(snapshot_id))
    st.bind_text(4, dataset)
    _ = st.step()
