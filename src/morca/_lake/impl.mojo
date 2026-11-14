"""What `morca.tables` does, inside liblake: the tables code as it was
before the lib-tin (#454), over iceberg, parquet and objectstore. The step's
`Ctx` is the host block (`morca._lake.host.Host`): `table`, `scan`, `append`
and the rest call back into the program for the checks and records `Ctx`
keeps. The module doc of `morca.tables` says what each does.

morca's own tools that need iceberg's types (`morca_maintain`, the data
view) import this directly; pipelines go through `morca.tables`.
"""

from std.memory.alloc import unsafe_alloc
from std.random import random_float64
from std.time import sleep

from dista import Codec
from iceberg.append import AppendResult, prepare_append
from iceberg.catalog.filesystem import FilesystemCatalog, Table
from iceberg.commit import FileChanges, prepare_commit
from iceberg.io import FileIO
from iceberg.expressions import FieldSummary
from iceberg.manifest import (
    CONTENT_DATA,
    DataFile,
    ManifestFile,
    decode_data_files,
    encode_data_files,
    read_manifest_io,
    read_manifest_list_io,
)
from iceberg.metadata import TableMetadata
from iceberg.scan import TableScan
from iceberg.schema import Schema
from iceberg.transforms import PartitionSpec
from iceberg.update_schema import (
    SchemaCommit,
    UpdateSchema,
    prepare_schema_update,
)
from iceberg.util import now_ms
from iceberg.values import Datum, compare, datum_from_bytes_prim
from iceberg.nested import filter_tree, find_struct_path, flatten_leaf
from iceberg.read import _extract
from iceberg.util import uuid4, zero_pad
from iceberg.io import join_path
from iceberg.write import (
    WriteOptions,
    _Aligned,
    _align,
    _partition_key,
    codec_value,
    data_file_from_footer,
    partition_path,
    write_data_files,
)
from parquet import (
    ListSink,
    ParquetWriter,
    RecordBatch,
    WriterOptions,
    WrittenFile,
)
from parquet.arrow import ArrayArena, ArrayData
from parquet_full import AllCodecs

from morca._lake.host import Host
from morca._lake.names import (
    DAY_MS,
    DEFAULT_HISTORY_DAYS,
    _split,
    dataset_of,
    table_defaults,
    warehouse,
)

comptime _COMMIT_RETRIES = 8
"""How many times to reload and retry when another writer got there first."""


def _backoff(attempt: Int):
    """Waits before retry `attempt` (1, 2, ...) of a commit that clashed:
    10 ms doubling with each, to 640 ms, times a random half to one and a
    half. Two writers that both wrote the same metadata version both back
    out (iceberg's filesystem catalog deletes both files), so retrying at
    once can clash again and again; the random wait lets one get ahead.
    Each process seeds `std.random` itself (`morca._internal.cli.seed_random`).
    """
    var base = 0.01 * Float64(1 << min(attempt - 1, 6))
    sleep(base * random_float64(0.5, 1.5))


def _reload(mut table: Table) raises:
    """`table.refresh()`, tried again when the metadata file it chose is
    gone: writers that clashed on a version delete the files they wrote, so
    a reader that listed one a moment before finds it missing."""
    var attempt = 0
    while True:
        try:
            table.refresh()
            return
        except e:
            attempt += 1
            if attempt > _COMMIT_RETRIES:
                raise Error(
                    "morca: can't reload ", table.metadata.location, ": ", e
                )
            _backoff(attempt)


def _load(cat: FilesystemCatalog, ns: String, name: String) raises -> Table:
    """`cat.load_table`, tried again as `_reload` is."""
    var attempt = 0
    while True:
        try:
            return cat.load_table(ns, name)
        except e:
            attempt += 1
            if attempt > _COMMIT_RETRIES:
                raise Error("morca: can't load ", ns, ".", name, ": ", e)
            _backoff(attempt)


def _landed(table: Table, snapshot_id: Int64) -> Bool:
    """Whether a commit that raised is in `table` after all. With
    iceberg-mojo 0.11.0 and earlier, another writer could load a clashing
    writer's metadata file before it was deleted and commit on top of it,
    so retrying appended the same rows twice (#164). That iceberg race
    can also drop a commit that won, which this can't see; the fix is
    iceberg.mojo#88."""
    for s in table.metadata.snapshots:
        if s.snapshot_id == snapshot_id:
            return True
    return False


def _catalog() raises -> FilesystemCatalog:
    """The warehouse's filesystem catalog: local, or in object storage
    (`s3://bucket/prefix`, through objectstore, configured from the
    `AWS_*` environment)."""
    var root = warehouse()
    if not root:
        raise Error(
            "morca: MORCA_WAREHOUSE isn't set, so datasets can't be found"
        )
    if "://" in root and not root.startswith("file://"):
        return FilesystemCatalog(String(root.rstrip("/")), FileIO())
    return FilesystemCatalog.local(root)


