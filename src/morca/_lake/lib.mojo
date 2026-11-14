"""The lake lib-tin's library, liblake (#454): morca's Iceberg tables behind
a C ABI. These `abi("C")` functions are its exports: `liblake.mojo`, the
library's root, exports each under its name (scripts/build-liblake.sh), and
the wrapper calls them directly in a build with `-D MORCA_LAKE_SOURCE=1`,
which compiles the library into the program instead (the fallback, and
what CI compares against). They carry no `@export` here: that would compile
them into every program that imports the module.

**Handles.** A table is the address of a heap `Table` (`lake_table_free`),
a file writer of a heap `FileWriter`, a batch reader of a heap
`BatchReader` (`lake_reader_free`). Written files cross as bytes, iceberg's
`encode_data_files`, which is also how a dista task carries them.

The ABI (`morca._lake.abi`) says how text, maps, out blocks, errors and the
host block cross; each function's doc says what its failure value is.
"""

from std.memory import bitcast
from std.memory.alloc import unsafe_alloc

from arrow_mlake import AT_STRUCT, ArrayArena, ArrayData, ArrowType
from arrow_mlake.carrow import ExportedArray, export_c
from arrow_mlake.carrow_import import ImportedArray
from arrow_mlake.carrow_stream import export_stream_of
from iceberg.catalog.filesystem import Table
from iceberg.commit import FileChanges
from iceberg.io import FileIO
from iceberg.json import parse_json
from iceberg.manifest import DataFile, decode_data_files, encode_data_files
from iceberg.nested import concat_tree, empty_tree
from iceberg.scan import BatchReader, TableScan
from iceberg.schema import Schema
from iceberg.transforms import PartitionSpec
from iceberg.values import Datum
from iceberg.write import WriteOptions, _partition_key
from parquet import ParquetReader, RecordBatch
from parquet_full import AllCodecs

from morca._lake.abi import (
    ABI_VERSION,
    MODE_APPEND,
    MODE_BY_STEP,
    MODE_REPLACE,
    SNAP_CURRENT,
    SNAP_NONE,
    Dec,
    Enc,
    bytes_of,
    free_text,
    give,
    give_text,
    get_int,
    put_int,
    text_of,
)
from morca._lake.host import Host
from morca._lake.names import dataset_of
import morca._lake.impl as tables


# ── handles, errors, batches ────────────────────────────────────────────────


def _new_table(var t: Table) -> Int:
    var p = unsafe_alloc[Table](1)
    p.unsafe_write(t^)
    return Int(p)


def _table(h: Int) -> Pointer[Table, MutAnyOrigin]:
    return Pointer[Table, MutAnyOrigin](unsafe_from_address=h)


def _writer(h: Int) -> Pointer[tables.FileWriter, MutAnyOrigin]:
    return Pointer[tables.FileWriter, MutAnyOrigin](unsafe_from_address=h)


def _fail(err: Int, e: Error):
    if err != 0:
        give_text(err, String(e))


def _batches(n: Int, arrays: Int, schemas: Int) raises -> List[RecordBatch]:
    """The `n` C batches the caller moved here, imported without copying
    (arrow-mlake-mojo 0.3.0): their buffers stay where the caller's export
    put them, and are released when the last batch over them dies. Their
    columns carry `PARQUET:field_id`, which the writer matches by.

    All `n` are taken before any is read, so on an error none is left for
    the caller to release.
    """
    var owned = List[ImportedArray]()
    for i in range(n):
        owned.append(
            ImportedArray(get_int(arrays, 8 * i), get_int(schemas, 8 * i))
        )
    var out = List[RecordBatch]()
    owned.reverse()
    while len(owned) > 0:
        out.append(owned.pop().into_batch())
    return out^


