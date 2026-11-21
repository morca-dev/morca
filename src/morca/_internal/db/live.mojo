"""Which runs are live: queued, deferred, or running with their process
alive, as SQL the other queries build on (`live_sql`, `dead_sql`, ...).

A running run's process is taken to have died when its heartbeat is older
than the stale limit (`MORCA_STALE_SECONDS`), or, before its first beat, when
the scheduler started it longer ago than the start grace
(`MORCA_START_SECONDS`); a Kubernetes run whose pods can't start waits
past that, saying why (`stale_sql`). A live run holds its partition keys: the
scheduler, sensors, rebuilds and the UI's start queue no second run over a
key a live run has.

**Held by its scheduler instance.** A local or control-placed run started
by an `morca scheduler` with MORCA_OVERLAP=on records that instance
(`runs.instance`, a row of `orca.schedulers`: docs/overlap.md). It isn't
dead while that instance has been seen within the stale limit and lists
it among its runs, whatever its heartbeat: the instance kills a
process whose heartbeat went stale, reaps it, and only then is the run
dead. So while two instances overlap in a deploy, the one that leads
counts the draining one's runs and leaves them alone.
"""

from std.os import getenv

from postgres import Connection, Params, Transaction


def stale_limit() raises -> Float64:
    """`MORCA_STALE_SECONDS` (default 30): how old a running run's heartbeat
    is when its process is taken to have died."""
    return Float64(getenv("MORCA_STALE_SECONDS", "30"))


def start_grace(stale: Float64) raises -> Float64:
    """`MORCA_START_SECONDS`: how long a run the scheduler started may go
    without a heartbeat. By default the stale limit for local runs, and 300
    s on Kubernetes or EC2, where a pod or an instance can take minutes to
    start."""
    var runner = getenv("MORCA_RUNNER", "local")
    return Float64(
        getenv(
            "MORCA_START_SECONDS",
            "300" if runner == "kubernetes"
            or runner == "ec2" else String(stale),
        )
    )


def stale_seconds() -> Float64:
    """`MORCA_STALE_SECONDS` (default 30): how old a running run's heartbeat
    is when its process is taken to have died."""
    try:
        return Float64(getenv("MORCA_STALE_SECONDS", "30"))
    except:
        return 30.0


def stalled_sql() -> String:
    """True for a run that's `running` with no live process: its heartbeat,
    or its start when it has none yet, is older than the stale limit."""
    return String(
        "(status = 'running' AND coalesce(heartbeat, started, created) <",
        " now() - make_interval(secs => ",
        stale_seconds(),
        "))",
    )


def held_sql(stale: String, t: String = "orca.runs") -> String:
    """SQL true for a run of table reference `t` (`orca.runs`, or its alias
    in the query) that a live scheduler instance holds: a local or
    control-placed run whose `instance` has been seen within `stale`
    seconds, hasn't ended, and lists the run among its running."""
    return String(
        "(",
        t,
        ".instance IS NOT NULL AND ",
        t,
        ".placement IN ('local', 'control') AND EXISTS (SELECT 1 FROM",
        " orca.schedulers hs WHERE hs.id = ",
        t,
        ".instance AND hs.ended IS NULL AND hs.last_seen > now() -",
        " make_interval(secs => ",
        stale,
        ") AND ",
        t,
        ".id::text = ANY (string_to_array(coalesce(hs.running, ''), ','))))",
    )


def stale_sql(stale: String, grace: Float64, t: String = "orca.runs") -> String:
    """SQL true for a running run whose process looks stopped: its
    heartbeat is older than `stale` (seconds, or a parameter such as `$2`),
    or it has none and was started longer ago than `grace` seconds, unless
    it's a Kubernetes run whose pods can't start (its `held` says why,
    `morca._internal.kube`) and it isn't asked to cancel: it waits for them
    rather than starting again on pods that would wait the same way. `t` is
    how the query names `orca.runs`: the table itself, or its alias."""
    return String(
        "((",
        t,
        ".heartbeat IS NOT NULL AND ",
        t,
        ".heartbeat <= now() - make_interval(secs => ",
        stale,
        ")) OR (",
        t,
        ".heartbeat IS NULL AND (",
        t,
        ".started IS NULL OR ",
        t,
        ".started <= now() - make_interval(secs => ",
        grace,
        ")) AND NOT (coalesce(",
        t,
        ".placement, '') = 'kubernetes' AND ",
        t,
        ".held IS NOT NULL AND NOT coalesce(",
        t,
        ".cancel_requested, false))))",
    )


def dead_sql(stale: String, grace: Float64, t: String = "orca.runs") -> String:
    """SQL true for a running run whose process died: it looks stopped
    (`stale_sql`) and no live scheduler instance holds it (`held_sql`)."""
    return String(
        "(", stale_sql(stale, grace, t), " AND NOT ", held_sql(stale, t), ")"
    )


