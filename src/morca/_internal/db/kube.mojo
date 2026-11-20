"""The Kubernetes runner's queries (`morca._internal.kube`): which runs' objects to
keep, and the `held` of a run whose pods can't start."""

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


def hold_stuck(
    mut conn: Connection, run: Int, start: String, why: String
) raises -> Optional[Tuple[String, Float64]]:
    """Has `run`, if it's running at start `start` on Kubernetes, say `why`
    as its `held`: a pod of it can't start. Returns its pipeline and how
    many seconds ago it started, or None if it isn't running there."""
    var rows = conn.query(
        (
            "UPDATE orca.runs SET held = $3 WHERE id = $1 AND status ="
            " 'running' AND starts::text = $2 AND placement = 'kubernetes'"
            " RETURNING pipeline, coalesce(extract(epoch FROM now() -"
            " started), 0)::float8 AS age"
        ),
        Params().int64(Int64(run)).text(start).text(why),
    )
    if len(rows) == 0:
        return None
    var r = rows.row(0)
    return (r.text("pipeline"), r.float64("age"))


def held_running(mut conn: Connection) raises -> List[Tuple[String, Bool]]:
    """`<run>-<start>` of every running Kubernetes run with a `held` (its
    pods were stuck), and whether it has a heartbeat."""
    var out = List[Tuple[String, Bool]]()
    for r in conn.query(
        (
            "SELECT id || '-' || starts AS k, heartbeat IS NOT NULL AS beat"
            " FROM orca.runs WHERE status = 'running' AND placement ="
            " 'kubernetes' AND held IS NOT NULL"
        ),
        Params(),
    ):
        out.append((r.text("k"), r.bool("beat")))
    return out^


def clear_held(mut conn: Connection, key: String) raises:
    """Clears the `held` of the running run `<run>-<start>` `key`."""
    _ = conn.execute(
        (
            "UPDATE orca.runs SET held = NULL WHERE status = 'running' AND"
            " id || '-' || starts = $1 AND held IS NOT NULL"
        ),
        Params().text(key),
    )