def _export_batch(var b: RecordBatch) raises -> ExportedArray:
    """A batch as one struct array, as a stream carries it: its arena gets
    the struct node, and the export copies the buffers once."""
    var st = ArrayData(ArrowType(AT_STRUCT), String())
    st.nullable = False
    st.length = b.num_rows
    st.children = b.roots.copy()
    var root = b.arena.add(st^)
    return export_c(b.arena, root)


def _export_all(var batches: List[RecordBatch]) raises -> List[ExportedArray]:
    """`batches` exported in order, each given up as it goes."""
    var out = List[ExportedArray]()
    batches.reverse()
    while len(batches) > 0:
        out.append(_export_batch(batches.pop()))
    return out^


def _files_of(addr: Int, n: Int) raises -> List[DataFile]:
    if n <= 0:
        return List[DataFile]()
    var buf = bytes_of(addr, n)
    var pos = 0
    return decode_data_files(Span(buf), pos)


def _partition_values(mut e: Enc, values: List[Datum]):
    """A file's partition values, as `morca.tables.PartitionValue` reads
    them: valid, kind, i, f's bits, s, b."""
    e.int(Int64(len(values)))
    for d in values:
        e.bool(d.valid)
        e.int(Int64(d.kind))
        e.int(d.i)
        e.int(bitcast[DType.int64](d.f))
        e.str(d.s)
        e.bytes(Span(d.b))


def _reader(h: Int) -> Pointer[BatchReader, MutAnyOrigin]:
    return Pointer[BatchReader, MutAnyOrigin](unsafe_from_address=h)


def _options(o: WriteOptions) -> Enc:
    """`WriteOptions`, as `morca.tables.WriteOptions` reads them."""
    var e = Enc()
    e.str(o.codec)
    e.int(Int64(o.row_group_rows))
    e.int(Int64(o.page_size))
    e.int(Int64(o.compression_level))
    e.bool(o.use_dictionary)
    e.int(Int64(o.truncate))
    e.int(Int64(o.num_workers))
    return e^


def _options_of(addr: Int, n: Int) raises -> WriteOptions:
    var d = Dec(addr, n)
    var o = WriteOptions()
    o.codec = d.str()
    o.row_group_rows = Int(d.int())
    o.page_size = Int(d.int())
    o.compression_level = Int(d.int())
    o.use_dictionary = d.bool()
    o.truncate = Int(d.int())
    o.num_workers = Int(d.int())
    return o^


def _give_files(out_block: Int, files: List[DataFile]):
    var buf = List[UInt8]()
    encode_data_files(files, buf)
    give(out_block, Span(buf))


struct _ScanOpts(Movable):
    var snapshot: Int64
    var filter: String
    var columns: List[String]
    var paths: List[String]

    def __init__(out self, addr: Int, n: Int) raises:
        var d = Dec(addr, n)
        self.snapshot = d.int()
        self.filter = d.str()
        self.columns = d.strs()
        self.paths = d.strs()


def _scan_of(t: Table, o: _ScanOpts) raises -> TableScan:
    var sc = t.scan()
    if o.snapshot >= 0:
        sc = sc.use_snapshot(o.snapshot)
    if o.filter:
        sc = sc.filter(o.filter)
    if len(o.columns) > 0:
        sc = sc.select(o.columns.copy())
    return sc^


# ── version ─────────────────────────────────────────────────────────────────


def lake_abi_version() abi("C") -> UInt32:
    return ABI_VERSION


def lake_free_text(p: Int) abi("C"):
    free_text(p)


# ── tables ──────────────────────────────────────────────────────────────────


def lake_load(loc: Int, n: Int, err: Int) abi("C") -> Int:
    """The table at a location, local or in object storage; 0 on error."""
    try:
        var place = text_of(loc, n)
        if "://" in place and not place.startswith("file://"):
            return _new_table(Table.load(place, FileIO()))
        return _new_table(
            Table.load_local(String(place.removeprefix("file://")))
        )
    except e:
        _fail(err, e)
        return 0


