"""Where the executor records what it does.

`Pipeline.execute` reports every attempt it starts and finishes, and every
step it skips, to a `Store`; a step's reads and commits reach the same store
through the `Recorder` its `Ctx` holds. `MemoryStore` keeps them in the
process, for a run that lives as long as it does; `morca._internal.state.PgStore`
writes them to Postgres, so a run can be resumed by another process.

`RunStore` is a `Store` that also keeps runs: the rest of what a pipeline
binary (`morca._cli`) asks of persistence, from registering the pipeline to
ending its run, so the binary depends on this trait and nothing else.
Both backends' SQL is in `morca._internal.db` (`morca._internal.db.runs`, `morca._internal.db.steps`,
`morca._internal.db.sqlite_runs`), as is the scheduler's and the UI's.
"""

from std.ffi import external_call
from std.os import getenv
from std.time import perf_counter_ns, sleep

from dista.codec import decode

from morca._internal.db.run_rows import RunInfo, StepInfo, Usage

comptime RUNNING = "running"
comptime CANCELLED = "cancelled"


comptime SUCCEEDED = "succeeded"
comptime FAILED = "failed"
comptime SKIPPED = "skipped"
comptime DEFERRED = "deferred"
"""A step that raised `defer`: not done, and not failed."""
comptime INTERRUPTED = "interrupted: the process running it stopped"
"""The error of an attempt whose process died without saying why."""


struct StepRun(Copyable, Movable):
    """One step for one partition (or for the run, for a gather step)."""

    var step: String
    var partition: String
    """Empty for a gather step."""
    var status: String
    var output: List[UInt8]
    """The encoded output, when the step succeeded."""
    var error: String
    var attempt: Int
    """The number of the attempt that settled it; 0 for a skipped step."""
    var until: Int64
    """When a deferred step may run again, on `morca.civil.now`'s clock."""

    def __init__(
        out self,
        step: String,
        partition: String,
        status: String,
        var output: List[UInt8],
        error: String,
        attempt: Int = 0,
        until: Int64 = 0,
    ):
        self.step = step
        self.partition = partition
        self.status = status
        self.output = output^
        self.error = error
        self.attempt = attempt
        self.until = until


struct RunResult(Movable):
    """What a run did: every step and partition, in the order they ran."""

    var steps: List[StepRun]

    def __init__(out self):
        self.steps = List[StepRun]()

    def succeeded(self) -> Bool:
        for i in range(len(self.steps)):
            if self.steps[i].status != SUCCEEDED:
                return False
        return True

    def deferred_until(self) -> Int64:
        """When the run may go on, if a step deferred and none failed: the
        latest time its deferred steps asked for. 0 otherwise."""
        var until = Int64(0)
        for i in range(len(self.steps)):
            ref s = self.steps[i]
            if s.status == FAILED:
                return 0
            if s.status == DEFERRED:
                until = max(until, s.until)
        return until

    def outcome(self) -> String:
        """`succeeded`, `deferred` or `failed`."""
        if self.succeeded():
            return SUCCEEDED
        return DEFERRED if self.deferred_until() > 0 else FAILED

    def find(self, step: StringSpan, partition: StringSpan) -> Int:
        """The index of `step` for `partition`, or -1."""
        for i in range(len(self.steps)):
            ref s = self.steps[i]
            if s.step == step and s.partition == partition:
                return i
        return -1

    def status(self, step: StringSpan, partition: StringSpan) raises -> String:
        var i = self.find(step, partition)
        if i < 0:
            raise Error("no step ", step, " for '", partition, "'")
        return self.steps[i].status

    def output[
        T: Movable
    ](self, step: StringSpan, partition: StringSpan = "") raises -> T:
        """The decoded output of `step` for `partition`."""
        var i = self.find(step, partition)
        if i < 0:
            raise Error("no step ", step, " for '", partition, "'")
        ref s = self.steps[i]
        if s.status != SUCCEEDED:
            raise Error("step ", step, " for '", partition, "' ", s.status)
        var pos = 0
        return decode[T](Span(s.output), pos)


comptime FINAL = "\x1f"
"""Starts the message of an error a retry can't help: the run was lost to
another process, or cancelled. `Backoff` raises it at once, without it."""


def db_retry_seconds() -> Float64:
    """`MORCA_DB_RETRY_SECONDS`: how long a run's process keeps retrying a
    write to its store that failed, by default the stale limit
    (`MORCA_STALE_SECONDS`, 30), past which another process may take the run
    over anyway."""
    try:
        return Float64(
            getenv(
                "MORCA_DB_RETRY_SECONDS", getenv("MORCA_STALE_SECONDS", "30")
            )
        )
    except:
        return 30.0


