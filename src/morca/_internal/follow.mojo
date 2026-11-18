"""How far a dated sensor pipeline is behind the datasets it follows.

A sensor (`morca._internal.sensors`) runs when a dataset it reads, and doesn't write,
gets a snapshot, over the snapshot's partitions. What it follows has, then,
is every partition of those datasets that morca knows of:

- each snapshot a succeeded attempt of another pipeline committed
  (`orca.commits`), holding its step's partition, or the run's partitions
  for a gather step, as the sensor reads them;
- each snapshot the sensor saw otherwise (`orca.sensed`, from `<binary>
  sense`), holding the partitions of the run it started.

Those keys, in the sensor's kind and range (from its start to today), are
what it could have done; `follow` gives each its state as the calendar
does (`morca._internal.calendar`), so what's behind splits into running or queued,
failed, and not queued yet. A single query reads the keys (through the
`commits_snapshot` index), then the calendar's three.
"""

from std.collections import Dict

import morca._internal.db.sensing as sensing_db

from morca._internal.calendar import states_of
from morca.civil import Civil, now
from morca._internal.estimate import Pace, pace
from morca._internal.json import quote
from morca.name import sort_texts
from morca._internal.sensors import key_kind, map_keys, split_keys
from morca._internal.state import State
from morca._internal.timekeys import containing_key, is_time_kind, unit_of


comptime LISTED = 8
"""The most keys of each kind of behind `follow_json` and the page list."""


struct Follow(Movable):
    var datasets: List[String]
    """What the sensor follows, by name."""
    var upstream: List[String]
    """The pipelines that committed them, by name."""
    var unit: String
    """`day` or `month`."""
    var available: Int
    """The keys they have in the sensor's range."""
    var done: Int
    var live: List[String]
    """Behind: in a queued, deferred or running run."""
    var failed: List[String]
    """Behind: the last run over it failed."""
    var waiting: List[String]
    """Behind: in no run yet."""
    var keys: Dict[String, Bool]
    """Every key they have, for the calendar's `behind`."""
    var pace: Pace
    """How long its recent runs took, to estimate queuing `waiting`."""

    def __init__(out self, unit: String):
        self.datasets = List[String]()
        self.upstream = List[String]()
        self.unit = unit
        self.available = 0
        self.done = 0
        self.live = List[String]()
        self.failed = List[String]()
        self.waiting = List[String]()
        self.keys = Dict[String, Bool]()
        self.pace = Pace(-1.0, 0)

    def behind(self) -> Int:
        return len(self.live) + len(self.failed) + len(self.waiting)


def follow(
    mut db: State, pipeline: String, kind: String, start: String
) raises -> Optional[Follow]:
    """How far the dated sensor `pipeline` (of `kind`, from `start`) is
    behind what it follows; None if it isn't a dated sensor."""
    if not is_time_kind(kind):
        return None
    var rows = sensing_db.upstream(db.conn, pipeline)
    if len(rows) == 0:
        return None
    var f = Follow(unit_of(kind))
    var t = Civil.of(now())
    var today = containing_key(kind, t.year, t.month, t.day, t.hour)
    var seen = Dict[String, Bool]()
    var keys = List[String]()
    for r in rows:
        var ds = r.dataset
        var by = r.pipeline
        var text = r.keys
        if not text:
            if ds not in f.datasets:
                f.datasets.append(ds)
            continue
        if by and by not in f.upstream:
            f.upstream.append(by)
        for k in split_keys(text):
            if not key_kind(k):
                continue
            for m in map_keys([k], kind, start):
                if m <= today and m not in seen:
                    seen[m] = True
                    keys.append(m)
    sort_texts(f.datasets)
    sort_texts(f.upstream)
    sort_texts(keys)
    f.available = len(keys)
    if len(keys) > 0:
        for c in states_of(db, pipeline, start, today, keys):
            f.keys[c.key] = True
            if c.state == "done":
                f.done += 1
            elif c.state == "live":
                f.live.append(c.key)
            elif c.state == "failed":
                f.failed.append(c.key)
            else:
                f.waiting.append(c.key)
    if f.waiting:
        f.pace = pace(db, pipeline)
    return f^


def _keys_json(mut j: String, name: StaticString, keys: List[String]):
    j.write(', "', name, '": {"count": ', len(keys), ', "first": [')
    for i in range(min(len(keys), LISTED)):
        j.write(", " if i else "", quote(keys[i]))
    j.write("]}")


def follow_json(f: Follow) -> String:
    """`f` as JSON: what it follows, how many keys they have and are done,
    and the behind ones by state, each with its count and first keys."""
    var j = String('{"datasets": [')
    for i in range(len(f.datasets)):
        j.write(", " if i else "", quote(f.datasets[i]))
    j.write('], "upstream": [')
    for i in range(len(f.upstream)):
        j.write(", " if i else "", quote(f.upstream[i]))
    j.write(
        '], "unit": ',
        quote(f.unit),
        ', "available": ',
        f.available,
        ', "done": ',
        f.done,
        ', "behind": ',
        f.behind(),
    )
    _keys_json(j, "live", f.live)
    _keys_json(j, "failed", f.failed)
    _keys_json(j, "waiting", f.waiting)
    j.write("}")
    return j^
