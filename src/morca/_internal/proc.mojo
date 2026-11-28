"""Starting processes: what the scheduler needs to run pipeline binaries.

`spawn` forks and executes a binary without waiting for it, its output
appended to a log file if one is given; `reap` collects the ones that
ended, with what `wait4` says they used (`morca._internal.usage`).
`capture` runs a command to the end, killing it past a timeout, and returns
what it printed; `Capture` is the same started without waiting, for the
scheduler to check on from tick to tick. Everything a child needs is
prepared before `fork`, so the child calls only `write` (into a run's
cgroup, on a descriptor the parent opened), `setpgid`, `fopen`, `dup2`,
`setenv`, `setpriority`, `fwrite` (Linux), `execv` (or `execvp`) and
`_exit`.
"""

from std.ffi import c_int, external_call
from std.memory import stack_allocation
from std.os import getenv, remove
from std.sys.info import CompilationTarget
from std.time import perf_counter_ns, sleep


def _cstr(s: String) -> List[UInt8]:
    var b = List[UInt8](capacity=s.byte_length() + 1)
    for c in s.as_bytes():
        b.append(c)
    b.append(0)
    return b^


def spawn(
    argv: List[String],
    log: String = "",
    env: List[String] = List[String](),
    nice: Int = 0,
    group: Bool = False,
    first_to_go: Bool = False,
    cgroup: String = "",
) raises -> Int:
    """Starts `argv[0]` (a path) with arguments `argv`, and returns its pid.
    Its stdout and stderr are appended to `log`, if given, else shared with
    this process. `env`'s `NAME=VALUE`s are added to its environment only,
    so they're on no command line; `nice` lowers its CPU priority; `group`
    makes it lead a process group of its own, which `kill(-pid)` ends whole;
    `first_to_go`, on Linux, makes it (and what it forks) the first the
    kernel kills when memory runs out (`oom_score_adj` 1000). `cgroup`, a
    cgroup v2 directory (`morca._internal.cgroup`), is where it goes before it execs:
    the parent opens its `cgroup.procs` (close-on-exec) and the child
    writes `0` to it, its first act and an async-signal-safe one, so all
    it runs and starts is in the cgroup."""
    if len(argv) == 0:
        raise Error("spawn: no program")
    var args = List[List[UInt8]]()
    for a in argv:
        args.append(_cstr(a))
    var ptrs = List[Int]()
    for i in range(len(args)):
        ptrs.append(Int(args[i].unsafe_ptr()))
    ptrs.append(0)
    var names = List[List[UInt8]]()
    var values = List[List[UInt8]]()
    for kv in env:
        var eq = kv.find("=").or_else(-1)
        if eq <= 0:
            # The value may be a secret: it stays out of the message.
            raise Error("spawn: an environment entry isn't NAME=VALUE")
        names.append(_cstr(String(kv[byte=:eq])))
        values.append(_cstr(String(kv[byte = eq + 1 :])))
    var log_c = _cstr(log)
    var mode = _cstr("a")
    var oom_path = _cstr("/proc/self/oom_score_adj")
    var oom_value = _cstr("1000")
    var oom_mode = _cstr("w")
    var procs = Int(0)
    var procs_fd = c_int(-1)
    var zero = _cstr("0")
    if cgroup:
        var path = _cstr(String(cgroup, "/cgroup.procs"))
        # "e": O_CLOEXEC, so the run doesn't inherit it.
        var we = _cstr("we")
        procs = external_call["fopen", Int](path.unsafe_ptr(), we.unsafe_ptr())
        if procs == 0:
            raise Error("spawn: can't open ", cgroup, "/cgroup.procs")
        procs_fd = external_call["fileno", c_int](procs)
    var pid = external_call["fork", c_int]()
    if pid < 0:
        if procs != 0:
            _ = external_call["fclose", c_int](procs)
        raise Error("spawn: fork failed")
    if pid == 0:
        if procs_fd >= 0:
            # 0 is the writer: this process, into the run's cgroup.
            _ = external_call["write", Int](procs_fd, zero.unsafe_ptr(), Int(1))
        if group:
            _ = external_call["setpgid", c_int](c_int(0), c_int(0))
        if log:
            var f = external_call["fopen", Int](
                log_c.unsafe_ptr(), mode.unsafe_ptr()
            )
            if f != 0:
                var fd = external_call["fileno", c_int](f)
                _ = external_call["dup2", c_int](fd, c_int(1))
                _ = external_call["dup2", c_int](fd, c_int(2))
        for k in range(len(names)):
            _ = external_call["setenv", c_int](
                names[k].unsafe_ptr(), values[k].unsafe_ptr(), c_int(1)
            )
        if nice > 0:
            # PRIO_PROCESS (0) of this process (0).
            _ = external_call["setpriority", c_int](
                c_int(0), c_int(0), c_int(nice)
            )
        comptime if CompilationTarget.is_linux():
            if first_to_go:
                # Raising one's own score needs no privilege. stdio, as
                # for the log: `open` is declared elsewhere with another
                # signature.
                var f = external_call["fopen", Int](
                    oom_path.unsafe_ptr(), oom_mode.unsafe_ptr()
                )
                if f != 0:
                    _ = external_call["fwrite", Int](
                        oom_value.unsafe_ptr(), Int(1), Int(4), f
                    )
                    _ = external_call["fclose", c_int](f)
        _ = external_call["execv", c_int](
            args[0].unsafe_ptr(), ptrs.unsafe_ptr()
        )
        external_call["_exit", NoneType](c_int(127))
    if procs != 0:
        _ = external_call["fclose", c_int](procs)
    _ = zero^
    _ = args^
    _ = ptrs^
    _ = names^
    _ = values^
    _ = oom_path^
    _ = oom_value^
    _ = oom_mode^
    return Int(pid)


