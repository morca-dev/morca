"""What `morca ui` does to runs: each action is rows in Postgres that the
scheduler, or the run's own process, acts on.

The UI never starts a pipeline's binary. Starting, resuming, rerunning and
backfilling leave a `queued` run, which the scheduler starts on its next
tick as it starts any other, within `max_runs`; cancelling sets
`cancel_requested`, which a running run sees before its next attempt; an
attempt still going `MORCA_CANCEL_KILL_SECONDS` (60) later is stopped, its
process exiting (`morca._internal.heartbeat`). Pausing a pipeline sets
`pipelines.paused`, and the scheduler starts none of its runs until it's
unpaused. So the UI works the same wherever the
scheduler runs, and retries and limits stay in one place.

Each action returns an `Outcome`: the run it made or acted on, or why it
refused, which is something the person can fix (a bad range, a run that's
still going) rather than an error.
"""

from std.os import getenv

import morca._internal.db.actions as actions_db
import morca._internal.db.starting as starting_db
from morca._internal.db.live import live_runs
from morca.name import parse_names
from morca._internal.pause import set_paused
from morca._internal.queueing import (
    ALLOW_APPEND_HOW,
    append_again,
    appending_writes,
    backfill,
    partition_keys,
    rerun_refusal,
)
from morca._internal.registered import (
    Registered,
    registered,
)
from morca._internal.sensors import rebuild
from morca._internal.state import State
from morca._internal.timekeys import parse_time_keys


@fieldwise_init
struct Outcome(Movable):
    var run: Int
    """The run made or acted on; 0 when refused, or for a backfill."""
    var queued: Int
    """How many runs a backfill queued, or a bulk cancel cancelled."""
    var refused: String
    """Why the action wasn't done, or empty."""
    var confirm: Bool
    """Refused only until confirmed: a resume onto new code."""
    var skipped: List[String]
    """Why a backfill left keys, a line per reason (`Queued.skipped`)."""

    @staticmethod
    def done(run: Int, queued: Int = 0) -> Self:
        return Self(run, queued, "", False, List[String]())

    @staticmethod
    def no(var why: String, confirm: Bool = False) -> Self:
        return Self(0, 0, why^, confirm, List[String]())


def cancel_kill_seconds() -> Float64:
    """`MORCA_CANCEL_KILL_SECONDS` (default 60): how long a running run
    asked to cancel has to finish its step before it's stopped."""
    try:
        return Float64(getenv("MORCA_CANCEL_KILL_SECONDS", "60"))
    except:
        return 60.0


def _pipeline(mut db: State, name: String) raises -> Optional[Registered]:
    var ps = registered(db, name)
    if len(ps) == 0:
        return None
    return ps[0].copy()


def start_run(
    mut db: State, pipeline: String, keys: String, trigger: String = "ui"
) raises -> Outcome:
    """A queued run over the partitions in `keys`, with `trigger`: `ui` from
    the Start runs form, `cli` from `morca start`. Refused
    while a live run has one of them, which a second run would run beside;
    a partition that's done is run again."""
    var p = _pipeline(db, pipeline)
    guard case .Some(reg) = p else:
        return Outcome.no(_unregistered(pipeline))
    var texts: List[String]
    try:
        texts = partition_keys(reg, keys)
    except e:
        return Outcome.no(String(e))
    if len(texts) == 0:
        return Outcome.no("no partitions to run")
    var joined = String()
    for i in range(len(texts)):
        joined.write("," if i else "", texts[i])
    var tx = db.conn.begin()
    starting_db.lock_pipeline(tx, pipeline)
    var live = live_runs(tx, pipeline)
    for k in texts:
        var run = live.get(k)
        if run:
            tx.commit()
            return Outcome.no(
                String(
                    k,
                    " is in run ",
                    run.value(),
                    ", which is queued or running; wait for it to end, or",
                    " cancel it",
                )
            )
    var id = actions_db.add_started_run(
        tx, pipeline, reg.registry_hash, joined, trigger
    )
    tx.commit()
    return Outcome.done(Int(id))


