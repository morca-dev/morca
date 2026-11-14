"""The program's side of liblake: finding and loading the library, the host
block that lets it reach the step's `Ctx`, and batches crossing as Arrow C
Data. No iceberg here; `morca.tables` is built on this.

**Loading.** The library is opened the first time a table is used, in the
step or the dista task that uses it, never at program start (dista forks
its workers first, #135). It's found by `open_library` as `liblake.so`
(`liblake.dylib` on macOS) in `$CONDA_PREFIX/lib`, next to the executable
or in its `../lib` (the image's `/opt/morca/lib`), then on the dynamic
linker's path; `LAKE_LIB` names the file instead. It's opened
`RTLD_NODELETE` and its handle kept for the process's life, so the code a
symbol points to is never unmapped (LIB-TINS.md §5, item 2), and refused
unless `lake_abi_version()` is this wrapper's `ABI_VERSION`.

**`-D MORCA_LAKE_SOURCE=1`** compiles the library's code into the program
instead, calling the same functions directly: the old way of building, for
CI to compare against and to fall back on.
"""

from std.ffi import OwnedDLHandle, RTLD, _get_global
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.sys import CompilationTarget, is_defined

from arrow_mlake import AT_STRUCT, ArrayData, ArrowType
from arrow_mlake.carrow import ExportedArray, export_c
from parquet import RecordBatch

from morca.ctx import Ctx
from morca._internal.dlopen import open_library
from morca._lake.abi import (
    ABI_VERSION,
    HOST_SIZE,
    H_CHECK_DECLARED,
    H_COMMITS,
    H_COMMITTED,
    H_DECLARES_WRITE,
    H_ERROR,
    H_FENCE,
    H_LOG,
    H_MADE,
    H_PIN,
    H_REPLACES,
    H_SAME_RUN,
    H_STATE,
    H_SUMMARY,
    CheckDeclaredFn,
    CommittedFn,
    Enc,
    FenceFn,
    LogFn,
    MadeFn,
    NameFn,
    PinFn,
    SameRunFn,
    Slots,
    SummaryFn,
    TextFn,
    bytes_of,
    decode_map,
    put_int,
    text_of,
)

comptime SOURCE = is_defined["MORCA_LAKE_SOURCE"]()
"""Whether this build compiles the library's code in (see the module doc)."""

# The exports' types, as `morca._lake.lib` declares them.
comptime VersionFn = def() thin abi("C") -> UInt32
comptime FreeFn = def(Int) thin abi("C") -> None
comptime LoadFn = def(Int, Int, Int) thin abi("C") -> Int
comptime TableFn = def(Int, Int, Int, Int) thin abi("C") -> Int
comptime EnsureFn = def(
    Int, Int, Int, Int, Int, Int, Int, Int, Int, Int
) thin abi("C") -> Int
comptime CopyFn = def(Int) thin abi("C") -> Int
comptime StatusFn = def(Int, Int) thin abi("C") -> Int32
comptime MetaFn = def(Int, Int, Int) thin abi("C") -> Int32
comptime PinTableFn = def(Int, Int, Int, Int) thin abi("C") -> Int32
comptime ScanFn = def(Int, Int, Int, Int, Int) thin abi("C") -> Int32
comptime FindFn = def(Int, Int) thin abi("C") -> Int64
comptime AppendFn = def(Int, Int, Int, Int, Int, Int, Int) thin abi(
    "C"
) -> Int64
comptime AppendFilesFn = def(Int, Int, Int, Int, Int, Int) thin abi(
    "C"
) -> Int64
comptime CommitFn = def(Int, Int, Int, Int, Int, Int, Int) thin abi(
    "C"
) -> Int64
comptime WriteFilesFn = def(Int, Int, Int, Int, Int, Int) thin abi("C") -> Int32
comptime WriterNewFn = def(Int, Int) thin abi("C") -> Int
comptime WriterWriteFn = def(Int, Int, Int, Int, Int, Int, Int, Int) thin abi(
    "C"
) -> Int32
comptime WriterOptionsFn = def(Int, Int) thin abi("C") -> None
comptime WriterFinishFn = def(Int, Int, Int) thin abi("C") -> Int32
comptime Call4Fn = def(Int, Int, Int, Int) thin abi("C") -> Int32
"""A call of four integers and a status: `lake_reader_next`,
`lake_schema_fields`, `lake_table_exists`, `lake_delete_file`."""
comptime FilesInfoFn = def(Int, Int, Int, Int) thin abi("C") -> Int32
comptime ConcatFn = def(Int, Int, Int, Int, Int, Int) thin abi("C") -> Int32
comptime DecodeFn = def(Int, Int, Int, Int, Int) thin abi("C") -> Int32
comptime EmptyBatchFn = def(Int, Int, Int, Int, Int) thin abi("C") -> Int32
comptime ConcatBatchesFn = def(Int, Int, Int, Int, Int, Int) thin abi(
    "C"
) -> Int32


