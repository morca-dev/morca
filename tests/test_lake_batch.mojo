"""morca.tables' BatchBuilder (#454): a value of each kind into a schema's
columns, through liblake's empty batch, read back with the accessors and
written to a table and scanned. And the APIs of #464: a batch reader, a
data file's partition values, a schema's fields, a file writer's row
groups and options, a table's uncommitted files, and table_exists. Needs
no database: the tables are used outside any step."""

from std.os import getenv, setenv
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.schema import Schema as IcebergSchema
from iceberg.transforms import PartitionField as IcebergPartitionField
from iceberg.transforms import PartitionSpec as IcebergSpec
from iceberg.transforms import parse_transform
from iceberg.util import now_ms
from parquet import RecordBatch

from morca.tables import (
    BatchBuilder,
    FileWriter,
    Schema,
    Table,
    concat_batches,
    ints_of,
    strings_of,
    table_exists,
    write_files,
)

comptime SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"id","required":true,"type":"long"},'
    '{"id":2,"name":"n","required":false,"type":"int"},'
    '{"id":3,"name":"day","required":false,"type":"date"},'
    '{"id":4,"name":"at","required":false,"type":"timestamptz"},'
    '{"id":5,"name":"x","required":false,"type":"double"},'
    '{"id":6,"name":"f","required":false,"type":"float"},'
    '{"id":7,"name":"ok","required":false,"type":"boolean"},'
    '{"id":8,"name":"s","required":false,"type":"string"},'
    '{"id":9,"name":"tags","required":false,"type":{"type":"list",'
    '"element-id":10,"element":"string","element-required":true}},'
    '{"id":11,"name":"geo","required":false,"type":{"type":"struct",'
    '"fields":[{"id":12,"name":"lat","required":false,"type":"double"}]}}]}'
)


def _rows(n: Int) raises -> BatchBuilder:
    var b = BatchBuilder(Schema.parse(SCHEMA))
    for i in range(n):
        b.add_int(b.col("id"), Int64(i))
        if i == 1:
            b.add_null(b.col("n"))
            b.add_null(b.col("s"))
            b.add_null(b.col("tags"))
            b.add_null(b.col("geo"))
        else:
            b.add_int(b.col("n"), Int64(-i))
            b.add_str(b.col("s"), String("row ", i))
            for k in range(i):
                b.add_str(b.col("tags.element"), String("t", k))
            b.end_list(b.col("tags"))
            b.add_float(b.col("geo.lat"), 0.5 * Float64(i))
            b.end_struct(b.col("geo"))
        b.add_int(b.col("day"), Int64(19000 + i))
        b.add_int(b.col("at"), Int64(1_700_000_000_000_000 + i))
        b.add_float(b.col("x"), Float64(i) + 0.25)
        b.add_float(b.col("f"), Float64(i))
        b.add_bool(b.col("ok"), i % 2 == 0)
    return b^


def test_a_batch_reads_back() raises:
    var batch = _rows(3)^.build()
    assert_equal(batch.num_rows, 3)
    assert_equal(batch.num_columns(), 10)
    var ns = ints_of(batch, "n")
    assert_equal(ns[0].value(), 0)
    assert_true(not ns[1])
    assert_equal(ns[2].value(), -2)
    var ss = strings_of(batch, "s")
    assert_equal(ss[2].value(), "row 2")
    assert_true(not ss[1])
    assert_equal(ints_of(batch, "day")[2].value(), 19002)
    with assert_raises(contains="isn't a string column"):
        _ = strings_of(batch, "id")


def test_columns_must_line_up() raises:
    var b = BatchBuilder(Schema.parse(SCHEMA))
    b.add_int(b.col("id"), 1)
    with assert_raises(contains="has 0 rows"):
        _ = b^.build()


def test_a_batch_writes_and_scans() raises:
    var root = String("build/wh-lake-batch-", now_ms())
    _ = FilesystemCatalog.local(root).create_table(
        "db", "t", IcebergSchema.parse(SCHEMA)
    )
    var t = Table.load_local(String(root, "/db/t"))
    var batches = List[RecordBatch]()
    batches.append(_rows(3)^.build())
    batches.append(_rows(2)^.build())
    var one = concat_batches(batches)
    assert_equal(one.num_rows, 5)
    _ = t.append([one^])
    assert_equal(len(t.metadata.snapshots), 1)
    var n = 0
    var ids = List[Int64]()
    for b in t.scan().select(["id", "s"]).to_batches():
        n += b.num_rows
        for v in ints_of(b, "id"):
            ids.append(v.value())
    assert_equal(n, 5)
    assert_equal(t.scan().count(), 5)
    assert_equal(len(t.scan().plan_files()), 1)


def _partitioned(root: String) raises -> Table:
    """A table of SCHEMA partitioned by `day` (identity)."""
    var spec = IcebergSpec(
        0,
        [
            IcebergPartitionField.single(
                3, 1000, "day", parse_transform("identity")
            )
        ],
    )
    _ = FilesystemCatalog.local(root).create_table(
        "db", "p", IcebergSchema.parse(SCHEMA), spec
    )
    return Table.load_local(String(root, "/db/p"))


