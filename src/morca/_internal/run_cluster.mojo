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
  pool whose head is known, that isn't already this worker's, and that
  wants a member this worker can serve. A run wants members with no group
  (its `workers`), sized as a run of the pipeline would be on that machine,
  and members of each of its groups (docs/groups.md), sized by the group's
  request and of the group's GPUs (`morca._internal.member_wants`): of each
  kind, what was last decided from its head's demand
  (`morca._internal.run_demand`), else its MIN. A
  member is counted against the machine's room with its runs, and kept in
  `orca.run_members` with its group. The worker starts a dista worker
  against the head, with the token (dista's `DISTA_TOKEN`: nothing without
  it joins) and, for a member of a group, `DISTA_GROUP`, and says when it
  ends (`/api/worker/left`, `member_left`).
- **Groups and GPUs.** Only a worker whose claim says it understands
  groups (`"groups": true`) is offered a member of one. A host with GPUs
  is offered the members that ask for GPUs first, and takes one that asks
  for none only when its run wants no member of a group it could serve
  and no other worker of the pool on a host without GPUs has room for it
  (`cluster_db.other_has_room`). The GPUs a claim says are free cap those
  offered, so a member still being stopped keeps its GPUs until reaped.
  A run with a group that asks for GPUs isn't started as its head by a
  host with GPUs while one without could start it (`head_elsewhere`): the
  head's host serves no group, so its GPUs would sit idle for the run.
- **Stopping.** Each claim's answer lists this worker's members whose run
  isn't running at that start any more (`members_to_stop`): the worker
  kills them, and they're ended "its run ended".

The token reaches a member only in a claim's answer, over the worker API's
TLS, and is never in a log or a page.
"""

from json import Value, loads
import morca._internal.db.run_cluster as cluster_db

from morca._internal.http_store import Body
from morca._internal.member_wants import (
    Want,
    group_request,
    groups_ask_gpus,
    gpu_host_takes,
    kinds_of,
    offer_order,
    wanted,
    wants_gpus_of,
)
from morca._internal.registered import Registered, registered, run_request
from morca._internal.cgroup import raised_request
from morca._internal.resources import Grant, Request, Room, admit
from morca._internal.state import State


def members_of(mut db: State, pipeline: String) raises -> Int:
    """How many more machines `pipeline`'s runs may spread over: its
    `workers` and each of its groups' MAX, when set for it; 0 (one
    machine) when none is. A run that may ever want a member starts its
    head, whatever its kinds want at first."""
    return cluster_db.spread(db.conn, pipeline)


def head_elsewhere(
    mut db: State,
    p: Registered,
    placement: String,
    worker: Int,
    run: Int,
    gpus: Int,
    request: Request,
) raises -> Bool:
    """Whether a worker on a host with `gpus` GPUs leaves queued `run` of
    `p` to another: when `p` has a group that asks for GPUs, and a worker
    of the pool on a host without GPUs could start it now
    (`cluster_db.other_has_room`, for `request`). The head's host serves
    no group, so the run couldn't use this host's GPUs."""
    if gpus <= 0 or not groups_ask_gpus(p.groups):
        return False
    return cluster_db.other_has_room(
        db.conn,
        placement,
        worker,
        run,
        -1,
        request.cpus_min,
        request.memory_min_mb,
        True,
    )


def say_gpu_head(p: Registered, run: Int, gpus: Int, name: String):
    """Logs it when a host with GPUs starts a run whose groups ask for
    them: no host without GPUs could, and the run's groups get none of
    this host's."""
    if gpus > 0 and groups_ask_gpus(p.groups):
        print(
            "morca: run",
            run,
            "of",
            p.name,
            "starts on",
            name if name else String("a worker"),
            "with",
            gpus,
            "GPUs, as no host of its pool without GPUs could: its groups",
            "that ask for GPUs can't use this host's",
        )


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
    var group: String
    """The group it serves (docs/groups.md), its dista worker's
    `DISTA_GROUP`; empty for none."""


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
        .text("group", m.group)
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
        v["group"].string_value() if String("group") in v
        and v["group"].is_string() else String(),
    )


@fieldwise_init
struct _Offer(Copyable, Movable):
    """A member a run wants, as `join_claim` offers it."""

    var row: Int
    """Its run, an index into `joinable`'s rows."""
    var pipeline: Int
    """Its pipeline, an index into the pipelines read."""
    var want: Want
    var run_wants_gpus: Bool
    """Its run wants a member that asks for GPUs this host has
    (`wants_gpus_of`)."""


def live_by_group(text: String) raises -> Dict[String, Int]:
    """`Joinable.live`'s (or `decided`'s) JSON object of counts, by
    group."""
    var out = Dict[String, Int]()
    if not text:
        return out^
    var v = loads(text)
    for k in v.object_keys():
        out[k] = Int(v[k].int_value())
    return out^


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
    understands_groups: Bool = False,
) raises -> Optional[MemberSpec]:
    """A run for this worker to join, recorded as its member, or None: of
    the running runs of the pool with their head known, none of them or
    their head this worker, a member one of them wants
    (`morca._internal.member_wants.wanted`) whose request fits what this
    machine hasn't granted (`used_*`, of its `gpus`). The oldest run's
    first, but on a host with GPUs the members that ask for GPUs first, and
    one that asks for none only if its run wants no member of a group this
    host could serve and no host without GPUs has room for it."""
    var rows = cluster_db.joinable(db.conn, placement, worker)
    var pipelines = List[Registered]()
    var offers = List[_Offer]()
    for i in range(len(rows)):
        ref c = rows[i]
        var ps = registered(db, c.pipeline)
        if len(ps) == 0:
            continue
        pipelines.append(ps[0].copy())
        var wants = wanted(
            kinds_of(
                c.min_workers,
                c.workers,
                ps[0].groups,
                live_by_group(c.decided),
                live_by_group(c.live),
                c.reports,
            ),
            understands_groups,
        )
        var gpus_wanted = wants_gpus_of(wants, gpus)
        for w in wants:
            offers.append(_Offer(i, len(pipelines) - 1, w.copy(), gpus_wanted))
    var asks = List[Int]()
    for o in offers:
        asks.append(o.want.gpus)
    for k in offer_order(asks, gpus):
        ref o = offers[k]
        ref c = rows[o.row]
        ref p = pipelines[o.pipeline]
        var request: Request
        if o.want.group:
            request = group_request(p.group(o.want.group))
        else:
            # The members with no group are sized as before groups.
            request = run_request(db, p, room_cpus).request
            if request.memory_min_mb > 0:
                request.memory_min_mb = raised_request(
                    request.memory_min_mb,
                    request.memory_max_mb,
                    p.memory_raised_mb,
                )
        if gpus > 0 and o.want.gpus == 0:
            var other = not o.run_wants_gpus and cluster_db.other_has_room(
                db.conn,
                placement,
                worker,
                c.run,
                c.start,
                request.cpus_min,
                request.memory_min_mb,
                o.want.group != "",
            )
            if not gpu_host_takes(gpus, 0, o.run_wants_gpus, other):
                continue
        var grant = Grant.none()
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
        elif request.gpus > 0:
            continue  # a worker that says nothing of its room has no GPUs
        var got = cluster_db.add_member(
            db.conn,
            c.run,
            c.start,
            worker,
            grant.cpus,
            grant.memory_mb,
            grant.gpus,
            o.want.group,
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
            o.want.group,
        )
    return None


def stop_json(ids: List[Int]) -> String:
    var out = String("[")
    for i in range(len(ids)):
        out.write(", " if i else "", ids[i])
    out.write("]")
    return out^
