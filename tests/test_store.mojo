"""`tests/store_suite.mojo` on the stores that need no server."""

from std.os import remove
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from morca import (
    MemoryStore,
    PgStore,
    RunResult,
    SqliteStore,
    parse_months,
    sqlite_path,
)
from morca._internal.sqlite_store import SqliteBeat
from store_suite import (
    Retrying,
    check_a_store_that_lost_its_run_stops,
    check_claim_needs_a_stale_heartbeat,
    check_execute_records_attempts_and_retries,
    check_finished_runs,
    check_killed_anywhere_then_resumed,
    check_reads_are_pinned_across_attempts,
    check_resume_skips_what_succeeded,
    check_runs_have_tokens,
    check_runs_pages,
    check_runs_pages,
    check_versions,
    new_run,
)


def test_memory_claim_needs_a_stale_heartbeat() raises:
    var s = MemoryStore()
    check_claim_needs_a_stale_heartbeat(s)


def test_memory_finished_runs() raises:
    var s = MemoryStore()
    check_finished_runs(s)


def test_memory_execute_records_attempts_and_retries() raises:
    var s = MemoryStore()
    check_execute_records_attempts_and_retries(s)


def test_memory_resume_skips_what_succeeded() raises:
    var s = MemoryStore()
    check_resume_skips_what_succeeded(s)


def test_memory_lost_run_stops() raises:
    var s = MemoryStore()
    check_a_store_that_lost_its_run_stops(s)


def test_memory_reads_are_pinned_across_attempts() raises:
    var s = MemoryStore()
    check_reads_are_pinned_across_attempts(s)


def test_memory_runs_pages() raises:
    var s = MemoryStore()
    check_runs_pages(s)


def test_memory_versions() raises:
    var s = MemoryStore()
    check_versions(s)


def test_memory_killed_anywhere_then_resumed() raises:
    var s = MemoryStore()
    check_killed_anywhere_then_resumed(s)


def test_memory_runs_are_never_positive() raises:
    # So `Ctx.made` recognises no commit of theirs: another process's
    # in-memory run would have the same number.
    var s = MemoryStore()
    assert_equal(new_run(s, "a:1"), 0)
    assert_equal(new_run(s, "a:1"), -1)
    assert_equal(s.runs(10)[0].id, -1)
    with assert_raises(contains="no run 1"):
        _ = s.run_info(1)


def test_memory_records_reads_and_commits() raises:
    var s = MemoryStore()
    check_reads_are_pinned_across_attempts(s)
    # Two attempts, each with one read and one commit, in order.
    assert_equal(len(s.records), 4)
    assert_true(not s.records[0].commit and s.records[1].commit)
    assert_equal(s.records[1].table.table, "/wh/out")
    assert_equal(s.records[3].table.snapshot_id, 3)


def test_memory_cancel_stops_before_the_next_attempt() raises:
    var s = MemoryStore()
    var run = new_run(s, "a:1")
    s.request_cancel(run)
    assert_true(s.cancel_requested())
    with assert_raises(contains="was cancelled"):
        _ = Retrying.execute(s, RunResult(), parse_months("2024-01"), run)


def _file(name: String) raises -> SqliteStore:
    """A store on a fresh file under build/."""
    var path = String("build/test-store-", name, ".db")
    for suffix in ["", "-wal", "-shm"]:
        if exists(path + suffix):
            remove(path + suffix)
    return SqliteStore(path)


def test_sqlite_claim_needs_a_stale_heartbeat() raises:
    var s = _file("claim")
    check_claim_needs_a_stale_heartbeat(s)


def test_sqlite_finished_runs() raises:
    var s = _file("finished")
    check_finished_runs(s)


def test_sqlite_execute_records_attempts_and_retries() raises:
    var s = _file("execute")
    check_execute_records_attempts_and_retries(s)


def test_sqlite_resume_skips_what_succeeded() raises:
    var s = _file("resume")
    check_resume_skips_what_succeeded(s)


def test_sqlite_lost_run_stops() raises:
    var s = _file("lost")
    check_a_store_that_lost_its_run_stops(s)


def test_sqlite_reads_are_pinned_across_attempts() raises:
    var s = _file("pinned")
    check_reads_are_pinned_across_attempts(s)


def test_sqlite_runs_have_tokens() raises:
    var s = _file("tokens")
    check_runs_have_tokens(s)


def test_sqlite_runs_pages() raises:
    var s = _file("pages")
    check_runs_pages(s)


def test_sqlite_versions() raises:
    var s = _file("versions")
    check_versions(s)


def test_sqlite_killed_anywhere_then_resumed() raises:
    var s = _file("killed")
    check_killed_anywhere_then_resumed(s)


def test_sqlite_survives_reopening() raises:
    # What one process recorded, another reads back from the file.
    var a = _file("reopen")
    var run = new_run(a, "a:1")
    var res = Retrying.execute(a, RunResult(), parse_months("2024-01"), run)
    assert_true(res.succeeded())
    a.finish_run("succeeded")
    var b = SqliteStore("build/test-store-reopen.db")
    b.migrate()
    assert_equal(b.run_info(run).status, "succeeded")
    assert_equal(len(b.prior(run).steps), 3)
    assert_equal(b.prior(run).output[Int]("add"), 10)
    assert_equal(b.steps(run)[1].attempts, 1)


def test_sqlite_fences_commits() raises:
    # What a commit to Iceberg checks first (#84): the owner, and a fresh
    # heartbeat.
    var a = _file("fence")
    var run = new_run(a, "a:1")
    a.fence()
    a.db.execute(
        String("UPDATE runs SET heartbeat = heartbeat - 3600 WHERE id = ", run)
    )
    with assert_raises(contains="heartbeat is older than"):
        a.fence()
    var b = SqliteStore("build/test-store-fence.db")
    b.claim(run, "b:2", -1.0)
    with assert_raises(contains="held by b:2, not this process (a:1)"):
        a.fence()


def test_sqlite_heartbeat_honours_cancel_at() raises:
    # A cancel whose cancel_at has passed stops the run from its heartbeat,
    # as on Postgres (#527), not only between attempts.
    var s = _file("cancel")
    var run = new_run(s, "a:1")
    _ = s.start_attempt("month_no", "2024-01", 0, List[UInt8]())
    var beat = SqliteBeat(s.path, run, "a:1")
    assert_equal(beat.stop(), "")
    # Asked to cancel, with a minute left before it's stopped.
    s.db.execute(
        String(
            "UPDATE runs SET cancel_requested = 1, cancel_at = ",
            "((julianday('now') - 2440587.5) * 86400.0) + 60 WHERE id = ",
            run,
        )
    )
    assert_equal(beat.stop(), "")
    s.db.execute(
        String("UPDATE runs SET cancel_at = cancel_at - 120 WHERE id = ", run)
    )
    assert_true(beat.stop().startswith("cancelled: its step hadn't finished"))
    assert_equal(s.run_info(run).status, "cancelled")
    assert_equal(s.steps(run)[0].status, "failed")


def test_sqlite_urls() raises:
    assert_equal(sqlite_path("sqlite:runs.db"), "runs.db")
    assert_equal(sqlite_path("sqlite://runs.db"), "runs.db")
    assert_equal(sqlite_path("sqlite:///var/orca/runs.db"), "/var/orca/runs.db")
    assert_equal(sqlite_path("postgresql:///morca"), "")
    with assert_raises(contains="no file"):
        _ = SqliteStore(sqlite_path("sqlite:"))
    with assert_raises(contains="need Postgres"):
        _ = PgStore("sqlite:runs.db")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
