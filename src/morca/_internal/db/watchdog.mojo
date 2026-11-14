"""The watchdog's queries (`morca._internal.watchdog`): what its rules read, and
`orca.watchdog_rules` (each rule's last reading and snooze) and
`orca.watchdog_trips` (each trip)."""

from postgres import Connection, Params


@fieldwise_init
struct Lease(Copyable, Movable):
    """An instance's row: its type, how long ago it started and ended
    (-1: it hasn't)."""

    var instance_type: String
    var start_ago: Float64
    var end_ago: Float64


@fieldwise_init
struct Counts(Copyable, Movable):
    """A pipeline's attempts that ended in the last hour."""

    var pipeline: String
    var failed: Int
    var total: Int


@fieldwise_init
struct Quiet(Copyable, Movable):
    """A run with a running attempt, and the minutes nothing has moved."""

    var pipeline: String
    var run: Int
    var minutes: Float64


@fieldwise_init
struct Unmet(Copyable, Movable):
    """A queued run waiting for a request more than any host it may run on
    can grant (#462), the minutes since it was queued, and why it waits."""

    var pipeline: String
    var run: Int
    var minutes: Float64
    var held: String


@fieldwise_init
struct TripRow(Copyable, Movable):
    """A row of `orca.watchdog_trips` with a pipeline still paused."""

    var rule: String
    var ago: Float64
    var at: String
    """UTC, `YYYY-MM-DD HH:MM:SS UTC`."""
    var value: Float64
    var threshold: Float64
    var detail: String
    var paused: String
    """The pipelines it paused that are still paused, comma-separated."""
    var id: Int
    var acked_by: String
    var checks: String
    """The checks' JSON, or empty for a trip from before they were kept."""
    var is_acked: Bool


@fieldwise_init
struct RuleReading(Copyable, Movable):
    """A rule's row of `orca.watchdog_rules`."""

    var value: Float64
    """-1 where the row has none."""
    var threshold: Float64
    var seen: Bool
    """Whether it was ever checked (a snooze alone writes a row)."""
    var until: String
    """When its snooze ends (UTC), or empty."""
    var live: Bool
    """Whether the snooze is still on."""
    var by: String
    var checks: String
    """The checks' JSON, or empty."""


def launches_last_hour(mut conn: Connection) raises -> Int:
    """Instances launched in the last hour, pool handovers left out."""
    return Int(
        conn.query(
            (
                "SELECT count(*) AS n FROM orca.instances WHERE launched >"
                " now() - interval '1 hour' AND NOT pooled"
            ),
            Params(),
        )
        .row(0)
        .int64("n")
    )


def leases(mut conn: Connection) raises -> List[Lease]:
    """The instances up, or ended in the last 24 hours."""
    var out = List[Lease]()
    for r in conn.query(
        (
            "SELECT instance_type, extract(epoch FROM now() -"
            " launched)::float8 AS s, CASE WHEN ended IS NULL THEN -1.0::float8"
            " ELSE extract(epoch FROM now() - ended)::float8 END AS e FROM"
            " orca.instances WHERE ended IS NULL OR ended > now() - interval"
            " '24 hours'"
        ),
        Params(),
    ):
        out.append(
            Lease(r.text("instance_type"), r.float64("s"), r.float64("e"))
        )
    return out^


comptime _IDLE_WORKERS = (
    "SELECT i.id, r.pipeline FROM orca.instances i JOIN orca.runs r ON r.id ="
    " i.run WHERE i.ended IS NULL AND i.role = 'worker' AND i.drained IS NULL"
    " AND i.idle IS NULL AND i.launched < now() - make_interval(mins =>"
    " $1::int)"
)


def idle_workers(
    mut conn: Connection, minutes: Int
) raises -> Tuple[Int, Float64, List[String]]:
    """The workers up the last `minutes` that were sampled, their average
    CPU (-1 if none), and the pipelines that own them."""
    var row = conn.query(
        String(
            "WITH w AS (",
            _IDLE_WORKERS,
            (
                ") SELECT count(DISTINCT s.host) AS n, avg(s.cpu)::float8 AS"
                " cpu FROM orca.fleet_samples s JOIN w ON w.id = s.host WHERE"
                " s.t > now() - make_interval(mins => $1::int)"
            ),
        ),
        Params().int32(Int32(minutes)),
    ).row(0)
    var pipelines = List[String]()
    for r in conn.query(
        String(
            "WITH w AS (",
            _IDLE_WORKERS,
            (
                ") SELECT DISTINCT w.pipeline FROM w WHERE EXISTS (SELECT 1"
                " FROM orca.fleet_samples s WHERE s.host = w.id AND s.t > now()"
                " - make_interval(mins => $1::int)) ORDER BY 1"
            ),
        ),
        Params().int32(Int32(minutes)),
    ):
        pipelines.append(r.text("pipeline"))
    var cpu = -1.0 if row.is_null("cpu") else row.float64("cpu")
    return (Int(row.int64("n")), cpu, pipelines^)


