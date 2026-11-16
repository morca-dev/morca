"""The Lean model of pinned reads (formal/Morca/Pins) against `Ctx.pin` over a
store: every sequence of up to five events in formal/difftest/pins.cases is
replayed in a run of its own, and the answers `Ctx.pin` gave are compared
with the ones the model's oracle printed (formal/Oracle/Pins.lean; the
`formal` CI job checks the file is its output). On `MemoryStore` for every
sequence, and on `SqliteStore` for those of up to four events.

Events, one letter each, over two tables, each at snapshot 1 to begin with:
- `a`, `b`: the attempt reads the table (`Ctx.pin` with its current
  snapshot);
- `A`, `B`: another writer commits to the table: its current snapshot is the
  next number;
- `x`: the worker crashes: the next attempt starts, with the store's
  `pinned_reads` and a new `Ctx`.

Run from the repository's root.
"""

from std.os import remove
from std.os.path import exists
from std.testing import TestSuite, assert_equal

from morca import Ctx, MemoryStore, RunStore, SqliteStore

comptime CASES = "formal/difftest/pins.cases"
comptime PIPELINE = "formal_pins"
comptime STEP = "load"
comptime KEY = "2024-01"
comptime OWNER = "a:1"


def _attempt[S: RunStore](mut s: S, run: Int) raises -> Ctx:
    """Starts the step's next attempt in `s` and returns its context, as
    `Pipeline.execute` makes it."""
    var pinned = s.pinned_reads(STEP, KEY)
    var attempt = s.start_attempt(STEP, KEY, 0, Span(List[UInt8]()))
    var recorder = s.recorder()
    return Ctx(PIPELINE, run, STEP, KEY, attempt, "", pinned^, recorder^)


def _replay[S: RunStore](mut s: S, events: String) raises -> String:
    """Replays `events` in a new run of `s`, and renders the answers as the
    oracle prints them: the table and the snapshot, `a1`; `-` for none."""
    var run = s.create_run(PIPELINE, "h", KEY, "manual", OWNER)
    s.own(run, OWNER, "h")
    var current_a = Int64(1)
    var current_b = Int64(1)
    var out = String()
    var answers = 0
    var ctx = _attempt(s, run)
    var bytes = events.as_bytes()
    for e in bytes:
        if e == UInt8(ord("a")):
            var got = ctx.pin("/wh/a", current_a)
            if answers > 0:
                out += ","
            out += String("a", got)
            answers += 1
        elif e == UInt8(ord("b")):
            var got = ctx.pin("/wh/b", current_b)
            if answers > 0:
                out += ","
            out += String("b", got)
            answers += 1
        elif e == UInt8(ord("A")):
            current_a += 1
        elif e == UInt8(ord("B")):
            current_b += 1
        elif e == UInt8(ord("x")):
            ctx = _attempt(s, run)
        else:
            raise Error("unknown event in ", events)
    s.finish_run("failed")
    if answers == 0:
        return String("-")
    return out


def _check[S: RunStore](mut s: S, longest: Int) raises -> Int:
    """Replays the cases of up to `longest` events in `s`; how many."""
    s.migrate()
    s.register(PIPELINE, "h", "{}")
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
        if len(events.as_bytes()) > longest:
            continue
        var got = _replay(s, events)
        if got != expected:
            raise Error(
                "after events ",
                events,
                " Ctx.pin answered ",
                got,
                "; the model says ",
                expected,
            )
        cases += 1
    return cases


def test_memory_pins_agree_with_the_model() raises:
    var s = MemoryStore()
    # 5 + 25 + 125 + 625 + 3125 sequences: an empty or cut file doesn't pass.
    assert_equal(_check(s, 5), 3905)


def test_sqlite_pins_agree_with_the_model() raises:
    var path = String("build/test-formal-pins.db")
    for suffix in ["", "-wal", "-shm"]:
        if exists(path + suffix):
            remove(path + suffix)
    var s = SqliteStore(path)
    assert_equal(_check(s, 4), 780)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
