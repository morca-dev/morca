"""Stopping `morca ui` without dropping a request. `docker stop` sends
SIGTERM and waits 10 s before it kills; Ctrl-C sends SIGINT. Either one
starts a drain:

1. `/healthz` answers 503 `draining` (the flag `Drain.draining` returns),
   so a health checker or proxy that asks over a kept-alive connection
   stops routing here; and the listening socket closes, so a new
   connection is refused at once (one waiting in its backlog is reset).
2. The requests already in the handler finish and their answers go out;
   so does one a kept-alive connection sends meanwhile.
3. Once no request has been in the handler for 200 ms, or after
   `MORCA_UI_DRAIN_SECONDS` (default 8, under `docker stop`'s 10), the
   server's loop stops, which closes the kept-alive connections, and
   `morca ui` exits 0. A request still running half a second after that
   can't be cut short (the handler runs on the loop's thread), so the
   process then exits 1 without it.

A second signal during the drain stops the loop at once.

A signal handler can't reach a Mojo variable, so it writes a byte to a pipe
whose write end is duplicated onto a fixed descriptor, `WAKE_FD`, and a
thread of its own waits on the read end (as `dista.signals` does for a
worker). The handler runs on whichever thread the kernel picks, and `write`
is async-signal-safe; `signal` installs it with `SA_RESTART`, so a query
it interrupts goes on.

Flare's `HttpServer.drain(timeout_ms)` always waits out its whole window,
since its loop publishes no count of what's in flight, so the drain counts
the requests in the handler itself (`Counting`) and stops the loop with
`HttpServer.close()` once there are none.
"""

from std.ffi import c_int, external_call
from std.os import getenv
from std.time import perf_counter_ns, sleep

from flare.http import Handler, HttpServer, Request, ResponseImpl
from threads import AtomicCounter, AtomicFlag, WorkerPool
from threads.ffi import OpaquePtr, opaque_ptr

comptime SIGINT: c_int = 2
comptime SIGTERM: c_int = 15
comptime WAKE_FD: c_int = 249
"""The descriptor the handler writes to: below macOS's default limit of 256
open files, above what a process has open when it starts, and one below
`dista.signals.WAKE_FD`."""
comptime DEFAULT_DRAIN_SECONDS = 8
comptime _SETTLE_MS = 200
"""How long the handler has to stay empty before the loop is stopped: the
last answer is written right after its handler returns, and a kept-alive
connection's next request, if it was already on its way, gets in."""
comptime _LAST_MS = 500
"""How long the loop gets to stop once it's told to."""
comptime _POLLIN: Int32 = 1


def _wake(sig: c_int):
    # Only async-signal-safe calls in here. A full pipe would block `write`,
    # which a few signals don't fill.
    var b = Array[UInt8, 1](fill=UInt8(Int(sig)))
    _ = external_call["write", Int](WAKE_FD, b.unsafe_ptr(), 1)


def _readable(fd: c_int, timeout_ms: Int) -> Bool:
    """Whether `fd` has something to read, waiting up to `timeout_ms`."""
    # struct pollfd { int fd; short events; short revents; }; `events` is
    # the low half of the second int on the little-endian targets morca runs
    # on. The argument types are dista's and flare's (`_c_poll`): one
    # program can't declare `poll` twice with different ones.
    var p = Array[Int32, 2](fill=0)
    p[0] = Int32(fd)
    p[1] = _POLLIN
    var n = external_call["poll", Int32](
        Int(p.unsafe_ptr()), Int(1), Int32(timeout_ms)
    )
    _ = p[0]  # p stays alive until poll has returned
    return n > 0


def _take(fd: c_int):
    """Reads the bytes the handler wrote, which `poll` found."""
    var buf = Array[UInt8, 16](fill=0)
    _ = external_call["read", Int](fd, buf.unsafe_ptr(), 16)