struct Backoff(Movable):
    """The waits between retries of one write to a store.

    `again(e)` is called with what the write raised: it raises again if the
    error is final (`FINAL`) or the time (`db_retry_seconds`) is up, else
    it waits, a quarter of a second doubling to 4 s; the store then
    reconnects and tries again."""

    var what: String
    """The store, for the message: `Postgres`, `SQLite`."""
    var started: Int
    var wait: Float64
    var budget: Float64

    def __init__(out self, what: String):
        self.what = what
        self.started = Int(perf_counter_ns())
        self.wait = 0.25
        self.budget = db_retry_seconds()

    def again(mut self, e: Error) raises:
        var msg = String(e)
        if msg.startswith(FINAL):
            raise Error(String(msg[byte = FINAL.byte_length() :]))
        var spent = Float64(Int(perf_counter_ns()) - self.started) / 1e9
        if spent + self.wait > self.budget:
            raise Error(msg)
        print(
            "morca: ",
            self.what,
            " failed (",
            msg,
            "); retrying in ",
            self.wait,
            " s",
            sep="",
        )
        sleep(self.wait)
        self.wait = min(self.wait * 2, 4.0)


def process_owner() -> String:
    """`host:pid`, naming this process as a run's owner."""
    var buf = List[UInt8](length=256, fill=0)
    _ = external_call["gethostname", Int32](buf.unsafe_ptr(), Int(255))
    var n = 0
    while n < 255 and buf[n] != 0:
        n += 1
    var host = String(from_utf8_lossy=Span(buf)[:n])
    return String(host, ":", external_call["getpid", Int32]())


@fieldwise_init
struct TableSnapshot(Copyable, Movable):
    """A table, by its location, at a snapshot."""

    var table: String
    var snapshot_id: Int64
    """-1 for a table that had no snapshot yet."""
    var dataset: String
    """The table's dataset name, `namespace.table`, or empty for a table
    outside the warehouse."""


def _record_nothing(store: Int, commit: Bool, t: TableSnapshot) raises:
    pass


def _record_in[S: Store](store: Int, commit: Bool, t: TableSnapshot) raises:
    Pointer[S, MutAnyOrigin](unsafe_from_address=store)[].record(commit, t)


def _fence_nothing(store: Int) raises:
    pass


def _fence_in[S: Store](store: Int) raises:
    Pointer[S, MutAnyOrigin](unsafe_from_address=store)[].fence()


struct Recorder(Movable):
    """Records an attempt's reads and commits in the store it came from, as
    they happen, so a process killed right after a commit still leaves it on
    record.

    It holds the store by address, as `Ctx` holds the run's dista runtime:
    `Ctx` isn't generic over the store, and the store outlives every `Ctx`
    `Pipeline.execute` makes from it."""

    var _store: Int
    """The store's address; 0 when nothing is recorded."""
    var _record: def(Int, Bool, TableSnapshot) raises thin -> None
    var _fence: def(Int) raises thin -> None

    def __init__(out self):
        """A recorder that records nothing."""
        self._store = 0
        self._record = _record_nothing
        self._fence = _fence_nothing

    def __init__[S: Store](out self, mut store: S):
        """A recorder that records in `store`."""
        self._store = Int(Pointer(to=store))
        self._record = _record_in[S]
        self._fence = _fence_in[S]

    def fence(mut self) raises:
        """Raises unless this process may still commit for its run: what
        `morca.tables` checks right before each commit (`Store.fence`)."""
        self._fence(self._store)

    def read(mut self, t: TableSnapshot) raises:
        self._record(self._store, False, t)

    def commit(mut self, t: TableSnapshot) raises:
        self._record(self._store, True, t)


