"""What tests/dataview_many.sh's pipeline writes: a commit a day to two
tables, so they end up with many snapshots, manifests and small files, as
a table appended to by many small runs does.

- lake.small: unpartitioned, 2 rows a commit, one file each;
- lake.wide: partitioned by day and shard, 4 shards of 5 rows a commit,
  four files each.
"""

from morca import Ctx, Daily, Day, Mapped, Pipeline, Step, morca_main
from morca.civil import days_from_civil
from morca.tables import (
    BatchBuilder,
    PartitionField,
    PartitionSpec,
    Schema,
    append,
    ensure_table,
    parse_transform,
)

comptime SMALL = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"id","required":true,"type":"long"},'
    '{"id":2,"name":"day","required":true,"type":"date"},'
    '{"id":3,"name":"note","required":false,"type":"string"}]}'
)
comptime WIDE = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"id","required":true,"type":"long"},'
    '{"id":2,"name":"day","required":true,"type":"string"},'
    '{"id":3,"name":"shard","required":true,"type":"int"},'
    '{"id":4,"name":"v","required":true,"type":"double"}]}'
)
comptime SHARDS = 4
comptime ROWS = 5


def load(mut ctx: Ctx, d: Day) raises -> Int64:
    var n = Int64(days_from_civil(d.year, d.month, d.day))
    var s = Schema.parse(SMALL)
    var small = ensure_table(
        ctx, "lake.small", s, PartitionSpec.unpartitioned()
    )
    var b = BatchBuilder(s)
    for i in range(2):
        b.add_int(b.col("id"), n * 10 + Int64(i))
        b.add_int(b.col("day"), n)
        b.add_str(b.col("note"), String(d, " #", i))
    _ = append(ctx, small, [b^.build()])
    var w = Schema.parse(WIDE)
    var spec = PartitionSpec(
        0,
        [
            PartitionField.single(2, 1000, "day", parse_transform("identity")),
            PartitionField.single(
                3, 1001, "shard", parse_transform("identity")
            ),
        ],
    )
    var wide = ensure_table(ctx, "lake.wide", w, spec)
    var c = BatchBuilder(w)
    for k in range(SHARDS):
        for i in range(ROWS):
            c.add_int(c.col("id"), (n * SHARDS + Int64(k)) * ROWS + Int64(i))
            c.add_str(c.col("day"), String(d))
            c.add_int(c.col("shard"), Int64(k))
            c.add_float(c.col("v"), Float64(i) + 0.5 * Float64(k))
    return append(ctx, wide, [c^.build()])


comptime Load = Step[
    "load", Day, Int64, load, Mapped, writes=["lake.small", "lake.wide"]
]
comptime Many = Pipeline["many", Load, partitions=Daily["2024-01-01"]]


def main() raises:
    morca_main[Many]()
