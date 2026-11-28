"""Demand per group on pools (docs/groups.md), the scheduler's side: the
head's status a worker sends with its claim, kept on the run, and what each
kind of the run's members wants decided from it.

The worker that runs a pool run's head asks it for its status
(`morca._internal.worker_demand`) and sends it in its claim's `demand`
list: `[{"run": 7, "start": 1, "status": "<dista status --json>"}]`. Each
answer for a run that is running at that start on that worker, with its
head known, is kept on the run (`orca.runs.demand`, `demand_at`); one for
any other run is ignored. Then, once per answer, each kind of the run's
members (the workers with no group, when its `workers` is set, and each of
its groups) is decided anew (`morca._internal.member_demand.decide_kind`)
and kept on `orca.run_wants`, where `join_claim` and the pool's demand read
it. A bad answer is skipped, never the claim.
"""

from dista.scale import Demand
from json import Value
import morca._internal.db.run_cluster as cluster_db

from morca._internal.groups import parse_groups
from morca._internal.member_demand import Prior, decide_kind
from morca._internal.scale_policy import ScaleKnobs
from morca._internal.state import State


def _prior(rows: List[cluster_db.WantRow], group: String) -> Optional[Prior]:
    for r in rows:
        if r.group == group:
            return Prior(r.wanted, r.short_since, r.at)
    return None


def decide_run(
    mut db: State,
    run: Int,
    start: Int,
    demand: Demand,
    kept: cluster_db.KeptDemand,
    knobs: ScaleKnobs,
) raises:
    """Decides and keeps what each kind of `run`'s members wants at `start`
    from its head's `demand`."""
    var rows = cluster_db.wants_of(db.conn, run, start)
    var kinds = List[Tuple[String, Int, Int]]()
    if kept.hi > 0:
        kinds.append((String(), kept.lo, kept.hi))
    for g in parse_groups(kept.groups):
        kinds.append((g.name, g.min_workers, g.max_workers))
    for k in kinds:
        var got = decide_kind(
            demand, k[0], k[1], k[2], knobs, kept.now, _prior(rows, k[0])
        )
        cluster_db.set_want(
            db.conn, run, start, k[0], got.wanted, got.short_since
        )


def record_demand(mut db: State, worker: Int, v: Value) raises -> Int:
    """A claim's `demand` (see above) from `worker`: each answer kept and
    decided on; returns how many were."""
    if String("demand") not in v or not v["demand"].is_array():
        return 0
    var knobs = ScaleKnobs.from_env()
    var n = 0
    for d in v["demand"].array_items():
        var run = 0
        try:
            run = Int(d["run"].int_value())
            var start = Int(d["start"].int_value())
            var status = d["status"].string_value()
            var demand = Demand.parse(status)
            var kept = cluster_db.keep_demand(
                db.conn, run, start, worker, status
            )
            if not kept:
                continue
            decide_run(db, run, start, demand, kept.value(), knobs)
            n += 1
        except e:
            print("morca: run", run, "demand from its head skipped:", e)
    return n
