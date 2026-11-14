"""A registered pipeline's row of `orca.pipelines`, as the scheduler reads
it (`morca._internal.registered`), and the request learned for it."""

from postgres import Connection, Params


@fieldwise_init
struct Registration(Copyable, Movable):
    """A pipeline registered with a binary, its settings resolved: what's
    registered, else what its code declares, else the default."""

    var name: String
    var binary_path: String
    var registry_hash: String
    var since: Int64
    var cron: String
    var tz: String
    var fills: String
    var catchup: Bool
    var kind: String
    var start: String
    var max_runs: Int
    var run_retries: Int
    var retry_seconds: Int
    var max_retry_seconds: Int
    var sensor: Bool
    var keys_per_run: Int
    var keys_dataset: String
    var image: String
    var workers: Int
    var head_type: String
    var worker_type: String
    var spot: Bool
    var min_workers: Int
    """-1 when unset."""
    var secrets: String
    """JSON, or empty."""
    var paused: Bool
    var worker_procs: Int
    var placement: String
    var env: String
    """JSON, or empty."""
    var fill_mode: String
    """`fills`, or empty."""
    var fill_order: String
    var fill_max_runs: Int
    var fill_budget: Float64
    """-1 for none."""
    var fill_window: String
    var fill_lag: String
    var fill_max_runs_auto: Bool
    var cpus: String
    var memory_gb: String
    var memory_raised_mb: Int
    var learn: Bool
    var learn_key: String
    var learned_runs: Int
    var learned_memory_mb: Int
    var learned_cpus: Int
    var learned_key: String
    """What `learned` was learned from (`learn_key` then)."""
    var learned_capped: String
    var max_runs_auto: Bool
    var priority: Int


