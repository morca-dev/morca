use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, OnceLock};

pub use arrow_array;
pub use arrow_schema;
pub use iceberg;

use arrow_array::{Array, RecordBatch, StringArray};
use arrow_schema::SchemaRef;
use futures::TryStreamExt;
use iceberg::arrow::{RecordBatchPartitionSplitter, schema_to_arrow_schema};
use iceberg::io::{
    FileIO, FileIOBuilder, S3_ACCESS_KEY_ID, S3_ENDPOINT, S3_PATH_STYLE_ACCESS, S3_REGION,
    S3_SECRET_ACCESS_KEY,
};
use iceberg::spec::{DataFile, DataFileFormat, Schema, TableMetadata, UnboundPartitionSpec};
use iceberg::table::Table;
use iceberg::transaction::{ApplyTransactionAction, Transaction};
use iceberg::writer::base_writer::data_file_writer::DataFileWriterBuilder;
use iceberg::writer::file_writer::ParquetWriterBuilder;
use iceberg::writer::file_writer::location_generator::{
    DefaultFileNameGenerator, DefaultLocationGenerator,
};
use iceberg::writer::file_writer::rolling_writer::RollingFileWriterBuilder;
use iceberg::writer::{IcebergWriter, IcebergWriterBuilder};
use iceberg::{Catalog, ErrorKind, NamespaceIdent, TableCreation, TableIdent};
use iceberg_storage_opendal::OpenDalStorageFactory;
use object_store::ObjectStore;
use object_store::aws::AmazonS3Builder;
use object_store::local::LocalFileSystem;
use parquet::file::properties::WriterProperties;

use super::catalog::MorcaCatalog;
use crate::ctx::Ctx;
use crate::pipeline::{Built, StepResult, fail};

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("morca: can't start tokio")
    })
}

fn block<F: Future>(f: F) -> F::Output {
    runtime().block_on(f)
}

fn env(k: &str) -> Option<String> {
    std::env::var(k).ok().filter(|v| !v.is_empty())
}

/// The catalog over `MORCA_WAREHOUSE`: local disk, or S3 from `AWS_*`
/// (`AWS_ENDPOINT_URL` for MinIO).
pub(crate) fn catalog() -> Result<MorcaCatalog, String> {
    let wh = env("MORCA_WAREHOUSE").ok_or("morca: MORCA_WAREHOUSE is unset")?;
    let wh = wh.strip_prefix("file://").map(str::to_string).unwrap_or(wh);
    if let Some(rest) = wh.strip_prefix("s3://") {
        let bucket = rest.split('/').next().unwrap_or("").to_string();
        let region = env("AWS_REGION")
            .or_else(|| env("AWS_DEFAULT_REGION"))
            .unwrap_or_else(|| "us-east-1".into());
        let key = env("AWS_ACCESS_KEY_ID").ok_or("morca: AWS_ACCESS_KEY_ID is unset")?;
        let secret = env("AWS_SECRET_ACCESS_KEY").ok_or("morca: AWS_SECRET_ACCESS_KEY is unset")?;
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
        if let Some(t) = env("AWS_SESSION_TOKEN") {
            s3 = s3.with_token(&t);
        }
        if let Some(ep) = env("AWS_ENDPOINT_URL") {
            s3 = s3
                .with_endpoint(&ep)
                .with_allow_http(ep.starts_with("http://"))
                .with_virtual_hosted_style_request(false);
            props.push((S3_ENDPOINT, ep));
            props.push((S3_PATH_STYLE_ACCESS, "true".into()));
        }
        let s3 = Arc::new(s3.build().map_err(|e| format!("morca: S3: {e}"))?);
        let store: Arc<dyn ObjectStore> = s3.clone();
        let io = FileIOBuilder::new(Arc::new(OpenDalStorageFactory::S3 {
            customized_credential_load: None,
        }))
        .with_props(props)
        .build();
        return Ok(MorcaCatalog::new(wh, store, Some(s3), io));
    }
    let abs = if wh.starts_with('/') {
        wh
    } else {
        let cwd = std::env::current_dir().map_err(|e| e.to_string())?;
        format!("{}/{wh}", cwd.display())
    };
    Ok(MorcaCatalog::new(
        abs,
        Arc::new(LocalFileSystem::new()),
        None,
        FileIO::new_with_fs(),
    ))
}

pub(crate) fn ident(dataset: &str) -> Result<TableIdent, String> {
    let (ns, name) = dataset
        .rsplit_once('.')
        .ok_or_else(|| format!("morca: '{dataset}' isn't namespace.table"))?;
    Ok(TableIdent::new(
        NamespaceIdent::from_strs(ns.split('.')).map_err(|e| e.to_string())?,
        name.to_string(),
    ))
}

