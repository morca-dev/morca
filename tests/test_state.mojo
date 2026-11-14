"""The state in Postgres: `tests/store_suite.mojo` on `PgStore`, and what
only Postgres has. Run under scripts/with-postgres.sh, which sets
MORCA_DATABASE_URL to a throwaway database."""

from std.os import getenv, setenv, unsetenv
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from postgres import Connection, Params

from morca import PgStore, RunResult, State, parse_months
from morca._internal.config import ProjectConfig
from morca._internal.pool_config import PoolConfig, read_pools, record_pools
from morca._internal.recommend import LEARN_RUNS, expire_raised
from morca._internal.migrations import migration_floor, schema_ahead
from store_suite import (
    Touching,
    check_a_store_that_lost_its_run_stops,
    check_claim_needs_a_stale_heartbeat,
    check_execute_records_attempts_and_retries,
    check_finished_runs,
    check_killed_anywhere_then_resumed,
    check_reads_are_pinned_across_attempts,
    check_resume_skips_what_succeeded,
    check_runs_have_tokens,
    check_runs_pages,
    check_versions,
)


def _db() raises -> State:
    var db = State(getenv("MORCA_DATABASE_URL"))
    db.migrate()
    return db^


def _count(sql: String) raises -> Int:
    var conn = Connection(getenv("MORCA_DATABASE_URL"))
    return Int(conn.query(sql).row(0).int64("n"))


def _new_run(mut db: State, owner: String) raises -> Int:
    db.register("t", "0x1", "{}")
    return db.create_run("t", "0x1", "2024-01..2024-03", "manual", owner)


def test_migrate_is_idempotent() raises:
    var db = _db()
    db.migrate()
    assert_equal(
        _count("SELECT max(version) AS n FROM orca.schema_version"), 62
    )
    assert_equal(_count("SELECT count(*) AS n FROM orca.schema_version"), 62)


def test_each_version_records_its_floor() raises:
    _ = _db()
    assert_equal(
        _count(
            "SELECT count(*) AS n FROM orca.schema_version WHERE min_binary"
            " IS NULL"
        ),
        0,
    )
    assert_equal(
        _count("SELECT max(min_binary) AS n FROM orca.schema_version"), 24
    )
    assert_equal(migration_floor(1), 1)
    assert_equal(migration_floor(23), 1)
    assert_equal(migration_floor(24), 24)
    assert_equal(migration_floor(40), 24)
    # 41 (orca.alerts), 42 (orca.schedulers), 43 (fill_lag), 44 (learned
    # requests), 45 (memory_raised_run), 46 (memory stall), 47 (run tokens),
    # 48 (unretried_start), 49 (max_runs_auto), 50 (data_version), 51
    # (orca.pools), 52 (the pool autoscaler's state), 53 (keys_per_run), 54
    # (run_members), 55 (fill_max_runs_auto), 56 (runs.batch), 57
    # (orca.dataset_settings), 58 (pool_machines.image, draining), 59
    # (pipelines.retired), 60 (pipelines.priority), 61 (workers' rooms)
    # and 62 (orca.fill_requests) are additive.
    assert_equal(migration_floor(41), 24)
    assert_equal(migration_floor(42), 24)
    assert_equal(migration_floor(43), 24)
    assert_equal(migration_floor(44), 24)
    assert_equal(migration_floor(45), 24)
    assert_equal(migration_floor(46), 24)
    assert_equal(migration_floor(47), 24)
    assert_equal(migration_floor(48), 24)
    assert_equal(migration_floor(49), 24)
    assert_equal(migration_floor(50), 24)
    assert_equal(migration_floor(51), 24)
    assert_equal(migration_floor(52), 24)
    assert_equal(migration_floor(53), 24)
    assert_equal(migration_floor(54), 24)
    assert_equal(migration_floor(55), 24)
    assert_equal(migration_floor(56), 24)
    assert_equal(migration_floor(57), 24)
    assert_equal(migration_floor(58), 24)
    assert_equal(migration_floor(59), 24)
    assert_equal(migration_floor(60), 24)
    assert_equal(migration_floor(61), 24)
    assert_equal(migration_floor(62), 24)


def test_the_schema_check() raises:
    assert_false(schema_ahead(40, 24, 40))
    assert_false(schema_ahead(12, 1, 40))
    assert_true(schema_ahead(41, 24, 40))
    assert_true(schema_ahead(41, 40, 40))
    with assert_raises(contains="needs a binary that knows at least 41"):
        _ = schema_ahead(41, 41, 40)
    with assert_raises(contains="doesn't record"):
        _ = schema_ahead(41, -1, 40)


