"""Remote workers, the server's side: worker tokens, claims, and the store
calls a worker's runs make over `morca ui` (`morca._internal.http_store`).

```
morca worker-token create --pool bgent [--days N] [--label L]   prints the token once
morca worker-token list                                          id, pool, label, worker, last seen
morca worker-token revoke <id>
```

A pipeline placed `worker:<pool>` (`placement` in morca.toml, or `morca
register --placement worker:<pool>`) has its runs started by a worker of
that pool (`morca worker`, `morca._internal.worker`), never by the scheduler, which
keeps them queued, `held` "waiting for a worker of pool <pool>", requeues
one whose heartbeat went stale (a worker that died, or a laptop that went
to sleep) as it would start any dead run again, and fails one that has no
retries left. A run whose worker is gone (not seen for half the stale
limit, or seen since without it) is queued again whatever its trigger. A
pipeline with `fills = "all"` has its fill runs queued the same way, held
for a worker, at most `fill_max_runs` of them queued or running across the
pool (`morca._internal.fill`).

**Tokens.** A worker token is an API token (`morca._internal.tokens`: `orca_` and 64
hex digits, kept only as its SHA-256), in `orca.workers` rather than
`orca.api_tokens`, scoped to one pool: it can claim that pool's runs and
make the store calls of the runs it claimed, and nothing else; a user's
token gets nothing here, and a worker token gets nothing elsewhere. It
lasts `--days` (default and at most `MORCA_WORKER_TOKEN_DAYS`, 365). A
revoked token stays listed, as revoked, and is answered 401.

**The API** (`morca._internal.api.worker`): `/api/worker/claim`, the worker's
heartbeat and its claims; `/api/worker/release`, a run it won't start;
`/api/worker/exited`, a run's process ended; `/api/worker/store/<call>`,
`store_call`, a `RunStore` call of a run it claimed.

A claim takes, under its pipeline's lock, a queued run whose pipeline isn't
paused and has fewer than `max_runs` live runs (a fill run: fewer than
`fill_max_runs` running fill runs, inside its `fill_window`, with fills on),
its other runs before its fill runs (the oldest of each pipeline's, so one
pipeline's queue at its cap never holds up another's), and starts it as the
scheduler starts a run: `running`, owner `worker`, no heartbeat yet (the
run's process claims it, within the start grace), one more start. Each
claim is a row of `orca.audit` (user `worker:<label>`, source `worker`).
**Versions.** A run needs its pipeline's image (`--image`, `image` in
morca.toml) to be the worker's (`MORCA_IMAGE`), both empty included: a worker
of another image isn't given it, and it stays queued, held saying why. The
worker checks the spec again before it starts anything (`morca._internal.worker`).
"""

from std.os import getenv

from json import Value, loads
import morca._internal.db.audit as audit_db
import morca._internal.db.pools as pools_db
import morca._internal.db.scheduler as scheduler_db
import morca._internal.db.starting as starting_db
import morca._internal.db.workers as workers_db

from morca._internal.run_cluster import (
    join_claim,
    member_spec_json,
    members_of,
    members_to_stop,
    stop_json,
)
from morca._internal.admission import (
    PressureRow,
    Report,
    alert_stuck,
    pressure_rows,
    record as record_pressure,
    resolve_stuck,
    row_json,
    worker_host,
)
from morca._internal.control import WORKER_PREFIX, pool_of, pool_problem
from morca._internal.http_store import (
    STORE_PATH,
    Body,
    bytes_of_hex,
    pins_json,
    prior_json,
    run_info_json,
    steps_json,
)
from morca.civil import now
from morca._internal.json import quote
from morca._internal.db.live import dead_sql, stale_limit, start_grace
from morca._internal.cgroup import (
    growth_pct_of,
    oom_text,
    raised_mb,
    raised_request,
)
from morca._internal.recommend import RunRequest
from morca._internal.resources import (
    WAITING,
    Grant,
    Request,
    Room,
    admit,
    gb_text,
)
from morca._internal.registered import (
    recorded_cpus,
    recorded_memory_gb,
    registered,
    run_request,
    say_capped,
    with_cap,
)
from morca._internal.handover import RunOutdated, run_outdated
from morca._internal.state import PgStore, State, beat_run
from morca._internal.store import FINAL, TableSnapshot
from morca._internal.tokens import (
    Issued,
    clean_label,
    is_token,
    new_token,
    token_hash,
)
from morca._internal.usage import marks_of, record as record_usage

