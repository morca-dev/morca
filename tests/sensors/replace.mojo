"""A sensor that replaces its partitions: reads raw.events and writes as
many rows to lake.monthly, partitioned by month, a month at a time, with
lake.monthly in `replaces=`, so a new run of a month leaves one copy of its
rows. The twin of rust/morca-sdk/examples/replace.rs; the conformance suite
runs it as tests/conformance/replace.json.

It writes its files and commits them in two calls (`write_files`, then
`append_files`), so that with MORCA_REPLACE_DIE set it can exit between the
two; MORCA_REPLACE_SLEEP makes each attempt take that many seconds first.
"""

from std.os import getenv
from std.sys import exit
from std.time import sleep

from morca import Ctx, Mapped, Month, Monthly, Pipeline, Step, morca_main
from morca.tables import (
    DataFiles,
    PartitionField,
    PartitionSpec,
    Schema,
    append_files,
    ensure_table,
    find_commit,
    parse_transform,
    table,
    write_files,
)
from rows import SCHEMA, count, rows

comptime TABLE = "lake.monthly"


def load(mut ctx: Ctx, m: Month) raises -> Int64:
    var nap = getenv("MORCA_REPLACE_SLEEP")
    if nap:
        sleep(Float64(nap))
    var n = count(ctx, table(ctx, "raw.events"))
    var t = ensure_table(
        ctx,
        TABLE,
        Schema.parse(SCHEMA),
        PartitionSpec(
            0,
            [
                PartitionField.single(
                    2, 1000, "month", parse_transform("identity")
                )
            ],
        ),
    )
    var files = DataFiles()
    if find_commit(ctx, t) < 0:
        files = write_files(t, rows(String(m), n))
        if getenv("MORCA_REPLACE_DIE"):
            print("replace: exiting between writing and committing", m)
            # As a kill would: no attempt finished, nothing committed.
            exit(70)
    _ = append_files(ctx, t, files)
    return Int64(n)


comptime Load = Step[
    "load",
    Month,
    Int64,
    load,
    Mapped,
    reads=["raw.events"],
    replaces=[TABLE],
]
comptime P = Pipeline[
    "replace", Load, partitions=Monthly["2024-01"], sensor=True
]


def main() raises:
    morca_main[P]()