def test_an_older_binary_runs_on_additive_migrations() raises:
    _ = _db()
    # A binary that knows 30 migrations: 31..62 are additive.
    _ = setenv("MORCA_TEST_MIGRATIONS", "30", True)
    try:
        var old = State(getenv("MORCA_DATABASE_URL"))
        old.migrate()
        # It runs on the schema, and doesn't touch the versions.
        _ = _new_run(old, "a:1")
        assert_equal(
            _count("SELECT max(version) AS n FROM orca.schema_version"), 62
        )
        # One that knows 23 doesn't: 24 raised the floor.
        _ = setenv("MORCA_TEST_MIGRATIONS", "23", True)
        with assert_raises(contains="needs a binary that knows at least 24"):
            var older = State(getenv("MORCA_DATABASE_URL"))
            older.migrate()
    finally:
        _ = unsetenv("MORCA_TEST_MIGRATIONS")


def test_floors_are_filled_in_for_an_older_database() raises:
    _ = _db()
    # As a database the binaries before min_binary migrated left it.
    var conn = Connection(getenv("MORCA_DATABASE_URL"))
    _ = conn.execute("UPDATE orca.schema_version SET min_binary = NULL")
    # An older binary can't tell what it may run on.
    _ = setenv("MORCA_TEST_MIGRATIONS", "30", True)
    try:
        with assert_raises(contains="doesn't record"):
            var older = State(getenv("MORCA_DATABASE_URL"))
            older.migrate()
    finally:
        _ = unsetenv("MORCA_TEST_MIGRATIONS")
    # This one knows every version's floor and fills them in.
    _ = _db()
    assert_equal(
        _count(
            "SELECT count(*) AS n FROM orca.schema_version WHERE min_binary ="
            " 24"
        ),
        39,
    )
    assert_equal(
        _count(
            "SELECT count(*) AS n FROM orca.schema_version WHERE min_binary"
            " IS NULL"
        ),
        0,
    )


def test_an_oom_raise_expires_after_the_learning_window() raises:
    """A pipeline's out-of-memory raise holds while the run that caused it
    is among the last LEARN_RUNS; once that many of its runs after it have
    succeeded, `expire_raised` forgets it (census #97: one 1.5 GB outlier
    held a 77 MB pipeline at 1.7 GB for good)."""
    var db = _db()
    db.register("floor", "0x1", "{}")
    var raised = db.create_run("floor", "0x1", "2024-01", "manual", "a:1")
    _ = db.conn.execute(
        (
            "UPDATE orca.pipelines SET memory_raised_mb = 1728,"
            " memory_raised_run = $1 WHERE name = 'floor'"
        ),
        Params().int64(Int64(raised)),
    )
    var ids = List[Int]()
    for _ in range(LEARN_RUNS):
        ids.append(db.create_run("floor", "0x1", "2024-02", "manual", "a:1"))
    var done = "UPDATE orca.runs SET status = 'succeeded' WHERE id = $1"
    # One short of the window, and failed runs don't count.
    for i in range(LEARN_RUNS - 1):
        _ = db.conn.execute(done, Params().int64(Int64(ids[i])))
    _ = db.conn.execute(
        "UPDATE orca.runs SET status = 'failed' WHERE id = $1",
        Params().int64(Int64(ids[LEARN_RUNS - 1])),
    )
    assert_equal(len(expire_raised(db)), 0)
    var floor = (
        "SELECT coalesce(memory_raised_mb, 0) AS n FROM orca.pipelines WHERE"
        " name = 'floor'"
    )
    assert_equal(_count(floor), 1728)
    _ = db.conn.execute(done, Params().int64(Int64(ids[LEARN_RUNS - 1])))
    var gone = expire_raised(db)
    assert_equal(len(gone), 1)
    assert_equal(gone[0], "floor")
    assert_equal(_count(floor), 0)
    assert_equal(len(expire_raised(db)), 0)


