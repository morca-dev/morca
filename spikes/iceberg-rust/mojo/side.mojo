"""The Mojo side of the iceberg-rust spike (#520): commits and reads a
warehouse dataset exactly as a step does, through `morca.tables`.

    side write <dataset> <run> <partition> <attempt> <YYYY-MM> <rows> [score-id]
    side find  <dataset> <run> <partition>
    side read  <dataset> [snapshot-id]
    side pinned <dataset> <snapshot-id>

`write` appends `rows` rows of (id, ts, name) in the month as step `load`
of pipeline `spike`, run `run`, with `ensure_table` (spec: month(ts)).
With `score-id`, the step's schema also has an optional `score` double of
that field id, so `ensure_table` adds it (schema evolution) and the rows
carry it. `find` is `find_commit` for that step's first commit. `read`
scans the current snapshot, or `snapshot-id` with `use_snapshot`; `pinned`
scans through a `Ctx` whose pin is `snapshot-id`, as a retry does.
MORCA_WAREHOUSE is the warehouse (a directory or s3://bucket/prefix).
"""

from std.sys import argv, exit

from parquet import RecordBatch

from morca import Ctx
from morca.tables import (
    BatchBuilder,
    PartitionField,
    PartitionSpec,
    Schema,
    Table,
    append,
    ensure_table,
    find_commit,
    ints_of,
    load_dataset,
    parse_transform,
    scan,
    strings_of,
)

comptime BASE = (
    '{"id":1,"name":"id","required":true,"type":"long"},'
    '{"id":2,"name":"ts","required":true,"type":"timestamp"},'
    '{"id":3,"name":"name","required":true,"type":"string"}'
)
comptime USAGE = "usage: side write|find|read|pinned <dataset> ... (see the module doc)"
comptime HOUR_US: Int64 = 3_600_000_000


def schema(score_id: Int) raises -> Schema:
    var j = String('{"schema-id":0,"type":"struct","fields":[', BASE)
    if score_id > 0:
        j.write(
            ',{"id":',
            score_id,
            ',"name":"score","required":false,"type":"double"}',
        )
    j.write("]}")
    return Schema.parse(j)


def spec() raises -> PartitionSpec:
    return PartitionSpec(
        0,
        [PartitionField.single(2, 1000, "ts_month", parse_transform("month"))],
    )


def month_start_us(month: String) raises -> Int64:
    """Microseconds since the epoch at the start of `YYYY-MM` (UTC)."""
    var parts = month.split("-")
    var y = Int(parts[0])
    var m = Int(parts[1])
    # Days from civil (Howard Hinnant's algorithm).
    var yy = y - 1 if m <= 2 else y
    var era = (yy if yy >= 0 else yy - 399) // 400
    var yoe = yy - era * 400
    var mp = m - 3 if m > 2 else m + 9
    var doy = (153 * mp + 2) // 5
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    var days = era * 146097 + doe - 719468
    return Int64(days) * 24 * HOUR_US


def rows(
    s: Schema, month: String, n: Int, scored: Bool
) raises -> List[RecordBatch]:
    var b = BatchBuilder(s)
    var ids = b.col("id")
    var ts = b.col("ts")
    var names = b.col("name")
    var start = month_start_us(month)
    var score = b.col("score") if scored else -1
    for i in range(n):
        b.add_int(ids, Int64(i))
        b.add_int(ts, start + Int64(i) * HOUR_US)
        b.add_str(names, String("mojo-", month, "-", i))
        if scored:
            b.add_float(score, Float64(i) / 2.0)
    return [b^.build()]


def ctx_for(
    dataset: String, run: Int, partition: String, attempt: Int
) -> Ctx:
    return Ctx(
        "spike",
        run,
        "load",
        partition,
        attempt=attempt,
        code="spike-mojo",
        declared_reads=[dataset],
        declared_writes=[dataset],
    )


def describe(batches: List[RecordBatch]) raises:
    var n = 0
    var id_sum: Int64 = 0
    var note = 0
    var score = 0
    var cols = String()
    for b in batches:
        n += b.num_rows
        if cols == "":
            for r in b.roots:
                cols.write("," if cols else "", b.arena.nodes[r].name)
        for v in ints_of(b, "id"):
            id_sum += v.value()
        for r in b.roots:
            ref name = b.arena.nodes[r].name
            if name == "note":
                for v in strings_of(b, "note"):
                    if v:
                        note += 1
            elif name == "score":
                ref a = b.arena.nodes[r]
                score += a.length - a.null_count
    print(
        "rows", n, "id_sum", id_sum, "columns", cols, "note", note, "score",
        score,
    )


def snapshots(t: Table):
    for s in t.metadata.snapshots:
        var keys = String()
        for e in s.summary.items():
            if e.key.startswith("orca."):
                keys.write(" ", e.key, "=", e.value)
        print(
            "snapshot",
            s.snapshot_id,
            s.summary.get("operation", "?"),
            "added-records",
            s.summary.get("added-records", "?"),
            "total-records",
            s.summary.get("total-records", "?"),
            keys,
        )


def main() raises:
    var a = argv()
    if len(a) < 3:
        print(USAGE)
        exit(2)
    var cmd = String(a[1])
    var ds = String(a[2])
    if cmd == "write":
        var run = Int(a[3])
        var score_id = Int(a[8]) if len(a) > 8 else 0
        var ctx = ctx_for(ds, run, String(a[4]), Int(a[5]))
        var s = schema(score_id)
        var t = ensure_table(ctx, ds, s, spec())
        var id = append(ctx, t, rows(s, String(a[6]), Int(a[7]), score_id > 0))
        print("committed", id)
    elif cmd == "find":
        var ctx = ctx_for(ds, Int(a[3]), String(a[4]), 1)
        print("found", find_commit(ctx, load_dataset(ds)))
    elif cmd == "read":
        var t = load_dataset(ds)
        snapshots(t)
        var sc = t.scan()
        if len(a) > 3:
            sc = sc.use_snapshot(Int64(Int(a[3])))
        describe(sc.to_batches())
    elif cmd == "pinned":
        var t = load_dataset(ds)
        var ctx = ctx_for(ds, 1, "x", 2)
        ctx.pinned[t.metadata.location] = Int64(Int(a[3]))
        describe(scan(ctx, t).to_batches())
    else:
        print(USAGE)
        exit(2)
