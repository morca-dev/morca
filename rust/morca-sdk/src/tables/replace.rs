//! Replacing partitions (`replaces`), as `replace_partitions` in
//! src/morca/_lake/impl.mojo does: iceberg-rust 0.11.0 has no overwrite
//! transaction, so the snapshot is written here from its lower-level parts
//! (manifests, a manifest list, the snapshot and its summary) and committed
//! through [`MorcaCatalog::commit_next`].
//!
//! - The run's first commit to a partition removes every data and delete
//!   file in it that this run didn't commit, and adds the new files, in one
//!   `overwrite` snapshot. Later commits of the run to the partition find
//!   only its own files there and append; files of this run, from any of its
//!   steps and attempts, are never removed.
//! - The partitions are those of the new files under the table's current
//!   spec: no rows replace nothing. Files written under an older spec are
//!   left alone. An unpartitioned table is one partition.
//! - What to remove is planned against the snapshot each try commits on top
//!   of, again on every retry after another writer committed first.
//! - A file in a partition being replaced that another writer committed
//!   after this run's first commit to the table means two writers are
//!   writing the partition at once: the commit fails, committing nothing.
//!
//! The summary carries `orca.replaced-files` and `orca.replaced-records`,
//! the data files and rows removed.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use iceberg::spec::{
    DataContentType, DataFile, DataFileFormat, Datum, FormatVersion, MAIN_BRANCH,
    ManifestContentType, ManifestEntryRef, ManifestFile, ManifestListWriter, ManifestWriter,
    ManifestWriterBuilder, Operation, PartitionSpecRef, PrimitiveType, Snapshot, SnapshotReference,
    SnapshotRetention, SnapshotSummaryCollector, Struct, Summary, TableProperties,
};
use iceberg::table::Table;
use iceberg::{Error, ErrorKind};

use super::catalog::MorcaCatalog;

/// What a replace removes from the snapshot it's planned on.
pub(crate) struct Plan {
    /// Manifests carried into the new snapshot as they are.
    keep: Vec<ManifestFile>,
    /// Manifests that hold a file to remove: each live entry, and whether
    /// it goes.
    rewrite: Vec<(ManifestFile, Vec<(ManifestEntryRef, bool)>)>,
    /// Files removed, data and delete.
    pub removed: usize,
    /// Data files and rows removed.
    pub files: u64,
    pub records: u64,
}

/// The partitions files land in (their `partition` under the default spec).
fn partitions(added: &[DataFile]) -> HashSet<Struct> {
    added.iter().map(|f| f.partition().clone()).collect()
}

/// Whether manifest `mf` may hold files of one of `keys`, by its partition
/// summaries; the others aren't read. Unsure is yes.
fn may_hold(mf: &ManifestFile, types: &[Option<PrimitiveType>], keys: &HashSet<Struct>) -> bool {
    let Some(sums) = &mf.partitions else {
        return true;
    };
    if sums.len() != types.len() || sums.is_empty() {
        return true;
    }
    keys.iter().any(|k| {
        k.fields().len() != sums.len()
            || k.fields().iter().zip(sums).zip(types).all(|((v, s), t)| {
                let Some(v) = v else {
                    return s.contains_null;
                };
                let (Some(t), Some(v)) = (t, v.as_primitive_literal()) else {
                    return true;
                };
                let (Some(lo), Some(hi)) = (&s.lower_bound, &s.upper_bound) else {
                    return false;
                };
                let (Ok(lo), Ok(hi)) = (
                    Datum::try_from_bytes(lo, t.clone()),
                    Datum::try_from_bytes(hi, t.clone()),
                ) else {
                    return true;
                };
                !matches!(lo.literal().partial_cmp(&v), Some(Ordering::Greater))
                    && !matches!(hi.literal().partial_cmp(&v), Some(Ordering::Less))
            })
    })
}

/// Who committed snapshot `id`.
fn by_whom(t: &Table, id: i64) -> String {
    match t.metadata().snapshot_by_id(id) {
        None => "a snapshot no longer in the table's history".into(),
        Some(s) => {
            let p = &s.summary().additional_properties;
            match p.get("orca.run") {
                Some(run) => format!(
                    "run {run} of {}, step {}",
                    p.get("orca.pipeline").map_or("?", String::as_str),
                    p.get("orca.step").map_or("?", String::as_str)
                ),
                None => format!("snapshot {id}, not morca's"),
            }
        }
    }
}