def test_pools_are_recorded_from_the_file() raises:
    """`record_pools` (#267): orca.pools is what morca.toml says, a pool the
    file no longer has deleted."""
    var db = _db()
    var two = ProjectConfig(
        String(
            (
                '[pools.a]\nprovider = "ec2"\nmachines = [{ type = "c7g.large"'
                " }]\n"
            ),
            '[pools.b]\nprovider = "hetzner"\nmachines = [{ type = "cax31",',
            ' wait = 60 }, { type = "cpx32" }]\nlocations = ["hel1"]\n',
            "max_machines = 2\n",
        ),
        "morca.toml",
    )
    assert_equal(len(record_pools(db, read_pools(two.doc))), 0)
    assert_equal(_count("SELECT count(*) AS n FROM orca.pools"), 2)
    assert_equal(
        _count(
            "SELECT max_machines AS n FROM orca.pools WHERE name = 'b' AND"
            " machines->0->>'type' = 'cax31' AND (machines->1->'wait') IS NULL"
            " AND locations = '[\"hel1\"]'"
        ),
        2,
    )
    var one = ProjectConfig(
        '[pools.b]\nprovider = "ec2"\nmachines = [{ type = "c7g.large" }]\n',
        "morca.toml",
    )
    var gone = record_pools(db, read_pools(one.doc))
    assert_equal(gone, ["a"])
    assert_equal(
        _count(
            "SELECT count(*) AS n FROM orca.pools WHERE name = 'b' AND provider"
            " = 'ec2' AND max_machines = 1"
        ),
        1,
    )
    _ = record_pools(db, List[PoolConfig]())
    assert_equal(_count("SELECT count(*) AS n FROM orca.pools"), 0)


def test_a_queued_run_can_be_claimed() raises:
    var db = _db()
    var run = _new_run(db, "a:1")
    _ = db.conn.execute(
        (
            "UPDATE orca.runs SET status = 'queued', owner = NULL, heartbeat ="
            " NULL WHERE id = $1"
        ),
        Params().int64(Int64(run)),
    )
    db.claim(run, "b:2", 30.0)
    assert_equal(db.run_info(run).status, "running")
    assert_equal(db.run_info(run).owner, "b:2")


def test_reads_and_commits_go_through_the_store() raises:
    var db = _db()
    db.register("touching", hex(Touching.registry_hash()), "{}")
    var run = db.create_run("touching", "h", "x", "manual", "a:1")
    var store = PgStore(db^, getenv("MORCA_DATABASE_URL"), run, "a:1", "h")
    var res = Touching.execute(store, RunResult(), parse_months("2024-03"), run)
    # The second attempt read the snapshot the first one did.
    assert_equal(res.output[Int]("touch", "2024-03"), 101)
    var att = String(
        " r JOIN orca.attempts a ON a.id = r.attempt JOIN orca.steps s ON",
        " s.id = a.step WHERE s.run = ",
        run,
    )
    assert_equal(
        _count(
            String(
                "SELECT count(*) AS n FROM orca.reads",
                att,
                " AND r.snapshot_id = 101 AND r.dataset = 'ns.in'",
            )
        ),
        2,
    )
    # Both commits are on record, the failed attempt's too.
    assert_equal(
        _count(
            String(
                "SELECT count(*) AS n FROM orca.commits",
                att,
                " AND r.table_name = '/wh/out' AND r.snapshot_id = 3",
            )
        ),
        2,
    )


def _store() raises -> PgStore:
    return PgStore(getenv("MORCA_DATABASE_URL"))


def test_pg_claim_needs_a_stale_heartbeat() raises:
    var s = _store()
    check_claim_needs_a_stale_heartbeat(s)


def test_pg_finished_runs() raises:
    var s = _store()
    check_finished_runs(s)


def test_pg_execute_records_attempts_and_retries() raises:
    var s = _store()
    check_execute_records_attempts_and_retries(s)


def test_pg_resume_skips_what_succeeded() raises:
    var s = _store()
    check_resume_skips_what_succeeded(s)


def test_pg_lost_run_stops() raises:
    var s = _store()
    check_a_store_that_lost_its_run_stops(s)


def test_pg_reads_are_pinned_across_attempts() raises:
    var s = _store()
    check_reads_are_pinned_across_attempts(s)


def test_pg_runs_have_tokens() raises:
    var s = _store()
    check_runs_have_tokens(s)


def test_pg_runs_pages() raises:
    var s = _store()
    check_runs_pages(s)


def test_pg_versions() raises:
    var s = _store()
    check_versions(s)


def test_pg_killed_anywhere_then_resumed() raises:
    var s = _store()
    check_killed_anywhere_then_resumed(s)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
