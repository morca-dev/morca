"""morca's runs in a SQLite file: `SqliteStore`, for single-node morca.

A pipeline binary takes `MORCA_DATABASE_URL=sqlite:<path>` (or
`sqlite://<path>`, so `sqlite:///var/orca/runs.db` is an absolute path):
`run`, `resume` and `status` then keep pipelines, runs, steps, attempts,
reads and commits in that file, through sqlite-mojo, with nothing to
operate. A run killed anywhere is resumed from the file as from Postgres,
by the same `RunStore` code path. The scheduler, the UI and morca's other
commands stay on Postgres (`morca._internal.state.State` refuses a SQLite URL).

The tables are Postgres's, under the same names without the `orca.` schema,
holding what a pipeline binary writes: steps' inputs and outputs are hex
text, times are Unix seconds (`julianday` based, to the millisecond). The
schema is `morca._internal.db.sqlite_schema`'s, the queries `morca._internal.db.sqlite_runs`'.

**Concurrency.** The file is in WAL mode, so readers (`status`, `sqlite3`)
don't block the writer and the writer doesn't block them. There is one
writer at a time: each change is one `BEGIN IMMEDIATE` transaction, which
takes the file's write lock up front, and a writer that finds it taken
waits up to a second (`busy_timeout`), then fails; the owned run's writes
are retried, reopening the file, for `MORCA_DB_RETRY_SECONDS`, as `PgStore`
reconnects. That serialises several runs' processes on one machine, which
is fine for steps that take seconds and rows that take microseconds; it
isn't meant for hundreds of runs at once. Claims are a single guarded
`UPDATE`, so two resumes racing for a run can't both win, and every attempt
checks ownership in its own transaction, as on Postgres. The file must be
on a local disk: SQLite's locks don't hold over NFS and most network file
systems, so two machines must not share one.

`synchronous = FULL`: a commit is on disk before it returns, so a power
loss, not only a killed process, keeps every recorded attempt.
"""

from std.ffi import external_call
from std.os import getenv

from sqlite import Database

import morca._internal.db.sqlite_runs as sql
import morca._internal.db.sqlite_schema as schema
from morca._internal.db.sqlite_runs import to_hex
from morca._internal.heartbeat import Beater, Heartbeat
from morca._internal.store import (
    DEFERRED,
    FAILED,
    FINAL,
    INTERRUPTED,
    RUNNING,
    SUCCEEDED,
    Backoff,
    RunResult,
    RunStore,
    status_list,
    StepRun,
    TableSnapshot,
)
from morca._internal.db.run_rows import RunInfo, StepInfo

comptime _BUSY_MS = 1000
"""How long a write waits for another writer's lock before it fails (and,
for the owned run, is retried on the file opened again)."""


def sqlite_path(url: String) -> String:
    """The file of `sqlite:<path>` or `sqlite://<path>`, or empty if `url`
    isn't a SQLite URL."""
    if not url.startswith("sqlite:"):
        return String()
    var rest = String(url[byte=7:])
    if rest.startswith("//"):
        return String(rest[byte=2:])
    return rest^


def _open(path: String) raises -> Database:
    var db = Database(path)
    db.execute(String("PRAGMA busy_timeout = ", _BUSY_MS))
    db.execute("PRAGMA journal_mode = WAL")
    db.execute("PRAGMA synchronous = FULL")
    db.execute("PRAGMA foreign_keys = ON")
    return db^


def _rollback(db: Database):
    try:
        db.execute("ROLLBACK")
    except:
        pass


