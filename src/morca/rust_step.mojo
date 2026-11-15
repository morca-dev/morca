"""Steps written in Rust: a worker library, called from a step of a Mojo
proxy pipeline, whose record batches morca writes into the step's table,
and whose own Parquet files it commits with them.

```mojo
from morca import Ctx, Mapped, Month, Pipeline, Step, morca_main
from morca.rust_step import rust_step
from morca.tables import Schema, ensure_table

comptime NUMBERS = "demo.numbers"
comptime SCHEMA = "schemas/numbers.json"  # read by the worker too

def numbers(mut ctx: Ctx, m: Month) raises -> Int64:
    var schema = Schema.parse(open(SCHEMA, "r").read())
    var t = ensure_table(ctx, NUMBERS, schema)
    return rust_step(ctx, "numbers_worker", t, params='{"rows": 100}').snapshot_id

comptime Numbers = Step["numbers", Month, Int64, numbers, Mapped, writes=[NUMBERS]]
```

`rust_step` runs the worker once, in this process (docs/rust-workers.md is
the contract, and the `morca-worker` crate its Rust side):

1. **A retry that finds its commit** returns it: if an earlier attempt of
   the step committed to the table in this run (`find_commit`), the worker
   doesn't run again, and nothing is written.
2. It **loads the library** now, not at program start, and refuses one
   built for another ABI version. `library` is a path, a file name
   (`libx.so`), or a bare name `x`, found as `libx.so` (`libx.dylib` on
   macOS) in `$CONDA_PREFIX/lib`, next to the executable or in its
   `../lib`, then on the dynamic linker's path.
3. It **calls the worker** with the step's context: pipeline, step,
   partition, run, attempt, the registry hash, `params` (a JSON object for
   the worker), `step_version`, and the run's secrets. The worker's log
   lines, progress and metrics go to the step's log.
4. It **checks the stream's schema** against the table's before writing
   anything: every column of the table must be in it, matched by name at
   any depth, and no other; a required column mustn't be nullable; a type
   must be the table's or one Iceberg widens to it (Int8–Int32 to `int`,
   any integer to `long`, Float32 to `double`, a large string or binary,
   a decimal of the same scale and no more precision, a timestamp in
   another unit). The error names the column. A nested column is checked
   for its kind here, and to the leaf as each batch is aligned.
5. It **writes Parquet as batches arrive**, each aligned to the table's
   schema, gathering small batches into files of about `flush_bytes`, so
   the output never sits in memory whole and the worker produces at the
   rate the writer consumes.
6. It **takes the worker's own Parquet files**, if it writes any: files
   the worker wrote into the directory the context names, and reported
   (`ctx.add_file` in the crate). When `run` returns and after each batch,
   morca checks each reported file against the table (every column with
   the table's field id and a type iceberg reads as the table's, and its
   rows in one partition, from its statistics), naming the column, uploads
   it under the table's `data/` with the table's `FileIO`, and keeps its
   entry. A worker may stream, write files, or both; a stream of no
   columns says it only writes files. A file reported that isn't there
   fails the attempt.
7. At the end of the stream it **commits once**: `append_files`, which is
   `replace_partition_files` for a dataset the step declared in
   `replaces=`. A step's commits keep their numbers, so a crash after this
   commit is recognised by the retry (1). The worker's files and those
   morca wrote from the stream are in the same commit.

**Stopping.** While the worker runs, a thread polls `stop_when()` (by
default `morca.outdated()`: a newer version of the pipeline leads) every
50 ms and, once it's true, sets the worker's stop flag. A worker that
honours it ends its stream early; what came is committed, and
`RustRun.stopped` says the flag was set. The step decides what that
means, as with `outdated()` in Mojo.

A failure anywhere (the library, the worker's error or panic, a schema
or a file that doesn't fit, a batch that can't be aligned) fails the
attempt before the commit; files already written or uploaded are left
unreferenced in `data/`, as with an interrupted `append`. The output
directory goes with the call, whatever's in it.

Not yet: a step's input stream (the worker gets none), several outputs,
and Rust steps as dista tasks (`Mapped` over tasks); see
docs/rust-workers.md. Steps 4 to 7 run in liblake, as `morca.tables`
does (`morca._lake.rust_sink`, #474), so a program with Rust steps
compiles no iceberg; this module runs the worker and pulls its stream.
"""

from arrow_mlake.carrow_import import release_c_array

from morca.ctx import Ctx
from morca._internal.handover import outdated
from morca._internal.rust_ffi import StopFn, WorkerCall, WorkerLib
from morca._lake.abi import Dec, Slots
from morca._lake import calls
from morca._lake.client import Api
from morca._lake.names import dataset_of
from morca.tables import DataFiles, Table, append_files, find_commit

comptime DEFAULT_FLUSH_BYTES = 64 * 1024 * 1024
"""About how much of the worker's output `rust_step` gathers into a file."""