def failing_counts(mut conn: Connection) raises -> List[Counts]:
    """Each pipeline's attempts that ended in the last hour."""
    var out = List[Counts]()
    for r in conn.query(
        (
            "SELECT r.pipeline, count(*) FILTER (WHERE a.status = 'failed') AS"
            " failed, count(*) AS total FROM orca.attempts a JOIN orca.steps s"
            " ON s.id = a.step JOIN orca.runs r ON r.id = s.run WHERE a.ended"
            " > now() - interval '1 hour' AND a.status IN ('succeeded',"
            " 'failed') GROUP BY r.pipeline ORDER BY r.pipeline"
        ),
        Params(),
    ):
        out.append(
            Counts(
                r.text("pipeline"),
                Int(r.int64("failed")),
                Int(r.int64("total")),
            )
        )
    return out^


def quiet_runs(mut conn: Connection, cpu: Float64) raises -> List[Quiet]:
    """The running runs with a running attempt on sampled instances, and
    how long since anything moved: an attempt, an instance, or a host
    over `cpu` percent."""
    var out = List[Quiet]()
    for r in conn.query(
        (
            "SELECT r.pipeline, r.id AS run, extract(epoch FROM now() -"
            " greatest(ev.last, b.last))::float8 / 60 AS quiet FROM orca.runs r"
            " JOIN LATERAL (SELECT greatest((SELECT max(greatest(a.started,"
            " a.ended)) FROM orca.attempts a JOIN orca.steps s ON s.id ="
            " a.step WHERE s.run = r.id), (SELECT max(greatest(i.launched,"
            " i.joined, i.ended)) FROM orca.instances i WHERE i.run = r.id),"
            " r.started, r.created) AS last) ev ON true LEFT JOIN LATERAL"
            " (SELECT max(f.t) AS last FROM orca.fleet_samples f JOIN"
            " orca.instances i ON i.id = f.host WHERE i.run = r.id AND f.cpu"
            " >= $1) b ON true WHERE r.status = 'running' AND EXISTS (SELECT 1"
            " FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE"
            " s.run = r.id AND a.status = 'running') AND EXISTS (SELECT 1 FROM"
            " orca.fleet_samples f JOIN orca.instances i ON i.id = f.host"
            " WHERE i.run = r.id AND i.ended IS NULL AND f.t > now() -"
            " interval '5 minutes') ORDER BY r.id"
        ),
        Params().float64(cpu),
    ):
        out.append(
            Quiet(r.text("pipeline"), Int(r.int64("run")), r.float64("quiet"))
        )
    return out^


def unmet_runs(mut conn: Connection) raises -> List[Unmet]:
    """The queued runs held for a request more than this host, or any
    worker of their pool, grants at most (`morca._internal.resources.admit`,
    `morca._internal.workers.pool_unmet`). One a single worker can't grant
    may wait for another, so isn't one."""
    var out = List[Unmet]()
    for r in conn.query(
        (
            "SELECT pipeline, id AS run, extract(epoch FROM now() -"
            " created)::float8 / 60 AS waited, held FROM orca.runs WHERE"
            " status = 'queued' AND (held LIKE '%this host grants at most%'"
            " OR held LIKE '%a worker of pool % grants at most%') ORDER BY id"
        ),
        Params(),
    ):
        out.append(
            Unmet(
                r.text("pipeline"),
                Int(r.int64("run")),
                r.float64("waited"),
                String(r.text("held").removeprefix("waiting: ")),
            )
        )
    return out^


def is_snoozed(mut conn: Connection, rule: String) raises -> Bool:
    return (
        len(
            conn.query(
                (
                    "SELECT 1 FROM orca.watchdog_rules WHERE rule = $1 AND"
                    " snoozed_until > now()"
                ),
                Params().text(rule),
            )
        )
        > 0
    )


def record_reading(
    mut conn: Connection,
    rule: String,
    value: Float64,
    threshold: Float64,
    detail: String,
    checks: String,
) raises:
    """Keeps a rule's reading, `checks` its checks' JSON."""
    _ = conn.execute(
        (
            "INSERT INTO orca.watchdog_rules (rule, value, threshold, detail,"
            " checked, checks) VALUES ($1, $2, $3, $4, now(),"
            " $5::text::jsonb) ON CONFLICT (rule) DO UPDATE SET value ="
            " EXCLUDED.value, threshold = EXCLUDED.threshold, detail ="
            " EXCLUDED.detail, checked = EXCLUDED.checked, checks ="
            " EXCLUDED.checks"
        ),
        Params()
        .text(rule)
        .float64(value)
        .float64(threshold)
        .text(detail)
        .text(checks),
    )