def library_file() -> String:
    """`LAKE_LIB`, else the library's file name on this platform."""
    var f = getenv("LAKE_LIB")
    if f:
        return f^
    comptime if CompilationTarget.is_macos():
        return "liblake.dylib"
    else:
        return "liblake.so"


def _sym[
    FT: TrivialRegisterPassable
](lib: OwnedDLHandle, name: String) raises -> FT:
    """A C function of the library: `get_symbol` and a bitcast, not
    `get_function` (LIB-TINS.md §5, item 5)."""
    var opt = lib.get_symbol[FT](name)
    if not opt:
        raise Error("lake: ", library_file(), " has no symbol ", name)
    var addr: Int = Int(opt.value())
    return Pointer(to=addr).unsafe_bitcast[FT]()[]


struct Api(Copyable, Movable):
    """liblake's functions, as pointers."""

    var free_text: FreeFn
    var load: LoadFn
    var load_dataset: LoadFn
    var table: TableFn
    var ensure_table: EnsureFn
    var table_free: FreeFn
    var table_copy: CopyFn
    var table_refresh: StatusFn
    var table_meta: MetaFn
    var pin: PinTableFn
    var scan: ScanFn
    var plan_files: ScanFn
    var count: ScanFn
    var empty_batch: EmptyBatchFn
    var concat: ConcatBatchesFn
    var find_commit: FindFn
    var append: AppendFn
    var append_files: AppendFilesFn
    var commit: CommitFn
    var write_files: WriteFilesFn
    var writer_new: WriterNewFn
    var writer_write: WriterWriteFn
    var writer_finish: WriterFinishFn
    var writer_free: FreeFn
    var files_info: FilesInfoFn
    var files_concat: ConcatFn
    var files_decode: DecodeFn
    var reader_open: ScanFn
    var reader_next: Call4Fn
    var reader_free: FreeFn
    var schema_fields: Call4Fn
    var table_exists: Call4Fn
    var read_file: ScanFn
    var delete_file: Call4Fn
    var writer_options: WriterOptionsFn
    var writer_close: StatusFn

    @staticmethod
    def from_library(lib: OwnedDLHandle) raises -> Self:
        return Self(
            free_text=_sym[FreeFn](lib, "lake_free_text"),
            load=_sym[LoadFn](lib, "lake_load"),
            load_dataset=_sym[LoadFn](lib, "lake_load_dataset"),
            table=_sym[TableFn](lib, "lake_table"),
            ensure_table=_sym[EnsureFn](lib, "lake_ensure_table"),
            table_free=_sym[FreeFn](lib, "lake_table_free"),
            table_copy=_sym[CopyFn](lib, "lake_table_copy"),
            table_refresh=_sym[StatusFn](lib, "lake_table_refresh"),
            table_meta=_sym[MetaFn](lib, "lake_table_meta"),
            pin=_sym[PinTableFn](lib, "lake_pin"),
            scan=_sym[ScanFn](lib, "lake_scan"),
            plan_files=_sym[ScanFn](lib, "lake_plan_files"),
            count=_sym[ScanFn](lib, "lake_count"),
            empty_batch=_sym[EmptyBatchFn](lib, "lake_empty_batch"),
            concat=_sym[ConcatBatchesFn](lib, "lake_concat"),
            find_commit=_sym[FindFn](lib, "lake_find_commit"),
            append=_sym[AppendFn](lib, "lake_append"),
            append_files=_sym[AppendFilesFn](lib, "lake_append_files"),
            commit=_sym[CommitFn](lib, "lake_commit"),
            write_files=_sym[WriteFilesFn](lib, "lake_write_files"),
            writer_new=_sym[WriterNewFn](lib, "lake_writer_new"),
            writer_write=_sym[WriterWriteFn](lib, "lake_writer_write"),
            writer_finish=_sym[WriterFinishFn](lib, "lake_writer_finish"),
            writer_free=_sym[FreeFn](lib, "lake_writer_free"),
            files_info=_sym[FilesInfoFn](lib, "lake_files_info"),
            files_concat=_sym[ConcatFn](lib, "lake_files_concat"),
            files_decode=_sym[DecodeFn](lib, "lake_files_decode"),
            reader_open=_sym[ScanFn](lib, "lake_reader_open"),
            reader_next=_sym[Call4Fn](lib, "lake_reader_next"),
            reader_free=_sym[FreeFn](lib, "lake_reader_free"),
            schema_fields=_sym[Call4Fn](lib, "lake_schema_fields"),
            table_exists=_sym[Call4Fn](lib, "lake_table_exists"),
            read_file=_sym[ScanFn](lib, "lake_read_file"),
            delete_file=_sym[Call4Fn](lib, "lake_delete_file"),
            writer_options=_sym[WriterOptionsFn](lib, "lake_writer_options"),
            writer_close=_sym[StatusFn](lib, "lake_writer_close"),
        )

    def __init__(
        out self,
        *,
        free_text: FreeFn,
        load: LoadFn,
        load_dataset: LoadFn,
        table: TableFn,
        ensure_table: EnsureFn,
        table_free: FreeFn,
        table_copy: CopyFn,
        table_refresh: StatusFn,
        table_meta: MetaFn,
        pin: PinTableFn,
        scan: ScanFn,
        plan_files: ScanFn,
        count: ScanFn,
        empty_batch: EmptyBatchFn,
        concat: ConcatBatchesFn,
        find_commit: FindFn,
        append: AppendFn,
        append_files: AppendFilesFn,
        commit: CommitFn,
        write_files: WriteFilesFn,
        writer_new: WriterNewFn,
        writer_write: WriterWriteFn,
        writer_finish: WriterFinishFn,
        writer_free: FreeFn,
        files_info: FilesInfoFn,
        files_concat: ConcatFn,
        files_decode: DecodeFn,
        reader_open: ScanFn,
        reader_next: Call4Fn,
        reader_free: FreeFn,
        schema_fields: Call4Fn,
        table_exists: Call4Fn,
        read_file: ScanFn,
        delete_file: Call4Fn,
        writer_options: WriterOptionsFn,
        writer_close: StatusFn,
    ):
        self.free_text = free_text
        self.load = load
        self.load_dataset = load_dataset
        self.table = table
        self.ensure_table = ensure_table
        self.table_free = table_free
        self.table_copy = table_copy
        self.table_refresh = table_refresh
        self.table_meta = table_meta
        self.pin = pin
        self.scan = scan
        self.plan_files = plan_files
        self.count = count
        self.empty_batch = empty_batch
        self.concat = concat
        self.find_commit = find_commit
        self.append = append
        self.append_files = append_files
        self.commit = commit
        self.write_files = write_files
        self.writer_new = writer_new
        self.writer_write = writer_write
        self.writer_finish = writer_finish
        self.writer_free = writer_free
        self.files_info = files_info
        self.files_concat = files_concat
        self.files_decode = files_decode
        self.reader_open = reader_open
        self.reader_next = reader_next
        self.reader_free = reader_free
        self.schema_fields = schema_fields
        self.table_exists = table_exists
        self.read_file = read_file
        self.delete_file = delete_file
        self.writer_options = writer_options
        self.writer_close = writer_close


