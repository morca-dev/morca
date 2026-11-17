# Spike: iceberg-rust against morca's tables (#520)

Can a Rust pipeline commit to and read morca's tables exactly as
`morca.tables` does, with no Mojo? **Yes**, with Apache iceberg-rust,
arrow-rs and object_store as they are, plus a small catalog (about 500
lines, `src/catalog.rs`) that commits the way iceberg-mojo's filesystem
catalog does. iceberg-rust has no catalog that commits that way. Rust
and Mojo writers then commit to one table at once without losing or
doubling a commit, on local disk and on MinIO. That held only after two
listing fixes in the Rust catalog, described under question 1. Questions
2 to 4 needed nothing beyond the crates' public APIs, so the fallback in
question 5 isn't needed. Its costs are written down anyway.

| | |
|---|---|
| Crates | `iceberg` 0.11.0, `iceberg-storage-opendal` 0.11.0 (S3 `FileIO`, opendal 0.58.2), `arrow-array`/`arrow-schema`/`parquet` 58.4.1 (iceberg 0.11.0 is built on arrow 58), `object_store` 0.14.2, tokio 1.54 |
| Toolchain | Rust 1.100.0 stable. iceberg 0.11.0 needs Rust 1.95 or later; morca-worker's floor is 1.85 |
| Mojo side | morca 0.34.0 (`origin/main` e141167) and iceberg-mojo 0.12.0, through `morca.tables` and liblake in the data environment |
| Tested on | macOS 27 arm64. Local disk is APFS on an external NVMe drive. MinIO is conda-forge `minio-server` through `scripts/with-minio.sh` |

## What's here

- `src/catalog.rs` is `MorcaCatalog`, iceberg-rust's `Catalog` trait over
  `object_store`. It loads, creates and commits tables the way
  iceberg-mojo's `FilesystemCatalog` does.
- `src/step.rs` is `StepCtx`, the Rust counterpart of what `morca.Ctx`
  does for commits: the `orca.*` summary of a step's next commit,
  `made`, and `find_commit`.
- `src/main.rs` is `rside`, with three commands. `write` creates the
  table if it's missing, or adds the `note` column, then commits, or finds
  the commit an earlier attempt already made. `find` is `find_commit`.
  `read` reads the current snapshot or one by id.
- `mojo/side.mojo` is the same commands over `morca.tables`: `write` uses
  `ensure_table` and `append` (or adds the `score` column), `find` uses
  `find_commit`, and `read` and `pinned` use `use_snapshot` and a step's
  pin.
- `roundtrip.sh` is the cross-language check (below). `race.sh` runs N
  writers at once and counts failed and lost commits. `build.sh` builds
  both sides.

```sh
spikes/iceberg-rust/build.sh
MORCA_WAREHOUSE=$PWD/build/wh spikes/iceberg-rust/roundtrip.sh
pixi run -e data scripts/with-minio.sh sh -c \
    'MORCA_WAREHOUSE=s3://morca/wh spikes/iceberg-rust/roundtrip.sh'
SIDE=mix ROUNDS=40 MORCA_WAREHOUSE=$PWD/build/wh spikes/iceberg-rust/race.sh
```

The table is the warehouse dataset `spike.<name>`, at
`<warehouse>/spike/<name>`. Its schema starts with `id` (long), `ts`
(timestamp) and `name` (string), and it's partitioned by `month(ts)` as
`ts_month`, like `examples/taxi`. It gets morca's `table_defaults()`.
Mojo adds `score` (double, id 4) with `ensure_table`. Rust adds `note`
(string, id 5) with iceberg-rust's `UpdateSchemaAction`.

`roundtrip.sh` passes on local disk and on MinIO:

1. Rust creates the table and commits as step `load`, run 1, partition
   2024-01. Mojo reads it. Mojo's `find_commit` returns that snapshot for
   the same step and -1 for another partition. A Mojo retry of the step
   (attempt 2) returns the Rust snapshot and commits nothing.
2. Mojo commits 2024-02 and adds `score`. Rust commits 2024-03 and adds
   `note`. A Rust retry of Mojo's 2024-02 step finds Mojo's snapshot and
   commits nothing.
3. Both sides read the current snapshot alike: 12 rows, the columns
   `id,ts,name,score,note`, 3 notes and 4 scores. Both read each earlier
   snapshot by id (`use_snapshot` / `snapshot_id`), with the schema it
   was written with. Mojo's step pin (`Ctx.pinned`, as on a retry) reads
   the Rust snapshots.
