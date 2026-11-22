"""The pipelines' pages' queries (`morca._internal.views.pipelines`,
`morca._internal.views.steps`, `morca._internal.ui.pipeline`): a registration with its schedule
and live runs (`PipelineRow`), its steps (`StepDef`), what its latest runs'
steps did, its sensor's errors, a keyed pipeline's failed keys and a key's
steps, and what its runs used (`UsageSummary`).
"""

from postgres import Connection, Params

from morca._internal.db.runs_view import utc_sql


def _int_or_zero(s: String) -> Int:
    try:
        return Int(s)
    except:
        return 0


def comma_list(s: String) -> List[String]:
    """A comma-separated list, empty for an empty string."""
    var out = List[String]()
    if s:
        for p in s.split(","):
            out.append(String(p))
    return out^


@fieldwise_init
struct PipelineRow(Copyable, Movable):
    var name: String
    var registry_hash: String
    var binary: String
    var kind: String
    var start: String
    var cron: String
    var tz: String
    var fills: String
    var max_runs: Int
    var run_retries: Int
    var running: Int
    var queued: Int
    var last_run: Int
    """0 when it has none."""
    var last_status: String
    var last_partitions: String
    var next_fire: String
    var next_partition: String
    var paused: Bool
    """`morca pause`: the scheduler starts none of its runs."""
    var sense_error: String
    """Why the sensor's last pass failed, or empty."""
    var sense_error_at: String
    var placement: String
    """`morca register --placement`: `control`, `ec2`, or empty for the
    scheduler's runner."""
    var cpus: String
    """The CPUs it asks for (`morca._internal.resources`), or empty."""
    var memory_gb: String
    """The memory it asks for, in GB, or empty."""
    var waiting: String
    """Why its oldest queued run that waits for room on its host waits
    (`morca._internal.resources`), or empty."""
    var fill_lag: String
    """`fill_lag` as registered (`morca._internal.fill`), or empty."""


def pipeline_rows(
    mut conn: Connection, name: String = ""
) raises -> List[PipelineRow]:
    """Every registered pipeline but the retired ones (#427), or the one
    named, retired too, with no next fire (`morca._internal.views.pipelines`
    works that out)."""
    var rows = conn.query(
        String(
            (
                "SELECT p.name, p.registry_hash, coalesce(p.binary_path, '') AS"
                " binary, coalesce(p.describe->'partitions'->>'kind', '') AS"
                " kind, coalesce(p.describe->'partitions'->>'start', '') AS"
                " start, coalesce(p.describe->'schedule'->>'cron', '') AS cron,"
                " coalesce(p.describe->'schedule'->>'tz', '') AS tz,"
                " coalesce(p.describe->'schedule'->>'fire',"
                " p.describe->'schedule'->>'fills', '') AS fills,"
                " coalesce(p.max_runs::text, p.describe->>'max_runs', '1') AS"
                " max_runs, coalesce(p.describe->>'run_retries', '0') AS"
                " run_retries, (SELECT count(*) FROM orca.runs r WHERE"
                " r.pipeline = p.name AND r.status = 'running')::text AS"
                " running, (SELECT count(*) FROM orca.runs r WHERE r.pipeline ="
                " p.name AND r.status = 'queued')::text AS queued,"
                " coalesce(l.id, 0)::text AS last_run, coalesce(l.status, '')"
                " AS last_status, coalesce(l.partitions, '') AS"
                " last_partitions, p.paused, coalesce(p.sense_error, '') AS"
                " sense_error, coalesce(p.placement, '') AS placement,"
                " coalesce(p.cpus, '') AS cpus, coalesce(p.memory_gb, '') AS"
                " memory_gb, coalesce((SELECT r.held FROM orca.runs r WHERE"
                " r.pipeline = p.name AND r.status = 'queued' AND r.held LIKE"
                " 'waiting: %' ORDER BY r.id LIMIT 1), '') AS waiting,"
                " coalesce(p.fill_lag, '') AS fill_lag, "
            ),
            utc_sql("p.sense_error_at"),
            (
                " AS sense_error_at FROM orca.pipelines p LEFT JOIN LATERAL"
                " (SELECT id, status, partitions FROM orca.runs r WHERE"
                " r.pipeline = p.name ORDER BY id DESC LIMIT 1) l ON true WHERE"
                " ($1 = '' AND p.retired IS NULL OR p.name = $1) ORDER BY"
                " p.name"
            ),
        ),
        Params().text(name),
    )
    var out = List[PipelineRow]()
    for r in rows:
        out.append(
            PipelineRow(
                r.text("name"),
                r.text("registry_hash"),
                r.text("binary"),
                r.text("kind"),
                r.text("start"),
                r.text("cron"),
                r.text("tz"),
                r.text("fills"),
                _int_or_zero(r.text("max_runs")),
                _int_or_zero(r.text("run_retries")),
                _int_or_zero(r.text("running")),
                _int_or_zero(r.text("queued")),
                _int_or_zero(r.text("last_run")),
                r.text("last_status"),
                r.text("last_partitions"),
                "",
                "",
                r.bool("paused"),
                r.text("sense_error"),
                r.text("sense_error_at"),
                r.text("placement"),
                r.text("cpus"),
                r.text("memory_gb"),
                r.text("waiting"),
                r.text("fill_lag"),
            )
        )
    return out^