struct _Loaded(Movable):
    """The process's one open library, kept for its life."""

    var lib: Optional[OwnedDLHandle]
    var api: Optional[Api]
    var error: String

    def __init__(out self):
        self.lib = None
        self.api = None
        self.error = String()
        comptime FLAGS = RTLD.NOW | RTLD.LOCAL | RTLD.NODELETE
        var file = library_file()
        try:
            var h: OwnedDLHandle
            if "/" in file:
                try:
                    h = OwnedDLHandle(file, FLAGS)
                except e:
                    raise Error("lake: can't load ", file, ": ", e)
            else:
                h = open_library("morca (liblake)", file, FLAGS)
            var v = _sym[VersionFn](h, "lake_abi_version")()
            if v != ABI_VERSION:
                raise Error(
                    "lake: ",
                    file,
                    " has ABI version ",
                    v,
                    ", and this morca speaks ",
                    ABI_VERSION,
                    (
                        ": the library and morca.tables come from different"
                        " morca releases (LAKE_LIB, CONDA_PREFIX)"
                    ),
                )
            self.api = Api.from_library(h)
            self.lib = h^
        except e:
            self.error = String(e)


comptime _Ptr = Pointer[NoneType, MutUntrackedOrigin]


def _init() -> Optional[_Ptr]:
    var p = unsafe_alloc[_Loaded](1)
    p.unsafe_write(_Loaded())
    return _Ptr(unsafe_from_address=Int(p))


