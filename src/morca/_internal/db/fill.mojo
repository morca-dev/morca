"""Fills' queries (`morca._internal.fill`): a pipeline's fill runs, what they've
done and cost, and why more may not start. Read in the transaction the
scheduler holds with the pipeline's row locked."""

from postgres import Params, Transaction


comptime _SAME_DATA = (
    "SELECT r.id FROM orca.runs r LEFT JOIN (SELECT registry_hash,"
    " max(data_version) AS dv FROM orca.pipeline_versions WHERE pipeline = $1"
    " GROUP BY registry_hash) AS h ON h.registry_hash = r.registry_hash WHERE"
    " r.pipeline = $1 AND coalesce(h.dv, '') = coalesce((SELECT"
    " v.data_version FROM orca.pipelines p JOIN orca.pipeline_versions v ON"
    " v.id = p.version WHERE p.name = $1), '')"
)
"""The runs of pipeline `$1` whose code has its current data version
(`morca._internal.state.data_version_sql`): the same steps' `version=`. A run's is its
registry hash's, since a step's version is in the hash; a hash recorded
before data versions, or none, has none."""

comptime _DONE_ANY_CODE = (
    "WITH m AS (SELECT x->>'name' AS step FROM orca.pipelines p,"
    " jsonb_array_elements(p.describe->'steps') AS x WHERE p.name = $1 AND"
    " x->>'kind' = 'mapped'), same AS ("
    + _SAME_DATA
    + ") SELECT st.partition AS key FROM orca.steps st"
    " JOIN orca.runs r ON r.id = st.run WHERE r.pipeline = $1 AND st.status ="
    " 'succeeded' AND st.step IN (SELECT step FROM m) AND r.id IN (SELECT id"
    " FROM same) GROUP BY st.partition HAVING count(DISTINCT st.step) ="
    " (SELECT count(*) FROM m) UNION SELECT k.key FROM orca.runs r,"
    " unnest(string_to_array(r.partitions, ',')) AS k(key) WHERE r.pipeline ="
    " $1 AND r.status = 'succeeded' AND r.id IN (SELECT id FROM same) AND NOT"
    " EXISTS (SELECT 1 FROM m)"
)
"""The keys done for pipeline `$1` in a run of any of its code with its
current data version: every mapped step succeeded for the key; with no
mapped step, a run over it succeeded. (`morca._internal.db.queueing.DONE_SQL`
asks the same of given keys, for coverage, the calendar and backfills.) A raised `version=` is a new data version, so
the fill runs the partitions again (#297)."""


def done_any_code(mut tx: Transaction, pipeline: String) raises -> List[String]:
    """The keys done for `pipeline` in a run of any of its code with its
    current data version (`_DONE_ANY_CODE`)."""
    var out = List[String]()
    for r in tx.query(_DONE_ANY_CODE, Params().text(pipeline)):
        out.append(r.text("key"))
    return out^


@fieldwise_init
struct KeyFill(Copyable, Movable):
    """A key's latest fill run, of the current data version."""

    var key: String
    var gone: Bool
    """It was cancelled, or failed for good."""
    var again: Bool
    """It failed and will be retried."""


def latest_fills(
    mut tx: Transaction, pipeline: String, run_retries: Int
) raises -> List[KeyFill]:
    """Each key's latest fill run of `pipeline` with its current data
    version, with `run_retries` the starts a run may make."""
    var out = List[KeyFill]()
    for r in tx.query(
        (
            "SELECT DISTINCT ON (k.key) k.key, r.status = 'cancelled' OR"
            " (r.status = 'failed' AND (r.starts - r.deferrals > $2 OR"
            " coalesce(r.error, '') LIKE 'not started: its code is %')) AS"
            " gone, r.status = 'failed' AND r.starts - r.deferrals <= $2 AS"
            " again"
            " FROM orca.runs r, unnest(string_to_array(r.partitions, ',')) AS"
            " k(key) WHERE r.pipeline = $1 AND r.trigger = 'fill' AND r.id IN ("
            + _SAME_DATA
            + ") ORDER BY k.key, r.id DESC"
        ),
        Params().text(pipeline).int64(Int64(run_retries)),
    ):
        out.append(KeyFill(r.text("key"), r.bool("gone"), r.bool("again")))
    return out^


def running_fills(
    mut tx: Transaction, pipeline: String, stale: Float64, dead: String
) raises -> List[Int]:
    """The seconds each of `pipeline`'s running fill runs whose process is
    alive (`dead`, with the stale limit `stale` as `$2`) has run."""
    var running = tx.query(
        String(
            "SELECT count(*) AS n, coalesce(sum(extract(epoch FROM now() -",
            " started)), 0)::float8 AS elapsed, coalesce(array_agg(extract(",
            "epoch FROM now() - started)::bigint), '{}')::text AS each FROM",
            " orca.runs WHERE pipeline = $1 AND trigger = 'fill' AND status =",
            " 'running' AND NOT ",
            dead,
        ),
        Params().text(pipeline).float64(stale),
    ).row(0)
    var elapsed = List[Int]()
    var each = running.text("each")
    if each.byte_length() > 2:
        for e in each[byte = 1 : each.byte_length() - 1].split(","):
            elapsed.append(Int(e))
    return elapsed^