struct SqliteBeat(Beater):
    """Refreshes a run's heartbeat in the file, on a connection of its own."""

    var path: String
    var run: Int
    var owner: String
    var timeouts: String
    """`step=seconds` for each step with a timeout, comma-separated."""
    var _db: Optional[Database]

    def __init__(
        out self, path: String, run: Int, owner: String, timeouts: String = ""
    ):
        self.path = path
        self.run = run
        self.owner = owner
        self.timeouts = timeouts
        self._db = None

    def beat(mut self) raises:
        if not self._db:
            self._db = _open(self.path)
        sql.beat(self._db.value(), self.run, self.owner)
        # The watchdog (morca.heartbeat): an attempt past its step's
        # timeout stops the process. There's no cancel to time out here:
        # `morca cancel` is the scheduler's, on Postgres.
        var why = self._timed_out()
        if why:
            print("run", self.run, why, flush=True)
            external_call["_exit", NoneType](Int32(1))

    def _timed_out(mut self) raises -> String:
        """Fails the attempt past its step's timeout, its step and the run,
        in one transaction, and says why; empty if there's none."""
        if not self.timeouts:
            return ""
        ref db = self._db.value()
        for pair in self.timeouts.split(","):
            var eq = pair.find("=").or_else(-1)
            if eq <= 0:
                continue
            var step = String(pair[byte=:eq])
            var secs = Float64(String(pair[byte = eq + 1 :]))
            var got = sql.timed_out(db, self.run, step, self.owner, secs)
            if not got:
                continue
            var attempt = got.value().attempt
            var partition = got.value().partition
            var why = String(
                "timed out after ",
                Int(secs),
                " s (timeout_seconds), so its process was stopped",
            )
            db.execute("BEGIN IMMEDIATE")
            try:
                if not sql.fail_attempt(db, attempt, why):
                    _rollback(db)
                    return ""  # it ended as we looked
                var named = String("step ", step)
                if partition:
                    named.write(" ", partition)
                var run_why = String(named, " ", why)
                sql.fail(db, self.run, self.owner, run_why)
                db.execute("COMMIT")
                return run_why^
            except e:
                _rollback(db)
                raise e^
        return ""

    def reset(mut self):
        self._db = None