def _keep(p: Optional[_Ptr]):
    """Kept for the process's life, like the library."""
    pass


def api() raises -> Api:
    """liblake's functions: loaded on first use (see the module doc)."""
    comptime if SOURCE:
        from morca._lake import lib

        return Api(
            free_text=lib.lake_free_text,
            load=lib.lake_load,
            load_dataset=lib.lake_load_dataset,
            table=lib.lake_table,
            ensure_table=lib.lake_ensure_table,
            table_free=lib.lake_table_free,
            table_copy=lib.lake_table_copy,
            table_refresh=lib.lake_table_refresh,
            table_meta=lib.lake_table_meta,
            pin=lib.lake_pin,
            scan=lib.lake_scan,
            plan_files=lib.lake_plan_files,
            count=lib.lake_count,
            empty_batch=lib.lake_empty_batch,
            concat=lib.lake_concat,
            find_commit=lib.lake_find_commit,
            append=lib.lake_append,
            append_files=lib.lake_append_files,
            commit=lib.lake_commit,
            write_files=lib.lake_write_files,
            writer_new=lib.lake_writer_new,
            writer_write=lib.lake_writer_write,
            writer_finish=lib.lake_writer_finish,
            writer_free=lib.lake_writer_free,
            files_info=lib.lake_files_info,
            files_concat=lib.lake_files_concat,
            files_decode=lib.lake_files_decode,
            reader_open=lib.lake_reader_open,
            reader_next=lib.lake_reader_next,
            reader_free=lib.lake_reader_free,
            schema_fields=lib.lake_schema_fields,
            table_exists=lib.lake_table_exists,
            read_file=lib.lake_read_file,
            delete_file=lib.lake_delete_file,
            writer_options=lib.lake_writer_options,
            writer_close=lib.lake_writer_close,
        )
    else:
        var p = _get_global["MORCA_LAKE_LIB", _init, _keep]()
        if not p:
            raise Error("lake: can't keep the library's state")
        ref l = Pointer[_Loaded, MutAnyOrigin](
            unsafe_from_address=Int(p.value())
        )[]
        if not l.api:
            raise Error(l.error)
        return l.api.value().copy()