def lake_load_dataset(ds: Int, n: Int, err: Int) abi("C") -> Int:
    """`load_dataset`: no step, nothing checked; 0 on error."""
    try:
        return _new_table(tables.load_dataset(text_of(ds, n)))
    except e:
        _fail(err, e)
        return 0


def lake_table(host: Int, ds: Int, n: Int, err: Int) abi("C") -> Int:
    """`table`: a dataset the step declared; 0 on error."""
    try:
        var ctx = Host(host)
        return _new_table(tables.table(ctx, text_of(ds, n)))
    except e:
        _fail(err, e)
        return 0


def lake_ensure_table(
    host: Int,
    ds: Int,
    ds_n: Int,
    schema: Int,
    schema_n: Int,
    spec: Int,
    spec_n: Int,
    props: Int,
    props_n: Int,
    err: Int,
) abi("C") -> Int:
    """`ensure_table`, with the schema and spec as Iceberg JSON (an empty
    spec is unpartitioned) and the properties an encoded map; 0 on error."""
    try:
        var ctx = Host(host)
        var s = Schema.parse(text_of(schema, schema_n))
        var p = PartitionSpec.unpartitioned()
        var spec_text = text_of(spec, spec_n)
        if spec_text:
            var doc = parse_json(spec_text)
            p = PartitionSpec.from_json(doc, doc.root)
        var d = Dec(props, props_n)
        var properties = d.map() if props_n > 0 else Dict[String, String]()
        return _new_table(
            tables.ensure_table(ctx, text_of(ds, ds_n), s, p, properties)
        )
    except e:
        _fail(err, e)
        return 0


def lake_table_free(h: Int) abi("C"):
    if h != 0:
        var p = _table(h)
        p.unsafe_deinit_pointee()
        p.unsafe_free()


def lake_table_copy(h: Int) abi("C") -> Int:
    return _new_table(_table(h)[].copy())


def lake_table_refresh(h: Int, err: Int) abi("C") -> Int32:
    """`Table.refresh`; 1 on error."""
    try:
        _table(h)[].refresh()
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_table_meta(h: Int, out_block: Int, err: Int) abi("C") -> Int32:
    """What `morca.tables.TableMeta` mirrors of the table's metadata, encoded
    in its order; 1 on error."""
    try:
        ref t = _table(h)[]
        ref m = t.metadata
        var e = Enc()
        e.str(m.location)
        e.str(t.metadata_location)
        e.int(Int64(m.format_version))
        e.str(m.table_uuid)
        e.bool(m.has_current_snapshot)
        e.int(m.current_snapshot_id)
        e.int(Int64(m.current_schema_id))
        e.int(Int64(m.default_spec_id))
        e.int(Int64(m.default_sort_order_id))
        e.int(m.last_updated_ms)
        e.int(m.last_sequence_number)
        e.map(m.properties)
        e.int(Int64(len(m.schemas)))
        for s in m.schemas:
            e.int(Int64(s.schema_id))
            e.str(s.to_json())
        e.int(Int64(len(m.partition_specs)))
        for p in m.partition_specs:
            e.int(Int64(p.spec_id))
            e.str(p.to_json())
        e.int(Int64(len(m.snapshots)))
        for s in m.snapshots:
            e.int(s.snapshot_id)
            e.bool(s.has_parent)
            e.int(s.parent_snapshot_id)
            e.int(s.sequence_number)
            e.int(s.timestamp_ms)
            e.str(s.manifest_list)
            e.int(Int64(s.schema_id) if s.has_schema_id else -1)
            e.map(s.summary)
        e.int(Int64(len(m.metadata_log)))
        for l in m.metadata_log:
            e.int(l.timestamp_ms)
            e.str(l.metadata_file)
        give(out_block, Span(e.buf))
        return 0
    except e:
        _fail(err, e)
        return 1


# ── reading ─────────────────────────────────────────────────────────────────


