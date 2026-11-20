"""Fires and sensors (`morca._internal.scheduler`): a schedule's fires, and a sensor's
snapshots, keyed or by partition.
"""

from std.time import perf_counter_ns
from postgres import Transaction
from morca.civil import Civil
from morca.cron import CronExpr
from morca._internal.db.batches import mark_batch
from morca._internal.db.live import live_runs
import morca._internal.db.sensing as sensing_db
import morca._internal.db.starting as starting_db
from morca.schedule import Schedule
from morca._internal.sensors import (
    join_keys,
    map_keys,
    parse_sense,
    split_keys,
)
from morca.tz import Zone
from morca._internal.scheduler import Scheduler
from morca._internal.registered import (
    Registered,
    fill_key,
)
from morca._internal.queueing import (
    _queue,
    keep_keys,
    parse_keys_output,
)


def _sense(mut self: Scheduler, p: Registered, now: Int64) raises:
    """Queues a run for the snapshots of `p`'s datasets it hasn't seen:
    those other pipelines' succeeded runs committed since it became a
    sensor, and, when its binary is due to be asked, the current ones
    something other than morca committed. A snapshot with no partitions
    stands for the one `p` would fill now."""
    var datasets = List[String]()
    var snapshots = List[Int64]()
    var keys = List[String]()
    for c in sensing_db.unsensed(self.db.conn, p.name):
        datasets.append(c.dataset)
        snapshots.append(c.snapshot)
        keys.append(c.keys)
    var polled = Optional[String](None)
    if p.name in self._unsensed:
        polled = self._unsensed.pop(p.name)
    else:
        var job = String("sense ", p.name)
        var t = Int(perf_counter_ns())
        var last = self._polled.get(p.name)
        if (
            job in self._asked
            or not last
            or Float64(t - last.value()) >= self.sense_seconds * 1e9
        ):
            if job not in self._asked:
                self._polled[p.name] = t
            polled = self._ask(job, "sense", [p.binary, "sense"])
    if polled:
        for c in parse_sense(polled.value()):
            if c.snapshot >= 0 and not c.by_morca:
                datasets.append(c.dataset)
                snapshots.append(c.snapshot)
                keys.append(c.partitions)
    if len(datasets) == 0:
        return
    if p.kind == "keyed":
        var current = _keys_for(self, p, datasets, snapshots)
        if not current:
            # Its keys are still being read: this pass waits for them,
            # with what `sense` said kept for it.
            if polled:
                self._unsensed[p.name] = polled.value()
            return
        _sense_keyed(
            self, p, current.value()[1].copy(), datasets, snapshots, keys
        )
        return
    var fallback: String
    if p.cron:
        var z = Zone.load(p.tz)
        fallback = fill_key(p.kind, p.fills, Civil.of(z.to_local(now)))
    else:
        fallback = fill_key(p.kind, "current", Civil.of(now))
    var tx = self.db.conn.begin()
    starting_db.lock_pipeline(tx, p.name)
    var taken = List[Int]()
    var unusable = List[Tuple[Int, String]]()
    var all = List[String]()
    # Each key a snapshot offers, with that snapshot: a live run of the
    # key may have read an older one.
    var offered = Offered()
    for i in range(len(datasets)):
        # Seen by another tick already, or twice in this one.
        if not sensing_db.see(tx, p.name, datasets[i], snapshots[i]):
            continue
        var ks = split_keys(keys[i])
        if len(ks) == 0:
            ks.append(fallback)
        # Keys that aren't partitions, such as a week another writer
        # put in `orca.partitions`, run nothing: the snapshot is seen,
        # with why, so it doesn't stop the others or the next tick.
        var mk: List[String]
        try:
            mk = map_keys(ks, p.kind, p.start)
        except e:
            sensing_db.sensed_error(
                tx, p.name, datasets[i], snapshots[i], String(e)
            )
            unusable.append((i, String(e)))
            continue
        taken.append(i)
        for k in mk:
            offered.add(k, datasets[i], snapshots[i])
        all.extend(ks^)
    var run = Int64(-1)
    # Keys a live run has are left to it, which becomes the snapshot's
    # run if it left nothing else; but a key whose live runs all read an
    # older snapshot than one offering it is queued again, behind them
    # (#139).
    var live = _live_for(tx, p, offered)
    var mapped = List[String]()
    var held = Int64(-1)
    var behind = Int64(-1)
    for k in map_keys(all, p.kind, p.start):
        var in_run = live[0].get(k)
        if in_run:
            if held < 0:
                held = Int64(in_run.value())
            continue
        mapped.append(k)
        var stale = live[1].get(k)
        if stale and behind < 0:
            behind = Int64(stale.value())
    var did = String()
    if len(mapped) == 0:
        run = held
    if len(mapped) > 0:
        var q = _queue_sensed(tx, p, mapped)
        run = q[0]
        did = q[1]
        if behind >= 0:
            did.write(", behind live run ", behind)
    if run >= 0:
        for i in taken:
            sensing_db.sensed_run(tx, p.name, datasets[i], snapshots[i], run)
    tx.commit()
    for i in taken:
        print(
            "sensed",
            String(datasets[i], "@", snapshots[i]),
            "for",
            p.name,
            did if len(mapped)
            > 0 else (
                String("left to live run ", run) if run
                >= 0 else "before its first partition"
            ),
        )
    for u in unusable:
        print(
            "sensed",
            String(datasets[u[0]], "@", snapshots[u[0]]),
            "for",
            p.name,
            "and ran nothing:",
            u[1],
        )