@fieldwise_init
struct Reaped(ImplicitlyCopyable, Movable):
    """A child that ended, as `reap` collects it."""

    var pid: Int
    var code: Int
    """Its exit code; 128 + the signal if a signal killed it."""
    var max_rss: Int
    """`wait4`'s `ru_maxrss` in bytes: the largest resident set of it or of
    a descendant it waited for, one process's, not their sum."""
    var cpu_seconds: Float64
    """Its user and system CPU seconds, with its waited-for descendants'."""


def reap() -> List[Reaped]:
    """The children that ended, without waiting, with what `wait4` says
    they used."""
    var out = List[Reaped]()
    var status = stack_allocation[1, c_int]()
    # struct rusage: two timevals (16 bytes each on 64-bit Linux and
    # macOS), then longs, ru_maxrss first; 144 bytes in all.
    var ru = List[UInt8](length=256, fill=0)
    while True:
        status[] = 0
        # WNOHANG is 1 on macOS and Linux.
        var pid = external_call["wait4", c_int](
            c_int(-1), status, c_int(1), ru.unsafe_ptr()
        )
        if pid <= 0:
            break
        out.append(
            Reaped(
                Int(pid),
                _code(Int(status[])),
                _max_rss(_u64(ru, 32)),
                Float64(_u64(ru, 0))
                + Float64(_u64(ru, 8) & 0xFFFFFFFF) / 1e6
                + Float64(_u64(ru, 16))
                + Float64(_u64(ru, 24) & 0xFFFFFFFF) / 1e6,
            )
        )
    return out^


def _u64(b: List[UInt8], at: Int) -> Int:
    """The little-endian 64-bit value at `at`."""
    var v = 0
    for k in range(8):
        v |= Int(b[at + k]) << (8 * k)
    return v


def _max_rss(v: Int) -> Int:
    """`ru_maxrss` in bytes: Linux counts it in KiB, macOS in bytes."""
    comptime if CompilationTarget.is_linux():
        return v * 1024
    else:
        return v


def binary_seconds() -> Float64:
    """`MORCA_BINARY_SECONDS` (default 300): how long a pipeline binary's
    `describe`, `sense` or `keys` may take before it's killed."""
    try:
        return Float64(getenv("MORCA_BINARY_SECONDS", "300"))
    except:
        return 300.0


def _code(s: Int) -> Int:
    """An exit code from a `waitpid` status: 128 + the signal if killed."""
    return (s >> 8) & 0xFF if s & 0x7F == 0 else 128 + (s & 0x7F)


