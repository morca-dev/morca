"""`tests/lake.sh`'s pipeline: one step that writes three rows to lake.f and
then scans them with a filter iceberg can't parse, so the attempt fails
inside the library with iceberg's own error. Built through liblake and with
-D MORCA_LAKE_SOURCE=1, the step's log must say the same."""

from morca import Ctx, Mapped, Month, Monthly, Pipeline, Step, morca_main
from morca.tables import BatchBuilder, Schema, append, ensure_table, scan

comptime SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"id","required":true,"type":"long"},'
    '{"id":2,"name":"month","required":true,"type":"string"}]}'
)


def load(mut ctx: Ctx, m: Month) raises -> Int:
    var t = ensure_table(ctx, "lake.f", Schema.parse(SCHEMA))
    var b = BatchBuilder(Schema.parse(SCHEMA))
    var ids = b.col("id")
    var months = b.col("month")
    for i in range(3):
        b.add_int(ids, Int64(i))
        b.add_str(months, String(m))
    _ = append(ctx, t, [b^.build()])
    var n = 0
    for batch in scan(ctx, t).filter('["no-such-op", "id", 1]').to_batches():
        n += batch.num_rows
    return n


comptime Load = Step[
    "load", Month, Int, load, Mapped, reads=["lake.f"], writes=["lake.f"]
]
comptime Failing = Pipeline["failing", Load, partitions=Monthly["2024-01"]]


def main() raises:
    morca_main[Failing]()
