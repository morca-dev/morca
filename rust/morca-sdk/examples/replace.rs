//! A sensor that replaces its partitions, the Rust twin of
//! tests/sensors/replace.mojo: reads raw.events and writes as many rows to
//! lake.monthly, partitioned by month, a month at a time, declaring
//! lake.monthly in `replaces` so a new run of a month leaves one copy of
//! its rows. The conformance suite runs it as
//! tests/conformance/replace-rust.json.
//!
//! It writes its files and commits them in two calls (`write_files`, then
//! `append_files`), so that with MORCA_REPLACE_DIE set it can die between
//! the two; MORCA_REPLACE_SLEEP makes each attempt take that many seconds
//! first.
//!
//!     cargo build --release --features tables --example replace
//!     replace rows <warehouse>     each month in lake.monthly and its rows

use std::collections::BTreeMap;
use std::sync::Arc;

use morca_sdk::tables::arrow_array::{ArrayRef, Int64Array, RecordBatch, StringArray};
use morca_sdk::tables::iceberg::arrow::schema_to_arrow_schema;
use morca_sdk::tables::iceberg::spec::{
    NestedField, PrimitiveType, Schema, Transform, Type, UnboundPartitionSpec,
};
use morca_sdk::tables::read_as_other;
use morca_sdk::{Ctx, Month, Pipeline, StepResult, step};

const TABLE: &str = "lake.monthly";

fn schema() -> Schema {
    Schema::builder()
        .with_schema_id(0)
        .with_fields(vec![
            NestedField::required(1, "id", Type::Primitive(PrimitiveType::Long)).into(),
            NestedField::required(2, "month", Type::Primitive(PrimitiveType::String)).into(),
        ])
        .build()
        .expect("a valid schema")
}

fn spec() -> UnboundPartitionSpec {
    UnboundPartitionSpec::builder()
        .with_spec_id(0)
        .add_partition_field(2, "month", Transform::Identity)
        .expect("a valid field")
        .build()
}

fn rows(month: &str, n: usize) -> Result<RecordBatch, String> {
    let schema = Arc::new(schema_to_arrow_schema(&schema()).map_err(|e| e.to_string())?);
    let ids: ArrayRef = Arc::new(Int64Array::from_iter_values(0..n as i64));
    let months: ArrayRef = Arc::new(StringArray::from_iter_values((0..n).map(|_| month)));
    RecordBatch::try_new(schema, vec![ids, months]).map_err(|e| e.to_string())
}

fn load(ctx: &mut Ctx, m: Month) -> StepResult<i64> {
    if let Some(s) = std::env::var("MORCA_REPLACE_SLEEP")
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
    {
        std::thread::sleep(std::time::Duration::from_secs_f64(s));
    }
    let n: usize = ctx.read("raw.events")?.iter().map(|b| b.num_rows()).sum();
    ctx.ensure_table(TABLE, schema(), Some(spec()))?;
    let files = if ctx.find_commit(TABLE)?.is_some() {
        vec![]
    } else {
        ctx.write_files(TABLE, vec![rows(&m.to_string(), n)?])?
    };
    if !files.is_empty() && std::env::var_os("MORCA_REPLACE_DIE").is_some() {
        eprintln!("replace: dying between writing {m}'s files and committing them");
        // As a kill would: no attempt finished, nothing committed.
        std::process::exit(70);
    }
    let snap = ctx.append_files(TABLE, files)?;
    ctx.log(format!("{n} rows for {m} in snapshot {snap}"));
    Ok(n as i64)
}

/// `rows <warehouse>`: each month in lake.monthly and how many rows it has.
fn print_rows(wh: &str) -> Result<(), String> {
    // SAFETY: single-threaded, before anything reads the environment.
    unsafe { std::env::set_var("MORCA_WAREHOUSE", wh) };
    let mut by = BTreeMap::<String, usize>::new();
    for b in read_as_other(TABLE)? {
        let c = b
            .column_by_name("month")
            .and_then(|c| c.as_any().downcast_ref::<StringArray>())
            .ok_or("no month column")?;
        for m in c.iter().flatten() {
            *by.entry(m.to_string()).or_default() += 1;
        }
    }
    for (m, n) in by {
        println!("{m} {n}");
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("rows") {
        let Some(wh) = args.get(2) else {
            eprintln!("usage: replace rows <warehouse>");
            std::process::exit(2);
        };
        if let Err(e) = print_rows(wh) {
            eprintln!("replace: {e}");
            std::process::exit(1);
        }
        return;
    }
    let p = Pipeline::<Month>::new("replace_rust")
        .start("2024-01")
        .sensor()
        .mapped(step("load").reads(["raw.events"]).replaces([TABLE]), load);
    morca_sdk::main(p.build());
}