@fieldwise_init
struct Capture(Copyable, Movable):
    """A command started with its standard output going to a file of its
    own, to be read when it ends (`capture` waits; the scheduler checks on
    it from tick to tick). It leads a process group of its own, so killing
    it kills what it started too."""

    var pid: Int
    var path: String
    var what: String
    """The command, for messages."""
    var started: Int
    """When it started, on the monotonic clock in nanoseconds."""
    var code: Int
    """Its exit code once it has ended, else -1."""

    @staticmethod
    def start(
        argv: List[String], nice: Int = 0, env: List[String] = List[String]()
    ) raises -> Capture:
        """Starts `argv` (`argv[0]` looked up on `PATH`), its stdout to a
        new file under `TMPDIR`, its stderr shared with this process; `nice`
        lowers its CPU priority; `env`'s `NAME=VALUE`s are added to its
        environment only, as `spawn`'s."""
        if len(argv) == 0:
            raise Error("capture: no program")
        var names = List[List[UInt8]]()
        var values = List[List[UInt8]]()
        for kv in env:
            var eq = kv.find("=").or_else(-1)
            if eq <= 0:
                raise Error("capture: an environment entry isn't NAME=VALUE")
            names.append(_cstr(String(kv[byte=:eq])))
            values.append(_cstr(String(kv[byte = eq + 1 :])))
        var what = String()
        for i in range(len(argv)):
            what.write(" " if i > 0 else "", argv[i])
        var t = Int(perf_counter_ns())
        var path = String(
            getenv("TMPDIR", "/tmp").rstrip("/"),
            "/morca-out-",
            external_call["getpid", c_int](),
            "-",
            t,
        )
        var args = List[List[UInt8]]()
        for a in argv:
            args.append(_cstr(a))
        var ptrs = List[Int]()
        for i in range(len(args)):
            ptrs.append(Int(args[i].unsafe_ptr()))
        ptrs.append(0)
        var path_c = _cstr(path)
        var mode = _cstr("w")
        var pid = external_call["fork", c_int]()
        if pid < 0:
            raise Error("capture: fork failed for ", what)
        if pid == 0:
            _ = external_call["setpgid", c_int](c_int(0), c_int(0))
            if nice > 0:
                _ = external_call["setpriority", c_int](
                    c_int(0), c_int(0), c_int(nice)
                )
            for k in range(len(names)):
                _ = external_call["setenv", c_int](
                    names[k].unsafe_ptr(), values[k].unsafe_ptr(), c_int(1)
                )
            var f = external_call["fopen", Int](
                path_c.unsafe_ptr(), mode.unsafe_ptr()
            )
            if f == 0:
                external_call["_exit", NoneType](c_int(126))
            var fd = external_call["fileno", c_int](f)
            _ = external_call["dup2", c_int](fd, c_int(1))
            _ = external_call["execvp", c_int](
                args[0].unsafe_ptr(), ptrs.unsafe_ptr()
            )
            external_call["_exit", NoneType](c_int(127))
        _ = args^
        _ = ptrs^
        _ = names^
        _ = values^
        return Capture(Int(pid), path^, what^, t, -1)

    def seconds(self) -> Float64:
        """How long it has been going."""
        return Float64(Int(perf_counter_ns()) - self.started) / 1e9

    def ended(mut self) -> Bool:
        """Whether it has ended, waiting for it if it has (not if the
        scheduler's `reap` got to it first, which sets `code`)."""
        if self.code >= 0:
            return True
        var status = stack_allocation[1, c_int]()
        status[] = 0
        var got = external_call["waitpid", c_int](
            c_int(self.pid), status, c_int(1)
        )
        if got == c_int(self.pid):
            self.code = _code(Int(status[]))
        elif got < 0:
            self.code = 255  # not our child any more: someone reaped it
        return self.code >= 0

    def kill(mut self):
        """Kills it and what it started, and forgets its output."""
        _ = external_call["kill", c_int](c_int(-self.pid), c_int(9))
        _ = external_call["kill", c_int](c_int(self.pid), c_int(9))
        self._remove()

    def output(mut self) raises -> String:
        """What it printed, once it has ended; the file is removed."""
        var text: String
        with open(self.path, "r") as f:
            text = f.read()
        self._remove()
        return text^

    def _remove(self):
        try:
            remove(self.path)
        except:
            pass

    def timed_out(self, limit: Float64) -> Error:
        return Error(
            "`",
            self.what,
            "` took longer than ",
            Int(limit),
            " s, and was killed",
        )


def capture(
    argv: List[String],
    timeout: Float64 = 0,
    nice: Int = 0,
    env: List[String] = List[String](),
) raises -> Tuple[Int, String]:
    """Runs `argv` to the end and returns its exit code and standard output.
    With a `timeout` (seconds), a command still going then is killed, with
    what it started, and this raises saying so. `nice` lowers its CPU
    priority; `env` is added to its environment."""
    var c = Capture.start(argv, nice, env)
    while not c.ended():
        if timeout > 0 and c.seconds() > timeout:
            c.kill()
            var status = stack_allocation[1, c_int]()
            _ = external_call["waitpid", c_int](c_int(c.pid), status, c_int(0))
            raise c.timed_out(timeout)
        sleep(0.005)
    return (c.code, c.output())
