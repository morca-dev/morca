"""Iceberg tables from steps: pinned reads, and commits a retry recognises.

```mojo
from morca.tables import append, scan

def load(mut ctx: Ctx, raw: RawFile) raises -> Loaded:
    var src = Table.load_local(raw.table)  # morca.tables.Table
    var batches = scan(ctx, src).to_batches()
    var dst = Table.load_local(OUT)
    var id = append(ctx, dst, transform(batches))
    return Loaded(raw.month, id)
```

- **`scan`** reads a table at a pinned snapshot: the one this step's first
  attempt read, or its current snapshot if this is the first attempt, which
  is then recorded. A retry or a resume of the step sees the same data,
  whatever was committed in between.
- **`append`** and **`commit`** put `morca.*` properties in the summary of the
  snapshot they commit (`Ctx.summary`): pipeline, run, step, partition,
  attempt, commit number, code, and the snapshots read. Before writing
  anything, they look through the table's snapshots for one this step
  already made in this run (`Ctx.made`). If an attempt committed and was
  killed before Postgres heard of it, the retry finds that snapshot and
  returns it instead of committing the data a second time.

A table is known by its location, `metadata.location`, and, when it's in
the warehouse, by its dataset name. `MORCA_WAREHOUSE` is the root of a
filesystem catalog: dataset `nyc.trips` is the table at
`<warehouse>/nyc/trips`, where the warehouse is a directory or a location
in object storage (`s3://bucket/warehouse`, as iceberg's `FileIO` reads it,
from the `AWS_*` environment). **`table`** loads a dataset the step declared, and
**`ensure_table`** creates one it writes if it's missing, and adds the
columns the step's schema has and the table lacks. `scan` refuses a
dataset the step didn't declare in `reads=`, and `append` and `commit` one it
didn't declare in `writes=`. A table outside the warehouse (or with
`MORCA_WAREHOUSE` unset) is used by location as before, and belongs to no
dataset.

**Files written on a worker.** A dista task can write a table's data
files itself and send back only their entries, so the step commits
metadata rather than receiving the rows:

```mojo
def write_hour(day: String, hour: Int) raises -> DataFiles:
    # On a worker: no Ctx, nothing checked or recorded.
    return write_files(load_dataset(EVENTS), fetch(day, hour))

comptime Hour = Task2[String, Int, DataFiles, write_hour]

def load_day(mut ctx: Ctx, d: Day) raises -> Int64:
    var t = ensure_table(ctx, EVENTS, schema())
    if find_commit(ctx, t) >= 0:  # a retry: don't write the files again
        return append_files(ctx, t, DataFiles())
    ref rt = ctx.runtime[Tasks[Hour]]()
    var got = rt.get(rt.remote[Hour](String(d), 0))
    return append_files(ctx, t, got)
```

- **`write_files`** (or a **`FileWriter`**, a batch at a time) writes
  batches into a table's `data/` without committing them, and returns their
  entries as **`DataFiles`**, a dista `Codec` over iceberg's
  `DataFile.encode`. A struct holding a `DataFiles` and plain fields (row
  counts, timings) crosses processes by dista's reflection, with no codec
  of its own.
- **`append_files`** commits entries written elsewhere as one `append`
  snapshot, as `append` commits the files it writes: the same `writes=`
  check, summary and recognition. A retry that finds its commit returns it
  and commits nothing; a step checks `find_commit` first, as above, so a
  retry doesn't have the workers write the files again. Files written by an
  attempt that died before committing them are left unreferenced in
  `data/`, as with an interrupted `append`.

**Replacing partitions.** A new run of a key (`morca backfill --rerun`)
isn't a retry: `find_commit` doesn't recognise an earlier run's commits, so
`append` adds the key's rows a second time. A step that recomputes a key's
rows declares the dataset in `replaces=` rather than `writes=`, and its
`append` and `append_files` to it then replace:

```mojo
comptime LoadDay = Step[
    "load_day", Day, Int64, load_day, Mapped, replaces=[EVENTS],
]
```

- The run's first commit to a partition is an `overwrite` that removes the
  files this run didn't commit from the partitions its new files land in,
  and adds them; its later commits find only the run's files there and
  append. A retry recognises its commits as before, so nothing is
  overwritten twice or lost.
- Another writer's file in such a partition, added after the run's first
  commit to the table, means two runs are replacing it at once: the commit
  raises, committing nothing, and only one run keeps its rows.
- `replace_partitions` and `replace_partition_files` do the same for one
  call, to any table. The summary has `orca.replaced-files` and
  `orca.replaced-records`.

`commit` refuses to remove files that aren't all in the current snapshot,
on every try: a removal planned before another writer replaced them
would otherwise keep both writers' rows.

**liblake (#454).** This module is the thin side of the lake lib-tin: the
work is done by `liblake`, a shared library the morca package ships in
`lib/` (the image in `/opt/morca/lib`), with iceberg, parquet and
objectstore compiled into it, so a pipeline's own build compiles none of
them. It's loaded on first use (`morca._lake.client` says where it's
found; `LAKE_LIB` names it). Rows cross as Arrow C Data, so batches are
`parquet.RecordBatch` (`arrow_mlake`'s) as before. The types here are the
library's handles and mirrors of iceberg's, under iceberg's names:

- **`Table`** (`table`, `ensure_table`, `load_dataset`, `Table.load_local`)
  holds the library's table; **`Table.metadata`** is a copy of what
  pipelines read of iceberg's (`location`, `snapshots` and their
  `summary`, `current_snapshot_id`, `properties`, `schema()`, ...),
  taken when the table loads, refreshes or commits.
- **`TableScan`** has `select`, `filter`, `use_snapshot`, `to_batches`,
  `to_batch_reader` (a batch at a time, as the library reads them),
  `plan_files`, `to_batches_for_tasks` and `count`. A planned file's
  `DataFile` has its `partition` values (`PartitionValue`, like iceberg's
  `Datum`: `partition[0].i` is a day or month partition's number).
- **`Schema`** and **`PartitionSpec`** are Iceberg JSON (`Schema.parse`);
  `Schema.find_by_name`, `find_field` and `has_field` look up its fields
  (`SchemaField`), which the library reads.
- **`table_exists`** says whether the warehouse has a dataset's table.
- **`FileWriter`** writes a file per partition per `write`, or a file per
  partition a row group at a time (`write_row_group`, `close_files`), with
  `options` (iceberg's `WriteOptions`) settable before it writes.
  `Table.read_file` and `Table.delete_file` reach files written and not
  committed, through the table's IO.
- **`BatchBuilder`** builds a batch of a schema's columns a value at a
  time, in place of `iceberg.batch`'s builders.
- **`DataFiles`** carries written entries in iceberg's own encoding, so a
  dista task's bytes are what they were.

`-D MORCA_LAKE_SOURCE=1` builds the library's code into the program
instead, through the same functions: the old way, to compare against and
to fall back on.
"""
from std.memory import bitcast

