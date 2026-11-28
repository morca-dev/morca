"""`orca.pools`, the worker pools morca.toml declares that morca grows
(`morca._internal.pool_config`), `orca.pool_machines`, the machines the pool
autoscaler (`morca._internal.pool_scale`) made for them, and
`orca.pool_settings`, what every declared pool's workers are given."""

from postgres import Connection, Params, Transaction

from morca._internal.db.run_cluster import GROUP_MAX_SQL


def upsert_pool(
    mut tx: Transaction,
    name: String,
    provider: String,
    machines: String,
    locations: String,
    max_machines: Int,
    idle_seconds: Int,
) raises:
    """Records pool `name` as morca.toml declares it; `machines` and
    `locations` are JSON."""
    _ = tx.execute(
        (
            "INSERT INTO orca.pools (name, provider, machines, locations,"
            " max_machines, idle_seconds) VALUES ($1, $2, $3::jsonb,"
            " $4::jsonb, $5, $6) ON CONFLICT (name) DO UPDATE SET provider"
            " = EXCLUDED.provider, machines = EXCLUDED.machines, locations"
            " = EXCLUDED.locations, max_machines = EXCLUDED.max_machines,"
            " idle_seconds = EXCLUDED.idle_seconds, updated = now()"
        ),
        Params()
        .text(name)
        .text(provider)
        .text(machines)
        .text(locations)
        .int64(Int64(max_machines))
        .int64(Int64(idle_seconds)),
    )


def delete_pools_but(mut tx: Transaction, keep: String) raises -> List[String]:
    """Deletes every pool not named in `keep`, a JSON array of names;
    returns the names deleted."""
    var gone = List[String]()
    for r in tx.query(
        (
            "DELETE FROM orca.pools WHERE NOT name = ANY (SELECT"
            " jsonb_array_elements_text($1::jsonb)) RETURNING name"
        ),
        Params().text(keep),
    ):
        gone.append(r.text("name"))
    return gone^


def upsert_settings(
    mut tx: Transaction,
    name: String,
    provider: String,
    env: String,
    secrets: String,
    max_runs: Int,
) raises:
    """Records what pool `name`'s workers are given; `env` and `secrets`
    are JSON, `provider` empty for a self-hosted pool, `max_runs` 0 for
    none."""
    _ = tx.execute(
        (
            "INSERT INTO orca.pool_settings (name, provider, env, secrets,"
            " max_runs) VALUES ($1, nullif($2, ''), $3::jsonb, $4::jsonb,"
            " nullif($5, 0)) ON CONFLICT (name) DO UPDATE SET provider ="
            " EXCLUDED.provider, env = EXCLUDED.env, secrets ="
            " EXCLUDED.secrets, max_runs = EXCLUDED.max_runs, updated = now()"
        ),
        Params()
        .text(name)
        .text(provider)
        .text(env)
        .text(secrets)
        .int32(Int32(max_runs)),
    )


def set_volumes(mut tx: Transaction, name: String, volumes: String) raises:
    """Records pool `name`'s volumes, a JSON array of `source:target[:ro]`
    (`upsert_settings` first)."""
    _ = tx.execute(
        "UPDATE orca.pool_settings SET volumes = $2::jsonb WHERE name = $1",
        Params().text(name).text(volumes),
    )


def volumes(mut conn: Connection, pool: String) raises -> String:
    """`pool`'s volumes as JSON, `[]` for none or a pool morca.toml doesn't
    declare."""
    var rows = conn.query(
        "SELECT volumes::text AS v FROM orca.pool_settings WHERE name = $1",
        Params().text(pool),
    )
    if len(rows) == 0:
        return "[]"
    return rows.row(0).text("v")


def delete_settings_but(mut tx: Transaction, keep: String) raises:
    """Deletes the settings of every pool not named in `keep`, a JSON array
    of names."""
    _ = tx.execute(
        (
            "DELETE FROM orca.pool_settings WHERE NOT name = ANY (SELECT"
            " jsonb_array_elements_text($1::jsonb))"
        ),
        Params().text(keep),
    )


