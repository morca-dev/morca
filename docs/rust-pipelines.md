# Pipelines in Rust

A whole pipeline can be written in Rust, with no Mojo compiler and no Mojo
runtime: its steps, partitions, schedule and tables, built with `cargo` into
a pipeline binary that the prebuilt `morca` scheduler registers and runs like
any other. The `morca-sdk` crate, in [rust/morca-sdk](../rust/morca-sdk), is
what such a binary links. It speaks the [pipeline-binary
protocol](pipeline-protocol.md), version 1, and passes the conformance suite
(`tests/conformance.py`) on SQLite and Postgres.

This is different from a [Rust worker](rust-workers.md), which is one step
in Rust inside a Mojo pipeline. With `morca-sdk` there is no Mojo at all.

[examples/toy-rust](../examples/toy-rust) is [examples/toy.mojo](../examples/toy.mojo)
rebuilt this way, and `pixi run -e rust test-rust-sdk` (tests/rust_sdk.sh)
runs it beside the Mojo toy under one scheduler.

## Writing a pipeline

```toml
# Cargo.toml
[dependencies]
morca-sdk = { git = "https://github.com/morca-dev/morca" }   # or a path
serde = { version = "1", features = ["derive"] }
```

```rust
use morca_sdk::{Cron, Ctx, Month, Pipeline, StepResult, fail, step};
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
struct Measured { month: Month, days: u32 }

fn days(_ctx: &mut Ctx, m: Month) -> StepResult<Measured> {
    Ok(Measured { days: m.days(), month: m })
}

fn measure(ctx: &mut Ctx, m: Measured) -> StepResult<Measured> {
    if m.days == 0 {
        return Err(fail("no days"));
    }
    ctx.log(format!("{} has {} days", m.month, m.days));
    Ok(Measured { days: m.days * 24, month: m.month })
}

fn total(_ctx: &mut Ctx, ms: Vec<Measured>) -> StepResult<i64> {
    Ok(ms.iter().map(|m| m.days as i64).sum())
}

fn main() {
    let toy = Pipeline::<Month>::new("toy_rust")
        .start("2024-01")
        .schedule(Cron::new("0 3 2 * *"))
        .max_runs(2)
        .mapped("days", days)
        .mapped(step("measure").retries(2).timeout_seconds(600), measure)
        .gather("total", total);
    morca_sdk::main(toy.build());
}
```

```sh
cargo build --release
./target/release/toy_rust describe
morca register ./target/release/toy_rust          # or --placement control
```

From there the scheduler fires it, backfills it, and the UI shows its runs,
steps and logs, as for a Mojo pipeline.

### Steps and their types

A step is a function (or closure) `Fn(&mut Ctx, In) -> StepResult<Out>`.

- **`mapped`** runs once per partition key. The first step takes the key
  (`Month`, `Week`, `Day`, `Hour`, or `Name` for a keyed pipeline); a
  mapped step after a mapped step takes its output for the same key.
- **`gather`** runs once per run. First, it takes the run's keys
  (`Vec<K>`); after a mapped step, its outputs in key order (`Vec<Out>`);
  after a gather, its output. A mapped step can't follow a gather.

The builder is typed, so a step whose input isn't what the step before it
makes doesn't compile. What Rust can't check at compile time is checked by
`build()`, which `main` calls before any command, so a broken definition
can't be registered (it exits 2): unique step names, datasets spelled
`namespace.table`, a start key that parses, a sensor that reads something,
a keyed pipeline's keys dataset.

Inputs and outputs are `serde` types. A step's output is kept in its step
row as JSON, `{"type": <Rust type name>, "value": ...}`, which is how a
resume hands it to the next step. A resume under new code
(`--allow-new-code`, or a rerun) decodes a stored output only into the type
it was stored as, so a step whose types changed fails with what it got
rather than misreading it.

`step("name")` sets a step's `retries`, `backoff_seconds` (doubling),
`timeout_seconds`, data `version`, and its `reads` and `writes`. A plain
`"name"` takes the defaults: no retries, no timeout.

A step fails by returning an error: `?` on any error type, or
`Err(fail("why"))`. A panic fails the attempt too, with its message. It
defers with `Err(defer(seconds, "why"))`: the attempt ends `deferred`, the
run starts again then, and no retries are spent.

### The pipeline

`Pipeline::<K>::new(name)` and then, in any order before `build()`:

| Call | describe | Default |
|---|---|---|
| `.start("2024-01")` | `partitions.start` | none |
| `.schedule(Cron::new("0 3 2 * *").tz("Europe/Paris"))` | `schedule` (`.fills_current()`, `.no_catchup()`) | none |
| `.max_runs(n)` | `max_runs` | 1 |
| `.run_retries(n)` | `run_retries` | 3 |
| `.retry_seconds(first, max)` | `retry_seconds`, `max_retry_seconds` | 0 |
| `.sensor()` | `sensor` | false |
| `.keys_per_run(n)` | `keys_per_run` | 1 |
| `.keys_from("ns.table", "column")` | `partitions.dataset`, `.column` (keyed) | required for `Name` |
| `.source(morca_sdk::source_from_build_env!())` | `source`, from `MORCA_SOURCE`, `MORCA_COMMIT`, `MORCA_DIRTY` at build time | empty |