from arrow_mlake.carrow_import import ImportedArray, ImportedStream
from dista import Codec
from parquet import RecordBatch

from morca.ctx import Ctx
from morca._lake.abi import (
    MODE_APPEND,
    MODE_BY_STEP,
    MODE_REPLACE,
    SNAP_CURRENT,
    SNAP_NONE,
    Dec,
    Enc,
    Slots,
)
from morca._lake.client import (
    Api,
    Exported,
    HostBlock,
    api,
    take_bytes,
    take_error,
)
from morca._lake.batch import (
    BatchBuilder,
    column_of,
    concat_batches,
    ints_of,
    strings_of,
)
from morca._lake.schema import (
    PartitionField,
    PartitionSpec,
    Schema,
    SchemaField,
    parse_transform,
)
from morca._lake.names import (
    DAY_MS,
    DEFAULT_HISTORY_DAYS,
    dataset_of,
    table_defaults,
    warehouse,
)

comptime CONTENT_DATA = 0
"""`DataFile.content` of a data file; 1 and 2 are delete files."""


# ── metadata ────────────────────────────────────────────────────────────────


@fieldwise_init
struct Snapshot(Copyable, Movable):
    """A snapshot, as `TableMeta.snapshots` lists it."""

    var snapshot_id: Int64
    var has_parent: Bool
    var parent_snapshot_id: Int64
    var sequence_number: Int64
    var timestamp_ms: Int64
    var manifest_list: String
    var schema_id: Int
    """-1 when the snapshot doesn't say."""
    var summary: Dict[String, String]


@fieldwise_init
struct MetadataLogEntry(Copyable, Movable):
    var timestamp_ms: Int64
    var metadata_file: String


struct TableMeta(Copyable, Movable):
    """A copy of a table's metadata, as iceberg's `TableMetadata` names it,
    for reading: changing it changes nothing in the table."""

    var location: String
    var format_version: Int
    var table_uuid: String
    var has_current_snapshot: Bool
    var current_snapshot_id: Int64
    var current_schema_id: Int
    var default_spec_id: Int
    var default_sort_order_id: Int
    var last_updated_ms: Int64
    var last_sequence_number: Int64
    var properties: Dict[String, String]
    var schemas: List[Schema]
    var schema_ids: List[Int]
    var partition_specs: List[PartitionSpec]
    var spec_ids: List[Int]
    var snapshots: List[Snapshot]
    var metadata_log: List[MetadataLogEntry]

    def __init__(out self):
        self.location = String()
        self.format_version = 2
        self.table_uuid = String()
        self.has_current_snapshot = False
        self.current_snapshot_id = -1
        self.current_schema_id = 0
        self.default_spec_id = 0
        self.default_sort_order_id = 0
        self.last_updated_ms = 0
        self.last_sequence_number = 0
        self.properties = Dict[String, String]()
        self.schemas = List[Schema]()
        self.schema_ids = List[Int]()
        self.partition_specs = List[PartitionSpec]()
        self.spec_ids = List[Int]()
        self.snapshots = List[Snapshot]()
        self.metadata_log = List[MetadataLogEntry]()

    def schema(self) raises -> Schema:
        """The current schema."""
        for k in range(len(self.schemas)):
            if self.schema_ids[k] == self.current_schema_id:
                return self.schemas[k].copy()
        raise Error("morca: ", self.location, " has no current schema")

    def spec(self) raises -> PartitionSpec:
        """The default partition spec."""
        for k in range(len(self.partition_specs)):
            if self.spec_ids[k] == self.default_spec_id:
                return self.partition_specs[k].copy()
        raise Error("morca: ", self.location, " has no default spec")

    def snapshot_by_id(self, id: Int64) raises -> Snapshot:
        for s in self.snapshots:
            if s.snapshot_id == id:
                return s.copy()
        raise Error("morca: ", self.location, " has no snapshot ", id)

    def current_snapshot(self) raises -> Snapshot:
        if not self.has_current_snapshot:
            raise Error("morca: ", self.location, " has no snapshot")
        return self.snapshot_by_id(self.current_snapshot_id)

    def property_(self, key: String, default: String) -> String:
        return self.properties.get(key, default)


