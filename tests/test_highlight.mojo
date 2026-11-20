"""The code-on-hover highlighter (`morca._internal.highlight`): what each run of
source is, and the HTML lines it makes."""

from std.testing import TestSuite, assert_equal, assert_true

from morca._internal.highlight import highlight, tokens


def _kinds(src: String) -> String:
    """`kind:text` for each coloured run, space-separated."""
    var out = String()
    var s = src.as_bytes()
    for t in tokens(src):
        if not t.kind:
            continue
        if out:
            out.write(" ")
        out.write(t.kind, ":", StringSpan(unsafe_from_utf8=s[t.start : t.end]))
    return out^


def test_keywords_and_names() raises:
    assert_equal(
        _kinds("def days(var x: Int) raises -> Int:"),
        "kw:def fn:days kw:var kw:raises",
    )
    assert_equal(_kinds("struct Point(Copyable):"), "kw:struct fn:Point")
    assert_equal(_kinds("comptime N = 4"), "kw:comptime num:4")
    assert_equal(
        _kinds("return self or None"), "kw:return const:self kw:or const:None"
    )
    # A keyword inside a word isn't one.
    assert_equal(_kinds("define = format"), "")


def test_strings() raises:
    assert_equal(_kinds('x = "a # b"  # c'), 'str:"a # b" com:# c')
    assert_equal(_kinds("s = 'it\\'s'"), "str:'it\\'s'")
    assert_equal(_kinds('"open'), 'str:"open')
    var doc = String('"""One.\n\nTwo "quoted".\n"""\nvar x = 1')
    assert_equal(_kinds(doc), 'str:"""One.\n\nTwo "quoted".\n""" kw:var num:1')


def test_numbers_and_decorators() raises:
    assert_equal(
        _kinds("1_000 0x1f 3.5e-2 x2"), "num:1_000 num:0x1f num:3.5e-2"
    )
    assert_equal(
        _kinds("@fieldwise_init\n@always_inline"),
        "dec:@fieldwise_init dec:@always_inline",
    )
    assert_equal(_kinds("a @ b"), "")


def test_lines_are_whole() raises:
    var lines = highlight(
        'def f():\n    """Doc\n    <b>"""\n    return 1  # one'
    )
    assert_equal(len(lines), 4)
    assert_equal(
        lines[0],
        (
            '<span class="hl hl--kw">def</span> <span class="hl'
            ' hl--fn">f</span>():'
        ),
    )
    # A docstring over two lines is a span on each, closed on each.
    assert_equal(
        lines[1], '    <span class="hl hl--str">&quot;&quot;&quot;Doc</span>'
    )
    assert_equal(
        lines[2],
        '<span class="hl hl--str">    &lt;b&gt;&quot;&quot;&quot;</span>',
    )
    assert_true(lines[3].endswith('<span class="hl hl--com"># one</span>'))


def test_covers_every_byte() raises:
    var src = String("def é(x):  # ünï\n    return 'ok' + 2\n")
    var at = 0
    for t in tokens(src):
        assert_equal(t.start, at)
        at = t.end
    assert_equal(at, src.byte_length())
    assert_equal(len(highlight(src)), 3)
    assert_equal(highlight("")[0], "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
