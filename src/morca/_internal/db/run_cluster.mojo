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
comptime GROUP_MIN_SQL = (
    "(CASE WHEN g->>'workers' LIKE '%..%' THEN split_part(g->>'workers',"
    " '..', 1) ELSE g->>'workers' END)::bigint"
)
"""And its MIN: equal to its MAX for a count."""


def plain_min_sql(p: String) -> String:
    """The MIN of the workers with no group of pipeline row `p`: its
    `ec2_min_workers`, or its `ec2_workers` for a fixed count (-1 or
    null), 0 when neither is set."""
    return String(
        "(CASE WHEN coalesce(",
        p,
        ".ec2_min_workers, -1) < 0 THEN coalesce(",
        p,
        ".ec2_workers, 0) ELSE least(",
        p,
        ".ec2_min_workers, coalesce(",
        p,
        ".ec2_workers, 0)) END)::bigint",
    )


def wanted_sql(r: String, group: String, lo: String, hi: String) -> String:
    """What kind `group` (an SQL text, '' for the workers with no group)
    of run row `r` wants at its start: its count decided from demand
    (`orca.run_wants`), else its MIN, `lo`, within `lo`..`hi`
    (`morca._internal.member_wants.kind_wanted`)."""
    return String(
        "least(greatest(coalesce((SELECT rw.wanted FROM orca.run_wants rw",
        " WHERE rw.run = ",
        r,
        ".id AND rw.start = ",
        r,
        ".starts AND rw.worker_group = ",
        group,
        "), ",
        lo,
        "), ",
        lo,
        "), greatest(",
        hi,
        ", ",
        lo,
        "))",
    )


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
    """Its pipeline's `workers` (`ec2_workers`), the most members with no
    group it wants; 0 for unset."""
    var live: String
    """Its live members by group, as a JSON object of counts, `""` for
    those with no group: `{"": 1, "gpu": 1}`."""
    var min_workers: Int
    """The fewest members with no group it wants (`plain_min_sql`)."""
    var decided: String
    """What each kind was decided to want from demand at this start
    (`orca.run_wants`), as `live` is: `{"gpu": 1}`."""


