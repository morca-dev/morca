"""`morca host`: the machines that run a pool's runs, by their worker
tokens (#220).

```
morca host list [--pool <pool>]     id, pool, name, state, image, CPUs, memory, runs, last seen
morca host drain <id>               finishes its runs, claims no more
morca host undrain <id>             claims again
morca host remove <id> [--force]    revokes its token: its worker exits
```

A host is a worker token's machine (`orca.workers`), whether it joined by
hand (`morca worker`) or the pool autoscaler made it
(`morca._internal.pool_scale`). **Draining** sets `orca.workers.draining`:
`/api/worker/claim` gives its worker nothing new, so it finishes the runs it
has and keeps beating; a machine the autoscaler made is removed once idle.
**Removing** revokes the token, so its worker is refused and exits at its
next claim; a host with runs running is refused unless `--force` (its runs
are then queued again as any lost worker's are). Each is a row of
`orca.audit`, as `morca worker-token` writes.
"""

from std.os import getenv

import morca._internal.db.workers as workers_db

from morca._internal.auth import audit
from morca._internal.db.live import stale_limit
from morca._internal.state import State
from morca._internal.workers import WorkerRow, worker_rows

comptime HOST_USAGE = """usage:
  morca host list [--pool <pool>]
  morca host drain <id>
  morca host undrain <id>
  morca host remove <id> [--force]"""


def host_state(r: WorkerRow, stale: Int) -> String:
    """`live`, `draining`, `not seen` (not heard from in `stale` seconds),
    `revoked` or `expired`."""
    if r.state != "live":
        return r.state
    if r.seen_ago < 0 or r.seen_ago > stale:
        return "not seen"
    return "draining" if r.draining else "live"


def _runs(running: String) -> Int:
    var n = 0
    for x in running.split(","):
        if String(x).strip():
            n += 1
    return n


def host_line(r: WorkerRow, stale: Int) -> String:
    """A host as `morca host list` prints it."""
    return String(
        r.id,
        " ",
        r.pool,
        " ",
        r.name if r.name else r.label,
        " ",
        host_state(r, stale).replace(" ", "-"),
        " image=",
        r.image if r.image else String("-"),
        " cpus=",
        r.cpus,
        " memory_mb=",
        r.memory_mb,
        " runs=",
        _runs(r.running),
        " seen=",
        r.last_seen if r.last_seen else String("never"),
    )


def _id(arg: String) raises -> Int:
    var id: Int
    try:
        id = Int(arg)
    except:
        id = 0
    if id <= 0:
        raise Error("morca: not a host's id (morca host list): ", arg)
    return id


def _usage(msg: String) -> Int:
    print(msg)
    print(HOST_USAGE)
    return 2


def host_command(url: String, args: List[String]) raises -> Int:
    """`morca host list|drain|undrain|remove ...`."""
    if len(args) < 3:
        return _usage("morca host needs list, drain, undrain or remove")
    var db = State(url)
    db.migrate()
    var who = getenv("USER", "local")
    var sub = args[2]
    if sub == "list":
        var pool = String()
        if len(args) == 5 and args[3] == "--pool":
            pool = args[4]
        elif len(args) != 3:
            return _usage("host list takes only --pool <pool>")
        var stale = Int(stale_limit())
        var n = 0
        for r in worker_rows(db):
            if pool and r.pool != pool:
                continue
            print(host_line(r, stale))
            n += 1
        if n == 0:
            print("no hosts")
        return 0
    if (sub == "drain" or sub == "undrain") and len(args) == 4:
        var id = _id(args[3])
        var on = sub == "drain"
        if not workers_db.set_draining(db.conn, id, on):
            raise Error(
                "morca: host ",
                id,
                " is no live worker token's, or is ",
                "draining" if on else "not draining",
                " already",
            )
        audit(db, who, String("host ", sub), 0, String("id=", id), "local")
        if on:
            print(
                "draining host",
                id,
                "- it finishes its",
                workers_db.running_runs(db.conn, id),
                "running runs and claims no more",
            )
        else:
            print("host", id, "claims runs again")
        return 0
    if sub == "remove" and (
        len(args) == 4 or (len(args) == 5 and args[4] == "--force")
    ):
        var id = _id(args[3])
        var running = workers_db.running_runs(db.conn, id)
        if running > 0 and len(args) == 4:
            raise Error(
                "morca: host ",
                id,
                " has ",
                running,
                " runs running: drain it first (morca host drain ",
                id,
                "), or remove it with --force, and they are queued again",
            )
        if not workers_db.revoke(db.conn, id):
            raise Error("morca: host ", id, " is no live worker token's")
        audit(
            db,
            who,
            "host remove",
            0,
            String("id=", id, " running=", running),
            "local",
        )
        print(
            "removed host",
            id,
            "- its token is revoked, and its worker exits at its next claim",
        )
        return 0
    return _usage(String("unknown: morca host ", sub))
