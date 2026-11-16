"""Steps that replace their partitions (`replaces=`, `replace_partitions`):
a new run of a key leaves one copy of its rows, a retry within a run gives
what an uninterrupted attempt gives, and two runs replacing one partition at
once don't both keep their rows. Over local Iceberg tables partitioned by
month; run under scripts/with-postgres.sh, in the data environment.

Each run writes ids from a base of its own (`MORCA_TEST_BASE`), so a table's
ids say which run each row came from.
"""

from std.os import getenv, setenv
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_true

from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.schema import Schema as IcebergSchema
from iceberg.transforms import PartitionField, PartitionSpec, parse_transform
from iceberg.util import now_ms
from parquet import RecordBatch

from morca import (
    Ctx,
    Mapped,
    Month,
    PgStore,
    Pipeline,
    RunResult,
    State,
    Step,
    parse_months,
)
from morca.tables import (
    BatchBuilder,
    FileChanges,
    Schema,
    Table,
    append,
    append_files,
    commit,
    replace_partition_files,
    replace_partitions,
    table,
    write_files,
)

comptime SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"id","required":true,"type":"long"},'
    '{"id":2,"name":"month","required":true,"type":"string"}]}'
)
comptime ROWS = 4
"""Rows per commit."""
comptime COMMITS = 2
"""Commits a step makes per month."""


def _spec() -> PartitionSpec:
    try:
        return PartitionSpec(
            0,
            [
                PartitionField.single(
                    2, 1000, "month", parse_transform("identity")
                )
            ],
        )
    except:
        return PartitionSpec.unpartitioned()


def _rows(month: String, start: Int, n: Int) raises -> List[RecordBatch]:
    var b = BatchBuilder(Schema.parse(SCHEMA))
    var ids = b.col("id")
    var months = b.col("month")
    for i in range(n):
        b.add_int(ids, Int64(start + i))
        b.add_str(months, month)
    return [b^.build()]


def _create(name: String) raises:
    var cat = FilesystemCatalog.local(getenv("MORCA_WAREHOUSE"))
    _ = cat.create_table("db", name, IcebergSchema.parse(SCHEMA), _spec())


def _table(name: String) raises -> Table:
    return Table.load_local(String(getenv("MORCA_WAREHOUSE"), "/db/", name))


def _ids(t: Table) raises -> List[Int64]:
    """Every id in the table, sorted."""
    var out = List[Int64]()
    for b in t.scan().to_batches():
        for i in range(b.num_columns()):
            if b.name(i) == "id":
                var got = b.column_i64(i)
                for v in got[0]:
                    out.append(v)
    sort(out)
    return out^


def _expected(base: Int) -> List[Int64]:
    """The ids one uninterrupted attempt of `load` writes for a month."""
    var out = List[Int64]()
    for i in range(COMMITS * ROWS):
        out.append(Int64(base + i))
    return out^


def _die_once(name: String) raises -> Bool:
    """True the first time for `name` while MORCA_TEST_DIE is `once`."""
    if getenv("MORCA_TEST_DIE") != "once":
        return False
    var marker = String(getenv("MORCA_WAREHOUSE"), "/died-", name)
    if exists(marker):
        return False
    with open(marker, "w") as f:
        f.write("1")
    return True


def load[dataset: StaticString](mut ctx: Ctx, m: Month) raises -> Int64:
    """`COMMITS` appends of `ROWS` rows for the month, ids from the month's
    base: `MORCA_TEST_BASE` plus 100 per month after January. With
    MORCA_TEST_DIE=once, the first attempt dies after its first commit."""
    var t = table(ctx, dataset)
    var base = Int(getenv("MORCA_TEST_BASE", "0")) + 100 * (m.month - 1)
    var id = Int64(-1)
    for c in range(COMMITS):
        id = append(ctx, t, _rows(String(m), base + c * ROWS, ROWS))
        if c == 0 and _die_once(String(dataset, "-", m, "-", ctx.run)):
            raise Error("died after its first commit")
    return id


comptime Replace = Step[
    "load", Month, Int64, load["db.r"], Mapped, retries=1, replaces=["db.r"]
]
comptime Replaces = Pipeline["replace_rerun", Replace]
comptime Append = Step[
    "load", Month, Int64, load["db.a"], Mapped, writes=["db.a"]
]
comptime Appends = Pipeline["replace_append", Append]
comptime Retried = Step[
    "load", Month, Int64, load["db.t"], Mapped, retries=1, replaces=["db.t"]
]
comptime Retries = Pipeline["replace_retry", Retried]


def _store(run_name: String) raises -> PgStore:
    """A new run, numbered by Postgres."""
    var url = getenv("MORCA_DATABASE_URL")
    var db = State(url)
    db.migrate()
    db.register(run_name, "h", "{}")
    var run = db.create_run(run_name, "h", "x", "manual", "a:1")
    return PgStore(db^, url, run, "a:1", "h")


