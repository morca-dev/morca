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


comptime GROUP_MAX_SQL = (
    "(CASE WHEN g->>'workers' LIKE '%..%' THEN split_part(g->>'workers',"
    " '..', 2) ELSE g->>'workers' END)::bigint"
)
"""A group's MAX workers, of `g`, an element of `orca.pipelines.groups`
(`morca._internal.groups.groups_json`: `N` or `MIN..MAX`)."""


def spread(mut conn: Connection, pipeline: String) raises -> Int:
    """`pipeline`'s `workers` (`ec2_workers`) and each of its groups' MAX
    (docs/groups.md), 0 when none is set or there's no such pipeline."""
    var rows = conn.query(
        String(
            "SELECT (coalesce(ec2_workers, 0) + coalesce((SELECT sum(",
            GROUP_MAX_SQL,
            ") FROM jsonb_array_elements(groups) g), 0))::bigint AS n FROM",
            " orca.pipelines WHERE name = $1",
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
    var workers: Int
    """Its pipeline's `workers` (`ec2_workers`), the members with no group
    it wants; 0 for unset."""
    var live: String
    """Its live members by group, as a JSON object of counts, `""` for
    those with no group: `{"": 1, "gpu": 1}`."""


def joinable(
    mut conn: Connection, placement: String, worker: Int
) raises -> List[Joinable]:
    """The running runs placed `placement`, oldest first, with their head
    known on another worker than `worker`, none of whose live members is
    `worker`, and either fewer live members with no group than their
    pipeline's `workers` or groups (docs/groups.md), which the caller
    counts."""
    var out = List[Joinable]()
    for c in conn.query(
        (
            "SELECT r.id, r.starts, r.pipeline, r.cluster_head,"
            " r.cluster_token, coalesce(p.ec2_workers, 0)::bigint AS workers,"
            " (SELECT coalesce(json_object_agg(x.g, x.n), '{}')::text FROM"
            " (SELECT coalesce(m.worker_group, '') AS g, count(*) AS n FROM"
            " orca.run_members m WHERE m.run = r.id AND m.start = r.starts AND"
            " m.ended IS NULL GROUP BY 1) x) AS live FROM orca.runs r JOIN"
            " orca.pipelines p ON p.name = r.pipeline WHERE r.status ="
            " 'running' AND p.placement = $1 AND r.cluster_head IS NOT NULL AND"
            " r.worker <> $2 AND (coalesce(p.ec2_workers, 0) > (SELECT"
            " count(*) FROM orca.run_members m WHERE m.run = r.id AND m.start"
            " = r.starts AND m.ended IS NULL AND m.worker_group IS NULL) OR"
            " jsonb_array_length(coalesce(p.groups, '[]')) > 0) AND NOT EXISTS"
            " (SELECT 1 FROM orca.run_members m WHERE m.run = r.id AND m.start"
            " = r.starts AND m.worker = $2 AND m.ended IS NULL) ORDER BY r.id"
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
                Int(c.int64("workers")),
                c.text("live"),
            )
        )
    return out^


comptime JOIN_SEEN_SECONDS = 30.0
"""How recently another worker must have claimed for `other_has_room` to
count it: one that has said nothing for longer won't join soon."""


def other_has_room(
    mut conn: Connection,
    placement: String,
    worker: Int,
    run: Int,
    start: Int,
    cpus: Int,
    memory_mb: Int,
    grouped: Bool,
) raises -> Bool:
    """Whether a worker of the pool placed `placement` other than `worker`,
    on a host without GPUs, could join `run` at `start` now: seen in the
    last `JOIN_SEEN_SECONDS`, with an address, a free slot and room for
    `cpus` and `memory_mb` (0 for none) less what its runs and members
    were granted (none said: room), not draining, neither the run's head
    nor one of its members; and for a member of a group (`grouped`), one
    that understands groups (docs/groups.md)."""
    var rows = conn.query(
        (
            "SELECT EXISTS (SELECT 1 FROM orca.workers w WHERE 'worker:' ||"
            " w.pool = $1 AND w.id <> $2 AND w.revoked IS NULL AND w.expires >"
            " now() AND w.draining IS NULL AND w.last_seen > now() -"
            " make_interval(secs => $8) AND coalesce(w.gpus, 0) = 0 AND"
            " w.advertise IS NOT NULL AND coalesce(w.slots, 0) > 0 AND (NOT $7"
            " OR coalesce(w.member_groups, false)) AND NOT EXISTS (SELECT 1"
            " FROM orca.pool_machines pm WHERE pm.worker = w.id AND pm.ended IS"
            " NULL AND pm.draining IS NOT NULL) AND NOT EXISTS (SELECT 1 FROM"
            " orca.runs r WHERE r.id = $3 AND r.worker = w.id) AND NOT EXISTS"
            " (SELECT 1 FROM orca.run_members m WHERE m.run = $3 AND m.start ="
            " $4 AND m.worker = w.id AND m.ended IS NULL) AND ($5 = 0 OR"
            " w.room_cpus IS NULL OR w.room_cpus - (SELECT"
            " coalesce(sum(r.grant_cpus), 0) FROM orca.runs r WHERE r.worker ="
            " w.id AND r.status = 'running') - (SELECT"
            " coalesce(sum(m.grant_cpus), 0) FROM orca.run_members m WHERE"
            " m.worker = w.id AND m.ended IS NULL) >= $5) AND ($6 = 0 OR"
            " w.room_memory_mb IS NULL OR w.room_memory_mb - (SELECT"
            " coalesce(sum(r.grant_memory_mb), 0) FROM orca.runs r WHERE"
            " r.worker = w.id AND r.status = 'running') - (SELECT"
            " coalesce(sum(m.grant_memory_mb), 0) FROM orca.run_members m"
            " WHERE m.worker = w.id AND m.ended IS NULL) >= $6)) AS yes"
        ),
        Params()
        .text(placement)
        .int64(Int64(worker))
        .int64(Int64(run))
        .int64(Int64(start))
        .int64(Int64(cpus))
        .int64(Int64(memory_mb))
        .bool(grouped)
        .float64(JOIN_SEEN_SECONDS),
    )
    return rows.row(0).bool("yes")


def add_member(
    mut conn: Connection,
    run: Int,
    start: Int,
    worker: Int,
    grant_cpus: Int,
    grant_memory_mb: Int,
    grant_gpus: Int = 0,
    group: String = "",
) raises -> Optional[Int]:
    """Records `worker` as a live member of `run` at `start`, of `group`
    (empty for none), granted that (0 for none), unless it is one already;
    returns the member's id, or None."""
    var got = conn.query(
        (
            "INSERT INTO orca.run_members (run, start, worker, grant_cpus,"
            " grant_memory_mb, grant_gpus, worker_group) SELECT $1, $2, $3,"
            " nullif($4, 0), nullif($5, 0), nullif($6, 0), nullif($7, '')"
            " WHERE NOT EXISTS (SELECT 1 FROM orca.run_members WHERE run = $1"
            " AND start = $2 AND worker = $3 AND ended IS NULL) RETURNING id"
        ),
        Params()
        .int64(Int64(run))
        .int64(Int64(start))
        .int64(Int64(worker))
        .int64(Int64(grant_cpus))
        .int64(Int64(grant_memory_mb))
        .int64(Int64(grant_gpus))
        .text(group),
    )
    if len(got) != 1:
        return None
    return Int(got.row(0).int64("id"))