4. Writers alternating between Rust and Mojo (8 by default) commit a
   month each to a new table at once, for several rounds. The table has
   each commit exactly once. A writer that runs out of commit retries is
   run again as its step's second attempt, as morca would retry it.
5. A Rust writer and a Mojo writer create the same new table at once,
   for several rounds. Both commit to the one table.

## 1. Catalog

**iceberg-rust has no catalog that commits like morca's**, but it does most
of the work. iceberg 0.11.0 has a `MemoryCatalog`, which keeps the
current-metadata pointer in memory. The REST, Glue, HMS, SQL and S3 Tables
catalogs are separate crates. None of them is a Hadoop-style filesystem
catalog. What makes a small catalog easy:

- `TableCommit::apply` is public. It checks a commit's requirements (the
  table's UUID, and that `main` is still at the snapshot the transaction
  started from) against the metadata it's given. It applies the updates,
  adds the metadata-log entry, and names the next file
  `<V+1>-<uuid>.metadata.json`, the same names iceberg-mojo writes.
- `Transaction::commit` reloads the table and replays its actions when the
  catalog's error is retryable. It retries as many times as the table's
  `commit.retry.*` properties allow (by default 4 times from 100 ms,
  without jitter).
- `TableMetadata` reads and writes the JSON iceberg-mojo writes, with no
  changes either way.

`MorcaCatalog` adds the protocol of `Table.commit_metadata` in
`iceberg/catalog/filesystem.mojo`:

- **Finding the current file.** It starts from `version-hint.text` and
  steps forward with one prefix listing (`<V:05>-`) per version. With no
  hint, it takes the highest version in the directory, and breaks ties by
  `last-updated-ms`.
- **Committing.** It refuses when the next version exists or the hint is
  already past the base. It writes a claim `<V:05>-<uuid>.<ms>.claim`, then
  lists `<V:05>-`. If any other claim younger than 60 s exists, or any
  metadata file of `V`, it removes its claim and returns a retryable
  conflict. Otherwise it writes the metadata file, removes the claim, and
  writes `version-hint.text`.
- **Creating a table.** It claims version 0 the same way
  (`write_first_metadata`).

Every write is `PutMode::Create`, which is `If-None-Match: *` on S3.
iceberg-mojo checks that the file is absent and then writes it. The names
are unique, so neither side relies on that.

Rust and Mojo writers race correctly against each other, because both
read the same claim files. These are the race results (`race.sh`, 8
writers per round, each committing one month to a new table):

| store | writers | rounds | failed (out of retries) | lost |
|---|---|---|---|---|
| local disk | Mojo | 40 | 0 | 0 |
| local disk | Rust | 40 | 0 | 0 |
| local disk | Rust and Mojo | 40 | 0 | 0 |
| local disk | Rust, object_store's listing (`SPIKE_OBJECT_STORE_LIST=1`) | 40 | 0 | **10** |
| MinIO | Mojo | 20 | 58 of 160 | 0 |
| MinIO | Rust | 20 | 0 | 0 |
| MinIO | Rust, listing from an offset (`start-after`) | 20 | 0 | **8** |
| MinIO | Rust and Mojo | 20 | 12 of 160 | 0 |

"Lost" means a writer reported a commit that the table doesn't have: two
writers both won one metadata version, and readers took the other file.
"Failed" means a writer ran out of commit retries and said so. Its step
fails that attempt, and the step's next attempt commits.

Making it safe took three changes. Each one is something a Rust port of
the catalog has to get right:

- **Local disk: list with one `readdir`, as iceberg-mojo does
  (`std.os.listdir`).** The first version listed through object_store's
  `LocalFileSystem`, which walks the directory and stats every entry. That
  lost commits: 3 times in 10 rounds, and 10 times in 40. A trace showed a
  claim's listing that saw neither the rival claim nor the rival's
  metadata file. The rival had linked its metadata file into place and
  then removed its claim, both while the listing ran. A `readdir` isn't a
  snapshot (POSIX leaves unspecified whether it returns entries added or
  removed during the read), and the slow walk made that window wide. With
  one plain `readdir` and no stats, there were no losses in 40 rounds.
  iceberg-mojo's local listing has the same exposure, with a narrower
  window. It had no losses in 40 rounds here. The protocol's own docstring
  says it needs "a listing that sees every write before it".
