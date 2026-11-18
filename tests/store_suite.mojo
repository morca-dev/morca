"""What every `RunStore` must do, written once over the trait.

`tests/test_store.mojo` runs it on the stores that need no server
(`MemoryStore`, and `SqliteStore` on a file), `tests/test_state.mojo` on
`PgStore`. Each check takes a fresh store, or one whose other runs don't
matter: runs are told apart by their number.
"""

from std.testing import assert_equal, assert_raises, assert_true

from dista import Seq
from morca import (
    Ctx,
    Gather,
    Mapped,
    Month,
    Pipeline,
    RunResult,
    RunStore,
    Step,
    Store,
    TableSnapshot,
    parse_months,
)

# --- a pipeline whose second step fails its first attempt ---


def month_no(mut ctx: Ctx, m: Month) raises -> Int:
    return m.month


def flaky(mut ctx: Ctx, n: Int) raises -> Int:
    if ctx.attempt == 1 and n == 2:
        raise Error("first try fails")
    return n * 10


def add(mut ctx: Ctx, xs: Seq[Int]) raises -> Int:
    var t = 0
    for i in range(len(xs)):
        t += xs[i]
    return t


comptime MonthNo = Step["month_no", Month, Int, month_no, Mapped]
comptime Flaky = Step[
    "flaky", Int, Int, flaky, Mapped, after=MonthNo, retries=1
]
comptime Add = Step["add", Seq[Int], Int, add, Gather, after=Flaky]
comptime Retrying = Pipeline["retrying", MonthNo, Flaky, Add]


# --- a step that reads and commits a table, as morca.tables would ---


def touch(mut ctx: Ctx, m: Month) raises -> Int:
    var id = ctx.pin("/wh/in", Int64(100 + ctx.attempt), "ns.in")
    ctx.committed("/wh/out", Int64(m.month), "ns.out")
    if ctx.attempt == 1:
        raise Error("fails after its commit")
    return Int(id)


comptime Touch = Step["touch", Month, Int, touch, Mapped, retries=1]
comptime Touching = Pipeline["touching", Touch]


def new_run[S: RunStore](mut s: S, owner: String) raises -> Int:
    """A run of `retrying` over three months, created and owned by `owner`."""
    s.migrate()
    s.register("retrying", hex(Retrying.registry_hash()), Retrying.describe())
    var run = s.create_run("retrying", "h", "2024-01..2024-03", "manual", owner)
    s.own(run, owner, "h")
    return run


def _is_uuid7(token: String) -> Bool:
    """Whether `token` is a UUID as text (8-4-4-4-12) of version 7 and the
    standard variant."""
    var b = token.as_bytes()
    if len(b) != 36:
        return False
    for i in [8, 13, 18, 23]:
        if b[i] != UInt8(ord("-")):
            return False
    var variant = b[19]
    return b[14] == UInt8(ord("7")) and (
        variant == UInt8(ord("8"))
        or variant == UInt8(ord("9"))
        or variant == UInt8(ord("a"))
        or variant == UInt8(ord("b"))
    )


def _time_of(token: String) -> String:
    """The 12 hex digits of a UUID version 7's time, which sort as it does."""
    var b = token.as_bytes()
    var out = String()
    for i in range(13):
        if i != 8:
            out += chr(Int(b[i]))
    return out


def check_runs_have_tokens[S: RunStore](mut s: S) raises:
    """Each run has a token of its own, the same each time it's asked for
    (#292)."""
    var first = new_run(s, "a:1")
    var a = s.run_token()
    assert_true(_is_uuid7(a))
    assert_equal(s.run_token(), a)
    var second = new_run(s, "a:1")
    var b = s.run_token()
    assert_true(_is_uuid7(b))
    assert_true(a != b)
    # The time comes first, so a later run's token sorts after an earlier
    # one's, unless they were made in the same millisecond.
    assert_true(_time_of(a) <= _time_of(b))
    s.own(first, "a:1", "h")
    assert_equal(s.run_token(), a)
    s.own(second, "a:1", "h")


def check_claim_needs_a_stale_heartbeat[S: RunStore](mut s: S) raises:
    var run = new_run(s, "a:1")
    with assert_raises(contains="is held by a:1"):
        s.claim(run, "b:2", 30.0)
    # Any heartbeat is older than the limit of -1 s: as if it went stale.
    s.claim(run, "b:2", -1.0)
    assert_equal(s.run_info(run).owner, "b:2")
    assert_equal(s.run_info(run).status, "running")