def live_sql() raises -> String:
    """SQL for the keys of pipeline `$1` in a live run, each with the first
    such run (`key`, `id`): one that's queued, deferred (a step said "not
    yet", and the scheduler starts it again at its `retry_at`), or running
    with its process alive. A run whose process died doesn't hold its keys, whatever its
    trigger, so a backfill or a sensor may queue them again."""
    return String(
        "SELECT DISTINCT ON (k.key) k.key, r.id FROM orca.runs r,",
        " unnest(string_to_array(r.partitions, ',')) AS k(key) WHERE",
        " r.pipeline = $1 AND ",
        is_live_sql("r"),
        " ORDER BY k.key, r.id",
    )


def is_live_sql(t: String) raises -> String:
    """SQL true for a live run of table reference `t`: queued, deferred,
    or running with its process alive (`live_sql`)."""
    var stale = stale_limit()
    return String(
        "(",
        t,
        ".status IN ('queued', 'deferred') OR (",
        t,
        ".status = 'running' AND NOT ",
        dead_sql(String(stale), start_grace(stale), t),
        "))",
    )


def behind_sql(t: String = "orca.runs") raises -> String:
    """SQL true for a run of table reference `t` that has a key an older
    live run of its pipeline has (`is_live_sql`): it waits for that run,
    so two runs of a key don't run at once. A sensor queues one so when a
    live run read an older snapshot than the one it sensed (#139). A run
    whose process died holds nothing back, as it holds no keys."""
    return String(
        "EXISTS (SELECT 1 FROM orca.runs b WHERE b.pipeline = ",
        t,
        ".pipeline AND b.id < ",
        t,
        ".id AND ",
        is_live_sql("b"),
        " AND string_to_array(b.partitions, ',') && string_to_array(",
        t,
        ".partitions, ','))",
    )


comptime WAITING_BEHIND = "waiting: for run "
"""How a queued run's `held` starts while it waits behind an older live run
of its keys (`behind_sql`)."""


def hold_behind(
    mut tx: Transaction, pipeline: String, after: String = ""
) raises:
    """Says on `pipeline`'s queued runs that wait behind an older live run
    (`behind_sql`) which run, and a key of it: "waiting: for run 12, which
    has 2024-03". Those that said so and no longer wait say `after`
    instead, or nothing."""
    _ = tx.execute(
        String(
            "UPDATE orca.runs q SET held = w.why FROM (SELECT DISTINCT ON",
            " (r.id) r.id, $2 || b.id || ', which has ' || k.key AS why",
            " FROM orca.runs r CROSS JOIN LATERAL",
            " unnest(string_to_array(r.partitions, ',')) AS k(key) JOIN",
            " orca.runs b ON b.pipeline = r.pipeline AND b.id < r.id AND",
            " k.key = ANY (string_to_array(b.partitions, ',')) AND ",
            is_live_sql("b"),
            " WHERE r.pipeline = $1 AND r.status = 'queued' ORDER BY r.id,",
            " b.id, k.key) AS w WHERE q.id = w.id AND q.held IS DISTINCT",
            " FROM w.why",
        ),
        Params().text(pipeline).text(WAITING_BEHIND),
    )
    _ = tx.execute(
        String(
            "UPDATE orca.runs SET held = nullif($3, '') WHERE pipeline = $1",
            " AND status = 'queued' AND starts_with(held, $2) AND NOT ",
            behind_sql(),
        ),
        Params().text(pipeline).text(WAITING_BEHIND).text(after),
    )


def live_runs(
    mut tx: Transaction, pipeline: String
) raises -> Dict[String, Int]:
    """The keys of `pipeline` in a live run, each with the first such run.
    Callers that then queue a run hold the pipeline's row `FOR UPDATE`, as
    `morca._internal.scheduler` does, so two can't both see a key free."""
    var out = Dict[String, Int]()
    for r in tx.query(live_sql(), Params().text(pipeline)):
        out[r.text("key")] = Int(r.int64("id"))
    return out^


def live_runs(
    mut conn: Connection, pipeline: String
) raises -> Dict[String, Int]:
    """`live_runs`, outside a transaction: for a page, which locks nothing."""
    var out = Dict[String, Int]()
    for r in conn.query(live_sql(), Params().text(pipeline)):
        out[r.text("key")] = Int(r.int64("id"))
    return out^


def ordered_runs(cond: String, tables: String = "orca.runs r") -> String:
    """SQL true for the runs `cond` names, locked first in `id` order
    (`FOR NO KEY UPDATE`), for a statement that updates several runs.
    Two statements that each update several runs, locking them in the
    order their scans meet the rows, deadlock when the orders cross
    (#440); in `id` order they wait for each other instead. `cond`
    reads `tables`, in which `r` is `orca.runs`."""
    return String(
        "id IN (SELECT r.id FROM ",
        tables,
        " WHERE ",
        cond,
        " ORDER BY r.id FOR NO KEY UPDATE OF r)",
    )