- **S3: list by key prefix, as iceberg-mojo does.** The second version
  listed the metadata directory from `<dir>/<V:05>-` with
  `list_with_offset` (S3's `start-after`) and stopped after the prefix.
  On MinIO that lost 8 commits in 20 rounds of Rust writers. Listing by
  the key prefix with `PaginatedListStore::list_paginated`
  (`prefix=<dir>/<V:05>-`, as iceberg-mojo sends) lost none. Why MinIO
  serves an offset listing that misses recent writes wasn't investigated.
  Its listing cache is a guess. AWS S3 wasn't tested, since the spike
  uses no cloud credentials.
- **Retry with jitter, as morca does.** iceberg-rust's own retries are
  4 tries with no jitter, and with 8 writers at once a writer ran out of
  them in one of the first five rounds. `rside` wraps the transaction in
  morca's `_commit_append` loop: 8 tries, waits of 10 ms doubling to
  640 ms times a random 0.5 to 1.5, then a reload, and the snapshot is
  returned if the commit landed after all (found by its summary).

On MinIO, Mojo writers often run out of retries when 8 commit at once:
58 of 160 in the Mojo-only rounds, and 12 of 160 in the mixed rounds (the
table above). Nothing is lost, and the step's retry commits, but
it's worth a look on its own if many writers will share a table on S3.
The fix would be morca's retry budget, not this protocol.

Other differences, none of which breaks the other side:

- iceberg-rust parses `write.metadata.delete-after-commit.enabled` but
  doesn't delete old metadata files. A Rust commit leaves them, and
  morca's next commit deletes what has fallen off the metadata log.
- iceberg-rust numbers a new schema `max id + 1` (schema 2 after Mojo's
  1). Mojo does the same.
- iceberg-rust's `Transaction` doesn't call `find_commit` between its own
  retries, so a commit whose outcome is unknown (a write that timed out)
  would be tried again. The outer loop in `rside` checks the summary
  after each failed try, as morca's `_landed` does.

## 2. Summary properties

**Yes.** `FastAppendAction::set_snapshot_properties` takes any map. The
`orca.*` keys go in alongside iceberg-rust's own summary (`operation`,
`added-records`, `total-records`, ...), and the totals carry on correctly
from Mojo's snapshots. `Snapshot::summary().additional_properties` reads
them back. `StepCtx::find_commit` walks the snapshots newest first, by
sequence number, and matches as `Ctx.made` does: pipeline, run, step,
partition and commit number all present and equal, plus the run token
when both sides have one. Mojo recognises Rust commits and Rust recognises
Mojo commits (`roundtrip.sh`, steps 1 and 2). The summary from each side,
for the round trip's three commits:

```text
snapshot ... append added-records 5 total-records 5  orca.attempt=1 orca.code=spike-rust orca.commit=0 orca.partition=2024-01 orca.partitions=2024-01 orca.pipeline=spike orca.reads= orca.run=1 orca.step=load
snapshot ... append added-records 4 total-records 9  orca.attempt=1 orca.code=spike-mojo orca.commit=0 orca.partition=2024-02 ...
snapshot ... append added-records 3 total-records 12 orca.attempt=1 orca.code=spike-rust orca.commit=0 orca.partition=2024-03 ...
```

`StepCtx` copies `Ctx.summary` and `Ctx.made` into Rust. A real Rust
pipeline would get those rules from morca, through the worker protocol or
a shared spec, instead of keeping a second copy (`fuzz/fuzz_summary.mojo`
found edge cases in them).

## 3. Pinned reads