def lake_pin(host: Int, h: Int, out_id: Int, err: Int) abi("C") -> Int32:
    """What `scan(ctx, table)` reads: the step's pinned snapshot of the table,
    to `out_id`, or `SNAP_NONE` when it pinned the table empty; 1 on error."""
    try:
        var ctx = Host(host)
        ref m = _table(h)[].metadata
        var dataset = dataset_of(m.location)
        ctx.check_declared(dataset, write=False)
        var current = m.current_snapshot_id if m.has_current_snapshot else -1
        var id = ctx.pin(m.location, current, dataset)
        put_int(out_id, 0, Int(id) if id >= 0 else Int(SNAP_NONE))
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_scan(
    h: Int, opts: Int, opts_n: Int, out_stream: Int, err: Int
) abi("C") -> Int32:
    """The scan's rows as an `ArrowArrayStream`, its address to
    `out_stream` (0 when there are no batches); 1 on error."""
    try:
        var o = _ScanOpts(opts, opts_n)
        put_int(out_stream, 0, 0)
        if o.snapshot == SNAP_NONE:
            return 0
        ref t = _table(h)[]
        if not t.metadata.has_current_snapshot and o.snapshot < 0:
            return 0
        var sc = _scan_of(t, o)
        var batches: List[RecordBatch]
        if len(o.paths) > 0:
            batches = sc.to_batches_for_paths(o.paths)
        else:
            batches = sc.to_batches()
        var exported = _export_all(batches^)
        if len(exported) > 0:
            put_int(out_stream, 0, export_stream_of(exported^))
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_plan_files(
    h: Int, opts: Int, opts_n: Int, out_block: Int, err: Int
) abi("C") -> Int32:
    """The scan's file tasks, encoded as `morca.tables.FileScanTask` reads
    them; 1 on error."""
    try:
        var o = _ScanOpts(opts, opts_n)
        var e = Enc()
        ref t = _table(h)[]
        if o.snapshot == SNAP_NONE or (
            not t.metadata.has_current_snapshot and o.snapshot < 0
        ):
            e.int(0)
            give(out_block, Span(e.buf))
            return 0
        var tasks = _scan_of(t, o).plan_files()
        e.int(Int64(len(tasks)))
        for task in tasks:
            ref f = task.data_file
            e.str(f.file_path)
            e.int(Int64(f.content))
            e.int(f.record_count)
            e.int(f.file_size_in_bytes)
            e.int(Int64(task.spec_id))
            e.str(_partition_key(f.partition))
            _partition_values(e, f.partition)
            e.str(task.residual)
            e.int(task.start)
            e.int(task.length)
            e.int(Int64(len(task.delete_files)))
        give(out_block, Span(e.buf))
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_count(
    h: Int, opts: Int, opts_n: Int, out_n: Int, err: Int
) abi("C") -> Int32:
    """How many rows the scan returns, to `out_n`; 1 on error."""
    try:
        var o = _ScanOpts(opts, opts_n)
        ref t = _table(h)[]
        put_int(out_n, 0, 0)
        if o.snapshot == SNAP_NONE or (
            not t.metadata.has_current_snapshot and o.snapshot < 0
        ):
            return 0
        put_int(out_n, 0, Int(_scan_of(t, o).count()))
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_empty_batch(
    schema: Int, schema_n: Int, out_array: Int, out_schema: Int, err: Int
) abi("C") -> Int32:
    """A zero-row batch of an Iceberg schema (JSON), every column at the
    Arrow type iceberg writes it with, as one C struct array: what the
    wrapper's `BatchBuilder` fills. 1 on error."""
    try:
        var s = Schema.parse(text_of(schema, schema_n))
        var b = RecordBatch()
        for f in s.columns():
            b.roots.append(
                empty_tree(
                    b.arena, s.store, f.type, f.name, f.id, not f.required
                )
            )
        var ex = _export_batch(b^)
        var pair = ex.into_raw()
        put_int(out_array, 0, pair[0])
        put_int(out_schema, 0, pair[1])
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_concat(
    n: Int, arrays: Int, schemas: Int, out_array: Int, out_schema: Int, err: Int
) abi("C") -> Int32:
    """`n` C batches moved here with the same columns as one, exported to the
    out slots as `lake_empty_batch` does; 1 on error."""
    try:
        var out = RecordBatch()
        var bs = _batches(n, arrays, schemas)
        for i in range(len(bs)):
            if i == 0:
                out = bs[0].copy()
                continue
            ref b = bs[i]
            if b.num_columns() != out.num_columns():
                raise Error(
                    "lake: batch ",
                    i,
                    " has ",
                    b.num_columns(),
                    " columns, the first ",
                    out.num_columns(),
                )
            for c in range(out.num_columns()):
                concat_tree(out.arena, out.roots[c], b.arena, b.roots[c])
            out.num_rows += b.num_rows
        var ex = _export_batch(out^)
        var pair = ex.into_raw()
        put_int(out_array, 0, pair[0])
        put_int(out_schema, 0, pair[1])
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_reader_open(
    h: Int, opts: Int, opts_n: Int, out_reader: Int, err: Int
) abi("C") -> Int32:
    """`TableScan.to_batch_reader`: a reader of the scan's batches, planned
    here, its handle to `out_reader` (0 when the scan has nothing to read);
    1 on error."""
    try:
        var o = _ScanOpts(opts, opts_n)
        put_int(out_reader, 0, 0)
        if o.snapshot == SNAP_NONE:
            return 0
        ref t = _table(h)[]
        if not t.metadata.has_current_snapshot and o.snapshot < 0:
            return 0
        var r = _scan_of(t, o).to_batch_reader()
        var p = unsafe_alloc[BatchReader](1)
        p.unsafe_write(r^)
        put_int(out_reader, 0, Int(p))
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_reader_next(
    r: Int, out_array: Int, out_schema: Int, err: Int
) abi("C") -> Int32:
    """The reader's next batch, as one C struct array to the out slots
    (both 0 once the scan is done); 1 on error."""
    try:
        put_int(out_array, 0, 0)
        put_int(out_schema, 0, 0)
        var b = _reader(r)[].next_batch()
        if not b:
            return 0
        var ex = _export_batch(b.take())
        var pair = ex.into_raw()
        put_int(out_array, 0, pair[0])
        put_int(out_schema, 0, pair[1])
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_reader_free(r: Int) abi("C"):
    if r != 0:
        var p = _reader(r)
        p.unsafe_deinit_pointee()
        p.unsafe_free()


