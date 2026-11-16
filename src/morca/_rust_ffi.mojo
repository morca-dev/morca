"""The C side of a Rust worker (docs/rust-workers.md): loading the library,
the `MorcaRunContext` morca passes it, the callbacks it calls back on, and
the thread that sets its stop flag. `morca.rust_step` drives a call.

**Loaded late.** `load_worker` `dlopen`s the library when the step runs,
never at program start: dista forks its workers, and a library that has
started threads before a fork breaks the child (#135). It's opened with
`RTLD_LOCAL`, so its symbols don't mix with Mojo's, and `RTLD_NODELETE`:
a Rust library with thread-locals mustn't be unloaded while the process
lives, so it never is.

**The context** is one block of memory laid out as the C struct, field for
field; the strings it points to are NUL-terminated copies `WorkerCall`
keeps. The callbacks (`_on_log`, `_on_progress`, `_on_metric`) are `abi("C")`
functions that the worker calls on the thread that called it, which is the
step's; they write to the step's log through its `Ctx`, whose address the
host block holds. A `WorkerCall` borrows that `Ctx`, as a reference does,
so the compiler keeps it alive while the call is.

**Files.** Each call has an output directory of its own, under `$TMPDIR`
(else `/tmp`), for the Parquet files a worker writes; `_on_add_file`
records each file the worker reports (and refuses one that doesn't exist),
and `morca.rust_step` takes them with `take_files` between pulls. The
directory, and whatever is left in it, goes when the call does.

**The stop flag** is an `int32` the worker polls. A thread of
`WorkerCall`'s own sets it once `stop_when()` (by default
`morca.outdated()`) says so, polling every 50 ms, because while the worker
runs, the step's thread is inside it.
"""

from std.atomic import Atomic, Ordering
from std.ffi import OwnedDLHandle, RTLD
from std.memory import OwnedPointer
from std.memory.alloc import unsafe_alloc
from std.ffi import external_call
from std.os import getenv, listdir, makedirs, remove, rmdir
from std.os.path import exists, isdir, islink
from std.sys import CompilationTarget
from std.time import monotonic, sleep

from arrow_mlake.carrow_import import ImportedStream

from threads import AtomicFlag, ThreadHandle
from threads.ffi import OpaquePtr, opaque_ptr

from morca.ctx import Ctx
from morca._common.dlopen import open_library
from morca._lake.abi import Slots
from morca._internal.json import quote

comptime ABI_VERSION: UInt32 = 1
"""The ABI version this morca speaks; a library with another is refused."""

comptime CONTEXT_SIZE = 136
"""`sizeof(MorcaRunContext)`: ABI version 1 with `output_dir` and
`add_file`, which a worker built before them doesn't read (its context was
120 bytes)."""

comptime StopFn = def() thin -> Bool
"""What says a worker should stop: called on a thread of its own."""

comptime _RunFn = def(Int, Int, Int, Int) thin abi("C") -> Int32
comptime _FreeFn = def(Int) thin abi("C") -> None
comptime _VersionFn = def() thin abi("C") -> UInt32
comptime _DescribeFn = def() thin abi("C") -> Int
comptime _LogFn = def(Int, Int, Int) thin abi("C") -> None
comptime _ProgressFn = def(Int, Int64, Int64) thin abi("C") -> None
comptime _MetricFn = def(Int, Int, Int, Float64) thin abi("C") -> None
comptime _AddFileFn = def(Int, Int, Int) thin abi("C") -> Int32
comptime _LastErrorFn = def(Int) thin abi("C") -> Int
comptime _GetNextFn = def(Int, Int) thin abi("C") -> Int32

comptime _PROGRESS_EVERY_NS = 10_000_000_000
"""Progress is logged at most every 10 s, and when it's done."""


def _sym[
    FT: TrivialRegisterPassable
](lib: OwnedDLHandle, name: String) raises -> FT:
    """A C function of the library, as a plain callable (postgres' `_dl_sym`).
    """
    var opt = lib.get_symbol[FT](name)
    if not opt:
        raise Error("morca: the Rust worker has no symbol ", name)
    var addr: Int = Int(opt.value())
    return Pointer(to=addr).unsafe_bitcast[FT]()[]


def library_file(library: String) -> String:
    """The file a library name means: a path or a file name as given, and a
    bare name `x` as `libx.so` (`libx.dylib` on macOS)."""
    if "/" in library or library.endswith(".so") or library.endswith(".dylib"):
        return library
    comptime if CompilationTarget.is_macos():
        return String("lib", library, ".dylib")
    else:
        return String("lib", library, ".so")


