"""A run's dista cluster over several workers of a pool
(`morca._internal.run_cluster`): its head on `orca.runs`, its members in
`orca.run_members`."""

from postgres import Connection, Params

comptime MEMBER_GRANTS_SQL = (
    " + coalesce((SELECT sum(m.grant_cpus) FROM orca.run_members m WHERE"
    " m.worker = $1 AND m.ended IS NULL), 0)"
)
"""Added to a worker's runs' granted CPUs: its live members'."""
comptime MEMBER_MB_SQL = (
    " + coalesce((SELECT sum(m.grant_memory_mb) FROM orca.run_members m"
    " WHERE m.worker = $1 AND m.ended IS NULL), 0)"
)
comptime MEMBER_GPUS_SQL = (
    " + coalesce((SELECT sum(m.grant_gpus) FROM orca.run_members m"
    " WHERE m.worker = $1 AND m.ended IS NULL), 0)"
)


def spread(mut conn: Connection, pipeline: String) raises -> Int:
    """`pipeline`'s `workers` (`ec2_workers`), 0 when unset or there's no
    such pipeline."""
    var rows = conn.query(
        (
            "SELECT coalesce(ec2_workers, 0) AS n FROM orca.pipelines WHERE"
            " name = $1"
        ),
        Params().text(pipeline),
    )
    if len(rows) == 0:
        return 0
    return Int(rows.row(0).int64("n"))


def set_head(
    mut conn: Connection,
    run: Int,
    start: Int,
    worker: Int,
    head: String,
    token: String,
) raises -> Int:
    """Keeps `run`'s head and cluster token, if it's running at `start` on
    `worker`; returns how many runs (0 or 1)."""
    return conn.execute(
        (
            "UPDATE orca.runs SET cluster_head = $4, cluster_token = $5 WHERE"
            " id = $1 AND starts = $2 AND worker = $3 AND status = 'running'"
        ),
        Params()
        .int64(Int64(run))
        .int64(Int64(start))
        .int64(Int64(worker))
        .text(head)
        .text(token),
    )


def end_member(
    mut conn: Connection, member: Int, worker: Int, why: String
) raises:
    """Ends `worker`'s live member `member`, saying `why` unless it says
    something already."""
    _ = conn.execute(
        (
            "UPDATE orca.run_members SET ended = now(), why = coalesce(why,"
            " $3) WHERE id = $1 AND worker = $2 AND ended IS NULL"
        ),
        Params().int64(Int64(member)).int64(Int64(worker)).text(why),
    )


def end_stale_members(mut conn: Connection, worker: Int) raises -> List[Int]:
    """Ends `worker`'s live members whose run isn't running at their start
    any more, "its run ended"; returns their ids."""
    var out = List[Int]()
    for r in conn.query(
        (
            "UPDATE orca.run_members m SET ended = now(), why = 'its run ended'"
            " FROM orca.runs r WHERE m.run = r.id AND m.worker = $1 AND"
            " m.ended IS NULL AND (r.status <> 'running' OR r.starts <>"
            " m.start) RETURNING m.id"
        ),
        Params().int64(Int64(worker)),
    ):
        out.append(Int(r.int64("id")))
    return out^


@fieldwise_init
struct Joinable(Copyable, Movable):
    """A running run whose cluster a worker could join."""

    var run: Int
    var start: Int
    var pipeline: String
    var head: String
    var token: String


def joinable(
    mut conn: Connection, placement: String, worker: Int
) raises -> List[Joinable]:
    """The running runs placed `placement`, oldest first, with their head
    known on another worker than `worker`, fewer live members than their
    pipeline's `workers` and none of them `worker`."""
    var out = List[Joinable]()
    for c in conn.query(
        (
            "SELECT r.id, r.starts, r.pipeline, r.cluster_head,"
            " r.cluster_token FROM orca.runs r JOIN orca.pipelines p ON p.name"
            " = r.pipeline WHERE r.status = 'running' AND p.placement = $1 AND"
            " r.cluster_head IS NOT NULL AND r.worker <> $2 AND"
            " coalesce(p.ec2_workers, 0) > (SELECT count(*) FROM"
            " orca.run_members m WHERE m.run = r.id AND m.start = r.starts AND"
            " m.ended IS NULL) AND NOT EXISTS (SELECT 1 FROM orca.run_members m"
            " WHERE m.run = r.id AND m.start = r.starts AND m.worker = $2 AND"
            " m.ended IS NULL) ORDER BY r.id"
        ),
        Params().text(placement).int64(Int64(worker)),
    ):
        out.append(
            Joinable(
                Int(c.int64("id")),
                Int(c.int64("starts")),
                c.text("pipeline"),
                c.text("cluster_head"),
                c.text("cluster_token"),
            )
        )
    return out^


def add_member(
    mut conn: Connection,
    run: Int,
    start: Int,
    worker: Int,
    grant_cpus: Int,
    grant_memory_mb: Int,
    grant_gpus: Int = 0,
) raises -> Optional[Int]:
    """Records `worker` as a live member of `run` at `start`, granted that
    (0 for none), unless it is one already; returns the member's id, or
    None."""
    var got = conn.query(
        (
            "INSERT INTO orca.run_members (run, start, worker, grant_cpus,"
            " grant_memory_mb, grant_gpus) SELECT $1, $2, $3, nullif($4, 0),"
            " nullif($5, 0), nullif($6, 0) WHERE NOT EXISTS (SELECT 1 FROM"
            " orca.run_members WHERE run = $1 AND start = $2 AND worker = $3"
            " AND ended IS NULL)"
            " RETURNING id"
        ),
        Params()
        .int64(Int64(run))
        .int64(Int64(start))
        .int64(Int64(worker))
        .int64(Int64(grant_cpus))
        .int64(Int64(grant_memory_mb))
        .int64(Int64(grant_gpus)),
    )
    if len(got) != 1:
        return None
    return Int(got.row(0).int64("id"))