def load_dataset(dataset: String) raises -> Table:
    """A dataset's table, outside any step: nothing is checked or recorded.
    For reading what isn't a step's input, such as a keyed pipeline's keys
    (`morca.keyed`)."""
    var name = _split(dataset)
    try:
        return _catalog().load_table(name[0], name[1])
    except e:
        raise Error("morca: can't load ", dataset, ": ", e)


def table_exists(dataset: String) raises -> Bool:
    """Whether the warehouse has `dataset`'s table. Raises only when there's
    no warehouse to look in."""
    var name = _split(dataset)
    return _catalog().table_exists(name[0], name[1])


def table(mut ctx: Host, dataset: String) raises -> Table:
    """The table of a dataset the step declared it reads or writes."""
    if not ctx.declares_write(dataset):
        ctx.check_declared(dataset, write=False)
    var name = _split(dataset)
    return _load(_catalog(), name[0], name[1])


def _wanted_properties(
    have: Dict[String, String], given: Dict[String, String]
) -> Dict[String, String]:
    """What to set: the defaults a table lacks, and what `given` says
    differently from it."""
    var out = Dict[String, String]()
    for e in table_defaults().items():
        if e.key not in have and e.key not in given:
            out[e.key] = e.value
    for e in given.items():
        if have.get(e.key, "\x00") != e.value:
            out[e.key] = e.value
    return out^


def _settle_properties(
    mut ctx: Host,
    mut table: Table,
    given: Dict[String, String],
    dataset: String,
) raises:
    """Commits the properties `_wanted_properties` finds missing, reloading
    and trying again when another writer commits first."""
    var attempt = 0
    while True:
        var want = _wanted_properties(table.metadata.properties, given)
        if len(want) == 0:
            return
        var m = table.metadata.copy()
        var names = String()
        for e in want.items():
            m.properties[e.key] = e.value
            names.write(", " if names else "", e.key, "=", e.value)
        m.last_updated_ms = now_ms()
        try:
            table.commit_metadata(m^)
        except e:
            attempt += 1
            if attempt > _COMMIT_RETRIES:
                raise Error("morca: can't set ", dataset, "'s properties: ", e)
            _backoff(attempt)
            _reload(table)
            continue
        ctx.log(String("set ", dataset, " properties: ", names))
        return