@fieldwise_init
struct SettingsRow(Copyable, Movable):
    var max_runs: Int
    var env: String
    """JSON: `[{"name": .., "value": ..}, ...]`."""
    var secrets: String
    """JSON: `[{"name": .., "id": ..}, ...]`."""


def settings(
    mut conn: Connection, pool: String
) raises -> Optional[SettingsRow]:
    """What `pool`'s workers are given; None for a pool morca.toml doesn't
    declare."""
    var rows = conn.query(
        (
            "SELECT coalesce(max_runs, 0) AS max_runs, env::text AS env,"
            " secrets::text AS secrets FROM orca.pool_settings WHERE name = $1"
        ),
        Params().text(pool),
    )
    if len(rows) == 0:
        return None
    var r = rows.row(0)
    return SettingsRow(
        Int(r.int64("max_runs")), r.text("env"), r.text("secrets")
    )


def booting_machine(
    mut conn: Connection, worker: Int
) raises -> Optional[String]:
    """The worker image of the live machine worker token `worker` was made
    for by the pool autoscaler, empty if its row has none (made before
    #356); None if the token isn't such a machine's."""
    var rows = conn.query(
        (
            "SELECT coalesce(m.image, '') AS image FROM orca.workers w JOIN"
            " orca.pool_machines m ON m.worker = w.id WHERE w.id = $1 AND"
            " m.ended IS NULL AND w.created_by LIKE 'pool:%'"
        ),
        Params().int64(Int64(worker)),
    )
    if len(rows) == 0:
        return None
    return rows.row(0).text("image")


def draining(mut conn: Connection, worker: Int) raises -> String:
    """The image of the live pool machine of worker token `worker` if the
    autoscaler is draining it (`drain`), so the worker is given no more
    runs; empty if it isn't (or the token is no machine's)."""
    var rows = conn.query(
        (
            "SELECT coalesce(image, '(none recorded)') AS image FROM"
            " orca.pool_machines WHERE worker = $1 AND ended IS NULL AND"
            " draining IS NOT NULL"
        ),
        Params().int64(Int64(worker)),
    )
    if len(rows) == 0:
        return ""
    return rows.row(0).text("image")


def drain(mut conn: Connection, id: Int, on: Bool) raises:
    """Starts draining machine `id` (its worker is given no more runs, and
    it's removed once idle), or stops, unless it's so already."""
    _ = conn.execute(
        (
            "UPDATE orca.pool_machines SET draining = CASE WHEN $2 THEN"
            " coalesce(draining, now()) END WHERE id = $1 AND ended IS NULL"
            " AND (draining IS NULL) = $2"
        ),
        Params().int64(Int64(id)).bool(on),
    )


# ── the autoscaler (`morca._internal.pool_scale`) ──────────────────────────────────────


def stack_id(mut conn: Connection) raises -> String:
    """This stack's id (`orca.stack_identity`), made the first time."""
    _ = conn.execute(
        "INSERT INTO orca.stack_identity (id) SELECT orca.uuidv7()::text WHERE"
        " NOT EXISTS (SELECT 1 FROM orca.stack_identity)"
    )
    return (
        conn.query("SELECT min(id) AS id FROM orca.stack_identity")
        .row(0)
        .text("id")
    )


