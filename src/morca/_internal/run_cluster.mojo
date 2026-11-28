"""One run's dista cluster over several workers of a pool (#268), the UI's
side: the run's head, the members that join it, and when they stop.

- **The head.** A pipeline placed `worker:<pool>` with `workers = N` set
  (its run spreads over up to N more machines) is started by the worker
  that claims it as a cluster of its own, when that worker says the
  address the pool's machines reach it at (`morca worker --advertise`): a
  dista head on a free port, a dista worker, and the run's driver. It
  reports the head's address and the run's cluster token
  (`/api/worker/cluster`, `report_head`), kept on the run
  (`orca.runs.cluster_head`, `cluster_token`) for this start only.
- **Members.** A worker of the pool with room, and an address, that has no
  run to start is given one to join (`join_claim`): a running run of the
  pool whose head is known, with fewer live members than its `workers`,
  that isn't already this worker's. It's sized as a run of the pipeline
  would be on that machine, counted against the machine's room with its
  runs, and kept in `orca.run_members`. The worker starts a dista worker
  against the head, with the token (dista's `DISTA_TOKEN`: nothing without
  it joins), and says when it ends (`/api/worker/left`, `member_left`).
- **Stopping.** Each claim's answer lists this worker's members whose run
  isn't running at that start any more (`members_to_stop`): the worker
  kills them, and they're ended "its run ended".

The token reaches a member only in a claim's answer, over the worker API's
TLS, and is never in a log or a page.
"""

from json import Value
import morca._internal.db.run_cluster as cluster_db

from morca._internal.http_store import Body
from morca._internal.registered import registered, run_request
from morca._internal.cgroup import raised_request
from morca._internal.resources import Grant, Room, admit
from morca._internal.state import State


def members_of(mut db: State, pipeline: String) raises -> Int:
    """How many more machines `pipeline`'s runs may spread over: its
    `workers`, when set for it; 0 (one machine) when not."""
    return cluster_db.spread(db.conn, pipeline)


def report_head(mut db: State, worker: Int, v: Value) raises -> String:
    """`/api/worker/cluster`: the run's head is at `head`, with `token`; kept
    if the run is still this worker's at that start."""
    var n = cluster_db.set_head(
        db.conn,
        Int(v["run"].int_value()),
        Int(v["start"].int_value()),
        worker,
        v["head"].string_value(),
        v["token"].string_value(),
    )
    return String('{"ok": ', "true" if n == 1 else "false", "}")


def member_left(mut db: State, worker: Int, v: Value) raises -> String:
    """`/api/worker/left`: member `member`'s process ended, `code`."""
    var code = v["code"].int_value() if String("code") in v else Int64(0)
    cluster_db.end_member(
        db.conn,
        Int(v["member"].int_value()),
        worker,
        String("its process exited ", code),
    )
    return String('{"ok": true}')


def members_to_stop(mut db: State, worker: Int) raises -> List[Int]:
    """This worker's live members whose run isn't running at their start
    any more, ended "its run ended": the worker kills them."""
    return cluster_db.end_stale_members(db.conn, worker)


@fieldwise_init
struct MemberSpec(Copyable, Movable):
    """What a worker is given to join: a dista worker for a run's cluster."""

    var member: Int
    var run: Int
    var start: Int
    var pipeline: String
    var binary: String
    var head: String
    """The run's head, `host:port`."""
    var token: String
    """The run's cluster token: dista's `DISTA_TOKEN`."""
    var env: List[Tuple[String, String]]
    var secrets: List[Tuple[String, String]]
    var grant: Grant


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


def member_spec_json(m: MemberSpec) -> String:
    return (
        Body()
        .int("member", Int64(m.member))
        .int("run", Int64(m.run))
        .int("start", Int64(m.start))
        .text("pipeline", m.pipeline)
        .text("binary", m.binary)
        .text("head", m.head)
        .text("token", m.token)
        .raw("env", _pairs_json(m.env, "name", "value"))
        .raw("secrets", _pairs_json(m.secrets, "name", "id"))
        .int("grant_cpus", Int64(m.grant.cpus))
        .int("grant_memory_mb", Int64(m.grant.memory_mb))
        .int("grant_gpus", Int64(m.grant.gpus))
        .finish()
    )


def member_spec_of(v: Value) raises -> MemberSpec:
    return MemberSpec(
        Int(v["member"].int_value()),
        Int(v["run"].int_value()),
        Int(v["start"].int_value()),
        v["pipeline"].string_value(),
        v["binary"].string_value(),
        v["head"].string_value(),
        v["token"].string_value(),
        _pairs_of(v["env"], "name", "value"),
        _pairs_of(v["secrets"], "name", "id"),
        Grant(
            Int(v["grant_cpus"].int_value()),
            Int(v["grant_memory_mb"].int_value()),
            Int(v["grant_gpus"].int_value()) if String("grant_gpus") in v
            and v["grant_gpus"].is_int() else 0,
        ),
    )


def join_claim(
    mut db: State,
    worker: Int,
    placement: String,
    room_cpus: Int,
    room_mb: Int,
    used_cpus: Int,
    used_mb: Int,
    label: String,
    gpus: Int = 0,
    used_gpus: Int = 0,
) raises -> Optional[MemberSpec]:
    """A run for this worker to join, recorded as its member, or None: the
    oldest running run of the pool with its head known, fewer live members
    than its `workers`, none of them or its head this worker, whose request
    fits what this machine hasn't granted (`used_*`, of its `gpus`)."""
    var rows = cluster_db.joinable(db.conn, placement, worker)
    for c in rows:
        var ps = registered(db, c.pipeline)
        if len(ps) == 0:
            continue
        ref p = ps[0]
        var grant = Grant.none()
        var sized = run_request(db, p, room_cpus)
        var request = sized.request
        if request.memory_min_mb > 0:
            request.memory_min_mb = raised_request(
                request.memory_min_mb, request.memory_max_mb, p.memory_raised_mb
            )
        if request.any() and room_cpus >= 0:
            var fit = admit(
                request,
                Room(
                    room_cpus,
                    room_mb,
                    room_cpus,
                    room_mb,
                    gpus,
                    max(gpus - used_gpus, 0),
                ),
                used_cpus,
                used_mb,
                1,
                label,
            )
            if len(fit[0]) == 0:
                continue
            grant = fit[0][0]
        var got = cluster_db.add_member(
            db.conn,
            c.run,
            c.start,
            worker,
            grant.cpus,
            grant.memory_mb,
            grant.gpus,
        )
        if not got:
            continue
        return MemberSpec(
            got.value(),
            c.run,
            c.start,
            p.name,
            p.binary,
            c.head,
            c.token,
            p.env.copy(),
            p.secrets.copy(),
            grant,
        )
    return None


def stop_json(ids: List[Int]) -> String:
    var out = String("[")
    for i in range(len(ids)):
        out.write(", " if i else "", ids[i])
    out.write("]")
    return out^
