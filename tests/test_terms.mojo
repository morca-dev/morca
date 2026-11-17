"""The UI's vocabulary (`morca._internal.ui.terms`): every status and trigger
it lists has help, and docs/ui.md's tables of them are the ones generated
from it. With MORCA_WRITE_DOCS=1 (`pixi run docs-vocabulary`) the test
writes them there instead of failing."""

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_true

from morca._internal.ui.terms import (
    RUN_STATUSES,
    RUN_TRIGGERS,
    STEP_STATUSES,
    VOCABULARY_BEGIN,
    VOCABULARY_END,
    value_help,
    vocabulary_markdown,
)

comptime DOC = "docs/ui.md"


def test_every_value_has_help() raises:
    for v in materialize[RUN_STATUSES]():
        assert_true(value_help("status", v) != "", String("status ", v))
    for v in materialize[STEP_STATUSES]():
        assert_true(value_help("status", v) != "", String("status ", v))
    for v in materialize[RUN_TRIGGERS]():
        assert_true(value_help("trigger", v) != "", String("trigger ", v))


def test_cli_is_its_own_trigger() raises:
    assert_true("cli" in materialize[RUN_TRIGGERS]())
    assert_true("morca start" in String(value_help("trigger", "cli")))
    assert_true("unpaused" in String(value_help("status", "paused")))


def test_docs_vocabulary() raises:
    var doc: String
    with open(DOC, "r") as f:
        doc = f.read()
    var begin = doc.find(VOCABULARY_BEGIN)
    var end = doc.find(VOCABULARY_END)
    assert_true(begin >= 0 and end > begin, String(DOC, " has no markers"))
    end += StaticString(VOCABULARY_END).byte_length()
    var want = vocabulary_markdown()
    var have = String(doc[byte=begin:end])
    if have == want:
        return
    if getenv("MORCA_WRITE_DOCS") == "1":
        with open(DOC, "w") as f:
            f.write(doc[byte=:begin], want, doc[byte=end:])
        print("wrote", DOC)
        return
    assert_equal(
        have,
        want,
        String(DOC, "'s tables differ: pixi run docs-vocabulary"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