def _meta_of(mut d: Dec) raises -> Tuple[TableMeta, String]:
    var m = TableMeta()
    m.location = d.str()
    var metadata_location = d.str()
    m.format_version = Int(d.int())
    m.table_uuid = d.str()
    m.has_current_snapshot = d.bool()
    m.current_snapshot_id = d.int()
    m.current_schema_id = Int(d.int())
    m.default_spec_id = Int(d.int())
    m.default_sort_order_id = Int(d.int())
    m.last_updated_ms = d.int()
    m.last_sequence_number = d.int()
    m.properties = d.map()
    for _ in range(Int(d.int())):
        m.schema_ids.append(Int(d.int()))
        m.schemas.append(Schema(d.str()))
    for _ in range(Int(d.int())):
        m.spec_ids.append(Int(d.int()))
        m.partition_specs.append(PartitionSpec(d.str()))
    for _ in range(Int(d.int())):
        var id = d.int()
        var has_parent = d.bool()
        var parent = d.int()
        var seq = d.int()
        var ts = d.int()
        var ml = d.str()
        var sid = Int(d.int())
        m.snapshots.append(
            Snapshot(id, has_parent, parent, seq, ts, ml^, sid, d.map())
        )
    for _ in range(Int(d.int())):
        var ts = d.int()
        m.metadata_log.append(MetadataLogEntry(ts, d.str()))
    return (m^, metadata_location^)


# ── tables ──────────────────────────────────────────────────────────────────


struct Table(Copyable, Movable):
    """A table the library holds (a handle), and a copy of its metadata.
    Copies are tables of their own in the library."""

    var handle: Int
    var metadata: TableMeta
    var metadata_location: String
    var _api: Api

    def __init__(out self, handle: Int, a: Api) raises:
        self.handle = handle
        self._api = a.copy()
        self.metadata = TableMeta()
        self.metadata_location = String()
        self._mirror()

    def __init__(out self, *, copy: Self):
        self._api = copy._api.copy()
        self.handle = copy._api.table_copy(copy.handle)
        self.metadata = copy.metadata.copy()
        self.metadata_location = copy.metadata_location.copy()

    def __deinit__(deinit self):
        self._api.table_free(self.handle)

    def _mirror(mut self) raises:
        """Takes the library's metadata again."""
        var got = Slots()
        var err = Slots()
        if self._api.table_meta(self.handle, got.addr, err.addr) != 0:
            raise take_error(self._api, err)
        var b = take_bytes(self._api, got)
        var d = Dec(Int(b.unsafe_ptr()), len(b))
        var meta = _meta_of(d)
        _ = b^
        self.metadata = meta[0].copy()
        self.metadata_location = meta[1].copy()

    @staticmethod
    def load(location: String) raises -> Table:
        """The table at `location`, a directory or in object storage
        (`s3://...`, configured from the `AWS_*` environment)."""
        var a = api()
        var err = Slots()
        var h = a.load(
            Int(location.unsafe_ptr()), location.byte_length(), err.addr
        )
        if h == 0:
            raise take_error(a, err)
        return Table(h, a)

    @staticmethod
    def load_local(location: String) raises -> Table:
        return Table.load(location)

    def refresh(mut self) raises:
        """Takes the table's latest metadata."""
        var err = Slots()
        if self._api.table_refresh(self.handle, err.addr) != 0:
            raise take_error(self._api, err)
        self._mirror()

    def read_file(self, path: String) raises -> List[RecordBatch]:
        """The rows of a Parquet file read through the table's IO: one this
        run wrote (`FileWriter`) and hasn't committed, which no scan sees."""
        var got = Slots(1)
        var err = Slots()
        var rc = self._api.read_file(
            self.handle,
            Int(path.unsafe_ptr()),
            path.byte_length(),
            got.addr,
            err.addr,
        )
        if rc != 0:
            raise take_error(self._api, err)
        var out = List[RecordBatch]()
        if got[0] == 0:
            return out^
        var s = ImportedStream(got[0])
        while True:
            var b = s.next()
            if not b:
                break
            out.append(b.take())
        return out^

    def delete_file(self, path: String) raises:
        """Deletes a file through the table's IO: one this run wrote and
        won't commit. A committed file is the table's to remove (`commit`)."""
        var err = Slots()
        if (
            self._api.delete_file(
                self.handle,
                Int(path.unsafe_ptr()),
                path.byte_length(),
                err.addr,
            )
            != 0
        ):
            raise take_error(self._api, err)

    def scan(self) -> TableScan:
        """A scan of the current snapshot: nothing pinned or checked (`scan`
        is the step's)."""
        return TableScan(self.copy(), SNAP_CURRENT)

    def append(mut self, batches: List[RecordBatch]) raises -> Int64:
        """Iceberg's own append, outside any step: nothing is checked or
        recorded, and a retry appends again. Steps use `append`."""
        var ex = Exported(batches)
        var err = Slots()
        var id = self._api.append(
            0,
            self.handle,
            ex.n(),
            ex.arrays_addr(),
            ex.schemas_addr(),
            MODE_APPEND,
            err.addr,
        )
        _ = ex^  # released after the library has read them
        if id == -2:
            raise take_error(self._api, err)
        self._mirror()
        return id