trait Store:
    def start_attempt(
        mut self,
        step: String,
        partition: String,
        ord: Int,
        input: Span[UInt8, _],
    ) raises -> Int:
        """Records that `step` for `partition` is starting, with its encoded
        input, and returns the attempt's number (1 for the first). `ord` is the
        step's place in the run order."""
        ...

    def finish_attempt(
        mut self,
        step: String,
        partition: String,
        attempt: Int,
        status: String,
        output: Span[UInt8, _],
        error: String,
    ) raises:
        """Records how attempt `attempt` ended: `succeeded` with its encoded
        output, or `failed` with its error."""
        ...

    def skip(
        mut self, step: String, partition: String, ord: Int, reason: String
    ) raises:
        """Records that `step` for `partition` didn't run, and why."""
        ...

    def pinned_reads(
        mut self, step: String, partition: String
    ) raises -> Dict[String, Int64]:
        """The table snapshots earlier attempts of `step` for `partition`
        read, each table at its first attempt's snapshot."""
        ...

    def run_token(mut self) raises -> String:
        """The run's random token, made with the run and the same for all
        its attempts, which goes into the summaries of the snapshots it
        commits (`Ctx.token`); empty for a run without one: an in-memory
        run, or one created before tokens."""
        return String()

    def record(mut self, commit: Bool, t: TableSnapshot) raises:
        """Records that the attempt last started read `t` (or, if `commit`,
        committed it). What a `Recorder` from this store calls."""
        ...

    def fence(mut self) raises:
        """Raises unless this process still owns the run, with a heartbeat
        younger than half of `MORCA_STALE_SECONDS`, so no other process can
        have claimed it nor claim it during a commit: what a commit to
        Iceberg checks right before it's made (`morca.ctx`). Its message
        starts `morca: not committing`."""
        ...

    def recorder(mut self) raises -> Recorder:
        """What records the reads and commits of the attempt just started."""
        return Recorder(self)

    def set_log(
        mut self, step: String, partition: String, attempt: Int, path: String
    ) raises:
        """Records where attempt `attempt` writes its log."""
        ...


trait RunStore(Store):
    """A `Store` that keeps runs too: everything a pipeline binary records.

    One process is a run's writer, its owner (`process_owner`): it creates
    or claims the run, `own`s it, which points the `Store` methods at it,
    keeps its heartbeat fresh, and ends it with `finish_run`. A store that
    other processes share stops an owner that lost its run, or whose run was
    asked to cancel, at its next attempt."""

    def migrate(mut self) raises:
        """Creates the store's schema, or brings it up to date."""
        ...

    def register(
        mut self, pipeline: String, registry_hash: String, describe: String
    ) raises:
        """Records a pipeline, or updates it to this binary's DAG."""
        ...

    def scheduled_hash(mut self, pipeline: String) raises -> String:
        """The registry hash `morca register` gave `pipeline`, or empty if it
        wasn't registered with a binary."""
        ...

    def version(
        mut self,
        pipeline: String,
        registry_hash: String,
        describe: String,
        image: String,
    ) raises -> Int:
        """The version of `pipeline` that code `registry_hash`, from the
        source `describe` names, in `image` is; recorded the first time."""
        ...

    def create_run(
        mut self,
        pipeline: String,
        registry_hash: String,
        partitions: String,
        trigger: String,
        owner: String,
    ) raises -> Int:
        """A new run, already claimed by `owner`."""
        ...

    def claim(mut self, run: Int, owner: String, stale_seconds: Float64) raises:
        """Makes `owner` the run's writer if no live process holds it: the
        run is `queued`, `failed`, `deferred`, or `running` with a heartbeat
        older than `stale_seconds` or cleared. Raises otherwise, saying
        why."""
        ...

    def ran_version(mut self, run: Int, version: Int) raises:
        """Records that `run` is running `version`'s code."""
        ...

    def interrupt(mut self, run: Int, why: String = "") raises -> Int:
        """Marks attempts left `running` by a process that died as failed,
        and returns how many there were. `why` is their error and their
        steps', such as a crash's (`morca._internal.crash`); empty, it's `interrupted:
        the process running it stopped`."""
        ...

    def prior(mut self, run: Int) raises -> RunResult:
        """The run's succeeded steps, with their outputs, for resuming it."""
        ...

    def run_info(mut self, run: Int) raises -> RunInfo:
        """The run; raises if there's no such run."""
        ...

    def runs(
        mut self, limit: Int, before: Int = 0, status: String = ""
    ) raises -> List[RunInfo]:
        """The latest `limit` runs, newest first; with `before` (unless 0),
        those older than run `before` (with ids under it, but in memory):
        the next page, keyed by the last run of the one before. With
        `status`, a status or several comma-separated, only runs with one
        of them."""
        ...

    def steps(mut self, run: Int) raises -> List[StepInfo]:
        """A run's steps in run order, with their attempt counts."""
        ...

    def own(mut self, run: Int, owner: String, registry_hash: String) raises:
        """Records this process's attempts, as `owner` with code
        `registry_hash`, against `run`, which it has created or claimed."""
        ...

    def start_heartbeat(
        mut self, interval: Float64, timeouts: String = ""
    ) raises:
        """Keeps the owned run's heartbeat fresh, every `interval` seconds,
        from a thread, until `stop_heartbeat`. The thread is also the run's
        watchdog (`morca._internal.heartbeat`): `timeouts` is `step=seconds` for each
        step with `timeout_seconds`, comma-separated
        (`Pipeline.timeouts`)."""
        ...

    def stop_heartbeat(mut self):
        """Stops the heartbeat thread, if it's going, and waits for it."""
        ...

    def finish_run(mut self, status: String) raises:
        """Ends the owned run with `status` and clears its heartbeat, so it
        can be resumed at once if it failed."""
        ...

    def defer_run(mut self, until: Int64) raises:
        """Ends the owned run `deferred`, to go on at `until` (on
        `morca.civil.now`'s clock): a step raised `defer` and none failed.
        That start isn't counted against its retries."""
        ...

    def cancel_requested(mut self) raises -> Bool:
        """Whether the owned run was asked to cancel."""
        ...


