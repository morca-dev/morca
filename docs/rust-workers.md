# Rust workers

A pipeline step can be written in Rust: a worker library, loaded into the
run's process, that implements the interface below. Each Rust worker comes
with a small **proxy pipeline in Mojo**, which declares the pipeline, its
partitions, and the dataset the step writes as for any step. The step calls
`morca.rust_step`, which runs the worker and writes the record batches it
streams back the way morca writes any step's output: Parquet, then one
Iceberg commit that a retry recognises. A worker that writes Parquet
itself hands over files instead, or as well, and they go into the same
commit.

```text
proxy pipeline (Mojo)                     worker (Rust cdylib)
─────────────────────                     ────────────────────
Step[..., writes=["demo.numbers"]]
  ensure_table(ctx, NUMBERS, Schema.parse(SCHEMA))
  rust_step(ctx, "numbers_worker", t) ──▶ morca_worker_run(ctx, NULL, &out)
     check the stream's schema       ◀──  out: ArrowArrayStream
     pull, align, write Parquet      ◀──  get_next, one batch at a time
     one commit: append_files
                    schemas/numbers.json, read by both
```

[examples/rust-worker](../examples/rust-worker) is a complete one, run in
CI by `pixi run -e rust test-rust-worker` (tests/rust_worker.sh), and
[examples/hindcast](../examples/hindcast) a real one: a Rust worker that
fetches and decodes NOAA's GFS forecasts with crates.io crates, then Mojo
steps that score them (`pixi run -e rust test-hindcast`). The
`morca-worker` crate, in [rust/morca-worker](../rust/morca-worker), is the
Rust side: a worker author writes only safe Rust.

This is ABI version 1. What isn't in it yet is at the end.

## Writing a worker

```toml
# Cargo.toml
[lib]
crate-type = ["cdylib", "rlib"]   # rlib too, for cargo test

[dependencies]
morca-worker = { git = "https://github.com/morca-dev/morca", rev = "<morca's commit>" }
```

With a `schemas/numbers.json` of one `long` column, `id`:

```rust
use std::sync::Arc;
use morca_worker::arrow_array::{Int64Array, RecordBatch};
use morca_worker::{export_worker, schema, Input, Output, Result, RunContext, Worker};

const SCHEMA: &str = include_str!("../schemas/numbers.json");

struct Numbers;

impl Worker for Numbers {
    const NAME: &'static str = "numbers";
    const VERSION: &'static str = env!("CARGO_PKG_VERSION");

    fn run(ctx: &RunContext, _input: Option<Input>) -> Result<Output> {
        let schema = Arc::new(schema::to_arrow(SCHEMA)?);
        ctx.log(format!("numbers for {}", ctx.partition()));
        let (s, c) = (schema.clone(), ctx.clone());
        let batches = (0..10).map_while(move |i| {
            if c.stopping() { return None; }   // end early when asked
            let ids = Int64Array::from_iter_values(i * 100..(i + 1) * 100);
            Some(RecordBatch::try_new(s.clone(), vec![Arc::new(ids)]).map_err(Into::into))
        });
        Ok(Output::from_iter(schema, batches))
    }
}

export_worker!(Numbers);
```

- **`Worker::run`** is called once per attempt and returns an `Output`: a
  `RecordBatchReader` morca pulls from (`Output::from_reader`,
  `from_batches` or `from_iter`). Work can happen in `run`, in the stream,
  or both. A stream that makes each batch when it's pulled holds one batch
  at a time, and produces at the rate morca writes: `get_next` is
  pull-based, so backpressure comes for free.
- **`RunContext`** has the pipeline, step, partition, run, attempt, the
  registry hash (`code`), the step's `version=` (`step_version`), the
  parameters the proxy passed (`params()`, `param(name)`, a JSON object)
  and the run's secrets (`secret(name)`). `log`, `progress` and `metric`
  write to the step's log, and `stopping()` is the stop flag.
- **Errors** are any `std::error::Error`; the message fails the attempt.
  **Panics** do too: the crate catches them at the boundary, in `run` and
  in each batch. Don't build a worker with `panic = "abort"`, which would
  take the whole process down instead.
