"""The home page's recent runs (#354): one row per batch (`morca._internal.batches`),
so one backfill doesn't fill the list, and a run with none as its own row;
what needs attention first.
"""

import morca._internal.db.home_view as home_db

from morca._internal.json import quote
from morca._internal.state import State
from morca._internal.views.runs import RunRow, runs_one


@fieldwise_init
struct RecentRow(Copyable, Movable):
    """A row of the home page's recent runs: a batch, or one run (`run`)."""

    var batch: Int
    """The batch's id (its first run's), or 0 for a run of its own."""
    var first: Int
    var last: Int
    var runs: Int
    var pipeline: String
    var trigger: String
    var running: Int
    var queued: Int
    """Queued or deferred: waiting to start."""
    var succeeded: Int
    var failed: Int
    var cancelled: Int
    var created: String
    """When its first run was made, UTC."""
    var seconds: Int
    """From its first start to its last end (or now), -1 before any
    start."""
    var first_partitions: String
    var last_partitions: String
    var run: Optional[RunRow]
    """The run, for a row of one run."""

    def live(self) -> Bool:
        """Whether a run in it is queued or running."""
        return self.running > 0 or self.queued > 0

    def done(self) -> Int:
        """Its runs that have ended."""
        return self.succeeded + self.failed + self.cancelled


def recent_rows(mut db: State, limit: Int) raises -> List[RecentRow]:
    """The `limit` rows the home page's Recent runs shows: batches with a
    run running or failed in the last `FAILED_LATELY` first, then those
    with runs waiting, newest first; then the rest, the latest to end or
    start first. A batch counts all its runs; a run with no batch is a row
    of its own."""
    var out = List[RecentRow]()
    for r in home_db.recent_records(db.conn, limit):
        out.append(
            RecentRow(
                r.batch,
                r.first,
                r.last,
                r.runs,
                r.pipeline,
                r.trigger,
                r.running,
                r.queued,
                r.succeeded,
                r.failed,
                r.cancelled,
                r.created,
                r.seconds,
                r.first_partitions,
                r.last_partitions,
                None,
            )
        )
    # A row of one run shows the run, as the runs lists do.
    for ref row in out:
        if row.runs == 1:
            row.run = runs_one(db, row.first)
    return out^


def json_recent(mut j: String, rows: List[RecentRow]):
    """The rows as a JSON list: each batch's id (null for a run of its
    own), its first and last runs, its runs and each status's count."""
    j.write("[")
    for i in range(len(rows)):
        ref r = rows[i]
        j.write(
            ", " if i else "",
            '{"batch": ',
            String(r.batch) if r.batch else String("null"),
            ', "first": ',
            r.first,
            ', "last": ',
            r.last,
            ', "runs": ',
            r.runs,
            ', "pipeline": ',
            quote(r.pipeline),
            ', "trigger": ',
            quote(r.trigger),
            ', "created": ',
            quote(r.created),
            ', "counts": {"running": ',
            r.running,
            ', "queued": ',
            r.queued,
            ', "succeeded": ',
            r.succeeded,
            ', "failed": ',
            r.failed,
            ', "cancelled": ',
            r.cancelled,
            "}}",
        )
    j.write("]")
