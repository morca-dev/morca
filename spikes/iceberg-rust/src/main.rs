//! The Rust side of the iceberg-rust spike (#520): commits to and reads
//! morca's warehouse tables with iceberg-rust, arrow-rs and object_store,
//! no Mojo. Its commands mirror `mojo/side.mojo`:
//!
//!     rside write <dataset> <run> <partition> <attempt> <YYYY-MM> <rows> [note]
//!     rside find  <dataset> <run> <partition>
//!     rside read  <dataset> [snapshot-id]
//!
//! `write` is step `load` of pipeline `spike`: it creates the table if it's
//! missing (schema id/ts/name, spec month(ts), morca's table defaults),
//! with `note` adds an optional `note` string column if the table lacks it
//! (an iceberg-rust schema update), then, unless `find_commit` recognises
//! an earlier attempt's commit, writes the rows as Parquet split by
//! partition and commits one fast-append snapshot carrying the `orca.*`
//! summary. `read` scans the current snapshot, or `snapshot-id`.
//!
//! MORCA_WAREHOUSE is the warehouse: an absolute directory, or
//! `s3://bucket/prefix` with the AWS_* environment (AWS_ENDPOINT_URL for
//! MinIO).

mod catalog;
mod step;

use std::collections::HashMap;
use std::sync::Arc;

use arrow_array::{
    Array, ArrayRef, Float64Array, Int64Array, RecordBatch, StringArray,
    TimestampMicrosecondArray,
};
use catalog::MorcaCatalog;
use futures::TryStreamExt;
use iceberg::arrow::{RecordBatchPartitionSplitter, schema_to_arrow_schema};
use iceberg::io::{
    FileIO, FileIOBuilder, S3_ACCESS_KEY_ID, S3_ENDPOINT, S3_PATH_STYLE_ACCESS, S3_REGION,
    S3_SECRET_ACCESS_KEY,
};
use iceberg::spec::{
    DataFileFormat, NestedField, PrimitiveType, Schema, Transform, Type, UnboundPartitionSpec,
};
use iceberg::table::Table;
use iceberg::transaction::{AddColumn, ApplyTransactionAction, Transaction};
use iceberg::writer::base_writer::data_file_writer::DataFileWriterBuilder;
use iceberg::writer::file_writer::ParquetWriterBuilder;
use iceberg::writer::file_writer::location_generator::{
    DefaultFileNameGenerator, DefaultLocationGenerator,
};
use iceberg::writer::file_writer::rolling_writer::RollingFileWriterBuilder;
use iceberg::writer::{IcebergWriter, IcebergWriterBuilder};
use iceberg::{Catalog, NamespaceIdent, TableCreation, TableIdent};
use iceberg_storage_opendal::OpenDalStorageFactory;
use object_store::ObjectStore;
use object_store::aws::AmazonS3Builder;
use object_store::local::LocalFileSystem;
use parquet::file::properties::WriterProperties;
use step::StepCtx;

type Res<T> = Result<T, Box<dyn std::error::Error>>;

const HOUR_US: i64 = 3_600_000_000;

fn env(k: &str) -> Option<String> {
    std::env::var(k).ok().filter(|v| !v.is_empty())
}

