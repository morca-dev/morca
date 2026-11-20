"""Finding a pipeline's functions in its source (`morca._internal.locate`), over this
repository's examples."""

from std.testing import TestSuite, assert_equal, assert_true

from json import loads

from morca._internal.locate import function_key, locate, mojo_files

comptime DESCRIBE = """{"pipeline": "toy", "steps": [
  {"name": "days", "function": "toy::days(morca::ctx::Ctx,morca::month::Month)"},
  {"name": "gone", "function": "toy::not_there(morca::ctx::Ctx)"},
  {"name": "x", "function": "nowhere::x(Int)"}],
 "tasks": ["fanout::trips(fanout::Day)", "toy::days(morca::ctx::Ctx)"]}"""


def test_function_key() raises:
    assert_equal(function_key("toy::days(morca::ctx::Ctx,Int)"), "toy::days")
    assert_equal(function_key("lake::steps::parse"), "lake::steps::parse")


def test_files_skip_build_and_hidden() raises:
    var fs = mojo_files(".")
    assert_true("examples/toy.mojo" in fs)
    for f in fs:
        assert_true(not f.startswith("build/") and not f.startswith("."))


def test_locate_examples() raises:
    var m = loads(locate(DESCRIBE, "."))
    assert_equal(m.object_count(), 3)
    var p = m["pipeline"].string_value()
    assert_true(p.startswith("examples/toy.mojo#L"))
    var pl = Int(p[byte = p.find("#L").or_else(-1) + 2 :])
    assert_true(m["toy::days"].string_value().startswith("examples/toy.mojo#L"))
    assert_true(
        m["fanout::trips"].string_value().startswith("examples/fanout.mojo#L")
    )
    # The line is the def's.
    var at = m["toy::days"].string_value()
    var line = Int(at[byte = at.find("#L").or_else(-1) + 2 :])
    var text: String
    with open("examples/toy.mojo", "r") as f:
        text = f.read()
    assert_true(text.split("\n")[line - 1].startswith("def days("))
    assert_true("= Pipeline[" in text.split("\n")[pl - 1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