/// The table, or None if there's none.
async fn load(cat: &MorcaCatalog, id: &TableIdent) -> Result<Option<Table>, String> {
    match cat.load_table(id).await {
        Ok(t) => Ok(Some(t)),
        Err(e) if e.kind() == ErrorKind::TableNotFound => Ok(None),
        Err(e) => Err(format!("morca: can't load {id}: {e}")),
    }
}

fn current(md: &TableMetadata) -> i64 {
    md.current_snapshot_id().unwrap_or(-1)
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

/// How many times to reload and retry when another writer got there first
/// (`_COMMIT_RETRIES` in src/morca/_lake/impl.mojo).
const COMMIT_RETRIES: u32 = 8;

impl Ctx<'_> {
    fn declared(&self, dataset: &str, write: bool) -> StepResult<()> {
        let list = if write {
            &self.declared_writes
        } else {
            &self.declared_reads
        };
        if !list.iter().any(|d| d == dataset) {
            return Err(fail(format!(
                "morca: step {} doesn't declare that it {} {dataset}: add it to its {}",
                self.step,
                if write { "writes" } else { "reads" },
                if write { "writes" } else { "reads" },
            )));
        }
        Ok(())
    }

    /// The Arrow schema of the dataset's current schema, with Iceberg's
    /// field ids: what the batches handed to [`Ctx::append`] must have.
    pub fn arrow_schema(&mut self, dataset: &str) -> StepResult<SchemaRef> {
        let cat = catalog()?;
        let t = block(load(&cat, &ident(dataset)?))?
            .ok_or_else(|| fail(format!("morca: there's no table {dataset}")))?;
        Ok(Arc::new(schema_to_arrow_schema(
            t.metadata().current_schema(),
        )?))
    }

    /// Creates the dataset's table with `schema` (and `spec`, else
    /// unpartitioned) if there's none, with morca's table defaults. A
    /// table that exists is left as it is.
    pub fn ensure_table(
        &mut self,
        dataset: &str,
        schema: Schema,
        spec: Option<UnboundPartitionSpec>,
    ) -> StepResult<()> {
        self.declared(dataset, true)?;
        let cat = catalog()?;
        let id = ident(dataset)?;
        block(async {
            if load(&cat, &id).await?.is_some() {
                return Ok::<(), String>(());
            }
            let mut b = TableCreation::builder()
                .name(id.name().to_string())
                .schema(schema)
                .properties(table_defaults())
                .build();
            if let Some(s) = spec {
                b.partition_spec = Some(s);
            }
            cat.create_table(id.namespace(), b)
                .await
                .map_err(|e| format!("morca: can't create {dataset}: {e}"))?;
            Ok(())
        })?;
        Ok(())
    }

    /// The rows of the dataset at the snapshot this step reads (pinned on a
    /// retry or a resume), recorded as this attempt's read. No table, or
    /// one with no snapshot, is no rows.
    pub fn read(&mut self, dataset: &str) -> StepResult<Vec<RecordBatch>> {
        self.declared(dataset, false)?;
        let cat = catalog()?;
        let id = ident(dataset)?;
        let t = block(load(&cat, &id))?;
        let (location, cur) = match &t {
            Some(t) => (t.metadata().location().to_string(), current(t.metadata())),
            None => (cat.table_location(&id), -1),
        };
        let snap = self.pin(&location, cur);
        let batches = match (&t, snap) {
            (Some(t), s) if s >= 0 => block(async {
                let scan = t
                    .scan()
                    .select_all()
                    .snapshot_id(s)
                    .build()
                    .map_err(|e| e.to_string())?;
                scan.to_arrow()
                    .await
                    .map_err(|e| e.to_string())?
                    .try_collect::<Vec<_>>()
                    .await
                    .map_err(|e| e.to_string())
            })
            .map_err(|e| fail(format!("morca: can't read {dataset} at {s}: {e}")))?,
            _ => vec![],
        };
        self.record_read(&location, snap, dataset)?;
        Ok(batches)
    }

    /// The snapshot an earlier attempt of this run made as this attempt's
    /// next commit to the dataset, or None (`find_commit`). A step that
    /// writes files before [`Ctx::append`] calls it first, so its retry
    /// doesn't write them again.
    pub fn find_commit(&mut self, dataset: &str) -> StepResult<Option<i64>> {
        let cat = catalog()?;
        let Some(t) = block(load(&cat, &ident(dataset)?))? else {
            return Ok(None);
        };
        Ok(self.found(t.metadata()))
    }

    fn found(&self, md: &TableMetadata) -> Option<i64> {
        let loc = md.location();
        let mut snaps: Vec<_> = md.snapshots().collect();
        snaps.sort_by_key(|s| s.sequence_number());
        snaps
            .into_iter()
            .find(|s| self.made(loc, &s.summary().additional_properties))
            .map(|s| s.snapshot_id())
    }

    /// Appends `batches` to the dataset in one snapshot, and returns it:
    /// written as Parquet split by the table's partition spec, fenced,
    /// committed with the `orca.*` summary and recorded. If an earlier
    /// attempt of this run already made this commit, records that one and
    /// writes nothing.
    pub fn append(&mut self, dataset: &str, batches: Vec<RecordBatch>) -> StepResult<i64> {
        self.declared(dataset, true)?;
        let cat = catalog()?;
        let id = ident(dataset)?;
        let mut t = block(load(&cat, &id))?.ok_or_else(|| {
            fail(format!(
                "morca: there's no table {dataset}: ensure_table it first"
            ))
        })?;
        let location = t.metadata().location().to_string();
        if let Some(found) = self.found(t.metadata()) {
            self.log_to_file(&format!(
                "found commit {found} to {dataset} from an earlier attempt"
            ));
            self.record_commit(&location, found, dataset)?;
            return Ok(found);
        }
        let files = block(write_files(&t, &batches))
            .map_err(|e| fail(format!("morca: can't write {dataset}'s files: {e}")))?;
        let mut tries = 0;
        let snap = loop {
            self.fence()?;
            let summary = self.summary(&location);
            let tx = Transaction::new(&t);
            let tx = tx
                .fast_append()
                .add_data_files(files.clone())
                .set_snapshot_properties(summary)
                .apply(tx)?;
            match block(tx.commit(&cat)) {
                Ok(t2) => break current(t2.metadata()),
                Err(e) if e.retryable() && tries < COMMIT_RETRIES => {
                    tries += 1;
                    let base = 0.01 * f64::from(1u32 << (tries - 1).min(6));
                    let wait = base * rand::random_range(0.5..1.5);
                    std::thread::sleep(std::time::Duration::from_secs_f64(wait));
                    t = block(load(&cat, &id))?
                        .ok_or_else(|| fail(format!("morca: {dataset} went away")))?;
                    if let Some(found) = self.found(t.metadata()) {
                        break found;
                    }
                }
                Err(e) => {
                    return Err(fail(format!(
                        "morca: can't commit to {dataset} ({} tries): {e}",
                        tries + 1
                    )));
                }
            }
        };
        self.record_commit(&location, snap, dataset)?;
        Ok(snap)
    }
}