def demand(mut conn: Connection, pool: String, after: Float64) raises -> Int:
    """The runs of `pool`'s pipelines queued at least `after` seconds that
    a worker could start: per pipeline at most `max_runs` less its running
    ones, and its fill runs; and the members its running runs that spread
    (#268) still want, once they've run `after` seconds: with no group, and
    of each group that asks for no GPU, its MAX (docs/groups.md)."""
    var r = conn.query(
        (
            "SELECT (SELECT coalesce(sum(least(q.n,"
            " greatest(coalesce(p.max_runs, (p.describe->>'max_runs')::bigint,"
            " 1) - coalesce(r.n, 0), 0))), 0) + coalesce(sum(q.fills), 0) FROM"
            " orca.pipelines p JOIN (SELECT pipeline, count(*) FILTER (WHERE"
            " trigger <> 'fill') AS n, count(*) FILTER (WHERE trigger ="
            " 'fill') AS fills FROM orca.runs WHERE status = 'queued' AND"
            " created <= now() - make_interval(secs => $2) GROUP BY pipeline)"
            " q ON q.pipeline = p.name LEFT JOIN (SELECT pipeline, count(*) AS"
            " n FROM orca.runs WHERE status = 'running' AND trigger <> 'fill'"
            " GROUP BY pipeline) r ON r.pipeline = p.name WHERE p.placement ="
            " 'worker:' || $1 AND NOT p.paused AND p.binary_path IS NOT NULL)"
            # Members a running run of the pool still wants (#268): its
            # workers with no group, and each group's MAX that asks for no
            # GPU (docs/groups.md; a machine with GPUs is gpu_machines',
            # which pools don't have yet).
            " + (SELECT coalesce(sum(greatest(coalesce(p2.ec2_workers, 0) -"
            " (SELECT count(*) FROM orca.run_members m WHERE m.run = r2.id AND"
            " m.start = r2.starts AND m.ended IS NULL AND m.worker_group IS"
            " NULL), 0) + (SELECT coalesce(sum(greatest("
        )
        + GROUP_MAX_SQL
        + " - (SELECT count(*) FROM orca.run_members m WHERE m.run = r2.id"
        " AND m.start = r2.starts AND m.ended IS NULL AND m.worker_group ="
        " g->>'name'), 0)), 0) FROM jsonb_array_elements(p2.groups) g"
        " WHERE coalesce((g->>'gpus')::int, 0) = 0)), 0) FROM orca.runs"
        " r2 JOIN orca.pipelines p2 ON p2.name = r2.pipeline WHERE"
        " r2.status = 'running' AND r2.cluster_head IS NOT NULL AND"
        " p2.placement = 'worker:' || $1 AND r2.started <= now() -"
        " make_interval(secs => $2)) AS n",
        Params().text(pool).float64(after),
    )
    return Int(r.row(0).int64("n"))


@fieldwise_init
struct LiveMachine(Copyable, Movable):
    """A live machine of a pool, and its worker."""

    var id: Int
    var name: String
    var provider_id: String
    var worker: Int
    var age: Float64
    var seen: Bool
    var silent: Float64
    var busy: Bool
    var idle_for: Float64
    """Seconds since it was last seen idle, from when; -1 if it isn't."""
    var image: String
    """The worker image it was made to run; empty if its row has none."""
    var draining: Bool
    var drained: Bool
    """Its worker was asked to drain (`morca host drain`): it's removed
    once idle."""


def live_machines(
    mut conn: Connection, pool: String
) raises -> List[LiveMachine]:
    """`pool`'s live machines, oldest first."""
    var out = List[LiveMachine]()
    for r in conn.query(
        (
            "SELECT m.id, m.name, coalesce(m.provider_id, '') AS provider_id,"
            " coalesce(m.worker, 0) AS worker, extract(epoch FROM now() -"
            " m.launched)::float8 AS age, w.last_seen IS NOT NULL AS seen,"
            " coalesce(extract(epoch FROM now() - w.last_seen)::float8, 0) AS"
            " silent, (coalesce(w.running, '') <> '' OR EXISTS (SELECT 1 FROM"
            " orca.runs r WHERE r.worker = m.worker AND r.status = 'running')"
            " OR EXISTS (SELECT 1 FROM orca.run_members rm WHERE rm.worker ="
            " m.worker AND rm.ended IS NULL)) AS busy, coalesce(extract(epoch"
            " FROM now() - m.idle_since)::float8, -1) AS idle_for,"
            " coalesce(m.image, '') AS image, m.draining IS NOT NULL AS"
            " draining, coalesce(w.draining IS NOT NULL, false) AS drained"
            " FROM orca.pool_machines m LEFT JOIN orca.workers w ON"
            " w.id = m.worker WHERE m.pool = $1 AND m.ended IS NULL ORDER BY"
            " m.id"
        ),
        Params().text(pool),
    ):
        out.append(
            LiveMachine(
                Int(r.int64("id")),
                r.text("name"),
                r.text("provider_id"),
                Int(r.int64("worker")),
                r.float64("age"),
                r.bool("seen"),
                r.float64("silent"),
                r.bool("busy"),
                r.float64("idle_for"),
                r.text("image"),
                r.bool("draining"),
                r.bool("drained"),
            )
        )
    return out^