/// The catalog over MORCA_WAREHOUSE: local disk, or S3 from AWS_*.
fn catalog() -> Res<MorcaCatalog> {
    let wh = env("MORCA_WAREHOUSE").ok_or("MORCA_WAREHOUSE is unset")?;
    if let Some(rest) = wh.strip_prefix("s3://") {
        let bucket = rest.split('/').next().unwrap().to_string();
        let region = env("AWS_REGION").unwrap_or_else(|| "us-east-1".into());
        let key = env("AWS_ACCESS_KEY_ID").ok_or("AWS_ACCESS_KEY_ID is unset")?;
        let secret = env("AWS_SECRET_ACCESS_KEY").ok_or("AWS_SECRET_ACCESS_KEY is unset")?;
        let mut s3 = AmazonS3Builder::new()
            .with_bucket_name(&bucket)
            .with_region(&region)
            .with_access_key_id(&key)
            .with_secret_access_key(&secret);
        let mut props = vec![
            (S3_REGION, region.clone()),
            (S3_ACCESS_KEY_ID, key),
            (S3_SECRET_ACCESS_KEY, secret),
        ];
        if let Some(ep) = env("AWS_ENDPOINT_URL") {
            s3 = s3
                .with_endpoint(&ep)
                .with_allow_http(ep.starts_with("http://"))
                .with_virtual_hosted_style_request(false);
            props.push((S3_ENDPOINT, ep));
            props.push((S3_PATH_STYLE_ACCESS, "true".into()));
        }
        let s3 = Arc::new(s3.build()?);
        let store: Arc<dyn ObjectStore> = s3.clone();
        let io = FileIOBuilder::new(Arc::new(OpenDalStorageFactory::S3 {
            customized_credential_load: None,
        }))
        .with_props(props)
        .build();
        return Ok(MorcaCatalog::new(wh, store, Some(s3), io));
    }
    if !wh.starts_with('/') {
        return Err("MORCA_WAREHOUSE must be an absolute path or s3://".into());
    }
    Ok(MorcaCatalog::new(
        wh,
        Arc::new(LocalFileSystem::new()),
        None,
        FileIO::new_with_fs(),
    ))
}

fn ident(dataset: &str) -> Res<TableIdent> {
    let (ns, name) = dataset.rsplit_once('.').ok_or("a dataset is ns.name")?;
    Ok(TableIdent::new(
        NamespaceIdent::from_strs(ns.split('.'))?,
        name.to_string(),
    ))
}

fn base_schema() -> Res<Schema> {
    Ok(Schema::builder()
        .with_schema_id(0)
        .with_fields(vec![
            NestedField::required(1, "id", Type::Primitive(PrimitiveType::Long)).into(),
            NestedField::required(2, "ts", Type::Primitive(PrimitiveType::Timestamp)).into(),
            NestedField::required(3, "name", Type::Primitive(PrimitiveType::String)).into(),
        ])
        .build()?)
}

/// `table_defaults()` in src/morca/_lake/names.mojo.
fn table_defaults() -> HashMap<String, String> {
    HashMap::from([
        (
            "write.metadata.delete-after-commit.enabled".into(),
            "true".into(),
        ),
        ("write.metadata.previous-versions-max".into(), "100".into()),
        (
            "history.expire.max-snapshot-age-ms".into(),
            (30i64 * 86_400_000).to_string(),
        ),
    ])
}

/// The table, created if missing, with `note` added if asked and missing.
async fn ensure_table(cat: &MorcaCatalog, id: &TableIdent, note: bool) -> Res<Table> {
    let mut t = match cat.load_table(id).await {
        Ok(t) => t,
        Err(_) => {
            let spec = UnboundPartitionSpec::builder()
                .with_spec_id(0)
                .add_partition_field(2, "ts_month", Transform::Month)?
                .build();
            let creation = TableCreation::builder()
                .name(id.name().to_string())
                .schema(base_schema()?)
                .partition_spec(spec)
                .properties(table_defaults())
                .build();
            cat.create_table(id.namespace(), creation).await?
        }
    };
    if note && t.metadata().current_schema().field_by_name("note").is_none() {
        let tx = Transaction::new(&t);
        let tx = tx
            .update_schema()
            .add_column(AddColumn::optional(
                "note",
                Type::Primitive(PrimitiveType::String),
            ))
            .apply(tx)?;
        t = tx.commit(cat).await?;
    }
    Ok(t)
}