/// Writes `batches` into the table's `data/`, a file per partition.
async fn write_files(t: &Table, batches: &[RecordBatch]) -> iceberg::Result<Vec<DataFile>> {
    let md = t.metadata();
    let schema = md.current_schema().clone();
    let spec = md.default_partition_spec().clone();
    let builder = DataFileWriterBuilder::new(RollingFileWriterBuilder::new_with_default_file_size(
        ParquetWriterBuilder::new(WriterProperties::builder().build(), schema.clone()),
        t.file_io().clone(),
        DefaultLocationGenerator::new(md)?,
        DefaultFileNameGenerator::new(
            uuid::Uuid::new_v4().to_string(),
            None,
            DataFileFormat::Parquet,
        ),
    ));
    let mut files = vec![];
    if spec.is_unpartitioned() {
        let mut w = builder.build(None).await?;
        for b in batches {
            w.write(b.clone()).await?;
        }
        files.extend(w.close().await?);
        return Ok(files);
    }
    let splitter = RecordBatchPartitionSplitter::try_new_with_computed_values(schema, spec)?;
    for b in batches {
        for (key, part) in splitter.split(b)? {
            let mut w = builder.build(Some(key)).await?;
            w.write(part).await?;
            files.extend(w.close().await?);
        }
    }
    Ok(files)
}

/// `sense`: one line per sensed dataset, `<dataset> <snapshot> <orca|other>
/// <partitions|->`, from its current snapshot.
pub(crate) fn sense(p: &Built) -> i32 {
    let sensed = p.sensed();
    if sensed.is_empty() {
        return 0;
    }
    let cat = match catalog() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            return 3;
        }
    };
    for ds in sensed {
        let got = ident(&ds).and_then(|id| block(load(&cat, &id)));
        let t = match got {
            Ok(t) => t,
            Err(e) => {
                eprintln!("{e}");
                return 3;
            }
        };
        let (snap, by, parts) = match t.as_ref().and_then(|t| t.metadata().current_snapshot()) {
            None => (-1, "other".to_string(), "-".to_string()),
            Some(s) => {
                let sum = &s.summary().additional_properties;
                let by = if sum.contains_key("orca.run") {
                    "orca"
                } else {
                    "other"
                };
                let parts = sum
                    .get("orca.partitions")
                    .filter(|v| !v.is_empty())
                    .cloned()
                    .unwrap_or_else(|| "-".into());
                (s.snapshot_id(), by.to_string(), parts)
            }
        };
        println!("{ds} {snap} {by} {parts}");
    }
    0
}