struct WorkerLib(Movable):
    """A worker library, open, its ABI version checked."""

    var handle: OwnedDLHandle
    var path: String
    var describe: String
    """`morca_worker_describe()`: the worker's name and version, as JSON."""
    var run: _RunFn
    var free: _FreeFn

    def __init__(out self, library: String) raises:
        comptime FLAGS = RTLD.NOW | RTLD.LOCAL | RTLD.NODELETE
        var file = library_file(library)
        self.path = file
        if "/" in file:
            try:
                self.handle = OwnedDLHandle(file, FLAGS)
            except e:
                raise Error("morca: can't load the Rust worker ", file, ": ", e)
        else:
            self.handle = open_library("morca", file, FLAGS)
        var version = _sym[_VersionFn](
            self.handle, "morca_worker_abi_version"
        )()
        if version != ABI_VERSION:
            raise Error(
                "morca: the Rust worker ",
                file,
                " has ABI version ",
                version,
                ", and this morca speaks ",
                ABI_VERSION,
                ": build it against a morca-worker crate of this morca",
            )
        var d = _sym[_DescribeFn](self.handle, "morca_worker_describe")()
        self.describe = _cstring(d)
        self.run = _sym[_RunFn](self.handle, "morca_worker_run")
        self.free = _sym[_FreeFn](self.handle, "morca_worker_free")


def _cstring(addr: Int) -> String:
    if addr == 0:
        return String()
    return String(
        unsafe_from_utf8_ptr=Pointer[UInt8, ImmUntrackedOrigin](
            unsafe_from_address=addr
        )
    )


def _text(addr: Int, n: Int) -> String:
    """`n` UTF-8 bytes at `addr`, copied."""
    var buf = List[UInt8](capacity=n)
    var p = Pointer[UInt8, ImmUntrackedOrigin](unsafe_from_address=addr)
    for i in range(n):
        buf.append(p[unsafe_offset=i])
    return String(unsafe_from_utf8=Span(buf))


def _c(s: String) -> List[UInt8]:
    var out = List[UInt8](capacity=s.byte_length() + 1)
    for b in s.as_bytes():
        out.append(b)
    out.append(0)
    return out^


def _zeroed(n: Int) -> Int:
    """`n` bytes, 8-aligned and zeroed."""
    var cells = (n + 7) // 8
    var p = unsafe_alloc[Int64](cells)
    for i in range(cells):
        p[unsafe_offset=i] = 0
    return Int(p)


def _free(addr: Int):
    if addr != 0:
        Pointer[Int64, MutUntrackedOrigin](
            unsafe_from_address=addr
        ).unsafe_free()


def _put_int(block: Int, at: Int, v: Int):
    Pointer[Int, MutUntrackedOrigin](unsafe_from_address=block + at)[] = v


def _get_int(block: Int, at: Int) -> Int:
    return Pointer[Int, MutUntrackedOrigin](unsafe_from_address=block + at)[]


def secrets_json() -> String:
    """The run's secrets, the variables `MORCA_SECRETS` names, as a JSON
    object of name to value."""
    var out = String("{")
    var first = True
    for n in getenv("MORCA_SECRETS").split(","):
        var name = String(n.strip())
        if not name:
            continue
        out.write("" if first else ",", quote(name), ":", quote(getenv(name)))
        first = False
    out.write("}")
    return out^


# --- the callbacks, on the step's thread ---


def _ctx_of(host: Int) -> Pointer[Ctx, ImmUntrackedOrigin]:
    """The `Ctx` the call borrows: the callbacks only log, which reads it."""
    return Pointer[Ctx, ImmUntrackedOrigin](
        unsafe_from_address=_get_int(host, 0)
    )


def _on_log(host: Int, msg: Int, n: Int) abi("C") -> None:
    _ctx_of(host)[].log(_text(msg, n))


def _on_progress(host: Int, done: Int64, total: Int64) abi("C") -> None:
    var now = Int(monotonic())
    var last = _get_int(host, 8)
    if last != 0 and now - last < _PROGRESS_EVERY_NS and done != total:
        return
    _put_int(host, 8, now)
    if total > 0:
        _ctx_of(host)[].log(String("progress ", done, "/", total))
    else:
        _ctx_of(host)[].log(String("progress ", done))


def _on_metric(host: Int, name: Int, n: Int, value: Float64) abi("C") -> None:
    _ctx_of(host)[].log(String("metric ", _text(name, n), "=", value))