comptime WORKER_OWNER = "worker"
"""A run's owner once a worker claimed it, until its process does."""
comptime DEFAULT_WORKER_TOKEN_DAYS = 365


# ── pools and placement ──────────────────────────────────────────────────────


def version_refusal(needed: String, have: String) -> String:
    """Why a worker of image `have` can't run a run whose pipeline is image
    `needed`, or empty when they're the same."""
    if needed == have:
        return ""
    return String(
        "the run needs image ",
        needed if needed else "(none)",
        " and the worker is ",
        have if have else "(none: MORCA_IMAGE isn't set)",
    )


# ── tokens ───────────────────────────────────────────────────────────────────


def worker_token_days(asked: Int = 0) raises -> Int:
    """`asked` if from 1 to `MORCA_WORKER_TOKEN_DAYS` (default 365, at most
    3650), else that most."""
    var most: Int
    try:
        most = Int(
            getenv("MORCA_WORKER_TOKEN_DAYS", String(DEFAULT_WORKER_TOKEN_DAYS))
        )
    except:
        raise Error("morca: MORCA_WORKER_TOKEN_DAYS isn't a count of days")
    if most < 1 or most > 3650:
        raise Error("morca: MORCA_WORKER_TOKEN_DAYS is 1 to 3650, not ", most)
    return asked if asked >= 1 and asked < most else most


def create_worker_token(
    mut db: State, pool: String, label: String, days: Int, by: String
) raises -> Issued:
    """A new token for a worker of `pool`, which only this answer holds."""
    var why = pool_problem(pool)
    if why:
        raise Error("morca: ", why)
    var token = new_token()
    var expires = workers_db.add_token(
        db.conn,
        token_hash(token),
        pool,
        clean_label(label if label else pool),
        by,
        days,
    )
    return Issued(token^, expires^)


def revoke_worker_token(mut db: State, id: Int) raises -> Bool:
    """Revokes worker token `id`; False if it's no live one."""
    return workers_db.revoke(db.conn, id)


@fieldwise_init
struct WorkerAuth(Copyable, Movable):
    """The worker a request's token is."""

    var id: Int
    var pool: String
    var label: String

    def placement(self) -> String:
        return String(WORKER_PREFIX, self.pool)

    def user(self) -> String:
        """Who it is in `orca.audit`."""
        return String(WORKER_PREFIX, self.label)


def worker_of(mut db: State, token: String) raises -> Optional[WorkerAuth]:
    """The live worker token `token` is, marked seen; None for any other."""
    if not is_token(token):
        return None
    var got = workers_db.seen(db.conn, token_hash(token))
    if not got:
        return None
    ref t = got.value()
    return WorkerAuth(t.id, t.pool, t.label)


@fieldwise_init
struct WorkerRow(Copyable, Movable):
    """A worker token, and what its worker last said of itself."""

    var id: Int
    var pool: String
    var label: String
    var state: String
    """`live`, `revoked` or `expired`."""
    var name: String
    """The worker's host name, once it has claimed; else empty."""
    var image: String
    var last_seen: String
    var seen_ago: Int
    """Seconds since it was last seen; -1 if never."""
    var cpus: Int
    var memory_mb: Int
    var running: String
    """The runs it's running, comma-separated, as it said."""
    var expires: String
    var pressure: Optional[PressureRow]
    """Its host's newest memory pressure reading (`morca._internal.admission`), if
    it sent one."""


def worker_rows(mut db: State) raises -> List[WorkerRow]:
    """Every worker token, newest first."""
    var out = List[WorkerRow]()
    var pressure = Dict[String, PressureRow]()
    for p in pressure_rows(db):
        pressure[p.host] = p.copy()
    for r in workers_db.tokens(db.conn):
        out.append(
            WorkerRow(
                r.id,
                r.pool,
                r.label,
                r.state,
                r.name,
                r.image,
                r.last_seen,
                r.seen_ago,
                r.cpus,
                r.memory_mb,
                r.running,
                r.expires,
                pressure.get(worker_host(r.id)),
            )
        )
    return out^