def registrations(
    mut conn: Connection, only: String
) raises -> List[Registration]:
    """Every pipeline registered with a binary and not retired (#427), or
    the one named (empty for every one): the highest `priority` first, then
    by name (#421)."""
    var rows = conn.query(
        (
            "SELECT name, binary_path, registry_hash, coalesce(since, 0) AS"
            " since, coalesce(describe->'schedule'->>'cron', '') AS cron,"
            " coalesce(describe->'schedule'->>'tz', 'UTC') AS tz,"
            " coalesce(describe->'schedule'->>'fills', 'previous') AS fills,"
            " coalesce((describe->'schedule'->>'catchup')::boolean, true) AS"
            " catchup, coalesce(describe->'partitions'->>'kind', 'monthly') AS"
            " kind, coalesce(describe->'partitions'->>'start', '') AS start,"
            " coalesce(max_runs, (describe->>'max_runs')::bigint, 1) AS"
            " max_runs, coalesce(max_runs_auto, false) AS max_runs_auto,"
            " coalesce((describe->>'run_retries')::bigint, 3) AS run_retries,"
            " coalesce((describe->>'retry_seconds')::bigint, 0) AS"
            " retry_seconds, coalesce((describe->>'max_retry_seconds')::bigint,"
            " 0) AS max_retry_seconds, coalesce((describe->>'sensor')::boolean,"
            " false) AS sensor, coalesce(keys_per_run,"
            " (describe->>'keys_per_run')::bigint, 1) AS keys_per_run,"
            " coalesce(describe->'partitions'->>'dataset', '') AS keys_dataset,"
            " coalesce(image, '') AS image, CASE WHEN"
            " jsonb_array_length(coalesce(describe->'tasks', '[]')) > 0 THEN"
            " coalesce(ec2_workers, (describe->>'workers')::bigint, 2) ELSE 0"
            " END AS workers, coalesce(head_type, '') AS head_type,"
            " coalesce(worker_type, '') AS worker_type, coalesce(spot, false)"
            " AS spot, coalesce(ec2_min_workers, -1) AS min_workers,"
            " coalesce(secrets::text, '') AS secrets, paused,"
            " coalesce(worker_procs, 1) AS worker_procs, coalesce(placement,"
            " '') AS placement, coalesce(env::text, '') AS env, coalesce(fills,"
            " '') AS fill_mode, coalesce(fill_order, '') AS fill_order,"
            " coalesce(fill_max_runs, 0) AS fill_max_runs,"
            " coalesce(fill_max_runs_auto, false) AS fill_max_runs_auto,"
            " coalesce(fill_budget_per_day, -1) AS fill_budget,"
            " coalesce(fill_window, '') AS fill_window, coalesce(fill_lag, '')"
            " AS fill_lag, coalesce(cpus, '') AS cpus, coalesce(memory_gb, '')"
            " AS memory_gb, coalesce(memory_raised_mb, 0) AS memory_raised_mb,"
            " coalesce(learn, true) AS learn, CASE WHEN cpus LIKE 'auto%' OR"
            " memory_gb LIKE 'auto%' THEN concat_ws('/', coalesce((SELECT"
            " r.id::text || CASE WHEN EXISTS (SELECT 1 FROM orca.steps s JOIN"
            " orca.attempts a ON a.step = s.id WHERE s.run = r.id AND"
            " a.peak_rss_bytes IS NOT NULL) THEN 'm' ELSE '' END FROM orca.runs"
            " r WHERE r.pipeline = orca.pipelines.name AND r.status ="
            " 'succeeded' ORDER BY r.id DESC LIMIT 1), ''),"
            " coalesce(memory_raised_mb, 0), coalesce(cpus, ''),"
            " coalesce(memory_gb, '')) ELSE '' END AS learn_key,"
            " coalesce(learned->>'key', '') AS learned_key,"
            " coalesce((learned->>'runs')::bigint, 0) AS learned_runs,"
            " coalesce((learned->>'memory_mb')::bigint, 0) AS"
            " learned_memory_mb, coalesce((learned->>'cpus')::bigint, 0) AS"
            " learned_cpus, coalesce(learned->>'capped', '') AS"
            " learned_capped, priority FROM orca.pipelines WHERE binary_path IS"
            " NOT NULL AND retired IS NULL AND ($1 = '' OR name = $1) ORDER BY"
            " priority DESC, name"
        ),
        Params().text(only),
    )
    var out = List[Registration]()
    for r in rows:
        out.append(
            Registration(
                r.text("name"),
                r.text("binary_path"),
                r.text("registry_hash"),
                r.int64("since"),
                r.text("cron"),
                r.text("tz"),
                r.text("fills"),
                r.bool("catchup"),
                r.text("kind"),
                r.text("start"),
                Int(r.int64("max_runs")),
                Int(r.int64("run_retries")),
                Int(r.int64("retry_seconds")),
                Int(r.int64("max_retry_seconds")),
                r.bool("sensor"),
                Int(r.int64("keys_per_run")),
                r.text("keys_dataset"),
                r.text("image"),
                Int(r.int64("workers")),
                r.text("head_type"),
                r.text("worker_type"),
                r.bool("spot"),
                Int(r.int64("min_workers")),
                r.text("secrets"),
                r.bool("paused"),
                Int(r.int64("worker_procs")),
                r.text("placement"),
                r.text("env"),
                r.text("fill_mode"),
                r.text("fill_order"),
                Int(r.int64("fill_max_runs")),
                r.float64("fill_budget"),
                r.text("fill_window"),
                r.text("fill_lag"),
                r.bool("fill_max_runs_auto"),
                r.text("cpus"),
                r.text("memory_gb"),
                Int(r.int64("memory_raised_mb")),
                r.bool("learn"),
                r.text("learn_key"),
                Int(r.int64("learned_runs")),
                Int(r.int64("learned_memory_mb")),
                Int(r.int64("learned_cpus")),
                r.text("learned_key"),
                r.text("learned_capped"),
                r.bool("max_runs_auto"),
                Int(r.int64("priority")),
            )
        )
    return out^


def keep_learned(
    mut conn: Connection,
    pipeline: String,
    key: String,
    runs: Int,
    memory_mb: Int,
    cpus: Int,
) raises:
    """Caches on `pipeline` the request learned from its runs (`key` says
    from what)."""
    _ = conn.execute(
        (
            "UPDATE orca.pipelines SET learned = jsonb_build_object('key',"
            " $2::text, 'runs', $3::bigint, 'memory_mb', $4::bigint, 'cpus',"
            " $5::bigint) || jsonb_strip_nulls(jsonb_build_object('capped',"
            " learned->'capped')) WHERE name = $1"
        ),
        Params()
        .text(pipeline)
        .text(key)
        .int64(Int64(runs))
        .int64(Int64(memory_mb))
        .int64(Int64(cpus)),
    )
