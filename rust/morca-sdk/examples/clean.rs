//! A sensor with tables, the Rust twin of tests/sensors/clean.mojo: reads
//! raw.events and appends as many rows to lake.clean, a month at a time.
//! The conformance suite runs it as tests/conformance/clean-rust.json;
//! MORCA_CLEAN_SLEEP makes each attempt take that many seconds first.
//!
//!     cargo build --release --features tables --example clean

use morca_sdk::tables::{id_name_rows, id_name_schema};
use morca_sdk::{Ctx, Month, Pipeline, StepResult, step};

fn clean(ctx: &mut Ctx, m: Month) -> StepResult<i64> {
    if let Some(s) = std::env::var("MORCA_CLEAN_SLEEP")
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
    {
        std::thread::sleep(std::time::Duration::from_secs_f64(s));
    }
    let n: usize = ctx.read("raw.events")?.iter().map(|b| b.num_rows()).sum();
    ctx.ensure_table("lake.clean", id_name_schema(), None)?;
    ctx.append("lake.clean", vec![id_name_rows(&m.to_string(), n)?])?;
    ctx.log(format!("{n} rows for {m}"));
    Ok(n as i64)
}

fn main() {
    let p = Pipeline::<Month>::new("clean_rust")
        .start("2024-01")
        .sensor()
        .mapped(
            step("clean").reads(["raw.events"]).writes(["lake.clean"]),
            clean,
        );
    morca_sdk::main(p.build());
}
