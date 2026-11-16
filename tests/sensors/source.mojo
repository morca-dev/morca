"""Commits three rows to raw.events as a program that isn't a morca
pipeline would: with iceberg alone, its summary saying which partitions it
holds only when given some.

    source <warehouse> [<partitions>]
"""

from std.sys import argv

from iceberg.append import prepare_append
from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.io import FileIO
from iceberg.schema import Schema
from iceberg.transforms import PartitionSpec
from iceberg.write import WriteOptions, write_data_files

from morca._cli import seed_random
from rows import SCHEMA, rows


def main() raises:
    seed_random()  # iceberg draws snapshot IDs from std.random
    var args = argv()
    var root = String(args[1])
    # A warehouse in object storage, as morca.tables opens one.
    var cat = FilesystemCatalog(
        root, FileIO()
    ) if "://" in root else FilesystemCatalog.local(root)
    if not cat.table_exists("raw", "events"):
        _ = cat.create_table(
            "raw", "events", Schema.parse(SCHEMA), PartitionSpec.unpartitioned()
        )
    var t = cat.load_table("raw", "events")
    var files = write_data_files(
        t.io,
        t.metadata.location,
        rows("source", 3),
        t.metadata.schema(),
        t.metadata.spec(),
        t.metadata.default_sort_order_id,
        WriteOptions.from_properties(t.metadata.properties),
    )
    var summary = Dict[String, String]()
    if len(args) > 2:
        summary["orca.partitions"] = String(args[2])
    var result = prepare_append(t.io, t.metadata, files^, summary^)
    t.commit(result)
    print(result.snapshot_id)
