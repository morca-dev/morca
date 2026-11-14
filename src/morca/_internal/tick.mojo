"""One pass of the scheduler (`morca tick`; `morca scheduler` makes one a
second): what each registered pipeline is due, started, the highest
`priority` first and, within one priority, every pipeline's other runs
before any pipeline's fill runs (#421).
"""

from std.time import perf_counter_ns
from std.os import remove
import morca._internal.db.scheduler as scheduler_db
import morca._internal.db.starting as starting_db
from morca._internal.db.fill_requests import requested
from morca._internal.alerts import failed_runs
from morca._internal.notify import configured as notify_configured
from morca._internal.logs import publish
from morca._internal.proc import reap
from morca._internal.sensors import advance_rebuilds
from morca._internal.recommend import (
    LEARN_RUNS,
    expire_raised,
)
from morca._internal.usage import record as record_usage
from morca._internal.scheduler import (
    Scheduler,
    _ControlProc,
    _RETRIED,
)
from morca._internal.starting import _start
from morca._internal.sensing import (
    _fire,
    _sense,
    _sensed,
)
from morca._internal.registered import Registered, registered


def tick(mut self: Scheduler, now: Int64) raises:
    """One pass: reap ended runs, advance rebuilds, make due fires,
    sense new snapshots, schedule retries, and start what may start."""
    for done in reap():
        var asked = String()
        for e in self._asked.items():
            if e.value.pid == done.pid:
                asked = e.key
        if asked:
            var c = self._asked.pop(asked)
            c.code = done.code
            self._asked[asked] = c^
            continue
        if done.pid in self._keeping:
            var stage = self._keeping.pop(done.pid)
            if done.code != 0:
                print("morca: keep-log exited", done.code, "keeping", stage)
            try:
                remove(stage)
            except:
                pass
            continue
        print("reaped pid", done.pid, "exit", done.code)
        var spawned = self._spawned.pop(done.pid, (-1, 0, String()))
        var over = String()
        var ctl = Optional[_ControlProc](None)
        if done.pid in self._control:
            ctl = self._control.pop(done.pid)
            over = ctl.value().over
        var spent = self._uncontain(done.pid, done.code, over)
        if self._wedged.pop(done.pid, False) and not over:
            # Killed by _kill_wedged: its attempts say why, rather than
            # "killed by signal 9".
            over = String(
                "killed: its heartbeat went stale (MORCA_STALE_SECONDS,",
                " ",
                Int(self.stale),
                " s), so the scheduler stopped its process",
            )
        if spawned[0] >= 0:
            try:
                self._exited(spawned, done.pid, done.code, over)
                if spent:
                    self._fail_spent(spawned, over)
            except e:
                print("morca: can't record run", spawned[0], "exiting:", e)
        if done.pid in self._meters:
            var m = self._meters.pop(done.pid)
            m.end(done.max_rss, done.cpu_seconds)
            try:
                _ = record_usage(
                    self.db, spawned[0], done.pid, m.aged(), m.max_rss
                )
            except e:
                print("morca: can't record run", spawned[0], "usage:", e)
        if ctl:
            self._keep_control_log(ctl.value())
        if done.pid in self._kept:
            self._keep_control_log(self._kept.pop(done.pid))
        var log = self._driver_logs.pop(done.pid, "")
        if log:
            try:
                publish(log)
            except e:
                print("morca: can't keep the driver log at", log, ":", e)
    var readings = self._sample()
    self._kill_held()
    try:
        self._kill_wedged()
    except e:
        print("morca: can't check its runs' heartbeats:", e)
    if self.instance > 0:
        self._lead()
        if not self.leading:
            # Supervising what it started, deciding nothing.
            self._record_cgroups()
            try:
                self._check_control_memory(readings)
            except e:
                print("morca: can't check control-placed runs' memory:", e)
            return
        try:
            self._going = scheduler_db.local_running(
                self.db.conn, self.stale, self._dead("$1")
            )
        except e:
            print("morca: can't count this host's runs:", e)
    try:
        self._pressure()
    except e:
        print("morca: can't keep the memory pressure:", e)
    self._record_cgroups()
    if self.runner:
        try:
            var n = self.runner.value().sweep(self.db)
            if n:
                print("deleted", n, "objects of runs that ended")
        except e:
            print("morca: can't sweep run clusters:", e)
    # Worker pools morca grows and shrinks (morca.pool_scale), every
    # MORCA_POOL_SCALE_SECONDS.
    if self.pools.due(Float64(perf_counter_ns()) / 1e9):
        try:
            self.pools.scale(self.db)
        except e:
            print("morca: can't scale worker pools:", e)
    if self.ec2:
        try:
            var n = self.ec2.value().sweep(self.db)
            if n:
                print("terminated", n, "instances of runs that ended")
        except e:
            print("morca: can't sweep run instances:", e)
        try:
            var moved = self.ec2.value().scale(self.db)
            if moved[0] or moved[1]:
                print(
                    "scaled run workers:",
                    moved[0],
                    "started,",
                    moved[1],
                    "drained",
                )
        except e:
            print("morca: can't scale run workers:", e)
    try:
        self._check_control_memory(readings)
    except e:
        print("morca: can't check control-placed runs' memory:", e)
    try:
        self._fleet()
    except e:
        print("morca: can't keep the fleet's samples:", e)
    try:
        self._watchdog()
    except e:
        print("morca: can't check the watchdog's rules:", e)
    try:
        self._notify(now)
    except e:
        print("morca: can't raise alerts:", e)
    advance_rebuilds(self.db)
    try:
        self._expire()
    except e:
        print("morca: can't expire snapshots:", e)
    try:
        for name in expire_raised(self.db):
            print(
                "morca:",
                name,
                (
                    "no longer asks for the memory an out-of-memory kill"
                    " raised it to:"
                ),
                LEARN_RUNS,
                "runs have succeeded since",
            )
    except e:
        print("morca: can't expire out-of-memory raises:", e)
    # Highest priority first (#421): fires, sensors and retries queue
    # what each pipeline is due, then each priority's pipelines start
    # their other runs, by name, before any of them starts a fill run, so
    # a fill takes only the room the others left.
    var ps = registered(self.db)
    for p in ps:
        if p.cron:
            try:
                _fire(self, p, now)
            except e:
                print("morca: pipeline", p.name, "can't fire:", e)
        if p.sensor:
            var error = String()
            try:
                _sense(self, p, now)
            except e:
                error = String(e)
            _sensed(self, p, error)
        self._schedule_retries(p, now)
        if notify_configured():
            try:
                _ = failed_runs(self.db, p.name, p.run_retries, _RETRIED)
            except e:
                print("morca: can't alert on", p.name, "failures:", e)
    # A pipeline with a fill request (#465) has a fill pass with fills
    # off too.
    var asked = Dict[String, Bool]()
    for name in requested(self.db.conn):
        asked[name] = True
    var i = 0
    while i < len(ps):
        var j = i
        while j < len(ps) and ps[j].priority == ps[i].priority:
            j += 1
        for k in range(i, j):
            _start_again(self, ps[k], now)
        for k in range(i, j):
            if ps[k].fill.all or ps[k].name in asked:
                _start_again(self, ps[k], now, fill=True)
        i = j


comptime _START_TRIES = 3
"""How many times a tick tries a pipeline's start pass that Postgres ends
for a deadlock (#440)."""


def _start_again(
    mut self: Scheduler, p: Registered, now: Int64, fill: Bool = False
) raises:
    """`_start`, tried again, up to `_START_TRIES` times in all, when
    Postgres ends its transaction for a deadlock or a serialization
    failure (`starting_db.retryable`): the transaction rolled back, and
    the next try reads what is there now."""
    var tries = 1
    while True:
        try:
            _start(self, p, now, fill)
            return
        except e:
            if tries >= _START_TRIES or not starting_db.retryable(e):
                raise e^
            tries += 1
            print("morca: pipeline", p.name, "start pass tried again:", e)