def check_finished_runs[S: RunStore](mut s: S) raises:
    var run = new_run(s, "a:1")
    s.finish_run("failed")
    # A failed run's heartbeat is cleared: it can be resumed at once.
    s.claim(run, "b:2", 30.0)
    s.own(run, "b:2", "h")
    s.finish_run("succeeded")
    with assert_raises(contains="is succeeded"):
        s.claim(run, "c:3", 30.0)
    with assert_raises(contains="no run"):
        s.claim(99999, "c:3", 30.0)
    with assert_raises(contains="no run"):
        _ = s.run_info(99999)


def check_execute_records_attempts_and_retries[S: RunStore](mut s: S) raises:
    var run = new_run(s, "a:1")
    var res = Retrying.execute(
        s, RunResult(), parse_months("2024-01..2024-03"), run
    )
    assert_true(res.succeeded())
    assert_equal(res.output[Int]("add"), 60)
    var steps = s.steps(run)
    assert_equal(len(steps), 7)
    assert_equal(steps[0].step, "month_no")
    assert_equal(steps[6].step, "add")
    for st in steps:
        assert_equal(st.status, "succeeded")
        assert_equal(
            st.attempts,
            2 if st.step == "flaky" and st.partition == "2024-02" else 1,
        )
    var found = False
    for r in s.runs(5):
        if r.id == run:
            found = True
            assert_equal(r.pipeline, "retrying")
            assert_equal(r.partitions, "2024-01..2024-03")
    assert_true(found)


def check_resume_skips_what_succeeded[S: RunStore](mut s: S) raises:
    var run = new_run(s, "a:1")
    var months = parse_months("2024-01..2024-02")
    var res = Retrying.execute(s, RunResult(), months, run)
    assert_equal(res.output[Int]("add"), 30)
    # A process that died during `add` leaves its attempt running.
    _ = s.start_attempt("add", "", 2, Span(List[UInt8]()))
    assert_equal(s.interrupt(run), 1)
    assert_equal(s.interrupt(run), 0)
    var prior = s.prior(run)
    assert_equal(len(prior.steps), 4)
    res = Retrying.execute(s, prior^, months, run)
    assert_true(res.succeeded())
    assert_equal(res.output[Int]("add"), 30)
    for st in s.steps(run):
        if st.step == "add":
            assert_equal(st.attempts, 3)
            assert_equal(st.status, "succeeded")
        elif st.step == "month_no":
            assert_equal(st.attempts, 1)


def check_a_store_that_lost_its_run_stops[S: RunStore](mut s: S) raises:
    var run = new_run(s, "a:1")
    s.claim(run, "b:2", -1.0)
    # Still recording as a:1, which no longer owns the run.
    with assert_raises(contains="lost run"):
        _ = Retrying.execute(s, RunResult(), parse_months("2024-01"), run)
    assert_equal(len(s.steps(run)), 0)


def check_reads_are_pinned_across_attempts[S: RunStore](mut s: S) raises:
    s.migrate()
    s.register("touching", hex(Touching.registry_hash()), "{}")
    var run = s.create_run("touching", "h", "2024-03", "manual", "a:1")
    s.own(run, "a:1", "h")
    var res = Touching.execute(s, RunResult(), parse_months("2024-03"), run)
    # The second attempt read the snapshot the first one did.
    assert_equal(res.output[Int]("touch", "2024-03"), 101)
    var pinned = s.pinned_reads("touch", "2024-03")
    assert_equal(len(pinned), 1)
    assert_equal(pinned["/wh/in"], 101)


def check_runs_pages[S: RunStore](mut s: S) raises:
    """`runs` pages newest first, each from under the last run of the one
    before, with no run twice and none skipped."""
    # One run first, so none of the five is 0, which `before` doesn't take.
    _ = new_run(s, "a:1")
    var made = List[Int]()
    for _ in range(5):
        made.append(new_run(s, "a:1"))
    var p1 = s.runs(2)
    assert_equal(len(p1), 2)
    assert_equal(p1[0].id, made[4])
    assert_equal(p1[1].id, made[3])
    var p2 = s.runs(2, p1[1].id)
    assert_equal(len(p2), 2)
    assert_equal(p2[0].id, made[2])
    assert_equal(p2[1].id, made[1])
    # The last of these five, then whatever this store had before them.
    var p3 = s.runs(2, p2[1].id)
    assert_equal(p3[0].id, made[0])
    for r in s.runs(100, made[0]):
        assert_true(r.id not in made)
    # By status: one of several, newest first, paged the same way.
    var ended = new_run(s, "a:1")
    s.finish_run("failed")
    var won = new_run(s, "a:1")
    s.finish_run("succeeded")
    var failed = s.runs(1, status="failed")
    assert_equal(len(failed), 1)
    assert_equal(failed[0].id, ended)
    var either = s.runs(2, status="succeeded, failed")
    assert_equal(len(either), 2)
    assert_equal(either[0].id, won)
    assert_equal(either[1].id, ended)
    for r in s.runs(100, ended, "failed,succeeded"):
        assert_true(r.status == "failed" or r.status == "succeeded")
        assert_true(r.id != ended and r.id != won)
    for r in s.runs(100, status="queued"):
        assert_equal(r.status, "queued")


