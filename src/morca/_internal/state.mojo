"""morca's state in Postgres: pipelines, runs, steps and attempts.

Everything lives in the `morca` schema, which `State.migrate` creates and
brings up to date; migrations are SQL in `_migrations`, applied in order
under a transaction-scoped advisory lock, so two processes starting at once
don't both apply one.

**One writer per run.** The process running a run is its `owner` and keeps
`runs.heartbeat` fresh from a thread (`morca._internal.heartbeat`). `State.claim` takes
a run only if its heartbeat is older than the stale limit, or cleared, which
`finish_run` does when a run ends. Every attempt checks in the same
transaction that this process still owns the run, so a process that lost its
run to a resume stops at its next step instead of racing it. The same check
stops a run that was asked to cancel (`runs.cancel_requested`, which `morca
ui` sets) before its next attempt; an attempt already going finishes and is
recorded.

**Each change is one transaction.** Starting an attempt marks its step
running and inserts the attempt; finishing it records the output or the
error on both. A process killed in between leaves an attempt `running`,
which `interrupt` marks failed when the run is resumed.
"""

from std.ffi import external_call
from std.os import getenv
from std.sys import stderr

from postgres import Connection, Transaction

import morca._internal.db.runs as runs_db
import morca._internal.db.schema as schema_db
import morca._internal.db.steps as steps_db
from morca._internal.heartbeat import Beater, Heartbeat
from morca._internal.migrations import (
    _migrations,
    migration_floor,
    known_migrations,
    schema_ahead,
)
from morca._internal.db.live import stale_limit
from morca._internal.db.pipelines import set_version
from morca._internal.db.schedulers import live_older
from morca._internal.handover import run_outdated, set_outdated
from morca._internal.store import (
    CANCELLED,
    DEFERRED,
    FINAL,
    FAILED,
    INTERRUPTED,
    Backoff,
    RUNNING,
    SKIPPED,
    SUCCEEDED,
    RunResult,
    RunStore,
    status_list,
    StepRun,
    TableSnapshot,
    process_owner,
)
from morca._internal.db.run_rows import RunInfo, StepInfo, Usage


comptime _MIGRATION_LOCK = 0x6F726361  # "orca"


def _refuse_overlap(mut tx: Transaction, floor: Int) raises:
    """Raises if a scheduler instance that knows fewer than `floor`
    migrations is still going: migrating would raise the schema's floor
    past it, and it would go on over a schema it can't run on. Such a
    deploy stops the old scheduler first (docs/overlap.md#migrations)."""
    var old = live_older(tx, floor)
    if len(old) == 0:
        return
    raise Error(
        "morca: this binary's migrations need a binary that knows at least ",
        floor,
        ", and scheduler instance ",
        old[0][0],
        " on ",
        old[0][1],
        " knows ",
        old[0][2],
        " and is still going; stop it, and wait for its runs, before",
        " deploying this one (docs/overlap.md#migrations)",
    )


