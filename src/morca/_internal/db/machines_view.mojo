"""Ops' machines' queries (`morca._internal.views.pools`, `morca._internal.ui.pool_status`,
`morca._internal.ui.contained`): the EC2 instances, a Kubernetes run's pods and the
workers' tokens Pools lists, the runs a worker claimed, the pools morca
scales (`orca.pools`), and the runs on the control host.
"""

from postgres import Connection, Params

from morca._internal.db.live import dead_sql, stale_limit, start_grace


comptime _TS = '\'YYYY-MM-DD"T"HH24:MI:SS"Z"\''


@fieldwise_init
struct SparkSample(Copyable, Movable):
    """A host's sample in the spark window."""

    var host: String
    var ago: Float64
    var cpu: Float64


def spark_samples(
    mut conn: Connection, seconds: Int
) raises -> List[SparkSample]:
    """Every host's samples of the last `seconds`, by host, oldest first."""
    var out = List[SparkSample]()
    for r in conn.query(
        (
            "SELECT host, extract(epoch FROM now() - t)::float8 AS ago, cpu"
            " FROM orca.fleet_samples WHERE t > now() - make_interval(secs =>"
            " $1::int) ORDER BY host, t"
        ),
        Params().int32(Int32(seconds)),
    ):
        out.append(
            SparkSample(r.text("host"), r.float64("ago"), r.float64("cpu"))
        )
    return out^


@fieldwise_init
struct Ec2Instance(Copyable, Movable):
    """An instance as Pools lists it, with its newest sample if it has one
    (`sampled`)."""

    var id: String
    var role: String
    var instance_type: String
    var market: String
    var run: Int
    var start: Int
    var up: Int
    var gone: Bool
    var draining: Bool
    var idle: Bool
    var ended: String
    var why: String
    var image: String
    var sampled: Bool
    var cores: Int
    var cpu: Float64
    var mem: Float64
    var ago: Int


def ec2_instances(
    mut conn: Connection, gone_minutes: Int, one: String
) raises -> List[Ec2Instance]:
    """The instances, or the one with id `one`: live, then those that
    ended in the last `gone_minutes`."""
    var sql = String(
        "SELECT i.id, i.role, i.instance_type, i.market, i.run, i.start,",
        " extract(epoch FROM now() - i.launched)::bigint AS up, i.ended IS",
        " NOT NULL AS gone, i.drained IS NOT NULL AS draining, i.idle IS NOT",
        " NULL AS idle, coalesce(to_char(i.ended AT TIME ZONE 'UTC', ",
        _TS,
        "), '') AS ended, coalesce(i.why, '') AS why, coalesce(p.image, '')",
        " AS image, s.cores, s.cpu, s.mem, s.ago FROM orca.instances i JOIN",
        " orca.runs r ON r.id = i.run LEFT JOIN orca.pipelines p ON p.name =",
        " r.pipeline LEFT JOIN LATERAL (SELECT cores, cpu, mem,",
        " extract(epoch FROM now() - t)::bigint AS ago FROM",
        " orca.fleet_samples WHERE host = i.id ORDER BY t DESC LIMIT 1) s ON",
        " true WHERE (i.ended IS NULL OR i.ended > now() - make_interval(mins",
        " => $1::int))",
        " AND i.id = $2" if one else " AND $2 = ''",
        " ORDER BY i.ended IS NOT NULL, i.launched, i.id",
    )
    var out = List[Ec2Instance]()
    for r in conn.query(sql, Params().int32(Int32(gone_minutes)).text(one)):
        var sampled = not r.is_null("cpu")
        out.append(
            Ec2Instance(
                r.text("id"),
                r.text("role"),
                r.text("instance_type"),
                r.text("market"),
                Int(r.int64("run")),
                Int(r.int64("start")),
                Int(r.int64("up")),
                r.bool("gone"),
                r.bool("draining"),
                r.bool("idle"),
                r.text("ended"),
                r.text("why"),
                r.text("image"),
                sampled,
                Int(r.int64("cores")) if sampled else 0,
                r.float64("cpu") if sampled else -1.0,
                r.float64("mem") if sampled else -1.0,
                Int(r.int64("ago")) if sampled else -1,
            )
        )
    return out^


