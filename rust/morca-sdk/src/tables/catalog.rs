//! morca's filesystem catalog, in Rust (from the iceberg-rust spike, #520,
//! spikes/iceberg-rust/src/catalog.rs): iceberg-rust's `Catalog` over
//! `object_store`, committing the way iceberg-mojo's `FilesystemCatalog`
//! does (iceberg.mojo `src/iceberg/catalog/filesystem.mojo`, 0.12.0).
//!
//! A dataset `ns.name` is the table at `<warehouse>/ns/name`. Its current
//! metadata is the newest `<V>-<uuid>.metadata.json` in `metadata/`:
//! `version-hint.text` names a version to start from, and the newest is
//! found by stepping forward a version at a time with one prefix listing
//! each (`<V:05>-`); with no hint, by listing the directory and taking the
//! highest version, ties broken by `last-updated-ms`.
//!
//! A commit of version `V`:
//!
//! 1. refuses if a file of `V` exists, or the hint is at `V` or past it
//!    (a stale base);
//! 2. writes a claim `<V:05>-<uuid>.<ms>.claim` (empty);
//! 3. lists `<V:05>-`: any other claim younger than a minute, or any
//!    metadata file of `V`, is a rival; claims older than that are removed;
//! 4. with a rival, removes its claim and fails (retryable: the transaction
//!    reloads and tries again); with none, writes `<V:05>-<uuid>.metadata.json`,
//!    removes its claim, and writes `version-hint.text`.
//!
//! Every write here is `PutMode::Create`, which on S3 is `If-None-Match: *`;
//! iceberg-mojo checks existence and then puts. The names are unique, so
//! neither relies on it; the listing is what settles a race, and needs a
//! store whose listings see every write before them (local disk, S3 since
//! 2020, MinIO).
//!
//! Data and manifest files go through iceberg-rust's own `FileIO`.

use std::collections::HashMap;
use std::str::FromStr;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use bytes::Bytes;
use iceberg::io::FileIO;
use iceberg::spec::{TableMetadata, TableMetadataBuilder};
use iceberg::table::Table;
use iceberg::{
    Catalog, Error, ErrorKind, MetadataLocation, Namespace, NamespaceIdent, Result, Runtime,
    TableCommit, TableCreation, TableIdent,
};
use object_store::aws::AmazonS3;
use object_store::list::{PaginatedListOptions, PaginatedListStore};
use object_store::path::Path;
use object_store::{ObjectStore, ObjectStoreExt, PutMode, PutOptions, PutPayload};

const METADATA_SUFFIX: &str = ".metadata.json";
const CLAIM_SUFFIX: &str = ".claim";
const VERSION_HINT: &str = "version-hint.text";
/// As iceberg-mojo's `CLAIM_STALE_MS`.
const CLAIM_STALE_MS: i64 = 60_000;
/// As iceberg-mojo's `CREATE_WAIT_MS`.
const CREATE_WAIT_MS: i64 = 10_000;

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

fn os_err(e: object_store::Error) -> Error {
    Error::new(ErrorKind::Unexpected, "object store").with_source(e)
}

fn conflict(msg: String) -> Error {
    Error::new(ErrorKind::CatalogCommitConflicts, msg).with_retryable(true)
}

