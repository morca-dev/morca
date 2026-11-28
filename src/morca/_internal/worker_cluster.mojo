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
from morca._internal.provider import (
    POOL,
    ClusterProcess,
    cluster_env,
    texts,
    worker_slots as slots_of,
)


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
    """The run's dista head, on `port`; its pid (its own process group).
    Its variables are the pool provider's (`morca._internal.provider`)."""
    return spawn(
        [binary],
        log,
        env=_with(
            env.copy(),
            texts(cluster_env(POOL, ClusterProcess.head_at(port, token))),
        ),
        group=True,
    )


def worker_slots(env: List[String], slots: Int) -> String:
    """A cluster worker's `DISTA_WORKER_SLOTS=`: `auto` if `env` asks for
    it, else `slots`."""
    return String("DISTA_WORKER_SLOTS=", slots_of(env, slots))


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
    with none runs the tasks that name no group. Its variables are the
    pool provider's (`morca._internal.provider`); its GPUs are in `env`,
    from its grant."""
    var p = ClusterProcess.worker_of(
        head, advertise, token, slots_of(env, slots), member, group
    )
    return spawn(
        [binary],
        log,
        env=_with(env.copy(), texts(cluster_env(POOL, p))),
        group=True,
    )


def stop_group(pid: Int):
    """SIGTERM to `pid`'s process group (dista exits on it)."""
    _ = external_call["kill", c_int](c_int(-pid), c_int(15))