def set_status(mut conn: Connection, pool: String, text: String) raises:
    """Has `pool` say `text` on Ops."""
    _ = conn.execute(
        "UPDATE orca.pools SET status = $2 WHERE name = $1",
        Params().text(pool).text(text),
    )


def revoke_worker(mut conn: Connection, worker: Int) raises:
    """Revokes worker token `worker`, unless it's revoked already."""
    _ = conn.execute(
        (
            "UPDATE orca.workers SET revoked = coalesce(revoked, now())"
            " WHERE id = $1"
        ),
        Params().int64(Int64(worker)),
    )


def end_machine(mut conn: Connection, id: Int, why: String) raises:
    """Ends machine `id`'s row with `why`, unless it's ended."""
    _ = conn.execute(
        (
            "UPDATE orca.pool_machines SET ended = now(), why = $2 WHERE id ="
            " $1 AND ended IS NULL"
        ),
        Params().int64(Int64(id)).text(why),
    )


@fieldwise_init
struct PoolRow(Copyable, Movable):
    """A pool, as the autoscaler reads it."""

    var name: String
    var provider: String
    var machines: String
    """JSON: `[{"type": ..., "wait": ...}, ...]`."""
    var locations: String
    """JSON: an array of names."""
    var max_machines: Int
    var idle_seconds: Int
    var configured: Bool
    """morca.toml has it: not one it left with machines still live."""
    var trying: Int
    var trying_for: Float64
    """Seconds since it started trying `trying`; -1 if it isn't."""
    var since_try: Float64
    """Seconds since the last attempt; -1 for none."""


def pool_rows(mut conn: Connection) raises -> List[PoolRow]:
    """The pools morca.toml has, then those it no longer has that still have
    machines live, by name."""
    var out = List[PoolRow]()
    for r in conn.query(
        (
            "SELECT name, provider, machines::text AS machines, locations::text"
            " AS locations, max_machines, idle_seconds, true AS configured,"
            " trying, coalesce(extract(epoch FROM now() -"
            " trying_since)::float8, -1) AS trying_for, coalesce(extract(epoch"
            " FROM now() - last_try)::float8, -1) AS since_try FROM orca.pools"
            " UNION ALL SELECT DISTINCT pool, provider, '[]', '[]', 0, 0,"
            " false, 0, -1, -1 FROM orca.pool_machines WHERE ended IS NULL AND"
            " pool NOT IN (SELECT name FROM orca.pools) ORDER BY 1"
        ),
        Params(),
    ):
        out.append(
            PoolRow(
                r.text("name"),
                r.text("provider"),
                r.text("machines"),
                r.text("locations"),
                Int(r.int64("max_machines")),
                Int(r.int64("idle_seconds")),
                r.bool("configured"),
                Int(r.int64("trying")),
                r.float64("trying_for"),
                r.float64("since_try"),
            )
        )
    return out^


def provider_ids(mut conn: Connection, pool: String) raises -> List[String]:
    """The provider's ids of `pool`'s live machines."""
    var out = List[String]()
    for r in conn.query(
        (
            "SELECT provider_id FROM orca.pool_machines WHERE pool = $1 AND"
            " ended IS NULL AND provider_id IS NOT NULL"
        ),
        Params().text(pool),
    ):
        out.append(r.text("provider_id"))
    return out^


def clear_idle(mut conn: Connection, id: Int) raises:
    """Machine `id` is busy: not idle since any time."""
    _ = conn.execute(
        "UPDATE orca.pool_machines SET idle_since = NULL WHERE id = $1",
        Params().int64(Int64(id)),
    )


def mark_idle(mut conn: Connection, id: Int) raises:
    """Machine `id` is idle from now."""
    _ = conn.execute(
        "UPDATE orca.pool_machines SET idle_since = now() WHERE id = $1",
        Params().int64(Int64(id)),
    )