**Yes.** `table.scan().snapshot_id(id)` reads a snapshot with the schema
that snapshot was written with (`id,ts,name` for the first one, without
the columns added later), as `TableScan.use_snapshot` does. Both sides read
the other side's snapshots by id, and Mojo's step pin reads Rust's.
Choosing which snapshot to pin (the snapshot a step's first attempt read,
recorded in morca's state) is morca's job and doesn't involve Iceberg. A
Rust step needs the pinned id from morca and nothing more.

## 4. Writes

**Yes, both ways.** The Rust side writes Parquet with iceberg-rust's
writers on arrow-rs 58. `RecordBatchPartitionSplitter` computes the
`month(ts)` partition. `ParquetWriterBuilder`, `RollingFileWriterBuilder`
and `DataFileWriterBuilder` write `data/ts_month=YYYY-MM/<uuid>-00000.parquet`
with field ids, and the files are committed with `fast_append`. The Mojo
reader reads those files, and iceberg-rust reads Mojo's. Schema evolution
works in both directions:

- Rust adds an optional column, and iceberg-rust assigns it the next id.
- Mojo's `ensure_table` adds one by name, and refuses an id that isn't
  the next one.
- Each side reads the other's older files with the new columns as null.
- Each side writes rows in the current schema, with nulls in the columns
  it doesn't fill.

One thing to plan for: iceberg 0.11.0 is on arrow 58, and morca-worker
(`rust/morca-worker`) is on arrow 60. A Rust step that hands morca-worker
batches it read through iceberg needs the two on one arrow version, or has
to pass the batches through the Arrow C Data interface. That's cheap,
since it's the interface morca-worker already speaks.

Not covered: delete files and merge-on-read, `replace_partitions`
(an overwrite that checks for other writers' files in the partitions it
replaces; iceberg-rust 0.11.0's transactions have fast append but no
overwrite or delete action), compaction (`commit` with removals), filter
pushdown, and sort orders. A Rust pipeline that needs `replaces=` would
have to write that overwrite itself, as manifest-level work on top of
iceberg-rust's `SnapshotProducer`, which is crate-private in 0.11.0. That
part would be real work, or a reason to call liblake for it.

## 5. Fallback: liblake from Rust

Questions 1 to 3 didn't fail, so this is for the record, and for `replaces=`
above.

- **The C ABI.** liblake exports 46 `lake_*` functions
  (`src/morca/_lake/liblake.mojo`). A Rust pipeline reading and committing
  as above would use about 25 of them: load and ensure a table, pin and
  scan, open, read and free a reader, find a commit, append, append
  files, commit, and the writer functions, plus the free functions. The
  step-side calls take a host block of callbacks into morca's `Ctx`
  (summary, pin, fence, committed), so a Rust host would have to provide
  those callbacks. Rows already cross as Arrow C Data, as the `lake_sink_*`
  functions do for Rust workers.
- **Size** (macOS arm64; Linux x86-64 wasn't measured):
  - `liblake.dylib` is 4.3 MB (built with `-g1`).
  - It links `libKGENCompilerRTShared.dylib` (1.2 MB, Mojo's runtime) and
    libSystem.
  - It loads four shims at run time: `libobjectstoremojo` (54 KB),
    `libzstdmojo`, `liblz4mojo` and `libbrotlimojo` (about 35 KB each).
    Those load conda-forge's zstd (0.8 MB), lz4 (0.2 MB), brotli (1.0 MB)
    and OpenSSL (6.0 MB), which a Rust build would otherwise link
    statically itself.
  - The whole set is about 13 MB. For comparison, the stripped release
    `rside` is 31 MB, with tokio, reqwest, opendal and both S3 clients in
    it.
- **Licences.**
  - Mojo runtime: the `mojo-compiler` 1.2.0 conda package, which ships
    `libKGENCompilerRTShared`, is licensed `LicenseRef-Modular-Proprietary`.
    morca already redistributes that library in its runtime image
    (`/opt/morca/lib`, see deploy/Dockerfile). Shipping it inside a Rust
    crate or wheel is the same redistribution in a new channel, and needs
    Modular's licence terms read for that case before anyone relies on
    it. That's a question for the user, not something this spike settles.
  - liblake and the magmalake Mojo libraries are morca's and magmalake's
    own code.
  - The Rust side resolves 401 crates, all under permissive licences:
    MIT or Apache-2.0 for most, and also BSD-2/3-Clause, ISC, Zlib,
    Unicode-3.0, Unlicense, CC0, BSL-1.0 and CDLA-Permissive-2.0
    (webpki-roots). Two crates offer LGPL-2.1 only as an alternative to
    MIT or Apache-2.0. iceberg, parquet, arrow and opendal are Apache-2.0,
    object_store is MIT or Apache-2.0, and tokio is MIT.

## Conclusion

- A pure-Rust pipeline can share morca's tables with iceberg-rust 0.11.0,
  arrow-rs 58 and object_store 0.14, plus a catalog of about 500 lines.
- That catalog has to list exactly as iceberg-mojo does (one `readdir`
  locally, a key-prefix `ListObjectsV2` on S3) and retry with jitter.
  The obvious object_store calls lost commits on both stores.
- What's missing for full parity is `replaces=`: iceberg-rust 0.11.0 has
  no overwrite or delete transaction.
- The race results above suggest two things worth issues of their own in
  morca:
  - Its local-disk commit protocol has the same exposure to non-snapshot
    `readdir` as the Rust port.
  - Its Mojo writers run out of retries on MinIO when 8 commit to one
    table at once.