@fieldwise_init
struct StepDef(Copyable, Movable):
    var name: String
    var kind: String
    var after: String
    var reads: List[String]
    var writes: List[String]
    var function: String
    """Its function's linkage name, as `describe` records it."""
    var input: String
    var output: String


def step_defs(mut conn: Connection, name: String) raises -> List[StepDef]:
    """Pipeline `name`'s steps as its registration describes them."""
    var rows = conn.query(
        (
            "SELECT s->>'name' AS name, s->>'kind' AS kind,"
            " coalesce(s->>'after', '') AS after, coalesce((SELECT"
            " string_agg(v, ',') FROM jsonb_array_elements_text(coalesce(s->"
            "'reads', '[]')) AS v), '') AS reads, coalesce((SELECT"
            " string_agg(v, ',') FROM jsonb_array_elements_text(coalesce(s->"
            "'writes', '[]')) AS v), '') AS writes, coalesce(s->>'function',"
            " '') AS function, coalesce(s->>'input', '') AS input,"
            " coalesce(s->>'output', '') AS output FROM orca.pipelines p,"
            " jsonb_array_elements(p.describe->'steps') WITH ORDINALITY AS x(s,"
            " n) WHERE p.name = $1 ORDER BY n"
        ),
        Params().text(name),
    )
    var out = List[StepDef]()
    for r in rows:
        out.append(
            StepDef(
                r.text("name"),
                r.text("kind"),
                r.text("after"),
                comma_list(r.text("reads")),
                comma_list(r.text("writes")),
                r.text("function"),
                r.text("input"),
                r.text("output"),
            )
        )
    return out^


comptime _FAILED_SQL = (
    "SELECT DISTINCT st.partition AS key FROM orca.steps st JOIN orca.runs r"
    " ON r.id = st.run WHERE r.pipeline = $1 AND st.status IN ('failed',"
    " 'skipped') AND st.partition = ANY (string_to_array($2, ',')) ORDER BY 1"
)


def failed_keys(
    mut conn: Connection, pipeline: String, keys: String
) raises -> List[String]:
    """Which of `keys` (comma-separated) a step of `pipeline` failed or
    skipped, in order."""
    var out = List[String]()
    for r in conn.query(_FAILED_SQL, Params().text(pipeline).text(keys)):
        out.append(r.text("key"))
    return out^


def has_fill_runs(mut conn: Connection, pipeline: String) raises -> Bool:
    """Whether `pipeline` has a fill run (`morca._internal.fill`)."""
    var any = conn.query(
        (
            "SELECT 1 FROM orca.runs WHERE pipeline = $1 AND trigger ="
            " 'fill' LIMIT 1"
        ),
        Params().text(pipeline),
    )
    return len(any) > 0


