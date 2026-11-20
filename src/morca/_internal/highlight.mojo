"""Mojo source coloured for the UI's code-on-hover (`_PEEK` in
`morca._internal.ui.layout`), on the server, with no library: `tokens` splits source
into runs of one kind, and `highlight` turns those into HTML lines with a
`<span>` per coloured run.

```
var lines = highlight(src)      # one HTML string per source line
```

The kinds, each a class `hl--<kind>` the stylesheet colours from its
tokens (so both themes have them):

| Kind | What |
|---|---|
| `kw` | a keyword: `def`, `struct`, `var`, `comptime`, `if`, `return`, ... |
| `str` | a string, `"..."`, `'...'` or triple-quoted over several lines |
| `com` | a comment, `#` to the end of the line |
| `num` | a number: `42`, `1_000`, `0x1f`, `3.5e-2` |
| `dec` | a decorator, `@fieldwise_init` |
| `fn` | the name a `def`, `fn`, `struct` or `trait` defines |
| `const` | `True`, `False`, `None`, `self`, `Self` |

Anything else is plain text. A string or comment never holds a span open
across a line: each line's HTML is whole, so the hover can show any slice
of them. It's a highlighter, not a parser: an unterminated string runs to
the end of its line (or, triple-quoted, of the file).
"""

from morca._internal.html import escape

comptime PLAIN = ""
comptime KEYWORD = "kw"
comptime STRING = "str"
comptime COMMENT = "com"
comptime NUMBER = "num"
comptime DECORATOR = "dec"
comptime NAME = "fn"
comptime CONSTANT = "const"

comptime _KEYWORDS: List[StaticString] = [
    "def",
    "fn",
    "struct",
    "trait",
    "var",
    "let",
    "comptime",
    "alias",
    "if",
    "elif",
    "else",
    "for",
    "while",
    "return",
    "raise",
    "raises",
    "try",
    "except",
    "finally",
    "with",
    "as",
    "import",
    "from",
    "in",
    "not",
    "and",
    "or",
    "is",
    "pass",
    "break",
    "continue",
    "mut",
    "out",
    "read",
    "ref",
    "deinit",
    "owned",
    "inout",
    "lambda",
    "yield",
    "del",
    "global",
    "nonlocal",
    "assert",
    "where",
    "async",
    "await",
]
comptime _CONSTANTS: List[StaticString] = [
    "True",
    "False",
    "None",
    "self",
    "Self",
]
comptime _DEFINES: List[StaticString] = ["def", "fn", "struct", "trait"]


@fieldwise_init
struct Token(Copyable, Movable):
    """A run of source of one kind: bytes `start` to `end`."""

    var kind: StaticString
    var start: Int
    var end: Int


def _ident_start(b: Int) -> Bool:
    return (
        (b >= ord("a") and b <= ord("z"))
        or (b >= ord("A") and b <= ord("Z"))
        or b == ord("_")
        or b >= 0x80
    )


def _ident(b: Int) -> Bool:
    return _ident_start(b) or (b >= ord("0") and b <= ord("9"))


def _digit(b: Int) -> Bool:
    return b >= ord("0") and b <= ord("9")


def _is_in[words: List[StaticString]](word: String) -> Bool:
    for w in materialize[words]():
        if word == w:
            return True
    return False


def _flush(mut out: List[Token], plain: Int, at: Int):
    """The plain text from `plain` to `at`, if there's any."""
    if at > plain:
        out.append(Token(PLAIN, plain, at))


def tokens(src: StringSpan) -> List[Token]:
    """`src` as runs of one kind each, in order, covering every byte."""
    var s = src.as_bytes()
    var n = len(s)
    var out = List[Token]()
    var i = 0
    var plain = 0  # where the plain text before the next token began
    var defining = False  # the last word was def, fn, struct or trait

    while i < n:
        var b = Int(s[i])
        var start = i
        var kind: StaticString
        if b == ord("#"):
            while i < n and Int(s[i]) != ord("\n"):
                i += 1
            kind = COMMENT
        elif b == ord('"') or b == ord("'"):
            var triple = i + 2 < n and Int(s[i + 1]) == b and Int(s[i + 2]) == b
            if triple:
                i += 3
                while i < n:
                    if (
                        Int(s[i]) == b
                        and i + 2 < n
                        and Int(s[i + 1]) == b
                        and Int(s[i + 2]) == b
                    ):
                        i += 3
                        break
                    if Int(s[i]) == ord("\\"):
                        i += 1
                    i += 1
                i = min(i, n)
            else:
                i += 1
                while i < n and Int(s[i]) != b and Int(s[i]) != ord("\n"):
                    if Int(s[i]) == ord("\\") and i + 1 < n:
                        i += 1
                    i += 1
                if i < n and Int(s[i]) == b:
                    i += 1
            kind = STRING
        elif b == ord("@") and i + 1 < n and _ident_start(Int(s[i + 1])):
            i += 1
            while i < n and (_ident(Int(s[i])) or Int(s[i]) == ord(".")):
                i += 1
            kind = DECORATOR
        elif _digit(b) and (i == 0 or not _ident(Int(s[i - 1]))):
            i += 1
            while i < n and (
                _ident(Int(s[i]))
                or Int(s[i]) == ord(".")
                or (
                    (Int(s[i]) == ord("-") or Int(s[i]) == ord("+"))
                    and (Int(s[i - 1]) == ord("e") or Int(s[i - 1]) == ord("E"))
                    and not (
                        Int(s[start + 1]) == ord("x")
                        or Int(s[start + 1]) == ord("X")
                    )
                )
            ):
                i += 1
            kind = NUMBER
        elif _ident_start(b):
            while i < n and _ident(Int(s[i])):
                i += 1
            var word = String(StringSpan(unsafe_from_utf8=s[start:i]))
            if defining:
                kind = NAME
                defining = False
            elif _is_in[_KEYWORDS](word):
                kind = KEYWORD
                defining = _is_in[_DEFINES](word)
            elif _is_in[_CONSTANTS](word):
                kind = CONSTANT
            else:
                kind = PLAIN
            if kind == PLAIN:
                continue
        else:
            i += 1
            continue
        _flush(out, plain, start)
        out.append(Token(kind, start, i))
        plain = i
    _flush(out, plain, n)
    return out^


def highlight(src: StringSpan) -> List[String]:
    """`src` as HTML, a string per line (split at `\\n`, without it), each
    coloured run a `<span class="hl hl--<kind>">`, everything escaped."""
    var s = src.as_bytes()
    var lines = List[String]()
    var line = String()
    for t in tokens(src):
        var a = t.start
        while a < t.end:
            var b = a
            while b < t.end and Int(s[b]) != ord("\n"):
                b += 1
            if b > a:
                var text = escape(StringSpan(unsafe_from_utf8=s[a:b]))
                if t.kind:
                    line.write(
                        '<span class="hl hl--', t.kind, '">', text, "</span>"
                    )
                else:
                    line.write(text)
            if b < t.end:
                lines.append(line^)
                line = String()
                b += 1
            a = b
    lines.append(line^)
    return lines^