def _new_run(base: Int, name: String) raises -> PgStore:
    """A new run whose rows start at `base`."""
    _ = setenv("MORCA_TEST_BASE", String(base))
    return _store(name)


def _error(res: RunResult) -> String:
    for st in res.steps:
        if st.error:
            return st.error
    return ""


def test_a_rerun_replaces_its_partition() raises:
    _create("r")
    var store = _new_run(1000, "replace_rerun")
    var res = Replaces.execute(
        store, RunResult(), parse_months("2024-01..2024-02"), store.run
    )
    assert_true(res.succeeded(), _error(res))
    var first = _ids(_table("r"))
    assert_equal(len(first), 2 * COMMITS * ROWS)
    # A new run of January, as `morca backfill --rerun` starts: January's rows
    # are this run's, February's the first run's.
    for base in [2000, 3000]:
        store = _new_run(base, "replace_rerun")
        res = Replaces.execute(
            store, RunResult(), parse_months("2024-01"), store.run
        )
        assert_true(res.succeeded(), _error(res))
        var want = _expected(1100)
        for v in _expected(base):
            want.append(v)
        assert_equal(_ids(_table("r")), want)
    # The run's first commit is an overwrite of January's two files; its
    # second appends, replacing nothing.
    var t = _table("r")
    var n = len(t.metadata.snapshots)
    assert_equal(n, 2 * COMMITS + 2 * COMMITS)
    var s0 = t.metadata.snapshots[n - 2].summary.copy()
    assert_equal(s0["operation"], "overwrite")
    assert_equal(s0["orca.commit"], "0")
    assert_equal(s0["orca.replaced-files"], String(COMMITS))
    assert_equal(s0["orca.replaced-records"], String(COMMITS * ROWS))
    assert_equal(s0["deleted-data-files"], String(COMMITS))
    var s1 = t.metadata.snapshots[n - 1].summary.copy()
    assert_equal(s1["operation"], "append")
    assert_equal(s1["orca.commit"], "1")
    assert_equal(s1["orca.replaced-files"], "0")


def test_append_mode_still_appends() raises:
    _create("a")
    var store = _new_run(1000, "replace_append")
    var res = Appends.execute(
        store, RunResult(), parse_months("2024-01"), store.run
    )
    assert_true(res.succeeded(), _error(res))
    store = _new_run(2000, "replace_append")
    res = Appends.execute(
        store, RunResult(), parse_months("2024-01"), store.run
    )
    assert_true(res.succeeded(), _error(res))
    var want = _expected(1000)
    for v in _expected(2000):
        want.append(v)
    sort(want)
    assert_equal(_ids(_table("a")), want)
    var t = _table("a")
    for s in t.metadata.snapshots:
        assert_equal(s.summary["operation"], "append")
        assert_true("orca.replaced-files" not in s.summary)


def test_a_retry_within_a_run_is_the_uninterrupted_result() raises:
    _create("t")
    var store = _new_run(1000, "replace_retry")
    var res = Retries.execute(
        store, RunResult(), parse_months("2024-01"), store.run
    )
    assert_true(res.succeeded(), _error(res))
    # The new run's first attempt replaces January and dies; its retry
    # finds that commit, and appends the second without replacing it.
    _ = setenv("MORCA_TEST_DIE", "once")
    store = _new_run(2000, "replace_retry")
    res = Retries.execute(
        store, RunResult(), parse_months("2024-01"), store.run
    )
    _ = setenv("MORCA_TEST_DIE", "")
    assert_true(res.succeeded(), _error(res))
    assert_equal(res.steps[0].attempt, 2)
    assert_equal(_ids(_table("t")), _expected(2000))
    var t = _table("t")
    var n = len(t.metadata.snapshots)
    assert_equal(n, 2 * COMMITS)
    assert_equal(t.metadata.snapshots[n - 2].summary["operation"], "overwrite")
    assert_equal(t.metadata.snapshots[n - 2].summary["orca.attempt"], "1")
    assert_equal(t.metadata.snapshots[n - 1].summary["operation"], "append")
    assert_equal(t.metadata.snapshots[n - 1].summary["orca.attempt"], "2")


def _ctx(run: Int, dataset: String) -> Ctx:
    """A step's context in run `run`, replacing `dataset`, recording nothing."""
    return Ctx(
        "replace_race",
        run,
        "load",
        "2024-01",
        declared_writes=[dataset],
        declared_replaces=[dataset],
    )