def insert_trip(
    mut conn: Connection,
    rule: String,
    value: Float64,
    threshold: Float64,
    detail: String,
    pipelines: String,
    checks: String,
) raises:
    """Records a trip that paused `pipelines` (comma-separated)."""
    _ = conn.execute(
        (
            "INSERT INTO orca.watchdog_trips (rule, value, threshold,"
            " detail, pipelines, checks) VALUES ($1, $2, $3, $4, $5,"
            " $6::text::jsonb)"
        ),
        Params()
        .text(rule)
        .float64(value)
        .float64(threshold)
        .text(detail)
        .text(pipelines)
        .text(checks),
    )


def prune_trips(mut conn: Connection) raises:
    """Forgets trips over 30 days old."""
    _ = conn.execute(
        "DELETE FROM orca.watchdog_trips WHERE at < now() - interval '30 days'",
        Params(),
    )


def end_snooze(mut conn: Connection, rule: String) raises:
    _ = conn.execute(
        (
            "UPDATE orca.watchdog_rules SET snoozed_until = NULL,"
            " snoozed_by = NULL WHERE rule = $1"
        ),
        Params().text(rule),
    )


def set_snooze(
    mut conn: Connection, rule: String, seconds: Int, by: String
) raises:
    """Snoozes `rule` for `seconds` from now."""
    _ = conn.execute(
        (
            "INSERT INTO orca.watchdog_rules (rule, snoozed_until, snoozed_by)"
            " VALUES ($1, now() + make_interval(secs => $2::float8), $3) ON"
            " CONFLICT (rule) DO UPDATE SET snoozed_until ="
            " EXCLUDED.snoozed_until, snoozed_by = EXCLUDED.snoozed_by"
        ),
        Params().text(rule).float64(Float64(seconds)).text(by),
    )


def acknowledge_trip(mut conn: Connection, trip: Int, by: String) raises:
    _ = conn.execute(
        (
            "UPDATE orca.watchdog_trips SET acknowledged_at = now(),"
            " acknowledged_by = $2 WHERE id = $1"
        ),
        Params().int64(Int64(trip)).text(by),
    )


def trip_rows(mut conn: Connection) raises -> List[TripRow]:
    """The trips with a pipeline still paused, newest first."""
    var out = List[TripRow]()
    for r in conn.query(
        (
            "SELECT * FROM (SELECT t.rule, extract(epoch FROM now() -"
            " t.at)::float8 AS ago, to_char(t.at AT TIME ZONE 'UTC',"
            " 'YYYY-MM-DD HH24:MI:SS') || ' UTC' AS at, t.value, t.threshold,"
            " t.detail, t.id, coalesce(t.acknowledged_by, '') AS acked,"
            " coalesce(t.checks::text, '') AS checks,"
            " t.acknowledged_at IS NOT NULL AS is_acked, (SELECT"
            " string_agg(p.name, ',' ORDER BY p.name) FROM orca.pipelines p"
            " WHERE p.paused AND p.name = ANY(string_to_array(t.pipelines,"
            " ','))) AS paused FROM orca.watchdog_trips t) x WHERE paused IS"
            " NOT NULL ORDER BY id DESC"
        ),
        Params(),
    ):
        out.append(
            TripRow(
                r.text("rule"),
                r.float64("ago"),
                r.text("at"),
                r.float64("value"),
                r.float64("threshold"),
                r.text("detail"),
                r.text("paused"),
                Int(r.int64("id")),
                r.text("acked"),
                r.text("checks"),
                r.bool("is_acked"),
            )
        )
    return out^


def rule_reading(mut conn: Connection, rule: String) raises -> RuleReading:
    """`rule`'s row of `orca.watchdog_rules`; not `seen` without one."""
    var rows = conn.query(
        (
            "SELECT value, threshold, checked IS NOT NULL AS seen,"
            " coalesce(to_char(snoozed_until AT TIME ZONE 'UTC',"
            " 'YYYY-MM-DD HH24:MI:SS') || ' UTC', '') AS until,"
            " snoozed_until > now() AS live, coalesce(snoozed_by, '') AS"
            " by, coalesce(checks::text, '') AS checks FROM"
            " orca.watchdog_rules WHERE rule = $1"
        ),
        Params().text(rule),
    )
    if len(rows) == 0 or not rows.row(0).bool("seen"):
        return RuleReading(
            -1.0, 0.0, False, String(), False, String(), String()
        )
    var r = rows.row(0)
    return RuleReading(
        r.float64("value") if not r.is_null("value") else -1.0,
        r.float64("threshold"),
        True,
        r.text("until"),
        (not r.is_null("live")) and r.bool("live"),
        r.text("by"),
        r.text("checks"),
    )
