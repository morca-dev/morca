"""A pipeline's coverage: one number for how much of it is done, shown on
the home page's table, its page's Progress card and in their JSON.

- A **daily or monthly** pipeline's is its partitions done of those in its
  range so far: from its first partition through the last one that has
  ended on the schedule's clock (UTC without a schedule), the range a fill
  works through (`morca._internal.fill.range_keys`). Today's day (this month) is
  still going, so it's in neither number, nor is one that ended less than
  the pipeline's `fill_lag` ago.
- A **keyed** pipeline's is its keys done of the keys morca knows: those
  `<binary> keys` last printed, as `orca.keys` keeps them (the scheduler's
  sensor and the pipeline's page read them; the home page never runs the
  binary).

**Done** is what the calendar and a backfill count as done
(`morca._internal.db.queueing.DONE_SQL`), and what the Fill line counts:
every mapped step of the pipeline succeeded for the key in a run of any of
its code with its current data version (the same steps' `version=`); with
no mapped step, such a run over the key succeeded. New code that keeps
every `version=` leaves keys done; a raised `version=`, or a new mapped
step, leaves them not done until they run again. A step `skipped` because
one before it failed isn't done, nor is a key done only under an older
data version. Running, queued, failed and never-run keys are all not
done.

A pipeline with nothing to count has no coverage (None, shown as "—"):
a dated one with no first partition, or whose first hasn't ended yet, and
a keyed one whose keys haven't been read, or are none.

**Cost**: one query, `DONE_SQL` over the range's keys, which looks each
key's steps up by the `steps_partition` index, so it grows with the range,
not with the runs: 7 ms for 1,492 days over 30,000 runs (10 ms with no
mapped step). A keyed pipeline's adds the read of its row of `orca.keys`.
Nothing is cached: the UI holds no state.
"""

from morca.civil import now
from morca._internal.fill import parse_fill_lag, range_keys
from morca._internal.json import quote
from morca._internal.queueing import (
    done_keys,
    kept_keys,
)
from morca._internal.state import State
from morca._internal.timekeys import is_time_kind, unit_of


@fieldwise_init
struct Coverage(Copyable, Movable):
    var done: Int
    var total: Int
    """At least 1: with none there's no coverage."""
    var unit: String
    """`day`, `month` or `key`."""

    def pct(self) -> Int:
        """Percent done, rounded down: 100 only when all are."""
        return self.done * 100 // self.total

    def pct1(self) -> Float64:
        """Percent done to a tenth, rounded down."""
        return Float64(self.done * 1000 // self.total) / 10.0

    def units(self) -> String:
        return String(self.unit, "" if self.total == 1 else "s")

    def text(self) -> String:
        """`1141 / 1407 days done (81%)`."""
        return String(
            self.done,
            " / ",
            self.total,
            " ",
            self.units(),
            " done (",
            self.pct(),
            "%)",
        )

    def json(self) -> String:
        """`{"done": 1141, "total": 1407, "pct": 81.0, "unit": "day"}`."""
        return String(
            '{"done": ',
            self.done,
            ', "total": ',
            self.total,
            ', "pct": ',
            self.pct1(),
            ', "unit": ',
            quote(self.unit),
            "}",
        )


def coverage_json(c: Optional[Coverage]) -> String:
    return c.value().json() if c else String("null")


def coverage(
    mut db: State,
    name: String,
    kind: String,
    start: String,
    tz: String,
    fill_lag: String = "",
) raises -> Optional[Coverage]:
    """`name`'s coverage now (see the module), or None if it has nothing
    to count. `fill_lag` is as registered (empty for none)."""
    var keys: List[String]
    var unit: String
    if is_time_kind(kind):
        var lag = parse_fill_lag(fill_lag) if fill_lag else 0
        keys = range_keys(kind, start, tz, now(), lag)
        unit = unit_of(kind)
    elif kind == "keyed":
        var kept = kept_keys(db, name)
        if not kept:
            return None
        keys = kept.value().keys.copy()
        unit = "key"
    else:
        return None
    if len(keys) == 0:
        return None
    return Coverage(len(done_keys(db, name, keys)), len(keys), unit)