/// The files a replace adding `added` removes from `t`'s current snapshot;
/// an error if another writer is writing one of its partitions.
/// `same_run` says whether a snapshot's summary is this run's.
pub(crate) async fn plan(
    t: &Table,
    added: &[DataFile],
    same_run: impl Fn(&HashMap<String, String>) -> bool,
    name: &str,
) -> Result<Plan, String> {
    let mut out = Plan {
        keep: vec![],
        rewrite: vec![],
        removed: 0,
        files: 0,
        records: 0,
    };
    let md = t.metadata();
    let Some(current) = md.current_snapshot() else {
        return Ok(out);
    };
    let e = |e: Error| format!("morca: can't plan the replace of {name}: {e}");
    let list = t.manifest_list_reader(current).load().await.map_err(e)?;
    if added.is_empty() {
        out.keep = list.consume_entries().into_iter().collect();
        return Ok(out);
    }
    let spec = md.default_partition_spec();
    let ptype = spec.partition_type(md.current_schema()).map_err(e)?;
    let types: Vec<Option<PrimitiveType>> = ptype
        .fields()
        .iter()
        .map(|f| f.field_type.as_primitive_type().cloned())
        .collect();
    let keys = partitions(added);
    // This run's snapshots, and where its first one is in the history.
    let mut snaps: Vec<_> = md.snapshots().collect();
    snaps.sort_by_key(|s| s.sequence_number());
    let mut index = HashMap::new();
    let mut mine = HashSet::new();
    let mut first_mine = None;
    for (i, s) in snaps.iter().enumerate() {
        index.insert(s.snapshot_id(), i);
        if same_run(&s.summary().additional_properties) {
            mine.insert(s.snapshot_id());
            first_mine.get_or_insert(i);
        }
    }
    for mf in list.consume_entries() {
        if mf.partition_spec_id != spec.spec_id() || !may_hold(&mf, &types, &keys) {
            out.keep.push(mf);
            continue;
        }
        let manifest = t.manifest_reader().read(&mf).await.map_err(e)?;
        let mut entries = vec![];
        let mut any = false;
        for en in manifest.entries() {
            if !en.is_alive() {
                continue;
            }
            let snap = en.snapshot_id().unwrap_or(mf.added_snapshot_id);
            let goes = keys.contains(en.data_file().partition()) && !mine.contains(&snap);
            if goes {
                if let (Some(first), Some(&at)) = (first_mine, index.get(&snap))
                    && at > first
                {
                    return Err(format!(
                        "morca: another writer is writing a partition of {name} that this \
                         run replaces: {} committed {} after this run's first commit to it. \
                         Nothing was committed; rerun once the other has finished",
                        by_whom(t, snap),
                        en.file_path()
                    ));
                }
                any = true;
                out.removed += 1;
                if en.content_type() == DataContentType::Data {
                    out.files += 1;
                    out.records += en.record_count();
                }
            }
            entries.push((en.clone(), goes));
        }
        if any {
            out.rewrite.push((mf, entries));
        } else {
            out.keep.push(mf);
        }
    }
    Ok(out)
}

fn new_snapshot_id(t: &Table) -> i64 {
    loop {
        let (a, b) = uuid::Uuid::new_v4().as_u64_pair();
        let id = ((a ^ b) >> 1) as i64;
        if id > 0 && t.metadata().snapshot_by_id(id).is_none() {
            return id;
        }
    }
}

fn manifest_writer(
    t: &Table,
    path: String,
    snap: i64,
    spec: &PartitionSpecRef,
    content: ManifestContentType,
) -> iceberg::Result<ManifestWriter> {
    let md = t.metadata();
    let b = ManifestWriterBuilder::new(
        t.file_io().new_output(path)?,
        Some(snap),
        md.current_schema().clone(),
        spec.as_ref().clone(),
    );
    Ok(match (md.format_version(), content) {
        (FormatVersion::V1, _) => b.build_v1(),
        (FormatVersion::V2, ManifestContentType::Data) => b.build_v2_data(),
        (FormatVersion::V2, ManifestContentType::Deletes) => b.build_v2_deletes(),
        (FormatVersion::V3, ManifestContentType::Data) => b.build_v3_data(),
        (FormatVersion::V3, ManifestContentType::Deletes) => b.build_v3_deletes(),
    })
}

/// `total-*` from the parent's total and this snapshot's changes, as
/// iceberg's `update_totals`: none when the parent has no total.
fn totals(props: &mut HashMap<String, String>, prev: Option<&Summary>) {
    for (total, add, del) in [
        ("total-data-files", "added-data-files", "deleted-data-files"),
        (
            "total-delete-files",
            "added-delete-files",
            "removed-delete-files",
        ),
        ("total-records", "added-records", "deleted-records"),
        ("total-files-size", "added-files-size", "removed-files-size"),
        (
            "total-position-deletes",
            "added-position-deletes",
            "removed-position-deletes",
        ),
        (
            "total-equality-deletes",
            "added-equality-deletes",
            "removed-equality-deletes",
        ),
    ] {
        let base = match prev {
            None => 0,
            Some(p) => match p.additional_properties.get(total).map(|v| v.parse::<u64>()) {
                Some(Ok(v)) => v,
                _ => continue,
            },
        };
        let n = |k: &str| {
            props
                .get(k)
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0)
        };
        let v = (base + n(add)).saturating_sub(n(del));
        props.insert(total.to_string(), v.to_string());
    }
}