def queued_fills(mut tx: Transaction, pipeline: String) raises -> Int:
    """How many of `pipeline`'s fill runs are queued."""
    return Int(
        tx.query(
            (
                "SELECT count(*) AS n FROM orca.runs WHERE pipeline = $1 AND"
                " trigger = 'fill' AND status = 'queued'"
            ),
            Params().text(pipeline),
        )
        .row(0)
        .int64("n")
    )


def recent_fills(
    mut tx: Transaction, pipeline: String, hours: Int
) raises -> Tuple[Int64, Float64]:
    """The partitions of `pipeline`'s fill runs that succeeded in the last
    `hours`, and the seconds since the first of them started."""
    var rate = tx.query(
        String(
            "SELECT coalesce(sum(cardinality(string_to_array(partitions,",
            " ','))), 0) AS n, coalesce(extract(epoch FROM now() -",
            " min(started)), 0)::float8 AS span FROM orca.runs WHERE pipeline",
            " = $1 AND trigger = 'fill' AND status = 'succeeded' AND ended >",
            " now() - make_interval(hours => ",
            hours,
            ")",
        ),
        Params().text(pipeline),
    ).row(0)
    return (rate.int64("n"), rate.float64("span"))


@fieldwise_init
struct InstanceTime(Copyable, Movable):
    var instance_type: String
    var seconds: Float64


def fill_instances(
    mut tx: Transaction, pipeline: String, now: Int64, since: Int64
) raises -> List[InstanceTime]:
    """Each instance of `pipeline`'s fill runs live between `since` and
    `now` (Unix times), with its seconds in that time."""
    var out = List[InstanceTime]()
    for r in tx.query(
        (
            "SELECT i.instance_type, extract(epoch FROM"
            " least(coalesce(i.ended, to_timestamp($2)), to_timestamp($2)) -"
            " greatest(i.launched, to_timestamp($3)))::float8 AS secs FROM"
            " orca.instances i JOIN orca.runs r ON r.id = i.run WHERE"
            " r.pipeline = $1 AND r.trigger = 'fill' AND coalesce(i.ended,"
            " to_timestamp($2)) > to_timestamp($3) AND i.launched <"
            " to_timestamp($2)"
        ),
        Params().text(pipeline).int64(now).int64(since),
    ):
        out.append(InstanceTime(r.text("instance_type"), r.float64("secs")))
    return out^


@fieldwise_init
struct PodTime(Copyable, Movable):
    """A Kubernetes run's pods: what they ask for in all, and its seconds."""

    var cpu_millis: Int
    var memory_mb: Int
    var seconds: Float64


def fill_pods(
    mut tx: Transaction, pipeline: String, now: Int64, since: Int64
) raises -> List[PodTime]:
    """Each of `pipeline`'s fill runs on Kubernetes live between `since`
    and `now` (Unix times), with its latest start's requests and seconds in
    that time (a run running counts to `now`)."""
    var out = List[PodTime]()
    for r in tx.query(
        (
            "WITH k AS (SELECT coalesce(cpu_millis, 0) AS cpu,"
            " coalesce(pod_memory_mb, 0) AS mem, started AS s, CASE WHEN status"
            " = 'running' THEN to_timestamp($2) ELSE least(coalesce(ended,"
            " started), to_timestamp($2)) END AS e FROM orca.runs WHERE"
            " pipeline = $1 AND trigger = 'fill' AND placement = 'kubernetes'"
            " AND started IS NOT NULL) SELECT cpu, mem, extract(epoch FROM e -"
            " greatest(s, to_timestamp($3)))::float8 AS secs FROM k WHERE e >"
            " to_timestamp($3) AND s < to_timestamp($2)"
        ),
        Params().text(pipeline).int64(now).int64(since),
    ):
        out.append(
            PodTime(Int(r.int64("cpu")), Int(r.int64("mem")), r.float64("secs"))
        )
    return out^


def fill_durations(
    mut tx: Transaction, pipeline: String, last: Int
) raises -> List[Int]:
    """The seconds each of `pipeline`'s last `last` ended fill runs took,
    those cancelled left out, newest first."""
    var out = List[Int]()
    for r in tx.query(
        String(
            "SELECT extract(epoch FROM ended - started)::bigint AS secs FROM",
            " orca.runs WHERE pipeline = $1 AND trigger = 'fill' AND ended IS",
            " NOT NULL AND started IS NOT NULL AND status <> 'cancelled' ORDER",
            " BY id DESC LIMIT ",
            last,
        ),
        Params().text(pipeline),
    ):
        out.append(Int(r.int64("secs")))
    return out^


def queued_others(mut tx: Transaction, pipeline: String) raises -> Int:
    """How many of `pipeline`'s runs but fill runs are queued."""
    return Int(
        tx.query(
            (
                "SELECT count(*) AS n FROM orca.runs WHERE pipeline = $1 AND"
                " status = 'queued' AND trigger <> 'fill'"
            ),
            Params().text(pipeline),
        )
        .row(0)
        .int64("n")
    )


def last_pause(
    mut tx: Transaction, pipeline: String
) raises -> Optional[Tuple[String, String]]:
    """Who last paused or unpaused `pipeline`, and the audit row's detail;
    None if no one did."""
    var by = tx.query(
        (
            "SELECT username, detail FROM orca.audit WHERE action IN"
            " ('/pipelines/' || $1 || '/pause', '/pipelines/' || $1 ||"
            " '/unpause') ORDER BY id DESC LIMIT 1"
        ),
        Params().text(pipeline),
    )
    if len(by) != 1:
        return None
    return (by.row(0).text("username"), by.row(0).text("detail"))