def load_dataset(dataset: String) raises -> Table:
    """A dataset's table, outside any step: nothing is checked or recorded.
    For reading what isn't a step's input, such as a keyed pipeline's keys
    (`morca.keyed`), and for a dista task's `write_files`."""
    var a = api()
    var err = Slots()
    var h = a.load_dataset(
        Int(dataset.unsafe_ptr()), dataset.byte_length(), err.addr
    )
    if h == 0:
        raise take_error(a, err)
    return Table(h, a)


def table_exists(dataset: String) raises -> Bool:
    """Whether the warehouse has `dataset`'s table, outside any step: nothing
    is checked or recorded. Raises only when there's no warehouse
    (`MORCA_WAREHOUSE`)."""
    var a = api()
    var yes = Slots(1)
    var err = Slots()
    var rc = a.table_exists(
        Int(dataset.unsafe_ptr()), dataset.byte_length(), yes.addr, err.addr
    )
    if rc != 0:
        raise take_error(a, err)
    return yes[0] != 0


def table(mut ctx: Ctx, dataset: String) raises -> Table:
    """The table of a dataset the step declared it reads or writes."""
    var a = api()
    var host = HostBlock(ctx)
    var err = Slots()
    var h = a.table(
        host.addr, Int(dataset.unsafe_ptr()), dataset.byte_length(), err.addr
    )
    _ = host^
    if h == 0:
        raise take_error(a, err)
    return Table(h, a)


def ensure_table(
    mut ctx: Ctx,
    dataset: String,
    schema: Schema,
    spec: PartitionSpec = PartitionSpec.unpartitioned(),
    properties: Dict[String, String] = Dict[String, String](),
) raises -> Table:
    """The table of a dataset the step writes, created empty with `schema`
    and `spec` if the warehouse doesn't have it yet.

    A table that exists is brought up to `schema`: the columns `schema` has
    and the table lacks, matched by name at any depth, are added in one
    schema commit, and a column `schema` makes optional becomes optional.
    Rows already in the table read the new columns as null. Columns the
    table has and `schema` doesn't are kept, and written as null.

    It refuses, with the dataset in the message, what that can't do: a
    column whose type differs, a new column marked required, a required
    column `schema` leaves out, and a field id in `schema` that isn't the
    id the table gave that column. A new column's id should be the next one
    up: the table numbers new fields from its highest id, in the order
    `schema` lists them, a struct's fields after the struct. `spec` is only
    used to create the table.

    `properties` are Iceberg table properties: a table is created with
    them on top of `table_defaults()`, and an existing one gets those it
    lacks or has with another value (one metadata commit; none when all
    are as given). `history.expire.max-snapshot-age-ms` sets how much
    history the scheduler's expiry keeps.
    """
    var a = api()
    var s = schema.to_json()
    var p = spec.to_json()
    var props = Enc()
    props.map(properties)
    var host = HostBlock(ctx)
    var err = Slots()
    var h = a.ensure_table(
        host.addr,
        Int(dataset.unsafe_ptr()),
        dataset.byte_length(),
        Int(s.unsafe_ptr()),
        s.byte_length(),
        Int(p.unsafe_ptr()),
        p.byte_length(),
        props.addr(),
        len(props),
        err.addr,
    )
    _ = host^
    _ = s^
    _ = p^
    _ = props^
    if h == 0:
        raise take_error(a, err)
    return Table(h, a)


# ── reading ─────────────────────────────────────────────────────────────────


@fieldwise_init
struct PartitionValue(Copyable, Movable):
    """One partition value of a data file, as iceberg's `Datum` holds it:
    `kind` is its primitive type (iceberg's `P_*`), and the value is in `i`
    (integers, dates, timestamps, booleans, and a `day`, `month`, `year`,
    `hour` or `bucket` transform's result), `f`, `s` or `b`. `valid` is
    False for a null."""

    var kind: Int
    var i: Int64
    var f: Float64
    var s: String
    var b: List[UInt8]
    var valid: Bool


def _partition_of(mut d: Dec) raises -> List[PartitionValue]:
    var out = List[PartitionValue]()
    for _ in range(Int(d.int())):
        var valid = d.bool()
        var kind = Int(d.int())
        var i = d.int()
        var f = bitcast[DType.float64](d.int())
        var s = d.str()
        out.append(PartitionValue(kind, i, f, s^, d.bytes(), valid))
    return out^


@fieldwise_init
struct DataFile(Copyable, Movable):
    """What a data or delete file entry shows; the entry itself stays in the
    library's encoding (`DataFiles`)."""

    var file_path: String
    var content: Int
    var record_count: Int64
    var file_size_in_bytes: Int64
    var partition_key: String
    """The partition's values, as iceberg keys them: equal for files of one
    partition."""
    var partition: List[PartitionValue]
    """The partition's values, one a partition field, in the spec's order."""


