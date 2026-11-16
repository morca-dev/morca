"""The Lean model of the schema floor (formal/Morca/Migrate) against
`morca._internal.state`: every line of formal/difftest/migrate.cases, which the model's
oracle printed (formal/Oracle/Migrate.lean; the `formal` CI job checks the
file is its output), is checked against the code.

- `F <version> <floor>`: `migration_floor`.
- `S <version> <floor> <known> <verdict>`: `schema_ahead`: `M` it returns
  False (the binary migrates), `A` True (it runs on a schema ahead of it),
  `X` it raises.
- `E <events> <outcomes> <version> <floor>`: binaries migrating an empty
  database in turn (`State.migrate` under `MORCA_TEST_MIGRATIONS`): `a`,
  `b`, `c`, `d` know 23, 24, 40 and 46 migrations, and `n` leaves every row
  of `orca.schema_version` without a floor. An outcome is `o` (the binary
  goes on), `x` (it refuses) or `-` (for `n`); then the database's version
  and the floor it states, -1 for none.

Run under scripts/with-postgres.sh, from the repository's root.
"""

from std.os import getenv, setenv, unsetenv
from std.testing import TestSuite, assert_equal

from postgres import Connection

from morca import State
from morca._internal.migrations import migration_floor, schema_ahead

comptime CASES = "formal/difftest/migrate.cases"


def _verdict(version: Int, floor: Int, known: Int) -> String:
    try:
        if schema_ahead(version, floor, known):
            return String("A")
        return String("M")
    except:
        return String("X")


def _number(mut conn: Connection, sql: String) raises -> Int:
    return Int(conn.query(sql).row(0).int64("n"))


def _migrate_as(known: String) -> String:
    """`State.migrate` by a binary that knows `known` migrations: `o` if it
    goes on, `x` if it refuses."""
    _ = setenv("MORCA_TEST_MIGRATIONS", known, True)
    var outcome = String("o")
    try:
        var db = State(getenv("MORCA_DATABASE_URL"))
        db.migrate()
    except:
        outcome = String("x")
    _ = unsetenv("MORCA_TEST_MIGRATIONS")
    return outcome


def _replay(events: String) raises -> String:
    """Replays `events` on an empty database, and renders the outcomes, the
    version and the floor as the oracle prints them."""
    var conn = Connection(getenv("MORCA_DATABASE_URL"))
    _ = conn.execute("DROP SCHEMA IF EXISTS orca CASCADE")
    _ = conn.execute("CREATE SCHEMA orca")
    _ = conn.execute(
        "CREATE TABLE orca.schema_version (version int NOT NULL, min_binary"
        " int)"
    )
    var outcomes = String()
    var bytes = events.as_bytes()
    for e in bytes:
        if e == UInt8(ord("a")):
            outcomes += _migrate_as("23")
        elif e == UInt8(ord("b")):
            outcomes += _migrate_as("24")
        elif e == UInt8(ord("c")):
            outcomes += _migrate_as("40")
        elif e == UInt8(ord("d")):
            outcomes += _migrate_as("46")
        elif e == UInt8(ord("n")):
            _ = conn.execute("UPDATE orca.schema_version SET min_binary = NULL")
            outcomes += "-"
        else:
            raise Error("unknown event in ", events)
    var version = _number(
        conn, "SELECT coalesce(max(version), 0) AS n FROM orca.schema_version"
    )
    var floor = _number(
        conn,
        (
            "SELECT CASE WHEN bool_or(min_binary IS NULL) THEN -1 ELSE"
            " coalesce(max(min_binary), 0) END AS n FROM orca.schema_version"
        ),
    )
    return String(outcomes, " ", version, " ", floor)


def test_the_floor_agrees_with_the_model() raises:
    var text: String
    with open(CASES, "r") as f:
        text = f.read()
    var floors = 0
    var checks = 0
    var replays = 0
    for line in text.split("\n"):
        if not line:
            continue
        var parts = line.split(" ")
        var kind = String(parts[0])
        var got = String()
        var expected = String()
        if kind == "F":
            assert_equal(len(parts), 3)
            got = String(migration_floor(Int(String(parts[1]))))
            expected = String(parts[2])
            floors += 1
        elif kind == "S":
            assert_equal(len(parts), 5)
            got = _verdict(
                Int(String(parts[1])),
                Int(String(parts[2])),
                Int(String(parts[3])),
            )
            expected = String(parts[4])
            checks += 1
        elif kind == "E":
            assert_equal(len(parts), 5)
            got = _replay(String(parts[1]))
            expected = String(parts[2], " ", parts[3], " ", parts[4])
            replays += 1
        else:
            raise Error("unknown line: ", line)
        if got != expected:
            raise Error(
                "for `", line, "` the code gives ", got, ", not ", expected
            )
    # An empty or cut file doesn't pass.
    assert_equal(floors, 51)
    assert_equal(checks, 810)
    assert_equal(replays, 155)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