def _now_ms() -> Int:
    return Int(perf_counter_ns() // 1_000_000)


def drain_seconds() -> Int:
    """`MORCA_UI_DRAIN_SECONDS`, or 8 if it's unset or not a number; 0 stops
    without waiting for anything."""
    var raw = getenv("MORCA_UI_DRAIN_SECONDS")
    if not raw:
        return DEFAULT_DRAIN_SECONDS
    try:
        return max(Int(raw), 0)
    except:
        print(
            "morca ui: MORCA_UI_DRAIN_SECONDS isn't a number of seconds:",
            raw,
            "- using",
            DEFAULT_DRAIN_SECONDS,
        )
        return DEFAULT_DRAIN_SECONDS


def _wake_fd() -> c_int:
    """Makes SIGTERM and SIGINT write to a pipe, and returns its read end;
    or -1, leaving both as they were, if `WAKE_FD` is taken or the pipe
    can't be made."""
    var taken = external_call["dup", c_int](WAKE_FD)
    if taken >= 0:
        _ = external_call["close", c_int](taken)
        return -1
    var fds = Array[c_int, 2](fill=-1)
    if external_call["pipe", c_int](fds.unsafe_ptr()) != 0:
        return -1
    if external_call["dup2", c_int](fds[1], WAKE_FD) != WAKE_FD:
        _ = external_call["close", c_int](fds[0])
        _ = external_call["close", c_int](fds[1])
        return -1
    _ = external_call["close", c_int](fds[1])
    _ = external_call["signal", Int](SIGTERM, _wake)
    _ = external_call["signal", Int](SIGINT, _wake)
    return fds[0]


def stop_signals() -> c_int:
    """For a loop other than `morca ui`'s (`morca scheduler`, #426): makes
    SIGTERM and SIGINT write to the same pipe, and returns its read end
    for `stop_asked`; or -1, leaving both as they were."""
    return _wake_fd()


def stop_asked(fd: c_int, timeout_ms: Int) -> Bool:
    """Whether SIGTERM or SIGINT has come, waiting up to `timeout_ms` for
    one on `stop_signals`'s `fd` (just sleeping when it's -1)."""
    if fd < 0:
        sleep(Float64(timeout_ms) / 1000)
        return False
    if _readable(fd, timeout_ms):
        _take(fd)
        return True
    return False


struct _Stopping(Movable):
    var server: Int
    """The `HttpServer`'s address; its loop runs on the main thread."""
    var busy: AtomicCounter
    var draining: AtomicFlag
    var wake: c_int
    var drain_ms: Int

    def __init__(
        out self,
        server: Int,
        busy: AtomicCounter,
        draining: AtomicFlag,
        wake: c_int,
        drain_ms: Int,
    ):
        self.server = server
        self.busy = busy
        self.draining = draining
        self.wake = wake
        self.drain_ms = drain_ms


def _drain(s: _Stopping, stop: AtomicFlag):
    ref server = Pointer[HttpServer, MutAnyOrigin](
        unsafe_from_address=s.server
    )[]
    s.draining.set()
    print(
        "morca ui: stopping: no new connections; waiting up to ",
        s.drain_ms // 1000,
        " s for ",
        s.busy.load(),
        " request(s) in flight",
        sep="",
    )
    # What `HttpServer.drain` does first; flare has no call for it alone.
    server._listener.close()
    var start = _now_ms()
    var idle_since = -1
    while True:
        var now = _now_ms()
        if now - start >= s.drain_ms:
            if s.busy.load() > 0:
                print(
                    "morca ui: ",
                    s.busy.load(),
                    " request(s) still in flight after ",
                    s.drain_ms // 1000,
                    " s",
                    sep="",
                )
            break
        if _readable(s.wake, 0):
            print("morca ui: a second signal: stopping now")
            break
        if s.busy.load() == 0:
            if idle_since < 0:
                idle_since = now
            elif now - idle_since >= _SETTLE_MS:
                break
        else:
            idle_since = -1
        sleep(0.01)
    server.close()
    # The loop sees `close` within its 100 ms poll, unless a handler is
    # still running on it; `serve_ui` returning drops the pool, which sets
    # `stop`.
    var told = _now_ms()
    while not stop.is_set():
        if _now_ms() - told >= _LAST_MS:
            print("morca ui: a request is still running: exiting without it")
            external_call["_exit", NoneType](c_int(1))
        sleep(0.01)


def _watch(worker: Int, ctx: OpaquePtr, stop: AtomicFlag) -> None:
    ref s = Pointer[_Stopping, MutAnyOrigin](unsafe_from_address=Int(ctx))[]
    while not stop.is_set():
        if _readable(s.wake, 100):
            _take(s.wake)
            _drain(s, stop)
            return


struct Counting[H: Handler & Copyable](Copyable, Handler):
    """`H`, counting the requests in it in `busy`."""

    comptime BodyType = Self.H.BodyType

    var inner: Self.H
    var busy: AtomicCounter

    def __init__(out self, var inner: Self.H, busy: AtomicCounter):
        self.inner = inner^
        self.busy = busy

    def serve(self, req: Request) raises -> ResponseImpl[Self.BodyType]:
        _ = self.busy.fetch_add(1)
        try:
            var resp = self.inner.serve(req)
            _ = self.busy.fetch_add(-1)
            return resp^
        except e:
            _ = self.busy.fetch_add(-1)
            raise e^


struct Drain(Movable):
    """A thread that drains the `HttpServer` it's given on SIGTERM or
    SIGINT, until this is dropped, which joins it. Serve the handler
    `counting` returns, so it knows what's in flight."""

    var _busy: AtomicCounter
    var _draining: AtomicFlag
    var _state: List[_Stopping]
    """One element, which the thread holds by address: a list's elements
    stay where they are when the list is moved."""
    var _pool: Optional[WorkerPool]

    def __init__(out self, mut server: HttpServer) raises:
        self._busy = AtomicCounter.alloc()
        self._draining = AtomicFlag.alloc()
        self._state = List[_Stopping]()
        self._pool = None
        var wake = _wake_fd()
        if wake < 0:
            print(
                "morca ui: can't watch for SIGTERM (descriptor",
                WAKE_FD,
                "is taken): it stops at once",
            )
            return
        self._state.append(
            _Stopping(
                Int(Pointer(to=server)),
                self._busy,
                self._draining,
                wake,
                drain_seconds() * 1000,
            )
        )
        self._pool = WorkerPool.start[_watch](
            1, opaque_ptr(Int(Pointer(to=self._state[0])))
        )

    def counting[H: Handler & Copyable](self, var handler: H) -> Counting[H]:
        """`handler`, counting its requests for the drain."""
        return Counting(handler^, self._busy)

    def draining(self) -> AtomicFlag:
        """Set from the moment a drain starts; valid while this lives."""
        return self._draining

    def __deinit__(deinit self):
        # Join the thread before freeing the cells it uses.
        _ = self._pool^
        self._busy.unsafe_free()
        self._draining.unsafe_free()