def ran_on(mut db: State, run: Int) raises -> String:
    """The worker a run's latest start was claimed by, as `<name> (token
    <id>, <label>)`, or empty for a run no worker claimed."""
    var got = workers_db.ran_on(db.conn, run)
    if not got:
        return ""
    ref r = got.value()
    return String(
        r.name if r.name else String("a worker"),
        " (token ",
        r.id,
        ", ",
        r.label,
        ")",
    )


# ── claims ───────────────────────────────────────────────────────────────────


@fieldwise_init
struct WorkerRun(Copyable, Movable):
    """What a worker is given to run: a start of a run, and how."""

    var run: Int
    var start: Int
    var pipeline: String
    var binary: String
    var registry_hash: String
    var partitions: String
    var allow_new_code: Bool
    var image: String
    """The image it needs the worker to be (`version_refusal`)."""
    var env: List[Tuple[String, String]]
    """The pipeline's own variables (`env` in morca.toml)."""
    var secrets: List[Tuple[String, String]]
    """Its secrets: the variable and the ID the worker reads it by, with its
    own `MORCA_SECRET_FETCH`."""
    var grant: Grant
    """What this start was granted of the worker's host (`morca._internal.resources`);
    none for a pipeline without a request, or a worker that didn't say
    what it can grant."""
    var members: Int
    """How many more workers its dista cluster may spread over
    (`morca._internal.run_cluster`); 0 runs it on this worker alone."""


def _pairs_json(
    pairs: List[Tuple[String, String]], a: String, b: String
) -> String:
    var out = String("[")
    for i in range(len(pairs)):
        out.write(", " if i else "")
        out.write(Body().text(a, pairs[i][0]).text(b, pairs[i][1]).finish())
    out.write("]")
    return out^


def _pairs_of(
    v: Value, a: String, b: String
) raises -> List[Tuple[String, String]]:
    var out = List[Tuple[String, String]]()
    for p in v.array_items():
        out.append((p[a].string_value(), p[b].string_value()))
    return out^


def worker_run_json(w: WorkerRun) -> String:
    return (
        Body()
        .int("run", Int64(w.run))
        .int("start", Int64(w.start))
        .text("pipeline", w.pipeline)
        .text("binary", w.binary)
        .text("registry_hash", w.registry_hash)
        .text("partitions", w.partitions)
        .bool("allow_new_code", w.allow_new_code)
        .text("image", w.image)
        .raw("env", _pairs_json(w.env, "name", "value"))
        .raw("secrets", _pairs_json(w.secrets, "name", "id"))
        .int("grant_cpus", Int64(w.grant.cpus))
        .int("grant_memory_mb", Int64(w.grant.memory_mb))
        .int("members", Int64(w.members))
        .finish()
    )


def worker_run_of(v: Value) raises -> WorkerRun:
    return WorkerRun(
        Int(v["run"].int_value()),
        Int(v["start"].int_value()),
        v["pipeline"].string_value(),
        v["binary"].string_value(),
        v["registry_hash"].string_value(),
        v["partitions"].string_value(),
        v["allow_new_code"].bool_value(),
        v["image"].string_value(),
        _pairs_of(v["env"], "name", "value"),
        _pairs_of(v["secrets"], "name", "id"),
        Grant(
            Int(v["grant_cpus"].int_value()) if String("grant_cpus")
            in v else 0,
            Int(v["grant_memory_mb"].int_value()) if String("grant_memory_mb")
            in v else 0,
        ),
        Int(v["members"].int_value()) if String("members") in v else 0,
    )


