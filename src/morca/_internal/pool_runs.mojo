"""The scheduler's part in a worker pool (`orca.workers`): due retries and
dead runs queued again for a worker, lost workers' runs, orphans of gone
instances, and fill runs queued for the pool.
"""

from postgres import Transaction
from morca._internal.db.batches import mark_batch
from morca._internal.fill import fill_status
from morca._internal.fill_requests import end_finished
import morca._internal.db.audit as audit_db
import morca._internal.db.pool_runs as pool_runs_db
import morca._internal.db.starting as starting_db
from morca._internal.db.live import hold_behind
from morca._internal.scheduler import (
    Scheduler,
    _WORKER_OWNER,
)
from morca._internal.registered import (
    Registered,
    fill_pipeline,
)


def _requeue_for_workers(
    mut self: Scheduler, p: Registered, now: Int64, pool: String
) raises:
    """What `_start` does for a pipeline placed `worker:<pool>`, whose
    runs a worker of the pool claims (`orca.workers`): queues again
    the runs of a worker that's gone (`_requeue_lost`), whatever their
    trigger; ends the runs that can't go on as for any pipeline; and
    queues again, for a worker to claim, the retries and deferred runs
    that are due and the runs whose process died with retries left.
    Its queued runs say they wait for a worker (its fill runs, while
    fills are off, that they wait for fills)."""
    var dead = self._dead("$2")
    var waiting = String("held: waiting for a worker of pool ", pool)
    var tx = self.db.conn.begin()
    starting_db.lock_pipeline(tx, p.name)
    starting_db.lock_runs(tx, p.name)
    var lost = _requeue_lost(self, tx, p, dead, waiting)
    self._end_dead(tx, p, dead)
    # One behind an older live run of its keys says which; a worker
    # doesn't claim it until that run ends.
    hold_behind(tx, p.name, waiting)
    if not p.fill.all:
        pool_runs_db.hold_fills(
            tx,
            p.name,
            (
                'held: fills are off (fills isn\'t "all"), so no worker'
                " is given it"
            ),
        )
    var n = pool_runs_db.requeue_due(
        tx, p.name, self.stale, p.run_retries, now, waiting, dead
    )
    pool_runs_db.hold_unheld(tx, p.name, waiting)
    tx.commit()
    _say_lost(p, pool, lost)
    if n > 0:
        print("requeued", n, "runs of", p.name, "for pool", pool)


def _say_lost(
    p: Registered, pool: String, lost: List[Tuple[Int, String]]
) raises:
    """Prints each run `_requeue_lost` queued again, with why."""
    for l in lost:
        print(
            String("requeued run ", l[0], " of ", p.name, " for pool ", pool),
            ": ",
            l[1],
            sep="",
        )


def _requeue_lost(
    mut self: Scheduler,
    mut tx: Transaction,
    p: Registered,
    dead: String,
    waiting: String,
) raises -> List[Tuple[Int, String]]:
    """Queues again, for the pool, `p`'s runs whose worker is gone,
    whatever their trigger (a manual, UI or rerun run too, which a dead
    process would fail): a running run whose worker hasn't been seen
    for half the stale limit (killed, or its machine asleep or off the
    network), or whose process died while the worker, seen since,
    doesn't say it has it (restarted). Nothing ran it past its last
    step, so its next start resumes it. A run the worker claimed but
    never started has its start given back; one that started counts
    it, and once `starts - deferrals` is past `run_retries` it is left
    to `_end_dead`, so a run that kills its workers can't loop. Each is
    a row of `orca.audit` (user `scheduler`, action
    `/api/worker/requeue`); returns each run with why."""
    var out = List[Tuple[Int, String]]()
    for r in pool_runs_db.requeue_lost(
        tx,
        p.name,
        self.stale,
        self.start_grace,
        p.run_retries,
        waiting,
        _WORKER_OWNER,
    ):
        var why = r.why
        if r.unstarted:
            why.write(", before starting it")
        out.append((r.run, why))
        audit_db.add(
            tx,
            "scheduler",
            "/api/worker/requeue",
            r.run,
            String("queued again: ", why),
            "scheduler",
        )
    return out^


def _requeue_orphans(
    mut self: Scheduler, mut tx: Transaction, p: Registered
) raises -> List[Tuple[Int, String]]:
    """Queues again `p`'s local and control-placed runs whose scheduler
    instance (`runs.instance`, docs/overlap.md) is gone (ended, or not
    seen for the stale limit) and whose heartbeat is stale,
    whatever their trigger: the deploy, or a crash, stopped them, not
    their own code. Nothing ran them past their last step, so the next
    start resumes them. The start counts, and once `starts - deferrals`
    is past `run_retries` a run is left to `_end_dead`, so a run that
    kills its scheduler can't loop. Each is a row of `orca.audit` (user
    `scheduler`, action `/api/scheduler/requeue`); returns each with
    why."""
    var out = List[Tuple[Int, String]]()
    for r in pool_runs_db.requeue_orphans(
        tx, p.name, self.stale, self.start_grace, p.run_retries
    ):
        out.append((r.run, r.why))
        audit_db.add(
            tx,
            "scheduler",
            "/api/scheduler/requeue",
            r.run,
            String("queued again: ", r.why),
            "scheduler",
        )
    return out^


def _fill_for_workers(
    mut self: Scheduler, p: Registered, now: Int64, pool: String
) raises:
    """`_start`'s fill pass for a pipeline placed `worker:<pool>`: as
    for a local one, but what may start is queued for a worker of the
    pool to claim rather than started. Within `morca._internal.fill.fill_status`'s
    slots (`fill_max_runs` less its fill runs running or queued, so the
    cap holds across the whole pool), the due retries, deferred runs
    and fill runs whose process died with retries left are queued
    again first, then new fill runs over the partitions nothing has
    filled, in `fill_order`."""
    var dead = self._dead("$2")
    var waiting = String("held: waiting for a worker of pool ", pool)
    var tx = self.db.conn.begin()
    starting_db.lock_pipeline(tx, p.name)
    starting_db.lock_runs(tx, p.name)
    # A gone worker's fill runs first, as the other pass does, so they
    # are queued again with why (and an audit row), not as merely dead:
    # the tick's passes run a moment apart, and either may see them first.
    var lost = _requeue_lost(self, tx, p, dead, waiting)
    var status = fill_status(tx, fill_pipeline(p), now, p.run_retries)
    end_finished(tx, status.request)
    var free = status.slots
    var again = 0
    if free > 0:
        again = pool_runs_db.requeue_fills(
            tx, p.name, self.stale, p.run_retries, now, waiting, free, dead
        )
    var ids = List[Int64]()
    ref next = status.next_keys
    for i in range(min(free - again, len(next))):
        ids.append(
            pool_runs_db.queue_fill(
                tx,
                p.name,
                p.registry_hash,
                next[i],
                waiting,
                status.next_request[i],
            )
        )
    mark_batch(tx, ids)
    tx.commit()
    _say_lost(p, pool, lost)
    if again > 0:
        print("requeued", again, "fill runs of", p.name, "for pool", pool)
    for i in range(len(ids)):
        print("fill", p.name, next[i], "run", ids[i], "for pool", pool)
