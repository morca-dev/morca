"""The NYC TLC yellow-taxi files: where they are, and how one becomes rows of
the `taxi.trips` table.

The table is taxibench's, field for field: the same schema, with the same
field IDs, partitioned by `month(tpep_pickup_datetime)` as `pickup_month`, so
the two loads can be compared row for row.

The files aren't consistent with each other. All of 2011 to 2024 have the
same 19 columns, but not the same types:

- 2011 to mid-2018 type `VendorID`, `passenger_count`, `RatecodeID` and the
  location IDs as int64; mid-2018 to 2023-01 make `passenger_count` and
  `RatecodeID` doubles; 2023-02 on narrow `VendorID` and the location IDs
  to int32 and spell the airport fee `Airport_fee`.
- `congestion_surcharge` (charged from 2019) and `airport_fee` (from 2021)
  are null before then, and a file whose column is all null types it as
  int32 rather than double, as does 2014-08's `improvement_surcharge`.

`read_month` renames a column to the table's spelling, and iceberg's writer
casts every column to the table's type (a double to an int truncates, as
taxibench's `safe=False` cast does; an all-null int32 stays null). Every
file also has a handful of rows dated outside its month, anywhere from 2001
to 2098; `read_month` drops them, as taxibench does, and counts them.
"""

from iceberg.io import FileIO, join_path
from iceberg.nested import filter_tree
from iceberg.schema import Schema as IcebergSchema
from objectstore.http import HttpClient
from parquet import ParquetReader, RecordBatch
from parquet_full import AllCodecs

from morca import Month
from morca.tables import PartitionField, PartitionSpec, Schema, parse_transform

comptime TLC_URL = "https://d37ci6vzurychx.cloudfront.net/trip-data"
"""Where the TLC publishes the files, one per month."""

comptime SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"VendorID","required":false,"type":"int"},'
    '{"id":2,"name":"tpep_pickup_datetime","required":false,"type":"timestamp"},'
    '{"id":3,"name":"tpep_dropoff_datetime","required":false,"type":"timestamp"},'
    '{"id":4,"name":"passenger_count","required":false,"type":"int"},'
    '{"id":5,"name":"trip_distance","required":false,"type":"double"},'
    '{"id":6,"name":"RatecodeID","required":false,"type":"int"},'
    '{"id":7,"name":"store_and_fwd_flag","required":false,"type":"string"},'
    '{"id":8,"name":"PULocationID","required":false,"type":"int"},'
    '{"id":9,"name":"DOLocationID","required":false,"type":"int"},'
    '{"id":10,"name":"payment_type","required":false,"type":"int"},'
    '{"id":11,"name":"fare_amount","required":false,"type":"double"},'
    '{"id":12,"name":"extra","required":false,"type":"double"},'
    '{"id":13,"name":"mta_tax","required":false,"type":"double"},'
    '{"id":14,"name":"tip_amount","required":false,"type":"double"},'
    '{"id":15,"name":"tolls_amount","required":false,"type":"double"},'
    '{"id":16,"name":"improvement_surcharge","required":false,"type":"double"},'
    '{"id":17,"name":"total_amount","required":false,"type":"double"},'
    '{"id":18,"name":"congestion_surcharge","required":false,"type":"double"},'
    '{"id":19,"name":"airport_fee","required":false,"type":"double"}]}'
)

comptime PICKUP = "tpep_pickup_datetime"


def schema() raises -> Schema:
    return Schema.parse(SCHEMA)


def spec() raises -> PartitionSpec:
    """`pickup_month`: the month of the pickup, as taxibench partitions."""
    return PartitionSpec(
        0,
        [
            PartitionField.single(
                2, 1000, "pickup_month", parse_transform("month")
            )
        ],
    )


def file_name(m: Month) -> String:
    return String("yellow_tripdata_", m, ".parquet")


def _is_parquet(io: FileIO, path: String) -> Bool:
    """Whether `path` is a whole Parquet file: `PAR1` at both ends. A
    download cut short ends without it."""
    try:
        var n = io.length(path)
        if n < 12:
            return False
        var head = io.read_range(path, 0, 4)
        var tail = io.read_range(path, n - 4, 4)
        return (
            String(StringSpan(unsafe_from_utf8=Span(head))) == "PAR1"
            and String(StringSpan(unsafe_from_utf8=Span(tail))) == "PAR1"
        )
    except:
        return False