def test_schema_fields() raises:
    var s = Schema.parse(SCHEMA)
    assert_equal(len(s.columns()), 10)
    assert_equal(len(s.fields()), 12)
    var lat = s.find_by_name("geo.lat")
    assert_equal(lat.id, 12)
    assert_equal(lat.parent_id, 11)
    assert_equal(lat.type, '"double"')
    assert_true(not lat.required)
    assert_equal(s.find_field(10).name, "tags.element")
    assert_true(s.find_field(1).required)
    assert_true(s.has_field(9))
    assert_true(not s.has_field(99))
    assert_true(s.has_field_named("tags"))
    assert_true(not s.has_field_named("nope"))
    with assert_raises(contains="no field named 'nope'"):
        _ = s.find_by_name("nope")
    with assert_raises(contains="no field with id 99"):
        _ = s.find_field(99)


def test_batch_reader() raises:
    var root = String("build/wh-lake-reader-", now_ms())
    _ = FilesystemCatalog.local(root).create_table(
        "db", "t", IcebergSchema.parse(SCHEMA)
    )
    var t = Table.load_local(String(root, "/db/t"))
    # No snapshot yet: nothing to read.
    var empty = t.scan().to_batch_reader()
    assert_true(not empty.next_batch())
    _ = t.append([_rows(3)^.build()])
    _ = t.append([_rows(2)^.build()])
    var reader = t.scan().select(["id"]).to_batch_reader()
    var n = 0
    var batches = 0
    while True:
        var b = reader.next_batch()
        if not b:
            break
        var batch = b.take()
        assert_equal(batch.num_columns(), 1)
        n += batch.num_rows
        batches += 1
    assert_equal(n, 5)
    assert_equal(batches, 2)
    assert_true(not reader.next_batch())  # stays done
    # The same rows as to_batches, filtered.
    var f = t.scan().filter('[">=", "id", 1]').to_batch_reader()
    var m = 0
    while True:
        var b = f.next_batch()
        if not b:
            break
        m += b.value().num_rows
    assert_equal(m, 3)
    with assert_raises():
        _ = t.scan().use_snapshot(12345).to_batch_reader()


def test_partition_values() raises:
    var root = String("build/wh-lake-parts-", now_ms())
    var t = _partitioned(root)
    _ = t.append([_rows(3)^.build()])
    var days = List[Int64]()
    for task in t.scan().plan_files():
        ref p = task.data_file.partition
        assert_equal(len(p), 1)
        assert_true(p[0].valid)
        days.append(p[0].i)
    sort(days)
    assert_equal(len(days), 3)
    assert_equal(days[0], 19000)
    assert_equal(days[2], 19002)
    # Written and not committed: the entries show them too.
    var files = write_files(t, [_rows(2)^.build()]).files()
    assert_equal(len(files), 2)
    assert_true(files[0].partition[0].valid)
    assert_equal(files[0].partition[0].i, 19000)
    assert_equal(files[1].partition[0].i, 19001)


def test_row_groups_and_uncommitted_files() raises:
    var root = String("build/wh-lake-groups-", now_ms())
    var t = _partitioned(root)
    var w = FileWriter(t)
    assert_equal(w.options.codec, "zstd")
    w.options.row_group_rows = 1
    w.options.num_workers = 2
    # Rows of days 19000-19002 twice: a row group of each day's file each
    # time, three files of two rows.
    w.write_row_group(_rows(3)^.build())
    w.write_row_group(_rows(3)^.build())
    # A batch alone, after the open files are ended: a file of its own.
    w.close_files()
    w.write_row_group(_rows(1)^.build())
    assert_equal(w.rows, 7)
    var entries = w^.finish()
    var files = entries.files()
    assert_equal(len(files), 4)
    for k in range(3):
        assert_equal(files[k].record_count, 2)
        assert_equal(files[k].partition[0].i, Int64(19000 + k))
    assert_equal(files[3].record_count, 1)
    # Read back through the table's IO: the file isn't committed, so no
    # scan sees it.
    var rows = 0
    var ids = List[Int64]()
    for b in t.read_file(files[1].file_path):
        rows += b.num_rows
        for v in ints_of(b, "id"):
            ids.append(v.value())
    assert_equal(rows, 2)
    assert_equal(ids[0], 1)
    assert_equal(ids[1], 1)
    t.delete_file(files[1].file_path)
    with assert_raises():
        _ = t.read_file(files[1].file_path)
    # The other files are still there, and the table has no snapshot.
    assert_equal(len(t.read_file(files[0].file_path)), 2)  # a row group each
    assert_equal(len(t.metadata.snapshots), 0)


def test_table_exists() raises:
    var root = String("build/wh-lake-exists-", now_ms())
    _ = FilesystemCatalog.local(root).create_table(
        "db", "here", IcebergSchema.parse(SCHEMA)
    )
    var before = getenv("MORCA_WAREHOUSE")
    setenv("MORCA_WAREHOUSE", root)
    assert_true(table_exists("db.here"))
    assert_true(not table_exists("db.gone"))
    assert_true(not table_exists("other.here"))
    with assert_raises(contains="namespace.table"):
        _ = table_exists("nodot")
    _ = setenv("MORCA_WAREHOUSE", before)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