@fieldwise_init
struct PodRun(Copyable, Movable):
    """A live run of the default placement, on the Kubernetes runner."""

    var id: Int
    var starts: Int
    var cpu_millis: Int
    var image: String
    var ago: Int
    """Seconds since its heartbeat; -1 before its first."""
    var up: Int


def pod_runs(mut conn: Connection, one: String) raises -> List[PodRun]:
    """The live runs of the default placement, or the one whose pods are
    named `one` (`morca-<run>-<start>`), by id."""
    var stale = stale_limit()
    var sql = String(
        "SELECT r.id, r.starts, coalesce(r.cpu_millis, 0) AS cpu_millis,",
        " coalesce(p.image, '') AS image, coalesce(extract(epoch FROM now()",
        " - r.heartbeat)::bigint, -1) AS ago, coalesce(extract(epoch FROM",
        " now() - r.started)::bigint, -1) AS up FROM orca.runs r LEFT JOIN",
        " orca.pipelines p ON p.name = r.pipeline WHERE r.status =",
        " 'running' AND coalesce(r.placement, 'default') IN ('default', '')",
        " AND NOT ",
        dead_sql(String(stale), start_grace(stale), "r"),
        " AND ('morca-' || r.id || '-' || r.starts) = $1" if one else (
            " AND $1 = ''"
        ),
        " ORDER BY r.id",
    )
    var out = List[PodRun]()
    for r in conn.query(sql, Params().text(one)):
        out.append(
            PodRun(
                Int(r.int64("id")),
                Int(r.int64("starts")),
                Int(r.int64("cpu_millis")),
                r.text("image"),
                Int(r.int64("ago")),
                Int(r.int64("up")),
            )
        )
    return out^


@fieldwise_init
struct WorkerToken(Copyable, Movable):
    """A worker token, as the machine its worker runs on."""

    var id: Int
    var pool: String
    var label: String
    var state: String
    """`live`, `draining` (`morca host drain`), `revoked`, `expired` or
    `not seen`."""
    var name: String
    var image: String
    var ago: Int
    var cpus: Int
    var memory_mb: Int
    var running: String
    """The runs it says it runs, comma-separated."""
    var expires: String


def worker_tokens(
    mut conn: Connection, stale: Int, one: Int
) raises -> List[WorkerToken]:
    """Every worker token, or the one with id `one` (over 0), by pool;
    `not seen` for one not heard from in `stale` seconds."""
    var sql = String(
        "SELECT id, pool, label, CASE WHEN revoked IS NOT NULL THEN",
        " 'revoked' WHEN expires <= now() THEN 'expired' WHEN last_seen IS",
        " NULL OR last_seen <= now() - make_interval(secs => $1::int) THEN",
        " 'not seen' WHEN draining IS NOT NULL THEN 'draining' ELSE 'live'",
        " END AS state, coalesce(name, '') AS name,",
        " coalesce(image, '') AS image, coalesce(extract(epoch FROM now() -",
        " last_seen)::bigint, -1) AS ago, coalesce(cpus, 0) AS cpus,",
        " coalesce(memory_mb, 0) AS mem, coalesce(running, '') AS running,",
        " to_char(expires AT TIME ZONE 'UTC', ",
        _TS,
        ") AS expires FROM orca.workers",
        " WHERE id = $2" if one else " WHERE $2 = 0",
        " ORDER BY pool, id DESC",
    )
    var out = List[WorkerToken]()
    for r in conn.query(sql, Params().int32(Int32(stale)).int64(Int64(one))):
        out.append(
            WorkerToken(
                Int(r.int64("id")),
                r.text("pool"),
                r.text("label"),
                r.text("state"),
                r.text("name"),
                r.text("image"),
                Int(r.int64("ago")),
                Int(r.int64("cpus")),
                Int(r.int64("mem")),
                r.text("running"),
                r.text("expires"),
            )
        )
    return out^


@fieldwise_init
struct WorkerRun(Copyable, Movable):
    """A run a worker claimed: for its machine's page."""

    var id: Int
    var pipeline: String
    var status: String
    var partitions: String
    var started: String
    var ended: String