def download(
    m: Month, dir: String, source: String
) raises -> Tuple[String, Int]:
    """Fetches month `m`'s file into `dir`, unless a whole copy is there
    already, and returns its path and size.

    `source` is the TLC's URL, or a local directory holding the same files
    (a mirror, or the test fixtures).
    """
    var io = FileIO.local()
    var name = file_name(m)
    var path = join_path(dir, name)
    if _is_parquet(io, path):
        return (path, io.length(path))
    var body: List[UInt8]
    if source.startswith("http://") or source.startswith("https://"):
        var url = String(source, "/", name)
        var client = HttpClient()
        client.timeout_ms = 10 * 60 * 1000
        client.follow_redirects = True
        var resp = client.get(url)
        if not resp.ok():
            raise Error("taxi: GET ", url, ": HTTP ", resp.status)
        body = resp.body.copy()
    else:
        body = io.read_all(join_path(source, name))
    io.write_all(path, Span(body))
    if not _is_parquet(io, path):
        raise Error("taxi: ", name, " isn't a whole Parquet file")
    return (path, len(body))


def _days(year: Int, month: Int) -> Int64:
    """Days from 1970-01-01 to the first of the month (Howard Hinnant's
    `days_from_civil`)."""
    var y = year - 1 if month <= 2 else year
    var era = (y if y >= 0 else y - 399) // 400
    var yoe = y - era * 400
    var mp = month - 3 if month > 2 else month + 9
    var doy = (153 * mp + 2) // 5
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return Int64(era * 146097 + doe - 719468)


def _per_second(unit: Int) raises -> Int64:
    # Arrow's time units: second, milli, micro, nano.
    if unit == 0:
        return 1
    if unit == 1:
        return 1000
    if unit == 2:
        return 1000000
    if unit == 3:
        return 1000000000
    raise Error("taxi: unknown time unit ", unit)


def _to_table_names(mut b: RecordBatch, s: IcebergSchema) raises:
    """Renames a column whose name matches a table column's but for case,
    `Airport_fee` to `airport_fee`."""
    var cols = s.columns()
    for c in range(b.num_columns()):
        var name = b.name(c)
        for k in range(len(cols)):
            if cols[k].name != name and cols[k].name.lower() == name.lower():
                b.arena.nodes[b.roots[c]].name = cols[k].name
                break


def month_bounds(m: Month, unit: Int) raises -> Tuple[Int64, Int64]:
    """The first instant of month `m` and of the month after, as timestamps
    in Arrow time unit `unit`."""
    var scale = _per_second(unit) * 86400
    var nxt = m.next()
    return (_days(m.year, m.month) * scale, _days(nxt.year, nxt.month) * scale)


def pickup_column(b: RecordBatch) raises -> Int:
    for c in range(b.num_columns()):
        if b.name(c) == PICKUP:
            return c
    raise Error("taxi: no ", PICKUP, " column")


def _in_month(b: RecordBatch, m: Month) raises -> Tuple[RecordBatch, Int]:
    """The rows of `b` picked up in month `m`, and how many weren't. A row
    without a pickup time is dropped too."""
    var c = pickup_column(b)
    var lo, hi = month_bounds(m, b.type(c).unit)
    var got = b.column_i64(c)
    ref vals = got[0]
    ref valid = got[1]
    var keep = List[Bool](capacity=b.num_rows)
    var n = 0
    for i in range(b.num_rows):
        var k = valid[i] and vals[i] >= lo and vals[i] < hi
        keep.append(k)
        if k:
            n += 1
    if n == b.num_rows:
        return (b.copy(), 0)
    var out = RecordBatch()
    for r in range(b.num_columns()):
        out.roots.append(filter_tree(b.arena, b.roots[r], keep, n, out.arena))
    out.num_rows = n
    return (out^, b.num_rows - n)


@fieldwise_init
struct MonthRows(Movable):
    var batches: List[RecordBatch]
    var rows: Int
    """Rows kept."""
    var dropped: Int
    """Rows dated outside the month."""


def read_month(path: String, m: Month) raises -> MonthRows:
    """The file's rows picked up in month `m`, under the table's column
    names, in the reader's batches."""
    var s = IcebergSchema.parse(SCHEMA)
    var r = ParquetReader[AllCodecs].open(path)
    var out = MonthRows(List[RecordBatch](), 0, 0)
    while r.has_next():
        var b = r.read_batch()
        _to_table_names(b, s)
        var kept = _in_month(b, m)
        out.dropped += kept[1]
        if kept[0].num_rows > 0:
            out.rows += kept[0].num_rows
            out.batches.append(kept[0].copy())
    return out^