def lake_schema_fields(
    schema: Int, schema_n: Int, out_block: Int, err: Int
) abi("C") -> Int32:
    """Every field of an Iceberg schema (JSON), nested ones included, as
    `morca.tables.SchemaField` reads them: id, dotted name, type JSON,
    required, the parent's id (-1 for a top-level column). 1 on error."""
    try:
        var s = Schema.parse(text_of(schema, schema_n))
        var e = Enc()
        e.int(Int64(len(s.flat)))
        for f in s.flat:
            e.int(Int64(f.id))
            e.str(f.name)
            e.str(s.store.type_json(f.type))
            e.bool(f.required)
            e.int(Int64(s.flat[f.parent].id) if f.parent >= 0 else -1)
        give(out_block, Span(e.buf))
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_table_exists(
    ds: Int, n: Int, out_yes: Int, err: Int
) abi("C") -> Int32:
    """Whether the warehouse has the dataset's table, 1 or 0 to `out_yes`;
    1 on error (no warehouse)."""
    try:
        put_int(out_yes, 0, 1 if tables.table_exists(text_of(ds, n)) else 0)
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_read_file(
    h: Int, path: Int, path_n: Int, out_stream: Int, err: Int
) abi("C") -> Int32:
    """The rows of one Parquet file, read through the table's IO (a file
    written and not yet committed, which no scan sees), as an
    `ArrowArrayStream` to `out_stream` (0 when it has no batches); 1 on
    error."""
    try:
        put_int(out_stream, 0, 0)
        ref t = _table(h)[]
        var reader = ParquetReader[AllCodecs](
            t.io.read_all(text_of(path, path_n))
        )
        var got = reader.read_table()
        var batches = List[RecordBatch]()
        for ref b in got.batches:
            batches.append(b.copy())
        var exported = _export_all(batches^)
        if len(exported) > 0:
            put_int(out_stream, 0, export_stream_of(exported^))
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_delete_file(
    h: Int, path: Int, path_n: Int, err: Int
) abi("C") -> Int32:
    """Deletes a file through the table's IO; 1 on error."""
    try:
        _table(h)[].io.delete(text_of(path, path_n))
        return 0
    except e:
        _fail(err, e)
        return 1


