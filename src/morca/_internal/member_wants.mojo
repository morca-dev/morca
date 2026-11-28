"""Which members a running run of a pool wants, by group, and which a host
is offered first (docs/groups.md, "Members by group" and "Demand per
group"): the part of `morca._internal.run_cluster.join_claim` that reads no
database.

- **Kinds.** A run's members come in kinds: the workers with no group
  (`workers`, stored as `ec2_min_workers`..`ec2_workers`), and each of its
  groups (`Group.min_workers`..`max_workers`). Each kind wants a count in
  its range, counted against its own live members (`kinds_of`).
- **What a kind wants** is what the scheduler last decided from the run's
  head's demand (`morca._internal.member_demand`), within its range; before
  the first decision of the run's start, its MIN (`kind_wanted`). A fixed
  count has MIN = MAX, so it wants that count from the start. A kind with
  more live members than it wants is given none; none is stopped yet.
- **A worker that doesn't understand groups** (its claim doesn't say
  `"groups": true`) is offered only members with no group.
- **A host with GPUs** is offered the members that ask for GPUs first
  (`offer_order`). It takes one that asks for none only when no host
  without GPUs has room for it (`gpu_host_takes`), so a member that needs
  no GPU doesn't take the place a model needs; and never of a run that
  still wants a member of a group it could serve (`wants_gpus_of`): a host
  is one member of a run at most, so that one would keep it from the
  group for the rest of the run.
"""

from morca._internal.groups import Group
from morca._internal.recommend import Recommendation, resolve_request
from morca._internal.resources import Request


@fieldwise_init
struct Want(Copyable, Movable):
    """Members a run wants and hasn't got, of one group."""

    var group: String
    """The group's name; empty for the workers with no group."""
    var gpus: Int
    """The GPUs each of its members asks for."""
    var short: Int
    """How many more members it wants, from 1."""


@fieldwise_init
struct Kind(Copyable, Movable):
    """One kind of a run's members: the workers with no group, or a group."""

    var group: String
    """The group's name; empty for the workers with no group."""
    var gpus: Int
    """The GPUs each of its members asks for."""
    var min_workers: Int
    var max_workers: Int
    var wanted: Int
    """How many members it wants now (`kind_wanted`)."""
    var decided: Bool
    """Whether `wanted` was decided from the head's demand, rather than
    the MIN a run starts with."""
    var live: Int
    """Its live members."""


def kind_wanted(lo: Int, hi: Int, decided: Optional[Int]) -> Int:
    """What a kind of range `lo`..`hi` wants now: the count last `decided`
    from its run's demand, kept within the range (re-registering may have
    moved it), or `lo` before any decision."""
    var n = decided.value() if decided else lo
    return min(max(n, lo), max(hi, lo))


def kinds_of(
    lo: Int,
    hi: Int,
    groups: List[Group],
    decided: Dict[String, Int],
    live: Dict[String, Int],
) -> List[Kind]:
    """A run's kinds: the workers with no group, `lo`..`hi` (none when
    `hi` is 0), then each of `groups` in order. `decided` and `live` are by
    group, "" for none."""
    var out = List[Kind]()
    if hi > 0:
        var d = decided.get("")
        out.append(
            Kind(
                "", 0, lo, hi, kind_wanted(lo, hi, d), Bool(d), live.get("", 0)
            )
        )
    for g in groups:
        var d = decided.get(g.name)
        out.append(
            Kind(
                g.name,
                g.gpus,
                g.min_workers,
                g.max_workers,
                kind_wanted(g.min_workers, g.max_workers, d),
                Bool(d),
                live.get(g.name, 0),
            )
        )
    return out^


def wanted(kinds: List[Kind], understands_groups: Bool) -> List[Want]:
    """What a run wants that it hasn't got: each kind's wanted count less
    its live members, in `kinds`' order; only the members with no group for
    a worker that doesn't understand groups; none that is full."""
    var out = List[Want]()
    for k in kinds:
        if k.group and not understands_groups:
            continue
        var short = k.wanted - k.live
        if short > 0:
            out.append(Want(k.group, k.gpus, short))
    return out^


def offer_order(gpus: List[Int], host_gpus: Int) -> List[Int]:
    """The order to offer a host the wants that ask for `gpus` each (their
    indexes, oldest run first): on a host with GPUs (`host_gpus`), those
    that ask for GPUs first, each part in its order; elsewhere as they
    are."""
    var out = List[Int]()
    if host_gpus > 0:
        for i in range(len(gpus)):
            if gpus[i] > 0:
                out.append(i)
    for i in range(len(gpus)):
        if host_gpus <= 0 or gpus[i] <= 0:
            out.append(i)
    return out^


def groups_ask_gpus(groups: List[Group]) -> Bool:
    """Whether one of `groups` asks for GPUs."""
    for g in groups:
        if g.gpus > 0:
            return True
    return False


def wants_gpus_of(wants: List[Want], host_gpus: Int) -> Bool:
    """Whether a run's `wants` (`wanted`'s) have a member that asks for
    GPUs, no more than a host's `host_gpus`."""
    for w in wants:
        if w.gpus > 0 and w.gpus <= host_gpus:
            return True
    return False


def gpu_host_takes(
    host_gpus: Int,
    want_gpus: Int,
    run_wants_its_gpus: Bool,
    other_host_has_room: Bool,
) -> Bool:
    """Whether a host with `host_gpus` GPUs takes a member that asks for
    `want_gpus`: always on a host without GPUs, or for a member that asks
    for some (admission then checks they're free). On a host with GPUs, a
    member that asks for none only if its run doesn't want a member that
    asks for GPUs this host has (`run_wants_its_gpus`, `wants_gpus_of`),
    and no host without GPUs has room for it. `offer_order` has already
    offered it every member that asks for GPUs, so none it could serve now
    is left."""
    if host_gpus <= 0 or want_gpus > 0:
        return True
    return not run_wants_its_gpus and not other_host_has_room


def group_request(g: Group) raises -> Request:
    """A member's request for group `g` (`Registered.group`'s, with the
    pipeline's fallbacks): its CPUs and memory as declared, `auto` not
    asked for (a group's members learn nothing yet), and its GPUs."""
    var r = resolve_request(g.request(), Recommendation.none(), False).request
    r.gpus = g.gpus
    return r