struct Reported(Movable):
    """The files a worker reported, which `take_files` hasn't taken yet,
    and those refused: reported, but not there."""

    var dir: String
    var files: List[String]
    var missing: List[String]

    def __init__(out self, var dir: String):
        self.dir = dir^
        self.files = List[String]()
        self.missing = List[String]()


def _reported_of(host: Int) -> Pointer[Reported, MutAnyOrigin]:
    return Pointer[Reported, MutAnyOrigin](
        unsafe_from_address=_get_int(host, 16)
    )


def _on_add_file(host: Int, path: Int, n: Int) abi("C") -> Int32:
    var given = _text(path, n)
    ref r = _reported_of(host)[]
    var p = given if given.startswith("/") else String(r.dir, "/", given)
    if not exists(p):
        r.missing.append(p^)
        return 1
    r.files.append(p^)
    return 0


def _remove_tree(path: String):
    """Removes `path` and what's in it, as far as it can; a link is removed,
    not followed."""
    try:
        if isdir(path) and not islink(path):
            for name in listdir(path):
                _remove_tree(String(path, "/", name))
            rmdir(path)
        else:
            remove(path)
    except:
        pass


def _output_dir() raises -> String:
    """A new, empty directory for one call's files."""
    var tmp = getenv("TMPDIR", "/tmp")
    while tmp.endswith("/") and tmp.byte_length() > 1:
        var cut = String(tmp[byte = : tmp.byte_length() - 1])
        tmp = cut^
    var dir = String(
        tmp,
        "/morca-rust-",
        external_call["getpid", Int32](),
        "-",
        Int(monotonic()),
    )
    makedirs(dir, exist_ok=False)
    return dir^


# --- the stop flag's thread ---


def _flag(addr: Int) -> Pointer[Atomic[Int32], MutUntrackedOrigin]:
    return Pointer[Atomic[Int32], MutUntrackedOrigin](unsafe_from_address=addr)


def _watch(arg: OpaquePtr) -> OpaquePtr:
    """Sets the stop flag (the block's first cell) once the `StopFn` in its
    third says so, until the done flag in its second is set."""
    var base = Int(arg)
    var done = AtomicFlag.at(base + 8)
    var stop_when = Pointer[StopFn, MutUntrackedOrigin](
        unsafe_from_address=base + 16
    )[]
    while not done.is_set():
        if stop_when():
            _flag(base)[].store[ordering=Ordering.RELEASE](1)
        sleep(0.05)
    return arg