@fieldwise_init
struct RustRun(Copyable, Movable, Writable):
    """What `rust_step` did."""

    var snapshot_id: Int64
    """The step's commit to the table."""
    var rows: Int
    """The rows written; 0 when `resumed`."""
    var files: Int
    """The data files committed: those morca wrote from the stream, and
    the worker's own."""
    var worker_files: Int
    """Of `files`, those the worker wrote itself."""
    var stopped: Bool
    """Whether the stop flag was set when the stream ended."""
    var resumed: Bool
    """Whether an earlier attempt's commit was found, and the worker didn't
    run."""


def rust_step(
    mut ctx: Ctx,
    library: String,
    mut table: Table,
    params: String = "{}",
    step_version: Int = 0,
    stop_when: StopFn = outdated,
    flush_bytes: Int = DEFAULT_FLUSH_BYTES,
) raises -> RustRun:
    """Runs the Rust worker in `library` and commits what it streams to
    `table` in one snapshot (the module's doc says how)."""
    table.refresh()
    if find_commit(ctx, table) >= 0:
        var id = append_files(ctx, table, DataFiles())
        ctx.log(
            "the worker's output is committed already; it doesn't run again"
        )
        return RustRun(id, 0, 0, 0, False, True)
    var dataset = dataset_of(table.metadata.location)
    var name = dataset if dataset else table.metadata.location

    var call = WorkerCall(
        WorkerLib(library), ctx, params, step_version, stop_when
    )
    ctx.log(
        String(
            "running the Rust worker ", call.lib.path, " ", call.lib.describe
        )
    )
    var sink = _Sink(table, name, call.output_dir, flush_bytes)
    try:
        call.start()
    except e:
        # A file morca refused is why the worker failed; say it first.
        _refused(call)
        raise e^
    _take(call, sink)
    sink.check(call.stream.value().schema_address())

    # Each array is pulled into `storage` and moved to the library, which
    # leaves the struct released (`morca._lake.rust_sink`).
    var storage = Slots(10)
    while True:
        var more: Bool
        try:
            more = call.next_array(storage.addr)
        except e:
            _refused(call)
            var plain = call.last_error()
            raise Error(
                "morca: the Rust worker ",
                call.lib.path,
                " failed: ",
                plain if plain else String(e),
            )
        try:
            _take(call, sink)
        except e:
            release_c_array(storage.addr)  # the array not moved yet
            raise e^
        if not more:
            break
        sink.put(storage.addr)
    var stopped = call.stopping()
    _ = call^
    var got = sink^.finish()
    var n_own = got.n_own
    var rows = got.rows + got.own_rows
    var n_files = len(got.files)
    var id = append_files(ctx, table, got.files)
    ctx.log(
        String(
            "the Rust worker wrote ",
            rows,
            " rows in ",
            n_files,
            " data file" if n_files == 1 else " data files",
            String(" (", n_own, " of its own)") if n_own else String(),
            " to ",
            name,
            " (stopped early)" if stopped else "",
        )
    )
    table.refresh()
    return RustRun(id, rows, n_files, n_own, stopped, False)


@fieldwise_init
struct _Output(Movable):
    """What the sink wrote and took, for the commit."""

    var files: DataFiles
    var rows: Int
    """Rows streamed."""
    var n_own: Int
    var own_rows: Int


struct _Sink(Movable):
    """liblake's sink for the worker's output (`morca._lake.rust_sink`)."""

    var handle: Int
    var _api: Api

    def __init__(
        out self, table: Table, name: String, dir: String, flush_bytes: Int
    ) raises:
        self._api = table._api.copy()
        self.handle = calls.sink_new(
            self._api, table.handle, name, dir, flush_bytes
        )

    def check(mut self, stream_schema: Int) raises:
        """Checks the stream's schema, which must outlive the sink."""
        calls.sink_schema(self._api, self.handle, stream_schema)

    def put(mut self, array: Int) raises:
        """Moves the `ArrowArray` at `array` to the library."""
        calls.sink_put(self._api, self.handle, array)

    def take(mut self, path: String) raises:
        calls.sink_take(self._api, self.handle, path)

    def finish(deinit self) raises -> _Output:
        var b = calls.sink_finish(self._api, self.handle)
        var d = Dec(Span(b))
        var files = DataFiles(d.bytes())
        var rows = Int(d.int())
        var n_own = Int(d.int())
        var own_rows = Int(d.int())
        return _Output(files^, rows, n_own, own_rows)

    def __deinit__(deinit self):
        self._api.sink_free(self.handle)


def _refused(call: WorkerCall) raises:
    """Raises why morca refused a file the worker reported, if it did."""
    var why = call.refused()
    if why:
        raise Error(why)


def _take(mut call: WorkerCall, mut sink: _Sink) raises:
    """Hands the library the files the worker reported since last time."""
    _refused(call)
    for p in call.take_files():
        sink.take(p)