def backfill_runs(
    mut db: State,
    pipeline: String,
    keys: String,
    rerun: Bool = False,
    allow_append: Bool = False,
) raises -> Outcome:
    """What `morca backfill` does: queued runs, `keys_per_run` keys each, of
    the keys in `keys` that aren't done and aren't in a live run; for time
    keys, by default a run for each partition in `keys`
    that has none queued, running or succeeded. With `rerun`, done keys are
    queued too: refused until `allow_append` confirms it if the pipeline's
    steps append to what they write (`rerun_refusal`)."""
    var p = _pipeline(db, pipeline)
    guard case .Some(reg) = p else:
        return Outcome.no(_unregistered(pipeline))
    try:
        if rerun and not allow_append:
            var why = rerun_refusal(db, reg, keys)
            if why:
                return Outcome.no(why^, confirm=True)
        var q = backfill(db, reg, keys, rerun, True)
        var o = Outcome.done(0, len(q.runs))
        o.skipped = q.skipped()
        return o^
    except e:
        return Outcome.no(String(e))


def resume_run(mut db: State, run: Int, allow_new_code: Bool) raises -> Outcome:
    """Queues a failed, cancelled, deferred or stalled run again, so the
    scheduler resumes it at what's unfinished (a deferred one now rather
    than when it asked). A run whose pipeline's code has changed
    since is refused until `allow_new_code`, which the scheduler passes on
    as `--allow-new-code`."""
    var got = actions_db.resumable(db.conn, run)
    guard case .Some(r) = got else:
        return Outcome.no(String("no run ", run))
    var status = r.status
    if (
        status != "failed"
        and status != "cancelled"
        and status != "deferred"
        and not r.stalled
    ):
        return Outcome.no(
            String(
                "run ",
                run,
                " is ",
                status,
                (
                    "; only a failed, cancelled, deferred or stalled run can be"
                    " resumed"
                ),
            )
        )
    if not r.has_binary:
        return Outcome.no(_unregistered(r.pipeline))
    if r.registry_hash != r.current and not allow_new_code:
        return Outcome.no(
            String(
                "run ",
                run,
                " ran code ",
                r.registry_hash,
                ", and the pipeline's binary is now ",
                r.current,
                ". Resuming runs the new code on the steps that haven't",
                " succeeded, over the outputs of the old code's that have.",
            ),
            confirm=True,
        )
    var n = actions_db.requeue(db.conn, run, allow_new_code)
    if n != 1:
        return Outcome.no(String("run ", run, " changed; look again"))
    return Outcome.done(run)


def rerun_from(
    mut db: State, run: Int, step: String, allow_append: Bool = False
) raises -> Outcome:
    """A new queued run over the same partitions, trigger `rerun`, with the
    steps before `step` that succeeded copied from `run` (their outputs, and
    `copied_from` naming the step they came from, whose attempts, reads and
    commits stay with it). Resuming it runs `step` and what follows. `run`
    is left as it was.

    Refused until `allow_append` confirms it if `step` or one after it
    appends to a dataset (`appending_writes`): the new run would append
    again beside what `run` committed."""
    var got = actions_db.rerunnable(db.conn, run, step)
    guard case .Some(r) = got else:
        return Outcome.no(String("no run ", run))
    var pipeline = r.pipeline
    var status = r.status
    if status == "queued" or status == "running":
        return Outcome.no(
            String("run ", run, " is ", status, "; rerun it once it has ended")
        )
    if r.ord < 0:
        return Outcome.no(String("pipeline ", pipeline, " has no step ", step))
    var ord = r.ord
    if not _pipeline(db, pipeline):
        return Outcome.no(_unregistered(pipeline))
    if not allow_append:
        var writes = appending_writes(db, pipeline, Int(ord))
        if len(writes) > 0:
            return Outcome.no(
                append_again(
                    pipeline,
                    String("run ", run, " from step ", step),
                    writes,
                    ALLOW_APPEND_HOW,
                ),
                confirm=True,
            )
    if ord > 0 and r.registry_hash != r.current:
        return Outcome.no(
            String(
                "run ",
                run,
                " ran code ",
                r.registry_hash,
                ", and the pipeline's binary is now ",
                r.current,
                "; its outputs may not be what the new code reads, so rerun",
                " it from the first step",
            )
        )
    var tx = db.conn.begin()
    var id = actions_db.add_rerun(tx, pipeline, r.current, r.partitions)
    actions_db.copy_steps(tx, run, id, ord)
    tx.commit()
    return Outcome.done(Int(id))


