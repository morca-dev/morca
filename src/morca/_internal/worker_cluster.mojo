"""The processes of one run's dista cluster on a remote worker (#268,
`morca._internal.run_cluster`): the head and a dista worker beside the run's driver
on the worker that starts it, and a dista worker on each one that joins.

Every one of them gets the run's cluster token as `DISTA_TOKEN` (dista
refuses a connection without it) and its address as `DISTA_ADVERTISE`, the
one `morca worker --advertise` says the pool's machines reach it at. A
member's dista worker gives up on a head that's gone after
`DISTA_CONNECT_TIMEOUT` (10 s), as well as being stopped when its run ends.
"""

from std.ffi import c_int, external_call

from dista.socket import Listener

from morca._internal.proc import spawn

comptime MEMBER_CONNECT_SECONDS = "10"


def free_port() raises -> Int:
    """A port no listener has now, for a run's head."""
    var l = Listener()
    var port = l.port
    l.close()
    return port


def _with(var env: List[String], extra: List[String]) -> List[String]:
    for e in extra:
        env.append(e)
    return env^


def start_head(
    binary: String, env: List[String], log: String, port: Int, token: String
) raises -> Int:
    """The run's dista head, on `port`; its pid (its own process group)."""
    return spawn(
        [binary],
        log,
        env=_with(
            env.copy(),
            [
                String("DISTA_ROLE=head"),
                String("DISTA_PORT=", port),
                String("DISTA_TOKEN=", token),
            ],
        ),
        group=True,
    )


def worker_slots(env: List[String], slots: Int) -> String:
    """A cluster worker's `DISTA_WORKER_SLOTS=`: `auto` if `env` asks for
    it, else `slots`."""
    for e in env:
        if e == "DISTA_WORKER_SLOTS=auto":
            return String("DISTA_WORKER_SLOTS=auto")
    return String("DISTA_WORKER_SLOTS=", slots)


def start_dista_worker(
    binary: String,
    env: List[String],
    log: String,
    head: String,
    advertise: String,
    token: String,
    slots: Int,
    member: Bool,
    group: String = "",
) raises -> Int:
    """A dista worker of the run's cluster at `head`, reached at
    `advertise`, with `slots` (0: one per core), or `auto` when `env` has
    `DISTA_WORKER_SLOTS=auto` (dista then sizes it from the grant in `env`,
    all of it its own); its pid. A member's gives up on a head that's gone
    within `MEMBER_CONNECT_SECONDS`. One of a worker group (docs/groups.md)
    gets `DISTA_GROUP`, so the head sends it that group's tasks alone; one
    with none runs the tasks that name no group."""
    var extra: List[String] = [
        String("DISTA_ROLE=worker"),
        String("DISTA_HEAD=", head),
        String("DISTA_ADVERTISE=", advertise),
        String("DISTA_TOKEN=", token),
        worker_slots(env, slots),
    ]
    if member:
        extra.append(String("DISTA_CONNECT_TIMEOUT=", MEMBER_CONNECT_SECONDS))
    if group:
        extra.append(String("DISTA_GROUP=", group))
    return spawn([binary], log, env=_with(env.copy(), extra), group=True)


def stop_group(pid: Int):
    """SIGTERM to `pid`'s process group (dista exits on it)."""
    _ = external_call["kill", c_int](c_int(-pid), c_int(15))