def ensure_table(
    mut ctx: Host,
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
    id the table gave that column, since batches built from `schema` carry
    its ids and a column is matched by id first. A new column's id should be
    the next one up: the table numbers new fields from its highest id, in
    the order `schema` lists them, a struct's fields after the struct.
    `spec` is only used to create the table.

    `properties` are Iceberg table properties: a table is created with
    them on top of `table_defaults()`, and an existing one gets those it
    lacks or has with another value (one metadata commit; none when all
    are as given). `history.expire.max-snapshot-age-ms` sets how much
    history the scheduler's expiry keeps.
    """
    ctx.check_declared(dataset, write=True)
    var name = _split(dataset)
    var cat = _catalog()
    if not cat.table_exists(name[0], name[1]):
        var props = table_defaults()
        for e in properties.items():
            props[e.key] = e.value
        try:
            _ = cat.create_table(name[0], name[1], schema, spec, props^)
        except e:
            # Another run, started at the same time, created it first.
            if not cat.table_exists(name[0], name[1]):
                raise Error("morca: can't create ", dataset, ": ", e)
    var t = _load(cat, name[0], name[1])
    _evolve(ctx, t, schema, dataset)
    _settle_properties(ctx, t, properties, dataset)
    return t^


def _named(s: Schema, name: String) -> Int:
    """Position in `s.flat` of the field named exactly `name`, or -1."""
    for k in range(len(s.flat)):
        if s.flat[k].name == name:
            return k
    return -1


def _required_left_out(table: Schema, given: Schema) -> String:
    """A required field of `table` that `given` leaves out, or "". A field
    under a struct `given` leaves out as a whole doesn't count: the struct
    is optional or it is reported itself."""
    for k in range(len(table.flat)):
        ref f = table.flat[k]
        if not f.required or f.child_pos < 0:
            continue
        if _named(given, f.name) >= 0:
            continue
        if f.parent >= 0 and _named(given, table.flat[f.parent].name) < 0:
            continue
        return f.name
    return ""


def _other_id(table: Schema, given: Schema) -> String:
    """Why a field of `given` has another id in `table`, or ""."""
    for k in range(len(given.flat)):
        ref g = given.flat[k]
        var at = _named(table, g.name)
        if at >= 0 and table.flat[at].id != g.id:
            return String(
                "'",
                g.name,
                "' is field ",
                table.flat[at].id,
                " in the table but ",
                g.id,
                " in the schema given; give it id ",
                table.flat[at].id,
                ", or batches built from this schema land in the wrong",
                " column",
            )
    return ""


def _evolve(
    mut ctx: Host, mut table: Table, schema: Schema, dataset: String
) raises:
    """Adds to `table` what `schema` has and it lacks (see `ensure_table`),
    reloading and trying again when another writer commits first."""
    var attempt = 0
    while True:
        var before = table.metadata.schema()
        var left_out = _required_left_out(before, schema)
        if left_out:
            raise Error(
                "morca: ",
                dataset,
                " requires column '",
                left_out,
                "', which the schema given leaves out; a pipeline can add",
                " columns or make them optional, not drop a required one",
            )
        var update = UpdateSchema()
        update.union_by_name(schema)
        var change: SchemaCommit
        try:
            change = prepare_schema_update(table.metadata, update)
        except e:
            raise Error(
                "morca: ", dataset, " can't take the schema given: ", String(e)
            )
        # Checked against the schema the commit would make, so a schema
        # with the wrong ids is refused before anything is committed.
        var mismatch = _other_id(change.schema, schema)
        if mismatch:
            raise Error("morca: ", dataset, ": ", mismatch)
        if change.changed:
            try:
                table.commit_metadata(change.metadata.copy())
            except e:
                attempt += 1
                if attempt > _COMMIT_RETRIES:
                    raise Error(
                        "morca: can't commit ",
                        dataset,
                        "'s new schema (",
                        attempt,
                        " tries): ",
                        e,
                    )
                _backoff(attempt)
                _reload(table)
                continue
            var added = String("")
            var n_added = 0
            for f in change.schema.flat:
                if _named(before, f.name) < 0:
                    added += String(", " if n_added > 0 else "", f.name)
                    n_added += 1
            ctx.log(
                String(
                    "evolved ",
                    dataset,
                    " to schema ",
                    change.schema.schema_id,
                    ", adding ",
                    n_added,
                    " field(s): ",
                    added,
                )
            )
        return


def scan(mut ctx: Host, table: Table) raises -> TableScan:
    """A scan of `table` at this step's pinned snapshot.

    A table that had no snapshot when it was first read stays empty for the
    step: the scan sees no files even if some were committed since.
    """
    var m = table.metadata.copy()
    var dataset = dataset_of(m.location)
    ctx.check_declared(dataset, write=False)
    var current = m.current_snapshot_id if m.has_current_snapshot else -1
    var id = ctx.pin(m.location, current, dataset)
    if id < 0:
        m.has_current_snapshot = False
        m.current_snapshot_id = -1
        return TableScan(m^, table.io.copy())
    return table.scan().use_snapshot(id)


def find_commit(ctx: Host, table: Table) -> Int64:
    """The snapshot this step already committed as its next commit to
    `table` in this run, or -1.

    `append` and `commit` check this themselves. A step that writes files
    before committing them, such as a compaction, checks it first, so a retry
    of an attempt that committed doesn't write the files again.
    """
    var loc = table.metadata.location
    for s in table.metadata.snapshots:
        if ctx.made(loc, s.summary):
            return s.snapshot_id
    return -1


struct DataFiles(Codec, Copyable, Movable, Sized):
    """Data file entries, written but not committed, as a dista task returns
    them: `encode`/`decode` are iceberg's `encode_data_files` /
    `decode_data_files`, which carry every field of each entry."""

    var files: List[DataFile]

    def __init__(out self):
        self.files = List[DataFile]()

    def __init__(out self, var files: List[DataFile]):
        self.files = files^

    def __len__(self) -> Int:
        return len(self.files)

    def add(mut self, other: DataFiles):
        """Appends `other`'s entries, e.g. from another task."""
        for f in other.files:
            self.files.append(f.copy())

    def encode(self, mut out: List[UInt8]):
        encode_data_files(self.files, out)

    @staticmethod
    def decode(buf: Span[UInt8, _], mut pos: Int) raises -> Self:
        return Self(decode_data_files(buf, pos))


struct _OpenFile(Movable):
    """A data file `FileWriter.write_row_group` is still adding row groups
    to: its writer, the bytes written so far, and its partition."""

    var writer: ParquetWriter[AllCodecs]
    var sink: ListSink
    var values: List[Datum]

    def __init__(
        out self, options: WriteOptions, schema: Schema, var values: List[Datum]
    ) raises:
        var opts = WriterOptions()
        opts.codec = codec_value(options.codec)
        opts.row_group_size = options.row_group_rows
        opts.data_page_size = options.page_size
        opts.compression_level = options.compression_level
        opts.use_dictionary = options.use_dictionary
        opts.num_workers = options.num_workers
        self.writer = ParquetWriter[AllCodecs](opts^)
        self.writer.add_metadata("iceberg.schema", schema.to_json())
        self.sink = ListSink()
        self.values = values^

    def finish(deinit self) raises -> Tuple[WrittenFile, List[UInt8]]:
        """The footer written and the file's bytes."""
        var sink = self.sink^
        var written = self.writer^.finish_to(sink)
        var out = List[UInt8]()
        swap(out, sink.bytes)
        return (written^, out^)


comptime _OpenPtr = Pointer[_OpenFile, MutUntrackedOrigin]


struct _Groups(Movable):
    """A batch's rows by partition, in the order each partition first
    appears: `keep[g]` marks group `g`'s rows."""

    var keys: List[String]
    var values: List[List[Datum]]
    var keep: List[List[Bool]]
    var count: List[Int]

    def __init__(out self):
        self.keys = List[String]()
        self.values = List[List[Datum]]()
        self.keep = List[List[Bool]]()
        self.count = List[Int]()


def _group_rows(
    batch: RecordBatch, aligned: _Aligned, schema: Schema, spec: PartitionSpec
) raises -> _Groups:
    """Which partition each row of `batch` (aligned to `schema` as
    `aligned`) falls in, as iceberg's `write_data_files` works it out."""
    var out = _Groups()
    var n = batch.num_rows
    if len(spec.fields) == 0:
        out.keys.append(String(""))
        out.values.append(List[Datum]())
        out.keep.append(List[Bool](length=n, fill=True))
        out.count.append(n)
        return out^
    var cols = schema.columns()
    var source_arrays = List[ArrayData]()
    var source_types = List[Int]()
    for f in range(len(spec.fields)):
        var src_id = spec.fields[f].source_id
        var top = schema.top_ancestor_id(src_id)
        var slot = -1
        for k in range(len(cols)):
            if cols[k].id == top:
                slot = k
                break
        if slot < 0:
            raise Error(
                "morca: partition field '",
                spec.fields[f].name,
                "' has no source column in the schema",
            )
        var path = List[Int]()
        if src_id != top and not find_struct_path(
            schema.store, cols[slot].type, src_id, path
        ):
            raise Error(
                "morca: partition field '",
                spec.fields[f].name,
                "' is inside a list or a map",
            )
        if aligned.borrowed[slot]:
            source_arrays.append(
                flatten_leaf(batch.arena, aligned.roots[slot], path)
            )
        else:
            source_arrays.append(
                flatten_leaf(aligned.own, aligned.roots[slot], path)
            )
        source_types.append(schema.find_field(src_id).type)
    var groups = Dict[String, Int]()
    for r in range(n):
        var values = List[Datum]()
        for f in range(len(spec.fields)):
            ref t = schema.store.nodes[source_types[f]]
            var v = _extract(
                source_arrays[f], r, t.prim, t.precision, t.scale, t.length
            )
            values.append(spec.fields[f].transform.apply(v))
        var key = _partition_key(values)
        if key in groups:
            var g = groups[key]
            out.keep[g][r] = True
            out.count[g] += 1
        else:
            groups[key] = len(out.keys)
            out.keys.append(key)
            out.values.append(values^)
            var keep = List[Bool](length=n, fill=False)
            keep[r] = True
            out.keep.append(keep^)
            out.count.append(1)
    return out^


struct FileWriter(Movable):
    """Writes batches into a table's data files as they come, without
    committing them, and keeps their entries. For a worker that produces a
    table's rows a batch at a time; `write_files` writes a list at once.

    `write` writes a file per partition of each call. `write_row_group`
    instead adds each partition's rows as a row group of a file per
    partition that stays open, so a file is written a slice at a time;
    `close_files` (or `finish`) ends those files.

    It holds the table's schema, spec, sort order and write properties as
    they were when it was made: a schema change committed meanwhile isn't
    seen, and `append_files` commits the entries all the same.
    """

    var io: FileIO
    var location: String
    var schema: Schema
    var spec: PartitionSpec
    var sort_order_id: Int
    var options: WriteOptions
    var files: DataFiles
    var rows: Int
    """The rows written so far."""
    var _open_keys: Dict[String, Int]
    var _open: List[Int]
    """`_OpenFile`s on the heap, in the order their partitions came."""
    var _counter: Int

    def __init__(out self, table: Table) raises:
        self.io = table.io.copy()
        self.location = table.metadata.location
        self.schema = table.metadata.schema()
        self.spec = table.metadata.spec()
        self.sort_order_id = table.metadata.default_sort_order_id
        self.options = WriteOptions.from_properties(table.metadata.properties)
        self.files = DataFiles()
        self.rows = 0
        self._open_keys = Dict[String, Int]()
        self._open = List[Int]()
        self._counter = 0

    def __deinit__(deinit self):
        """Files still open are dropped unwritten."""
        for a in self._open:
            var p = _OpenPtr(unsafe_from_address=a)
            p.unsafe_deinit_pointee()
            p.unsafe_free()

    def _name(self) -> String:
        try:
            var name = dataset_of(self.location)
            if name:
                return name^
        except:
            pass
        return self.location

    def write(mut self, batches: List[RecordBatch]) raises:
        """Writes `batches`: a file per partition they hold."""
        for b in batches:
            self.rows += b.num_rows
        var written: List[DataFile]
        try:
            written = write_data_files(
                self.io,
                self.location,
                batches,
                self.schema,
                self.spec,
                self.sort_order_id,
                self.options,
            )
        except e:
            raise Error(
                "morca: can't write data files for ", self._name(), ": ", e
            )
        for i in range(len(written)):
            self.files.files.append(written[i].copy())

    def put(mut self, var batch: RecordBatch) raises:
        """Writes one batch."""
        var one = List[RecordBatch]()
        one.append(batch^)
        self.write(one)

    def write_row_group(mut self, batch: RecordBatch) raises:
        """Adds `batch`'s rows to the open file of the partition they fall
        in, as a row group (more than one past `options.row_group_rows`),
        opening the file on the partition's first rows. Rows of several
        partitions make a row group in each one's file."""
        var n = batch.num_rows
        if n == 0:
            return
        try:
            var aligned = _align(batch, self.schema)
            var groups = _group_rows(batch, aligned, self.schema, self.spec)
            for g in range(len(groups.keys)):
                var at: Int
                if groups.keys[g] in self._open_keys:
                    at = self._open[self._open_keys[groups.keys[g]]]
                else:
                    var p = unsafe_alloc[_OpenFile](1)
                    p.unsafe_write(
                        _OpenFile(
                            self.options, self.schema, groups.values[g].copy()
                        )
                    )
                    at = Int(p)
                    self._open_keys[groups.keys[g]] = len(self._open)
                    self._open.append(at)
                ref f = _OpenPtr(unsafe_from_address=at)[]
                if groups.count[g] == n:
                    if (
                        not aligned.all_borrowed()
                        and not aligned.none_borrowed()
                    ):
                        aligned.adopt_borrowed(batch)
                    if aligned.all_borrowed():
                        f.writer.write_batch_to(
                            batch.arena, aligned.roots, f.sink
                        )
                    else:
                        f.writer.write_batch_to(
                            aligned.own, aligned.roots, f.sink
                        )
                    continue
                var arena = ArrayArena()
                var roots = List[Int]()
                for k in range(len(aligned.roots)):
                    if aligned.borrowed[k]:
                        roots.append(
                            filter_tree(
                                batch.arena,
                                aligned.roots[k],
                                groups.keep[g],
                                groups.count[g],
                                arena,
                            )
                        )
                    else:
                        roots.append(
                            filter_tree(
                                aligned.own,
                                aligned.roots[k],
                                groups.keep[g],
                                groups.count[g],
                                arena,
                            )
                        )
                f.writer.write_batch_to(arena, roots, f.sink)
        except e:
            raise Error(
                "morca: can't write a row group for ", self._name(), ": ", e
            )
        self.rows += n

    def close_files(mut self) raises:
        """Ends the files `write_row_group` has open, in the order their
        partitions came, and keeps their entries."""
        var open = self._open^
        self._open = List[Int]()
        self._open_keys = Dict[String, Int]()
        try:
            for a in open:
                var p = _OpenPtr(unsafe_from_address=a)
                var f = p.unsafe_take_pointee()
                p.unsafe_free()
                var values = f.values.copy()
                var done = f^.finish()
                ref written = done[0]
                var dir = join_path(self.location, "data")
                var rel = partition_path(self.spec, values)
                if rel != "":
                    dir = join_path(dir, rel)
                var path = join_path(
                    dir, uuid4() + "-" + zero_pad(self._counter, 5) + ".parquet"
                )
                self._counter += 1
                self.io.write_all(path, Span(done[1]))
                self.files.files.append(
                    data_file_from_footer(
                        written.metadata,
                        written.file_size,
                        path,
                        self.schema,
                        self.spec,
                        values,
                        self.sort_order_id,
                        self.options,
                    )
                )
        except e:
            raise Error(
                "morca: can't write data files for ", self._name(), ": ", e
            )

    def finish(deinit self) raises -> DataFiles:
        """The entries of every file written, the open ones ended first."""
        self.close_files()
        return self.files^


def write_files(table: Table, batches: List[RecordBatch]) raises -> DataFiles:
    """Writes `batches` into `table`'s data files without committing them,
    and returns their entries, for `append_files` to commit, here or in
    another process. Nothing is checked or recorded: it's for a dista task,
    which has no `Ctx`, with the table from `load_dataset`."""
    var w = FileWriter(table)
    w.write(batches)
    return w^.finish()


def _found(mut ctx: Host, mut table: Table) raises -> Int64:
    """What `append`, `append_files` and `commit` do first: reload `table`,
    refuse a dataset the step didn't declare in `writes=`, and return the
    snapshot an earlier attempt committed (recorded again), or -1."""
    _reload(table)
    var loc = table.metadata.location
    var dataset = dataset_of(loc)
    ctx.check_declared(dataset, write=True)
    var found = find_commit(ctx, table)
    if found >= 0:
        ctx.log(String("found its commit ", found, " to ", loc))
        ctx.committed(loc, found, dataset)
    return found


def append(
    mut ctx: Host, mut table: Table, batches: List[RecordBatch]
) raises -> Int64:
    """Writes `batches` to `table` as one `append` snapshot and returns its ID,
    or returns the snapshot an earlier attempt of this step committed.

    To a dataset the step declared in `replaces=`, it's `replace_partitions`:
    the partitions the rows land in lose what earlier runs left there."""
    return _append(ctx, table, batches, ctx.replaces(_dataset(table)))


def _dataset(table: Table) -> String:
    try:
        return dataset_of(table.metadata.location)
    except:
        return ""


def _append(
    mut ctx: Host, mut table: Table, batches: List[RecordBatch], replace: Bool
) raises -> Int64:
    var found = _found(ctx, table)
    if found >= 0:
        return found
    var files: List[DataFile]
    try:
        files = write_data_files(
            table.io,
            table.metadata.location,
            batches,
            table.metadata.schema(),
            table.metadata.spec(),
            table.metadata.default_sort_order_id,
            WriteOptions.from_properties(table.metadata.properties),
        )
    except e:
        raise Error(
            "morca: can't write data files for ",
            dataset_of(table.metadata.location),
            ": ",
            e,
        )
    if replace:
        return _commit_replace(ctx, table, files^)
    return _commit_append(ctx, table, files^)


def append_files(
    mut ctx: Host, mut table: Table, files: List[DataFile]
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
    return _append_files(ctx, table, files, ctx.replaces(_dataset(table)))


def _append_files(
    mut ctx: Host, mut table: Table, files: List[DataFile], replace: Bool
) raises -> Int64:
    for f in files:
        if f.content != CONTENT_DATA:
            raise Error(
                "morca: append_files takes data files, and ",
                f.file_path,
                " is a delete file (content ",
                f.content,
                "); commit it with morca.tables.commit",
            )
    var found = _found(ctx, table)
    if found >= 0:
        return found
    if replace:
        return _commit_replace(ctx, table, files.copy())
    return _commit_append(ctx, table, files.copy())


def append_files(
    mut ctx: Host, mut table: Table, files: DataFiles
) raises -> Int64:
    """`append_files` of the entries a task returned."""
    return append_files(ctx, table, files.files)


def _commit_append(
    mut ctx: Host, mut table: Table, var files: List[DataFile]
) raises -> Int64:
    """Commits `files` to `table` as an `append` with this step's summary,
    reloading and trying again when another writer commits first."""
    var loc = table.metadata.location
    var dataset = dataset_of(loc)
    var attempt = 0
    while True:
        var result = prepare_append(
            table.io, table.metadata, files.copy(), ctx.summary(loc)
        )
        # Not if this process may have lost its run (`Ctx.fence`).
        ctx.fence()
        try:
            table.commit(result)
        except e:
            attempt += 1
            if attempt > _COMMIT_RETRIES:
                raise Error(
                    "morca: can't commit to ",
                    dataset,
                    " (",
                    attempt,
                    " tries): ",
                    e,
                )
            _backoff(attempt)
            _reload(table)
            # A commit that landed after all is done, not tried again.
            if not _landed(table, result.snapshot_id):
                continue
        ctx.committed(loc, result.snapshot_id, dataset)
        _reload(table)
        return result.snapshot_id


def commit(
    mut ctx: Host,
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
    var found = _found(ctx, table)
    if found >= 0:
        return found
    var loc = table.metadata.location
    var dataset = dataset_of(loc)
    var removing = _distinct(files.removed)
    var attempt = 0
    while True:
        var result = _prepare_commit(
            table,
            operation,
            files.copy(),
            ctx.summary(loc),
            dataset if dataset else loc,
        )
        _check_removed(result, removing, dataset if dataset else loc)
        # Not if this process may have lost its run (`Ctx.fence`).
        ctx.fence()
        try:
            table.commit(result)
        except e:
            attempt += 1
            if attempt > _COMMIT_RETRIES:
                raise Error(
                    "morca: can't commit to ",
                    dataset,
                    " (",
                    attempt,
                    " tries): ",
                    e,
                )
            _backoff(attempt)
            _reload(table)
            # A commit that landed after all is done, not tried again.
            if not _landed(table, result.snapshot_id):
                continue
        ctx.committed(loc, result.snapshot_id, dataset)
        _reload(table)
        return result.snapshot_id


def _prepare_commit(
    table: Table,
    operation: String,
    var files: FileChanges,
    var summary: Dict[String, String],
    name: String,
) raises -> AppendResult:
    """`prepare_commit`, its refusal of removals not in the current snapshot
    (iceberg-mojo 0.12.0 checks that itself) naming the table."""
    try:
        return prepare_commit(
            table.io, table.metadata, operation, files^, summary^
        )
    except e:
        var why = String(e)
        if "files to delete" in why:
            raise Error("morca: the commit to ", name, " was refused: ", why)
        raise e^


def _distinct(paths: List[String]) -> Int:
    var seen = Dict[String, Bool]()
    for p in paths:
        seen[p] = True
    return len(seen)


def _summary_int(s: Dict[String, String], key: String) -> Int:
    try:
        return Int(s.get(key, "0"))
    except:
        return 0


def _check_removed(result: AppendResult, removing: Int, name: String) raises:
    """Raises unless the prepared commit removes all `removing` files: the
    ones it doesn't find aren't in the snapshot it was planned on."""
    if removing == 0:
        return
    ref m = result.metadata
    var s = m.snapshots[len(m.snapshots) - 1].summary.copy()
    var found = _summary_int(s, "deleted-data-files") + _summary_int(
        s, "removed-delete-files"
    )
    if found < removing:
        raise Error(
            "morca: ",
            removing - found,
            " of the ",
            removing,
            " files this commit to ",
            name,
            " removes aren't in its current snapshot: another writer removed",
            " or replaced them since they were read. Nothing was committed;",
            " plan the change again (the step's retry does)",
        )


# ── replacing partitions ─────────────────────────────────────────────────────


def replace_partitions(
    mut ctx: Host, mut table: Table, batches: List[RecordBatch]
) raises -> Int64:
    """Writes `batches` to `table` as one snapshot that also removes the
    files earlier runs left in the partitions the rows land in, and returns
    its ID, or the snapshot an earlier attempt of this step committed.

    What `append` does to a dataset the step declared in `replaces=`; this
    is for a table outside the warehouse, or a step that replaces one table
    and appends to another it declares in `writes=`.

    - The run's first commit to a partition is an `overwrite` that removes
      every data and delete file in it that this run didn't commit, and
      adds the new files. Later commits of the run to the partition find
      only its own files there and append; files of this run, from any of
      its steps and attempts, are never removed.
    - The partitions are those of the new files under the table's current
      spec: no rows replace nothing. Files written under an older spec are
      left alone. An unpartitioned table is one partition: the run replaces
      the whole table.
    - What to remove is planned against the snapshot each try commits on
      top of, again on every retry after another writer committed first.
    - A file in a partition being replaced that another writer committed
      after this run's first commit to the table means two writers are
      replacing (or writing) the partition at once. The commit raises,
      committing nothing, so only one of them keeps its rows: the other's
      attempt fails, and a rerun of it once the first has finished replaces
      the partition again.

    The snapshot's summary has `orca.replaced-files` and
    `orca.replaced-records`: the data files and rows it removed.
    """
    return _append(ctx, table, batches, True)


def replace_partition_files(
    mut ctx: Host, mut table: Table, files: List[DataFile]
) raises -> Int64:
    """`replace_partitions` of data files already written, here or on a
    worker (`write_files`), as `append_files` commits them."""
    return _append_files(ctx, table, files, True)


def replace_partition_files(
    mut ctx: Host, mut table: Table, files: DataFiles
) raises -> Int64:
    """`replace_partition_files` of the entries a task returned."""
    return _append_files(ctx, table, files.files, True)


struct _Replaced(Movable):
    """What a replace removes: the paths, and the data files and rows."""

    var removed: List[String]
    var files: Int
    var records: Int64

    def __init__(out self):
        self.removed = List[String]()
        self.files = 0
        self.records = 0


def _within(
    sums: List[FieldSummary],
    spec: PartitionSpec,
    ptype: Schema,
    value: List[Datum],
) raises -> Bool:
    """Whether a manifest with partition summaries `sums` may hold files of
    the partition `value`."""
    if len(value) != len(spec.fields) or len(sums) != len(spec.fields):
        return True
    for k in range(len(spec.fields)):
        ref sum = sums[k]
        ref v = value[k]
        if not v.valid:
            if not sum.contains_null:
                return False
            continue
        if not sum.has_lower or not sum.has_upper:
            return False
        ref tn = ptype.store.nodes[
            ptype.find_field(spec.fields[k].field_id).type
        ]
        var lo = datum_from_bytes_prim(
            tn.prim, tn.precision, tn.scale, tn.length, sum.lower_bound
        )
        var hi = datum_from_bytes_prim(
            tn.prim, tn.precision, tn.scale, tn.length, sum.upper_bound
        )
        if compare(lo, v) > 0 or compare(hi, v) < 0:
            return False
    return True


def _may_hold(
    mf: ManifestFile,
    spec: PartitionSpec,
    ptype: Schema,
    values: List[List[Datum]],
) -> Bool:
    """Whether manifest `mf` may hold files of any of the partitions
    `values`, by its partition summaries: the others aren't read."""
    if len(spec.fields) == 0 or not mf.has_partitions:
        return True
    try:
        for v in values:
            if _within(mf.partitions, spec, ptype, v):
                return True
        return False
    except:
        return True


def _by_whom(m: TableMetadata, at: Int) -> String:
    """Who committed snapshot `at` (an index into `m.snapshots`)."""
    if at < 0:
        return "a snapshot no longer in the table's history"
    ref s = m.snapshots[at].summary
    var run = s.get("orca.run")
    if run:
        return String(
            "run ",
            run.value(),
            " of ",
            s.get("orca.pipeline", "?"),
            ", step ",
            s.get("orca.step", "?"),
        )
    return String("snapshot ", m.snapshots[at].snapshot_id, ", not morca's")


def _plan_replace(
    ctx: Host, table: Table, added: List[DataFile]
) raises -> _Replaced:
    """The files a replace adding `added` removes from `table`'s current
    snapshot (see `replace_partitions`), or raises if another writer is
    writing one of its partitions."""
    var out = _Replaced()
    ref m = table.metadata
    if not m.has_current_snapshot or len(added) == 0:
        return out^
    var current = m.current_snapshot()
    if current.manifest_list == "":
        return out^
    var spec = m.spec()
    var ptype = spec.partition_type(m.schema())
    var keys = Dict[String, Bool]()
    var values = List[List[Datum]]()
    for f in added:
        var k = _partition_key(f.partition)
        if k not in keys:
            keys[k] = True
            values.append(f.partition.copy())
    # This run's snapshots, and where its first one is in the history.
    var loc = m.location
    var mine = Dict[Int64, Bool]()
    for c in ctx.commits():
        if c.table == loc:
            mine[c.snapshot_id] = True
    var index = Dict[Int64, Int]()
    var first_mine = -1
    for i in range(len(m.snapshots)):
        ref s = m.snapshots[i]
        index[s.snapshot_id] = i
        if ctx.same_run(s.summary):
            mine[s.snapshot_id] = True
        if s.snapshot_id in mine and first_mine < 0:
            first_mine = i
    var name = dataset_of(loc)
    for mf in read_manifest_list_io(table.io, current.manifest_list):
        if mf.partition_spec_id != spec.spec_id:
            continue
        if not _may_hold(mf, spec, ptype, values):
            continue
        var manifest = read_manifest_io(table.io, mf.manifest_path, mf)
        for e in manifest.entries:
            if not e.is_live():
                continue
            if _partition_key(e.data_file.partition) not in keys:
                continue
            if e.snapshot_id in mine:
                continue
            var at = index.get(e.snapshot_id, -1)
            if first_mine >= 0 and at > first_mine:
                raise Error(
                    "morca: another writer is writing a partition of ",
                    name if name else loc,
                    " that this run replaces: ",
                    _by_whom(m, at),
                    " committed ",
                    e.data_file.file_path,
                    " after this run's first commit to it. Nothing was",
                    " committed; rerun once the other has finished",
                )
            out.removed.append(e.data_file.file_path)
            if e.data_file.content == CONTENT_DATA:
                out.files += 1
                out.records += e.data_file.record_count
    return out^


def _commit_replace(
    mut ctx: Host, mut table: Table, var files: List[DataFile]
) raises -> Int64:
    """Commits `files` to `table` replacing their partitions (see
    `replace_partitions`), planned again and tried again when another writer
    commits first."""
    var loc = table.metadata.location
    var dataset = dataset_of(loc)
    var attempt = 0
    while True:
        # Planned against the snapshot this try builds on, never one an
        # earlier try saw: a stale list of files would leave another
        # writer's rows beside these.
        var plan = _plan_replace(ctx, table, files)
        var summary = ctx.summary(loc)
        summary["orca.replaced-files"] = String(plan.files)
        summary["orca.replaced-records"] = String(plan.records)
        var result: AppendResult
        if len(plan.removed) == 0:
            result = prepare_append(
                table.io, table.metadata, files.copy(), summary^
            )
        else:
            var change = FileChanges()
            change.added_data = files.copy()
            change.removed = plan.removed.copy()
            result = _prepare_commit(
                table,
                "overwrite",
                change^,
                summary^,
                dataset if dataset else loc,
            )
            _check_removed(
                result, len(plan.removed), dataset if dataset else loc
            )
        # Not if this process may have lost its run (`Ctx.fence`).
        ctx.fence()
        try:
            table.commit(result)
        except e:
            attempt += 1
            if attempt > _COMMIT_RETRIES:
                raise Error(
                    "morca: can't commit to ",
                    dataset,
                    " (",
                    attempt,
                    " tries): ",
                    e,
                )
            _backoff(attempt)
            _reload(table)
            # A commit that landed after all is done, not tried again.
            if not _landed(table, result.snapshot_id):
                continue
        ctx.committed(loc, result.snapshot_id, dataset)
        if len(plan.removed) > 0:
            ctx.log(
                String(
                    "replaced ",
                    plan.files,
                    " files (",
                    plan.records,
                    " rows) of ",
                    dataset if dataset else loc,
                    " that earlier runs committed, in snapshot ",
                    result.snapshot_id,
                )
            )
        _reload(table)
        return result.snapshot_id