@fieldwise_init
struct FileScanTask(Copyable, Movable):
    """One data file a scan reads."""

    var data_file: DataFile
    var spec_id: Int
    var residual: String
    var start: Int64
    var length: Int64
    var delete_files: Int
    """How many delete files apply to it."""


struct TableScan(Copyable, Movable):
    """A scan of a table at one snapshot, as iceberg's `TableScan` builds one:
    each method returns a new scan."""

    var table: Table
    var snapshot: Int64
    """A snapshot id, `SNAP_CURRENT`, or `SNAP_NONE` for a table a step
    pinned before it had a snapshot."""
    var filter_dsl: String
    var columns: List[String]

    def __init__(out self, var table: Table, snapshot: Int64):
        self.table = table^
        self.snapshot = snapshot
        self.filter_dsl = String()
        self.columns = List[String]()

    def use_snapshot(self, id: Int64) -> Self:
        var s = self.copy()
        s.snapshot = id
        return s^

    def filter(self, dsl: String) -> Self:
        """Rows matching iceberg's filter DSL, e.g. `["=", "month", "x"]`."""
        var s = self.copy()
        s.filter_dsl = dsl.copy()
        return s^

    def select(self, var columns: List[String]) -> Self:
        var s = self.copy()
        s.columns = columns^
        return s^

    def snapshot_id(self) -> Int64:
        """The id of the snapshot the scan reads, or -1 when it reads none
        (a table without snapshots, or one a step pinned empty): what
        iceberg's `scan.snapshot().snapshot_id` is."""
        if self.snapshot == SNAP_NONE:
            return -1
        if self.snapshot >= 0:
            return self.snapshot
        if self.table.metadata.has_current_snapshot:
            return self.table.metadata.current_snapshot_id
        return -1

    def has_any_snapshot(self) -> Bool:
        if self.snapshot == SNAP_NONE:
            return False
        return self.snapshot >= 0 or self.table.metadata.has_current_snapshot

    def _opts(self, paths: List[String]) -> Enc:
        var e = Enc()
        e.int(self.snapshot)
        e.str(self.filter_dsl)
        e.strs(self.columns)
        e.strs(paths)
        return e^

    def to_batches_for_paths(
        self, paths: List[String]
    ) raises -> List[RecordBatch]:
        ref a = self.table._api
        var o = self._opts(paths)
        var stream = Slots(1)
        var err = Slots()
        var rc = a.scan(
            self.table.handle, o.addr(), len(o), stream.addr, err.addr
        )
        _ = o^
        if rc != 0:
            raise take_error(a, err)
        var out = List[RecordBatch]()
        if stream[0] == 0:
            return out^
        var s = ImportedStream(stream[0])
        while True:
            var b = s.next()
            if not b:
                break
            out.append(b.take())
        return out^

    def to_batches(self) raises -> List[RecordBatch]:
        """The rows, as batches."""
        return self.to_batches_for_paths(List[String]())

    def to_batch_reader(self) raises -> BatchReader:
        """The same rows as `to_batches`, in the same order, a batch at a
        time: the library reads the plan a file at a time, so a caller that
        folds the rows holds a file's batches rather than the scan's.
        Planning happens here, so a bad snapshot raises from this call."""
        ref a = self.table._api
        var o = self._opts(List[String]())
        var r = Slots(1)
        var err = Slots()
        var rc = a.reader_open(
            self.table.handle, o.addr(), len(o), r.addr, err.addr
        )
        _ = o^
        if rc != 0:
            raise take_error(a, err)
        return BatchReader(r[0], a)

    def to_batches_for_tasks(
        self, tasks: List[FileScanTask]
    ) raises -> List[RecordBatch]:
        """The rows of tasks `plan_files` returned."""
        var paths = List[String]()
        for t in tasks:
            paths.append(t.data_file.file_path)
        if len(paths) == 0:
            return List[RecordBatch]()
        return self.to_batches_for_paths(paths)

    def plan_files(self) raises -> List[FileScanTask]:
        ref a = self.table._api
        var o = self._opts(List[String]())
        var got = Slots()
        var err = Slots()
        var rc = a.plan_files(
            self.table.handle, o.addr(), len(o), got.addr, err.addr
        )
        _ = o^
        if rc != 0:
            raise take_error(a, err)
        var b = take_bytes(a, got)
        var d = Dec(Int(b.unsafe_ptr()), len(b))
        var tasks = List[FileScanTask]()
        for _ in range(Int(d.int())):
            var path = d.str()
            var content = Int(d.int())
            var records = d.int()
            var size = d.int()
            var spec_id = Int(d.int())
            var key = d.str()
            var partition = _partition_of(d)
            var residual = d.str()
            var start = d.int()
            var length = d.int()
            var deletes = Int(d.int())
            tasks.append(
                FileScanTask(
                    DataFile(path^, content, records, size, key^, partition^),
                    spec_id,
                    residual^,
                    start,
                    length,
                    deletes,
                )
            )
        _ = b^
        return tasks^

    def count(self) raises -> Int64:
        """How many rows the scan returns."""
        ref a = self.table._api
        var o = self._opts(List[String]())
        var n = Slots(1)
        var err = Slots()
        var rc = a.count(self.table.handle, o.addr(), len(o), n.addr, err.addr)
        _ = o^
        if rc != 0:
            raise take_error(a, err)
        return Int64(n[0])


