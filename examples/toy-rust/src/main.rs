//! examples/toy.mojo rebuilt in Rust: three steps over months, scheduled at
//! 03:00 UTC on the 2nd of each month for the month before, from 2024-01,
//! with at most two runs at once. No Mojo compiler and no Mojo runtime.
//!
//!     cargo build --release --manifest-path examples/toy-rust/Cargo.toml
//!     build/cargo/release/toy_rust describe
//!     morca register build/cargo/release/toy_rust
//!
//! As the Mojo toy: a month in MORCA_TOY_FAIL (e.g. `2024-02`) fails its
//! `measure` step, one in MORCA_TOY_CRASH aborts the process there, and
//! MORCA_TOY_SLEEP makes every step take that many seconds.

use std::time::Duration;

use morca_sdk::{Cron, Ctx, Month, Pipeline, StepResult, fail};
use serde::{Deserialize, Serialize};

fn nap() {
    if let Some(s) = std::env::var("MORCA_TOY_SLEEP")
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
    {
        std::thread::sleep(Duration::from_secs_f64(s));
    }
}

fn listed(var: &str, m: &Month) -> bool {
    std::env::var(var)
        .unwrap_or_default()
        .contains(&m.to_string())
}

#[derive(Serialize, Deserialize)]
struct Measured {
    month: Month,
    days: u32,
}

/// The number of days in the month.
fn days(_ctx: &mut Ctx, m: Month) -> StepResult<Measured> {
    nap();
    Ok(Measured {
        days: m.days(),
        month: m,
    })
}

/// Hours in the month; fails for the months in MORCA_TOY_FAIL.
fn measure(ctx: &mut Ctx, m: Measured) -> StepResult<Measured> {
    nap();
    if listed("MORCA_TOY_FAIL", &m.month) {
        return Err(fail(format!("failing {} as asked", m.month)));
    }
    if listed("MORCA_TOY_CRASH", &m.month) {
        eprintln!("crashing {} as asked", m.month);
        std::process::abort();
    }
    ctx.log(format!("{} has {} days", m.month, m.days));
    Ok(Measured {
        days: m.days * 24,
        month: m.month,
    })
}

fn total(ctx: &mut Ctx, ms: Vec<Measured>) -> StepResult<i64> {
    nap();
    let t: i64 = ms.iter().map(|m| m.days as i64).sum();
    ctx.log(format!("{} months, {t} hours", ms.len()));
    Ok(t)
}

fn main() {
    let toy = Pipeline::<Month>::new("toy_rust")
        .start("2024-01")
        .schedule(Cron::new("0 3 2 * *"))
        .max_runs(2)
        .mapped("days", days)
        .mapped("measure", measure)
        .gather("total", total);
    morca_sdk::main(toy.build());
}
