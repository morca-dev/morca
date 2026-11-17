//! Write a whole morca pipeline in Rust: steps, partitions and tables,
//! built into a pipeline binary that the prebuilt `morca` scheduler
//! registers and runs like any other, with no Mojo toolchain.
//!
//! The binary speaks the pipeline-binary protocol (docs/pipeline-protocol.md
//! in the morca repository), version 1, for `default` (local) and `control`
//! placement: `describe`, `resume`, `sense`, `keys`, `keep-log`, `put-log`,
//! on Postgres or a SQLite file. docs/rust-pipelines.md is the guide.
//!
//! ```no_run
//! use morca_sdk::{Ctx, Month, Pipeline, StepResult, Cron};
//! use serde::{Deserialize, Serialize};
//!
//! #[derive(Serialize, Deserialize)]
//! struct Measured { month: Month, days: u32 }
//!
//! fn days(_ctx: &mut Ctx, m: Month) -> StepResult<Measured> {
//!     Ok(Measured { days: m.days(), month: m })
//! }
//!
//! fn total(ctx: &mut Ctx, ms: Vec<Measured>) -> StepResult<u64> {
//!     let t = ms.iter().map(|m| m.days as u64 * 24).sum();
//!     ctx.log(format!("{} months, {t} hours", ms.len()));
//!     Ok(t)
//! }
//!
//! fn main() {
//!     let p = Pipeline::<Month>::new("hours")
//!         .start("2024-01")
//!         .schedule(Cron::new("0 3 2 * *"))
//!         .mapped("days", days)
//!         .gather("total", total);
//!     morca_sdk::main(p.build());
//! }
//! ```

// Without `tables`, the read and commit plumbing has no caller.
#![cfg_attr(not(feature = "tables"), allow(dead_code))]

mod cli;
mod ctx;
mod exec;
mod heartbeat;
mod logs;
mod partition;
mod pipeline;
mod store;
pub mod tables;

pub use ctx::Ctx;
pub use partition::{Day, Hour, Month, Name, Partition, Week, days_in_month};
pub use pipeline::{
    AfterGather, AfterMapped, Built, Cron, Pipeline, Source, Start, StepError, StepResult,
    StepSpec, defer, fail, step,
};
pub use serde;
pub use serde_json;

/// The version of the pipeline-binary protocol this crate speaks:
/// describe's `"protocol"`.
pub const PROTOCOL_VERSION: u32 = 1;

/// Runs the binary's command line for the pipeline, and exits with its
/// code. A definition that didn't build is a usage error (exit 2), so a
/// broken binary can't be registered.
pub fn main(pipeline: Result<Built, String>) -> ! {
    let p = match pipeline {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    let args: Vec<String> = std::env::args().collect();
    let code = cli::run(&p, &args);
    use std::io::Write;
    let _ = std::io::stdout().flush();
    std::process::exit(code)
}