def joinable(
    mut conn: Connection, placement: String, worker: Int
) raises -> List[Joinable]:
    """The running runs placed `placement`, oldest first, with their head
    known on another worker than `worker`, none of whose live members is
    `worker`, and either fewer live members with no group than their
    pipeline's `workers` (its MAX) or groups (docs/groups.md); the caller
    counts each kind's live members against what it wants now
    (`morca._internal.member_wants.kinds_of`)."""
    var out = List[Joinable]()
    for c in conn.query(
        (
            "SELECT r.id, r.starts, r.pipeline, r.cluster_head,"
            " r.cluster_token, coalesce(p.ec2_workers, 0)::bigint AS workers,"
            " (SELECT coalesce(json_object_agg(x.g, x.n), '{}')::text FROM"
            " (SELECT coalesce(m.worker_group, '') AS g, count(*) AS n FROM"
            " orca.run_members m WHERE m.run = r.id AND m.start = r.starts AND"
            " m.ended IS NULL GROUP BY 1) x) AS live, "
            + plain_min_sql("p")
            + " AS lo, (SELECT coalesce(json_object_agg(rw.worker_group,"
            " rw.wanted), '{}')::text FROM orca.run_wants rw WHERE rw.run ="
            " r.id AND rw.start = r.starts) AS decided FROM orca.runs r JOIN"
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
                Int(c.int64("lo")),
                c.text("decided"),
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


# ── demand per group (`morca._internal.run_demand`) ──────────────────────


@fieldwise_init
struct KeptDemand(Copyable, Movable):
    """A run whose head's status was kept: what deciding for it needs."""

    var lo: Int
    """The fewest members with no group (`plain_min_sql`)."""
    var hi: Int
    """The most (`ec2_workers`), 0 for unset."""
    var groups: String
    """Its pipeline's groups (`orca.pipelines.groups`), empty for none."""
    var now: Float64
    """The database's clock, in seconds since the epoch."""


def keep_demand(
    mut conn: Connection, run: Int, start: Int, worker: Int, status: String
) raises -> Optional[KeptDemand]:
    """Keeps `status`, its head's `dista status --json`, on `run`, with
    when, if `run` is running at `start` on `worker` with its head known;
    None, keeping nothing, otherwise."""
    var got = conn.query(
        String(
            "UPDATE orca.runs r SET demand = $4::jsonb, demand_at = now() FROM",
            " orca.pipelines p WHERE p.name = r.pipeline AND r.id = $1 AND",
            " r.starts = $2 AND r.worker = $3 AND r.status = 'running' AND",
            " r.cluster_head IS NOT NULL RETURNING ",
            plain_min_sql("p"),
            " AS lo, coalesce(p.ec2_workers, 0)::bigint AS hi,",
            " coalesce(p.groups::text, '') AS groups, extract(epoch FROM",
            " now())::float8 AS now",
        ),
        Params()
        .int64(Int64(run))
        .int64(Int64(start))
        .int64(Int64(worker))
        .text(status),
    )
    if len(got) != 1:
        return None
    var r = got.row(0)
    return KeptDemand(
        Int(r.int64("lo")),
        Int(r.int64("hi")),
        r.text("groups"),
        r.float64("now"),
    )


@fieldwise_init
struct WantRow(Copyable, Movable):
    """A kind's last decision at a run's start (`orca.run_wants`)."""

    var group: String
    """"" for the workers with no group."""
    var wanted: Int
    var short_since: Float64
    var at: Float64
    """When it was decided, in seconds since the epoch."""


def wants_of(
    mut conn: Connection, run: Int, start: Int
) raises -> List[WantRow]:
    """The kinds decided for `run` at `start`."""
    var out = List[WantRow]()
    for r in conn.query(
        (
            "SELECT worker_group, wanted::bigint AS wanted, short_since,"
            " extract(epoch FROM decided_at)::float8 AS at FROM"
            " orca.run_wants WHERE run = $1 AND start = $2"
        ),
        Params().int64(Int64(run)).int64(Int64(start)),
    ):
        out.append(
            WantRow(
                r.text("worker_group"),
                Int(r.int64("wanted")),
                r.float64("short_since"),
                r.float64("at"),
            )
        )
    return out^


def set_want(
    mut conn: Connection,
    run: Int,
    start: Int,
    group: String,
    wanted: Int,
    short_since: Float64,
) raises:
    """Keeps what kind `group` of `run` at `start` wants now, and since when
    it's been short (0 for not)."""
    _ = conn.execute(
        (
            "INSERT INTO orca.run_wants (run, start, worker_group, wanted,"
            " short_since, decided_at) VALUES ($1, $2, $3, $4, $5, now()) ON"
            " CONFLICT (run, start, worker_group) DO UPDATE SET wanted ="
            " EXCLUDED.wanted, short_since = EXCLUDED.short_since,"
            " decided_at = EXCLUDED.decided_at"
        ),
        Params()
        .int64(Int64(run))
        .int64(Int64(start))
        .text(group)
        .int64(Int64(wanted))
        .float64(short_since),
    )


@fieldwise_init
struct KindsRow(Copyable, Movable):
    """What a run's Cluster card says of its kinds, at its current start."""

    var lo: Int
    var hi: Int
    var groups: String
    var live: String
    """Live members by group, as `Joinable.live`."""
    var decided: String
    """Decided counts by group, as `Joinable.decided`."""
    var demand_at: String
    """When its head's status last came, UTC (`2026-11-27T10:00:00Z`);
    empty for never."""


def kinds_row(mut conn: Connection, run: Int) raises -> Optional[KindsRow]:
    """`run`'s kinds of members at its current start, if it has a head."""
    var got = conn.query(
        String(
            "SELECT ",
            plain_min_sql("p"),
            " AS lo, coalesce(p.ec2_workers, 0)::bigint AS hi,",
            " coalesce(p.groups::text, '') AS groups, (SELECT",
            " coalesce(json_object_agg(x.g, x.n), '{}')::text FROM (SELECT",
            " coalesce(m.worker_group, '') AS g, count(*) AS n FROM",
            " orca.run_members m WHERE m.run = r.id AND m.start = r.starts",
            " AND m.ended IS NULL GROUP BY 1) x) AS live, (SELECT",
            " coalesce(json_object_agg(rw.worker_group, rw.wanted),",
            " '{}')::text FROM orca.run_wants rw WHERE rw.run = r.id AND",
            " rw.start = r.starts) AS decided, coalesce(to_char(r.demand_at",
            " AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), '') AS",
            " demand_at FROM orca.runs r JOIN orca.pipelines p ON p.name =",
            " r.pipeline WHERE r.id = $1 AND r.cluster_head IS NOT NULL",
        ),
        Params().int64(Int64(run)),
    )
    if len(got) != 1:
        return None
    var r = got.row(0)
    return KindsRow(
        Int(r.int64("lo")),
        Int(r.int64("hi")),
        r.text("groups"),
        r.text("live"),
        r.text("decided"),
        r.text("demand_at"),
    )