def take_error(a: Api, err: Slots) -> Error:
    """The error the library wrote to `err`, freed."""
    var msg = text_of(err[0], err[1])
    a.free_text(err[0])
    return Error(msg^)


def take_bytes(a: Api, got: Slots) -> List[UInt8]:
    """The buffer the library wrote to `got`, copied and freed."""
    var b = bytes_of(got[0], got[1])
    a.free_text(got[0])
    return b^


# ── the host block: callbacks into the step's Ctx ───────────────────────────


struct _HostState(Movable):
    var ctx: Int
    var scratch: List[UInt8]
    var err: String

    def __init__(out self, ctx: Int):
        self.ctx = ctx
        self.scratch = List[UInt8]()
        self.err = String()


def _st(state: Int) -> Pointer[_HostState, MutAnyOrigin]:
    return Pointer[_HostState, MutAnyOrigin](unsafe_from_address=state)


def _ctx(state: Int) -> Pointer[Ctx, MutAnyOrigin]:
    return Pointer[Ctx, MutAnyOrigin](unsafe_from_address=_st(state)[].ctx)


def _hand(state: Int, var b: List[UInt8], out_n: Int) -> Int:
    """`b` kept in the host until its next callback, its address returned."""
    ref s = _st(state)[]
    s.scratch = b^
    put_int(out_n, 0, len(s.scratch))
    return Int(s.scratch.unsafe_ptr())


def _on_check_declared(
    state: Int, ds: Int, n: Int, write: Int
) abi("C") -> Int32:
    try:
        _ctx(state)[].check_declared(text_of(ds, n), write=write != 0)
        return 0
    except e:
        _st(state)[].err = String(e)
        return 1


def _on_pin(
    state: Int, loc: Int, n: Int, current: Int64, ds: Int, dn: Int, out_id: Int
) abi("C") -> Int32:
    try:
        var id = _ctx(state)[].pin(text_of(loc, n), current, text_of(ds, dn))
        put_int(out_id, 0, Int(id))
        return 0
    except e:
        _st(state)[].err = String(e)
        return 1


def _on_fence(state: Int) abi("C") -> Int32:
    try:
        _ctx(state)[].fence()
        return 0
    except e:
        _st(state)[].err = String(e)
        return 1


def _on_committed(
    state: Int, loc: Int, n: Int, id: Int64, ds: Int, dn: Int
) abi("C") -> Int32:
    try:
        _ctx(state)[].committed(text_of(loc, n), id, text_of(ds, dn))
        return 0
    except e:
        _st(state)[].err = String(e)
        return 1


def _on_summary(state: Int, loc: Int, n: Int, out_n: Int) abi("C") -> Int:
    var e = Enc()
    e.map(_ctx(state)[].summary(text_of(loc, n)))
    return _hand(state, e^.take(), out_n)


def _on_same_run(state: Int, t: Int, n: Int) abi("C") -> Int32:
    return 1 if _ctx(state)[].same_run(decode_map(t, n)) else 0


def _on_made(state: Int, loc: Int, n: Int, t: Int, tn: Int) abi("C") -> Int32:
    return 1 if _ctx(state)[].made(text_of(loc, n), decode_map(t, tn)) else 0


def _on_replaces(state: Int, ds: Int, n: Int) abi("C") -> Int32:
    return 1 if _ctx(state)[].replaces(text_of(ds, n)) else 0


def _on_declares_write(state: Int, ds: Int, n: Int) abi("C") -> Int32:
    return 1 if text_of(ds, n) in _ctx(state)[].declared_writes else 0


def _on_log(state: Int, msg: Int, n: Int) abi("C") -> None:
    _ctx(state)[].log(text_of(msg, n))


