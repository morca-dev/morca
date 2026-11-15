# Future directions

Design notes on where morca's seams are and which ones are worth cutting,
written after 0.3.2 (November 2026). Nothing here is scheduled; the point is
to record the reasoning so a later change starts from it rather than from a
blank page. DESIGN.md says what morca is; this says what it could become and,
as often, what it shouldn't.

## The question

morca is tightly bound to its data layer: runs, steps, attempts, reads and
commits live in Postgres, tables are Iceberg, and lineage is spread over both
(rows in `reads`/`commits`, properties in snapshot summaries). Should there be
an interface so those can be replaced? Should there be an `morca-core` without
lineage and an `morca-full` with it?

## What the code says today

- **There is a seam, and it is the right shape.** `Store` (`src/morca/_internal/store.mojo`)
  is the executor's only view of persistence: six methods, two implementations
  (`MemoryStore`, `PgStore`). `Pipeline.execute` sees nothing else.
- **The seam stops at the executor.** `State` (`src/morca/_internal/state.mojo`, 22
  methods, Postgres only) is imported by eleven modules; the pipeline binary's
  `cli.mojo` calls thirteen of its methods directly; `Ctx`'s `Recorder` opens
  its own Postgres connection; the scheduler and the UI write SQL of their own.
- **Lineage is not a layer on top.** `reads` and `commits` are what make a
  retry safe: pinned reads give a second attempt the inputs the first had, and
  `find_commit` on the snapshot summary (`orca.run`, `orca.step`,
  `orca.partition`) is how a commit made just before a crash is recognised
  instead of repeated. DESIGN.md: "written from phase 1 because resuming needs
  them." A morca without lineage is a morca without safe retries.
- **The Iceberg side is already a leaf.** Nothing in morca imports `morca.tables`
  but itself, so a pipeline without tables doesn't link iceberg.
- **The control plane is already a separate binary.** The scheduler, the UI,
  auth, the Kubernetes and EC2 runners and flare live in `morca`, which never
  links a pipeline's dependencies (DESIGN.md, phase 2).

So "core versus full" already exists, at the module and the binary. Packaging
it as two tins would double the test matrix and give a user nothing they can
feel.

## What to do, in order

Each step is shippable on its own; none depends on a later one.

### 1. `Store` becomes the pipeline binary's whole view of persistence

Tracked in [#82](https://github.com/morca-dev/morca/issues/82).

- Extend `Store` (or add a `RunStore` that includes it) with the calls
  `cli.mojo` makes on `State`: `create_run`, `claim`, `interrupt`, `prior`,
  `finish_run`, `cancel_requested`, `run_info`, `steps`, `register`,
  `version`, `ran_version`, `migrate`. The pipeline binary then depends on
  the trait alone; `State` keeps the scheduler's and the UI's SQL.
- `Recorder` writes reads and commits through the store it came from
  (`Store.recorder` exists for this), and `ctx.mojo` stops importing postgres.
- `MemoryStore` implements the full trait. `<binary> run` without
  `MORCA_DATABASE_URL` is then the no-server mode on the production code path,
  and the executor's tests run without Postgres.

### 2. A second real backend: SQLite

`SqliteStore` over `sqlite-mojo`, for single-node morca (a laptop, one VM, CI)
with resumable runs and nothing to operate. It is the backend that proves the
trait's shape; a trait with one implementation is a cost and a trait with a
hypothetical third is a guess. `tests/chaos.sh` should pass against it, with
"Postgres restarts" becoming "reopen the file".

### 3. The scheduler and the UI stay on SQL

Claims with `SKIP LOCKED`, the run listings, the lineage queries, `DONE_SQL`
and `LIVE_SQL` are queries. A trait over them would grow a method per page
and hide the thing that matters about them, which is the SQL. They live in
the `morca` binary, so they weigh on nobody's pipeline. If single-node ever
needs the scheduler too, that is SQL to SQL with a small dialect shim
(`SKIP LOCKED` → `BEGIN IMMEDIATE`, `now()` → `datetime('now')`), not an
interface.

### 4. A seam on the table side, when a second format exists

The Iceberg-specific operations are three: `extra_summary` on a commit,
`find_commit` walking snapshots newest first, and `use_snapshot(id)` for
pinned reads. A Lance or Delta backend would implement those as a
`Catalog`-like trait, and `morca.tables` is already isolated enough that
carving it is a day's work. Doing it now would mean guessing at the other
format's commit model (Lance has versions, not snapshots with summaries;
Delta has a log). taxibench's Lance branch is the candidate that makes it
real.

### 5. If the package ever splits, split by binary

The pain a consumer feels is weight, not lineage: `shelf.toml` lists k8s,
flare and the UI as dependencies of every pipeline binary, because the shelf
has no optional tins. The cut that matches the design is

- `morca-mojo`: `pipeline`, `step`, `ctx`, the store trait and its memory and
  SQLite implementations, `tables`, `key`/partitions, dista;
- `morca-server` (or `morca-cli`): the scheduler, the UI, auth, the runners,
  flare, `PgStore`.

Do it when a consumer complains about build time or image size, with a
measurement in hand; not before.

## What not to do

- **No `morca-core` without lineage.** See above: lineage is the retry
  contract, not a feature.
- **No trait designed for one implementation.** Every interface here is cut
  when its second implementation is in the same PR.
- **No abstraction over the control plane's SQL.** It would be the largest
  interface in the codebase and the least stable.
- **No table trait before a second format.** `morca.tables` being a leaf is
  the isolation that matters today.