def stop_trying(mut conn: Connection, pool: String) raises:
    """`pool` needs no machine: it tries no type and says nothing."""
    _ = conn.execute(
        (
            "UPDATE orca.pools SET trying = 0, trying_since = NULL,"
            " status = NULL WHERE name = $1"
        ),
        Params().text(pool),
    )


def mark_try(mut conn: Connection, pool: String) raises:
    """`pool` tries to grow now, and has been trying since then if it
    wasn't."""
    _ = conn.execute(
        (
            "UPDATE orca.pools SET last_try = now(), trying_since ="
            " coalesce(trying_since, now()) WHERE name = $1"
        ),
        Params().text(pool),
    )


def grew(mut conn: Connection, pool: String, status: String) raises:
    """`pool` made a machine: it tries no type, and says `status`."""
    _ = conn.execute(
        (
            "UPDATE orca.pools SET trying = 0, trying_since ="
            " NULL, status = $2 WHERE name = $1"
        ),
        Params().text(pool).text(status),
    )


def refused(
    mut conn: Connection, pool: String, trying: Int, status: String
) raises:
    """`pool`'s type `trying` was refused: it says `status`."""
    _ = conn.execute(
        "UPDATE orca.pools SET trying = $2, status = $3 WHERE name = $1",
        Params().text(pool).int64(Int64(trying)).text(status),
    )


def try_next(
    mut conn: Connection, pool: String, trying: Int, status: String
) raises:
    """`pool` tries type `trying` from now, saying `status`."""
    _ = conn.execute(
        (
            "UPDATE orca.pools SET trying = $2, trying_since = now(),"
            " status = $3 WHERE name = $1"
        ),
        Params().text(pool).int64(Int64(trying)).text(status),
    )


def keep_trying(
    mut conn: Connection,
    pool: String,
    trying: Int,
    since_now: Bool,
    status: String,
) raises:
    """`pool` waits for type `trying`, saying `status`: since it started
    trying it, or from now (`since_now`, a type it wasn't trying)."""
    var since = "now()" if since_now else "trying_since"
    _ = conn.execute(
        String(
            "UPDATE orca.pools SET trying = $2, trying_since = ",
            since,
            ", status = $3 WHERE name = $1",
        ),
        Params().text(pool).int64(Int64(trying)).text(status),
    )


def next_machine_id(mut conn: Connection) raises -> Int:
    """A new id for `orca.pool_machines`."""
    return Int(
        conn.query("SELECT nextval('orca.pool_machines_id_seq') AS id")
        .row(0)
        .int64("id")
    )


def worker_id(mut conn: Connection, token_hash: String) raises -> Int:
    """The id of the worker token whose hash is `token_hash`."""
    return Int(
        conn.query(
            "SELECT id FROM orca.workers WHERE token_hash = $1",
            Params().text(token_hash),
        )
        .row(0)
        .int64("id")
    )


def delete_worker(mut conn: Connection, worker: Int) raises:
    """Deletes worker token `worker`."""
    _ = conn.execute(
        "DELETE FROM orca.workers WHERE id = $1",
        Params().int64(Int64(worker)),
    )


def add_machine(
    mut conn: Connection,
    id: Int,
    pool: String,
    provider: String,
    name: String,
    server_type: String,
    arch: String,
    location: String,
    provider_id: String,
    address: String,
    worker: Int,
    image: String,
) raises:
    """Records a machine made for `pool` to run worker image `image`
    (empty `arch` or `address` for unknown)."""
    _ = conn.execute(
        (
            "INSERT INTO orca.pool_machines (id, pool, provider, name,"
            " server_type, arch, location, provider_id, address, worker,"
            " image) VALUES ($1, $2, $3, $4, $5, nullif($6, ''), $7, $8,"
            " nullif($9, ''), $10, nullif($11, ''))"
        ),
        Params()
        .int64(Int64(id))
        .text(pool)
        .text(provider)
        .text(name)
        .text(server_type)
        .text(arch)
        .text(location)
        .text(provider_id)
        .text(address)
        .int64(Int64(worker))
        .text(image),
    )