def cancel_run(mut db: State, run: Int) raises -> Outcome:
    """Cancels a run: a queued, deferred or failed one at once (it isn't
    started again), a running one before its next attempt, or, if its step
    is still going `MORCA_CANCEL_KILL_SECONDS` later, by stopping its process
    (`morca._internal.heartbeat`)."""
    if actions_db.cancel(db.conn, run, cancel_kill_seconds()):
        return Outcome.done(run)
    var st = actions_db.status_of(db.conn, run)
    if not st:
        return Outcome.no(String("no run ", run))
    return Outcome.no(String("run ", run, " is ", st.value(), " already"))


def cancel_runs(
    mut db: State, pipeline: String, keys: String
) raises -> Outcome:
    """What `morca cancel` does: cancels, as `cancel_run` does each, the
    pipeline's runs that are queued, deferred, running, or failed and due
    to be retried, over any of `keys` (a run of several keys is cancelled whole),
    or all of them for `@all`. The outcome's `queued` is how many."""
    var got = actions_db.partitioning(db.conn, pipeline)
    guard case .Some(part) = got else:
        return Outcome.no(String("no pipeline ", pipeline))
    var kind = part.kind
    var start = part.start
    var retries = part.run_retries
    var all = keys.strip() == "@all"
    var joined = String()
    if not all:
        try:
            if kind == "keyed":
                for n in parse_names(keys):
                    joined.write("," if joined else "", n)
            else:
                for k in parse_time_keys(kind, keys, start):
                    joined.write("," if joined else "", k)
        except e:
            return Outcome.no(String(e))
    var done = actions_db.cancel_over(
        db.conn, pipeline, all, joined, retries, cancel_kill_seconds()
    )
    return Outcome.done(0, done)


def pause_pipeline(
    mut db: State, pipeline: String, paused: Bool
) raises -> Outcome:
    """What `morca pause` (or, with `paused` false, `morca unpause`) does:
    while a pipeline is paused the scheduler starts none of its runs. Fires,
    sensors, retries and backfills still queue theirs, which start once
    it's unpaused; runs already going go on."""
    var why = set_paused(db, pipeline, paused)
    if why:
        return Outcome.no(why^)
    return Outcome.done(0)


def rebuild_downstream(
    mut db: State, dataset: String, keys: String
) raises -> Outcome:
    """What `morca rebuild` does: plans runs of every pipeline downstream of
    `dataset` over `keys`, which the scheduler queues a level at a time.
    The outcome's `run` is the rebuild's ID."""
    try:
        return Outcome.done(rebuild(db, dataset, keys))
    except e:
        return Outcome.no(String(e))


def _unregistered(pipeline: String) -> String:
    return String(
        "pipeline ",
        pipeline,
        " isn't registered with a binary (morca register), so the scheduler",
        " can't start its runs",
    )


# ── in bulk, from a runs list ───────────────────────────────────────────────


@fieldwise_init
struct Bulk(Movable):
    """What an action on runs picked from a list did (`morca._internal.api.actions.bulk`).
    """

    var done: List[Int]
    """The runs it acted on: cancelled (or asked to stop), queued again, or
    whose partitions were backfilled."""
    var skipped: List[Int]
    """The runs it left as they were: ended already, or not failed."""
    var refused: List[Tuple[Int, String]]
    """Runs (or, as 0, a pipeline's) it couldn't act on, and why."""
    var queued: Int
    """The runs a backfill queued."""
    var confirm: String
    """Why a backfill waits to be confirmed (its steps append), or empty;
    nothing was done then."""
    var pipelines: List[Tuple[String, String]]
    """Each pipeline a backfill queued runs of, and its partitions."""

    @staticmethod
    def none() -> Self:
        return Self(
            List[Int](),
            List[Int](),
            List[Tuple[Int, String]](),
            0,
            String(),
            List[Tuple[String, String]](),
        )