def _on_commits(state: Int, out_n: Int) abi("C") -> Int:
    var e = Enc()
    ref commits = _ctx(state)[].commits
    e.int(Int64(len(commits)))
    for c in commits:
        e.str(c.table)
        e.int(c.snapshot_id)
    return _hand(state, e^.take(), out_n)


def _on_error(state: Int, out_n: Int) abi("C") -> Int:
    ref s = _st(state)[]
    put_int(out_n, 0, s.err.byte_length())
    return Int(s.err.unsafe_ptr())


def _put_fn[FT: TrivialRegisterPassable](block: Int, at: Int, f: FT):
    Pointer[FT, MutUntrackedOrigin](unsafe_from_address=block + at)[] = f


struct HostBlock(Movable):
    """The host block for one call into the library, over `ctx`, whose
    address it keeps: the `Ctx` must outlive it, which a block made and
    dropped around one call does."""

    var addr: Int
    var state: Int

    def __init__(out self, ctx: Ctx):
        var st = unsafe_alloc[_HostState](1)
        st.unsafe_write(_HostState(Int(Pointer(to=ctx))))
        self.state = Int(st)
        self.addr = Int(unsafe_alloc[Int](HOST_SIZE // 8))
        var h = self.addr
        put_int(h, H_STATE, self.state)
        _put_fn[CheckDeclaredFn](h, H_CHECK_DECLARED, _on_check_declared)
        _put_fn[PinFn](h, H_PIN, _on_pin)
        _put_fn[FenceFn](h, H_FENCE, _on_fence)
        _put_fn[CommittedFn](h, H_COMMITTED, _on_committed)
        _put_fn[SummaryFn](h, H_SUMMARY, _on_summary)
        _put_fn[SameRunFn](h, H_SAME_RUN, _on_same_run)
        _put_fn[MadeFn](h, H_MADE, _on_made)
        _put_fn[NameFn](h, H_REPLACES, _on_replaces)
        _put_fn[NameFn](h, H_DECLARES_WRITE, _on_declares_write)
        _put_fn[LogFn](h, H_LOG, _on_log)
        _put_fn[TextFn](h, H_COMMITS, _on_commits)
        _put_fn[TextFn](h, H_ERROR, _on_error)

    def __deinit__(deinit self):
        var st = Pointer[_HostState, MutUntrackedOrigin](
            unsafe_from_address=self.state
        )
        st.unsafe_deinit_pointee()
        st.unsafe_free()
        Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=self.addr
        ).unsafe_free()


# ── batches as C structs ────────────────────────────────────────────────────


def export_batch(b: RecordBatch) raises -> ExportedArray:
    """A batch as one C struct array, its columns the struct's children."""
    var arena = b.arena.copy()
    var st = ArrayData(ArrowType(AT_STRUCT), String())
    st.nullable = False
    st.length = b.num_rows
    st.children = b.roots.copy()
    var root = arena.add(st^)
    return export_c(arena, root)


struct Exported(Movable):
    """Batches exported for one call, as two C arrays of the arrays' and the
    schemas' addresses. The call moves them to the library, which releases
    them (ABI 2): nothing here does, and the two lists stay alive across the
    call (LIB-TINS.md §5, item 4)."""

    var arrays: List[Int]
    var schemas: List[Int]

    def __init__(out self, batches: List[RecordBatch]) raises:
        self.arrays = List[Int]()
        self.schemas = List[Int]()
        for b in batches:
            var ex = export_batch(b)
            var pair = ex.into_raw()
            self.arrays.append(pair[0])
            self.schemas.append(pair[1])

    def n(self) -> Int:
        return len(self.arrays)

    def arrays_addr(self) -> Int:
        return Int(self.arrays.unsafe_ptr())

    def schemas_addr(self) -> Int:
        return Int(self.schemas.unsafe_ptr())