struct BatchReader(Movable):
    """A scan being read a batch at a time (`TableScan.to_batch_reader`), as
    iceberg's `BatchReader` is: the library's reader, a handle."""

    var handle: Int
    """0 for a scan with nothing to read."""
    var _api: Api

    def __init__(out self, handle: Int, a: Api):
        self.handle = handle
        self._api = a.copy()

    def __deinit__(deinit self):
        self._api.reader_free(self.handle)

    def next_batch(mut self) raises -> Optional[RecordBatch]:
        """The next batch, or nothing once the scan is done."""
        if self.handle == 0:
            return None
        var arr = Slots(1)
        var sch = Slots(1)
        var err = Slots()
        var rc = self._api.reader_next(
            self.handle, arr.addr, sch.addr, err.addr
        )
        if rc != 0:
            raise take_error(self._api, err)
        if arr[0] == 0:
            self._api.reader_free(self.handle)
            self.handle = 0
            return None
        return ImportedArray(arr[0], sch[0]).into_batch()


def scan(mut ctx: Ctx, table: Table) raises -> TableScan:
    """A scan of `table` at this step's pinned snapshot.

    A table that had no snapshot when it was first read stays empty for the
    step: the scan sees no files even if some were committed since.
    """
    ref a = table._api
    var host = HostBlock(ctx)
    var id = Slots(1)
    var err = Slots()
    var rc = a.pin(host.addr, table.handle, id.addr, err.addr)
    _ = host^
    if rc != 0:
        raise take_error(a, err)
    return TableScan(table.copy(), Int64(id[0]))


def find_commit(ctx: Ctx, table: Table) -> Int64:
    """The snapshot this step already committed as its next commit to
    `table` in this run, or -1.

    `append` and `commit` check this themselves. A step that writes files
    before committing them, such as a compaction, checks it first, so a retry
    of an attempt that committed doesn't write the files again.
    """
    var host = HostBlock(ctx)
    var id = table._api.find_commit(host.addr, table.handle)
    _ = host^
    return id


# ── written files ───────────────────────────────────────────────────────────


struct DataFiles(Codec, Copyable, Movable, Sized):
    """Data file entries, written but not committed, as a dista task returns
    them: `encode` writes iceberg's `encode_data_files` bytes, as before the
    lib-tin, and `decode` reads them."""

    var bytes: List[UInt8]
    """iceberg's encoding of the entries; empty for none."""

    def __init__(out self):
        self.bytes = List[UInt8]()

    def __init__(out self, var bytes: List[UInt8]):
        self.bytes = bytes^

    def __len__(self) -> Int:
        if len(self.bytes) < 8:
            return 0
        try:
            var d = Dec(Int(self.bytes.unsafe_ptr()), len(self.bytes))
            return Int(d.int())
        except:
            return 0

    def add(mut self, other: DataFiles) raises:
        """Appends `other`'s entries, e.g. from another task."""
        if len(other.bytes) == 0:
            return
        if len(self.bytes) == 0:
            self.bytes = other.bytes.copy()
            return
        var a = api()
        var got = Slots()
        var err = Slots()
        var rc = a.files_concat(
            Int(self.bytes.unsafe_ptr()),
            len(self.bytes),
            Int(other.bytes.unsafe_ptr()),
            len(other.bytes),
            got.addr,
            err.addr,
        )
        if rc != 0:
            raise take_error(a, err)
        self.bytes = take_bytes(a, got)

    def files(self) raises -> List[DataFile]:
        """What each entry shows."""
        var out = List[DataFile]()
        if len(self.bytes) == 0:
            return out^
        var a = api()
        var buf = Slots()
        var err = Slots()
        if (
            a.files_info(
                Int(self.bytes.unsafe_ptr()),
                len(self.bytes),
                buf.addr,
                err.addr,
            )
            != 0
        ):
            raise take_error(a, err)
        var b = take_bytes(a, buf)
        var d = Dec(Int(b.unsafe_ptr()), len(b))
        for _ in range(Int(d.int())):
            var p = d.str()
            var content = Int(d.int())
            var records = d.int()
            var size = d.int()
            var key = d.str()
            out.append(
                DataFile(p^, content, records, size, key^, _partition_of(d))
            )
        _ = b^
        return out^

    def encode(self, mut out: List[UInt8]):
        if len(self.bytes) == 0:
            for _ in range(8):  # a count of none, as iceberg writes it
                out.append(0)
            return
        out.extend(Span(self.bytes))

    @staticmethod
    def decode(buf: Span[UInt8, _], mut pos: Int) raises -> Self:
        var a = api()
        var at = Slots(1)
        Pointer[Int, MutUntrackedOrigin](unsafe_from_address=at.addr)[] = pos
        var got = Slots()
        var err = Slots()
        if (
            a.files_decode(
                Int(buf.unsafe_ptr()), len(buf), at.addr, got.addr, err.addr
            )
            != 0
        ):
            raise take_error(a, err)
        pos = at[0]
        var b = take_bytes(a, got)
        if len(b) == 8 and Self(b.copy()).__len__() == 0:
            return Self()
        return Self(b^)