@fieldwise_init
struct UsageSummary(Copyable, Movable):
    """What a pipeline's latest measured runs used: the median and the most
    of each run's peak memory, CPU seconds and peak cores; -1 for none."""

    var runs: Int
    var peak_p50: Float64
    var peak_max: Float64
    var cpu_p50: Float64
    var cpu_max: Float64
    var cpus_p50: Float64
    var cpus_max: Float64
    var ws_runs: Int
    """How many of them a probe measured the working set of (#281)."""
    var ws_p50: Float64
    """Their working sets' median and most, in MB; -1 for none."""
    var ws_max: Float64

    def json(self) -> String:
        """`{"runs": n, "peak_rss_bytes": {"p50": .., "max": ..}, ...}`."""
        var out = String('{"runs": ', self.runs)
        var parts = [
            ("peak_rss_bytes", self.peak_p50, self.peak_max),
            ("cpu_seconds", self.cpu_p50, self.cpu_max),
            ("peak_cpus", self.cpus_p50, self.cpus_max),
            ("working_set_mb", self.ws_p50, self.ws_max),
        ]
        for p in parts:
            out.write(', "', p[0], '": {"p50": ')
            out.write(_json_num(p[1]), ', "max": ', _json_num(p[2]), "}")
        out.write(', "working_set_runs": ', self.ws_runs, "}")
        return out^


def _json_num(x: Float64) -> String:
    """`x` to the thousandth as JSON, or null if it's negative."""
    if x < 0:
        return "null"
    return String(Float64(Int(x * 1000.0 + 0.5)) / 1000.0)


def usage_summary(
    mut conn: Connection, name: String, runs: Int
) raises -> UsageSummary:
    """Pipeline `name`'s latest `runs` runs that recorded what they used,
    summarized."""
    var r = conn.query(
        (
            "SELECT count(*) AS n, coalesce(percentile_cont(0.5) WITHIN GROUP"
            " (ORDER BY peak), -1) AS peak_p50, coalesce(max(peak), -1)::float8"
            " AS peak_max, coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY"
            " cpu), -1) AS cpu_p50, coalesce(max(cpu), -1) AS cpu_max,"
            " coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY cpus), -1)"
            " AS cpus_p50, coalesce(max(cpus), -1) AS cpus_max, count(ws) AS"
            " ws_n, coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY ws),"
            " -1) AS ws_p50, coalesce(max(ws), -1)::float8 AS ws_max FROM"
            " (SELECT max(a.peak_rss_bytes) AS peak, sum(a.cpu_seconds) AS cpu,"
            " max(a.peak_cpus) AS cpus, max(a.working_set_mb) AS ws FROM"
            " orca.runs r JOIN orca.steps s ON"
            " s.run = r.id JOIN orca.attempts a ON a.step = s.id WHERE"
            " r.pipeline = $1 GROUP BY r.id HAVING max(a.peak_rss_bytes) IS"
            " NOT NULL OR sum(a.cpu_seconds) IS NOT NULL ORDER BY r.id DESC"
            " LIMIT $2) x"
        ),
        Params().text(name).int64(Int64(runs)),
    ).row(0)
    return UsageSummary(
        Int(r.int64("n")),
        r.float64("peak_p50"),
        r.float64("peak_max"),
        r.float64("cpu_p50"),
        r.float64("cpu_max"),
        r.float64("cpus_p50"),
        r.float64("cpus_max"),
        Int(r.int64("ws_n")),
        r.float64("ws_p50"),
        r.float64("ws_max"),
    )


@fieldwise_init
struct SenseError(Copyable, Movable):
    """A snapshot a pipeline's sensor saw and couldn't run, and why."""

    var dataset: String
    var snapshot: Int64
    var at: String
    var error: String


