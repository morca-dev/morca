"""Which members a running run of a pool wants, by group, and which a host
is offered first (docs/groups.md, "Members by group"): the part of
`morca._internal.run_cluster.join_claim` that reads no database.

- **The workers with no group** (`workers`, stored as `ec2_workers`) want
  that many members, counted against the run's live members with no group,
  as before groups.
- **Each group** wants its MAX (`Group.max_workers`), counted against its
  own live members, each sized by the group's request (`group_request`).
  MIN is honoured once demand per group lands (PR 4 of docs/groups.md).
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


def wanted(
    workers: Int,
    groups: List[Group],
    live: Dict[String, Int],
    understands_groups: Bool,
) -> List[Want]:
    """What a run wants that it hasn't got: `workers` members with no
    group, and each group's MAX, less the run's live members of each
    (`live`, by group, "" for none). Only the members with no group for a
    worker that doesn't understand groups. The workers with no group first,
    then the groups by name; none that is full."""
    var out = List[Want]()
    var plain = workers - live.get("", 0)
    if plain > 0:
        out.append(Want("", 0, plain))
    if not understands_groups:
        return out^
    for g in groups:
        var short = g.max_workers - live.get(g.name, 0)
        if short > 0:
            out.append(Want(g.name, g.gpus, short))
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
