"""`morca register`'s queries (`morca._internal.registering`): what a binary's
`describe` says, and recording the pipeline it describes."""

from postgres import Connection, Params

from morca._internal.db.scheduler import RETRIED


@fieldwise_init
struct Described(Copyable, Movable):
    """What `describe` says of a pipeline, as `register` reads it."""

    var name: String
    var sensor: Bool
    var new_sensor: Bool
    """No pipeline of the name senses yet."""
    var kind: String
    """Its partitions' kind, `monthly` by default."""
    var start: String
    """Its partitions' start, or empty."""


def described(mut conn: Connection, describe: String) raises -> Described:
    """What `describe` (a binary's JSON) says of its pipeline."""
    var info = conn.query(
        (
            "SELECT $1::jsonb->>'pipeline' AS name,"
            " coalesce(($1::jsonb->>'sensor')::boolean, false) AS"
            " sensor, NOT EXISTS (SELECT 1 FROM orca.pipelines WHERE name"
            " = $1::jsonb->>'pipeline' AND sensing_since IS NOT NULL) AS"
            " new_sensor, coalesce($1::jsonb->'partitions'->>'kind',"
            " 'monthly') AS kind, coalesce($1::jsonb->'partitions'->>"
            "'start', '') AS start"
        ),
        Params().text(describe),
    ).row(0)
    return Described(
        info.text("name"),
        info.bool("sensor"),
        info.bool("new_sensor"),
        info.text("kind"),
        info.text("start"),
    )


@fieldwise_init
struct Registration(Copyable, Movable):
    """A pipeline's row as `morca register` records it: empty texts and
    the numbers' "not given" are no value."""

    var describe: String
    """The binary's `describe` (JSON)."""
    var binary_path: String
    var now: Int64
    """Its schedule counts from here the first time."""
    var sensor: Bool
    """Whether it's a sensor."""
    var image: String
    var head_type: String
    var worker_type: String
    var workers: Int
    """0: not given."""
    var spot: Bool
    var min_workers: Int
    """-1: not given."""
    var secrets: String
    """JSON, or empty."""
    var worker_procs: Int
    """-1: not given."""
    var placement: String
    """`default` clears it; empty keeps it."""
    var in_file: Bool
    """The project's morca.toml names it: what it and the flags say is all of it; otherwise a value not given keeps what was registered."""
    var max_runs: Int
    """-1: not given."""
    var env: String
    """JSON, or empty."""
    var config: String
    """JSON."""
    var fills: String
    var fill_order: String
    var fill_max_runs: Int
    """-1: not given."""
    var fill_budget: Float64
    """-1: not given."""
    var fill_window: String
    var cpus: String
    var memory_gb: String
    var fill_lag: String
    var learn: String
    var max_runs_auto: Bool
    var keys_per_run: Int
    """-1: not given."""
    var fill_max_runs_auto: Bool
    var priority: Int
    """0 when not given: kept for a pipeline the file doesn't name."""
    var probe_every: Int
    """`probe_every` (#281); -1: not given."""


