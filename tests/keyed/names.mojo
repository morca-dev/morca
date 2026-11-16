"""Appends to a keys dataset: `log_id` and `frames` columns, `count` logs
(default 50) named `log-<n>` from `from` (default 0), zero-padded to
`width` digits (default 2), shuffled and each written twice, so the keys
are the distinct values and not the rows; `prefix` replaces `log-`, as in
`org/repo-` for names with a `/`. Prints the snapshot.

    names <warehouse> [<count> [<table> [<from> [<width> [<prefix>]]]]]   (table: keys.logs)
"""

from std.sys import argv

from iceberg.append import prepare_append
from iceberg.batch import ColumnBuilder, batch_of
from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.schema import Schema
from iceberg.transforms import PartitionSpec
from iceberg.values import Datum
from iceberg.write import WriteOptions, write_data_files

from morca._cli import seed_random

comptime SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"log_id","required":true,"type":"string"},'
    '{"id":2,"name":"frames","required":true,"type":"long"}]}'
)


def main() raises:
    seed_random()  # iceberg draws snapshot IDs from std.random
    var args = argv()
    var n = Int(String(args[2])) if len(args) > 2 else 50
    var table = String(args[3]) if len(args) > 3 else String("logs")
    var start = Int(String(args[4])) if len(args) > 4 else 0
    var width = Int(String(args[5])) if len(args) > 5 else 2
    var prefix = String(args[6]) if len(args) > 6 else String("log-")
    var cat = FilesystemCatalog.local(String(args[1]))
    var schema = Schema.parse(SCHEMA)
    if not cat.table_exists("keys", table):
        _ = cat.create_table(
            "keys", table, schema.copy(), PartitionSpec.unpartitioned()
        )
    var t = cat.load_table("keys", table)
    var ids = ColumnBuilder.of(schema, 1)
    var frames = ColumnBuilder.of(schema, 2)
    for copy in range(2):
        for i in range(n):
            # 37 is prime to these counts, so this visits each log once,
            # out of order.
            var k = start + (i * 37 + copy) % n
            var digits = String(k)
            var padded = String("0") * max(width - digits.byte_length(), 0)
            ids.add(Datum.string_(String(prefix, padded, digits)))
            frames.add(Datum.long_(Int64(k * 10)))
    var files = write_data_files(
        t.io,
        t.metadata.location,
        [batch_of([ids^, frames^])],
        t.metadata.schema(),
        t.metadata.spec(),
        t.metadata.default_sort_order_id,
        WriteOptions.from_properties(t.metadata.properties),
    )
    var result = prepare_append(
        t.io, t.metadata, files^, Dict[String, String]()
    )
    t.commit(result)
    print(result.snapshot_id)