struct Offered(Movable):
    """Keys sensed snapshots offer, each beside its dataset and snapshot."""

    var keys: List[String]
    var datasets: List[String]
    var snapshots: List[String]

    def __init__(out self):
        self.keys = List[String]()
        self.datasets = List[String]()
        self.snapshots = List[String]()

    def add(mut self, key: String, dataset: String, snapshot: Int64):
        self.keys.append(key)
        self.datasets.append(dataset)
        self.snapshots.append(String(snapshot))


def _live_for(
    mut tx: Transaction, p: Registered, offered: Offered
) raises -> Tuple[Dict[String, Int], Dict[String, Int]]:
    """Of the keys `offered`, those a live run of `p` has, each with the
    first live run that read no older snapshot of the datasets offering
    it, which the key is left to; and, for the others, the first live run
    that did, which a run queued for the key waits behind. A run
    read an older snapshot when a step over the key (or over all the
    run's keys) read the dataset at another one, unless morca committed
    both and that one later. One that hasn't read it yet will read the
    new one."""
    var left = Dict[String, Int]()
    var stale = Dict[String, Int]()
    if len(offered.keys) == 0:
        return (left^, stale^)
    for r in sensing_db.live_keys(
        tx,
        p.name,
        join_keys(offered.keys),
        join_keys(offered.datasets),
        join_keys(offered.snapshots),
    ):
        if r.behind:
            if r.key not in stale:
                stale[r.key] = r.run
        elif r.key not in left:
            left[r.key] = r.run
    return (left^, stale^)


def _queue_sensed(
    mut tx: Transaction, p: Registered, keys: List[String]
) raises -> Tuple[Int64, String]:
    """Runs of `p` over `keys` (sorted, none left to a live run), trigger
    `sensor`; returns the first, and what was done for the log. With
    `keys_per_run` 1, the default, one run over them all, as before #240.
    Above 1, at most `keys_per_run` keys to a run (#240): the sensor runs
    queued and never started take keys first, oldest first, up to that;
    the rest are new runs, in key order. So a catch-up of one upstream
    snapshot a tick still makes few runs. The caller holds `p`'s row
    `FOR UPDATE`, as a start or a worker's claim does, so a run topped up
    hasn't started meanwhile."""
    var k = p.keys_per_run
    if k <= 1:
        var id = sensing_db.add_sensor_run(
            tx, p.name, p.registry_hash, join_keys(keys)
        )
        return (id, String("run ", id, " for ", join_keys(keys)))
    var first = Int64(-1)
    var log = String()
    var made = List[Int64]()
    var i = 0
    for r in sensing_db.unstarted_sensor_runs(tx, p.name, p.registry_hash):
        if i >= len(keys):
            break
        var have = split_keys(r.partitions)
        if len(have) >= k:
            continue
        var added = List[String]()
        while i < len(keys) and len(have) + len(added) < k:
            added.append(keys[i])
            i += 1
        var both = have.copy()
        both.extend(added.copy())
        var id = r.id
        sensing_db.set_partitions(tx, id, join_keys(map_keys(both, p.kind)))
        if first < 0:
            first = id
        log.write(
            "; " if log else "",
            "run ",
            id,
            " (queued) takes ",
            join_keys(added),
        )
    while i < len(keys):
        var batch = List[String]()
        while i < len(keys) and len(batch) < k:
            batch.append(keys[i])
            i += 1
        var id = sensing_db.add_sensor_run(
            tx, p.name, p.registry_hash, join_keys(batch)
        )
        if first < 0:
            first = id
        made.append(id)
        log.write("; " if log else "", "run ", id, " for ", join_keys(batch))
    # The new runs are one batch; those topped up keep theirs.
    mark_batch(tx, made)
    return (first, log^)