def _seen(mut db: State, w: WorkerAuth, v: Value) raises:
    """Keeps what the worker says of itself, for Ops."""
    var cpus = Int64(0)
    var mem = Int64(0)
    if String("cpus") in v and v["cpus"].is_int():
        cpus = v["cpus"].int_value()
    if String("memory_mb") in v and v["memory_mb"].is_int():
        mem = v["memory_mb"].int_value()
    # What it can grant a run, from a worker that says (#462).
    var room_cpus = Int64(-1)
    var room_mb = Int64(-1)
    if String("room_cpus") in v and String("room_memory_mb") in v:
        room_cpus = v["room_cpus"].int_value()
        room_mb = v["room_memory_mb"].int_value()
    workers_db.set_seen(
        db.conn,
        w.id,
        text_field(v, "name"),
        text_field(v, "image"),
        Int(cpus),
        Int(mem),
        text_field(v, "running"),
        Int(room_cpus),
        Int(room_mb),
    )
    if String("pressure") in v and v["pressure"].is_object():
        _pressure_seen(db, w, v, Report.from_json(v["pressure"]))


def _pressure_seen(mut db: State, w: WorkerAuth, v: Value, r: Report) raises:
    """Keeps a worker's memory pressure (`morca._internal.admission`), says on its
    pool's queued runs that they wait for it while it claims none, and
    alerts once a hold has nothing of morca's to wait for."""
    record_pressure(db, worker_host(w.id), r)
    var name = text_field(v, "name")
    var who = String("worker ", name) if name else w.user()
    var suffix = String(" on ", who)
    if r.held:
        workers_db.hold_for_pressure(
            db.conn, w.placement(), String(r.held, suffix), suffix
        )
        if r.stuck:
            alert_stuck(db, who, r)
        return
    workers_db.unhold_pressure(
        db.conn,
        w.placement(),
        String("held: waiting for a worker of pool ", w.pool),
        suffix,
    )
    resolve_stuck(db, who, r)


def text_field(v: Value, key: String) raises -> String:
    """A field of a worker's JSON as text: a number's digits, empty for
    none or null."""
    if key not in v or v[key].is_null():
        return ""
    if v[key].is_int():
        return String(v[key].int_value())
    return v[key].string_value()


def _num(v: Value, key: String) raises -> Int64:
    if key not in v:
        raise Error("morca: no ", key, " in the request")
    return v[key].int_value()


def claim(mut db: State, w: WorkerAuth, v: Value) raises -> String:
    """`/api/worker/claim`'s answer: `{"run": <spec>|null, "refused": ...,
    "join": <member spec>, "stop": [member, ...]}`. Nothing for a draining
    pool machine (`morca._internal.pool_scale`). With no run to start,
    room left and an address the pool's machines reach it at
    (`advertise`), a run to join (`morca._internal.run_cluster`); and always the
    members it has whose run has ended, to stop."""
    var stop = members_to_stop(db, w.id)
    # A pool machine the autoscaler is draining (a deploy changed the
    # worker image, #356) is given nothing new: it finishes what it has
    # and is replaced once idle.
    var drained = pools_db.draining(db.conn, w.id)
    var answer: String
    if drained:
        _seen(db, w, v)
        answer = String(
            '{"run": null, "refused": ',
            quote(
                String(
                    "this machine is draining: it runs ",
                    drained,
                    ", which is no longer the pool's image",
                )
            ),
            "}",
        )
    else:
        answer = _claim_run(db, w, v)
    var slots = Int(v["slots"].int_value()) if String("slots") in v else 0
    var advertise = text_field(v, "advertise")
    if (
        not drained
        and answer.startswith('{"run": null')
        and slots > 0
        and advertise
    ):
        var room_cpus = -1
        var room_mb = -1
        if String("room_cpus") in v and String("room_memory_mb") in v:
            room_cpus = Int(v["room_cpus"].int_value())
            room_mb = Int(v["room_memory_mb"].int_value())
        var g = workers_db.granted(db.conn, w.id)
        var name = text_field(v, "name")
        var joined = join_claim(
            db,
            w.id,
            w.placement(),
            room_cpus,
            room_mb,
            g[0],
            g[1],
            String("worker ", name) if name else w.user(),
        )
        if joined:
            var head = String(answer[byte = : answer.byte_length() - 1])
            answer = String(
                head,
                ', "join": ',
                member_spec_json(joined.value()),
                "}",
            )
    return String(
        answer[byte = : answer.byte_length() - 1],
        ', "stop": ',
        stop_json(stop),
        "}",
    )