/// The leading version of a metadata file name, or None.
fn version_of(name: &str) -> Option<i64> {
    if !name.ends_with(METADATA_SUFFIX) {
        return None;
    }
    let s = name.strip_prefix('v').unwrap_or(name);
    let digits: String = s.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

/// When a claim was made, from its name, or None if it isn't one.
fn claim_ms(name: &str) -> Option<i64> {
    let stem = name.strip_suffix(CLAIM_SUFFIX)?;
    stem.rsplit_once('.')?.1.parse().ok()
}

#[derive(Debug)]
pub(crate) struct MorcaCatalog {
    /// The warehouse root as tables' `location`s spell it: a bare absolute
    /// path, or `s3://bucket/prefix`.
    warehouse: String,
    store: Arc<dyn ObjectStore>,
    /// The same store, for listings by key prefix, on S3.
    s3: Option<Arc<AmazonS3>>,
    /// `s3://bucket/` (with the slash) for S3, "" for local disk.
    scheme_root: String,
    file_io: FileIO,
}

impl MorcaCatalog {
    pub fn new(
        warehouse: String,
        store: Arc<dyn ObjectStore>,
        s3: Option<Arc<AmazonS3>>,
        file_io: FileIO,
    ) -> Self {
        let warehouse = warehouse.trim_end_matches('/').to_string();
        let scheme_root = match warehouse.strip_prefix("s3://") {
            Some(rest) => format!("s3://{}/", rest.split('/').next().unwrap()),
            None => String::new(),
        };
        Self {
            warehouse,
            store,
            s3,
            scheme_root,
            file_io,
        }
    }

    /// `ns.name` -> `<warehouse>/ns/name`.
    pub fn table_location(&self, ident: &TableIdent) -> String {
        format!(
            "{}/{}/{}",
            self.warehouse,
            ident.namespace().join("/"),
            ident.name()
        )
    }

    fn path(&self, location: &str) -> Path {
        let key = if self.scheme_root.is_empty() {
            location
                .trim_start_matches("file://")
                .trim_start_matches('/')
        } else {
            location.strip_prefix(&self.scheme_root).unwrap_or(location)
        };
        Path::from(key)
    }

    /// Names in `dir` starting with `prefix` (one listing).
    async fn names_with_prefix(&self, dir: &str, prefix: &str) -> Result<Vec<String>> {
        if self.scheme_root.is_empty() {
            // One readdir, as iceberg-mojo's local listing (`std.os.listdir`):
            // object_store's LocalFileSystem walks and stats every entry,
            // which widens the window in which a listing misses a file
            // created, and a claim removed, while it runs (spikes/iceberg-rust/README.md).
            let names = match std::fs::read_dir(dir) {
                Ok(rd) => rd
                    .filter_map(|e| e.ok())
                    .filter_map(|e| e.file_name().into_string().ok())
                    .filter(|n| n.starts_with(prefix))
                    .collect(),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => vec![],
                Err(e) => return Err(Error::new(ErrorKind::Unexpected, "listing").with_source(e)),
            };
            return Ok(names);
        }
        // On S3, ListObjectsV2 with the key prefix `<dir>/<prefix>`, as
        // iceberg-mojo lists: one short page. Listing the directory from an
        // offset (start-after) lost commits on MinIO (spikes/iceberg-rust/README.md).
        let s3 = self.s3.as_ref().ok_or_else(|| unsupported("listing"))?;
        let key_prefix = format!("{}/{prefix}", self.path(dir).as_ref());
        let mut names = vec![];
        let mut token = None;
        loop {
            let page = s3
                .list_paginated(
                    Some(&key_prefix),
                    PaginatedListOptions {
                        page_token: token,
                        ..Default::default()
                    },
                )
                .await
                .map_err(os_err)?;
            names.extend(
                page.result
                    .objects
                    .into_iter()
                    .filter_map(|m| m.location.filename().map(str::to_string)),
            );
            token = page.page_token;
            if token.is_none() {
                return Ok(names);
            }
        }
    }

    async fn read_hint(&self, dir: &str) -> Option<i64> {
        let got = self
            .store
            .get(&self.path(&format!("{dir}/{VERSION_HINT}")))
            .await
            .ok()?;
        let b = got.bytes().await.ok()?;
        String::from_utf8_lossy(&b).trim().parse().ok()
    }

    async fn read_metadata(&self, location: &str) -> Result<TableMetadata> {
        let got = self.store.get(&self.path(location)).await.map_err(os_err)?;
        let b = got.bytes().await.map_err(os_err)?;
        Ok(serde_json::from_slice(&b)?)
    }

    /// One version's metadata files, as locations.
    async fn files_of_version(&self, dir: &str, v: i64) -> Result<Vec<String>> {
        Ok(self
            .names_with_prefix(dir, &format!("{v:05}-"))
            .await?
            .into_iter()
            .filter(|n| version_of(n) == Some(v))
            .map(|n| format!("{dir}/{n}"))
            .collect())
    }

    /// Of several files of one version, the one with the latest
    /// `last-updated-ms`.
    async fn newest_of(&self, mut paths: Vec<String>) -> Option<String> {
        paths.sort();
        if paths.len() <= 1 {
            return paths.pop();
        }
        let mut best = (i64::MIN, paths[0].clone());
        for p in paths {
            if let Ok(m) = self.read_metadata(&p).await
                && m.last_updated_ms() > best.0
            {
                best = (m.last_updated_ms(), p);
            }
        }
        Some(best.1)
    }

    /// The current metadata file of the table at `location`, or None.
    pub async fn find_latest_metadata(&self, location: &str) -> Result<Option<String>> {
        let dir = format!("{location}/metadata");
        if let Some(hint) = self.read_hint(&dir).await
            && let Some(mut found) = self
                .newest_of(self.files_of_version(&dir, hint).await?)
                .await
        {
            let mut v = hint + 1;
            while let Some(next) = self.newest_of(self.files_of_version(&dir, v).await?).await {
                found = next;
                v += 1;
            }
            return Ok(Some(found));
        }
        let names = self.names_with_prefix(&dir, "").await?;
        let Some(best) = names.iter().filter_map(|n| version_of(n)).max() else {
            return Ok(None);
        };
        let candidates = names
            .into_iter()
            .filter(|n| version_of(n) == Some(best))
            .map(|n| format!("{dir}/{n}"))
            .collect();
        Ok(self.newest_of(candidates).await)
    }

    async fn put_new(&self, location: &str, data: Bytes) -> Result<()> {
        self.store
            .put_opts(
                &self.path(location),
                PutPayload::from(data),
                PutOptions {
                    mode: PutMode::Create,
                    ..Default::default()
                },
            )
            .await
            .map_err(os_err)?;
        Ok(())
    }

    async fn remove(&self, location: &str) {
        let _ = self.store.delete(&self.path(location)).await;
    }

    /// Other claims on `v` and its metadata files (stale claims removed).
    async fn rivals(&self, dir: &str, v: i64, mine: &str) -> Result<usize> {
        let now = now_ms();
        let mut n = 0;
        for name in self.names_with_prefix(dir, &format!("{v:05}-")).await? {
            if name == mine {
                continue;
            }
            if version_of(&name) == Some(v) {
                n += 1;
            } else if let Some(at) = claim_ms(&name) {
                if now - at > CLAIM_STALE_MS {
                    self.remove(&format!("{dir}/{name}")).await;
                } else {
                    n += 1;
                }
            }
        }
        Ok(n)
    }

    fn claim_name(v: i64) -> String {
        format!("{v:05}-{}.{}{CLAIM_SUFFIX}", uuid::Uuid::new_v4(), now_ms())
    }

    /// Writes metadata version `v` (the file `path`) under a claim, as
    /// iceberg-mojo's `Table.commit_metadata` does. `Ok(false)`: a rival
    /// claimed it too, and nothing was written.
    async fn claim_and_write(&self, dir: &str, v: i64, path: &str, doc: Bytes) -> Result<bool> {
        let claim = Self::claim_name(v);
        let claim_path = format!("{dir}/{claim}");
        self.put_new(&claim_path, Bytes::new()).await?;
        let rivals = match self.rivals(dir, v, &claim).await {
            Ok(n) => n,
            Err(e) => {
                self.remove(&claim_path).await;
                return Err(e);
            }
        };
        if rivals > 0 {
            self.remove(&claim_path).await;
            return Ok(false);
        }
        let wrote = self.put_new(path, doc).await;
        self.remove(&claim_path).await;
        wrote?;
        // Advisory, after the metadata file, as iceberg-mojo writes it.
        let _ = self
            .store
            .put(
                &self.path(&format!("{dir}/{VERSION_HINT}")),
                PutPayload::from(format!("{v}\n")),
            )
            .await;
        Ok(true)
    }

    /// Commits `metadata`, built on `base`, as the table's next version
    /// (`<V+1>-<uuid>.metadata.json`), as `update_table` commits a
    /// transaction: for a snapshot iceberg-rust has no transaction for
    /// (`overwrite`). Refuses, retryably, unless `base` is still the
    /// table's current metadata.
    pub async fn commit_next(&self, base: &Table, metadata: TableMetadata) -> Result<Table> {
        let current = self.load_table(base.identifier()).await?;
        let at = base.metadata_location_result()?;
        if current.metadata_location() != Some(at) {
            return Err(conflict(format!(
                "{} moved on from {at}; reload and retry",
                base.identifier()
            )));
        }
        let path = MetadataLocation::from_str(at)?
            .with_next_version()
            .try_with_new_metadata(&metadata)?
            .to_string();
        let staged = self.table(base.identifier().clone(), path, metadata)?;
        self.write_staged(staged).await
    }

    /// Writes a staged table's metadata as the version its location names,
    /// unless another writer committed that version first.
    async fn write_staged(&self, staged: Table) -> Result<Table> {
        let path = staged.metadata_location_result()?.to_string();
        let (dir, name) = path.rsplit_once('/').unwrap();
        let v = version_of(name).unwrap();
        if !self.files_of_version(dir, v).await?.is_empty()
            || self.read_hint(dir).await.is_some_and(|h| h >= v)
        {
            return Err(conflict(format!(
                "another writer committed version {v} first"
            )));
        }
        let doc = Bytes::from(serde_json::to_vec(staged.metadata())?);
        if !self.claim_and_write(dir, v, &path, doc).await? {
            return Err(conflict(format!(
                "several writers claimed version {v}; reload and retry"
            )));
        }
        Ok(staged)
    }

    fn table(&self, ident: TableIdent, location: String, metadata: TableMetadata) -> Result<Table> {
        Table::builder()
            .file_io(self.file_io.clone())
            .metadata_location(location)
            .metadata(metadata)
            .identifier(ident)
            .runtime(Runtime::current())
            .build()
    }
}

fn unsupported(what: &str) -> Error {
    Error::new(
        ErrorKind::FeatureUnsupported,
        format!("MorcaCatalog: {what}"),
    )
}

#[async_trait]
impl Catalog for MorcaCatalog {
    async fn list_namespaces(&self, _: Option<&NamespaceIdent>) -> Result<Vec<NamespaceIdent>> {
        Err(unsupported("list_namespaces"))
    }
    async fn create_namespace(
        &self,
        ns: &NamespaceIdent,
        _: HashMap<String, String>,
    ) -> Result<Namespace> {
        // A namespace is a directory: nothing to create.
        Ok(Namespace::new(ns.clone()))
    }
    async fn get_namespace(&self, ns: &NamespaceIdent) -> Result<Namespace> {
        Ok(Namespace::new(ns.clone()))
    }
    async fn namespace_exists(&self, _: &NamespaceIdent) -> Result<bool> {
        Ok(true)
    }
    async fn update_namespace(&self, _: &NamespaceIdent, _: HashMap<String, String>) -> Result<()> {
        Err(unsupported("update_namespace"))
    }
    async fn drop_namespace(&self, _: &NamespaceIdent) -> Result<()> {
        Err(unsupported("drop_namespace"))
    }
    async fn list_tables(&self, _: &NamespaceIdent) -> Result<Vec<TableIdent>> {
        Err(unsupported("list_tables"))
    }

    /// Writes version 0 under a claim, as iceberg-mojo's
    /// `write_first_metadata`. A creator that loses waits for the
    /// winner's table and returns it.
    async fn create_table(&self, ns: &NamespaceIdent, creation: TableCreation) -> Result<Table> {
        let ident = TableIdent::new(ns.clone(), creation.name.clone());
        let location = self.table_location(&ident);
        let creation = TableCreation {
            location: Some(location.clone()),
            ..creation
        };
        let metadata = TableMetadataBuilder::from_table_creation(creation)?
            .build()?
            .metadata;
        let dir = format!("{location}/metadata");
        let path = format!("{dir}/00000-{}{METADATA_SUFFIX}", uuid::Uuid::new_v4());
        let doc = Bytes::from(serde_json::to_vec(&metadata)?);
        let deadline = now_ms() + CREATE_WAIT_MS;
        loop {
            if self.claim_and_write(&dir, 0, &path, doc.clone()).await? {
                return self.table(ident, path, metadata);
            }
            loop {
                if !self.files_of_version(&dir, 0).await?.is_empty() {
                    return self.load_table(&ident).await;
                }
                if self.rivals(&dir, 0, "").await? == 0 {
                    break;
                }
                if now_ms() > deadline {
                    return Err(conflict(format!(
                        "another writer is still creating {location}; retry"
                    )));
                }
                tokio::time::sleep(Duration::from_millis(1 + (now_ms() % 10) as u64)).await;
            }
        }
    }

    async fn load_table(&self, ident: &TableIdent) -> Result<Table> {
        let location = self.table_location(ident);
        let Some(path) = self.find_latest_metadata(&location).await? else {
            return Err(Error::new(
                ErrorKind::TableNotFound,
                format!("no table at {location}"),
            ));
        };
        let metadata = self.read_metadata(&path).await?;
        self.table(ident.clone(), path, metadata)
    }

    async fn drop_table(&self, _: &TableIdent) -> Result<()> {
        Err(unsupported("drop_table"))
    }
    async fn purge_table(&self, _: &TableIdent) -> Result<()> {
        Err(unsupported("purge_table"))
    }
    async fn table_exists(&self, ident: &TableIdent) -> Result<bool> {
        Ok(self
            .find_latest_metadata(&self.table_location(ident))
            .await?
            .is_some())
    }
    async fn rename_table(&self, _: &TableIdent, _: &TableIdent) -> Result<()> {
        Err(unsupported("rename_table"))
    }
    async fn register_table(&self, _: &TableIdent, _: String) -> Result<Table> {
        Err(unsupported("register_table"))
    }

    async fn update_table(&self, commit: TableCommit) -> Result<Table> {
        let current = self.load_table(commit.identifier()).await?;
        // Checks the requirements (the table's UUID, main's snapshot, ...)
        // against what's current, applies the updates, and names the next
        // version `<V+1>-<uuid>.metadata.json`.
        let staged = commit.apply(current).map_err(|e| {
            if e.kind() == ErrorKind::CatalogCommitConflicts {
                e.with_retryable(true)
            } else {
                e
            }
        })?;
        self.write_staged(staged).await
    }
}