def check_versions[S: RunStore](mut s: S) raises:
    var run = new_run(s, "a:1")
    var v = s.version("retrying", "h", "{}", "img")
    assert_equal(s.version("retrying", "h", "{}", "img"), v)
    assert_true(s.version("retrying", "h2", "{}", "img") != v)
    s.ran_version(run, v)


struct Dying[S: RunStore](Movable, Store):
    """`S`, but the process "dies" before its `at`-th write: that write and
    every later one raise, as if killed."""

    var store: Pointer[Self.S, MutUntrackedOrigin]
    var at: Int
    var writes: Int

    def __init__(out self, mut store: Self.S, at: Int):
        self.store = Pointer[Self.S, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=store))
        )
        self.at = at
        self.writes = 0

    def _write(mut self) raises:
        self.writes += 1
        if self.writes >= self.at:
            raise Error("killed")

    def start_attempt(
        mut self,
        step: String,
        partition: String,
        ord: Int,
        input: Span[UInt8, _],
    ) raises -> Int:
        self._write()
        return self.store[].start_attempt(step, partition, ord, input)

    def finish_attempt(
        mut self,
        step: String,
        partition: String,
        attempt: Int,
        status: String,
        output: Span[UInt8, _],
        error: String,
    ) raises:
        self._write()
        self.store[].finish_attempt(
            step, partition, attempt, status, output, error
        )

    def skip(
        mut self, step: String, partition: String, ord: Int, reason: String
    ) raises:
        self._write()
        self.store[].skip(step, partition, ord, reason)

    def pinned_reads(
        mut self, step: String, partition: String
    ) raises -> Dict[String, Int64]:
        return self.store[].pinned_reads(step, partition)

    def run_token(mut self) raises -> String:
        return self.store[].run_token()

    def record(mut self, commit: Bool, t: TableSnapshot) raises:
        self.store[].record(commit, t)

    def fence(mut self) raises:
        self.store[].fence()

    def set_log(
        mut self, step: String, partition: String, attempt: Int, path: String
    ) raises:
        self.store[].set_log(step, partition, attempt, path)


def check_killed_anywhere_then_resumed[S: RunStore](mut s: S) raises:
    """A kill test in one process: a run of `retrying` over two months
    dies before each of its writes in turn (12 in all), and is resumed by
    another owner. Every time, it ends succeeded with the total of an
    uninterrupted run, every step succeeded, and at most one attempt more
    than an uninterrupted run made, when the death left one running."""
    var months = parse_months("2024-01..2024-02")
    for at in range(1, 14):
        var run = new_run(s, "a:1")
        var d = Dying(s, at)
        var died = False
        try:
            _ = Retrying.execute(d, RunResult(), months, run)
        except e:
            assert_equal(String(e), "killed")
            died = True
        assert_equal(died, at <= 12)
        var owner = String("b:", at)
        s.claim(run, owner, -1.0)
        s.own(run, owner, "h")
        var interrupted = s.interrupt(run)
        assert_true(interrupted <= 1)
        var prior = s.prior(run)
        var res = Retrying.execute(s, prior^, months, run)
        assert_true(res.succeeded())
        assert_equal(res.output[Int]("add"), 30)
        s.finish_run("succeeded")
        assert_equal(s.run_info(run).status, "succeeded")
        var attempts = 0
        var steps = s.steps(run)
        assert_equal(len(steps), 5)
        for st in steps:
            assert_equal(st.status, "succeeded")
            attempts += st.attempts
        # 6 attempts uninterrupted (flaky 2024-02 takes two); a death
        # inside an attempt, after its start was recorded, can add one.
        assert_true(attempts >= 6 and attempts <= 6 + interrupted)
