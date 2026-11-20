"""Pinned reads, recognised commits and declared datasets, over local
Iceberg tables in a warehouse (`MORCA_WAREHOUSE`). Run under
scripts/with-postgres.sh, in the data environment."""

from std.os import getenv, setenv
from std.os.path import exists
from std.random import seed
from std.testing import TestSuite, assert_equal, assert_true

from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.catalog.filesystem import Table as IcebergTable
from iceberg.schema import Schema as IcebergSchema
from iceberg.util import now_ms
from parquet import RecordBatch
from postgres import Connection, Params

from dista import Seq

from morca import (
    Ctx,
    Gather,
    Mapped,
    Month,
    PgStore,
    Pipeline,
    RunResult,
    State,
    Step,
    parse_months,
)
from morca._lake.backoff import jitter
from morca.tables import (
    BatchBuilder,
    Schema,
    Table,
    append,
    dataset_of,
    ensure_table,
    scan,
    table,
)

comptime SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"id","required":true,"type":"long"},'
    '{"id":2,"name":"month","required":true,"type":"string"}]}'
)


def _rows(month: String, n: Int) raises -> List[RecordBatch]:
    var b = BatchBuilder(Schema.parse(SCHEMA))
    var ids = b.col("id")
    var months = b.col("month")
    for i in range(n):
        b.add_int(ids, Int64(i))
        b.add_str(months, month)
    return [b^.build()]


def _count(t: Table) raises -> Int:
    var n = 0
    for b in t.scan().to_batches():
        n += b.num_rows
    return n


def _snapshots(t: Table) -> Int:
    return len(t.metadata.snapshots)


# Where the steps' tables are, and how the next attempt misbehaves: the
# steps are plain functions, so the test talks to them through the
# environment.


def _table(name: String) raises -> Table:
    return Table.load_local(String(getenv("MORCA_TEST_WH"), "/db/", name))


def load(mut ctx: Ctx, m: Month) raises -> Int64:
    """Appends 3 rows for the month to `out`; dies right after committing
    while MORCA_TEST_DIE is set."""
    var out = _table("out")
    var id = append(ctx, out, _rows(String(m), 3))
    if getenv("MORCA_TEST_DIE"):
        raise Error("died after committing")
    return id


def taken_load(mut ctx: Ctx, m: Month) raises -> Int64:
    """Appends as `load` does, after making the run look lost as
    MORCA_TEST_TAKE says: `owner`, another process claimed it; `stale`, this
    process's heartbeat went stale while it worked."""
    var c = Connection(getenv("MORCA_DATABASE_URL"))
    if getenv("MORCA_TEST_TAKE") == "owner":
        _ = c.execute(
            (
                "UPDATE orca.runs SET owner = 'b:2', heartbeat = now() WHERE id"
                " = $1"
            ),
            Params().int64(Int64(ctx.run)),
        )
    else:
        _ = c.execute(
            (
                "UPDATE orca.runs SET heartbeat = now() - interval '1 hour'"
                " WHERE id = $1"
            ),
            Params().int64(Int64(ctx.run)),
        )
    var out = _table("out")
    return append(ctx, out, _rows(String(m), 3))


def copy_count(mut ctx: Ctx, m: Month) raises -> Int:
    """Counts `src` at the pinned snapshot. While MORCA_TEST_DIE is set,
    another writer appends to `src` first, then the attempt dies."""
    var src = _table("src")
    var n = 0
    for b in scan(ctx, src).to_batches():
        n += b.num_rows
    if getenv("MORCA_TEST_DIE"):
        _ = src.append(_rows("late", 5))
        raise Error("died after reading")
    return n


def sneak(mut ctx: Ctx, m: Month) raises -> Int:
    """Scans `out`, which it doesn't declare."""
    var out = _table("out")
    return len(scan(ctx, out).to_batches())


def scribble(mut ctx: Ctx, m: Month) raises -> Int64:
    """Appends to `src`, which it declares it reads, not writes."""
    var src = _table("src")
    return append(ctx, src, _rows(String(m), 1))


def by_name(mut ctx: Ctx, m: Month) raises -> Int:
    """Counts `db.src`, loaded by its dataset name."""
    var n = 0
    for b in scan(ctx, table(ctx, "db.src")).to_batches():
        n += b.num_rows
    return n


def key(mut ctx: Ctx, m: Month) raises -> Int:
    return m.month


def sum_all(mut ctx: Ctx, ms: Seq[Int]) raises -> Int64:
    """Appends one row per month, in one commit for the run."""
    var out = _table("out")
    return append(ctx, out, _rows("all", len(ms)))