comptime POOL_ROOM_SECONDS = 600
"""How recently a worker must have been seen for its room to count among
its pool's (`pool_room`)."""


def pool_unmet(
    req: Request, most_cpus: Int, most_mb: Int, pool: String
) -> String:
    """Why `req` waits for no worker of `pool` that's up, the most of which
    grants `most_cpus` and `most_mb`: "waiting: needs 5 GB, more than the
    3.5 GB a worker of pool g grants at most"; empty if one could."""
    var why = List[String]()
    if most_mb > 0 and req.memory_min_mb > most_mb:
        why.append(
            String(
                gb_text(req.memory_min_mb),
                " GB, more than the ",
                gb_text(most_mb),
                " GB a worker of pool ",
                pool,
                " grants at most",
            )
        )
    if most_cpus > 0 and req.cpus_min > most_cpus:
        why.append(
            String(
                req.cpus_min,
                " CPU" if req.cpus_min == 1 else " CPUs",
                ", more than the ",
                most_cpus,
                " a worker of pool ",
                pool,
                " grants at most",
            )
        )
    if len(why) == 0:
        return String()
    var text = String(WAITING)
    for i in range(len(why)):
        text.write("; needs " if i else "", why[i])
    return text^


def _claim_run(mut db: State, w: WorkerAuth, v: Value) raises -> String:
    """A queued run of the pool for the worker to start: `{"run":
    <spec>|null, "refused": ...}`."""
    _seen(db, w, v)
    var slots = Int(v["slots"].int_value()) if String("slots") in v else 0
    if slots <= 0:
        return String('{"run": null}')
    var image = text_field(v, "image")
    var name = text_field(v, "name")
    # What the worker's host can grant (morca.resources), from a worker that
    # says; -1 from one that doesn't, whose runs aren't admitted.
    var room_cpus = -1
    var room_mb = -1
    if String("room_cpus") in v and String("room_memory_mb") in v:
        room_cpus = Int(v["room_cpus"].int_value())
        room_mb = Int(v["room_memory_mb"].int_value())
    var stale = stale_limit()
    var dead = dead_sql("$2", start_grace(stale))
    var refused = String()
    # The most a worker of the pool grants a run, this one's included
    # (#462): learned requests are capped at it, and a request over it
    # waits for no worker that's up.
    var most = workers_db.pool_room(db.conn, w.pool, POOL_ROOM_SECONDS)
    var most_cpus = max(most[0], room_cpus)
    var most_mb = max(most[1], room_mb)
    var most_of = String("the most a worker of pool ", w.pool, " grants")
    # The oldest queued run of each of the pool's pipelines, and of its fill
    # runs: the others of a pipeline would be refused for the same reasons
    # (its cap, image or request), and a long queue of one pipeline at its
    # max_runs mustn't hide the runs of the others behind it. The highest
    # priority first (#421), and within one, the other runs first, then the
    # fill runs, each oldest first. One behind an
    # older run of its keys waits for it (morca.live.behind_sql).
    var candidates = workers_db.candidates(db.conn, w.placement())
    var hour = Int((now() % 86400) // 3600)
    for c in candidates:
        var id = c.id
        var ps = registered(db, c.pipeline)
        if len(ps) == 0:
            continue
        ref p = ps[0]
        var fill = c.trigger == "fill"
        if fill and not p.fill.in_window(hour):
            continue  # it waits for its fill_window, as a local one does
        var why = version_refusal(p.image, image)
        if why:
            refused = why
            workers_db.hold_queued(
                db.conn,
                p.name,
                String("held: ", w.user(), " can't run it: ", why),
                fill,
            )
            continue
        # Its request (morca.resources), `auto` learned from its runs
        # (morca.recommend), from a worker that says what it can grant.
        var sized = RunRequest.none()
        if room_cpus >= 0:
            sized = run_request(db, p, most_cpus, most_mb, most_of)
            say_capped(db, p, sized)
        var tx = db.conn.begin()
        starting_db.lock_pipeline(tx, p.name)
        # Its fill runs and its others are capped apart, as on the local
        # runner: `fill_max_runs` (the scheduler queues no more than that,
        # and this holds it if it was lowered since), `max_runs`.
        var live = starting_db.live_count(tx, p.name, stale, dead, fill)
        if live >= (p.fill.max_runs if fill else p.max_runs):
            tx.rollback()
            continue
        var request = sized.request
        if request.memory_min_mb > 0:
            # At least what an out-of-memory kill raised it to.
            request.memory_min_mb = raised_request(
                request.memory_min_mb,
                request.memory_max_mb,
                p.memory_raised_mb,
            )
        var grant = Grant.none()
        var admitted = request.any() and room_cpus >= 0
        if admitted:
            var g = workers_db.granted_live(tx, w.id, stale, dead)
            var fit = admit(
                request,
                Room(room_cpus, room_mb, room_cpus, room_mb),
                g[0],
                g[1],
                1,
                String("worker ", name) if name else w.user(),
            )
            if len(fit[0]) == 0:
                tx.rollback()
                var unmet = pool_unmet(request, most_cpus, most_mb, w.pool)
                refused = with_cap(unmet if unmet else fit[1], sized)
                workers_db.hold_queued(db.conn, p.name, refused, fill)
                continue
            grant = fit[0][0]
        var got = workers_db.start_claimed(
            tx,
            id,
            WORKER_OWNER,
            w.placement(),
            w.id,
            recorded_cpus(p, sized) if admitted else String(),
            recorded_memory_gb(p, sized) if admitted else String(),
            grant.cpus,
            grant.memory_mb,
            sized.source,
            sized.runs,
        )
        if not got:
            tx.rollback()
            continue
        ref r = got.value()
        var spec = WorkerRun(
            Int(id),
            r.start,
            p.name,
            p.binary,
            p.registry_hash,
            r.partitions,
            r.allow_new_code,
            p.image,
            p.env.copy(),
            p.secrets.copy(),
            grant,
            members_of(db, p.name) if p.workers > 0 else 0,
        )
        audit_db.add(
            tx,
            w.user(),
            "/api/worker/claim",
            Int(id),
            String(
                "start ",
                spec.start,
                " on ",
                name if name else String("a worker"),
                ", pool ",
                w.pool,
            ),
            "worker",
        )
        tx.commit()
        return String('{"run": ', worker_run_json(spec), "}")
    if refused:
        return String('{"run": null, "refused": ', quote(refused), "}")
    return String('{"run": null}')


def release(mut db: State, w: WorkerAuth, v: Value) raises -> String:
    """`/api/worker/release`: puts back a run the worker was given and won't
    start (its spec isn't for this worker's image), held saying why."""
    var why = text_field(v, "why")
    var n = workers_db.give_back(
        db.conn,
        _num(v, "run"),
        _num(v, "start"),
        w.id,
        String("held: ", w.user(), " refused it: ", why),
        WORKER_OWNER,
    )
    return String('{"released": ', "true" if n == 1 else "false", "}")


def _contained_exit(mut db: State, w: WorkerAuth, v: Value) raises:
    """A worker's run's cgroup (`morca._internal.cgroup`), at its process's end: its
    limit on the attempts it made, and after an out-of-memory kill, while
    the start is still this worker's, those left running failed saying so
    and the pipeline's memory raised, up to its request's maximum; killed
    at that maximum, the run fails too, unretried."""
    var run = _num(v, "run")
    var start = _num(v, "start")
    var limit = Int(_num(v, "memory_limit_mb"))
    var kill = (
        Int(_num(v, "memory_max_mb")) if String("memory_max_mb") in v else limit
    )
    var got = workers_db.contained(db.conn, run, w.id, start)
    if not got:
        return
    ref r = got.value()
    # Stall times from a worker that measures them (an older one doesn't).
    var stall = (
        _num(v, "memory_stall_ms") if String("memory_stall_ms") in v else -1
    )
    var stall_full = (
        _num(v, "memory_stall_full_ms") if String("memory_stall_full_ms")
        in v else -1
    )
    workers_db.set_attempt_limits(
        db.conn,
        run,
        String(_num(v, "pid")),
        limit,
        r.grant_mb,
        stall,
        stall_full,
    )
    if _num(v, "oom") != 1 or not r.running:
        return
    var ceiling = limit
    if r.memory_gb:
        ceiling = Request.of("", r.memory_gb).memory_max_mb
    var g = getenv("MORCA_RUN_MEMORY_GROWTH")
    var next = raised_mb(limit, growth_pct_of(g) if g else 150, ceiling)
    # `held` from a worker that knows it (an older one doesn't send it).
    var held = String("held") in v and _num(v, "held") == 1
    var why = oom_text(limit, kill, next, held)
    _ = db.interrupt(Int(run), why)
    scheduler_db.raise_memory(db.conn, r.pipeline, next, Int(run))
    print("run", run, "on", w.user(), why)
    # At the most it may ask for, a retry would be killed again: the run
    # fails now, with the kill as its error.
    if next <= limit:
        workers_db.fail_killed(db.conn, run, w.id, start, why)


def exited(mut db: State, w: WorkerAuth, v: Value) raises -> String:
    """`/api/worker/exited`: fails a run whose process ended before it
    claimed it, as the scheduler's reap does for a local run, and records
    what the process's attempts used from the worker's samples."""
    var run = _num(v, "run")
    var why = String(
        "its process on ",
        text_field(v, "name") if text_field(v, "name") else String("a worker"),
        " exited ",
        _num(v, "code"),
        " before claiming it",
    )
    var last = text_field(v, "last")
    if last:
        why.write(": ", last)
    var n = workers_db.fail_unclaimed(
        db.conn, run, _num(v, "start"), w.id, why, WORKER_OWNER
    )
    var used = 0
    if String("marks") in v and String("pid") in v:
        used = record_usage(
            db,
            Int(run),
            Int(_num(v, "pid")),
            marks_of(v["marks"]),
            Int(_num(v, "max_rss")) if String("max_rss") in v else -1,
            worker=w.id,
            start=Int(_num(v, "start")),
        )
    if String("memory_limit_mb") in v and String("pid") in v:
        _contained_exit(db, w, v)
    return String(
        '{"failed": ', "true" if n == 1 else "false", ', "usage": ', used, "}"
    )


# ── store calls ──────────────────────────────────────────────────────────────


def _run_of(mut db: State, w: WorkerAuth, run: Int64) raises -> String:
    """The pipeline of `run` if this worker claimed its latest start; else
    raises, final."""
    var got = workers_db.claimed_pipeline(db.conn, run, w.id, w.placement())
    if not got:
        raise Error(
            FINAL,
            "morca: run ",
            run,
            " isn't one ",
            w.user(),
            " claimed; stopping",
        )
    return got.value()


def _check_attempt(mut db: State, run: Int64, attempt_id: Int64) raises:
    if not workers_db.attempt_of(db.conn, attempt_id, run):
        raise Error(
            FINAL, "morca: attempt ", attempt_id, " isn't run ", run, "'s"
        )


def store_call(
    mut db: State, url: String, w: WorkerAuth, call: String, v: Value
) raises -> String:
    """A worker's run's `RunStore` call `call`, with the fields `v`, made on
    `PgStore`; the answer's JSON. Raises what the call raised."""
    var run = _num(v, "run")
    var pipeline = _run_of(db, w, run)
    var store = PgStore(
        State(url),
        url,
        Int(run),
        text_field(v, "owner"),
        text_field(v, "registry_hash"),
    )
    if call == "run_info":
        return String('{"run": ', run_info_json(store.run_info(Int(run))), "}")
    if call == "claim":
        var stale = (
            v["stale"].float_value() if String("stale") in v else stale_limit()
        )
        store.claim(Int(run), text_field(v, "owner"), stale)
        return "{}"
    if call == "version":
        if text_field(v, "pipeline") != pipeline:
            raise Error(FINAL, "morca: run ", run, " is of pipeline ", pipeline)
        var n = store.version(
            pipeline,
            text_field(v, "registry_hash"),
            v["describe"].raw_json(),
            text_field(v, "image"),
        )
        return String('{"version": ', n, "}")
    if call == "ran_version":
        store.ran_version(Int(run), Int(_num(v, "version")))
        return "{}"
    if call == "interrupt":
        var n = store.interrupt(Int(run), text_field(v, "why"))
        return String('{"n": ', n, "}")
    if call == "prior":
        return String('{"steps": ', prior_json(store.prior(Int(run))), "}")
    if call == "steps":
        return String('{"steps": ', steps_json(store.steps(Int(run))), "}")
    if call == "start_attempt":
        var input = bytes_of_hex(text_field(v, "input"))
        var n = store.start_attempt_once(
            text_field(v, "step"),
            text_field(v, "partition"),
            Int(_num(v, "ord")),
            Span(input),
        )
        return String(
            '{"attempt": ', n, ', "attempt_id": ', store.attempt_id(), "}"
        )
    if call == "finish_attempt":
        var output = bytes_of_hex(text_field(v, "output"))
        store.finish_attempt_once(
            text_field(v, "step"),
            text_field(v, "partition"),
            Int(_num(v, "attempt")),
            text_field(v, "status"),
            Span(output),
            text_field(v, "error"),
        )
        return "{}"
    if call == "skip":
        store.skip_once(
            text_field(v, "step"),
            text_field(v, "partition"),
            Int(_num(v, "ord")),
            text_field(v, "reason"),
        )
        return "{}"
    if call == "pinned_reads":
        var pins = store.pinned_reads(
            text_field(v, "step"), text_field(v, "partition")
        )
        return String('{"pins": ', pins_json(pins), "}")
    if call == "run_token":
        return String('{"token": ', quote(store.run_token()), "}")
    if call == "record":
        var attempt = _num(v, "attempt_id")
        _check_attempt(db, run, attempt)
        store.at_attempt(attempt)
        store.record(
            v["commit"].bool_value(),
            TableSnapshot(
                text_field(v, "table"),
                _num(v, "snapshot"),
                text_field(v, "dataset"),
            ),
        )
        return "{}"
    if call == "set_log":
        var attempt = _num(v, "attempt_id")
        _check_attempt(db, run, attempt)
        store.at_attempt(attempt)
        store.set_log("", "", 0, text_field(v, "path"))
        return "{}"
    if call == "fence":
        store.fence()
        return "{}"
    if call == "finish_run":
        store.finish_run(text_field(v, "status"))
        return "{}"
    if call == "defer_run":
        store.defer_run(_num(v, "until"))
        return "{}"
    if call == "cancel_requested":
        var c = store.cancel_requested()
        return String('{"cancel": ', "true" if c else "false", "}")
    if call == "beat":
        var why = beat_run(
            store.db.conn,
            Int(run),
            text_field(v, "owner"),
            text_field(v, "timeouts"),
        )
        # And whether a newer version leads, for its `morca.outdated()`;
        # not knowing doesn't fail the beat.
        var o = RunOutdated(False, String(), String(), String())
        try:
            o = run_outdated(store.db.conn, Int(run))
        except:
            pass
        return String(
            '{"stop": ',
            quote(why),
            ', "outdated": ',
            "true" if o.outdated else "false",
            ', "code_version": ',
            quote(o.mine),
            ', "desired_code_version": ',
            quote(o.desired),
            ', "outdated_why": ',
            quote(o.why),
            "}",
        )
    raise Error("morca: no store call ", call)


# ── Ops ──────────────────────────────────────────────────────────────────────


def workers_json(rows: List[WorkerRow]) -> String:
    var out = String('{"workers": [')
    for i in range(len(rows)):
        ref r = rows[i]
        out.write(", " if i else "")
        out.write(
            Body()
            .int("id", Int64(r.id))
            .text("pool", r.pool)
            .text("label", r.label)
            .text("state", r.state)
            .text("name", r.name)
            .text("image", r.image)
            .text("last_seen", r.last_seen)
            .int("seen_seconds_ago", Int64(r.seen_ago))
            .int("cpus", Int64(r.cpus))
            .int("memory_mb", Int64(r.memory_mb))
            .text("running", r.running)
            .text("expires", r.expires)
            .raw("memory_pressure", row_json(r.pressure))
            .finish()
        )
    out.write("]}")
    return out^