@fieldwise_init
struct _MemRun(Copyable, Movable):
    var pipeline: String
    var registry_hash: String
    var partitions: String
    var status: String
    var owner: String
    var error: String
    var heartbeat: Int
    """`perf_counter_ns` at the last beat; -1 when cleared."""
    var cancel_requested: Bool
    var version: Int


@fieldwise_init
struct _MemStep(Copyable, Movable):
    var run: Int
    var step: String
    var partition: String
    var ord: Int
    var status: String
    var input: List[UInt8]
    var output: List[UInt8]
    var error: String


@fieldwise_init
struct _MemAttempt(Copyable, Movable):
    var step: Int
    """The step's index in `MemoryStore._steps`."""
    var attempt: Int
    var status: String
    var host: String
    var registry_hash: String
    var error: String
    var log: String


@fieldwise_init
struct MemRecord(Copyable, Movable):
    """A read or commit an attempt recorded in a `MemoryStore`."""

    var attempt: Int
    """The attempt's index in the store's attempts."""
    var commit: Bool
    var table: TableSnapshot


struct MemoryStore(Movable, RunStore):
    """Keeps runs in the process's memory: what `<pipeline> run` uses
    without `MORCA_DATABASE_URL`, and `Pipeline.run`.

    The same rows `PgStore` keeps, and the same rules: a run in it can be
    interrupted, claimed by another owner and resumed, so long as the
    process lives. Its runs are numbered 0, -1, -2, ...: never positive, so
    `Ctx.made` recognises none of their commits, since another process's
    in-memory run would have the same number. Nothing beats the heartbeat:
    no other process can see the run."""

    var _pipelines: Dict[String, String]
    """Name to registry hash."""
    var _versions: List[String]
    """Version `i + 1` is the pipeline, hash, `describe` and image at `i`."""
    var _runs: List[_MemRun]
    """Run `-i` is at `i`."""
    var _steps: List[_MemStep]
    var _attempts: List[_MemAttempt]
    var records: List[MemRecord]
    """Every read and commit recorded, in order."""
    var run: Int
    var owner: String
    var registry_hash: String
    var _attempt: Int
    """The index of the attempt last started; -1 before the first."""

    def __init__(out self):
        self._pipelines = Dict[String, String]()
        self._versions = List[String]()
        self._runs = List[_MemRun]()
        self._steps = List[_MemStep]()
        self._attempts = List[_MemAttempt]()
        self.records = List[MemRecord]()
        self.run = 0
        self.owner = String()
        self.registry_hash = String()
        self._attempt = -1

    def _at(self, run: Int) raises -> Int:
        if run > 0 or -run >= len(self._runs):
            raise Error("morca: no run ", run)
        return -run

    def _step_at(self, run: Int, step: String, partition: String) -> Int:
        for i in range(len(self._steps)):
            ref s = self._steps[i]
            if s.run == run and s.step == step and s.partition == partition:
                return i
        return -1

    def _still_owner(mut self, starting: Bool) raises:
        """Raises unless this store still owns its run, or, when a step is
        `starting`, if the run was asked to cancel."""
        ref r = self._runs[self._at(self.run)]
        if r.owner != self.owner or r.status != RUNNING:
            raise Error(
                "morca: lost run ", self.run, " to another process; stopping"
            )
        if starting and r.cancel_requested:
            raise Error("morca: run ", self.run, " was cancelled; stopping")
        r.heartbeat = Int(perf_counter_ns())

    def _upsert_step(
        mut self, step: String, partition: String, ord: Int
    ) -> Int:
        var i = self._step_at(self.run, step, partition)
        if i >= 0:
            return i
        self._steps.append(
            _MemStep(
                self.run,
                step,
                partition,
                ord,
                RUNNING,
                List[UInt8](),
                List[UInt8](),
                "",
            )
        )
        return len(self._steps) - 1

    def request_cancel(mut self, run: Int) raises:
        """Asks `run` to cancel, as `morca ui` does in Postgres."""
        self._runs[self._at(run)].cancel_requested = True

    # --- RunStore ---

    def migrate(mut self) raises:
        pass

    def register(
        mut self, pipeline: String, registry_hash: String, describe: String
    ) raises:
        self._pipelines[pipeline] = registry_hash
        _ = self.version(
            pipeline, registry_hash, describe, getenv("MORCA_IMAGE")
        )

    def scheduled_hash(mut self, pipeline: String) raises -> String:
        # Only `morca register`, against a shared store, schedules a binary.
        return String()

    def version(
        mut self,
        pipeline: String,
        registry_hash: String,
        describe: String,
        image: String,
    ) raises -> Int:
        var key = String(
            pipeline, "\t", registry_hash, "\t", describe, "\t", image
        )
        for i in range(len(self._versions)):
            if self._versions[i] == key:
                return i + 1
        self._versions.append(key^)
        return len(self._versions)

    def create_run(
        mut self,
        pipeline: String,
        registry_hash: String,
        partitions: String,
        trigger: String,
        owner: String,
    ) raises -> Int:
        self._runs.append(
            _MemRun(
                pipeline,
                registry_hash,
                partitions,
                RUNNING,
                owner,
                "",
                Int(perf_counter_ns()),
                False,
                0,
            )
        )
        return -(len(self._runs) - 1)

    def claim(mut self, run: Int, owner: String, stale_seconds: Float64) raises:
        ref r = self._runs[self._at(run)]
        if (
            r.status != RUNNING
            and r.status != FAILED
            and r.status != DEFERRED
            and r.status != "queued"
        ):
            raise Error("morca: run ", run, " is ", r.status)
        var now = Int(perf_counter_ns())
        if (
            r.heartbeat >= 0
            and Float64(now - r.heartbeat) / 1e9 <= stale_seconds
        ):
            raise Error(
                "morca: run ",
                run,
                " is held by ",
                r.owner,
                ", whose heartbeat is fresher than ",
                stale_seconds,
                " s",
            )
        r.status = RUNNING
        r.owner = owner
        r.heartbeat = now
        r.error = String()

    def ran_version(mut self, run: Int, version: Int) raises:
        self._runs[self._at(run)].version = version

    def interrupt(mut self, run: Int, why: String = "") raises -> Int:
        var n = 0
        for ref a in self._attempts:
            if self._steps[a.step].run == run and a.status == RUNNING:
                a.status = FAILED
                a.error = why if why else INTERRUPTED
                n += 1
        for ref s in self._steps:
            if s.run == run and s.status == RUNNING:
                s.status = FAILED
                s.error = why if why else String("interrupted")
        return n

    def prior(mut self, run: Int) raises -> RunResult:
        var res = RunResult()
        for s in self._steps:
            if s.run == run and s.status == SUCCEEDED:
                res.steps.append(
                    StepRun(s.step, s.partition, SUCCEEDED, s.output.copy(), "")
                )
        return res^

    def run_info(mut self, run: Int) raises -> RunInfo:
        ref r = self._runs[self._at(run)]
        return RunInfo(
            run,
            r.pipeline,
            r.registry_hash,
            r.partitions,
            r.status,
            r.owner,
            r.error,
        )

    def runs(
        mut self, limit: Int, before: Int = 0, status: String = ""
    ) raises -> List[RunInfo]:
        var out = List[RunInfo]()
        var i = len(self._runs) - 1
        # Run `-i` is the i-th: under `before` once i is past -before.
        if before != 0:
            i = min(i, -before - 1)
        var wanted = status_list(status)
        while i >= 0 and len(out) < limit:
            var r = self.run_info(-i)
            if len(wanted) == 0 or r.status in wanted:
                out.append(r^)
            i -= 1
        return out^

    def steps(mut self, run: Int) raises -> List[StepInfo]:
        # In run order, then in the order they were first recorded, as
        # `ORDER BY ord, id`.
        var at = List[Int]()
        for i in range(len(self._steps)):
            if self._steps[i].run != run:
                continue
            var j = len(at)
            at.append(i)
            while j > 0 and self._steps[at[j - 1]].ord > self._steps[i].ord:
                at[j] = at[j - 1]
                j -= 1
            at[j] = i
        var out = List[StepInfo]()
        for i in at:
            ref s = self._steps[i]
            var attempts = 0
            var last = 0
            var log = String()
            for a in self._attempts:
                if a.step == i:
                    attempts += 1
                    if a.attempt > last:
                        last = a.attempt
                        log = a.log
            out.append(
                StepInfo(
                    s.step,
                    s.partition,
                    s.status,
                    attempts,
                    s.error,
                    log,
                    Usage.unknown(),
                )
            )
        return out^

    def own(mut self, run: Int, owner: String, registry_hash: String) raises:
        _ = self._at(run)
        self.run = run
        self.owner = owner
        self.registry_hash = registry_hash

    def start_heartbeat(
        mut self, interval: Float64, timeouts: String = ""
    ) raises:
        pass  # no thread, so no watchdog: one process, nothing to stop

    def stop_heartbeat(mut self):
        pass

    def finish_run(mut self, status: String) raises:
        ref r = self._runs[self._at(self.run)]
        if r.owner == self.owner:
            r.status = status
            r.heartbeat = -1

    def defer_run(mut self, until: Int64) raises:
        # No scheduler to start it again in one process; resume does.
        self.finish_run(DEFERRED)

    def cancel_requested(mut self) raises -> Bool:
        return self._runs[self._at(self.run)].cancel_requested

    # --- Store ---

    def start_attempt(
        mut self,
        step: String,
        partition: String,
        ord: Int,
        input: Span[UInt8, _],
    ) raises -> Int:
        self._still_owner(starting=True)
        var i = self._upsert_step(step, partition, ord)
        ref s = self._steps[i]
        s.status = RUNNING
        s.input = List[UInt8](input)
        s.error = String()
        var n = 1
        for a in self._attempts:
            if a.step == i and a.attempt >= n:
                n = a.attempt + 1
        self._attempts.append(
            _MemAttempt(i, n, RUNNING, self.owner, self.registry_hash, "", "")
        )
        self._attempt = len(self._attempts) - 1
        return n

    def finish_attempt(
        mut self,
        step: String,
        partition: String,
        attempt: Int,
        status: String,
        output: Span[UInt8, _],
        error: String,
    ) raises:
        self._still_owner(starting=False)
        var i = self._step_at(self.run, step, partition)
        if i < 0:
            raise Error("morca: no step ", step, " ", partition)
        for ref a in self._attempts:
            if a.step == i and a.attempt == attempt:
                a.status = status
                a.error = error
        ref s = self._steps[i]
        s.status = status
        s.output = List[UInt8](output) if status == SUCCEEDED else List[UInt8]()
        s.error = error

    def skip(
        mut self, step: String, partition: String, ord: Int, reason: String
    ) raises:
        self._still_owner(starting=True)
        ref s = self._steps[self._upsert_step(step, partition, ord)]
        s.status = SKIPPED
        s.error = reason
        s.output = List[UInt8]()

    def pinned_reads(
        mut self, step: String, partition: String
    ) raises -> Dict[String, Int64]:
        # Each table at the earliest attempt that read it.
        var out = Dict[String, Int64]()
        var first = Dict[String, Int]()
        var i = self._step_at(self.run, step, partition)
        for r in self.records:
            if r.commit or self._attempts[r.attempt].step != i:
                continue
            var n = self._attempts[r.attempt].attempt
            if first.get(r.table.table, n + 1) > n:
                first[r.table.table] = n
                out[r.table.table] = r.table.snapshot_id
        return out^

    def record(mut self, commit: Bool, t: TableSnapshot) raises:
        if self._attempt >= 0:
            self.records.append(MemRecord(self._attempt, commit, t.copy()))

    def fence(mut self) raises:
        pass  # one process: nothing can take its run over

    def set_log(
        mut self, step: String, partition: String, attempt: Int, path: String
    ) raises:
        if self._attempt >= 0:
            self._attempts[self._attempt].log = path


def status_list(status: String) -> List[String]:
    """`runs`' `status`, a status or several comma-separated, as a list,
    each once; empty for any."""
    var out = List[String]()
    for s in status.split(","):
        var t = String(s.strip())
        if t and t not in out:
            out.append(t^)
    return out^
