"""morca: orchestration for Mojo data pipelines.

Declare steps and the pipeline they make, and give the binary morca's
command line:

```mojo
from dista import Seq
from morca import Ctx, Gather, Mapped, Month, Pipeline, Step, morca_main

def size(mut ctx: Ctx, m: Month) raises -> Int:
    return m.month * 100

def total(mut ctx: Ctx, sizes: Seq[Int]) raises -> Int:
    var t = 0
    for i in range(len(sizes)):
        t += sizes[i]
    return t

comptime Size = Step["size", Month, Int, size, Mapped]
comptime Total = Step["total", Seq[Int], Int, total, Gather, after=Size]
comptime Sizes = Pipeline["sizes", Size, Total]

def main() raises:
    morca_main[Sizes]()
```

See DESIGN.md for how it works and where it's going.

## Public API

These modules are morca's public API: a breaking change to one of them
comes with a minor-version note in the changelog (changes/README.md).

| Module | For |
|---|---|
| `morca` | everything below but tables and keyed partitions, in one import |
| `morca.step` | `Step`, `Mapped`, `Gather`, `NoStep`, `StepKind`, `StepLike`, `defer` |
| `morca.pipeline` | `Pipeline`, and what a run returns: `RunResult`, `StepRun`, `SUCCEEDED`, `FAILED`, `SKIPPED` |
| `morca.ctx` | `Ctx`, what a step is given: its run, partition, attempt, logs and dista runtime |
| `morca.partitions` | `Monthly`, `Daily`, `Hourly`, `Partitions`, `parse_partitions` |
| `morca.keyed` | `Keyed`: partitions named by a dataset's column, not dates |
| `morca.month`, `morca.day`, `morca.hour`, `morca.key`, `morca.name` | the partition keys: `Month`, `Day`, `Hour`, `Name`, `Key`, `TimeKey`, and their parsers |
| `morca.schedule`, `morca.cron`, `morca.tz` | `Cron`, `Current`, `Previous`, `Fill`, `NoSchedule`, `Schedule`, `ScheduleLike`; `CronExpr`; `Zone`, `PosixTZ` |
| `morca.civil` | `Civil`, `now`, `parse_time`, `utc` |
| `morca.tasks` | `Tasks`, `TaskSet`, `NoTasks`, `workers`: a step's dista tasks |
| `morca.tables` | Iceberg from steps, through liblake: `table`, `scan`, `append`, `commit`, `ensure_table`, `find_commit`, `append_files`, `write_files`, `replace_partitions`, `load_dataset`, `table_exists`; `Table`, `TableScan`, `BatchReader`, `Schema`, `PartitionSpec`, `BatchBuilder`, `FileWriter`, `DataFiles` |
| `morca.rust_step` | steps written in Rust: `rust_step`, which runs a worker library and commits what it streams and the Parquet files it writes, and `RustRun` (docs/rust-workers.md) |
| `morca.cli` | `morca_main`, the command line of a pipeline binary, and `report` |
| `morca.command` | `morca_command`, the `morca` binary (scheduler, UI, registration) |
| `morca.maintain` | `maintain_main`, the `morca_maintain` binary (snapshot expiry) |

From `morca` too: `outdated()`, `outdated_why()`, `code_version()` and
`desired_code_version()` (whether this run's code is still the one to
run), and `Grant` and `auto_count` (what a run was given, and a count of
work sized to it). A pipeline declares sensors with `Pipeline[...,
sensor=True]`; the sensing itself is internal.

`morca.tables`, `morca.keyed` and `morca.rust_step` aren't re-exported
from `morca`: tables load liblake (#454), and `morca.rust_step` imports
iceberg, which the `morca` binary and a pipeline without tables don't
need.

**Kept for compatibility, no stability promise.** `morca` still exports
the run stores (`Store`, `RunStore`, `MemoryStore`, `Recorder`, `RunInfo`,
`StepInfo`, `TableSnapshot`, `State`, `PgStore`, `SqliteStore`,
`sqlite_path`) and memory pressure (`Psi`, `Stall`, `memory_pressure`), and
the modules that defined them (`morca.store`, `morca.state`,
`morca.sqlite_store`, `morca.pressure`, `morca.resources`,
`morca.handover`) re-export just those names. They are internals.

**Internals** are everything under `morca._internal`: the scheduler, the
stores and their SQL, the runners, the UI and its API, the command line's
subcommands. They change without notice; a pipeline shouldn't import them.
"""

from morca._internal.cli import morca_main, report
from morca.ctx import Ctx
from morca.civil import Civil, now, parse_time, utc
from morca.cron import CronExpr
from morca.day import Day
from morca.hour import Hour
from morca.key import Key, TimeKey, parse_keys
from morca.month import Month, days_in, parse_months
from morca._internal.handover import (
    code_version,
    desired_code_version,
    outdated,
    outdated_why,
)
from morca.name import Name, parse_names
from morca.partitions import (
    Daily,
    Hourly,
    Monthly,
    Partitions,
    parse_partitions,
)
from morca.pipeline import (
    FAILED,
    SKIPPED,
    SUCCEEDED,
    Pipeline,
    RunResult,
    StepRun,
)
from morca._internal.resources import Grant, auto_count
from morca.schedule import (
    Cron,
    Current,
    Fill,
    NoSchedule,
    Previous,
    Schedule,
    ScheduleLike,
)
from morca.tasks import NoTasks, Tasks, TaskSet, workers
from morca.step import (
    Gather,
    Mapped,
    NoStep,
    Step,
    StepKind,
    StepLike,
    defer,
)
from morca.tz import PosixTZ, Zone

# Kept for compatibility, with no stability promise: internals (#382).
from morca._internal.pressure import Psi, Stall, memory_pressure
from morca._internal.sqlite_store import SqliteStore, sqlite_path
from morca._internal.state import PgStore, State
from morca._internal.store import (
    MemoryStore,
    Recorder,
    RunInfo,
    RunStore,
    StepInfo,
    Store,
    TableSnapshot,
)
