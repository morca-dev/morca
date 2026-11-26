"""Usage's queries (`morca._internal.usage`): which attempts a process made, and
what each used."""

from postgres import Connection, Params


@fieldwise_init
struct AttemptSpan(ImplicitlyCopyable, Movable):
    """An attempt the process made, in seconds before now."""

    var id: Int
    var started: Float64
    var ended: Float64
    """-1 if it hadn't ended when the process did."""


def unmeasured(
    mut conn: Connection,
    run: Int,
    pid: Int,
    since: Float64,
    worker: Int,
    start: Int,
) raises -> List[AttemptSpan]:
    """`run`'s attempts by process `pid`, started in the last `since`
    seconds, with no usage recorded yet, oldest first; with `worker` (0 for
    none), only while the run's start `start` is that worker's."""
    var only_worker = String()
    if worker > 0:
        only_worker = (
            " AND EXISTS (SELECT 1 FROM orca.runs r WHERE r.id = $1 AND"
            " r.worker = $4 AND r.starts = $5)"
        )
    var params = Params().int64(Int64(run)).text(String(pid)).float64(since)
    if worker > 0:
        params = params^.int64(Int64(worker)).int64(Int64(start))
    var rows = conn.query(
        String(
            "SELECT a.id, extract(epoch FROM now() - a.started)::float8 AS s,",
            " coalesce(extract(epoch FROM now() - a.ended)::float8, -1) AS e",
            " FROM orca.attempts a JOIN orca.steps st ON st.id = a.step WHERE",
            " st.run = $1 AND a.host LIKE '%:' || $2 AND a.cpu_seconds IS",
            " NULL AND a.peak_rss_bytes IS NULL AND a.started > now() -",
            " make_interval(secs => $3)",
            only_worker,
            " ORDER BY a.started, a.id",
        ),
        params,
    )
    var spans = List[AttemptSpan]()
    for r in rows:
        spans.append(
            AttemptSpan(Int(r.int64("id")), r.float64("s"), r.float64("e"))
        )
    return spans^


def set_usage(
    mut conn: Connection,
    attempt: Int,
    peak_rss_bytes: Int,
    cpu_seconds: Float64,
    peak_cpus: Float64,
) raises -> Int:
    """Records what `attempt` used (-1 for unmeasured); returns how many
    attempts."""
    return conn.execute(
        (
            "UPDATE orca.attempts SET peak_rss_bytes = NULLIF($2, -1),"
            " cpu_seconds = NULLIF($3, -1), peak_cpus = NULLIF($4, -1)"
            " WHERE id = $1"
        ),
        Params()
        .int64(Int64(attempt))
        .int64(Int64(peak_rss_bytes))
        .float64(cpu_seconds)
        .float64(peak_cpus),
    )
