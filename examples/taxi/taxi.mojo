"""The NYC yellow-taxi load as a morca pipeline: download each month's TLC
file, load it into a month-partitioned Iceberg table, then compact the months
the run loaded to one file each.

    pixi run -e data taxi
    pixi run -e data ./build/taxi run --partitions 2023-01..2024-12

That's phase 1's gate: 2023-2024 loads to 79,478,796 rows, as taxibench's
table does, and a run killed during the load resumes at the month it was on.
With MORCA_DATABASE_URL set the run is recorded, so `taxi resume <run>` can
finish it.

Phase 2's gate schedules it. The partitions are the months from 2011-01, the
first the TLC publishes in this form, and it fires at 06:00 UTC on the 2nd
for the month before, four runs at most at once:

    pixi run -e data morca
    ./build/morca register ./build/taxi
    ./build/morca backfill taxi 2011-01..2024-12
    ./build/morca scheduler

The TLC publishes a month about two months after it ends, so a fire for the
month just ended fails its download, is retried with backoff and then fails;
a backfill of the month once it's out loads it.

- `MORCA_WAREHOUSE` (default `build/taxi-data/warehouse`): the warehouse that
  holds the dataset `taxi.trips`, created by the first load. `load` declares
  it in `writes=`, and `compact`, which rewrites it, in `reads=` and
  `writes=`.
- `TAXI_TLC` (default `build/taxi-data/tlc`): where the downloads go. A month whose
  file is already there whole isn't downloaded again.
- `TAXI_SOURCE` (default the TLC's URL): where to download from, a URL or a
  local directory of the same files.

The load appends a month in the reader's batches, which leaves about 46 files
per month (220 for 2011's); the compaction rewrites each month the run loaded
as one file, in one `replace` snapshot. It leaves other months alone, so runs
loading different months at once don't rewrite each other's files. Data files written by an attempt killed before it committed aren't
in any snapshot and are left behind; expiring and removing orphans is for
later.
"""

from std.os import getenv, setenv

from dista import Seq

from morca import (
    Cron,
    Ctx,
    Gather,
    Mapped,
    Month,
    Monthly,
    Pipeline,
    Step,
    morca_main,
)
from morca.tables import (
    FileChanges,
    FileScanTask,
    Table,
    TableScan,
    append,
    commit,
    concat_batches,
    ensure_table,
    find_commit,
    scan,
    write_files,
)
from tlc import TLC_URL, download, read_month, schema, spec


comptime TRIPS = "taxi.trips"


def _trips(mut ctx: Ctx) raises -> Table:
    """`taxi.trips`, created if the warehouse doesn't have it yet."""
    return ensure_table(ctx, TRIPS, schema(), spec())


@fieldwise_init
struct RawFile(Copyable, Movable):
    var month: Month
    var path: String
    var bytes: Int


@fieldwise_init
struct Loaded(Copyable, Movable):
    var month: Month
    var snapshot: Int64
    var rows: Int
    var dropped: Int
    """Rows dated outside the month, not loaded."""


@fieldwise_init
struct Compacted(Copyable, Movable):
    var snapshot: Int64
    var rows: Int
    var files_before: Int
    var files_after: Int


def fetch(mut ctx: Ctx, m: Month) raises -> RawFile:
    var got = download(
        m,
        getenv("TAXI_TLC", "build/taxi-data/tlc"),
        getenv("TAXI_SOURCE", TLC_URL),
    )
    ctx.log(String(got[0], ", ", got[1], " bytes"))
    return RawFile(m.copy(), got[0], got[1])


def load(mut ctx: Ctx, raw: RawFile) raises -> Loaded:
    var rows = read_month(raw.path, raw.month)
    var table = _trips(ctx)
    var id = append(ctx, table, rows.batches)
    ctx.log(
        String(
            rows.rows,
            " rows in ",
            len(rows.batches),
            " batches, ",
            rows.dropped,
            " dropped as out of month",
        )
    )
    return Loaded(raw.month.copy(), id, rows.rows, rows.dropped)


def _partition(path: String) -> String:
    """A data file's partition directory, `.../data/pickup_month=2024-01`."""
    var at = path.rfind("/").or_else(-1)
    return String(path[byte=0:at]) if at >= 0 else String()


def _files(s: TableScan) raises -> Tuple[Int, Int]:
    """How many data files the scan's snapshot has, and their rows."""
    var files = 0
    var rows = 0
    for t in s.plan_files():
        files += 1
        rows += Int(t.data_file.record_count)
    return (files, rows)


def compact(mut ctx: Ctx, loads: Seq[Loaded]) raises -> Compacted:
    """Rewrites each month this run loaded that has more than one file as one
    file, all in one `replace` snapshot. Months other runs load are theirs to
    compact, so runs at once don't rewrite each other's files."""
    var table = _trips(ctx)
    var s = scan(ctx, table)
    var tasks = s.plan_files()
    var mine = List[String]()
    for i in range(len(loads)):
        mine.append(String("pickup_month=", loads[i].month))
    var parts = List[String]()
    var groups = List[List[FileScanTask]]()
    for t in tasks:
        var p = _partition(t.data_file.file_path)
        if String(p[byte = p.rfind("/").or_else(-1) + 1 :]) not in mine:
            continue
        var g = -1
        for k in range(len(parts)):
            if parts[k] == p:
                g = k
                break
        if g < 0:
            parts.append(p)
            groups.append(List[FileScanTask]())
            g = len(groups) - 1
        groups[g].append(t.copy())
    var before = len(tasks)

    var id = find_commit(ctx, table)
    if id < 0:
        var changes = FileChanges()
        var m = table.metadata.copy()
        for g in range(len(groups)):
            if len(groups[g]) < 2:
                continue
            # The group's rows as one batch, so one file.
            var one = concat_batches(s.to_batches_for_tasks(groups[g]))
            changes.added_data.add(write_files(table, [one^]))
            for t in groups[g]:
                changes.removed.append(t.data_file.file_path)
            ctx.log(String(parts[g], ": ", len(groups[g]), " files to 1"))
        if changes.is_empty():
            var n = _files(s)
            ctx.log(String("nothing to compact: ", n[1], " rows"))
            return Compacted(m.current_snapshot_id, n[1], before, before)
        id = commit(ctx, table, "replace", changes^)
    var n = _files(table.scan().use_snapshot(id))
    var loaded = 0
    for i in range(len(loads)):
        loaded += loads[i].rows
    ctx.log(
        String(
            n[1], " rows in ", n[0], " files (", loaded, " loaded by this run)"
        )
    )
    return Compacted(id, n[1], before, n[0])


comptime Fetch = Step["download", Month, RawFile, fetch, Mapped, retries=2]
comptime Load = Step[
    "load", RawFile, Loaded, load, Mapped, after=Fetch, writes=[TRIPS]
]
comptime Compact = Step[
    "compact",
    Seq[Loaded],
    Compacted,
    compact,
    Gather,
    after=Load,
    reads=[TRIPS],
    writes=[TRIPS],
]
comptime Taxi = Pipeline[
    "taxi",
    Fetch,
    Load,
    Compact,
    partitions=Monthly["2011-01"],
    schedule=Cron["0 6 2 * *"],
    max_runs=4,
]


def main() raises:
    if not getenv("MORCA_WAREHOUSE"):
        _ = setenv("MORCA_WAREHOUSE", "build/taxi-data/warehouse")
    morca_main[Taxi]()