def evolve(mut ctx: Ctx, m: Month) raises -> Int:
    """`ensure_table` on `out` with the schema in MORCA_TEST_SCHEMA; returns
    how many schemas the table has after."""
    var t = ensure_table(
        ctx, "db.out", Schema.parse(getenv("MORCA_TEST_SCHEMA"))
    )
    return len(t.metadata.schemas)


comptime Load = Step["load", Month, Int64, load, Mapped, writes=["db.out"]]
comptime Loads = Pipeline["loads", Load]
comptime TakenLoad = Step[
    "taken_load", Month, Int64, taken_load, Mapped, writes=["db.out"]
]
comptime Takens = Pipeline["takens", TakenLoad]
comptime CopyCount = Step[
    "copy_count", Month, Int, copy_count, Mapped, reads=["db.src"]
]
comptime Copies = Pipeline["copies", CopyCount]
comptime Sneak = Step["sneak", Month, Int, sneak, Mapped, reads=["db.src"]]
comptime Sneaky = Pipeline["sneaky", Sneak]
comptime Scribble = Step[
    "scribble", Month, Int64, scribble, Mapped, reads=["db.src"]
]
comptime Scribbles = Pipeline["scribbles", Scribble]
comptime ByName = Step["by_name", Month, Int, by_name, Mapped, reads=["db.src"]]
comptime ByNames = Pipeline["by_names", ByName]
comptime Key = Step["key", Month, Int, key, Mapped]
comptime SumAll = Step[
    "sum_all", Seq[Int], Int64, sum_all, Gather, after=Key, writes=["db.out"]
]
comptime Sums = Pipeline["sums", Key, SumAll]
comptime Evolve = Step["evolve", Month, Int, evolve, Mapped, writes=["db.out"]]
comptime Evolves = Pipeline["evolves", Evolve]

# SCHEMA with a column and a struct added, ids numbered on from the table's.
comptime WIDER = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"id","required":true,"type":"long"},'
    '{"id":2,"name":"month","required":true,"type":"string"},'
    '{"id":3,"name":"note","required":false,"type":"string"},'
    '{"id":4,"name":"geo","required":false,"type":{"type":"struct","fields":['
    '{"id":5,"name":"lat","required":false,"type":"double"}]}}]}'
)


def _warehouse() raises -> FilesystemCatalog:
    # A root of its own for each test: two tests can start in one
    # millisecond (they did on CI), so the time alone isn't enough.
    var root = String("build/wh-", now_ms())
    var n = 0
    while exists(root):
        n += 1
        root = String("build/wh-", now_ms(), "-", n)
    _ = setenv("MORCA_TEST_WH", root)
    _ = setenv("MORCA_WAREHOUSE", root)
    var cat = FilesystemCatalog.local(root)
    _ = cat.create_table("db", "out", IcebergSchema.parse(SCHEMA))
    _ = cat.create_table("db", "src", IcebergSchema.parse(SCHEMA))
    return cat^


def _store(run_name: String) raises -> PgStore:
    var url = getenv("MORCA_DATABASE_URL")
    var db = State(url)
    db.migrate()
    db.register(run_name, "h", "{}")
    var run = db.create_run(run_name, "h", "x", "manual", "a:1")
    return PgStore(db^, url, run, "a:1", "h")


def _resume(mut store: PgStore) raises -> RunResult:
    """What `resume` does to the store between two processes."""
    _ = store.db.interrupt(store.run)
    return store.db.prior(store.run)


def test_a_commit_is_recognised_on_resume() raises:
    _ = _warehouse()
    var store = _store("loads")
    var months = parse_months("2024-01..2024-02")
    _ = setenv("MORCA_TEST_DIE", "1")
    var res = Loads.execute(store, RunResult(), months, store.run)
    assert_true(not res.succeeded())
    assert_equal(_snapshots(_table("out")), 2)
    # The commits were recorded as they happened, before the attempts died.
    var conn = Connection(getenv("MORCA_DATABASE_URL"))
    assert_equal(
        Int(
            conn.query(
                (
                    "SELECT count(*) AS n FROM orca.commits c JOIN"
                    " orca.attempts a ON a.id = c.attempt JOIN orca.steps s ON"
                    " s.id = a.step WHERE s.run = $1 AND c.dataset = 'db.out'"
                ),
                Params().int64(Int64(store.run)),
            )
            .row(0)
            .int64("n")
        ),
        2,
    )
    _ = setenv("MORCA_TEST_DIE", "")
    res = Loads.execute(store, _resume(store), months, store.run)
    assert_true(res.succeeded())
    var out = _table("out")
    # One snapshot per month, not two, and the step returns it.
    assert_equal(_snapshots(out), 2)
    assert_equal(_count(out), 6)
    assert_equal(
        res.output[Int64]("load", "2024-01"),
        out.metadata.snapshots[0].snapshot_id,
    )
    var s = out.metadata.snapshots[1].summary.copy()
    assert_equal(s["orca.pipeline"], "loads")
    assert_equal(s["orca.run"], String(store.run))
    assert_equal(s["orca.step"], "load")
    assert_equal(s["orca.partition"], "2024-02")
    assert_equal(s["orca.partitions"], "2024-02")
    assert_equal(s["orca.attempt"], "1")
    assert_equal(s["orca.commit"], "0")
    assert_equal(s["orca.code"], hex(Loads.registry_hash()))


