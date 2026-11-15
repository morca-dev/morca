"""The library's side of a Rust step (#474): what `morca.rust_step` does with
the worker's output, here so a program with Rust steps compiles no iceberg.
`morca.rust_step` runs the worker and pulls its stream; a sink checks the
stream's schema, aligns and writes its batches, takes the files the worker
wrote itself (`morca._lake.rust_files`), and hands back the entries of both
for the step's one `append_files`.

**Exports.** A sink is the address of a heap `RustSink`:

- `lake_sink_new(h, name, dir, flush_bytes)`: a sink writing to table `h`,
  `name` the dataset for messages, `dir` the call's output directory; 0 on
  error;
- `lake_sink_schema(s, schema)`: checks the stream's schema, an
  `ArrowSchema` the caller keeps (borrowed until the sink is freed);
- `lake_sink_put(s, array)`: one `ArrowArray` of the stream, moved here
  as the C Data Interface moves one: the sink copies the struct into
  storage of its own and marks the caller's released, so the caller frees
  only its storage, and the sink releases the array when the last batch
  over it dies (as `ImportedStream.next` does);
- `lake_sink_take(s, path)`: a file the worker reported;
- `lake_sink_finish(s, out)`: what's pending written, then the entries
  (`encode_data_files` bytes), the rows streamed, and the worker's own files'
  count and rows, encoded, to `out`; frees the sink either way;
- `lake_sink_free(s)`.

Each fallible one takes `err` and returns 1 (0 for a handle) on error.
"""

from std.memory import ArcPointer
from std.memory.alloc import unsafe_alloc

from arrow_mlake import ForeignBuffers
from arrow_mlake.carrow import CArrowSchema
from arrow_mlake.carrow_import import _import_batch
from iceberg.catalog.filesystem import Table
from iceberg.manifest import encode_data_files
from iceberg.nested import ColumnTree, concat_tree, subtree_copy
from iceberg.schema import Schema
from iceberg.write import align_batch
from parquet import RecordBatch

from morca._lake.abi import Enc, give, give_text, text_of
from morca._lake.impl import FileWriter
from morca._lake.rust_files import WorkerFiles
from morca._lake.rust_schema import check_schema


struct RustSink(Movable):
    """The worker's output on its way to the table (see the module doc)."""

    var schema: Schema
    """The table's, when the sink was made."""
    var name: String
    var flush_bytes: Int
    var writer: FileWriter
    var own: WorkerFiles
    var stream_schema: Int
    """The stream's `ArrowSchema`, borrowed; 0 until `check`."""
    var streams: Bool
    """Whether the stream has columns: none says the worker only writes
    files."""
    var pending: List[ColumnTree]
    var pending_rows: Int
    var pending_bytes: Int
    var rows: Int

    def __init__(
        out self, table: Table, var name: String, var dir: String, flush: Int
    ) raises:
        self.schema = table.metadata.schema()
        self.writer = FileWriter(table)
        self.own = WorkerFiles(table, name.copy(), dir^)
        self.name = name^
        self.flush_bytes = flush
        self.stream_schema = 0
        self.streams = False
        self.pending = List[ColumnTree]()
        self.pending_rows = 0
        self.pending_bytes = 0
        self.rows = 0

    def check(mut self, stream_schema: Int) raises:
        """Checks the stream's schema against the table's, before anything
        is written."""
        self.stream_schema = stream_schema
        self.streams = _columns(stream_schema) > 0
        if self.streams:
            try:
                check_schema(stream_schema, self.schema)
            except e:
                raise Error(
                    "morca: the Rust worker's output doesn't fit ",
                    self.name,
                    ": ",
                    e,
                )

    def put(mut self, array: Int) raises:
        """Moves the stream's array at `array` here, aligns it to the table
        and writes what's pending once there's about `flush_bytes` of it."""
        var storage = _move_array(array)
        var owner = ArcPointer(ForeignBuffers(storage, True))
        if self.stream_schema == 0:
            raise Error("lake: a batch reached the sink before its schema")
        var batch = _import_batch(storage, self.stream_schema, owner)
        _ = owner^
        if batch.num_rows == 0:
            return
        if not self.streams:
            raise Error(
                "morca: the Rust worker streamed rows of no columns to ",
                self.name,
            )
        var cols: List[ColumnTree]
        try:
            cols = align_batch(batch, self.schema)
        except e:
            raise Error(
                "morca: a batch of the Rust worker doesn't fit ",
                self.name,
                ": ",
                e,
            )
        if self.pending_rows == 0:
            self.pending = cols^
        else:
            for k in range(len(self.pending)):
                concat_tree(
                    self.pending[k].arena,
                    self.pending[k].root,
                    cols[k].arena,
                    cols[k].root,
                )
        self.pending_rows += batch.num_rows
        self.pending_bytes += _bytes(batch)
        self.rows += batch.num_rows
        if self.pending_bytes >= self.flush_bytes:
            self._flush()

    def _flush(mut self) raises:
        if self.pending_rows == 0:
            return
        self.writer.put(_batch_of(self.pending, self.pending_rows))
        self.pending = List[ColumnTree]()
        self.pending_rows = 0
        self.pending_bytes = 0

    def finish(mut self) raises -> Enc:
        """Writes what's pending; the encoded result (see the module doc)."""
        self._flush()
        self.writer.close_files()
        var files = self.writer.files.files.copy()
        var n_own = len(self.own.files)
        for f in self.own.files:
            files.append(f.copy())
        var buf = List[UInt8]()
        encode_data_files(files, buf)
        var e = Enc()
        e.bytes(Span(buf))
        e.int(Int64(self.rows))
        e.int(Int64(n_own))
        e.int(Int64(self.own.rows))
        return e^