The registry hash is FNV-1a over the pipeline's name, each step's name,
kind, upstream, function, datasets and version, and the partition kind, as
the Mojo binary hashes its own; the function is the step's Rust path
(`toy_rust::measure`). The same source builds the same hash; a new step,
edge, function or dataset changes it.

### The context

`Ctx` has the step's `pipeline()`, `run()`, `step()`, `partition()`,
`attempt()` and `code()`, and:

- `log(msg)`: a line on stdout tagged `[step partition]`, and in the
  attempt's log with a timestamp, with the run's secrets masked;
- `progress(done, total)` and `metric(name, value)`, as log lines;
- `secret(name)`: a variable `MORCA_SECRETS` names, or None;
- `stopping()`: true once the run is outdated (newer code is registered, or
  its scheduler instance drains; Postgres only). Poll it between units of
  work, from any thread. What to do is the step's choice.

These are the calls morca-worker's `RunContext` has for a worker step. A
step can parallelise inside itself with threads, rayon or tokio.

### Tables

With the crate's `tables` feature, a step reads and commits Iceberg tables
in `MORCA_WAREHOUSE` (a directory, or `s3://bucket/prefix` with the `AWS_*`
variables), with iceberg-rust 0.11.0 on arrow-rs 58:

```rust
fn clean(ctx: &mut Ctx, m: Month) -> StepResult<i64> {
    let n: usize = ctx.read("raw.events")?.iter().map(|b| b.num_rows()).sum();
    ctx.ensure_table("lake.clean", schema(), None)?;
    ctx.append("lake.clean", vec![rows(&m, n)?])?;
    Ok(n as i64)
}

Pipeline::<Month>::new("clean_rust")
    .sensor()
    .mapped(step("clean").reads(["raw.events"]).writes(["lake.clean"]), clean)
```

- `read(dataset)` scans the snapshot this attempt already read, else the
  one the step's first attempt read (so a retry or a resume sees the same
  data), else the current one, and records the read.
- `append(dataset, batches)` writes Parquet split by the table's partition
  spec, checks the commit fence, and commits one snapshot with the
  `orca.*` summary keys, recorded as the attempt's commit. If an earlier
  attempt of the run already made that commit, it records that one and
  writes nothing. `find_commit(dataset)` asks first, for a step that writes
  files itself. `arrow_schema(dataset)` is the schema the batches need.
- `ensure_table(dataset, schema, spec)` creates a table that isn't there.
- A step may read and write only the datasets it declares.

The binary then also answers `sense` (a sensor's datasets) and `keys` (a
keyed pipeline's keys). [rust/morca-sdk/examples/clean.rs](../rust/morca-sdk/examples/clean.rs)
is a sensor, the twin of tests/sensors/clean.mojo; the conformance suite runs
it as tests/conformance/clean-rust.json.

The crate picks arrow-rs 58 because iceberg-rust 0.11.0 is built on it, and
the batches a step hands iceberg must be the same major version.
morca-worker is on arrow 60, which doesn't matter here: a worker is a cdylib
that morca's Mojo side loads, and a morca-sdk binary never loads one.

## Running

A morca-sdk binary is a pipeline binary like any other: `morca register`
runs its `describe`, and the scheduler starts each run as
`<binary> resume <run>`. It needs only `MORCA_DATABASE_URL`
(`postgres://...` or `sqlite:<path>`), and `MORCA_WAREHOUSE` for tables.

Over Postgres it checks that the schema has every column it uses, and
leaves migrations to the scheduler. Over SQLite it makes the file's schema
itself, as the Mojo binary does, so either can use a file the other made.

`<binary> sample`, which the runners start beside each run, runs the
`morca sample` on the path; without one the run's Machines card stays
empty.

## What isn't in version 1

- **Placements**: `default` (the scheduler's runner) and `control` only.
  `MORCA_STATE_URL` (a worker pool's runs, over the UI's API), `ec2`
  placement, the warm pool's commands and the Kubernetes runner come
  later.
- **dista tasks**: a dista task is Mojo code, and forking a threaded Rust
  process is the #135 hazard. A step parallelises inside itself instead.
- **`replaces=`**: iceberg-rust 0.11.0 has no overwrite or delete
  transaction, so a step only appends.
- **Object storage for logs**: `MORCA_LOGS`, `keep-log` and `put-log` take
  local paths; an `s3://` `MORCA_LOGS` keeps no attempt logs yet.
- **Postgres over TLS**: the client connects without TLS
  (`sslmode=disable`), as to a database on the same host or network.
- **`run`, `status` and `fires`**, which are for people, not the
  scheduler.
- **Mojo outputs**: a pipeline moved from Mojo to Rust is new code (its
  functions differ), and can't resume a run a Mojo build started, since the
  step outputs are encoded differently.
