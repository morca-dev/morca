# morca-sdk

Write a whole [morca](https://github.com/morca-dev/morca) pipeline in Rust:
steps, partitions, schedule and Iceberg tables, built with `cargo` into a
pipeline binary that the prebuilt `morca` scheduler registers and runs. No
Mojo compiler and no Mojo runtime.

```rust
use morca_sdk::{Cron, Ctx, Month, Pipeline, StepResult};

fn days(_ctx: &mut Ctx, m: Month) -> StepResult<u32> {
    Ok(m.days())
}

fn total(ctx: &mut Ctx, days: Vec<u32>) -> StepResult<u32> {
    let t = days.iter().sum();
    ctx.log(format!("{t} days"));
    Ok(t)
}

fn main() {
    let p = Pipeline::<Month>::new("days")
        .start("2024-01")
        .schedule(Cron::new("0 3 2 * *"))
        .mapped("days", days)
        .gather("total", total);
    morca_sdk::main(p.build());
}
```

```sh
cargo build --release && morca register target/release/days
```

- The binary speaks the pipeline-binary protocol, version 1
  (docs/pipeline-protocol.md), for `default` and `control` placement, on
  Postgres or a SQLite file, and passes the conformance suite
  (tests/conformance.py).
- The `tables` feature adds Iceberg reads (pinned on a retry, recorded) and
  commits (fenced, with the `orca.*` summary keys, found again on a retry)
  through iceberg-rust 0.11.0 and arrow-rs 58, plus `sense` and `keys`. A
  commit appends, or with `step(..).replaces([..])` replaces the partitions
  it writes in one `overwrite` snapshot, as Mojo's `replaces=` does.
- Rust 1.95 or later.

docs/rust-pipelines.md in the morca repository is the guide, including what
version 1 leaves out. examples/toy-rust is examples/toy.mojo rebuilt with
it; `pixi run -e data test-rust-sdk` runs both under one scheduler.
