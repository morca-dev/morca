"""What sensors read and decide without a database: a table's current
snapshot from its metadata JSON (`morca._internal.warehouse`), `sense`'s lines, and
partition keys moved between kinds (`morca._internal.sensors`).

tests/sensors.sh checks `sense` against tables iceberg wrote.
"""

from std.os import makedirs
from std.time import perf_counter_ns
from std.testing import TestSuite, assert_equal, assert_false, assert_raises
from std.testing import assert_true

from morca._internal.sensors import (
    join_keys,
    key_kind,
    map_keys,
    parse_sense,
    split_keys,
)
from morca._internal.warehouse import current_of, current_snapshot

comptime META = """{
  "format-version" : 2,
  "location" : "/w/ns/t",
  "last-updated-ms" : 1700000000000,
  "properties" : { "a \\"quoted\\" key" : "x}]", "nested" : "{\\"not\\": 1}" },
  "schemas" : [ { "type" : "struct", "fields" : [ { "id" : 1, "name" : "id" } ] } ],
  "snapshots" : [ {
    "snapshot-id" : 11,
    "summary" : { "operation" : "append", "orca.partitions" : "2023-12" }
  }, {
    "snapshot-id" : -42,
    "parent-snapshot-id" : 11,
    "timestamp-ms" : 1700000000000,
    "summary" : { "operation" : "append", "orca.run" : "7",
                  "orca.partitions" : "2024-01,2024-02", "note" : "caf\\u00e9 \\ud83d\\ude00" }
  } ],
  "current-snapshot-id" : -42
}"""


def test_current_of() raises:
    var c = current_of("ns.t", META)
    assert_equal(c.dataset, "ns.t")
    # Writers draw positive IDs, so a negative one means none, as -1 does.
    assert_equal(c.snapshot, -1)
    var m = String(META).replace(
        '"current-snapshot-id" : -42', '"current-snapshot-id" : 11'
    )
    c = current_of("ns.t", m)
    assert_equal(c.snapshot, 11)
    assert_false(c.by_morca)
    assert_equal(c.partitions, "2023-12")


def test_current_of_morca_snapshot() raises:
    var m = String(META).replace("-42", "4417")
    var c = current_of("ns.t", m)
    assert_equal(c.snapshot, 4417)
    assert_true(c.by_morca)
    assert_equal(c.partitions, "2024-01,2024-02")


def test_current_of_no_snapshot() raises:
    for doc in [
        String('{"format-version": 2, "snapshots": []}'),
        String('{"current-snapshot-id": null, "snapshots": []}'),
        String('{"current-snapshot-id": -1}'),
        String("{}"),
    ]:
        assert_equal(current_of("ns.t", doc).snapshot, -1)
    # A current snapshot the list doesn't have: its ID, nothing else known.
    var c = current_of("ns.t", '{"current-snapshot-id": 9, "snapshots": []}')
    assert_equal(c.snapshot, 9)
    assert_false(c.by_morca)


def test_current_of_bad_json() raises:
    for doc in [
        String('{"current-snapshot-id"'),
        String('{"snapshots": [{"snapshot-id": 1,}], "current-snapshot-id": 1'),
        String('{"a": "unterminated}'),
        String('{"a" 1}'),
    ]:
        with assert_raises():
            _ = current_of("ns.t", doc)


def _write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def test_current_snapshot_files() raises:
    # A new warehouse each run, so a rerun doesn't find this one's files.
    var wh = String("build/warehouse-test-", perf_counter_ns())
    var dir = String(wh, "/ns/t/metadata")
    makedirs(dir, exist_ok=True)
    # No table: no snapshot.
    assert_equal(current_snapshot(wh, "ns.missing").snapshot, -1)
    _write(
        String(dir, "/00000-a.metadata.json"),
        '{"last-updated-ms": 1, "current-snapshot-id": 1, "snapshots": []}',
    )
    _write(
        String(dir, "/00001-b.metadata.json"),
        '{"last-updated-ms": 2, "current-snapshot-id": 2, "snapshots": []}',
    )
    # Two writers of version 1 from different lifetimes: the later one.
    _write(
        String(dir, "/00001-c.metadata.json"),
        '{"last-updated-ms": 3, "current-snapshot-id": 3, "snapshots": []}',
    )
    _write(String(dir, "/notes.txt"), "not metadata")
    assert_equal(current_snapshot(wh, "ns.t").snapshot, 3)
    # A version hint wins.
    _write(
        String(dir, "/v7.metadata.json"),
        '{"last-updated-ms": 0, "current-snapshot-id": 7, "snapshots": []}',
    )
    _write(String(dir, "/version-hint.text"), "7\n")
    assert_equal(current_snapshot(wh, "ns.t").snapshot, 7)
    with assert_raises(contains="namespace.table"):
        _ = current_snapshot(wh, "nodot")


