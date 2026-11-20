"""The smallest pipeline over an Iceberg table, for tests/kind.sh: `write`
appends three rows for its month to the dataset `kind.rows` in
`MORCA_WAREHOUSE`, creating the table on first use, and `count` reads it
back, logs `ROWS <n>` and fails unless the table has the rows of every month
the run wrote. It needs the data environment and liblake
(deploy/Dockerfile.data builds both into an image):

    docker build -f deploy/Dockerfile.data --build-arg PIPELINES=examples/lake.mojo -t morca:data .
    morca register --image morca:data /opt/morca/pipelines/lake
    morca backfill lake 2024-01..2024-02
"""

from dista import Seq
from morca import (
    Ctx,
    Gather,
    Mapped,
    Month,
    Monthly,
    Pipeline,
    Step,
    morca_main,
)
from morca.tables import BatchBuilder, Schema, append, ensure_table, scan, table

comptime ROWS = "kind.rows"
comptime SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"id","required":true,"type":"long"},'
    '{"id":2,"name":"month","required":true,"type":"string"}]}'
)


def write(mut ctx: Ctx, m: Month) raises -> Int:
    var t = ensure_table(ctx, ROWS, Schema.parse(SCHEMA))
    var b = BatchBuilder(Schema.parse(SCHEMA))
    var ids = b.col("id")
    var months = b.col("month")
    for i in range(3):
        b.add_int(ids, Int64(i))
        b.add_str(months, String(m))
    var id = append(ctx, t, [b^.build()])
    ctx.log(String("wrote 3 rows for ", m, " in snapshot ", id))
    return 3


def count(mut ctx: Ctx, wrote: Seq[Int]) raises -> Int:
    var want = 0
    for i in range(len(wrote)):
        want += wrote[i]
    var n = 0
    for b in scan(ctx, table(ctx, ROWS)).to_batches():
        n += b.num_rows
    ctx.log(String("ROWS ", n))
    if n < want:
        raise Error("lake: read ", n, " rows, wrote ", want)
    return n


comptime Write = Step["write", Month, Int, write, Mapped, writes=[ROWS]]
comptime Count = Step[
    "count", Seq[Int], Int, count, Gather, after=Write, reads=[ROWS]
]
comptime Lake = Pipeline["lake", Write, Count, partitions=Monthly["2024-01"]]


def main() raises:
    morca_main[Lake]()
