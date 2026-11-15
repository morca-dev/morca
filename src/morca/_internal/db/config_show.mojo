"""`morca config show` and `morca config export`'s query
(`morca._internal.config_show`): each registered pipeline's settings as registered,
null where nothing was, beside what its code declares."""

from postgres import Connection, Params, Row

comptime _SHOWN_SQL = (
    "SELECT name, head_type, worker_type, ec2_workers, ec2_min_workers,"
    " worker_procs, placement, max_runs, coalesce(max_runs_auto, false) AS"
    " max_runs_auto, coalesce(describe->>'max_runs', '1') AS code_max_runs,"
    " keys_per_run, coalesce(describe->>'keys_per_run', '1') AS"
    " code_keys_per_run, describe->>'workers' AS code_workers,"
    " jsonb_array_length(coalesce(describe->'tasks', '[]')) > 0 AS tasks,"
    " coalesce(secrets::text, '') AS secrets, coalesce(env::text, '') AS env,"
    " coalesce(config::text, '') AS config, coalesce(image, '') AS image,"
    " coalesce(spot, false) AS spot, coalesce(fills, '') AS fills,"
    " coalesce(fill_order, '') AS fill_order, coalesce(fill_max_runs, 0) AS"
    " fill_max_runs, coalesce(fill_max_runs_auto, false) AS fill_max_runs_auto,"
    " coalesce(fill_budget_per_day, -1) AS fill_budget, coalesce(fill_window,"
    " '') AS fill_window, coalesce(fill_lag, '') AS fill_lag, coalesce(cpus,"
    " '') AS cpus, coalesce(memory_gb, '') AS memory_gb, learn, priority,"
    " coalesce(concurrency_key, '') AS concurrency_key,"
    " coalesce(concurrency_limit, 0)::bigint AS concurrency_limit FROM"
    " orca.pipelines WHERE binary_path IS NOT NULL AND ($1 = '' OR name = $1)"
    " ORDER BY name"
)


@fieldwise_init
struct Settings(Copyable, Movable):
    """A registered pipeline's row of `_SHOWN_SQL`: None where nothing is
    registered."""

    var name: String
    var head_type: Optional[String]
    var worker_type: Optional[String]
    var ec2_workers: Optional[Int64]
    var ec2_min_workers: Optional[Int64]
    var worker_procs: Optional[Int64]
    var placement: Optional[String]
    var max_runs: Optional[Int64]
    var max_runs_auto: Bool
    var code_max_runs: String
    var keys_per_run: Optional[Int64]
    var code_keys_per_run: String
    var code_workers: Optional[String]
    var tasks: Bool
    var secrets: String
    var env: String
    var config: String
    """JSON, or empty."""
    var image: String
    var spot: Bool
    var fills: String
    var fill_order: String
    var fill_max_runs: Int64
    var fill_max_runs_auto: Bool
    var fill_budget: Float64
    """-1 for none."""
    var fill_window: String
    var fill_lag: String
    var cpus: String
    var memory_gb: String
    var learn: Optional[Bool]
    var priority: Int64
    var concurrency_key: String
    """Its concurrency key (#397), or empty."""
    var concurrency_limit: Int64


def _text(r: Row, c: String) raises -> Optional[String]:
    if r.is_null(c):
        return None
    return r.text(c)


def _int(r: Row, c: String) raises -> Optional[Int64]:
    if r.is_null(c):
        return None
    return r.int64(c)


def _bool(r: Row, c: String) raises -> Optional[Bool]:
    if r.is_null(c):
        return None
    return r.bool(c)


def settings(mut conn: Connection, only: String) raises -> List[Settings]:
    """Each pipeline registered with a binary, or the one named (empty for
    every one), by name."""
    var out = List[Settings]()
    for r in conn.query(_SHOWN_SQL, Params().text(only)):
        out.append(
            Settings(
                r.text("name"),
                _text(r, "head_type"),
                _text(r, "worker_type"),
                _int(r, "ec2_workers"),
                _int(r, "ec2_min_workers"),
                _int(r, "worker_procs"),
                _text(r, "placement"),
                _int(r, "max_runs"),
                r.bool("max_runs_auto"),
                r.text("code_max_runs"),
                _int(r, "keys_per_run"),
                r.text("code_keys_per_run"),
                _text(r, "code_workers"),
                r.bool("tasks"),
                r.text("secrets"),
                r.text("env"),
                r.text("config"),
                r.text("image"),
                r.bool("spot"),
                r.text("fills"),
                r.text("fill_order"),
                r.int64("fill_max_runs"),
                r.bool("fill_max_runs_auto"),
                r.float64("fill_budget"),
                r.text("fill_window"),
                r.text("fill_lag"),
                r.text("cpus"),
                r.text("memory_gb"),
                _bool(r, "learn"),
                r.int64("priority"),
                r.text("concurrency_key"),
                r.int64("concurrency_limit"),
            )
        )
    return out^
