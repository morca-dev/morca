"""The Parquet files a Rust worker writes itself (docs/rust-workers.md,
"Parquet files from the worker"): `WorkerFiles.take` checks one against the
table, uploads it to where the table's data files go, and keeps its entry
for the step's one commit.

A file is taken as the worker wrote it, not rewritten:

- **its schema** must fit the table's by the stricter rule for files
  (`morca._lake.rust_schema`): the table's field ids, and types
  iceberg's reader reads as the table's;
- **its partition** is read from its footer: for each field of the table's
  partition spec, the source column's statistics in every row group must
  give one value under the transform (for `bucket`, one value outright).
  A file holding rows of two partitions is refused, naming the column;
- **its entry** (row count, size, column sizes, value and null counts,
  bounds, split offsets) comes from the footer too, as for a file morca
  writes (iceberg's `data_file_from_footer`).

The file is read once, whole, to be uploaded with the table's `FileIO`
(a local warehouse or object storage), under the table's `data/` as
`<uuid>-w<n>.parquet`, then deleted if it's in the call's output
directory. A file of no rows is dropped.
"""

from std.os import remove

from iceberg.catalog.filesystem import Table
from iceberg.io import FileIO, join_path
from iceberg.manifest import DataFile
from iceberg.schema import Schema
from iceberg.transforms import T_VOID, PartitionSpec
from iceberg.util import uuid4, zero_pad
from iceberg.values import Datum, compare, datum_from_bytes_prim
from iceberg.write import (
    WriteOptions,
    bound_bytes,
    data_file_from_footer,
    partition_path,
)
from parquet import build_schema
from parquet.schema import ParquetSchema
from parquet.stats import ScalarValue, decode_stats
from thrift import FileMetaData, read_footer

from morca._lake.rust_schema import check_tree, file_tree


struct WorkerFiles(Movable):
    """The files a worker reported, taken one at a time, and their entries."""

    var io: FileIO
    var location: String
    var schema: Schema
    var spec: PartitionSpec
    var options: WriteOptions
    var name: String
    """The dataset, for messages."""
    var dir: String
    """The call's output directory: files in it are deleted once uploaded."""
    var files: List[DataFile]
    var rows: Int
    var counter: Int

    def __init__(
        out self, table: Table, var name: String, var dir: String
    ) raises:
        self.io = table.io.copy()
        self.location = table.metadata.location
        self.schema = table.metadata.schema()
        self.spec = table.metadata.spec()
        self.options = WriteOptions.from_properties(table.metadata.properties)
        self.name = name^
        self.dir = dir^
        self.files = List[DataFile]()
        self.rows = 0
        self.counter = 0

    def take(mut self, path: String) raises:
        """Checks, uploads and records the file at `path` (an absolute
        path), or raises naming the file and what's wrong with it."""
        var data: List[UInt8]
        try:
            with open(path, "r") as f:
                data = f.read_bytes()
        except e:
            raise Error(
                "morca: can't read the Rust worker's file ", path, ": ", e
            )
        var meta: FileMetaData
        try:
            meta = read_footer(Span(data))
        except e:
            raise Error(
                "morca: the Rust worker's file ", path, " isn't Parquet: ", e
            )
        var ps = build_schema(meta.schema)
        var part: List[Datum]
        try:
            check_tree(file_tree(ps), self.schema)
            part = partition_of(meta, ps, self.schema, self.spec)
        except e:
            raise Error(
                "morca: the Rust worker's file ",
                path,
                " doesn't fit ",
                self.name,
                ": ",
                e,
            )
        if meta.num_rows > 0:
            var dir = join_path(self.location, "data")
            var rel = partition_path(self.spec, part)
            if rel != "":
                dir = join_path(dir, rel)
            var target = join_path(
                dir,
                String(uuid4(), "-w", zero_pad(self.counter, 5), ".parquet"),
            )
            self.counter += 1
            try:
                self.io.write_all(target, Span(data))
            except e:
                raise Error(
                    "morca: can't upload the Rust worker's file ",
                    path,
                    " to ",
                    target,
                    ": ",
                    e,
                )
            self.files.append(
                data_file_from_footer(
                    meta,
                    len(data),
                    target,
                    self.schema,
                    self.spec,
                    part,
                    0,
                    self.options,
                )
            )
            self.rows += Int(meta.num_rows)
        if path.startswith(String(self.dir, "/")):
            try:
                remove(path)
            except:
                pass


def _datum(v: ScalarValue, schema: Schema, field_id: Int) raises -> Datum:
    """A statistic as the table's value of the column `field_id`."""
    ref t = schema.store.nodes[schema.find_field(field_id).type]
    var raw = bound_bytes(v, t.prim, t.precision, t.scale)
    if not raw[1]:
        return Datum.none()
    return datum_from_bytes_prim(t.prim, t.precision, t.scale, t.length, raw[0])


def partition_of(
    meta: FileMetaData, ps: ParquetSchema, schema: Schema, spec: PartitionSpec
) raises -> List[Datum]:
    """The partition a file's rows are in, from its footer's statistics, by
    the rule in the module's doc; raises, naming the column, if they don't
    give one."""
    var out = List[Datum]()
    for pf in spec.fields:
        if pf.transform.kind == T_VOID or meta.num_rows == 0:
            out.append(Datum.none())
            continue
        var col = schema.find_field(pf.source_id).name
        var leaf = -1
        for i in range(len(ps.leaves)):
            if Int(ps.leaves[i].field_id) == pf.source_id:
                leaf = i
                break
        if leaf < 0:
            raise Error(
                "column ",
                col,
                ", which the table is partitioned by, isn't in it",
            )
        ref lc = ps.leaves[leaf]
        if lc.max_rep > 0:
            raise Error(
                "column ",
                col,
                ", which the table is partitioned by, is in a list",
            )
        var value = Datum.none()
        var have = False
        var nulls = False
        for rg in meta.row_groups:
            if rg.num_rows == 0:
                continue
            ref chunk = rg.columns[leaf]
            var st_ok = False
            if chunk.meta_data and chunk.meta_data.value().statistics:
                st_ok = True
            if not st_ok:
                raise Error(
                    "column ",
                    col,
                    (
                        ", which the table is partitioned by, has no"
                        " statistics, so morca can't tell its partition: write"
                        " them"
                    ),
                )
            var st = decode_stats(
                lc, chunk.meta_data.value().statistics.value()
            )
            if st.has_null_count and st.null_count > 0:
                nulls = True
                if st.null_count == rg.num_rows:
                    continue
            if not st.has_min_max:
                raise Error(
                    "column ",
                    col,
                    (
                        ", which the table is partitioned by, has no minimum"
                        " and maximum, so morca can't tell its partition: write"
                        " them"
                    ),
                )
            var lo = _datum(st.min, schema, pf.source_id)
            var hi = _datum(st.max, schema, pf.source_id)
            var a = pf.transform.apply(lo)
            var b = pf.transform.apply(hi)
            var one = compare(a, b) == 0
            if one and not pf.transform.preserves_order():
                one = compare(lo, hi) == 0
            if one and have:
                one = compare(value, a) == 0
            if not one:
                raise Error(
                    "it holds rows of more than one partition: column ",
                    col,
                    " goes from ",
                    lo,
                    " to ",
                    hi,
                    " (",
                    pf.transform,
                    "); write a file per partition",
                )
            value = a^
            have = True
        if have and nulls:
            raise Error(
                "it holds rows of more than one partition: column ",
                col,
                " has nulls and values; write a file per partition",
            )
        out.append(value^)
    return out^
