"""How many members of one kind a pool run wants, from its head's demand
(docs/groups.md, "Demand per group"): the part of
`morca._internal.run_demand` that reads no database.

The worker that runs a run's head sends the head's status
(`dista status --json`) with its claims. For each kind of the run's members
(`morca._internal.member_wants.Kind`: the workers with no group, and each
group), the scheduler takes that kind's demand (`Demand.of`) and asks
dista's `decide`, with the kind's range as the policy's bounds and the
`MORCA_SCALE_*` knobs (`morca._internal.scale_policy`).

- **Units.** dista counts its workers; on a pool each member is one dista
  worker. The workers with no group also count the dista worker of the
  host that runs the head, which isn't a member: for them, dista's count is
  the members plus one (`own_workers`).
- **Pending.** Members wanted and not yet in the head's count (no host has
  joined yet, or one is still starting) are `decide`'s pending workers, so
  a slow join isn't asked for twice.
- **The count.** What the kind wants is the workers the decision leaves
  (those there and pending, plus those it starts, less those it would
  drain), less the head's own, within the kind's range. Nothing drains a
  member yet: a kind with more live members than that only gets no new
  ones.
- **State.** `decide` remembers since when a kind has been short of
  workers (`short_since`), which the scheduler keeps on
  `orca.run_wants` beside the count. A decision older than
  `DEMAND_STALE_SECONDS` is a stale memory: its `short_since` is dropped,
  and the next answer waits `MORCA_SCALE_UP_AFTER` again before growing.
"""

from dista.scale import Demand, decide

from morca._internal.scale_policy import ScaleKnobs

comptime DEMAND_STALE_SECONDS = 60.0
"""How old a kind's last decision may be for its `short_since` to count."""


def own_workers(group: String) -> Int:
    """The dista workers of a kind that aren't members: the head's host's
    own, for the workers with no group; none for a group."""
    return 0 if group else 1


@fieldwise_init
struct Decided(Copyable, Movable):
    """A kind's decision: how many members it wants, and `decide`'s memory
    for the next one."""

    var wanted: Int
    var short_since: Float64


@fieldwise_init
struct Prior(Copyable, Movable):
    """A kind's last decision, as kept on `orca.run_wants`."""

    var wanted: Int
    var short_since: Float64
    var at: Float64
    """When it was decided, in seconds on the same clock as `now`."""


def decide_kind(
    demand: Demand,
    group: String,
    lo: Int,
    hi: Int,
    knobs: ScaleKnobs,
    now: Float64,
    prior: Optional[Prior],
) -> Decided:
    """How many members of kind `group` ("" for the workers with no group),
    of range `lo`..`hi`, the run wants now, from its head's `demand`, at
    `now` (seconds), after its `prior` decision (none before the first:
    then it wants `lo`)."""
    var own = own_workers(group)
    var d = demand.of(group)
    var before = lo
    var since = 0.0
    if prior:
        ref p = prior.value()
        before = min(max(p.wanted, lo), max(hi, lo))
        if now - p.at <= DEMAND_STALE_SECONDS:
            since = p.short_since
    var live = d.live()
    var pending = max(before + own - live, 0)
    var got = decide(
        d, knobs.policy(lo + own, max(hi, lo) + own), now, pending, since
    )
    var workers = live + pending + got.start - len(got.drain)
    return Decided(min(max(workers - own, lo), max(hi, lo)), got.short_since)