- **Threads** are the worker's own business: rayon, a tokio runtime, a few
  `std::thread`s, sized to the run's grant (a Rust step is a
  single-process step, below). `RunContext` is `Send + Sync`; a clone in
  another thread can log and read `stopping()`. Stop and join every
  thread before the stream ends.

`morca_worker::testing::Run` runs a worker through the same C ABI in a
`cargo test`, and returns its batches, the files it reported, and its log
lines.

## Parquet files from the worker

A worker that already produces Parquet, or whose output is too large to
hand over batch by batch, writes the files itself and reports them:

```rust
// The worker's own dependency: parquet = { version = "60", default-features
// = false, features = ["arrow", "snap"] }, arrow-rs's, pure Rust.
use parquet::arrow::ArrowWriter;

fn run(ctx: &RunContext, _input: Option<Input>) -> Result<Output> {
    let schema = Arc::new(schema::to_arrow(SCHEMA)?);   // field ids included
    let c = ctx.clone();
    let files = (0..4).map(move |i| {
        let path = c.output_dir()?.join(format!("part-{i}.parquet"));
        let mut w = ArrowWriter::try_new(File::create(&path)?, schema.clone(), None)?;
        w.write(&make_batch(i)?)?;
        w.close()?;
        Ok(path)
    });
    Ok(Output::from_files(ctx, files))
}
```

- **`ctx.output_dir()`** is a local directory, empty and this attempt's
  own (under `$TMPDIR`). morca removes it, with whatever's left in it,
  when the call ends.
- **`ctx.add_file(path)`** reports a finished file (a relative path is in
  the output directory). Call it in `run` and return `Output::files()`,
  which is a stream of no columns, or return **`Output::from_files(ctx,
  iter)`**, whose iterator writes one file per item: morca takes each file
  before it asks for the next, so the worker's disk holds one at a time.
  From another thread, `add_file` is queued and delivered on the run
  thread, as logs are.
