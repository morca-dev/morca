"""Lineage: which snapshots a dataset's snapshot was made from, and what was
made from it, from the reads and commits every attempt records.

```
morca lineage lake.report            the latest snapshot's, back and forward
morca lineage lake.report 4417...    one snapshot's
```

A snapshot that a morca attempt committed is **made** by that attempt: its
run, pipeline, step, partition and code, and the snapshots it read, its
**inputs**. The walks go over those edges in SQL (recursive CTEs):

- **`back`** from a snapshot: the attempt that made it, then the attempts
  that made each of its inputs, and so on, to inputs no morca attempt made
  (sources: a table written by something else, or a read of a dataset
  before it had any snapshot, which isn't listed).
- **`forward`** from a snapshot: every snapshot made by an attempt that read
  it, then what was made from those, and so on.

Both stop at `depth` steps (default 20), so a deep graph is cut rather than
slow. A snapshot recorded by two attempts (a retry that recognised its
earlier attempt's commit) is listed once, as the nearer and earlier. Only
datasets take part: a table outside the warehouse has no name to follow.
The same edges are in the snapshots' own summaries, as `orca.reads`.
"""

import morca._internal.db.lineage as lineage_db
from morca._internal.db.lineage import (
    Commit,
    Dataset,
    Flow,
    Made,
    SnapshotCursor,
    SnapshotRef,
)

from morca._internal.state import State


def back(mut db: State, start: SnapshotRef) raises -> List[Made]:
    """The snapshot, if a morca attempt made it, and everything it was made
    from: one `Made` per snapshot a morca attempt made."""
    return lineage_db.back(db.conn, start)


def forward(mut db: State, start: SnapshotRef) raises -> List[Made]:
    """Every snapshot made from `start`, directly or not."""
    return lineage_db.forward(db.conn, start)


def latest(mut db: State, dataset: String) raises -> Int64:
    """The dataset's newest snapshot morca knows of, committed or read, or
    -1 if it knows of none."""
    return lineage_db.latest(db.conn, dataset)


def datasets(mut db: State, only: String = "") raises -> List[Dataset]:
    """Every dataset a pipeline declares or an attempt touched, or the one
    named, by name."""
    return lineage_db.datasets(db.conn, only)


def flows(mut db: State) raises -> List[Flow]:
    """Every pipeline's declared reads and writes."""
    return lineage_db.flows(db.conn)


def commits(
    mut db: State,
    dataset: String,
    limit: Int = 50,
    before: SnapshotCursor = SnapshotCursor(0, 0),
    after: SnapshotCursor = SnapshotCursor(0, 0),
) raises -> List[Commit]:
    """The dataset's snapshots morca committed, newest first (by the attempt
    that first committed each, then the snapshot): those after `before` if
    it's set; with `after` set, the `limit` just before it, oldest first."""
    return lineage_db.commits(db.conn, dataset, limit, before, after)