# ── writing ─────────────────────────────────────────────────────────────────


def lake_find_commit(host: Int, h: Int) abi("C") -> Int64:
    return tables.find_commit(Host(host), _table(h)[])


def lake_append(
    host: Int, h: Int, n: Int, arrays: Int, schemas: Int, mode: Int, err: Int
) abi("C") -> Int64:
    """`append` (`MODE_BY_STEP`), or `replace_partitions` (`MODE_REPLACE`),
    of `n` C batches moved here. With no host, iceberg's own `Table.append`,
    which nothing checks or records. -2 on error."""
    try:
        ref t = _table(h)[]
        var bs = _batches(n, arrays, schemas)
        if host == 0:
            return t.append(bs)
        var ctx = Host(host)
        if mode == MODE_REPLACE:
            return tables.replace_partitions(ctx, t, bs)
        if mode == MODE_APPEND:
            return tables._append(ctx, t, bs, False)
        return tables.append(ctx, t, bs)
    except e:
        _fail(err, e)
        return -2


def lake_append_files(
    host: Int, h: Int, files: Int, files_n: Int, mode: Int, err: Int
) abi("C") -> Int64:
    """`append_files` (`MODE_BY_STEP`) or `replace_partition_files`
    (`MODE_REPLACE`) of encoded entries; -2 on error."""
    try:
        var ctx = Host(host)
        ref t = _table(h)[]
        var fs = _files_of(files, files_n)
        if mode == MODE_REPLACE:
            return tables.replace_partition_files(ctx, t, fs)
        if mode == MODE_APPEND:
            return tables._append_files(ctx, t, fs, False)
        return tables.append_files(ctx, t, fs)
    except e:
        _fail(err, e)
        return -2


def lake_commit(
    host: Int,
    h: Int,
    op: Int,
    op_n: Int,
    changes: Int,
    changes_n: Int,
    err: Int,
) abi("C") -> Int64:
    """`commit` of `FileChanges` encoded as added data files, added delete
    files (each `encode_data_files` bytes) and the paths removed; -2 on
    error."""
    try:
        var ctx = Host(host)
        ref t = _table(h)[]
        var d = Dec(changes, changes_n)
        var fc = FileChanges()
        var data = d.bytes()
        var deletes = d.bytes()
        fc.added_data = _files_of(Int(data.unsafe_ptr()), len(data))
        fc.added_deletes = _files_of(Int(deletes.unsafe_ptr()), len(deletes))
        fc.removed = d.strs()
        return tables.commit(ctx, t, text_of(op, op_n), fc^)
    except e:
        _fail(err, e)
        return -2


