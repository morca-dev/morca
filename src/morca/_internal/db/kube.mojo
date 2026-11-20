"""The Kubernetes runner's queries (`morca._internal.kube`): which runs' objects to
keep."""

from postgres import Connection, Params


def running_at(mut conn: Connection, run: Int, start: String) raises -> Bool:
    """Whether `run` is running at start `start` (its number, as text)."""
    return (
        len(
            conn.query(
                (
                    "SELECT id FROM orca.runs WHERE id = $1 AND status"
                    " = 'running' AND starts::text = $2"
                ),
                Params().int64(Int64(run)).text(start),
            )
        )
        > 0
    )


def running_keys(mut conn: Connection) raises -> List[String]:
    """`<run>-<start>` of every running run."""
    var out = List[String]()
    for r in conn.query(
        (
            "SELECT id || '-' || starts AS k FROM orca.runs WHERE status ="
            " 'running'"
        ),
        Params(),
    ):
        out.append(r.text("k"))
    return out^


def ended_keys(mut conn: Connection, secs: Float64) raises -> List[String]:
    """`<run>-<start>` of every run that isn't running and ended in the
    last `secs` seconds."""
    var out = List[String]()
    for r in conn.query(
        (
            "SELECT id || '-' || starts AS k FROM orca.runs WHERE status <>"
            " 'running' AND ended > now() - make_interval(secs => $1)"
        ),
        Params().float64(secs),
    ):
        out.append(r.text("k"))
    return out^


def memory_gb(mut conn: Connection, pipeline: String) raises -> String:
    """The pipeline's registered `memory_gb`; empty for none."""
    for r in conn.query(
        (
            "SELECT coalesce(memory_gb, '') AS m FROM orca.pipelines WHERE"
            " name = $1"
        ),
        Params().text(pipeline),
    ):
        return r.text("m")
    return String()


def fail_killed(
    mut conn: Connection, run: Int, start: String, why: String
) raises:
    """Fails `run`, unretried, with `why`, if it's running at start `start`
    (its number, as text)."""
    _ = conn.execute(
        (
            "UPDATE orca.runs SET status = 'failed', ended = now(),"
            " heartbeat = NULL, retry_at = NULL, error = $3,"
            " unretried_start = starts WHERE id = $1 AND status = 'running'"
            " AND starts::text = $2"
        ),
        Params().int64(Int64(run)).text(start).text(why),
    )
