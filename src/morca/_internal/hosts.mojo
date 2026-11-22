"""`morca host`: the machines that run a pool's runs, by their worker
tokens (#220).

```
morca host list [--pool <pool>]     id, pool, name, state, image, CPUs, memory, runs, last seen
morca host drain <id>               finishes its runs, claims no more
morca host undrain <id>             claims again
morca host remove <id> [--force]    revokes its token: its worker exits
morca host upgrade <id>             moves it to the server's worker image now
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

**Images.** A host `morca host join --container` installed follows the
server's worker image (`MORCA_WORKER_IMAGE`) after a deploy: it drains
itself, and once idle its container is started on the new image
(`morca._internal.host_follow`). `host list` shows each host's image, the
server's as it last heard it, and `upgrade=`: `current`, `draining` (to
move), `failed` (the pull or the start failed: it runs the old image and
claims again), or `needs-upgrade` (a service, which can't change its own
binary); `-` for a worker that doesn't say (one the pool autoscaler made,
or an older one). **Upgrading** asks a container host to try now, also an
image it failed to move to; it never stops a run.
"""

from std.os import getenv

import morca._internal.db.workers as workers_db

from morca._internal.auth import audit
from morca._internal.db.live import stale_limit
from morca._internal.pool_boot import WORKER_IMAGE
from morca._internal.state import State
from morca._internal.workers import WorkerRow, worker_rows

comptime HOST_USAGE = """usage:
  morca host list [--pool <pool>]
  morca host drain <id>
  morca host undrain <id>
  morca host remove <id> [--force]
  morca host upgrade <id>"""


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


def host_upgrade(r: WorkerRow, server: String) -> Tuple[String, String]:
    """What host `r` says of the server's worker image: its state
    (`current`, `draining`, `failed`, `needs-upgrade`, or `-` when it
    says nothing), and that image as it last heard it, else `server`."""
    var said = r.host_upgrade
    var sp = said.find(" ").or_else(-1)
    if sp > 0:
        return (String(said[byte=:sp]), String(said[byte = sp + 1 :]))
    return (String("-"), server if server else String("-"))


def host_line(r: WorkerRow, stale: Int, server: String = "") -> String:
    """A host as `morca host list` prints it; `server` is the worker image
    of the server this runs beside, if it knows it."""
    var up = host_upgrade(r, server)
    var image = r.host_image if r.host_image else r.image
    return String(
        r.id,
        " ",
        r.pool,
        " ",
        r.name if r.name else r.label,
        " ",
        host_state(r, stale).replace(" ", "-"),
        " image=",
        image if image else String("-"),
        " server_image=",
        up[1],
        " upgrade=",
        up[0],
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
        return _usage(
            "morca host needs list, drain, undrain, remove or upgrade"
        )
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
        var server = getenv(WORKER_IMAGE)
        var n = 0
        for r in worker_rows(db):
            if pool and r.pool != pool:
                continue
            print(host_line(r, stale, server))
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
    if sub == "upgrade" and len(args) == 4:
        var id = _id(args[3])
        var row = Optional[WorkerRow]()
        for r in worker_rows(db):
            if r.id == id:
                row = r.copy()
        if not row or row.value().state != "live":
            raise Error("morca: host ", id, " is no live worker token's")
        ref h = row.value()
        if not h.host_image:
            var why = String(
                "it runs as a service, which can't change its own binary:"
                " install the server's version on it by hand"
            ) if h.host_upgrade.startswith("needs-upgrade") else String(
                "it says no image of its own: only a worker morca host join"
                " --container installed (of this version or newer) moves"
                " itself; a machine the pool autoscaler made is replaced"
                " once idle after a deploy"
            )
            raise Error("morca: host ", id, " can't upgrade itself: ", why)
        if not workers_db.ask_upgrade(db.conn, id):
            raise Error("morca: host ", id, " is no live worker token's")
        audit(
            db,
            who,
            "host upgrade",
            0,
            String("id=", id, " image=", h.host_image),
            "local",
        )
        print(
            "asked host",
            id,
            "to move to the server's worker image at its next claim: it",
            "finishes its",
            workers_db.running_runs(db.conn, id),
            "running runs first, and claims no more until it has",
        )
        return 0
    return _usage(String("unknown: morca host ", sub))