@fieldwise_init
struct WriteOptions(Copyable, Equatable, Movable):
    """How a `FileWriter` writes, as iceberg's `WriteOptions` names it:
    taken from the table's properties when the writer is made, and the
    writer's to change before it writes."""

    var codec: String
    var row_group_rows: Int
    """Rows per row group at most."""
    var page_size: Int
    """Target uncompressed bytes of values per data page."""
    var compression_level: Int
    """0 is the codec's default; ZSTD takes 1 to 22."""
    var use_dictionary: Bool
    var truncate: Int
    """Bytes the column bounds keep; 0 keeps them whole."""
    var num_workers: Int
    """Threads that encode a file's pages: 1 is the calling thread, 0 every
    core. The files are the same either way."""

    def __eq__(self, other: Self) -> Bool:
        return self._enc().buf == other._enc().buf

    def _enc(self) -> Enc:
        var e = Enc()
        e.str(self.codec)
        e.int(Int64(self.row_group_rows))
        e.int(Int64(self.page_size))
        e.int(Int64(self.compression_level))
        e.bool(self.use_dictionary)
        e.int(Int64(self.truncate))
        e.int(Int64(self.num_workers))
        return e^

    @staticmethod
    def _dec(mut d: Dec) raises -> Self:
        var codec = d.str()
        var rows = Int(d.int())
        var page = Int(d.int())
        var level = Int(d.int())
        var dict = d.bool()
        var truncate = Int(d.int())
        return Self(codec^, rows, page, level, dict, truncate, Int(d.int()))


struct FileWriter(Movable):
    """Writes batches into a table's data files as they come, without
    committing them, and keeps their entries. For a worker that produces a
    table's rows a batch at a time; `write_files` writes a list at once.

    - **`write`** (and `put`) writes a file per partition of each call.
    - **`write_row_group`** adds each partition's rows to that partition's
      open file as a row group, so a big file is written a slice at a time
      and the rows are never all in one batch; **`close_files`** ends the
      open files (`finish` does too). Files come in the order their
      partitions first appear.

    `options` are the table's write properties when it's made; a change to
    them applies to what's written after. It holds the table's schema, spec
    and sort order as they were when it was made: a schema change committed
    meanwhile isn't seen, and `append_files` commits the entries all the
    same.
    """

    var handle: Int
    var rows: Int
    """The rows written so far."""
    var options: WriteOptions
    var _sent: WriteOptions
    """The options the library has."""
    var _api: Api

    def __init__(out self, table: Table) raises:
        self._api = table._api.copy()
        var err = Slots()
        self.handle = self._api.writer_new(table.handle, err.addr)
        self.rows = 0
        if self.handle == 0:
            raise take_error(self._api, err)
        var got = Slots()
        self._api.writer_options(self.handle, got.addr)
        var b = take_bytes(self._api, got)
        var d = Dec(Int(b.unsafe_ptr()), len(b))
        self.options = WriteOptions._dec(d)
        _ = b^
        self._sent = self.options.copy()

    def _write(mut self, batches: List[RecordBatch], row_group: Bool) raises:
        for b in batches:
            self.rows += b.num_rows
        var o = Enc()
        if self.options != self._sent:
            o = self.options._enc()
        var ex = Exported(batches)
        var err = Slots()
        var rc = self._api.writer_write(
            self.handle,
            o.addr(),
            len(o),
            ex.n(),
            ex.arrays_addr(),
            ex.schemas_addr(),
            1 if row_group else 0,
            err.addr,
        )
        _ = ex^
        _ = o^
        if rc != 0:
            raise take_error(self._api, err)
        self._sent = self.options.copy()

    def write(mut self, batches: List[RecordBatch]) raises:
        """Writes `batches`: a file per partition they hold."""
        self._write(batches, False)

    def put(mut self, var batch: RecordBatch) raises:
        """Writes one batch."""
        var one = List[RecordBatch]()
        one.append(batch^)
        self.write(one)

    def write_row_group(mut self, var batch: RecordBatch) raises:
        """Adds `batch`'s rows to the open file of the partition they fall
        in as a row group (more than one past `options.row_group_rows`),
        opening the file on the partition's first rows."""
        var one = List[RecordBatch]()
        one.append(batch^)
        self._write(one, True)

    def close_files(mut self) raises:
        """Ends the files `write_row_group` has open; their entries are
        `finish`'s with the rest."""
        var err = Slots()
        if self._api.writer_close(self.handle, err.addr) != 0:
            raise take_error(self._api, err)

    def finish(deinit self) raises -> DataFiles:
        """The entries of every file written, open ones ended first."""
        var got = Slots()
        var err = Slots()
        if self._api.writer_finish(self.handle, got.addr, err.addr) != 0:
            raise take_error(self._api, err)
        return DataFiles(take_bytes(self._api, got))

    def __deinit__(deinit self):
        self._api.writer_free(self.handle)