def _move_array(array: Int) -> Int:
    """The 80-byte `ArrowArray` at `array` moved into storage of this
    side's allocator, the original marked released (its `release` slot,
    at byte 64, zeroed)."""
    var p = unsafe_alloc[Int](10)
    for i in range(10):
        p[unsafe_offset=i] = Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=array + 8 * i
        )[]
    Pointer[Int, MutUntrackedOrigin](unsafe_from_address=array + 64)[] = 0
    return Int(p)


def _columns(schema: Int) -> Int:
    """How many columns the `ArrowSchema` at `schema` has."""
    return Int(
        Pointer[CArrowSchema, MutUntrackedOrigin](
            unsafe_from_address=schema
        )[].n_children
    )


def _bytes(batch: RecordBatch) -> Int:
    """About how many bytes `batch`'s buffers hold."""
    var n = 0
    for a in batch.arena.nodes:
        n += len(a.values) + len(a.validity)
        n += 4 * len(a.offsets) + 8 * len(a.large_offsets)
    return n


def _batch_of(cols: List[ColumnTree], rows: Int) raises -> RecordBatch:
    """Aligned columns as one batch, for the writer."""
    var b = RecordBatch()
    for c in cols:
        b.roots.append(subtree_copy(c.arena, c.root, b.arena))
    b.num_rows = rows
    return b^


# ── the exports (`morca._lake.lib` re-exports them) ─────────────────────────


def _sink(s: Int) -> Pointer[RustSink, MutAnyOrigin]:
    return Pointer[RustSink, MutAnyOrigin](unsafe_from_address=s)


def _fail(err: Int, e: Error):
    if err != 0:
        give_text(err, String(e))


def lake_sink_new(
    h: Int, name: Int, name_n: Int, dir: Int, dir_n: Int, flush: Int, err: Int
) abi("C") -> Int:
    """A sink for the table at handle `h`; 0 on error."""
    try:
        ref t = Pointer[Table, MutAnyOrigin](unsafe_from_address=h)[]
        var p = unsafe_alloc[RustSink](1)
        p.unsafe_write(
            RustSink(t, text_of(name, name_n), text_of(dir, dir_n), flush)
        )
        return Int(p)
    except e:
        _fail(err, e)
        return 0


def lake_sink_schema(s: Int, schema: Int, err: Int) abi("C") -> Int32:
    """Checks the stream's schema; 1 if it doesn't fit."""
    try:
        _sink(s)[].check(schema)
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_sink_put(s: Int, array: Int, err: Int) abi("C") -> Int32:
    """One array of the stream, moved here; 1 on error."""
    try:
        _sink(s)[].put(array)
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_sink_take(s: Int, path: Int, path_n: Int, err: Int) abi("C") -> Int32:
    """A file the worker reported; 1 if it's refused."""
    try:
        _sink(s)[].own.take(text_of(path, path_n))
        return 0
    except e:
        _fail(err, e)
        return 1


def lake_sink_finish(s: Int, out_block: Int, err: Int) abi("C") -> Int32:
    """The sink's result to `out_block`; 1 on error. Frees the sink."""
    var p = _sink(s)
    try:
        var e = p[].finish()
        give(out_block, Span(e.buf))
        p.unsafe_deinit_pointee()
        p.unsafe_free()
        return 0
    except e:
        p.unsafe_deinit_pointee()
        p.unsafe_free()
        _fail(err, e)
        return 1


def lake_sink_free(s: Int) abi("C"):
    if s != 0:
        var p = _sink(s)
        p.unsafe_deinit_pointee()
        p.unsafe_free()