def test_parse_sense() raises:
    var got = parse_sense(
        "a.b 12 other 2024-01\n\nc.d -1 other -\ne.f 5 orca 2024-02,2024-03\n"
    )
    assert_equal(len(got), 3)
    assert_equal(got[0].dataset, "a.b")
    assert_equal(got[0].snapshot, 12)
    assert_false(got[0].by_morca)
    assert_equal(got[0].partitions, "2024-01")
    assert_equal(got[1].snapshot, -1)
    assert_equal(got[1].partitions, "")
    assert_true(got[2].by_morca)
    with assert_raises():
        _ = parse_sense("a.b 12 other\n")
    with assert_raises():
        _ = parse_sense("a.b twelve other -\n")


def test_map_weekly_keys() raises:
    assert_equal(key_kind("2026-W46"), "weekly")
    assert_equal(key_kind("2026-X46"), "")
    assert_equal(join_keys(map_keys(["2024-12-31"], "weekly")), "2025-W01")
    assert_equal(join_keys(map_keys(["2026-11-15T23"], "weekly")), "2026-W46")
    assert_equal(
        join_keys(map_keys(["2026-11-09", "2026-11-15"], "weekly")),
        "2026-W46",
    )
    # A month is the weeks with a day in it, a week the months it spans.
    assert_equal(
        join_keys(map_keys(["2026-02"], "weekly")),
        "2026-W05,2026-W06,2026-W07,2026-W08,2026-W09",
    )
    assert_equal(
        join_keys(map_keys(["2026-02"], "weekly", "2026-W07")),
        "2026-W07,2026-W08,2026-W09",
    )
    assert_equal(
        join_keys(map_keys(["2026-W53"], "monthly")), "2026-12,2027-01"
    )
    var days = map_keys(["2026-W46"], "daily")
    assert_equal(len(days), 7)
    assert_equal(days[0], "2026-11-09")
    assert_equal(days[6], "2026-11-15")
    assert_equal(len(map_keys(["2026-W46"], "hourly")), 7 * 24)
    assert_equal(join_keys(map_keys(["2026-W46"], "weekly")), "2026-W46")


def test_map_hourly_keys() raises:
    assert_equal(key_kind("2024-02-29T07"), "hourly")
    assert_equal(key_kind("2024-02-29 07"), "")
    assert_equal(
        join_keys(map_keys(["2024-02-29T07", "2024-02-29T23"], "daily")),
        "2024-02-29",
    )
    assert_equal(join_keys(map_keys(["2024-03-01T00"], "monthly")), "2024-03")
    var hours = map_keys(["2024-02-29"], "hourly")
    assert_equal(len(hours), 24)
    assert_equal(hours[0], "2024-02-29T00")
    assert_equal(hours[23], "2024-02-29T23")
    assert_equal(len(map_keys(["2024-02"], "hourly")), 29 * 24)
    assert_equal(
        join_keys(map_keys(["2024-01-01"], "hourly", "2024-01-01T22")),
        "2024-01-01T22,2024-01-01T23",
    )


def test_map_keys() raises:
    assert_equal(key_kind("2024-03"), "monthly")
    assert_equal(key_kind("2024-03-01"), "daily")
    assert_equal(key_kind("x"), "")
    # A month is each of its days.
    var days = map_keys(["2024-02"], "daily")
    assert_equal(len(days), 29)
    assert_equal(days[0], "2024-02-01")
    assert_equal(days[28], "2024-02-29")
    # A day is the month it's in: sorted, once each.
    assert_equal(
        join_keys(
            map_keys(["2024-04-01", "2024-03-05", "2024-03-20"], "monthly")
        ),
        "2024-03,2024-04",
    )
    # The same kind as they are; before the start dropped.
    assert_equal(
        join_keys(
            map_keys(["2024-03", "2023-12", "2024-01"], "monthly", "2024-01")
        ),
        "2024-01,2024-03",
    )
    assert_equal(
        join_keys(map_keys(["2024-01"], "daily", "2024-01-30")),
        "2024-01-30,2024-01-31",
    )
    assert_equal(len(map_keys(["2023-12"], "monthly", "2024-01")), 0)
    with assert_raises(contains="not a partition key"):
        _ = map_keys(["2024"], "monthly")
    with assert_raises():
        _ = map_keys(["2024-13"], "monthly")
    assert_equal(
        join_keys(split_keys(" 2024-01, ,2024-02 ")), "2024-01,2024-02"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