struct State(Movable):
    """A connection to morca's database."""

    var conn: Connection

    def __init__(out self, url: String) raises:
        if url.startswith("sqlite:"):
            raise Error(
                "morca: MORCA_DATABASE_URL is a SQLite file, which only a",
                " pipeline binary's run, resume and status take; the",
                " scheduler, the UI and morca's other commands need Postgres",
            )
        self.conn = Connection(url)

    def migrate(mut self) raises:
        """Creates the schema, or applies the migrations it hasn't had."""
        var tx = self.conn.begin()
        schema_db.quiet(tx)
        schema_db.lock(tx, _MIGRATION_LOCK)
        schema_db.ensure(tx)
        var migrations = _migrations()
        var known = known_migrations()
        for v in schema_db.unfloored(tx, known):
            schema_db.set_floor(tx, v, migration_floor(v))
        var have: Int
        var floor: Int
        have, floor = schema_db.current(tx)
        var raises_to = migration_floor(known)
        if have < known and raises_to > floor:
            _refuse_overlap(tx, raises_to)
        if schema_ahead(have, floor, known):
            print(
                "morca: the database is at schema version ",
                have,
                ", ahead of this binary's ",
                known,
                "; its migrations since are additive, so running on it",
                sep="",
                file=stderr,
            )
            tx.commit()
            return
        for v in range(have, known):
            for stmt in migrations[v]:
                _ = tx.execute(stmt)
            schema_db.applied(tx, v + 1, migration_floor(v + 1))
        tx.commit()

    def register(
        mut self, pipeline: String, registry_hash: String, describe: String
    ) raises:
        """Records a pipeline, or updates it to this binary's DAG."""
        runs_db.register(self.conn, pipeline, registry_hash, describe)
        set_version(
            self.conn,
            pipeline,
            self.version(
                pipeline, registry_hash, describe, getenv("MORCA_IMAGE")
            ),
        )

    def scheduled_hash(mut self, pipeline: String) raises -> String:
        """The registry hash `morca register` gave `pipeline`, or empty if it
        wasn't registered with a binary."""
        return runs_db.scheduled_hash(self.conn, pipeline)

    def version(
        mut self,
        pipeline: String,
        registry_hash: String,
        describe: String,
        image: String,
    ) raises -> Int:
        """The version of `pipeline` that code `registry_hash`, from the
        source `describe` (a pipeline binary's) names, in `image` is;
        recorded the first time it's seen."""
        return runs_db.version(
            self.conn, pipeline, registry_hash, describe, image
        )

    def ran_version(mut self, run: Int, version: Int) raises:
        """Records that `run` is running `version`'s code."""
        runs_db.ran_version(self.conn, run, version)

    def create_run(
        mut self,
        pipeline: String,
        registry_hash: String,
        partitions: String,
        trigger: String,
        owner: String,
    ) raises -> Int:
        """A new run, already claimed by `owner`."""
        return runs_db.create(
            self.conn, pipeline, registry_hash, partitions, trigger, owner
        )

    def run_info(mut self, run: Int) raises -> RunInfo:
        var got = runs_db.info(self.conn, run)
        if not got:
            raise Error("morca: no run ", run)
        return got.take()

    def claim(mut self, run: Int, owner: String, stale_seconds: Float64) raises:
        """Makes `owner` the run's writer, if no live process holds it.

        A run can be claimed while it's `queued`, unfinished (`running` with
        a stale or cleared heartbeat; the scheduler starts a run with none)
        or `failed`. Raises otherwise, saying why.
        """
        if runs_db.claim(self.conn, run, owner, stale_seconds):
            return
        var info = self.run_info(run)
        if (
            info.status != RUNNING
            and info.status != FAILED
            and info.status != "queued"
            and info.status != DEFERRED
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

    def interrupt(mut self, run: Int, why: String = "") raises -> Int:
        """Marks attempts left `running` by a process that died as failed,
        and returns how many there were. `why` is their error and their
        steps', such as a crash's (`morca._internal.crash`); empty, it's
        `INTERRUPTED`."""
        var tx = self.conn.begin()
        var n = steps_db.fail_running_attempts(
            tx, run, why if why else INTERRUPTED
        )
        steps_db.fail_running_steps(
            tx, run, why if why else String("interrupted")
        )
        tx.commit()
        return n

    def prior(mut self, run: Int) raises -> RunResult:
        """The run's succeeded steps, with their outputs, for resuming it."""
        var res = RunResult()
        for r in steps_db.succeeded(self.conn, run):
            res.steps.append(
                StepRun(r.step, r.partition, SUCCEEDED, r.output.copy(), "")
            )
        return res^

    def finish_run(mut self, run: Int, owner: String, status: String) raises:
        """Ends the run and clears its heartbeat, so it can be resumed at
        once if it failed."""
        runs_db.finish(self.conn, run, owner, status)

    def defer_run(mut self, run: Int, owner: String, until: Int64) raises:
        """Ends the run `deferred`, to be started again at `until` (on the
        scheduler's clock) by the scheduler, whatever started it; that start
        isn't counted against its retries."""
        runs_db.defer_run(self.conn, run, owner, until)

    def cancel_requested(mut self, run: Int) raises -> Bool:
        return runs_db.cancel_requested(self.conn, run)

    def runs(
        mut self, limit: Int = 20, before: Int = 0, status: String = ""
    ) raises -> List[RunInfo]:
        """The latest runs, newest first; those under `before` if it isn't
        0, and with `status` (one or several, comma-separated) one of
        those."""
        return runs_db.latest(
            self.conn, limit, before, String(",").join(status_list(status))
        )

    def steps(mut self, run: Int) raises -> List[StepInfo]:
        """A run's steps in run order, with their attempt counts."""
        return steps_db.of_run(self.conn, run)


struct DbRetry(Movable):
    """Retries of one call to Postgres from a run's process: `Backoff`,
    then a new connection, so a restart or failover of the server doesn't
    stop the run."""

    var backoff: Backoff

    def __init__(out self):
        self.backoff = Backoff("Postgres")

    def again(mut self, e: Error, mut db: State, url: String) raises:
        self.backoff.again(e)
        try:
            db = State(url)
        except:
            pass  # the next try fails too, and comes back here


def _stop(
    mut conn: Connection, run: Int, owner: String, timeouts: String
) raises -> String:
    """Ends the run as the watchdog finds it should end, and returns why,
    or empty if it shouldn't: a cancel whose time has come, or an attempt
    past its step's timeout (`morca._internal.db.runs.stop_reason`)."""
    var got = runs_db.stop_reason(conn, run, owner, timeouts)
    if not got:
        return ""
    var r = got.take()
    var tx = conn.begin()
    var why: String
    if r.why == "timeout":
        var step = r.step
        if r.partition:
            step.write(" ", r.partition)
        why = String(
            "timed out after ",
            Int(r.secs),
            " s (timeout_seconds), so its process was stopped",
        )
        if not steps_db.fail_attempt(tx, r.attempt, why):
            tx.rollback()
            return ""  # it ended as we looked
        why = String("step ", step, " ", why)
        runs_db.fail(tx, run, owner, why)
    else:
        why = String(
            "cancelled: its step hadn't finished when the cancel's",
            " MORCA_CANCEL_KILL_SECONDS ran out, so its process was stopped",
        )
        _ = steps_db.fail_running_attempts(tx, run, why)
        steps_db.fail_running_steps(tx, run, why)
        runs_db.cancel(tx, run, owner)
    runs_db.audit_stop(tx, run, String(owner, ": ", why))
    tx.commit()
    return why^


def beat_run(
    mut conn: Connection, run: Int, owner: String, timeouts: String
) raises -> String:
    """One beat of `run`'s heartbeat as `owner`, and the watchdog's look at
    it (`morca._internal.heartbeat`): why the run's process must stop now, a cancel
    whose time has come or an attempt past its step's timeout, which is
    then recorded, or empty. `PgBeat`'s, and `morca ui`'s for a worker's run
    (`orca.workers`), whose process then stops itself."""
    runs_db.beat(conn, run, owner)
    return _stop(conn, run, owner, timeouts)


struct PgBeat(Beater):
    """Refreshes a run's heartbeat in Postgres, on a connection of its own,
    and asks whether the run is outdated (`morca.outdated`)."""

    var url: String
    var run: Int
    var owner: String
    var timeouts: String
    """`step=seconds` for each step with a timeout, comma-separated."""
    var _conn: Optional[Connection]

    def __init__(
        out self, url: String, run: Int, owner: String, timeouts: String = ""
    ):
        self.url = url
        self.run = run
        self.owner = owner
        self.timeouts = timeouts
        self._conn = None

    def beat(mut self) raises:
        if not self._conn:
            self._conn = Connection(self.url)
        var why = beat_run(
            self._conn.value(), self.run, self.owner, self.timeouts
        )
        if why:
            print("run", self.run, why, flush=True)
            external_call["_exit", NoneType](Int32(1))
        # Whether a newer version leads, for `morca.outdated()` (#397). Not
        # knowing leaves the last answer; it never stops the beat.
        try:
            var o = run_outdated(self._conn.value(), self.run)
            set_outdated(o.outdated, o.mine, o.desired, o.why)
        except:
            pass

    def reset(mut self):
        self._conn = None


struct PgStore(Movable, RunStore):
    """morca's runs in Postgres, `State` behind the `RunStore` trait.

    The calls for the owned run (attempts, skips, reads and commits, its
    end) are retried for `MORCA_DB_RETRY_SECONDS` on a new connection
    (`DbRetry`), except when the run was lost or cancelled, so a blip of
    the server doesn't throw away a step that finished. The others are made
    once, before the run starts or after it ends."""

    var db: State
    var url: String
    var run: Int
    var owner: String
    var registry_hash: String
    var _attempt_id: Int64
    """The `attempts` row of the attempt last started."""
    var _heartbeat: Optional[Heartbeat[PgBeat]]

    def __init__(out self, url: String) raises:
        """Connects to `url`; `own` a run before recording attempts."""
        self.db = State(url)
        self.url = url
        self.run = 0
        self.owner = String()
        self.registry_hash = String()
        self._attempt_id = 0
        self._heartbeat = None

    def __init__(
        out self,
        var db: State,
        url: String,
        run: Int,
        owner: String,
        registry_hash: String,
    ):
        """Over `db`, already owning `run`."""
        self.db = db^
        self.url = url
        self.run = run
        self.owner = owner
        self.registry_hash = registry_hash
        self._attempt_id = 0
        self._heartbeat = None

    # --- RunStore: State's calls, for the pipeline binary ---

    def migrate(mut self) raises:
        self.db.migrate()

    def register(
        mut self, pipeline: String, registry_hash: String, describe: String
    ) raises:
        self.db.register(pipeline, registry_hash, describe)

    def scheduled_hash(mut self, pipeline: String) raises -> String:
        return self.db.scheduled_hash(pipeline)

    def version(
        mut self,
        pipeline: String,
        registry_hash: String,
        describe: String,
        image: String,
    ) raises -> Int:
        return self.db.version(pipeline, registry_hash, describe, image)

    def create_run(
        mut self,
        pipeline: String,
        registry_hash: String,
        partitions: String,
        trigger: String,
        owner: String,
    ) raises -> Int:
        return self.db.create_run(
            pipeline, registry_hash, partitions, trigger, owner
        )

    def claim(mut self, run: Int, owner: String, stale_seconds: Float64) raises:
        self.db.claim(run, owner, stale_seconds)

    def ran_version(mut self, run: Int, version: Int) raises:
        self.db.ran_version(run, version)

    def interrupt(mut self, run: Int, why: String = "") raises -> Int:
        return self.db.interrupt(run, why)

    def prior(mut self, run: Int) raises -> RunResult:
        return self.db.prior(run)

    def run_info(mut self, run: Int) raises -> RunInfo:
        return self.db.run_info(run)

    def runs(
        mut self, limit: Int, before: Int = 0, status: String = ""
    ) raises -> List[RunInfo]:
        return self.db.runs(limit, before, status)

    def steps(mut self, run: Int) raises -> List[StepInfo]:
        return self.db.steps(run)

    def own(mut self, run: Int, owner: String, registry_hash: String) raises:
        self.run = run
        self.owner = owner
        self.registry_hash = registry_hash

    def attempt_id(self) -> Int64:
        """The `attempts` row of the attempt last started: what a worker's
        run is told, to name it in its later calls (`orca.workers`)."""
        return self._attempt_id

    def at_attempt(mut self, id: Int64):
        """Points `record` and `set_log` at the `attempts` row `id`."""
        self._attempt_id = id

    def start_attempt_once(
        mut self,
        step: String,
        partition: String,
        ord: Int,
        input: Span[UInt8, _],
    ) raises -> Int:
        """`start_attempt` without its retries, its errors as they are
        (`FINAL` for a lost or cancelled run): for `morca ui`, whose worker
        retries the call itself (`morca._internal.http_store`)."""
        return self._start_attempt(step, partition, ord, input)

    def finish_attempt_once(
        mut self,
        step: String,
        partition: String,
        attempt: Int,
        status: String,
        output: Span[UInt8, _],
        error: String,
    ) raises:
        """`finish_attempt` without its retries, as `start_attempt_once`."""
        self._finish_attempt(step, partition, attempt, status, output, error)

    def skip_once(
        mut self, step: String, partition: String, ord: Int, reason: String
    ) raises:
        """`skip` without its retries, as `start_attempt_once`."""
        self._skip(step, partition, ord, reason)

    def start_heartbeat(
        mut self, interval: Float64, timeouts: String = ""
    ) raises:
        self._heartbeat = Heartbeat(
            PgBeat(self.url, self.run, self.owner, timeouts), interval
        )

    def stop_heartbeat(mut self):
        self._heartbeat = None

    # --- Store: the owned run's attempts ---

    @staticmethod
    def _still_owner(
        mut tx: Transaction, run: Int, owner: String, starting: Bool
    ) raises:
        """Raises unless this process still owns the run, or, when a step is
        `starting`, if the run was asked to cancel."""
        var o = runs_db.still_owner(tx, run, owner)
        if not o.owned:
            raise Error(
                FINAL, "morca: lost run ", run, " to another process; stopping"
            )
        if starting and o.cancel_requested:
            raise Error(FINAL, "morca: run ", run, " was cancelled; stopping")

    def start_attempt(
        mut self,
        step: String,
        partition: String,
        ord: Int,
        input: Span[UInt8, _],
    ) raises -> Int:
        var r = DbRetry()
        while True:
            try:
                return self._start_attempt(step, partition, ord, input)
            except e:
                r.again(e, self.db, self.url)

    def _start_attempt(
        mut self,
        step: String,
        partition: String,
        ord: Int,
        input: Span[UInt8, _],
    ) raises -> Int:
        var tx = self.db.conn.begin()
        Self._still_owner(tx, self.run, self.owner, starting=True)
        var id = steps_db.start(tx, self.run, step, partition, ord, input)
        var n = steps_db.next_attempt(tx, id)
        self._attempt_id = steps_db.add_attempt(
            tx, id, n, self.owner, self.registry_hash
        )
        tx.commit()
        return Int(n)

    def pinned_reads(
        mut self, step: String, partition: String
    ) raises -> Dict[String, Int64]:
        var r = DbRetry()
        while True:
            try:
                return self._pinned_reads(step, partition)
            except e:
                r.again(e, self.db, self.url)

    def run_token(mut self) raises -> String:
        var r = DbRetry()
        while True:
            try:
                return runs_db.token(self.db.conn, self.run)
            except e:
                r.again(e, self.db, self.url)

    def _pinned_reads(
        mut self, step: String, partition: String
    ) raises -> Dict[String, Int64]:
        return steps_db.pinned_reads(self.db.conn, self.run, step, partition)

    def record(mut self, commit: Bool, t: TableSnapshot) raises:
        # Not owner-checked: what an attempt read or committed is so even
        # if the run was lost meanwhile, and a commit must stay on record.
        var r = DbRetry()
        while True:
            try:
                steps_db.record(
                    self.db.conn,
                    commit,
                    self._attempt_id,
                    t.table,
                    t.snapshot_id,
                    t.dataset,
                )
                return
            except e:
                r.again(e, self.db, self.url)

    def fence(mut self) raises:
        # On the store's connection; an unreachable database is waited for
        # while the heartbeat could still be fresh, then the commit is off.
        var stale: Float64
        try:
            stale = Float64(getenv("MORCA_STALE_SECONDS", "30"))
        except:
            stale = 30.0
        var r = DbRetry()
        r.backoff.budget = stale / 2
        while True:
            try:
                var row = runs_db.fence(self.db.conn, self.run, stale / 2)
                if row.owner != self.owner or row.status != RUNNING:
                    raise Error(
                        "morca: not committing: run ",
                        self.run,
                        " is ",
                        row.status,
                        " and held by ",
                        row.owner if row.owner else "nobody",
                        ", not this process (",
                        self.owner,
                        ")",
                    )
                if not row.fresh:
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
                    r.again(e, self.db, self.url)
                except e2:
                    raise Error("morca: not committing: ", e2)

    def set_log(
        mut self, step: String, partition: String, attempt: Int, path: String
    ) raises:
        var r = DbRetry()
        while True:
            try:
                steps_db.set_log(self.db.conn, self._attempt_id, path)
                return
            except e:
                r.again(e, self.db, self.url)

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
        var r = DbRetry()
        while True:
            try:
                self._finish_attempt(
                    step, partition, attempt, status, output, error
                )
                return
            except e:
                r.again(e, self.db, self.url)

    def _finish_attempt(
        mut self,
        step: String,
        partition: String,
        attempt: Int,
        status: String,
        output: Span[UInt8, _],
        error: String,
    ) raises:
        var tx = self.db.conn.begin()
        Self._still_owner(tx, self.run, self.owner, starting=False)
        var id = steps_db.step_id(tx, self.run, step, partition)
        steps_db.finish_attempt(tx, id, attempt, status, error)
        steps_db.finish(tx, id, status, output, status == SUCCEEDED, error)
        tx.commit()

    def skip(
        mut self, step: String, partition: String, ord: Int, reason: String
    ) raises:
        var r = DbRetry()
        while True:
            try:
                self._skip(step, partition, ord, reason)
                return
            except e:
                r.again(e, self.db, self.url)

    def finish_run(mut self, status: String) raises:
        """`State.finish_run` for this run, retried as the attempts are."""
        var r = DbRetry()
        while True:
            try:
                self.db.finish_run(self.run, self.owner, status)
                return
            except e:
                r.again(e, self.db, self.url)

    def defer_run(mut self, until: Int64) raises:
        """`State.defer_run` for this run, retried as the attempts are."""
        var r = DbRetry()
        while True:
            try:
                self.db.defer_run(self.run, self.owner, until)
                return
            except e:
                r.again(e, self.db, self.url)

    def cancel_requested(mut self) raises -> Bool:
        var r = DbRetry()
        while True:
            try:
                return self.db.cancel_requested(self.run)
            except e:
                r.again(e, self.db, self.url)

    def _skip(
        mut self, step: String, partition: String, ord: Int, reason: String
    ) raises:
        var tx = self.db.conn.begin()
        Self._still_owner(tx, self.run, self.owner, starting=True)
        steps_db.skip(tx, self.run, step, partition, ord, reason)
        tx.commit()
