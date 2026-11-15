# Notes for coding agents

## Changelog

Don't edit CHANGELOG.md: add `changes/<pr>-<slug>.<patch|minor>.md` with the
entry (`shelf changes new <pr>-<slug> --bump minor`; changes/README.md).
`shelf release apply` moves fragments into CHANGELOG.md. If the PR number
isn't known yet, use a slug and rename the file once the PR exists. Keep
the entry to one bullet: a bold title and one sentence on what changed for a
user (and anything they must do when upgrading), then `(#<pr>)`; the details
go in the PR.

## Code shape

- **File size.** Keep a source file under 1,000 lines, and split it before
  it passes 1,500. Split by concern into modules of their own, not into
  `part1`/`part2`. A change that would push a file past the limit splits it
  first, in a PR of its own that only moves code.
- **No circular imports.** Modules form layers: a module imports only those
  below it, never one that imports it back, directly or through others.
  Mojo compiles a cycle, so the compiler won't catch one. When two modules
  need each other, move what they share into a lower module, or pass a
  function or value in from the caller, instead. The packages are layers
  too: `morca._common` imports nothing of morca's, `morca._lake` (liblake
  and the plumbing that calls it) imports only `morca._common`, and
  `morca._internal` and the public modules may import both. `_lake` never
  imports `_internal`, `morca.ctx` or another public module, even for one
  helper: what both need goes in `_common`.

## Migrations

A deploy can be rolled back to an older image without restoring the
database, because an older morca runs on a newer schema as long as every
migration it doesn't know is additive (`schema_ahead` in
`src/morca/_internal/migrations.mojo`). Keep new migrations additive:

- add columns only nullable or with a default, never `NOT NULL` without one;
- add tables and indexes freely; a foreign key onto a table morca deletes
  from needs `ON DELETE CASCADE` or `SET NULL`;
- don't rename, drop or retype anything, tighten a constraint, change a key
  an `ON CONFLICT` names, write a status or other value older code reads and
  acts on, or give an old column a new meaning.

A migration that has to do one of those adds its version to
`_floor_raisers`, with why; from then on a rollback past it needs the
backup (docs/hetzner.md#rolling-back). Queries name their columns (in
`INSERT` and `SELECT`; `SELECT *` only over a subquery that names them) and
read rows by column name, so a new column never shifts what older code
reads. Bookkeeping for the migrations themselves (`orca.schema_version`) is
set up in `State.migrate` before them, not as a numbered migration.

## Writing fast data code

Morca runs pipelines whose stages read Iceberg tables and transform their rows. Before writing or speeding up code that loops over record batches,
or that filters, groups or aggregates rows, use the
[`mojo-data-performance`](https://github.com/magmalake/skills/tree/main/mojo-data-performance)
skill. It explains how to time the decoding apart from the work, without a
second implementation to compare against, and gives the loop and pipeline
rules magmalake has measured. Install it with Modular's `mojo-syntax`,
which keeps the Mojo current:

```text
/plugin marketplace add magmalake/skills     # Claude Code
/plugin install skills@magmalake
npx skills add magmalake/skills              # other agents
npx skills add modular/skills --skill mojo-syntax
```