def _id_list(runs: List[Int]) -> String:
    """`runs` as `1,2,3`, for `string_to_array($n, ',')::bigint[]`."""
    var ids = String()
    for r in runs:
        ids.write("," if ids else "", r)
    return ids^


def cancel_runs_picked(mut db: State, runs: List[Int]) raises -> Bulk:
    """Cancels, as `cancel_run` does each, those of `runs` that are queued,
    deferred or running (and not already stopping); the others are left as
    they are, and skipped."""
    var b = Bulk.none()
    if len(runs) == 0:
        return b^
    b.done = actions_db.cancel_picked(
        db.conn, _id_list(runs), cancel_kill_seconds()
    )
    for id in runs:
        if id not in b.done and id not in b.skipped:
            b.skipped.append(id)
    return b^


def resume_failed(mut db: State, runs: List[Int]) raises -> Bulk:
    """Queues again, as `resume_run` does each (Resume on a runs list), those
    of `runs` that failed or stalled. One whose pipeline's code has changed
    since is refused, to be resumed from its page; the others are skipped."""
    var b = Bulk.none()
    if len(runs) == 0:
        return b^
    var failed = actions_db.failed_or_stalled(db.conn, _id_list(runs))
    for id in runs:
        if id not in failed:
            if id not in b.skipped:
                b.skipped.append(id)
            continue
        var o = resume_run(db, id, False)
        if o.refused:
            b.refused.append((id, o.refused))
        else:
            b.done.append(id)
    return b^


def backfill_picked(
    mut db: State, runs: List[Int], allow_append: Bool
) raises -> Bulk:
    """What `morca backfill --rerun` does, over the partitions of `runs`, a
    backfill per pipeline: a queued run for each of them that isn't in a
    live run. If a pipeline's steps append to what they write, nothing is
    done until `allow_append` confirms it (`confirm` says why)."""
    var b = Bulk.none()
    if len(runs) == 0:
        return b^
    # Each pipeline's partitions, in the order of its runs, each once.
    var names = List[String]()
    var keys = List[List[String]]()
    var of = List[List[Int]]()
    for r in actions_db.runs_keys(db.conn, _id_list(runs)):
        var name = r.pipeline
        var i = -1
        for j in range(len(names)):
            if names[j] == name:
                i = j
        if i < 0:
            names.append(name)
            keys.append(List[String]())
            of.append(List[Int]())
            i = len(names) - 1
        of[i].append(r.id)
        for k in r.partitions.split(","):
            var key = String(k.strip())
            if key and key not in keys[i]:
                keys[i].append(key^)
    for id in runs:
        var seen = False
        for ids in of:
            if id in ids:
                seen = True
        if not seen and id not in b.skipped:
            b.skipped.append(id)
    # Every pipeline checked before any is backfilled, so a confirmation
    # asked for does all of them or none.
    var joined = List[String]()
    for i in range(len(names)):
        joined.append(String(",").join(keys[i]))
        var p = _pipeline(db, names[i])
        if not p:
            continue
        if not allow_append:
            try:
                var why = rerun_refusal(db, p.value(), joined[i])
                if why:
                    b.confirm = why^
                    return b^
            except e:
                pass
    for i in range(len(names)):
        if len(keys[i]) == 0:
            for id in of[i]:
                b.skipped.append(id)
            continue
        var o = backfill_runs(
            db, names[i], joined[i], rerun=True, allow_append=True
        )
        if o.refused:
            b.refused.append((0, String(names[i], ": ", o.refused)))
            continue
        b.queued += o.queued
        b.pipelines.append((names[i], joined[i]))
        for id in of[i]:
            b.done.append(id)
    return b^