- **Streams and files mix.** A worker may stream some rows and write
  others to files in the same run (examples/rust-worker's `mix` mode);
  all of them land in the step's one commit. A stream of no columns says
  the worker only writes files.

morca takes each reported file the next time it has control: when `run`
returns, and after each batch it pulls. For each file it:

1. **Fails the attempt if it isn't there**: `the Rust worker reported the
   file …, which doesn't exist`. `add_file` returns that error to the
   worker too, when it's called on the run thread.
2. **Checks its schema** against the table's, from the footer, by the rule in
   "The schema" below, with two differences, since the file is committed as it is and
   read later by field id: every column must carry the table's field id,
   and a type must be one iceberg's reader reads as the table's: the same
   (a timestamp or time in the same unit), or `int` for `long`, `float`
   for `double`, a decimal of the same scale and no more precision. The
   error names the file and the column.
3. **Finds its partition** from the footer's statistics: for each field of
   the table's partition spec, the source column's minimum and maximum in
   every row group must give one value under the transform (under
   `bucket`, one value outright), and a column that's all null is the null
   partition. A file holding rows of two partitions fails the attempt,
   naming the column: write a file per partition. arrow-rs writes the
   statistics by default. A string column the writer truncated statistics
   for has a minimum and maximum that differ, so partition by a short key.
4. **Uploads it** where the table's data files go, with the table's
   `FileIO` (a local warehouse or object storage, S3 included), as
   `data/<partition>/<uuid>-w<n>.parquet`, and deletes the local file if
   it's in the output directory. The file is read whole once to upload it,
   so keep files to a few hundred MB.
5. **Keeps its entry** for the commit: row count, file size, split offsets
   and per-column sizes, value and null counts and bounds, all from the
   footer (iceberg's `data_file_from_footer`, as for files morca writes).

At the end of the stream the files are committed with those morca wrote
from the stream: one `append_files`, the same commit path, and the same
recognition of an earlier attempt's commit after a crash. A file of no
rows is dropped. The worker writes local files, not to the warehouse
itself, so it needs no storage credentials and no object store crate,
and a file that doesn't fit never reaches the table's location.

## The schema: one file, checked twice

The proxy pipeline is the source of truth, as for any step: it declares
`writes=[...]` and creates the table with
`ensure_table(ctx, dataset, Schema.parse(...), spec)`. The schema is an
Iceberg schema JSON file, such as `schemas/numbers.json`:

- **Mojo** embeds it at build time: `scripts/embed-json.sh
  schemas/numbers.json NUMBERS_SCHEMA > build/x/numbers_schema.mojo`
  writes a module with the file as a string, and `-I build/x` makes it
  importable, so the binary needs no file next to it.
- **Rust** embeds it with `include_str!`, and
  `morca_worker::schema::to_arrow` turns it into the Arrow schema the
  worker builds its batches with, each field carrying its Iceberg id
  (`PARQUET:field_id`).
- **`cargo test`** checks the worker's schema against the file with
  `schema::check` or `schema::assert_fits`, so drift fails there first.
- **morca** checks the stream's schema (`get_schema`) against the table's
  before it writes anything, by the same rule, and fails the attempt
  naming the column.

The rule. Columns are matched by name, at every depth. Every column of the
table must be in the worker's schema, and no other; a field id, when the
worker gives one, must be the table's. A required column mustn't be
nullable. A type fits when it's the table's, or one Iceberg widens to it:

| Table | The worker's Arrow type |
|---|---|
| `int` | Int8, Int16, Int32 |
| `long` | Int8, Int16, Int32, Int64 |
| `double` | Float32, Float64 |
| `string` | Utf8, LargeUtf8 |
| `binary` | Binary, LargeBinary |
| `decimal(P,S)` | Decimal128 of scale S and precision up to P |
| `timestamp`, `timestamp_ns` | Timestamp in any unit, without a time zone |
| `timestamptz`, `timestamptz_ns` | Timestamp in any unit, with a time zone |
| `time` | Time64 |
| `uuid`, `fixed[N]` | FixedSizeBinary(16), FixedSizeBinary(N) |
| struct, list, map | the same kind, its fields, element or key and value by the same rule |
| anything else | the type `to_arrow` gives |

morca checks a nested column's kind with the stream's schema, and its
leaves as each batch is aligned to the table (iceberg's `align_batch`),
which also fails naming the column.

## What `rust_step` does

```mojo
def rust_step(
    mut ctx: Ctx,
    library: String,
    mut table: Table,
    params: String = "{}",
    step_version: Int = 0,
    stop_when: def() thin -> Bool = outdated,
    flush_bytes: Int = 64 MiB,
) raises -> RustRun   # snapshot_id, rows, files, stopped, resumed
```

1. **A retry that finds its commit returns it.** If an earlier attempt of
   the step committed to the table in this run (`find_commit`), the worker
   doesn't run again and nothing is written: a process killed after the
   commit, before morca's database heard of it, is resumed without
   duplicate rows.
2. **It loads the library late**, when the step runs, never at program
   start (see the process model below), and refuses a library whose
   `morca_worker_abi_version()` isn't 1.
3. **It calls `morca_worker_run`** with the context, and takes the stream.
4. **It checks the stream's schema** against the table's.
5. **It pulls batches and writes Parquet as they arrive**, each aligned to
   the table's schema, gathering small batches into files of about
   `flush_bytes`, so a large output never sits in memory whole.
6. **It takes the worker's own Parquet files**, if it reported any, when
   `run` returns and after each batch (above).
7. At the end of the stream it **commits once**: `append_files`, which is
   `replace_partition_files` for a dataset the step declared in
   `replaces=`, with the files from the stream and the worker's own. One
   commit, not one per batch: morca recognises a step's commits by their
   number after a crash.

Steps 4 to 7 run inside liblake, the library `morca.tables` loads, so a
proxy pipeline compiles no iceberg: the stream's arrays move to the library
as they're pulled, without a copy (#474).

Any failure before the commit (the worker's error or panic, a schema or a
file that doesn't fit, a batch that can't be aligned) fails the attempt,
and the run's retries apply. Files already written or uploaded are left
unreferenced in `data/`, as with an interrupted `append`.

`RustRun` has `snapshot_id`, `rows` (streamed and in the worker's files),
`files` (all data files committed), `worker_files` (of those, the
worker's own), `stopped` and `resumed`.

`library` is a path, a file name (`libx.so`), or a bare name `x`, which
is `libx.so` (`libx.dylib` on macOS), looked up as morca's other native
libraries are: `$CONDA_PREFIX/lib`, the executable's directory and its
`../lib`, then the dynamic linker's path.

## The C ABI

`export_worker!` generates these four functions; a library exports them and
nothing else. A worker in another language implements them itself.

```c
#include <stdint.h>
#include <stddef.h>

#define MORCA_WORKER_ABI_VERSION 1

typedef struct MorcaRunContext {
    uint64_t size;              /* sizeof this struct as morca built it */
    const char *pipeline;       /* NUL-terminated UTF-8 */
    const char *step;
    const char *partition;      /* empty for a gather step */
    const char *params;         /* a JSON object, from the proxy step */
    const char *secrets;        /* a JSON object: secret name -> value */
    const char *code;           /* the pipeline's registry hash, hex */
    int64_t run;                /* 0 for a run in memory */
    int64_t attempt;            /* from 1 */
    int64_t step_version;       /* the step's version= */
    const int32_t *stop;        /* atomic; non-zero: stop early */
    void *host;                 /* passed back to the callbacks */
    void (*log)(void *host, const char *msg, size_t len);
    void (*progress)(void *host, int64_t done, int64_t total);
    void (*metric)(void *host, const char *name, size_t name_len, double value);
    /* From size 136: */
    const char *output_dir;     /* a local directory for the worker's files */
    int32_t (*add_file)(void *host, const char *path, size_t len);
} MorcaRunContext;              /* 136 bytes on a 64-bit platform */

uint32_t morca_worker_abi_version(void);
const char *morca_worker_describe(void);
int32_t morca_worker_run(const MorcaRunContext *ctx,
                         struct ArrowArrayStream *input,
                         struct ArrowArrayStream *out,
                         char **error);
void morca_worker_free(char *p);
```

- **`morca_worker_abi_version`** is 1. morca refuses another, naming both.
- **`size` comes first.** A later morca can add fields at the end without
  a new version: a worker reads the fields it knows. The first morca with
  Rust workers passed 120 bytes; `output_dir` and `add_file` came after,
  still version 1, since a worker built before them reads only the first
  120. The crate reads a context of 120 bytes or more, and the two file
  fields only when `size` is 136 or more; under an older morca,
  `output_dir()` and `add_file` fail saying so, and streams work as
  before.
- **`add_file`** is called on the run thread with a UTF-8 path, absolute
  or relative to `output_dir`, of a complete Parquet file. It returns 0
  when morca has taken note of it, non-zero when it refuses it (it isn't
  there); morca then fails the attempt with its reason, whatever the
  worker does.
- **`morca_worker_describe`** returns static JSON the library owns and
  never frees: `{"name", "version", "abi", "morca_worker"}`. morca logs it.
  It doesn't carry the schema; the proxy pipeline does.
- **`morca_worker_run`** returns 0 having moved a stream into `*out` (the
  [Arrow C stream interface](https://arrow.apache.org/docs/format/CStreamInterface.html)).
  morca owns it from then on and releases it once it's done with it, at
  the end of the stream or on a failure. On failure `run` returns
  non-zero (1 an error, 2 a panic) and points `*error` at a message the
  library allocated, which morca frees with **`morca_worker_free`**. There
  is no global "last error", which wouldn't be safe with two calls in one
  process. An error *during* the stream is the stream's own: `get_next`
  returns non-zero and `get_last_error` says why, in the worker's words:
  the crate drops arrow-rs's `External error: ` from the front, and morca
  logs it as `morca: the Rust worker <library> failed: <message>`.
- **`input`** is NULL in version 1 (below).
- **Lifetimes.** `ctx` and everything it points to, the stop flag
  included, stay valid until morca has released `out`, which is when the
  worker's side of the call ends.
- **Callbacks** are called only from the thread morca called `run` on;
  morca calls `get_next` and `release` on that thread too. The crate
  queues what other threads send and delivers it there, the next time the
  run thread logs or a batch is pulled. Progress is logged at most every 10
  s, and when it reaches its total.
- **The stop flag** is an `int32` the worker reads atomically (acquire),
  from any thread, between units of work (`ctx.stopping()`). morca sets it
  when `stop_when()` returns true, polling it every 50 ms on a thread of its
  own; by default that's `morca.outdated()`, true once a newer version of
  the pipeline leads or the run's scheduler drains. A worker that sees it
  ends its stream early; morca commits what came and sets
  `RustRun.stopped`, and the step decides what a stopped run means (the
  example logs it and returns). A worker that ignores it runs to the end.

## Symbols and linking

A `cdylib` exports only its `#[no_mangle]` functions, so with
`export_worker!` that's the four above (`add_file` is a callback in the
context, not an export); tests/rust_worker.sh checks it with
`nm`. Rust's standard library is linked in statically, as it always is for
a `cdylib`, so the library depends on libc and nothing of Rust's. That
keeps the library's libc use apart from Mojo's `external_call`
declarations, and morca opens it with `RTLD_LOCAL`, so its symbols don't
mix with the process's. It's also opened with `RTLD_NODELETE` and never
unloaded: a Rust library with thread-locals must outlive its threads.

## Process model and fork safety

- **A Rust step is a single-process step.** `rust_step` runs the worker
  once, in the run's process. The worker can use the run's granted cores
  with its own threads. Given up, for now: spreading over machines
  (`workers = N`), retries per key, and per-task bars on the run's
  timeline; see below.
- **Loaded late.** The library is opened when the step runs, never at
  program start: dista forks its workers, and a library that has started
  threads (tokio) before a fork breaks the child (#135 is the same failure
  with libcurl). Nothing Rust crosses a fork.
- **Isolation.** Each run is its own process, so a Rust abort fails only
  that attempt, and the run's retries apply. The usual failure is a caught
  panic, an error message.
- **Memory.** A run's learned grant (`memory_gb = "auto"`) comes from its
  cgroup's peak, and Rust's heap is in the same process and cgroup, so a
  Rust step is sized like any other. morca can't see *why*; a worker that
  wants its own peak on record reports it with `ctx.metric`.
- **Batches cross with one copy.** arrow-mlake's stream import copies each
  batch into Mojo memory and releases the producer's at once, so the
  worker holds one batch at a time. The copy runs at memory speed.

## Building and shipping

Cargo is a build-time dependency only. The image the runs use carries the
built library, not the Rust toolchain:

- In development and CI, `cargo build --release` and point the proxy at the
  library, or install it into the environment's `lib/`. In this repository
  the `rust` pixi environment (the data environment plus conda-forge's
  `rust`) builds and tests the example.
- For an image, make the worker a pixi package whose recipe runs `cargo
  build --release` and installs `lib/lib<name>.so` into the environment,
  as magmalake's iceberg-rs.mojo does with its `ffi/` (`recipe.yaml` over
  `pixi-build-rattler-build`, `rust` in its build requirements). The
  project image's build has the toolchain; `morca-runtime` doesn't need it,
  since the library is found in `$CONDA_PREFIX/lib` like morca's other
  native libraries.
- Build the worker against the `morca-worker` crate of the morca the
  pipeline uses: the ABI version is checked when the step runs.

## Not yet

- **Rust steps as dista tasks** (`rust_step` in a `Mapped` step over
  tasks), with each task process loading the library itself.
- **Several outputs**: one stream per declared output, drained in
  declaration order.
- **A step's input** as the `input` stream.
- **`[steps.<name>] rust = "crates/x"`** in morca.toml. For now the proxy
  names the library.
