"""A run's commits are told from those of another run that had its number
(#292): a run created after morca's database was restored from a backup, or
in a new database over the same tables, is given the number of a run whose
snapshots are still in the tables. Each run has a random token
(`Store.run_token`), its commits carry it (`orca.run-token`), and
`Ctx.made` takes a snapshot with another token for another run's.

Over a local Iceberg table each, with a `Ctx` per attempt as
`Pipeline.execute` makes it. Run in the data environment.
"""

from std.os import getenv, setenv
from std.testing import TestSuite, assert_equal

from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.schema import Schema as IcebergSchema
from iceberg.util import now_ms
from parquet import RecordBatch

from morca import Ctx
from morca.tables import BatchBuilder, Schema, Table, append

comptime SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"id","required":true,"type":"long"},'
    '{"id":2,"name":"month","required":true,"type":"string"}]}'
)
comptime KEY = "2024-01"


def _rows(id: Int) raises -> List[RecordBatch]:
    var b = BatchBuilder(Schema.parse(SCHEMA))
    var ids = b.col("id")
    var months = b.col("month")
    b.add_int(ids, Int64(id))
    b.add_str(months, KEY)
    return [b^.build()]


def _create(name: String) raises -> Table:
    var cat = FilesystemCatalog.local(getenv("MORCA_WAREHOUSE"))
    _ = cat.create_table("db", name, IcebergSchema.parse(SCHEMA))
    return Table.load_local(String(getenv("MORCA_WAREHOUSE"), "/db/", name))


def _ctx(name: String, attempt: Int, token: String) -> Ctx:
    """Run 7's step for `KEY`, of the run with `token`."""
    return Ctx(
        "tokens",
        7,
        "load",
        KEY,
        attempt=attempt,
        declared_writes=[String("db.", name)],
        token=token,
    )


def _snapshots(name: String) raises -> Int:
    var root = String(getenv("MORCA_WAREHOUSE"))
    return len(Table.load_local(String(root, "/db/", name)).metadata.snapshots)


def test_a_run_with_another_token_commits_again() raises:
    var t = _create("restored")
    # Run 7, which a restore of morca's database then loses.
    var lost = _ctx("restored", 1, "01938f2a-0000-7111-8111-111111111111")
    var first = append(lost, t, _rows(1))
    assert_equal(_snapshots("restored"), 1)
    # The run the restored database numbers 7: the same pipeline, step and
    # partition, and a token of its own. Its commit isn't there yet.
    var again = _ctx("restored", 1, "01938f2b-0000-7222-8222-222222222222")
    var second = append(again, t, _rows(2))
    assert_equal(_snapshots("restored"), 2)
    if first == second:
        raise Error("the new run took the lost run's commit for its own")
    assert_equal(
        t.metadata.snapshots[1].summary["orca.run-token"],
        "01938f2b-0000-7222-8222-222222222222",
    )
    # Its retry finds that commit, and not the lost run's.
    var retry = _ctx("restored", 2, "01938f2b-0000-7222-8222-222222222222")
    assert_equal(append(retry, t, _rows(3)), second)
    assert_equal(_snapshots("restored"), 2)


def test_a_commit_from_before_tokens_is_still_recognised() raises:
    var t = _create("upgraded")
    # An attempt by a binary from before tokens committed and died.
    var before = _ctx("upgraded", 1, "")
    var first = append(before, t, _rows(1))
    # Its retry, by a binary that gives the run a token, finds the commit.
    var after = _ctx("upgraded", 2, "01938f2c-0000-7333-8333-333333333333")
    assert_equal(append(after, t, _rows(2)), first)
    assert_equal(_snapshots("upgraded"), 1)


def test_a_run_without_a_token_recognises_its_commit() raises:
    var t = _create("worker")
    # A worker's run whose `morca ui` knows tokens for one attempt and not
    # for the next (an image rolled back): the number alone tells.
    var with_token = _ctx("worker", 1, "01938f2d-0000-7444-8444-444444444444")
    var first = append(with_token, t, _rows(1))
    var without = _ctx("worker", 2, "")
    assert_equal(append(without, t, _rows(2)), first)
    assert_equal(_snapshots("worker"), 1)


def before_tests() raises:
    """A warehouse of its own for the run, before any test."""
    _ = setenv("MORCA_WAREHOUSE", String("build/wh-run-token-", now_ms()))


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
        raise Error("test_run_token failed")