def register(
    mut conn: Connection, r: Registration
) raises -> Tuple[String, String, String]:
    """Records the pipeline `r.describe` describes, or updates its row;
    returns its name, registry hash and image (empty without one)."""
    var res = conn.query(
        (
            "INSERT INTO orca.pipelines (name, registry_hash, describe,"
            " binary_path, since, sensing_since, image, head_type,"
            " worker_type, ec2_workers, spot, ec2_min_workers, secrets,"
            " worker_procs, placement, max_runs, env, config, fills,"
            " fill_order, fill_max_runs, fill_budget_per_day, fill_window,"
            " cpus, memory_gb, fill_lag, learn, max_runs_auto, keys_per_run,"
            " fill_max_runs_auto, priority, learn_from, probe_every)"
            " SELECT"
            " d->>'pipeline',"
            " d->>'registry_hash',"
            " d, $2, $3, CASE WHEN $4 THEN now() END, nullif($5, ''),"
            " nullif($6, ''), nullif($7, ''), nullif($8, 0), $9,"
            " nullif($10, -1), nullif($11, '')::jsonb, nullif($12, -1),"
            " nullif(nullif($13, ''), 'default'), nullif($15, -1),"
            " nullif($16, '')::jsonb, $17::jsonb, nullif($18, ''),"
            " nullif($19, ''), nullif($20, -1), nullif($21, -1::float8),"
            " nullif($22, ''), nullif($23, ''), nullif($24, ''),"
            " nullif($25, ''), CASE WHEN $26 = 'working_set' THEN true ELSE"
            " nullif($26, '')::boolean END, CASE WHEN $15 > 0"
            " THEN $27 END, nullif($28, -1), CASE WHEN $20 > 0 THEN $29 END,"
            " $30, CASE WHEN $26 = 'working_set' THEN $26 END,"
            " nullif($31, -1)"
            " FROM"
            " (SELECT $1::jsonb AS d) AS x ON CONFLICT (name) DO UPDATE SET"
            " registry_hash = EXCLUDED.registry_hash, describe ="
            " EXCLUDED.describe, binary_path = EXCLUDED.binary_path, since"
            " = coalesce(orca.pipelines.since, EXCLUDED.since),"
            " sensing_since = CASE WHEN $4 THEN"
            " coalesce(orca.pipelines.sensing_since, now()) END, image ="
            " coalesce(EXCLUDED.image, orca.pipelines.image), head_type ="
            " CASE WHEN $14 THEN EXCLUDED.head_type ELSE"
            " coalesce(EXCLUDED.head_type, orca.pipelines.head_type) END,"
            " worker_type = CASE WHEN $14 THEN EXCLUDED.worker_type ELSE"
            " coalesce(EXCLUDED.worker_type, orca.pipelines.worker_type)"
            " END, ec2_workers = CASE WHEN $14 THEN EXCLUDED.ec2_workers"
            " ELSE coalesce(EXCLUDED.ec2_workers,"
            " orca.pipelines.ec2_workers) END, ec2_min_workers = CASE WHEN"
            " $14 OR $8 > 0 THEN EXCLUDED.ec2_min_workers ELSE"
            " orca.pipelines.ec2_min_workers END, secrets = CASE WHEN $14"
            " THEN EXCLUDED.secrets ELSE coalesce(EXCLUDED.secrets,"
            " orca.pipelines.secrets) END, worker_procs = CASE WHEN $14"
            " THEN EXCLUDED.worker_procs WHEN $12 >= 0 THEN $12 ELSE"
            " orca.pipelines.worker_procs END, placement = CASE WHEN $14"
            " THEN EXCLUDED.placement WHEN $13 = '' THEN"
            " orca.pipelines.placement ELSE nullif($13, 'default') END,"
            " max_runs = CASE WHEN $14 OR $15 > 0 THEN EXCLUDED.max_runs"
            " ELSE orca.pipelines.max_runs END, max_runs_auto = CASE WHEN"
            " $14 OR $15 > 0 THEN EXCLUDED.max_runs_auto ELSE"
            " orca.pipelines.max_runs_auto END, env = CASE WHEN $14 THEN"
            " EXCLUDED.env ELSE orca.pipelines.env END, config = CASE WHEN"
            " $14 THEN EXCLUDED.config ELSE jsonb_build_object('sources',"
            " coalesce(orca.pipelines.config->'sources', '{}'::jsonb) ||"
            " coalesce(EXCLUDED.config->'sources', '{}'::jsonb)) END, spot"
            " = CASE WHEN $6 <> '' OR $7 <> '' OR $8 > 0 OR $9 THEN $9 ELSE"
            " orca.pipelines.spot END, fills = CASE WHEN $14 THEN"
            " EXCLUDED.fills ELSE orca.pipelines.fills END, fill_order ="
            " CASE WHEN $14 THEN EXCLUDED.fill_order ELSE"
            " orca.pipelines.fill_order END, fill_max_runs = CASE WHEN $14"
            " THEN EXCLUDED.fill_max_runs ELSE orca.pipelines.fill_max_runs"
            " END, fill_max_runs_auto = CASE WHEN $14 THEN"
            " EXCLUDED.fill_max_runs_auto ELSE"
            " orca.pipelines.fill_max_runs_auto"
            " END, fill_budget_per_day = CASE WHEN $14 THEN"
            " EXCLUDED.fill_budget_per_day ELSE"
            " orca.pipelines.fill_budget_per_day END, fill_window = CASE"
            " WHEN $14 THEN EXCLUDED.fill_window ELSE"
            " orca.pipelines.fill_window END, fill_lag = CASE WHEN $14 THEN"
            " EXCLUDED.fill_lag ELSE orca.pipelines.fill_lag END, learn ="
            " CASE WHEN $14 THEN EXCLUDED.learn ELSE orca.pipelines.learn"
            " END, learn_from = CASE WHEN $14 THEN EXCLUDED.learn_from ELSE"
            " orca.pipelines.learn_from END, probe_every = CASE WHEN $14"
            " THEN EXCLUDED.probe_every ELSE orca.pipelines.probe_every END,"
            " keys_per_run = CASE WHEN $14 THEN EXCLUDED.keys_per_run"
            " ELSE orca.pipelines.keys_per_run END, priority = CASE WHEN"
            " $14 THEN EXCLUDED.priority ELSE orca.pipelines.priority END,"
            " cpus ="
            " CASE WHEN $14 OR $23"
            " <> '' THEN EXCLUDED.cpus ELSE orca.pipelines.cpus END,"
            " memory_gb = CASE WHEN $14 OR $24 <> '' THEN"
            " EXCLUDED.memory_gb ELSE orca.pipelines.memory_gb END,"
            # A new request forgets what out-of-memory kills raised.
            " memory_raised_mb = CASE WHEN (CASE WHEN $14 OR $24 <> ''"
            " THEN EXCLUDED.memory_gb ELSE orca.pipelines.memory_gb END)"
            " IS DISTINCT FROM orca.pipelines.memory_gb THEN NULL ELSE"
            " orca.pipelines.memory_raised_mb END,"
            " last_seen = now() RETURNING name, registry_hash,"
            " coalesce(image, '') AS image"
        ),
        Params()
        .text(r.describe)
        .text(r.binary_path)
        .int64(r.now)
        .bool(r.sensor)
        .text(r.image)
        .text(r.head_type)
        .text(r.worker_type)
        .int64(Int64(r.workers))
        .bool(r.spot)
        .int64(Int64(r.min_workers))
        .text(r.secrets)
        .int64(Int64(r.worker_procs))
        .text(r.placement)
        .bool(r.in_file)
        .int64(Int64(r.max_runs))
        .text(r.env)
        .text(r.config)
        .text(r.fills)
        .text(r.fill_order)
        .int64(Int64(r.fill_max_runs))
        .float64(r.fill_budget)
        .text(r.fill_window)
        .text(r.cpus)
        .text(r.memory_gb)
        .text(r.fill_lag)
        .text(r.learn)
        .bool(r.max_runs_auto)
        .int64(Int64(r.keys_per_run))
        .bool(r.fill_max_runs_auto)
        .int64(Int64(r.priority))
        .int64(Int64(r.probe_every)),
    )
    var row = res.row(0)
    return (row.text("name"), row.text("registry_hash"), row.text("image"))