/// `rows` rows of the month, in the table's current schema: `note` gets a
/// value when the table has it, any other column (Mojo's `score`) null.
fn rows(t: &Table, month: &str, n: usize) -> Res<RecordBatch> {
    let schema = t.metadata().current_schema();
    let arrow = Arc::new(schema_to_arrow_schema(schema)?);
    let (y, m) = month.split_once('-').ok_or("month is YYYY-MM")?;
    let start = days_from_civil(y.parse()?, m.parse()?) * 24 * HOUR_US;
    let mut cols: Vec<ArrayRef> = vec![];
    for f in arrow.fields() {
        let col: ArrayRef = match f.name().as_str() {
            "id" => Arc::new(Int64Array::from_iter_values(0..n as i64)),
            "ts" => Arc::new(TimestampMicrosecondArray::from_iter_values(
                (0..n as i64).map(|i| start + i * HOUR_US),
            )),
            "name" => Arc::new(StringArray::from_iter_values(
                (0..n).map(|i| format!("rust-{month}-{i}")),
            )),
            "note" => Arc::new(StringArray::from_iter_values(
                (0..n).map(|i| format!("note {i}")),
            )),
            "score" => Arc::new(Float64Array::from(vec![None; n])),
            other => return Err(format!("no rows for column {other}").into()),
        };
        cols.push(col);
    }
    Ok(RecordBatch::try_new(arrow, cols)?)
}

