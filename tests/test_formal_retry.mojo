"""The Lean model of a retried step (formal/) against `morca.tables.append`:
every sequence of up to five events in formal/difftest/retry.cases is
replayed over a local Iceberg table of its own, and the snapshots the table
then holds are compared with the ones the model's oracle printed
(formal/Oracle/Main.lean; the `formal` CI job checks the file is its output).

Events, one letter each:
- `c`: the attempt makes its next commit (`append`);
- `x`: the worker crashes: the next attempt starts with a new `Ctx`, which
  has made no commits;
- `o`: the same step commits for another partition.

A crash in the middle of an `append` isn't replayed as such: to the table it
is `x` (the commit didn't happen) or `c` then `x` (it did). Run in the data
environment, from the repository's root.
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
comptime CASES = "formal/difftest/retry.cases"
comptime MINE = "2024-01"
comptime OTHER = "2024-02"


def _rows(month: String, id: Int) raises -> List[RecordBatch]:
    var b = BatchBuilder(Schema.parse(SCHEMA))
    var ids = b.col("id")
    var months = b.col("month")
    b.add_int(ids, Int64(id))
    b.add_str(months, month)
    return [b^.build()]


def _ctx(partition: String, attempt: Int, dataset: String) -> Ctx:
    """The step's context for `partition` in run 1, recording nothing: what
    a retry is recognised by is in the table."""
    return Ctx(
        "formal_retry",
        1,
        "load",
        partition,
        attempt=attempt,
        declared_writes=[dataset],
    )


def _render(t: Table) raises -> String:
    """The table's snapshots as the oracle prints them: `m<attempt>.<commit>`
    for the step's own, `o<commit>` for the other partition's, `-` for none."""
    var out = String()
    var n = 0
    for s in t.metadata.snapshots:
        if n > 0:
            out += ","
        if s.summary["orca.partition"] == MINE:
            out += String(
                "m", s.summary["orca.attempt"], ".", s.summary["orca.commit"]
            )
        else:
            out += String("o", s.summary["orca.commit"])
        n += 1
    if n == 0:
        return String("-")
    return out


def _replay(name: String, events: String) raises -> String:
    """Replays `events` over a new table `db.<name>` and renders it."""
    var root = String(getenv("MORCA_WAREHOUSE"))
    var cat = FilesystemCatalog.local(root)
    _ = cat.create_table("db", name, IcebergSchema.parse(SCHEMA))
    var t = Table.load_local(String(root, "/db/", name))
    var dataset = String("db.", name)
    var attempt = 1
    var me = _ctx(MINE, attempt, dataset)
    var other = _ctx(OTHER, 1, dataset)
    var row = 0
    var bytes = events.as_bytes()
    for e in bytes:
        if e == UInt8(ord("c")):
            _ = append(me, t, _rows(MINE, row))
        elif e == UInt8(ord("x")):
            attempt += 1
            me = _ctx(MINE, attempt, dataset)
        elif e == UInt8(ord("o")):
            _ = append(other, t, _rows(OTHER, row))
        else:
            raise Error("unknown event in ", events)
        row += 1
    return _render(Table.load_local(String(root, "/db/", name)))


def test_append_agrees_with_the_model() raises:
    var text: String
    with open(CASES, "r") as f:
        text = f.read()
    var cases = 0
    for line in text.split("\n"):
        if not line:
            continue
        var parts = line.split(" ")
        assert_equal(len(parts), 2)
        var events = String(parts[0])
        var expected = String(parts[1])
        var got = _replay(String("t", cases), events)
        if got != expected:
            raise Error(
                "after events ",
                events,
                " the table holds ",
                got,
                "; the model says ",
                expected,
            )
        cases += 1
    # 3 + 9 + 27 + 81 + 243 sequences: an empty or cut file doesn't pass.
    assert_equal(cases, 363)


def before_tests() raises:
    """A warehouse of its own for the run, before any test."""
    _ = setenv("MORCA_WAREHOUSE", String("build/wh-formal-retry-", now_ms()))


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
        raise Error("test_formal_retry failed")