struct SqliteStore(Movable, RunStore):
    """morca's runs in a SQLite file, as their owner."""

    var path: String
    var db: Database
    var run: Int
    var owner: String
    var registry_hash: String
    var _attempt_id: Int
    """The `attempts` row of the attempt last started."""
    var _heartbeat: Optional[Heartbeat[SqliteBeat]]

    def __init__(out self, path: String) raises:
        """Opens the file at `path`, creating it if there's none; `own` a
        run before recording attempts."""
        if not path:
            raise Error("morca: no file in the SQLite URL")
        self.path = path
        self.db = _open(path)
        self.run = 0
        self.owner = String()
        self.registry_hash = String()
        self._attempt_id = 0
        self._heartbeat = None

    def _reopen(mut self):
        try:
            self.db = _open(self.path)
        except:
            pass  # the next try fails too, and comes back here

    # --- RunStore ---

    def migrate(mut self) raises:
        # BEGIN IMMEDIATE takes the write lock: two processes starting at
        # once apply each migration once.
        self.db.execute("BEGIN IMMEDIATE")
        try:
            schema.ensure(self.db)
            var have = schema.current(self.db)
            var migrations = schema.migrations()
            if have > len(migrations):
                raise Error(
                    "morca: the SQLite file is at schema version ",
                    have,
                    ", newer than this binary's ",
                    len(migrations),
                )
            for v in range(have, len(migrations)):
                for stmt in migrations[v]:
                    self.db.execute(stmt)
                schema.applied(self.db, v + 1)
            self.db.execute("COMMIT")
        except e:
            _rollback(self.db)
            raise e^

    def register(
        mut self, pipeline: String, registry_hash: String, describe: String
    ) raises:
        sql.register(self.db, pipeline, registry_hash, describe)
        var v = self.version(
            pipeline, registry_hash, describe, getenv("MORCA_IMAGE")
        )
        sql.set_version(self.db, pipeline, v)

    def scheduled_hash(mut self, pipeline: String) raises -> String:
        return sql.scheduled_hash(self.db, pipeline)

    def version(
        mut self,
        pipeline: String,
        registry_hash: String,
        describe: String,
        image: String,
    ) raises -> Int:
        return sql.version(self.db, pipeline, registry_hash, describe, image)

    def create_run(
        mut self,
        pipeline: String,
        registry_hash: String,
        partitions: String,
        trigger: String,
        owner: String,
    ) raises -> Int:
        return sql.create(
            self.db, pipeline, registry_hash, partitions, trigger, owner
        )

    def claim(mut self, run: Int, owner: String, stale_seconds: Float64) raises:
        if sql.claim(self.db, run, owner, stale_seconds):
            return
        var info = self.run_info(run)
        if (
            info.status != RUNNING
            and info.status != FAILED
            and info.status != DEFERRED
            and info.status != "queued"
        ):
            raise Error("morca: run ", run, " is ", info.status)
        raise Error(
            "morca: run ",
            run,
            " is held by ",
            info.owner,
            ", whose heartbeat is fresher than ",
            stale_seconds,
            " s",
        )

    def ran_version(mut self, run: Int, version: Int) raises:
        sql.ran_version(self.db, run, version)

    def interrupt(mut self, run: Int, why: String = "") raises -> Int:
        self.db.execute("BEGIN IMMEDIATE")
        try:
            var n = sql.fail_running_attempts(
                self.db, run, why if why else INTERRUPTED
            )
            sql.fail_running_steps(
                self.db, run, why if why else String("interrupted")
            )
            self.db.execute("COMMIT")
            return n
        except e:
            _rollback(self.db)
            raise e^

    def prior(mut self, run: Int) raises -> RunResult:
        var res = RunResult()
        for r in sql.succeeded(self.db, run):
            res.steps.append(
                StepRun(r.step, r.partition, SUCCEEDED, r.output.copy(), "")
            )
        return res^

    def run_info(mut self, run: Int) raises -> RunInfo:
        var got = sql.info(self.db, run)
        if not got:
            raise Error("morca: no run ", run)
        return got.take()

    def runs(
        mut self, limit: Int, before: Int = 0, status: String = ""
    ) raises -> List[RunInfo]:
        return sql.latest(
            self.db, limit, before, String(",").join(status_list(status))
        )

    def steps(mut self, run: Int) raises -> List[StepInfo]:
        return sql.of_run(self.db, run)

    def own(mut self, run: Int, owner: String, registry_hash: String) raises:
        self.run = run
        self.owner = owner
        self.registry_hash = registry_hash

    def start_heartbeat(
        mut self, interval: Float64, timeouts: String = ""
    ) raises:
        self._heartbeat = Heartbeat(
            SqliteBeat(self.path, self.run, self.owner, timeouts), interval
        )

    def stop_heartbeat(mut self):
        self._heartbeat = None

    def finish_run(mut self, status: String) raises:
        var r = Backoff("SQLite")
        while True:
            try:
                sql.finish(self.db, self.run, self.owner, status)
                return
            except e:
                r.again(e)
                self._reopen()

    def defer_run(mut self, until: Int64) raises:
        var r = Backoff("SQLite")
        while True:
            try:
                sql.defer_run(self.db, self.run, self.owner, until)
                return
            except e:
                r.again(e)
                self._reopen()

    def cancel_requested(mut self) raises -> Bool:
        var r = Backoff("SQLite")
        while True:
            try:
                return sql.cancel_requested(self.db, self.run)
            except e:
                r.again(e)
                self._reopen()

    # --- Store: the owned run's attempts, each change one transaction ---

    def _still_owner(mut self, starting: Bool) raises:
        """Raises unless this process still owns the run, or, when a step is
        `starting`, if the run was asked to cancel. In the transaction."""
        var o = sql.still_owner(self.db, self.run, self.owner)
        if not o.owned:
            raise Error(
                FINAL,
                "morca: lost run ",
                self.run,
                " to another process; stopping",
            )
        if starting and o.cancel_requested:
            raise Error(
                FINAL, "morca: run ", self.run, " was cancelled; stopping"
            )

    def start_attempt(
        mut self,
        step: String,
        partition: String,
        ord: Int,
        input: Span[UInt8, _],
    ) raises -> Int:
        var r = Backoff("SQLite")
        var hex_input = to_hex(input)
        while True:
            try:
                return self._start_attempt(step, partition, ord, hex_input)
            except e:
                r.again(e)
                self._reopen()

    def _start_attempt(
        mut self, step: String, partition: String, ord: Int, input: String
    ) raises -> Int:
        self.db.execute("BEGIN IMMEDIATE")
        try:
            self._still_owner(starting=True)
            var id = sql.start(self.db, self.run, step, partition, ord, input)
            var n = sql.next_attempt(self.db, id)
            var attempt_id = sql.add_attempt(
                self.db, id, n, self.owner, self.registry_hash
            )
            self.db.execute("COMMIT")
            self._attempt_id = attempt_id
            return n
        except e:
            _rollback(self.db)
            raise e^

    def finish_attempt(
        mut self,
        step: String,
        partition: String,
        attempt: Int,
        status: String,
        output: Span[UInt8, _],
        error: String,
    ) raises:
        # Retried whole: it sets the attempt's and the step's rows, so
        # doing it twice leaves what doing it once does.
        var r = Backoff("SQLite")
        var hex_output = to_hex(output)
        while True:
            try:
                self._finish_attempt(
                    step, partition, attempt, status, hex_output, error
                )
                return
            except e:
                r.again(e)
                self._reopen()

    def _finish_attempt(
        mut self,
        step: String,
        partition: String,
        attempt: Int,
        status: String,
        output: String,
        error: String,
    ) raises:
        self.db.execute("BEGIN IMMEDIATE")
        try:
            self._still_owner(starting=False)
            var id = sql.step_id(self.db, self.run, step, partition)
            sql.finish_attempt(self.db, id, attempt, status, error)
            sql.finish(self.db, id, status, output, status == SUCCEEDED, error)
            self.db.execute("COMMIT")
        except e:
            _rollback(self.db)
            raise e^

    def skip(
        mut self, step: String, partition: String, ord: Int, reason: String
    ) raises:
        var r = Backoff("SQLite")
        while True:
            try:
                self._skip(step, partition, ord, reason)
                return
            except e:
                r.again(e)
                self._reopen()

    def _skip(
        mut self, step: String, partition: String, ord: Int, reason: String
    ) raises:
        self.db.execute("BEGIN IMMEDIATE")
        try:
            self._still_owner(starting=True)
            sql.skip(self.db, self.run, step, partition, ord, reason)
            self.db.execute("COMMIT")
        except e:
            _rollback(self.db)
            raise e^

    def run_token(mut self) raises -> String:
        return sql.token(self.db, self.run)

    def pinned_reads(
        mut self, step: String, partition: String
    ) raises -> Dict[String, Int64]:
        var r = Backoff("SQLite")
        while True:
            try:
                return sql.pinned_reads(self.db, self.run, step, partition)
            except e:
                r.again(e)
                self._reopen()

    def record(mut self, commit: Bool, t: TableSnapshot) raises:
        # Not owner-checked, as on Postgres: what an attempt read or
        # committed is so even if the run was lost meanwhile.
        var r = Backoff("SQLite")
        while True:
            try:
                sql.record(
                    self.db,
                    commit,
                    self._attempt_id,
                    t.table,
                    t.snapshot_id,
                    t.dataset,
                )
                return
            except e:
                r.again(e)
                self._reopen()

    def fence(mut self) raises:
        # As on Postgres: the owner, and a heartbeat younger than half the
        # stale limit; a file that stays locked or unreadable is waited for
        # while the heartbeat could still be fresh, then the commit is off.
        var stale: Float64
        try:
            stale = Float64(getenv("MORCA_STALE_SECONDS", "30"))
        except:
            stale = 30.0
        var r = Backoff("SQLite")
        r.budget = stale / 2
        while True:
            try:
                var got = sql.fence(self.db, self.run, stale / 2)
                if not got:
                    raise Error(
                        "morca: not committing: run ", self.run, " is gone"
                    )
                var owner = got.value().owner
                var status = got.value().status
                var fresh = got.value().fresh
                if owner != self.owner or status != RUNNING:
                    raise Error(
                        "morca: not committing: run ",
                        self.run,
                        " is ",
                        status,
                        " and held by ",
                        owner if owner else "nobody",
                        ", not this process (",
                        self.owner,
                        ")",
                    )
                if not fresh:
                    raise Error(
                        "morca: not committing: run ",
                        self.run,
                        "'s heartbeat is older than ",
                        stale / 2,
                        " s, so another process may take it over",
                    )
                return
            except e:
                if String(e).startswith("morca: not committing"):
                    raise e^
                try:
                    r.again(e)
                except e2:
                    raise Error("morca: not committing: ", e2)
                self._reopen()

    def set_log(
        mut self, step: String, partition: String, attempt: Int, path: String
    ) raises:
        var r = Backoff("SQLite")
        while True:
            try:
                sql.set_log(self.db, self._attempt_id, path)
                return
            except e:
                r.again(e)
                self._reopen()