fn days_from_civil(y: i64, m: i64) -> i64 {
    let yy = if m <= 2 { y - 1 } else { y };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// Writes `batch` into the table's `data/`, a file per partition.
async fn write_files(t: &Table, batch: &RecordBatch) -> Res<Vec<iceberg::spec::DataFile>> {
    let md = t.metadata();
    let schema = md.current_schema().clone();
    let spec = md.default_partition_spec().clone();
    let splitter = RecordBatchPartitionSplitter::try_new_with_computed_values(
        schema.clone(),
        spec,
    )?;
    let builder = DataFileWriterBuilder::new(RollingFileWriterBuilder::new_with_default_file_size(
        ParquetWriterBuilder::new(WriterProperties::builder().build(), schema),
        t.file_io().clone(),
        DefaultLocationGenerator::new(md)?,
        DefaultFileNameGenerator::new(
            uuid::Uuid::new_v4().to_string(),
            None,
            DataFileFormat::Parquet,
        ),
    ));
    let mut files = vec![];
    for (key, part) in splitter.split(batch)? {
        let mut w = builder.build(Some(key)).await?;
        w.write(part).await?;
        files.extend(w.close().await?);
    }
    Ok(files)
}

fn step_ctx(run: i64, partition: &str, attempt: i64) -> StepCtx {
    StepCtx {
        pipeline: "spike".into(),
        run,
        step: "load".into(),
        partition: partition.into(),
        partitions: partition.into(),
        attempt,
        code: "spike-rust".into(),
        reads: vec![],
        commits: vec![],
        token: String::new(),
    }
}

async fn write(a: &[String]) -> Res<()> {
    let cat = catalog()?;
    let id = ident(&a[2])?;
    let ctx = step_ctx(a[3].parse()?, &a[4], a[5].parse()?);
    let t = ensure_table(&cat, &id, a.get(8).is_some_and(|s| s == "note")).await?;
    if let Some(found) = ctx.find_commit(t.metadata()) {
        println!("found {found}");
        return Ok(());
    }
    let files = write_files(&t, &rows(&t, &a[6], a[7].parse()?)?).await?;
    let id = commit_append(&cat, &id, &ctx, t, files).await?;
    println!("committed {id}");
    Ok(())
}

/// How many times to reload and retry when another writer got there first
/// (`_COMMIT_RETRIES` in src/morca/_lake/impl.mojo).
const COMMIT_RETRIES: u32 = 8;

/// Commits `files` as one fast append with the step's summary, as morca's
/// `_commit_append` does: on a clash, waits 10 ms doubling to 640 ms times
/// a random half to one and a half, reloads, and returns the snapshot if
/// the commit landed after all (found by its summary), or tries again.
/// iceberg-rust's `Transaction::commit` retries too (the table's
/// `commit.retry.*`, 4 times from 100 ms, without jitter): that alone lost
/// a writer in eight at once.
async fn commit_append(
    cat: &MorcaCatalog,
    ident: &TableIdent,
    ctx: &StepCtx,
    mut t: Table,
    files: Vec<iceberg::spec::DataFile>,
) -> Res<i64> {
    let mut attempt = 0;
    loop {
        let summary = ctx.summary(t.metadata().location());
        let tx = Transaction::new(&t);
        let tx = tx
            .fast_append()
            .add_data_files(files.clone())
            .set_snapshot_properties(summary)
            .apply(tx)?;
        match tx.commit(cat).await {
            Ok(t) => return Ok(t.metadata().current_snapshot_id().unwrap_or(-1)),
            Err(e) if e.retryable() && attempt < COMMIT_RETRIES => {
                attempt += 1;
                let base = 0.01 * f64::from(1u32 << (attempt - 1).min(6));
                let wait = base * rand::random_range(0.5..1.5);
                tokio::time::sleep(std::time::Duration::from_secs_f64(wait)).await;
                t = cat.load_table(ident).await?;
                if let Some(found) = ctx.find_commit(t.metadata()) {
                    return Ok(found);
                }
            }
            Err(e) => return Err(format!("can't commit ({} tries): {e}", attempt + 1).into()),
        }
    }
}

async fn find(a: &[String]) -> Res<()> {
    let cat = catalog()?;
    let t = cat.load_table(&ident(&a[2])?).await?;
    let ctx = step_ctx(a[3].parse()?, &a[4], 1);
    println!("found {}", ctx.find_commit(t.metadata()).unwrap_or(-1));
    Ok(())
}

async fn read(a: &[String]) -> Res<()> {
    let cat = catalog()?;
    let t = cat.load_table(&ident(&a[2])?).await?;
    let mut snaps: Vec<_> = t.metadata().snapshots().collect();
    snaps.sort_by_key(|s| s.sequence_number());
    for s in snaps {
        let sum = s.summary();
        let p = &sum.additional_properties;
        let mut orca: Vec<_> = p.iter().filter(|(k, _)| k.starts_with("orca.")).collect();
        orca.sort();
        println!(
            "snapshot {} {} added-records {} total-records {} {}",
            s.snapshot_id(),
            sum.operation.as_str(),
            p.get("added-records").map_or("?", |s| s.as_str()),
            p.get("total-records").map_or("?", |s| s.as_str()),
            orca.iter()
                .map(|(k, v)| format!("{k}={v}"))
                .collect::<Vec<_>>()
                .join(" ")
        );
    }
    let mut scan = t.scan().select_all();
    if let Some(id) = a.get(3) {
        scan = scan.snapshot_id(id.parse()?);
    }
    let batches: Vec<RecordBatch> = scan.build()?.to_arrow().await?.try_collect().await?;
    let (mut n, mut id_sum, mut note, mut score) = (0, 0i64, 0, 0);
    let mut cols = String::new();
    for b in &batches {
        n += b.num_rows();
        if cols.is_empty() {
            cols = b
                .schema()
                .fields()
                .iter()
                .map(|f| f.name().clone())
                .collect::<Vec<_>>()
                .join(",");
        }
        let ids = b
            .column_by_name("id")
            .and_then(|c| c.as_any().downcast_ref::<Int64Array>())
            .ok_or("no id column")?;
        id_sum += ids.iter().flatten().sum::<i64>();
        if let Some(c) = b.column_by_name("note") {
            note += c.len() - c.null_count();
        }
        if let Some(c) = b.column_by_name("score") {
            score += c.len() - c.null_count();
        }
    }
    println!("rows {n} id_sum {id_sum} columns {cols} note {note} score {score}");
    Ok(())
}

#[tokio::main]
async fn main() -> Res<()> {
    let a: Vec<String> = std::env::args().collect();
    match a.get(1).map(String::as_str) {
        Some("write") if a.len() >= 8 => write(&a).await,
        Some("find") if a.len() >= 5 => find(&a).await,
        Some("read") if a.len() >= 3 => read(&a).await,
        _ => {
            eprintln!("usage: rside write|find|read <dataset> ... (see src/main.rs)");
            std::process::exit(2)
        }
    }
}
