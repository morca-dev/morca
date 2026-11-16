"""The Lean model of fencing (formal/Morca/Fence) against `PgStore`: every
sequence of up to four events in formal/difftest/fence.cases is replayed on
a run of its own, and which claims and fence checks passed is compared with
what the model's oracle printed (formal/Oracle/Fence.lean; the `formal` CI
job checks the file is its output).

Two processes, `p:1` and `q:2`, and a run that `p:1` has just created; the
stale limit is 1000 s. Events, one letter each:
- `P`, `Q`: the process claims the run (`claim`);
- `p`, `q`: the process checks its fence (`fence`, what `Ctx.fence` calls
  before each commit);
- `b`, `c`: the process's heartbeat beats (`beat_run`);
- `t`, `T`: 300 s, 600 s pass: the run's heartbeat is moved that far back,
  which is the same to every comparison with `now()`.

An outcome is `o` (the claim or the check passes), `x` (it is refused) or
`-` (a beat, or time). The seconds the test itself takes are far from any
limit: the nearest is 100 s away. Run under scripts/with-postgres.sh, from
the repository's root.
"""

from std.os import getenv, setenv
from std.testing import TestSuite, assert_equal

from postgres import Connection, Params

from morca import PgStore
from morca._internal.state import beat_run

comptime CASES = "formal/difftest/fence.cases"
comptime PIPELINE = "formal_fence"
comptime P = "p:1"
comptime Q = "q:2"
comptime STALE = 1000.0


def _claim(mut s: PgStore, run: Int, owner: String) -> String:
    try:
        s.claim(run, owner, STALE)
        return String("o")
    except:
        return String("x")


def _fence(mut s: PgStore, run: Int, owner: String) -> String:
    try:
        s.own(run, owner, "h")
        s.fence()
        return String("o")
    except:
        return String("x")


def _pass(mut conn: Connection, run: Int, seconds: Float64) raises:
    _ = conn.execute(
        (
            "UPDATE orca.runs SET heartbeat = heartbeat - make_interval(secs"
            " => $2) WHERE id = $1"
        ),
        Params().int64(Int64(run)).float64(seconds),
    )


def _replay(
    mut s: PgStore, mut conn: Connection, events: String
) raises -> String:
    """Replays `events` on a new run, and renders the outcomes as the oracle
    prints them."""
    var run = s.create_run(PIPELINE, "h", "2024-01", "manual", P)
    var out = String()
    var bytes = events.as_bytes()
    for e in bytes:
        if e == UInt8(ord("P")):
            out += _claim(s, run, P)
        elif e == UInt8(ord("Q")):
            out += _claim(s, run, Q)
        elif e == UInt8(ord("p")):
            out += _fence(s, run, P)
        elif e == UInt8(ord("q")):
            out += _fence(s, run, Q)
        elif e == UInt8(ord("b")):
            _ = beat_run(conn, run, P, "")
            out += "-"
        elif e == UInt8(ord("c")):
            _ = beat_run(conn, run, Q, "")
            out += "-"
        elif e == UInt8(ord("t")):
            _pass(conn, run, 300.0)
            out += "-"
        elif e == UInt8(ord("T")):
            _pass(conn, run, 600.0)
            out += "-"
        else:
            raise Error("unknown event in ", events)
    return out


def test_fencing_agrees_with_the_model() raises:
    _ = setenv("MORCA_STALE_SECONDS", "1000", True)
    var s = PgStore(getenv("MORCA_DATABASE_URL"))
    s.migrate()
    s.register(PIPELINE, "h", "{}")
    var conn = Connection(getenv("MORCA_DATABASE_URL"))
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
        var got = _replay(s, conn, events)
        if got != expected:
            raise Error(
                "after events ",
                events,
                " the store answered ",
                got,
                "; the model says ",
                expected,
            )
        cases += 1
    # 8 + 64 + 512 + 4096 sequences: an empty or cut file doesn't pass.
    assert_equal(cases, 4680)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
