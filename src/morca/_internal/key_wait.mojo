"""A start's part in concurrency keys (`morca._internal.concurrency`, #397):
how many more runs a key has room for, and, for the scheduler, its queued
runs saying which run they wait on and failing once they have waited the
wait limit on one of an older version.

The scheduler's pass (`morca._internal.starting`, and for a worker pool
`morca._internal.pool_runs`) and a worker's claim (`morca._internal.workers`)
call `key_room` in the transaction that starts the run, after the
pipeline's row lock and before the locks across pipelines (the host's, the
control slots', the budget's), so the lock on the key is always taken in
the same order.
"""

from postgres import Connection, Transaction

import morca._internal.db.concurrency as concurrency_db
from morca._internal.concurrency import WAIT_ENV, wait_limit


comptime KEY_WAITING = "waiting: for concurrency key "
"""How a queued run's `held` starts while it waits on a key."""


struct KeyRoom(Movable):
    """What `key_room` found."""

    var room: Int
    """How many more runs may hold the key now."""
    var hold: String
    """Why its queued runs wait, when there's no room."""
    var timed_out: List[Int]
    """The runs that failed for waiting too long."""
    var error: String
    """The timed-out runs' error."""

    def __init__(out self, room: Int):
        self.room = room
        self.hold = String()
        self.timed_out = List[Int]()
        self.error = String()


def _version(v: String) -> String:
    return v if v else String("unknown")


def key_room(
    mut tx: Transaction,
    pipeline: String,
    key: String,
    limit: Int,
    stale: Float64,
    dead: String,
    which: Int,
    say: Bool,
    after: String = "",
) raises -> KeyRoom:
    """Locks `key` and counts its live holders (`dead`, with the stale limit
    `$2`): the room `limit` leaves. With `say` (the scheduler), `pipeline`'s
    queued runs (of `which`, `morca._internal.db.concurrency`) say which run
    they wait on when there's none, and those that have waited on a run of
    an older version for `MORCA_HANDOVER_WAIT_SECONDS` fail; when there is
    room, those that waited say `after` instead (if it isn't empty)."""
    concurrency_db.lock_key(tx, key)
    var hs = concurrency_db.holders(tx, key, stale, dead)
    var out = KeyRoom(max(0, limit - len(hs)))
    if not say:
        return out^
    if out.room > 0:
        concurrency_db.release(tx, pipeline, after, which)
        return out^
    # The run to name: an outdated one if any holds it, which the runs wait
    # on at most the wait limit, else the oldest.
    var h = hs[0].copy()
    for x in hs:
        if x.outdated:
            h = x.copy()
            break
    var head = String(
        KEY_WAITING,
        key,
        " (limit ",
        limit,
        "): run ",
        h.run,
        " of ",
        h.pipeline,
        " holds it",
    )
    if not h.outdated:
        out.hold = head^
        concurrency_db.hold_on(tx, pipeline, h.run, False, out.hold, which)
        return out^
    var seconds: Float64
    try:
        seconds = wait_limit()
    except e:
        # Checked at startup; a key registered since without the setting
        # holds its runs, saying so.
        out.hold = String(head, "; held: ", e)
        concurrency_db.hold_on(tx, pipeline, h.run, False, out.hold, which)
        return out^
    out.hold = String(
        head,
        ", on older version ",
        _version(h.version),
        ": it fails if that run hasn't ended within ",
        Int(seconds),
        " s (",
        WAIT_ENV,
        ")",
    )
    concurrency_db.hold_on(tx, pipeline, h.run, True, out.hold, which)
    out.error = String(
        "timed out waiting for run ",
        h.run,
        " (version ",
        _version(h.version),
        "): it holds concurrency key ",
        key,
        " (limit ",
        limit,
        "), and ",
        WAIT_ENV,
        " is ",
        Int(seconds),
        " s; that run was left running",
    )
    out.timed_out = concurrency_db.time_out(
        tx, pipeline, seconds, out.error, which
    )
    return out^


def started(mut tx: Transaction, run: Int64, key: String) raises:
    """`run`, just started, holds `key` (none if it's empty)."""
    if key:
        concurrency_db.record_start(tx, run, key)


def check_wait_limit(mut conn: Connection) raises:
    """Raises when a registered pipeline declares a concurrency key and
    `MORCA_HANDOVER_WAIT_SECONDS` isn't set to a number of seconds above 0:
    the scheduler's check at startup."""
    var p = concurrency_db.any_key(conn)
    if not p:
        return
    try:
        _ = wait_limit()
    except e:
        raise Error(String(e), " (pipeline ", p, " declares one)")
