"""Scheduler instances: two `morca scheduler`s of different images overlapping
on one Postgres during a deploy (docs/overlap.md).

With `MORCA_OVERLAP=on`, each `morca scheduler` has a row in
`orca.schedulers`, kept fresh on every tick with the runs its processes
are. One instance leads: it holds the session advisory lock `LEAD_LOCK`,
and only it decides (fires, sensors, retries, starts, alerts, sweeps). The
newest live instance takes the lead: an older one that sees a newer one
live, or is asked to (`morca scheduler drain`), gives the lock up and
drains: it starts nothing, keeps supervising the processes it started
until they end, then ends its row and exits. A run an instance started
records it (`runs.instance`), and `morca._internal.live.held_sql` keeps it live while
the instance lists it, so the leader counts it and leaves it alone.

An instance is live while it has been seen within the stale limit and
hasn't ended; "gone" is the opposite, and only then are its runs, once
their heartbeats are stale too, queued again (`Scheduler._requeue_orphans`).
"""

from std.os import getenv
from std.time import sleep

import morca._internal.db.schedulers as schedulers_db

from morca._internal.db.live import stale_limit
from morca._internal.migrations import known_migrations, migration_floor
from morca._internal.state import State
from morca._internal.store import process_owner


comptime LEAD_LOCK = 0x6F726365  # "orce"
"""The session advisory lock the leading instance holds."""


def overlap_on() raises -> Bool:
    """`MORCA_OVERLAP`: `off` (the default: one scheduler at a time, as
    before) or `on` (an instance row, a lead, and a drain)."""
    var v = getenv("MORCA_OVERLAP", "off")
    if v != "on" and v != "off":
        raise Error("morca: MORCA_OVERLAP is on or off, not ", v)
    return v == "on"


def drain_limit() raises -> Float64:
    """`MORCA_DRAIN_SECONDS`, required of an instance (#390): how long it may
    keep draining its runs once a newer one leads before it kills what is
    left. Raises when it's unset, not a number, or not above 0."""
    var v = getenv("MORCA_DRAIN_SECONDS")
    var how = String(
        ": with MORCA_OVERLAP=on it is how long, in seconds, a scheduler may",
        " keep draining its runs once a newer one leads before it kills them",
        " (docs/overlap.md#the-drain). Set it (in the Hetzner stack,",
        " DRAIN_SECONDS in hetzner.env), or MORCA_OVERLAP=off",
    )
    if not v:
        raise Error("morca: MORCA_DRAIN_SECONDS isn't set", how)
    var n: Float64
    try:
        n = Float64(v)
    except:
        raise Error(
            "morca: MORCA_DRAIN_SECONDS isn't a number of seconds (",
            v,
            ")",
            how,
        )
    if not n > 0:
        raise Error("morca: MORCA_DRAIN_SECONDS isn't above 0 (", v, ")", how)
    return n


def join(mut db: State) raises -> Int:
    """Adds this process's row, waiting, with the migrations it knows and
    its image (`MORCA_IMAGE`); returns its id."""
    var me = process_owner()
    var at = me.rfind(":").or_else(-1)
    return schedulers_db.join(
        db.conn,
        String(me[byte=:at]),
        Int(String(me[byte = at + 1 :])),
        getenv("MORCA_IMAGE"),
        known_migrations(),
    )


def beat(mut db: State, id: Int, running: String) raises -> Bool:
    """Marks instance `id` seen, with `running` (run ids, comma-separated)
    its processes' runs; returns whether it was asked to drain."""
    return schedulers_db.beat(db.conn, id, running)


def newer(mut db: State, id: Int) raises -> Int:
    """The newest live instance after `id` that isn't draining, or 0."""
    return schedulers_db.newer(db.conn, id, stale_limit())


def try_lead(mut db: State, id: Int) raises -> Bool:
    """Takes the lead for instance `id` if no one holds it; records it."""
    return schedulers_db.try_lead(db.conn, id, LEAD_LOCK)


def step_down(mut db: State, id: Int, leading: Bool) raises:
    """Instance `id` drains: gives up the lead if it held it, and records
    that it drains."""
    schedulers_db.step_down(db.conn, id, leading, LEAD_LOCK)


def end(mut db: State, id: Int) raises:
    """Instance `id` has ended: gone at once, for the leader's requeue."""
    schedulers_db.end(db.conn, id)


def ask_drain(mut db: State, id: Int) raises -> Bool:
    """Asks live instance `id` to drain; False if there's no such one."""
    return schedulers_db.ask_drain(db.conn, id, stale_limit())


def instances(mut db: State) raises -> List[String]:
    """A line for each instance not long gone (ended or unseen within the
    last hour), oldest first: id, host and pid, role, image, migrations
    known, runs going, and when it was last seen."""
    var out = List[String]()
    for r in schedulers_db.instance_rows(db.conn, stale_limit()):
        out.append(
            String(
                r.id,
                " ",
                r.host,
                ":",
                r.pid,
                " ",
                r.role,
                " image=",
                r.image if r.image else String("-"),
                " migrations=",
                r.known,
                " runs=",
                r.runs,
                " seen=",
                r.ago,
                "s ago",
            )
        )
    return out^


def overlap_refusal(mut db: State) raises -> String:
    """Why this binary can't start beside the scheduler going now, or
    empty if it can (docs/overlap.md#deploying): a live instance leads, and
    no live instance knows fewer migrations than this binary's floor
    (`morca._internal.state.migration_floor`), which its migrations would raise past
    it. Doesn't migrate."""
    var floor = migration_floor(known_migrations())
    var got = schedulers_db.overlap_state(db.conn, floor, stale_limit())
    if not got:
        return String(
            "no scheduler instance has ever run on this database (one before",
            " MORCA_OVERLAP, or with it off, keeps none)",
        )
    ref old = got.value()[0]
    if len(old) > 0:
        return String(
            "this binary's migrations need a binary that knows at least ",
            floor,
            ", and scheduler instance ",
            old[0][0],
            " on ",
            old[0][1],
            " knows ",
            old[0][2],
        )
    if got.value()[1] == 0:
        return String(
            "no live scheduler instance leads (none is going, or it has",
            " MORCA_OVERLAP off)",
        )
    return String()


def wait_for_lead(mut db: State, timeout: Float64) raises -> Bool:
    """Waits, up to `timeout` seconds, for the newest live instance to lead
    (a handover over); True at once with no instance live. A deploy
    registers the new image's pipelines only after this, so the instance
    going away never starts their new code."""
    var waited = 0.0
    while True:
        if schedulers_db.newest_leads(db.conn, stale_limit()):
            return True
        if waited >= timeout:
            return False
        sleep(0.5)
        waited += 0.5