def write_files(table: Table, batches: List[RecordBatch]) raises -> DataFiles:
    """Writes `batches` into `table`'s data files without committing them,
    and returns their entries, for `append_files` to commit, here or in
    another process. Nothing is checked or recorded: it's for a dista task,
    which has no `Ctx`, with the table from `load_dataset`."""
    ref a = table._api
    var ex = Exported(batches)
    var got = Slots()
    var err = Slots()
    var rc = a.write_files(
        table.handle,
        ex.n(),
        ex.arrays_addr(),
        ex.schemas_addr(),
        got.addr,
        err.addr,
    )
    _ = ex^
    if rc != 0:
        raise take_error(a, err)
    return DataFiles(take_bytes(a, got))


struct FileChanges(Copyable, Defaultable, Movable):
    """What one snapshot adds and what it takes away: data and delete files
    already written (`write_files`), and the paths of files it removes."""

    var added_data: DataFiles
    var added_deletes: DataFiles
    var removed: List[String]

    def __init__(out self):
        self.added_data = DataFiles()
        self.added_deletes = DataFiles()
        self.removed = List[String]()

    def is_empty(self) -> Bool:
        return (
            len(self.added_data) == 0
            and len(self.added_deletes) == 0
            and len(self.removed) == 0
        )


# ── committing ──────────────────────────────────────────────────────────────


def _append(
    mut ctx: Ctx, mut table: Table, batches: List[RecordBatch], mode: Int
) raises -> Int64:
    var ex = Exported(batches)
    var host = HostBlock(ctx)
    var err = Slots()
    var id = table._api.append(
        host.addr,
        table.handle,
        ex.n(),
        ex.arrays_addr(),
        ex.schemas_addr(),
        mode,
        err.addr,
    )
    _ = host^
    _ = ex^
    if id == -2:
        raise take_error(table._api, err)
    table._mirror()
    return id


def append(
    mut ctx: Ctx, mut table: Table, batches: List[RecordBatch]
) raises -> Int64:
    """Writes `batches` to `table` as one `append` snapshot and returns its ID,
    or returns the snapshot an earlier attempt of this step committed.

    To a dataset the step declared in `replaces=`, it's `replace_partitions`:
    the partitions the rows land in lose what earlier runs left there."""
    return _append(ctx, table, batches, MODE_BY_STEP)


def replace_partitions(
    mut ctx: Ctx, mut table: Table, batches: List[RecordBatch]
) raises -> Int64:
    """Writes `batches` to `table` as one snapshot that also removes the
    files earlier runs left in the partitions the rows land in, and returns
    its ID, or the snapshot an earlier attempt of this step committed.

    What `append` does to a dataset the step declared in `replaces=`; this
    is for a table outside the warehouse, or a step that replaces one table
    and appends to another it declares in `writes=`. The module doc says
    what a replace removes, and when it refuses.
    """
    return _append(ctx, table, batches, MODE_REPLACE)


def _append_files(
    mut ctx: Ctx, mut table: Table, files: DataFiles, mode: Int
) raises -> Int64:
    var host = HostBlock(ctx)
    var err = Slots()
    var id = table._api.append_files(
        host.addr,
        table.handle,
        Int(files.bytes.unsafe_ptr()),
        len(files.bytes),
        mode,
        err.addr,
    )
    _ = host^
    if id == -2:
        raise take_error(table._api, err)
    table._mirror()
    return id


def append_files(
    mut ctx: Ctx, mut table: Table, files: DataFiles
) raises -> Int64:
    """Commits data files already written, here or on a worker
    (`write_files`), to `table` as one `append` snapshot and returns its ID,
    or returns the snapshot an earlier attempt of this step committed, as
    `append` does; the files are then not committed again. No files commits
    an empty snapshot, as `append` of no batches does, so a step's commits
    keep their numbers.

    Refuses a dataset the step didn't declare in `writes=`, and an entry
    that isn't a data file (a delete file goes through `commit`).

    To a dataset the step declared in `replaces=`, it's
    `replace_partition_files`.
    """
    return _append_files(ctx, table, files, MODE_BY_STEP)


def replace_partition_files(
    mut ctx: Ctx, mut table: Table, files: DataFiles
) raises -> Int64:
    """`replace_partitions` of data files already written, here or on a
    worker (`write_files`), as `append_files` commits them."""
    return _append_files(ctx, table, files, MODE_REPLACE)


def commit(
    mut ctx: Ctx,
    mut table: Table,
    operation: String,
    var files: FileChanges,
) raises -> Int64:
    """Commits `files` (data files added and removed, already written) to
    `table` as one snapshot of `operation`, e.g. `replace` for a compaction,
    and returns its ID, or returns the snapshot an earlier attempt of this
    step committed.

    Every file `files` removes must be in the table's current snapshot, on
    the first try and on each retry after another writer committed first:
    if one isn't, another writer removed or replaced it since the caller
    read it, and the commit raises, committing nothing, rather than remove
    the rest and keep both writers' rows. The step's retry plans the change
    again. (`replace_partitions` plans it again itself on each try.)"""
    var e = Enc()
    e.bytes(Span(files.added_data.bytes))
    e.bytes(Span(files.added_deletes.bytes))
    e.strs(files.removed)
    var host = HostBlock(ctx)
    var err = Slots()
    var id = table._api.commit(
        host.addr,
        table.handle,
        Int(operation.unsafe_ptr()),
        operation.byte_length(),
        e.addr(),
        len(e),
        err.addr,
    )
    _ = host^
    _ = e^
    if id == -2:
        raise take_error(table._api, err)
    table._mirror()
    return id