def test_a_lost_run_doesnt_commit() raises:
    """A process whose run another process claimed while it worked (its
    heartbeat went stale while it was alive) doesn't commit (#60)."""
    _ = _warehouse()
    var store = _store("takens")
    _ = setenv("MORCA_TEST_TAKE", "owner")
    var raised = False
    try:
        _ = Takens.execute(
            store, RunResult(), parse_months("2024-01"), store.run
        )
    except e:
        raised = True
        assert_true("lost run" in String(e), String(e))
    assert_true(raised, "the attempt carried on after losing its run")
    assert_equal(_snapshots(_table("out")), 0)


def test_a_stale_heartbeat_doesnt_commit() raises:
    """A process whose heartbeat is stale may lose its run at any moment,
    so it doesn't commit either; the attempt fails saying why."""
    _ = _warehouse()
    var store = _store("takens")
    _ = setenv("MORCA_TEST_TAKE", "stale")
    var res = Takens.execute(
        store, RunResult(), parse_months("2024-01"), store.run
    )
    assert_true(not res.succeeded())
    assert_true("heartbeat is older than" in _error(res), _error(res))
    assert_equal(_snapshots(_table("out")), 0)


def test_in_memory_runs_dont_recognise() raises:
    _ = _warehouse()
    _ = setenv("MORCA_TEST_DIE", "")
    _ = Loads.run(parse_months("2024-01"))
    _ = Loads.run(parse_months("2024-01"))
    assert_equal(_snapshots(_table("out")), 2)


def test_a_resumed_step_reads_its_pinned_snapshot() raises:
    _ = _warehouse()
    var src = _table("src")
    _ = src.append(_rows("2024-01", 4))
    var store = _store("copies")
    var months = parse_months("2024-01")
    _ = setenv("MORCA_TEST_DIE", "1")
    var res = Copies.execute(store, RunResult(), months, store.run)
    assert_true(not res.succeeded())
    assert_equal(_count(_table("src")), 9)  # the late commit landed
    _ = setenv("MORCA_TEST_DIE", "")
    res = Copies.execute(store, _resume(store), months, store.run)
    assert_true(res.succeeded())
    assert_equal(res.output[Int]("copy_count", "2024-01"), 4)
    # Without the pin, a new run sees the late rows.
    res = Copies.run(months)
    assert_equal(res.output[Int]("copy_count", "2024-01"), 9)


def test_an_empty_table_stays_empty_for_the_step() raises:
    _ = _warehouse()
    var store = _store("copies")
    var months = parse_months("2024-01")
    _ = setenv("MORCA_TEST_DIE", "1")
    _ = Copies.execute(store, RunResult(), months, store.run)
    _ = setenv("MORCA_TEST_DIE", "")
    var res = Copies.execute(store, _resume(store), months, store.run)
    assert_equal(res.output[Int]("copy_count", "2024-01"), 0)


def _error(res: RunResult) -> String:
    for st in res.steps:
        if st.error:
            return st.error
    return ""


def test_an_undeclared_dataset_fails_the_attempt() raises:
    _ = _warehouse()
    var res = Sneaky.run(parse_months("2024-01"))
    assert_true(not res.succeeded())
    assert_equal(
        _error(res),
        (
            "morca: step sneak of sneaky reads db.out, which it doesn't declare"
            " in reads="
        ),
    )
    res = Scribbles.run(parse_months("2024-01"))
    assert_equal(
        _error(res),
        (
            "morca: step scribble of scribbles writes db.src, which it doesn't"
            " declare in writes="
        ),
    )
    assert_equal(_snapshots(_table("src")), 0)


def test_a_declared_dataset_loads_by_name() raises:
    _ = _warehouse()
    var src = _table("src")
    _ = src.append(_rows("2024-01", 3))
    var res = ByNames.run(parse_months("2024-01"))
    assert_true(res.succeeded())
    assert_equal(res.output[Int]("by_name", "2024-01"), 3)
    assert_equal(
        dataset_of(String(getenv("MORCA_TEST_WH"), "/db/src/")), "db.src"
    )
    assert_equal(dataset_of("/elsewhere/db/src"), "")
    assert_equal(dataset_of(String(getenv("MORCA_TEST_WH"), "/db")), "")