def sense_errors(
    mut conn: Connection, pipeline: String
) raises -> List[SenseError]:
    """The latest 10 snapshots `pipeline`'s sensor couldn't run."""
    var out = List[SenseError]()
    for x in conn.query(
        String(
            "SELECT dataset, snapshot_id, error, ",
            utc_sql("created"),
            " AS at FROM orca.sensed WHERE pipeline = $1 AND error IS NOT",
            " NULL ORDER BY created DESC, dataset LIMIT 10",
        ),
        Params().text(pipeline),
    ):
        out.append(
            SenseError(
                x.text("dataset"),
                x.int64("snapshot_id"),
                x.text("at"),
                x.text("error"),
            )
        )
    return out^


@fieldwise_init
struct KeyStep(Copyable, Movable):
    """A step a run of a keyed pipeline ran over one key (`/pipelines/<name>
    /keys/<key>`)."""

    var run: Int64
    var run_status: String
    var current: Bool
    """Whether the run ran the code the pipeline is registered with now."""
    var step: String
    var status: String
    var error: String
    var attempts: Int64


def key_steps(
    mut conn: Connection, pipeline: String, key: String
) raises -> List[KeyStep]:
    """`key`'s steps in every run of `pipeline` it was in, by run."""
    var out = List[KeyStep]()
    for r in conn.query(
        (
            "SELECT r.id AS run, r.status AS run_status, r.registry_hash ="
            " p.registry_hash AS current, st.step, st.status,"
            " coalesce(st.error, '') AS error, (SELECT count(*) FROM"
            " orca.attempts a WHERE a.step = st.id) AS attempts FROM orca.steps"
            " st JOIN orca.runs r ON r.id = st.run JOIN orca.pipelines p ON"
            " p.name = r.pipeline WHERE r.pipeline = $1 AND st.partition = $2"
            " ORDER BY r.id, st.ord"
        ),
        Params().text(pipeline).text(key),
    ):
        out.append(
            KeyStep(
                r.int64("run"),
                r.text("run_status"),
                r.bool("current"),
                r.text("step"),
                r.text("status"),
                r.text("error"),
                r.int64("attempts"),
            )
        )
    return out^


@fieldwise_init
struct StepStats(Copyable, Movable):
    """What a step's attempts in a pipeline's latest runs did
    (`morca._internal.views.steps`); -1 for a time or a peak none had."""

    var step: String
    var runs: Int
    var attempts: Int
    var failed: Int
    var took_p50: Float64
    var took_max: Float64
    var peak_p50: Float64
    var peak_max: Float64


def step_stats(
    mut conn: Connection, pipeline: String, runs: Int
) raises -> List[StepStats]:
    """Each step's attempts in `pipeline`'s latest `runs` runs: how many
    failed, the p50 and most its succeeded ones took, and its peak
    memory's."""
    var out = List[StepStats]()
    for r in conn.query(
        (
            "SELECT s.step, count(DISTINCT s.run) AS runs, count(*) AS"
            " attempts, count(*) FILTER (WHERE a.status = 'failed') AS failed,"
            " coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY"
            " extract(epoch FROM a.ended - a.started)::float8) FILTER (WHERE"
            " a.status = 'succeeded' AND a.ended IS NOT NULL), -1) AS"
            " took_p50, coalesce(max(extract(epoch FROM a.ended -"
            " a.started)::float8) FILTER (WHERE a.status = 'succeeded'), -1)"
            " AS took_max, coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER"
            " BY a.peak_rss_bytes), -1) AS peak_p50,"
            " coalesce(max(a.peak_rss_bytes), -1)::float8 AS peak_max FROM"
            " orca.steps s JOIN orca.attempts a ON a.step = s.id WHERE s.run"
            " IN (SELECT id FROM orca.runs WHERE pipeline = $1 ORDER BY id"
            " DESC LIMIT $2) GROUP BY s.step"
        ),
        Params().text(pipeline).int64(Int64(runs)),
    ):
        out.append(
            StepStats(
                r.text("step"),
                Int(r.int64("runs")),
                Int(r.int64("attempts")),
                Int(r.int64("failed")),
                r.float64("took_p50"),
                r.float64("took_max"),
                r.float64("peak_p50"),
                r.float64("peak_max"),
            )
        )
    return out^
