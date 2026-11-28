"""The dista tasks a pipeline's steps call, and the runtime a run gets.

```mojo
comptime Square = Task[Int, Int, square]
comptime TaxiTasks = Tasks[Square]
comptime Taxi = Pipeline["taxi", Download, Load, tasks=TaxiTasks]

def load(mut ctx: Ctx, raw: RawFile) raises -> Loaded:
    ref rt = ctx.runtime[TaxiTasks]()
    var r = rt.remote[Square](7)
    ...
```

A run of a pipeline with tasks starts one dista `Runtime` before its first
step and keeps it until the run ends: in local mode it forks a head and
`MORCA_WORKERS` workers (default 4) with no group, and the workers of each
group `MORCA_GROUPS` names (`gpu=1,io=2`, which the local runner and the
control host set from the pipeline's groups, docs/groups.md); with
`DISTA_HEAD` set it joins that cluster instead. The same binary is dista's worker: run with `DISTA_ROLE`
set, `morca_main` hands the process to dista before reading its arguments.

The runtime starts before morca opens a database connection or its heartbeat
thread, so the forked head and workers inherit neither.

On macOS a local runtime initialises libcurl (objectstore's
`curl_global_init`) before it forks (#135). The process has threads by
then, and in the child of a process with threads the Objective-C runtime
crashes any class's first `+initialize`, which libcurl's macOS setup
(`Curl_macos_init`, loading SystemConfiguration) runs. Done in the driver,
the classes are initialised once, before the fork, and the head and workers
inherit them: a task's first S3 request no longer crashes its worker. curl
asks for exactly this (`curl_global_init` before `fork`). Linux needs
nothing, and a cluster's head and workers are started, not forked.

A driver or worker given `DISTA_HEAD` first waits until the head accepts a
connection (`wait_for_head`), trying for a second at a time. On Kubernetes
the head's Service can be a moment old: a connection sent before the node
routes its address waits on a connection-tracking entry that never routes,
for minutes, and dista connects without a timeout. A fresh try each second
gets a fresh entry.
"""

from std.ffi import c_int, c_uint, external_call
from std.memory import stack_allocation
from std.os import getenv
from std.sys.info import CompilationTarget, platform_map
from std.time import perf_counter_ns, sleep

from dista import Runtime, TaskLike
from objectstore.http import free_connection_pool, new_connection_pool
from dista.socket import (
    AF_INET,
    POLLOUT,
    SOCK_STREAM,
    SOCKADDR_IN_SIZE,
    SOL_SOCKET,
    _sockaddr,
    poll,
    resolve_ipv4,
)

comptime _pm = platform_map[T=Int, ...]
comptime _F_SETFL: c_int = 4
comptime _O_NONBLOCK: c_int = c_int(_pm["O_NONBLOCK", linux=0x800, macos=0x4]())
comptime _SO_ERROR: c_int = c_int(_pm["SO_ERROR", linux=4, macos=0x1007]())


def _accepts(host: String, port: Int) raises -> Bool:
    """Whether `host`:`port` accepts a TCP connection within a second."""
    var fd = external_call["socket", c_int](AF_INET, SOCK_STREAM, c_int(0))
    if fd < 0:
        return False
    var ok = False
    try:
        # fcntl is variadic, which Apple's arm64 ABI passes on the stack:
        # declared as dista declares it, or the flag isn't set there.
        _ = external_call["fcntl", c_int, num_fixed_args=2](
            fd, _F_SETFL, _O_NONBLOCK
        )
        var addr = _sockaddr(resolve_ipv4(host), port)
        if (
            # dista's and flare's argument types: one program can't
            # declare a libc function twice with different ones.
            external_call["connect", Int32](
                fd, Int(addr.unsafe_ptr()), Int32(SOCKADDR_IN_SIZE)
            )
            == 0
        ):
            ok = True
        elif poll([fd], [POLLOUT], 1000)[0] != 0:
            var err = stack_allocation[1, c_int]()
            err[] = -1
            var size = stack_allocation[1, c_uint]()
            size[] = 4
            _ = external_call["getsockopt", Int32](
                fd, SOL_SOCKET, _SO_ERROR, Int(err), Int(size)
            )
            ok = err[] == 0
        _ = addr[0]  # addr stays alive until connect has returned
    except:
        pass
    _ = external_call["close", c_int](fd)
    return ok