def test_a_gather_commit_holds_the_runs_partitions() raises:
    _ = _warehouse()
    var store = _store("sums")
    var res = Sums.execute(
        store, RunResult(), parse_months("2024-01..2024-02"), store.run
    )
    assert_true(res.succeeded())
    var s = _table("out").metadata.snapshots[0].summary.copy()
    assert_equal(s["orca.partition"], "")
    assert_equal(s["orca.partitions"], "2024-01,2024-02")


def test_a_table_outside_the_warehouse_needs_no_declaration() raises:
    _ = _warehouse()
    _ = setenv("MORCA_WAREHOUSE", "build/wh-elsewhere")
    var res = Sneaky.run(parse_months("2024-01"))
    assert_true(res.succeeded())


def _evolve_with(schema: String) raises -> RunResult:
    _ = setenv("MORCA_TEST_SCHEMA", schema)
    return Evolves.run(parse_months("2024-01"))


def test_ensure_table_adds_the_columns_the_table_lacks() raises:
    _ = _warehouse()
    var out = _table("out")
    _ = out.append(_rows("2024-01", 3))
    var res = _evolve_with(WIDER)
    assert_true(res.succeeded(), _error(res))
    assert_equal(res.output[Int]("evolve", "2024-01"), 2)
    # Read back with iceberg itself, not through the library.
    var t = IcebergTable.load_local(String(getenv("MORCA_TEST_WH"), "/db/out"))
    var s = t.metadata.schema()
    assert_equal(s.schema_id, 1)
    assert_equal(s.find_by_name("note").id, 3)
    assert_equal(s.find_by_name("geo.lat").id, 5)
    assert_equal(t.metadata.last_column_id, 5)
    # The rows written before read the new columns as null.
    var rows = t.scan().to_table()
    assert_equal(rows.num_rows(), 3)
    assert_equal(rows.num_columns(), 4)
    for r in range(rows.num_rows()):
        assert_true(not rows.value(r, 2).valid, "note is null")
    # The same schema again changes nothing, and so does a narrower one
    # that keeps the required columns: what it leaves out stays.
    var loc = t.metadata_location
    res = _evolve_with(WIDER)
    assert_true(res.succeeded(), _error(res))
    res = _evolve_with(SCHEMA)
    assert_true(res.succeeded(), _error(res))
    assert_equal(_table("out").metadata_location, loc)


def test_ensure_table_refuses_an_incompatible_schema() raises:
    _ = _warehouse()
    var retyped = (
        '{"schema-id":0,"type":"struct","fields":['
        '{"id":1,"name":"id","required":true,"type":"long"},'
        '{"id":2,"name":"month","required":true,"type":"long"}]}'
    )
    var res = _evolve_with(retyped)
    assert_true(not res.succeeded())
    assert_true(
        "cannot change the type of 'month' from string to long" in _error(res),
        _error(res),
    )
    assert_true(_error(res).startswith("morca: db.out can't take"), _error(res))
    var dropped = (
        '{"schema-id":0,"type":"struct","fields":['
        '{"id":1,"name":"id","required":true,"type":"long"}]}'
    )
    res = _evolve_with(dropped)
    assert_true(
        "db.out requires column 'month', which the schema given leaves out"
        in _error(res),
        _error(res),
    )
    var required = (
        '{"schema-id":0,"type":"struct","fields":['
        '{"id":1,"name":"id","required":true,"type":"long"},'
        '{"id":2,"name":"month","required":true,"type":"string"},'
        '{"id":3,"name":"note","required":true,"type":"string"}]}'
    )
    res = _evolve_with(required)
    assert_true("as a required column" in _error(res), _error(res))
    var renumbered = (
        '{"schema-id":0,"type":"struct","fields":['
        '{"id":1,"name":"id","required":true,"type":"long"},'
        '{"id":2,"name":"month","required":true,"type":"string"},'
        '{"id":7,"name":"note","required":false,"type":"string"}]}'
    )
    res = _evolve_with(renumbered)
    assert_true(
        "'note' is field 3 in the table but 7 in the schema given"
        in _error(res),
        _error(res),
    )
    # Nothing above committed a schema.
    assert_equal(len(_table("out").metadata.schemas), 1)


def test_commit_backoff_differs_between_processes() raises:
    """A commit's retry waits don't follow `std.random`: two processes in
    the same state (unseeded, as every process starts) wait differently,
    so writers that clashed don't clash again on every retry (#532)."""
    var waits = List[Float64]()
    for _ in range(4):
        seed(532)
        waits.append(jitter())
    var distinct = 0
    for i in range(len(waits)):
        assert_true(0.5 <= waits[i] < 1.5, String(waits[i]))
        if i > 0 and waits[i] != waits[i - 1]:
            distinct += 1
    assert_true(distinct > 0, "the same wait each time: " + String(waits[0]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