def lake_write_files(
    h: Int, n: Int, arrays: Int, schemas: Int, out_block: Int, err: Int
) abi("C") -> Int32:
    """`write_files` of `n` C batches moved here: the entries, encoded, to
    `out_block`; 1 on error."""
    try:
        ref t = _table(h)[]
        var bs = _batches(n, arrays, schemas)
        _give_files(out_block, tables.write_files(t, bs).files)
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_writer_new(h: Int, err: Int) abi("C") -> Int:
    """A `FileWriter` for the table; 0 on error."""
    try:
        var p = unsafe_alloc[tables.FileWriter](1)
        p.unsafe_write(tables.FileWriter(_table(h)[]))
        return Int(p)
    except e:
        _fail(err, e)
        return 0


def lake_writer_options(w: Int, out_block: Int) abi("C"):
    """The writer's `WriteOptions`, encoded, to `out_block`."""
    var e = _options(_writer(w)[].options)
    give(out_block, Span(e.buf))


def lake_writer_write(
    w: Int,
    opts: Int,
    opts_n: Int,
    n: Int,
    arrays: Int,
    schemas: Int,
    row_group: Int,
    err: Int,
) abi("C") -> Int32:
    """`FileWriter.write` of `n` C batches moved here, or with `row_group`
    1, `write_row_group` of each; with `opts_n` > 0 the writer's options
    are those first. 1 on error."""
    try:
        ref fw = _writer(w)[]
        var bs = _batches(n, arrays, schemas)
        if opts_n > 0:
            fw.options = _options_of(opts, opts_n)
        if row_group != 0:
            for ref b in bs:
                fw.write_row_group(b)
        else:
            fw.write(bs)
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_writer_close(w: Int, err: Int) abi("C") -> Int32:
    """`FileWriter.close_files`; 1 on error."""
    try:
        _writer(w)[].close_files()
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_writer_finish(w: Int, out_block: Int, err: Int) abi("C") -> Int32:
    """The writer's entries, its open files ended first, encoded, to
    `out_block`; 1 on error. Frees the writer either way."""
    var p = _writer(w)
    try:
        p[].close_files()
    except e:
        p.unsafe_deinit_pointee()
        p.unsafe_free()
        _fail(err, e)
        return 1
    var files = p[].files.files.copy()
    p.unsafe_deinit_pointee()
    p.unsafe_free()
    _give_files(out_block, files)
    return 0


def lake_writer_free(w: Int) abi("C"):
    if w != 0:
        var p = _writer(w)
        p.unsafe_deinit_pointee()
        p.unsafe_free()


# ── written files ───────────────────────────────────────────────────────────


def lake_files_info(
    files: Int, files_n: Int, out_block: Int, err: Int
) abi("C") -> Int32:
    """What `morca.tables.DataFile` shows of each entry; 1 on error."""
    try:
        var fs = _files_of(files, files_n)
        var e = Enc()
        e.int(Int64(len(fs)))
        for f in fs:
            e.str(f.file_path)
            e.int(Int64(f.content))
            e.int(f.record_count)
            e.int(f.file_size_in_bytes)
            e.str(_partition_key(f.partition))
            _partition_values(e, f.partition)
        give(out_block, Span(e.buf))
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_files_concat(
    a: Int, a_n: Int, b: Int, b_n: Int, out_block: Int, err: Int
) abi("C") -> Int32:
    """The entries of two encodings as one; 1 on error."""
    try:
        var fs = _files_of(a, a_n)
        for f in _files_of(b, b_n):
            fs.append(f.copy())
        _give_files(out_block, fs)
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_files_decode(
    buf: Int, n: Int, pos: Int, out_block: Int, err: Int
) abi("C") -> Int32:
    """Reads one encoding of entries starting at the offset in the slot
    `pos`, which it advances, and returns it alone (`DataFiles.decode`);
    1 on error."""
    try:
        var bytes = bytes_of(buf, n)
        var at = get_int(pos, 0)
        var start = at
        _ = decode_data_files(Span(bytes), at)
        put_int(pos, 0, at)
        give(out_block, Span(bytes)[start:at])
        return 0
    except e:
        _fail(err, e)
        return 1