/// `keys`: the keys dataset's snapshot, then each distinct value of its
/// column, sorted.
pub(crate) fn keys(p: &Built) -> i32 {
    let Some((ds, col)) = p.cfg.keys_dataset.clone() else {
        return 2;
    };
    let run = || -> Result<(i64, Vec<String>), String> {
        let cat = catalog()?;
        let Some(t) = block(load(&cat, &ident(&ds)?))? else {
            return Ok((-1, vec![]));
        };
        let snap = current(t.metadata());
        if snap < 0 {
            return Ok((-1, vec![]));
        }
        let batches: Vec<RecordBatch> = block(async {
            t.scan()
                .select([col.as_str()])
                .snapshot_id(snap)
                .build()
                .map_err(|e| e.to_string())?
                .to_arrow()
                .await
                .map_err(|e| e.to_string())?
                .try_collect()
                .await
                .map_err(|e| e.to_string())
        })?;
        let mut keys = std::collections::BTreeSet::new();
        for b in &batches {
            let c = b
                .column_by_name(&col)
                .and_then(|c| c.as_any().downcast_ref::<StringArray>())
                .ok_or_else(|| format!("morca: {ds}.{col} isn't a string column"))?;
            for i in 0..c.len() {
                if c.is_valid(i) {
                    keys.insert(c.value(i).to_string());
                }
            }
        }
        Ok((snap, keys.into_iter().collect()))
    };
    match run() {
        Ok((snap, keys)) => {
            println!("{snap}");
            for k in keys {
                println!("{k}");
            }
            0
        }
        Err(e) => {
            eprintln!("{e}");
            3
        }
    }
}

/// For tests and tools: appends `batches` to the dataset (made with
/// `schema` if there's none, unpartitioned) as a program that isn't a morca
/// pipeline would, with `summary` as its only extra summary properties.
/// Returns the snapshot.
pub fn append_as_other(
    dataset: &str,
    schema: Schema,
    batches: Vec<RecordBatch>,
    summary: HashMap<String, String>,
) -> Result<i64, String> {
    let cat = catalog()?;
    let id = ident(dataset)?;
    block(async {
        let t = match load(&cat, &id).await? {
            Some(t) => t,
            None => {
                let c = TableCreation::builder()
                    .name(id.name().to_string())
                    .schema(schema)
                    .properties(table_defaults())
                    .build();
                cat.create_table(id.namespace(), c)
                    .await
                    .map_err(|e| e.to_string())?
            }
        };
        let files = write_files(&t, &batches).await.map_err(|e| e.to_string())?;
        let tx = Transaction::new(&t);
        let tx = tx
            .fast_append()
            .add_data_files(files)
            .set_snapshot_properties(summary)
            .apply(tx)
            .map_err(|e| e.to_string())?;
        let t = tx.commit(&cat).await.map_err(|e| e.to_string())?;
        Ok(current(t.metadata()))
    })
}

/// A two-column schema (`id` long, `name` string), as the examples use.
pub fn id_name_schema() -> Schema {
    use iceberg::spec::{NestedField, PrimitiveType, Type};
    Schema::builder()
        .with_schema_id(0)
        .with_fields(vec![
            NestedField::required(1, "id", Type::Primitive(PrimitiveType::Long)).into(),
            NestedField::required(2, "name", Type::Primitive(PrimitiveType::String)).into(),
        ])
        .build()
        .expect("a valid schema")
}

/// `n` rows of [`id_name_schema`], named `<prefix>-<i>`.
pub fn id_name_rows(prefix: &str, n: usize) -> Result<RecordBatch, String> {
    use arrow_array::{ArrayRef, Int64Array};
    let schema = Arc::new(schema_to_arrow_schema(&id_name_schema()).map_err(|e| e.to_string())?);
    let ids: ArrayRef = Arc::new(Int64Array::from_iter_values(0..n as i64));
    let names: ArrayRef = Arc::new(StringArray::from_iter_values(
        (0..n).map(|i| format!("{prefix}-{i}")),
    ));
    RecordBatch::try_new(schema, vec![ids, names]).map_err(|e| e.to_string())
}