def wait_for_head(addr: String, timeout_s: Float64) raises:
    """Returns once the dista head at `host:port` accepts a connection;
    raises after `timeout_s` seconds."""
    var colon = addr.rfind(":").or_else(-1)
    if colon <= 0:
        raise Error("morca: DISTA_HEAD is host:port, not ", addr)
    var host = String(addr[byte=:colon])
    var port = Int(addr[byte = colon + 1 :])
    var deadline = Int(perf_counter_ns()) + Int(timeout_s * 1e9)
    while not _accepts(host, port):
        if Int(perf_counter_ns()) >= deadline:
            raise Error(
                "morca: the dista head at ",
                addr,
                " accepted no connection in ",
                timeout_s,
                " s",
            )
        sleep(0.25)


def init_curl_before_fork():
    """Initialises libcurl, through objectstore, before a local runtime forks
    (#135, the module's docstring). Without objectstore's library there's no
    libcurl to initialise, and nothing to do."""
    try:
        free_connection_pool(new_connection_pool())
    except:
        pass


trait TaskSet:
    """The tasks a pipeline registers with dista."""

    comptime RT: Movable & Deinitable
    """The runtime type: `Runtime` of the tasks, or `NoneType`."""
    comptime HAS_RUNTIME: Bool

    @staticmethod
    def start(workers: Int) raises -> Self.RT:
        """Starts the runtime: forks a local cluster, or joins `DISTA_HEAD`."""
        ...

    @staticmethod
    def names() -> List[String]:
        """The tasks' linkage names, for the pipeline's registry hash."""
        ...

    @staticmethod
    def timeline(mut rt: Self.RT, path: String) raises -> Int:
        """Writes the run's dista timeline (Chrome's trace format) to `path`
        and returns the tasks in it."""
        ...


struct Tasks[*Ts: TaskLike](TaskSet):
    """A pipeline's dista tasks."""

    comptime RT = Runtime[*Self.Ts]
    comptime HAS_RUNTIME = True

    @staticmethod
    def start(workers: Int) raises -> Self.RT:
        var head = getenv("DISTA_HEAD")
        if head and getenv("DISTA_ROLE") != "head":
            # A head pod may wait for a node and its image.
            wait_for_head(
                head, Float64(getenv("MORCA_HEAD_WAIT_SECONDS", "300"))
            )
        comptime if CompilationTarget.is_macos():
            if not head and not getenv("DISTA_ROLE"):
                init_curl_before_fork()
        return Self.RT(workers=workers, groups=getenv("MORCA_GROUPS"))

    @staticmethod
    def names() -> List[String]:
        var out = List[String]()
        comptime for i in range(Self.Ts.length):
            out.append(String(Self.Ts[i].name()))
        return out^

    @staticmethod
    def timeline(mut rt: Self.RT, path: String) raises -> Int:
        return rt.timeline(path)


struct NoTasks(TaskSet):
    """A pipeline that calls no dista tasks: no runtime is started."""

    comptime RT = NoneType
    comptime HAS_RUNTIME = False

    @staticmethod
    def start(workers: Int) raises -> Self.RT:
        return None

    @staticmethod
    def names() -> List[String]:
        return List[String]()

    @staticmethod
    def timeline(mut rt: Self.RT, path: String) raises -> Int:
        return 0


def task_list[T: TaskSet]() -> String:
    """`T`'s task names, one per line."""
    var out = String()
    for n in T.names():
        out.write(n, "\n")
    return out^


def workers() raises -> Int:
    """`MORCA_WORKERS`, the local workers a run forks (default 4)."""
    var s = getenv("MORCA_WORKERS", "4")
    try:
        var n = Int(s)
        if n >= 1:
            return n
    except:
        pass
    raise Error("morca: MORCA_WORKERS must be a positive number, got ", s)
