"""Learning a request's queries (`morca._internal.recommend`): a pipeline's runs'
peaks, and its out-of-memory raise."""

from postgres import Connection, Params


@fieldwise_init
struct RunPeaks(Copyable, Movable):
    """One run's peaks: its attempts' largest memory, in bytes, and peak
    cores; -1 for what wasn't measured."""

    var peak_rss_bytes: Float64
    var peak_cpus: Float64


def expire_raised(mut conn: Connection, runs: Int) raises -> List[String]:
    """Forgets each pipeline's out-of-memory raise once `runs` of its runs
    after the one that caused it have succeeded; returns their names."""
    var out = List[String]()
    for r in conn.query(
        (
            "UPDATE orca.pipelines p SET memory_raised_mb = NULL,"
            " memory_raised_run = NULL WHERE p.memory_raised_mb IS NOT NULL"
            " AND p.memory_raised_run IS NOT NULL AND (SELECT count(*) FROM"
            " orca.runs r WHERE r.pipeline = p.name AND r.status ="
            " 'succeeded' AND r.id > p.memory_raised_run) >= $1 RETURNING"
            " p.name"
        ),
        Params().int64(Int64(runs)),
    ):
        out.append(r.text("name"))
    return out^


def peaks(
    mut conn: Connection, pipeline: String, runs: Int
) raises -> List[RunPeaks]:
    """The peaks of `pipeline`'s last `runs` succeeded runs that measured
    memory, newest first."""
    var out = List[RunPeaks]()
    for r in conn.query(
        (
            "SELECT max(a.peak_rss_bytes)::float8 AS peak,"
            " coalesce(max(a.peak_cpus), -1)::float8 AS cpus FROM orca.runs r"
            " JOIN orca.steps s ON s.run = r.id JOIN orca.attempts a ON a.step"
            " = s.id WHERE r.pipeline = $1 AND r.status = 'succeeded' GROUP BY"
            " r.id HAVING max(a.peak_rss_bytes) IS NOT NULL ORDER BY r.id DESC"
            " LIMIT $2"
        ),
        Params().text(pipeline).int64(Int64(runs)),
    ):
        out.append(RunPeaks(r.float64("peak"), r.float64("cpus")))
    return out^


def raised_mb(mut conn: Connection, pipeline: String) raises -> Int:
    """`pipeline`'s out-of-memory raise, 0 for none."""
    var raised = conn.query(
        (
            "SELECT coalesce(memory_raised_mb, 0) AS raised FROM"
            " orca.pipelines WHERE name = $1"
        ),
        Params().text(pipeline),
    )
    return Int(raised.row(0).int64("raised")) if len(raised) else 0


def capped(mut conn: Connection, pipeline: String) raises -> String:
    """What `pipeline`'s learned memory was last capped at, empty for
    nothing (`orca.pipelines.learned`'s `capped`)."""
    var rows = conn.query(
        (
            "SELECT coalesce(learned->>'capped', '') AS capped FROM"
            " orca.pipelines WHERE name = $1"
        ),
        Params().text(pipeline),
    )
    return rows.row(0).text("capped") if len(rows) else String()


def keep_capped(mut conn: Connection, pipeline: String, capped: String) raises:
    """Sets `capped` in `pipeline`'s `learned`, or with `capped` empty
    removes it. Additive in the JSON: a binary before #462 ignores it."""
    _ = conn.execute(
        (
            "UPDATE orca.pipelines SET learned = CASE WHEN $2 = '' THEN"
            " learned - 'capped' ELSE coalesce(learned, '{}'::jsonb) ||"
            " jsonb_build_object('capped', $2::text) END WHERE name = $1"
        ),
        Params().text(pipeline).text(capped),
    )