def test_two_runs_replacing_one_partition_keep_one_runs_rows() raises:
    _create("c")
    var cat = FilesystemCatalog.local(getenv("MORCA_WAREHOUSE"))
    var t = _table("c")
    # An earlier run's January.
    var old = _ctx(9000, "db.c")
    _ = replace_partitions(old, t, _rows("2024-01", 9000, ROWS))
    # Runs a and b replace January at once, a commit at a time in turn.
    var a = _ctx(9001, "db.c")
    var b = _ctx(9002, "db.c")
    _ = replace_partitions(a, t, _rows("2024-01", 1000, ROWS))
    _ = replace_partitions(b, t, _rows("2024-01", 2000, ROWS))
    # b removed a's rows: a's next commit would leave half a January, so it
    # refuses, committing nothing.
    var snapshots = len(_table("c").metadata.snapshots)
    var refused = String()
    try:
        _ = replace_partitions(a, t, _rows("2024-01", 1000 + ROWS, ROWS))
    except e:
        refused = String(e)
    assert_true("another writer is writing a partition" in refused, refused)
    assert_true("run 9002 of replace_race" in refused, refused)
    assert_equal(len(_table("c").metadata.snapshots), snapshots)
    _ = replace_partitions(b, t, _rows("2024-01", 2000 + ROWS, ROWS))
    assert_equal(_ids(_table("c")), _expected(2000))
    # Files written elsewhere replace the same way.
    var w = _ctx(9003, "db.c")
    var files = write_files(_table("c"), _rows("2024-01", 3000, 2 * ROWS))
    _ = replace_partition_files(w, t, files)
    assert_equal(_ids(_table("c")), _expected(3000))


def test_a_commit_refuses_a_stale_removal() raises:
    """GAPS #29: an overwrite planned before another writer removed some of
    its files isn't committed over the rest."""
    _create("s")
    var cat = FilesystemCatalog.local(getenv("MORCA_WAREHOUSE"))
    var t = _table("s")
    var first = _ctx(9101, "db.s")
    _ = replace_partitions(first, t, _rows("2024-01", 1000, ROWS))
    _ = replace_partitions(first, t, _rows("2024-01", 1000 + ROWS, ROWS))
    # A writer reads January's files to replace them itself...
    var stale = List[String]()
    for task in _table("s").scan().plan_files():
        stale.append(task.data_file.file_path)
    assert_equal(len(stale), 2)
    # ...another writer removes one of them meanwhile...
    var other = Ctx(
        "replace_race", 9102, "drop", "2024-01", declared_writes=["db.s"]
    )
    var drop = FileChanges()
    drop.removed = [stale[0]]
    _ = commit(other, t, "delete", drop^)
    # ...and the overwrite planned before is refused, rather than remove the
    # other file and keep both writers' changes.
    var late = Ctx(
        "replace_race", 9103, "load", "2024-01", declared_writes=["db.s"]
    )
    var change = FileChanges()
    change.added_data = write_files(_table("s"), _rows("2024-01", 3000, ROWS))
    change.removed = stale.copy()
    var snapshots = len(_table("s").metadata.snapshots)
    var refused = String()
    try:
        _ = commit(late, t, "overwrite", change^)
    except e:
        refused = String(e)
    # iceberg-mojo 0.12.0 refuses it itself; morca's own check is behind it.
    assert_true(
        "the commit to db.s was refused" in refused
        and "1 of the 2 files this commit removes are not in the current snapshot"
        in refused,
        refused,
    )
    assert_equal(len(_table("s").metadata.snapshots), snapshots)
    assert_equal(len(_ids(_table("s"))), ROWS)


def _expected_n(base: Int, n: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(n):
        out.append(Int64(base + i))
    return out^


def test_an_unpartitioned_table_is_replaced_whole() raises:
    var cat = FilesystemCatalog.local(getenv("MORCA_WAREHOUSE"))
    _ = cat.create_table("db", "u", IcebergSchema.parse(SCHEMA))
    var t = _table("u")
    var one = _ctx(9201, "db.u")
    _ = replace_partitions(one, t, _rows("2024-01", 1000, ROWS))
    _ = replace_partitions(one, t, _rows("2024-02", 1000 + ROWS, ROWS))
    var two = _ctx(9202, "db.u")
    _ = replace_partitions(two, t, _rows("2024-03", 2000, ROWS))
    assert_equal(_ids(_table("u")), _expected_n(2000, ROWS))


def test_append_to_a_replaced_dataset_replaces() raises:
    """`append` and `append_files` replace for a dataset in `replaces=`."""
    _create("d")
    var cat = FilesystemCatalog.local(getenv("MORCA_WAREHOUSE"))
    var t = _table("d")
    var one = _ctx(9301, "db.d")
    _ = append(one, t, _rows("2024-01", 1000, ROWS))
    var two = _ctx(9302, "db.d")
    _ = append_files(two, t, write_files(t, _rows("2024-01", 2000, ROWS)))
    assert_equal(_ids(_table("d")), _expected_n(2000, ROWS))


def before_tests() raises:
    """A warehouse of its own for the run, before any test."""
    var root = String("build/wh-replace-", now_ms())
    _ = setenv("MORCA_WAREHOUSE", root)


def after_tests() raises:
    """Nothing to undo: the process ends after the tests."""
    pass


def main() raises:
    # scripts/unit-tests.sh, which runs the tests from one binary, calls
    # before_tests and after_tests as this does.
    before_tests()
    var failed = False
    try:
        TestSuite.discover_tests[__functions_in_module()]().run()
    except e:
        failed = True
        print(e)
    after_tests()
    if failed:
        raise Error("test_replace failed")