/// Commits `added` to `t` as one `overwrite` snapshot that removes what
/// `plan` found, with `summary` (the `orca.*` keys) beside iceberg's own
/// counts, and returns the table as committed.
pub(crate) async fn commit_overwrite(
    cat: &MorcaCatalog,
    t: &Table,
    added: Vec<DataFile>,
    plan: &Plan,
    summary: HashMap<String, String>,
) -> iceberg::Result<Table> {
    let md = t.metadata();
    if t.encryption_manager().is_some() {
        return Err(Error::new(
            ErrorKind::FeatureUnsupported,
            "morca: replacing partitions of an encrypted table",
        ));
    }
    let snap = new_snapshot_id(t);
    let commit = uuid::Uuid::new_v4();
    let dir = md.metadata_location()?;
    let schema = md.current_schema().clone();
    let spec = md.default_partition_spec().clone();
    let mut collector = SnapshotSummaryCollector::default();
    collector.set_partition_summary_limit(
        md.properties()
            .get(TableProperties::PROPERTY_WRITE_PARTITION_SUMMARY_LIMIT)
            .and_then(|v| v.parse().ok())
            .unwrap_or(TableProperties::PROPERTY_WRITE_PARTITION_SUMMARY_LIMIT_DEFAULT),
    );
    let mut n = 0..;
    let mut path = || {
        format!(
            "{dir}/{commit}-m{}.{}",
            n.next().unwrap(),
            DataFileFormat::Avro
        )
    };
    let mut manifests = vec![];
    if !added.is_empty() {
        let mut w = manifest_writer(t, path(), snap, &spec, ManifestContentType::Data)?;
        for f in added {
            collector.add_file(&f, schema.clone(), spec.clone());
            // Its sequence numbers are inherited from the manifest list.
            w.add_file(f, -1)?;
        }
        manifests.push(w.write_manifest_file().await?);
    }
    for (mf, entries) in &plan.rewrite {
        let mut w = manifest_writer(t, path(), snap, &spec, mf.content)?;
        for (en, goes) in entries {
            let seq = en.sequence_number().unwrap_or(mf.sequence_number);
            let file_seq = en.file_sequence_number.or(Some(seq));
            let f = en.data_file().clone();
            if *goes {
                collector.remove_file(&f, schema.clone(), spec.clone());
                w.add_delete_file(f, seq, file_seq)?;
            } else {
                let id = en.snapshot_id().unwrap_or(mf.added_snapshot_id);
                w.add_existing_file(f, id, seq, file_seq)?;
            }
        }
        manifests.push(w.write_manifest_file().await?);
    }
    manifests.extend(plan.keep.iter().cloned());

    let list_path = format!("{dir}/snap-{snap}-0-{commit}.{}", DataFileFormat::Avro);
    let parent = md.current_snapshot_id();
    let seq = md.next_sequence_number();
    let first_row = md.next_row_id();
    let writer = t.file_io().new_output(list_path.clone())?.writer().await?;
    let mut list = match md.format_version() {
        FormatVersion::V1 => ManifestListWriter::v1(writer, snap, parent),
        FormatVersion::V2 => ManifestListWriter::v2(writer, snap, parent, seq),
        FormatVersion::V3 => ManifestListWriter::v3(writer, snap, parent, seq, Some(first_row)),
    };
    list.add_manifests(manifests.into_iter())?;
    let next_row = list.next_row_id();
    list.close().await?;

    let mut props = summary;
    props.extend(collector.build());
    totals(&mut props, md.current_snapshot().map(|s| s.summary()));
    let b = Snapshot::builder()
        .with_manifest_list(list_path)
        .with_snapshot_id(snap)
        .with_parent_snapshot_id(parent)
        .with_sequence_number(seq)
        .with_summary(Summary {
            operation: Operation::Overwrite,
            additional_properties: props,
        })
        .with_schema_id(md.current_schema_id())
        .with_timestamp_ms(now_ms());
    let snapshot = match next_row {
        Some(r) => b.with_row_range(first_row, r - first_row).build(),
        None => b.build(),
    };
    let metadata = md
        .clone()
        .into_builder(Some(t.metadata_location_result()?.to_string()))
        .add_snapshot(snapshot)?
        .set_ref(
            MAIN_BRANCH,
            SnapshotReference::new(snap, SnapshotRetention::branch(None, None, None)),
        )?
        .build()?
        .metadata;
    cat.commit_next(t, metadata).await
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