struct WorkerCall[mut: Bool, //, origin: Origin[mut=mut]](Movable):
    """One call of a worker, over a borrow of the step's `Ctx`: its
    context, its stop flag's thread and, once `start` has run it, the
    stream it returned. Destroying it releases the stream (which ends the
    worker's side of the call), stops the thread and frees the context, in
    that order."""

    var _ctx: Pointer[Ctx, Self.origin]
    """The `Ctx` the callbacks log to, by its address in `host`."""
    var lib: WorkerLib
    var strings: List[List[UInt8]]
    var context: Int
    """The `MorcaRunContext` block."""
    var host: Int
    """What the callbacks get: the `Ctx`'s address, the last progress time,
    and `reported`'s address."""
    var output_dir: String
    """The directory the worker writes its files in."""
    var reported: OwnedPointer[Reported]
    var watch: Int
    """The stop flag, the thread's done flag and the `StopFn`, one cell each."""
    var watcher: ThreadHandle
    var stream_block: Int
    """The `ArrowArrayStream` the worker fills; 0 until `start`."""
    var stream: Optional[ImportedStream]

    def __init__(
        out self,
        var lib: WorkerLib,
        ref[Self.origin] ctx: Ctx,
        params: String,
        step_version: Int,
        stop_when: StopFn,
    ) raises:
        self._ctx = Pointer(to=ctx)
        self.output_dir = _output_dir()
        self.lib = lib^
        self.strings = List[List[UInt8]]()
        self.context = _zeroed(CONTEXT_SIZE)
        self.host = _zeroed(24)
        self.watch = _zeroed(24)
        self.stream_block = 0
        self.stream = None
        self.reported = OwnedPointer(Reported(self.output_dir.copy()))
        _put_int(self.host, 0, Int(self._ctx))
        _put_int(self.host, 16, Int(Pointer(to=self.reported[])))
        Pointer[StopFn, MutUntrackedOrigin](
            unsafe_from_address=self.watch + 16
        )[] = stop_when
        var c = self.context
        _put_int(c, 0, CONTEXT_SIZE)
        var texts: List[String] = [
            ctx.pipeline,
            ctx.step,
            ctx.partition,
            params if params else String("{}"),
            secrets_json(),
            ctx.code,
        ]
        for i in range(len(texts)):
            self.strings.append(_c(texts[i]))
            _put_int(c, 8 * (i + 1), Int(self.strings[i].unsafe_ptr()))
        _put_int(c, 56, ctx.run)
        _put_int(c, 64, ctx.attempt)
        _put_int(c, 72, step_version)
        _put_int(c, 80, self.watch)
        _put_int(c, 88, self.host)
        Pointer[_LogFn, MutUntrackedOrigin](
            unsafe_from_address=c + 96
        )[] = _on_log
        Pointer[_ProgressFn, MutUntrackedOrigin](
            unsafe_from_address=c + 104
        )[] = _on_progress
        Pointer[_MetricFn, MutUntrackedOrigin](
            unsafe_from_address=c + 112
        )[] = _on_metric
        self.strings.append(_c(self.output_dir))
        _put_int(c, 120, Int(self.strings[len(texts)].unsafe_ptr()))
        Pointer[_AddFileFn, MutUntrackedOrigin](
            unsafe_from_address=c + 128
        )[] = _on_add_file
        self.watcher = ThreadHandle.spawn[_watch](opaque_ptr(self.watch))

    def __init__(out self, *, deinit move: Self):
        self._ctx = move._ctx
        self.lib = move.lib^
        self.strings = move.strings^
        self.context = move.context
        self.host = move.host
        self.output_dir = move.output_dir^
        self.reported = move.reported^
        self.watch = move.watch
        self.watcher = move.watcher^
        self.stream_block = move.stream_block
        self.stream = move.stream^

    def stopping(self) -> Bool:
        """Whether the stop flag is set."""
        return _flag(self.watch)[].load[ordering=Ordering.ACQUIRE]() != 0

    def take_files(mut self) -> List[String]:
        """The files reported since the last call, in order."""
        var out = List[String]()
        swap(out, self.reported[].files)
        return out^

    def refused(self) -> String:
        """Why morca refused a file the worker reported, or empty."""
        if len(self.reported[].missing) == 0:
            return String()
        return String(
            "morca: the Rust worker reported the file ",
            self.reported[].missing[0],
            ", which doesn't exist",
        )

    def last_error(self) -> String:
        """The stream's `get_last_error`, after `get_next` failed: the
        worker's own message."""
        if self.stream_block == 0:
            return String()
        var f = _get_int(self.stream_block, 16)
        if f == 0:
            return String()
        var msg = Pointer(to=f).unsafe_bitcast[_LastErrorFn]()[](
            self.stream_block
        )
        return _cstring(msg)

    def next_array(mut self, mut storage: Slots) raises -> Bool:
        """Pulls the stream's next `ArrowArray` into `storage` (10 slots),
        not imported (`morca.rust_step` moves it to liblake); False at the
        end of the stream. Raises if `get_next` fails, and `last_error`
        says why in the worker's words."""
        debug_assert(storage.n >= 10, "an ArrowArray takes 10 slots")
        var f = _get_int(self.stream_block, 8)
        var rc = Pointer(to=f).unsafe_bitcast[_GetNextFn]()[](
            self.stream_block, storage.addr
        )
        if rc != 0:
            raise Error(
                "the stream's get_next failed (", rc, "): ", self.last_error()
            )
        return storage[8] != 0

    def start(mut self) raises:
        """Calls `morca_worker_run` and takes the stream it returns; raises
        with the worker's message if it fails."""
        self.stream_block = _zeroed(40)
        var err = _zeroed(8)
        var rc = self.lib.run(self.context, 0, self.stream_block, err)
        if rc != 0:
            var msg_at = _get_int(err, 0)
            var msg = _cstring(msg_at)
            if msg_at != 0:
                self.lib.free(msg_at)
            _free(err)
            raise Error(
                "morca: the Rust worker ",
                self.lib.path,
                " failed: ",
                msg if msg else String("(no message)"),
            )
        _free(err)
        self.stream = ImportedStream(self.stream_block)

    def __deinit__(deinit self):
        var s = self.stream^
        if s:
            s.value().release()
        AtomicFlag.at(self.watch + 8).set()
        try:
            self.watcher.join()
        except e:
            print(
                "morca: the Rust worker's stop thread didn't join: ", e, sep=""
            )
        _remove_tree(self.output_dir)
        _free(self.stream_block)
        _free(self.context)
        _free(self.host)
        _free(self.watch)
        _ = self.strings^
        _ = self.reported^
        _ = self.lib^