def _sensed(mut self: Scheduler, p: Registered, error: String) raises:
    """Records how `p`'s pass went: the error of one that failed, which
    is printed when it's new rather than on every tick, or none. A
    pass still waiting for its `sense` or `keys` changes nothing."""
    if not error and (
        String("sense ", p.name) in self._asked
        or String("keys ", p.name) in self._asked
    ):
        return
    if not error:
        sensing_db.clear_sense_error(self.db.conn, p.name)
        return
    if sensing_db.set_sense_error(self.db.conn, p.name, error):
        print("morca: pipeline", p.name, "can't sense:", error)


def _keys_for(
    mut self: Scheduler,
    p: Registered,
    datasets: List[String],
    snapshots: List[Int64],
) raises -> Optional[Tuple[Int64, List[String]]]:
    """A keyed sensor's current keys: those last read if no snapshot of
    its keys dataset among `snapshots` is newer than theirs, else from
    `<binary> keys`, which may still be going (None)."""
    var keys_snap = Int64(-1)
    for i in range(len(datasets)):
        if datasets[i] == p.keys_dataset:
            keys_snap = snapshots[i]
    var have = self._keys.get(p.name)
    if have and (keys_snap < 0 or have.value()[0] == keys_snap):
        return have.value().copy()
    var out = self._ask(
        String("keys ", p.name),
        String("morca: ", p.binary, " keys"),
        [p.binary, "keys"],
    )
    if not out:
        return None
    var got = parse_keys_output(p.binary, out.value())
    keep_keys(self.db, p.name, got)
    self._keys[p.name] = got.copy()
    return got^


def _sense_keyed(
    mut self: Scheduler,
    p: Registered,
    var all_keys: List[String],
    datasets: List[String],
    snapshots: List[Int64],
    keys: List[String],
) raises:
    """For a keyed sensor whose current keys are `all_keys`: a snapshot
    of its keys dataset offers every current key, and one of another
    dataset the names it holds that are current keys; the offered keys
    that aren't done or in a live run are queued, `keys_per_run` to a
    run."""
    var cur = Dict[String, Bool]()
    for k in all_keys:
        cur[k] = True
    var tx = self.db.conn.begin()
    var taken = List[Int]()
    var everything = False
    var offer = List[String]()
    for i in range(len(datasets)):
        if not sensing_db.see(tx, p.name, datasets[i], snapshots[i]):
            continue
        taken.append(i)
        if datasets[i] == p.keys_dataset:
            everything = True
        else:
            # Names a keyed pipeline upstream committed; others aren't
            # this pipeline's to run.
            for k in split_keys(keys[i]):
                if k in cur:
                    offer.append(k)
    var runs = _queue(
        tx, p, all_keys if everything else offer, "sensor"
    ).runs.copy()
    if len(runs) > 0:
        for i in taken:
            sensing_db.sensed_run(
                tx, p.name, datasets[i], snapshots[i], Int64(runs[0])
            )
    tx.commit()
    for i in taken:
        print(
            "sensed",
            String(datasets[i], "@", snapshots[i]),
            "for",
            p.name,
            String(len(runs), " runs from run ", runs[0]) if len(runs)
            > 0 else "no new keys",
        )


def _fire(mut self: Scheduler, p: Registered, now: Int64) raises:
    var s = Schedule(CronExpr.parse(p.cron), Zone.load(p.tz))
    var last = sensing_db.last_fire(self.db.conn, p.name, p.since)
    var times = List[Int64]()
    var t = last
    # Many missed fires are made a thousand at a time, one per tick.
    while len(times) < 1000:
        t = s.next_fire(t)
        if t > now:
            break
        times.append(t)
    if not p.catchup and len(times) > 1:
        times = [times[len(times) - 1]]
    for t in times:
        var key = fill_key(p.kind, p.fills, Civil.of(s.zone.to_local(t)))
        var tx = self.db.conn.begin()
        starting_db.lock_pipeline(tx, p.name)
        var made = sensing_db.add_fire(tx, p.name, t, key)
        var run = Int64(-1)
        var held = False
        # Keys of one kind order as text: `YYYY-MM`, `YYYY-MM-DD`.
        if made and (not p.start or key >= p.start):
            # A live run of the key is the fire's run: a second one
            # would run beside it, and both would append.
            var live = live_runs(tx, p.name).get(key)
            held = Bool(live)
            run = Int64(live.value()) if live else _queue_fire(self, tx, p, key)
            sensing_db.fire_run(tx, p.name, t, run)
        tx.commit()
        if made:
            print(
                "fired",
                p.name,
                "at",
                String(Civil.of(t), "Z"),
                "for",
                key,
                String("left to live run ", run) if held else (
                    String("run ", run) if run >= 0 else "before the start"
                ),
            )


def _queue_fire(
    mut self: Scheduler, mut tx: Transaction, p: Registered, key: String
) raises -> Int64:
    """A queued run of `p` over `key`, trigger `schedule`."""
    return sensing_db.add_schedule_run(tx, p.name, p.registry_hash, key)
