"""The program's side of liblake: finding and loading the library, and
batches crossing as Arrow C Data. No iceberg here, and no `Ctx`:
`morca._lake.calls` calls the library through this, and the host block over
a step's `Ctx` is the program's (`morca._internal.lakehost`).

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

from morca._common.dlopen import open_library
from morca._lake.abi import ABI_VERSION

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
`lake_schema_fields`, `lake_table_exists`, `lake_delete_file`,
`lake_expire`, `lake_data`, `lake_sink_take`."""
comptime FilesInfoFn = def(Int, Int, Int, Int) thin abi("C") -> Int32
comptime ConcatFn = def(Int, Int, Int, Int, Int, Int) thin abi("C") -> Int32
comptime DecodeFn = def(Int, Int, Int, Int, Int) thin abi("C") -> Int32
comptime EmptyBatchFn = def(Int, Int, Int, Int, Int) thin abi("C") -> Int32
comptime SinkNewFn = def(Int, Int, Int, Int, Int, Int, Int) thin abi("C") -> Int
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
    var expire: Call4Fn
    var data: Call4Fn
    var sink_new: SinkNewFn
    var sink_schema: MetaFn
    var sink_put: MetaFn
    var sink_take: Call4Fn
    var sink_finish: MetaFn
    var sink_free: FreeFn

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
            expire=_sym[Call4Fn](lib, "lake_expire"),
            data=_sym[Call4Fn](lib, "lake_data"),
            sink_new=_sym[SinkNewFn](lib, "lake_sink_new"),
            sink_schema=_sym[MetaFn](lib, "lake_sink_schema"),
            sink_put=_sym[MetaFn](lib, "lake_sink_put"),
            sink_take=_sym[Call4Fn](lib, "lake_sink_take"),
            sink_finish=_sym[MetaFn](lib, "lake_sink_finish"),
            sink_free=_sym[FreeFn](lib, "lake_sink_free"),
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
        expire: Call4Fn,
        data: Call4Fn,
        sink_new: SinkNewFn,
        sink_schema: MetaFn,
        sink_put: MetaFn,
        sink_take: Call4Fn,
        sink_finish: MetaFn,
        sink_free: FreeFn,
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
        self.expire = expire
        self.data = data
        self.sink_new = sink_new
        self.sink_schema = sink_schema
        self.sink_put = sink_put
        self.sink_take = sink_take
        self.sink_finish = sink_finish
        self.sink_free = sink_free


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
            expire=lib.lake_expire,
            data=lib.lake_data,
            sink_new=lib.lake_sink_new,
            sink_schema=lib.lake_sink_schema,
            sink_put=lib.lake_sink_put,
            sink_take=lib.lake_sink_take,
            sink_finish=lib.lake_sink_finish,
            sink_free=lib.lake_sink_free,
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
    them (ABI 2): nothing here does. Pass it to the call
    (`morca._lake.calls`) as an argument, which keeps the two lists alive
    across the call (LIB-TINS.md §5, item 4)."""

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
