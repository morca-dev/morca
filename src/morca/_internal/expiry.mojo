"""Snapshot expiry, the scheduler's half: what morca still needs of a
dataset's history, and the binary that does the expiring.

Expiring needs iceberg, which the `morca` binary doesn't link, so it runs in
the project's `morca_maintain` binary (`morca._internal.maintain`). This side decides
what must survive whatever the table's policy says, from Postgres:

- **the snapshots a run that can still go on has read.** A step's reads are
  pinned: a retry or `resume` scans the snapshot the first attempt read,
  so a queued, running, deferred or failed run keeps every snapshot its
  attempts read. (A failed run can be resumed; a succeeded or cancelled one
  can't, and is let go.)
- **the snapshots such a run committed.** A retry finds the commits its
  step made before it was killed by looking through the table's snapshots
  (`morca.tables.find_commit`); one that was expired would be committed a
  second time.
- **every snapshot of the last run that committed to the dataset**, so an
  expiry never leaves fewer than one run's worth of history.

What expiry costs: `morca lineage` and the UI's dataset and snapshot pages
read Postgres only, so they still show an expired snapshot, what made it
and what it was made from; but the snapshot itself is gone from the table,
so it can no longer be read (time travel, `use_snapshot`), and a `rebuild`
reruns the pipelines from the current data, not from it.
"""

from std.os import getenv
from std.os.path import exists
from std.sys import argv

import morca._internal.db.expiry as expiry_db

from morca._internal.state import State


comptime MAINTAIN_BINARY = String("morca_maintain")


def retained(mut db: State, dataset: String) raises -> List[Int64]:
    """The snapshots of `dataset` morca still needs (see the module doc)."""
    return expiry_db.retained(db.conn, dataset)


def expirable(mut db: State) raises -> List[String]:
    """Every dataset morca has committed to, by name."""
    return expiry_db.committed(db.conn)


def maintain_binary() -> String:
    """`$MORCA_MAINTAIN`, else `morca_maintain` beside this binary, else on
    `PATH`; empty when there is none."""
    var set = getenv("MORCA_MAINTAIN")
    if set:
        return set
    var me = String(argv()[0])
    var slash = me.rfind("/").or_else(-1)
    if slash >= 0:
        var beside = String(me[byte = : slash + 1], MAINTAIN_BINARY)
        if exists(beside):
            return beside
    for dir in getenv("PATH").split(":"):
        if dir.byte_length() == 0:
            continue
        var p = String(dir, "/", MAINTAIN_BINARY)
        if exists(p):
            return p
    return String()


def expire_argv(
    mut db: State,
    binary: String,
    dataset: String,
    older_than: String = "",
    keep: String = "",
    dry_run: Bool = False,
    report: Bool = False,
) raises -> List[String]:
    """The `morca_maintain expire` command line for `dataset`: the policy
    given, or the table's own (`--if-policy`, so a table without one is
    left alone), and `--retain` with what morca still needs."""
    var a: List[String] = [binary, String("expire"), dataset]
    if older_than:
        a.append(String("--older-than"))
        a.append(older_than)
    else:
        a.append(String("--if-policy"))
    if keep:
        a.append(String("--keep"))
        a.append(keep)
    var keep_ids = retained(db, dataset)
    if len(keep_ids) > 0:
        var ids = String()
        for k in range(len(keep_ids)):
            ids.write("," if k > 0 else "", keep_ids[k])
        a.append(String("--retain"))
        a.append(ids^)
    if dry_run:
        a.append(String("--dry-run"))
    if report:
        a.append(String("--report"))
    return a^