def data_versions(
    mut conn: Connection, pipeline: String, version: Int
) raises -> Tuple[Bool, String, String]:
    """Whether `pipeline` had a version, its data version, and `version`'s
    (empty for none)."""
    var dv = conn.query(
        (
            "SELECT p.version IS NOT NULL AS was, coalesce((SELECT"
            " data_version FROM orca.pipeline_versions WHERE id ="
            " p.version), '') AS old, coalesce((SELECT data_version FROM"
            " orca.pipeline_versions WHERE id = $2), '') AS new FROM"
            " orca.pipelines p WHERE p.name = $1"
        ),
        Params().text(pipeline).int64(Int64(version)),
    ).row(0)
    return (dv.bool("was"), dv.text("old"), dv.text("new"))


def set_locations(mut conn: Connection, version: Int, json: String) raises:
    """Keeps where `version`'s functions are (`morca locate`'s map)."""
    _ = conn.execute(
        "UPDATE orca.pipeline_versions SET locations = $2::jsonb WHERE id = $1",
        Params().int64(Int64(version)).text(json),
    )


def seen(
    mut conn: Connection, pipeline: String, dataset: String, snapshot: Int64
) raises:
    """Records that `pipeline` has seen `dataset`'s `snapshot`."""
    _ = conn.execute(
        (
            "INSERT INTO orca.sensed (pipeline, dataset,"
            " snapshot_id) VALUES ($1, $2, $3) ON CONFLICT DO"
            " NOTHING"
        ),
        Params().text(pipeline).text(dataset).int64(snapshot),
    )


def move_to_code(
    mut conn: Connection, pipeline: String, registry_hash: String
) raises:
    """Moves `pipeline`'s queued runs, and its deferred and retried failed
    ones with no step done, to code `registry_hash`."""
    _ = conn.execute(
        String(
            "UPDATE orca.runs r SET registry_hash = $2 WHERE pipeline =",
            " $1 AND registry_hash <> $2 AND (status = 'queued' OR",
            " ((status = 'deferred' OR (status = 'failed' AND ",
            RETRIED,
            " AND starts - deferrals BETWEEN 1 AND (SELECT",
            " coalesce((describe->>'run_retries')::bigint, 3) FROM",
            " orca.pipelines WHERE name = $1))) AND NOT EXISTS (SELECT 1",
            " FROM orca.steps s WHERE s.run = r.id AND s.status =",
            " 'succeeded')))",
        ),
        Params().text(pipeline).text(registry_hash),
    )