def worker_runs(
    mut conn: Connection, token: Int, n: Int
) raises -> List[WorkerRun]:
    """The runs a worker token's latest starts were claimed by, newest
    first."""
    var out = List[WorkerRun]()
    for r in conn.query(
        String(
            "SELECT id, pipeline, status, partitions, coalesce(to_char(started",
            " AT TIME ZONE 'UTC', ",
            _TS,
            "), '') AS started, coalesce(to_char(ended AT TIME ZONE 'UTC', ",
            _TS,
            "), '') AS ended FROM orca.runs WHERE worker = $1 ORDER BY id DESC",
            " LIMIT $2",
        ),
        Params().int64(Int64(token)).int32(Int32(n)),
    ):
        out.append(
            WorkerRun(
                Int(r.int64("id")),
                r.text("pipeline"),
                r.text("status"),
                r.text("partitions"),
                r.text("started"),
                r.text("ended"),
            )
        )
    return out^


def run_pipeline(mut conn: Connection, run: Int) raises -> String:
    """The pipeline of a run, or empty."""
    var rows = conn.query(
        "SELECT pipeline FROM orca.runs WHERE id = $1",
        Params().int64(Int64(run)),
    )
    if len(rows) == 0:
        return ""
    return rows.row(0).text("pipeline")


@fieldwise_init
struct PoolRecord(Copyable, Movable):
    """A pool morca scales (`orca.pools`), with its machine types and
    locations as the JSON it keeps them as."""

    var name: String
    var provider: String
    var machines: String
    var locations: String
    var max_machines: Int
    var idle_seconds: Int
    var live: Int
    var trying: Int
    var status: String


def scaled_pools(mut conn: Connection) raises -> List[PoolRecord]:
    """Every pool morca scales, by name, with its live machines."""
    var out = List[PoolRecord]()
    for r in conn.query(
        (
            "SELECT p.name, p.provider, p.machines::text AS machines,"
            " p.locations::text AS locations, p.max_machines, p.idle_seconds,"
            " p.trying, coalesce(p.status, '') AS status, (SELECT count(*) FROM"
            " orca.pool_machines m WHERE m.pool = p.name AND m.ended IS NULL)"
            " AS live FROM orca.pools p ORDER BY p.name"
        ),
        Params(),
    ):
        out.append(
            PoolRecord(
                r.text("name"),
                r.text("provider"),
                r.text("machines"),
                r.text("locations"),
                Int(r.int64("max_machines")),
                Int(r.int64("idle_seconds")),
                Int(r.int64("live")),
                Int(r.int64("trying")),
                r.text("status"),
            )
        )
    return out^


@fieldwise_init
struct HostRun(Copyable, Movable):
    var id: Int
    var pipeline: String
    var placement: String
    var grant_mb: Int
    var limit_mb: Int
    """`memory.high`; 0 for a run without a cgroup."""
    var max_mb: Int
    var memory_bytes: Int
    """Its cgroup's memory when last recorded; -1 before that."""


def host_runs(mut conn: Connection) raises -> List[HostRun]:
    """The running runs placed on the scheduler's host."""
    var out = List[HostRun]()
    for r in conn.query(
        (
            "SELECT id, pipeline, coalesce(placement, 'local') AS placement,"
            " coalesce(grant_memory_mb, 0)::bigint AS grant_mb,"
            " coalesce(memory_limit_mb, 0)::bigint AS limit_mb,"
            " coalesce(memory_max_mb, 0)::bigint AS max_mb,"
            " coalesce(memory_bytes, -1)::bigint AS memory_bytes FROM"
            " orca.runs WHERE status = 'running' AND coalesce(placement,"
            " 'local') IN ('local', 'control') ORDER BY id"
        ),
        Params(),
    ):
        out.append(
            HostRun(
                Int(r.int64("id")),
                r.text("pipeline"),
                r.text("placement"),
                Int(r.int64("grant_mb")),
                Int(r.int64("limit_mb")),
                Int(r.int64("max_mb")),
                Int(r.int64("memory_bytes")),
            )
        )
    return out^
