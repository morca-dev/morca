"""The TOML that `morca.toml` is written in (`morca._internal.config`): a parser and a
writer for the subset a configuration file needs.

    var doc = parse_toml(text)          # raises "<line>: <why>" on bad input
    doc.get(["pipelines", "gharchive", "workers"])   # Optional[TomlValue]
    doc.tables(["pipelines"])           # the tables directly under it

Supported, as TOML 1.0 has them: comments, `[table]` headers with bare,
quoted and dotted keys, `key = value` with dotted keys, basic strings (with
every escape) and literal strings, integers (decimal, with `_` between
digits), floats, booleans, arrays of those (over several lines, with
comments and a trailing comma), inline tables, nested, and arrays of inline
tables, inline (`machines = [{ type = "cax31", wait = 600 }, ...]`) or as
`[[x]]` headers, nested too (`[[version.step]]` adds to the last
`[[version]]`). A key or table
defined twice, a dotted key extending a table a header defined, and a header
reopening an inline table are refused, as TOML refuses them. Not supported,
each refused with a message saying so: multi-line strings, dates and times, hexadecimal, octal and binary integers,
`inf` and `nan`, arrays of arrays, arrays mixing tables with other values,
and keys holding control characters.

The document is flat: an entry per table and per value, in the order the
file has them, each with its whole key path, so a reader looks values up by
path and a new key needs no new type. An array of tables is an `ARRAY`
entry whose items are its elements' indices, of kind `TABLE`, and each
element a table at the array's path and its index: `machines.0.type`. mojoshelf's `mojo-toml` is built for
Mojo before 1.0, which is why morca has its own.
"""

comptime STRING = "string"
comptime INTEGER = "integer"
comptime FLOAT = "float"
comptime BOOLEAN = "boolean"
comptime ARRAY = "array"
comptime TABLE = "table"

comptime _SEP = "\x1f"
"""Between a path's keys in `TomlDoc`'s index; no key may hold it."""

# How a table came to be, for TOML's rules on defining one twice.
comptime _IMPLICIT = 0
"""Only as the parent of a header's table, `[a]` of `[a.b]`."""
comptime _HEADER = 1
comptime _DOTTED = 2
"""By a dotted key, `a.b = 1` making `a`."""
comptime _INLINE = 3
"""An inline table, or one inside it: closed once it ends."""
comptime _ARRAY_HEADER = 4
"""An array of tables made by `[[x]]` headers, which more of them extend."""


@fieldwise_init
struct TomlValue(Copyable, Movable, Writable):
    """One value: its kind (`STRING`, `INTEGER`, `FLOAT`, `BOOLEAN`, `ARRAY`
    or `TABLE`) and its text: a string's contents, a number as written
    without its `_`s, `true` or `false`; an array's elements are `items`,
    each scalar, with their kinds in `item_kinds`."""

    var kind: String
    var text: String
    var items: List[String]
    var item_kinds: List[String]
    var line: Int
    """The line it was defined on, from 1."""

    def as_int(self) raises -> Int:
        if self.kind != INTEGER:
            raise Error("is ", self.kind, ", not an integer")
        return Int(self.text)

    def write_to(self, mut writer: Some[Writer]):
        """The value as TOML."""
        if self.kind == STRING:
            writer.write(toml_string(self.text))
        elif self.kind == ARRAY:
            writer.write("[")
            for i in range(len(self.items)):
                writer.write(", " if i > 0 else "")
                if self.item_kinds[i] == STRING:
                    writer.write(toml_string(self.items[i]))
                else:
                    writer.write(self.items[i])
            writer.write("]")
        elif self.kind == TABLE:
            writer.write("{}")
        else:
            writer.write(self.text)


@fieldwise_init
struct TomlEntry(Copyable, Movable):
    var path: List[String]
    var value: TomlValue
    var how: Int
    """For a table, how it was made (`_HEADER` and the rest)."""


def _join(path: List[String]) -> String:
    var out = String()
    for i in range(len(path)):
        out.write(_SEP if i > 0 else "", path[i])
    return out^


struct TomlDoc(Movable):
    """A parsed document: its tables and values, in the file's order."""

    var entries: List[TomlEntry]
    var _index: Dict[String, Int]

    def __init__(out self):
        self.entries = List[TomlEntry]()
        self._index = Dict[String, Int]()

    def find(self, path: List[String]) -> Int:
        """The entry at `path`'s index, or -1."""
        return self._index.get(_join(path), -1)

    def get(self, path: List[String]) -> Optional[TomlValue]:
        var i = self.find(path)
        if i < 0:
            return None
        return self.entries[i].value.copy()

    def has_table(self, path: List[String]) -> Bool:
        var i = self.find(path)
        return i >= 0 and self.entries[i].value.kind == TABLE

    def keys(self, table: List[String]) -> List[String]:
        """The keys directly under `table` (`[]` for the root), tables and
        values, in the order they were first defined."""
        var out = List[String]()
        var n = len(table)
        for e in self.entries:
            if len(e.path) != n + 1:
                continue
            var under = True
            for k in range(n):
                if e.path[k] != table[k]:
                    under = False
                    break
            if under:
                out.append(e.path[n])
        return out^

    def tables(self, table: List[String]) -> List[String]:
        """The tables directly under `table`, in order."""
        var out = List[String]()
        for k in self.keys(table):
            var p = table.copy()
            p.append(k)
            if self.has_table(p):
                out.append(k)
        return out^

    def _add(mut self, var path: List[String], var value: TomlValue, how: Int):
        self._index[_join(path)] = len(self.entries)
        self.entries.append(TomlEntry(path^, value^, how))

    def dump(self) -> String:
        """The document as TOML, every value under its whole dotted key and
        every table with nothing in it as `{}`: what `parse_toml` reads back
        to the same entries (`fuzz/fuzz_toml.mojo` checks it)."""
        var out = String()
        for e in self.entries:
            if e.value.kind == TABLE and len(self.keys(e.path)) > 0:
                continue
            if self._in_table_array(e.path):
                continue
            for k in range(len(e.path)):
                out.write("." if k > 0 else "", toml_key(e.path[k]))
            out.write(" = ", self._value(e.path, e.value), "\n")
        return out^

    def is_table_array(self, v: TomlValue) -> Bool:
        """Whether `v` is an array of tables (`machines.0`, ...)."""
        return (
            v.kind == ARRAY
            and len(v.item_kinds) > 0
            and v.item_kinds[0] == TABLE
        )

    def _in_table_array(self, path: List[String]) -> Bool:
        """Whether `path` is inside an element of an array of tables."""
        for n in range(1, len(path)):
            var v = self.get(List[String](path[:n]))
            if v and self.is_table_array(v.value()):
                return True
        return False

    def _value(self, path: List[String], v: TomlValue) -> String:
        """`v`, at `path`, as TOML: an array of tables or a table as inline
        ones, from their entries."""
        if self.is_table_array(v):
            var out = String("[")
            for i in range(len(v.items)):
                var p = path.copy()
                p.append(v.items[i])
                out.write(", " if i > 0 else "", self._inline(p))
            out.write("]")
            return out^
        if v.kind == TABLE:
            return self._inline(path)
        return String(v)

    def _inline(self, path: List[String]) -> String:
        """The table at `path` as an inline table."""
        var out = String("{")
        var first = True
        for k in self.keys(path):
            var p = path.copy()
            p.append(k)
            var v = self.get(p)
            if not v:
                continue
            out.write("" if first else ",", " ", toml_key(k), " = ")
            out.write(self._value(p, v.value()))
            first = False
        out.write(" }" if not first else "}")
        return out^

    def is_inline(self, path: List[String]) -> Bool:
        """Whether the table at `path` was written inline, `{ ... }`."""
        var i = self.find(path)
        return i >= 0 and self.entries[i].how == _INLINE

    def merge(mut self, over: TomlDoc) -> List[List[String]]:
        """`over` laid on this document, as a stack's overlay on a project's
        file: a value of `over` replaces the one at its path (and a table
        or an array there, with all under it), and a table is merged key by
        key, so what `over` leaves out keeps its value. Returns the paths
        `over` set: its values, and its tables this document hadn't."""
        var set = List[List[String]]()
        for e in over.entries:
            var i = self.find(e.path)
            if (
                i >= 0
                and e.value.kind == TABLE
                and self.entries[i].value.kind == TABLE
            ):
                continue
            if i >= 0:
                self._drop_under(e.path)
                self.entries[self.find(e.path)] = e.copy()
            else:
                self._add(e.path.copy(), e.value.copy(), e.how)
            set.append(e.path.copy())
        return set^

    def _drop_under(mut self, path: List[String]):
        """Removes every entry under `path` (not `path`'s own)."""
        var kept = List[TomlEntry]()
        for e in self.entries:
            if not _within(e.path, path):
                kept.append(e.copy())
        self.entries = kept^
        self._index = Dict[String, Int]()
        for i in range(len(self.entries)):
            self._index[_join(self.entries[i].path)] = i

    def pretty(self, notes: Dict[String, String]) -> String:
        """The document as a person writes it: a `[table]` header for each
        table with values (or with nothing in it), each value under its own
        key, inline tables and arrays inline. A value whose path
        (`path_key`), or one under it, is in `notes` ends in `# <note>`."""
        var out = String()
        # Depth first, in the file's order: a stack of the tables to write.
        var todo = List[List[String]]()
        todo.append(List[String]())
        while len(todo) > 0:
            var path = todo.pop()
            var keys = self.keys(path)
            var header = len(path) > 0 and len(keys) == 0
            if header:
                out.write(
                    "\n" if out.byte_length() > 0 else "",
                    "[",
                    _dotted(path),
                    "]\n",
                )
            var tables = List[String]()
            for k in keys:
                var p = path.copy()
                p.append(k)
                var got = self.get(p)
                guard case .Some(v) = got else:
                    continue
                if v.kind == TABLE and not self.is_inline(p):
                    tables.append(k)
                    continue
                if len(path) > 0 and not header:
                    out.write(
                        "\n" if out.byte_length() > 0 else "",
                        "[",
                        _dotted(path),
                        "]\n",
                    )
                    header = True
                out.write(toml_key(k), " = ", self._value(p, v))
                var note = _note(p, notes)
                if note:
                    out.write("  # ", note)
                out.write("\n")
            for j in range(len(tables) - 1, -1, -1):
                var p = path.copy()
                p.append(tables[j])
                todo.append(p^)
        return out^


def path_key(path: List[String]) -> String:
    """`path` as one string, a key for a `Dict` of paths (`TomlDoc.pretty`'s
    notes)."""
    return _join(path)


def _within(path: List[String], prefix: List[String]) -> Bool:
    """Whether `path` is under `prefix`, and not `prefix` itself."""
    if len(path) <= len(prefix):
        return False
    for i in range(len(prefix)):
        if path[i] != prefix[i]:
            return False
    return True


def _note(path: List[String], notes: Dict[String, String]) -> String:
    """`notes`' note for `path`, or for the first path under it; empty if
    none."""
    var k = _join(path)
    var got = notes.get(k)
    if got:
        return got.value()
    for e in notes.items():
        if e.key.startswith(String(k, _SEP)):
            return e.value
    return ""


def toml_key(k: String) -> String:
    """`k` as a TOML key: bare if it can be, else a basic string."""
    if k.byte_length() == 0:
        return '""'
    for b in k.as_bytes():
        if not _bare(b):
            return toml_string(k)
    return k


def toml_string(s: String) -> String:
    """`s` as a TOML basic string, quotes included."""
    comptime digits = "0123456789ABCDEF"
    var out = String('"')
    for cp in s.codepoint_slices():
        if cp == '"':
            out.write('\\"')
        elif cp == "\\":
            out.write("\\\\")
        elif cp == "\n":
            out.write("\\n")
        elif cp == "\t":
            out.write("\\t")
        elif cp == "\r":
            out.write("\\r")
        elif cp.byte_length() == 1 and (
            Int(cp.as_bytes()[0]) < 0x20 or Int(cp.as_bytes()[0]) == 0x7F
        ):
            var b = Int(cp.as_bytes()[0])
            out.write("\\u00", digits[byte=b >> 4], digits[byte=b & 15])
        else:
            out.write(cp)
    out.write('"')
    return out^


def _bare(b: UInt8) -> Bool:
    var c = Int(b)
    return (
        (c >= ord("A") and c <= ord("Z"))
        or (c >= ord("a") and c <= ord("z"))
        or (c >= ord("0") and c <= ord("9"))
        or c == ord("_")
        or c == ord("-")
    )


def _utf8(cp: UInt32) -> String:
    """The UTF-8 bytes of the scalar value `cp`."""
    var b = List[UInt8]()
    if cp < 0x80:
        b.append(UInt8(cp))
    elif cp < 0x800:
        b.append(UInt8(0xC0 | (cp >> 6)))
        b.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        b.append(UInt8(0xE0 | (cp >> 12)))
        b.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        b.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        b.append(UInt8(0xF0 | (cp >> 18)))
        b.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        b.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        b.append(UInt8(0x80 | (cp & 0x3F)))
    return String(unsafe_from_utf8=Span(b))


struct _Parser(Movable):
    var src: List[UInt8]
    var pos: Int
    var line: Int
    var doc: TomlDoc

    def __init__(out self, text: String):
        self.src = List[UInt8](text.as_bytes())
        self.pos = 0
        self.line = 1
        self.doc = TomlDoc()
        # A UTF-8 byte order mark.
        if (
            len(self.src) >= 3
            and self.src[0] == 0xEF
            and self.src[1] == 0xBB
            and self.src[2] == 0xBF
        ):
            self.pos = 3

    def fail(self, msg: String) raises:
        raise Error(self.line, ": ", msg)

    def at_end(self) -> Bool:
        return self.pos >= len(self.src)

    def peek(self, ahead: Int = 0) -> Int:
        """The byte `ahead` from here, or -1 past the end."""
        if self.pos + ahead >= len(self.src):
            return -1
        return Int(self.src[self.pos + ahead])

    def skip_space(mut self):
        while self.peek() == ord(" ") or self.peek() == ord("\t"):
            self.pos += 1

    def skip_comment(mut self) raises:
        """A comment, if one starts here, to the end of its line."""
        if self.peek() != ord("#"):
            return
        while not self.at_end():
            var c = self.peek()
            if c == ord("\n") or (c == ord("\r") and self.peek(1) == ord("\n")):
                return
            if (c < 0x20 and c != ord("\t")) or c == 0x7F:
                self.fail("a control character in a comment")
            self.pos += 1

    def newline(mut self) raises -> Bool:
        """Takes a newline (LF or CRLF) if one is here."""
        if self.peek() == ord("\n"):
            self.pos += 1
            self.line += 1
            return True
        if self.peek() == ord("\r"):
            if self.peek(1) != ord("\n"):
                self.fail("a carriage return without a line feed")
            self.pos += 2
            self.line += 1
            return True
        return False

    def end_of_line(mut self) raises:
        """Spaces, maybe a comment, then the end of the line or file."""
        self.skip_space()
        self.skip_comment()
        if self.at_end():
            return
        if not self.newline():
            self.fail("expected the end of the line")

    def skip_blank(mut self) raises:
        """Spaces, comments and newlines, as between an array's elements."""
        while True:
            self.skip_space()
            self.skip_comment()
            if not self.newline():
                return

    def key(mut self) raises -> List[String]:
        """A key, dotted or not, with spaces around its dots."""
        var out = List[String]()
        while True:
            self.skip_space()
            var c = self.peek()
            var k: String
            if c == ord('"'):
                if self.peek(1) == ord('"') and self.peek(2) == ord('"'):
                    self.fail("multi-line strings aren't supported")
                k = self.basic_string()
            elif c == ord("'"):
                if self.peek(1) == ord("'") and self.peek(2) == ord("'"):
                    self.fail("multi-line strings aren't supported")
                k = self.literal_string()
            else:
                var start = self.pos
                while not self.at_end() and _bare(self.src[self.pos]):
                    self.pos += 1
                if self.pos == start:
                    self.fail("expected a key")
                k = String(unsafe_from_utf8=Span(self.src)[start : self.pos])
            for b in k.as_bytes():
                if b < 0x20 or b == 0x7F:
                    self.fail("a key with a control character")
            out.append(k^)
            self.skip_space()
            if self.peek() != ord("."):
                return out^
            self.pos += 1

    def hex(mut self, n: Int) raises -> UInt32:
        var v = UInt32(0)
        for _ in range(n):
            var c = self.peek()
            var d: Int
            if c >= ord("0") and c <= ord("9"):
                d = c - ord("0")
            elif c >= ord("a") and c <= ord("f"):
                d = c - ord("a") + 10
            elif c >= ord("A") and c <= ord("F"):
                d = c - ord("A") + 10
            else:
                self.fail("a \\u or \\U escape needs hex digits")
                return 0
            v = v * 16 + UInt32(d)
            self.pos += 1
        return v

    def basic_string(mut self) raises -> String:
        """A `"..."` string, from its opening quote."""
        self.pos += 1
        var out = String()
        var start = self.pos
        while True:
            if self.at_end():
                self.fail("a string without its closing quote")
            var c = self.peek()
            if c == ord('"'):
                out.write(
                    StringSpan(
                        unsafe_from_utf8=Span(self.src)[start : self.pos]
                    )
                )
                self.pos += 1
                return out^
            if c == ord("\\"):
                out.write(
                    StringSpan(
                        unsafe_from_utf8=Span(self.src)[start : self.pos]
                    )
                )
                self.pos += 1
                var e = self.peek()
                self.pos += 1
                if e == ord("b"):
                    out.write("\x08")
                elif e == ord("t"):
                    out.write("\t")
                elif e == ord("n"):
                    out.write("\n")
                elif e == ord("f"):
                    out.write("\x0c")
                elif e == ord("r"):
                    out.write("\r")
                elif e == ord('"'):
                    out.write('"')
                elif e == ord("\\"):
                    out.write("\\")
                elif e == ord("u") or e == ord("U"):
                    var cp = self.hex(4 if e == ord("u") else 8)
                    if cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
                        self.fail("an escape that isn't a Unicode scalar value")
                    out.write(_utf8(cp))
                else:
                    self.pos -= 1
                    self.fail("an unknown escape in a string")
                start = self.pos
                continue
            if c == ord("\n") or c == ord("\r"):
                self.fail("a string without its closing quote")
            if (c < 0x20 and c != ord("\t")) or c == 0x7F:
                self.fail("a control character in a string")
            self.pos += 1

    def literal_string(mut self) raises -> String:
        """A `'...'` string, from its opening quote."""
        self.pos += 1
        var start = self.pos
        while True:
            if self.at_end():
                self.fail("a string without its closing quote")
            var c = self.peek()
            if c == ord("'"):
                var s = String(
                    unsafe_from_utf8=Span(self.src)[start : self.pos]
                )
                self.pos += 1
                return s^
            if c == ord("\n") or c == ord("\r"):
                self.fail("a string without its closing quote")
            if (c < 0x20 and c != ord("\t")) or c == 0x7F:
                self.fail("a control character in a string")
            self.pos += 1

    def number(mut self) raises -> TomlValue:
        """An integer or a float, decimal."""
        var line = self.line
        var text = String()
        var c = self.peek()
        if c == ord("+") or c == ord("-"):
            text.write(chr(c))
            self.pos += 1
        if self.peek() == ord("i") or self.peek() == ord("n"):
            self.fail("inf and nan aren't supported")
        if self.peek() == ord("0") and (
            self.peek(1) == ord("x")
            or self.peek(1) == ord("o")
            or self.peek(1) == ord("b")
        ):
            self.fail("hexadecimal, octal and binary integers aren't supported")
        var int_digits = self.digits(text)
        if int_digits == 0:
            self.fail("expected a value")
        if self.peek() == ord("-") or self.peek() == ord(":"):
            self.fail("dates and times aren't supported")
        if int_digits > 1 and text.as_bytes()[
            text.byte_length() - int_digits
        ] == UInt8(ord("0")):
            self.fail("a number with a leading zero")
        var kind = String(INTEGER)
        if self.peek() == ord("."):
            text.write(".")
            self.pos += 1
            if self.digits(text) == 0:
                self.fail("a float needs digits after its point")
            kind = FLOAT
        if self.peek() == ord("e") or self.peek() == ord("E"):
            text.write("e")
            self.pos += 1
            if self.peek() == ord("+") or self.peek() == ord("-"):
                text.write(chr(self.peek()))
                self.pos += 1
            if self.digits(text) == 0:
                self.fail("a float needs digits in its exponent")
            kind = FLOAT
        if kind == INTEGER:
            if int_digits > 18:
                self.fail("an integer too large")
        return TomlValue(kind^, text^, List[String](), List[String](), line)

    def digits(mut self, mut text: String) raises -> Int:
        """Digits, with single `_`s between them, onto `text`; how many."""
        var n = 0
        while True:
            var c = self.peek()
            if c >= ord("0") and c <= ord("9"):
                text.write(chr(c))
                n += 1
                self.pos += 1
            elif c == ord("_"):
                if n == 0 or not (
                    self.peek(1) >= ord("0") and self.peek(1) <= ord("9")
                ):
                    self.fail("an '_' must be between digits")
                self.pos += 1
            else:
                return n

    def scalar(mut self) raises -> TomlValue:
        """A value that isn't an array or an inline table."""
        var line = self.line
        var c = self.peek()
        if c == ord('"') or c == ord("'"):
            if self.peek(1) == c and self.peek(2) == c:
                self.fail("multi-line strings aren't supported")
            var s = (
                self.basic_string() if c == ord('"') else self.literal_string()
            )
            return TomlValue(STRING, s^, List[String](), List[String](), line)
        if self._word("true"):
            return TomlValue(
                BOOLEAN, "true", List[String](), List[String](), line
            )
        if self._word("false"):
            return TomlValue(
                BOOLEAN, "false", List[String](), List[String](), line
            )
        if c == ord("+") or c == ord("-") or (c >= ord("0") and c <= ord("9")):
            return self.number()
        if c == ord("i") or c == ord("n"):
            self.fail("inf and nan aren't supported")
        self.fail("expected a value")
        return TomlValue(STRING, "", List[String](), List[String](), line)

    def _word(mut self, w: StaticString) -> Bool:
        var b = w.as_bytes()
        for i in range(len(b)):
            if self.peek(i) != Int(b[i]):
                return False
        var after = self.peek(len(b))
        if after >= 0 and _bare(UInt8(after)):
            return False
        self.pos += len(b)
        return True

    def array(mut self) raises -> TomlValue:
        """An array of scalars, from its `[`."""
        var line = self.line
        self.pos += 1
        var items = List[String]()
        var kinds = List[String]()
        while True:
            self.skip_blank()
            if self.peek() == ord("]"):
                self.pos += 1
                break
            if self.at_end():
                self.fail("an array without its closing ']'")
            if self.peek() == ord("["):
                self.fail("arrays of arrays aren't supported")
            if self.peek() == ord("{"):
                self.fail("an array can't mix inline tables with other values")
            var v = self.scalar()
            items.append(v.text)
            kinds.append(v.kind)
            self.skip_blank()
            if self.peek() == ord(","):
                self.pos += 1
            elif self.peek() == ord("]"):
                self.pos += 1
                break
            elif self.at_end():
                self.fail("an array without its closing ']'")
            else:
                self.fail("expected ',' or ']' in an array")
        return TomlValue(ARRAY, "", items^, kinds^, line)

    def _tables_ahead(mut self) raises -> Bool:
        """Whether the array starting here holds inline tables: its first
        element, past blanks and comments, starts with `{`."""
        var pos = self.pos
        var line = self.line
        self.pos += 1
        self.skip_blank()
        var tables = self.peek() == ord("{")
        self.pos = pos
        self.line = line
        return tables

    def table_array(mut self, path: List[String], how: Int) raises:
        """An array of inline tables at `path`, from its `[`: the array's
        entry, then each element as a table at `path` and its index."""
        var at = len(self.doc.entries)
        self.doc._add(
            path.copy(),
            TomlValue(ARRAY, "", List[String](), List[String](), self.line),
            how,
        )
        self.pos += 1
        var n = 0
        while True:
            self.skip_blank()
            if self.peek() == ord("]"):
                self.pos += 1
                return
            if self.at_end():
                self.fail("an array without its closing ']'")
            if self.peek() != ord("{"):
                self.fail("an array can't mix inline tables with other values")
            var p = path.copy()
            p.append(String(n))
            self.inline_table(p)
            self.doc.entries[at].value.items.append(String(n))
            self.doc.entries[at].value.item_kinds.append(TABLE)
            n += 1
            self.skip_blank()
            if self.peek() == ord(","):
                self.pos += 1
            elif self.peek() == ord("]"):
                self.pos += 1
                return
            elif self.at_end():
                self.fail("an array without its closing ']'")
            else:
                self.fail("expected ',' or ']' in an array")

    def table_at(mut self, path: List[String], how: Int) raises:
        """Makes the tables above `path`'s last key that aren't there, as
        `how`, refusing a value or a closed table in the way."""
        for n in range(1, len(path)):
            var p = List[String](path[:n])
            var i = self.doc.find(p)
            if i < 0:
                self.doc._add(
                    p^,
                    TomlValue(
                        TABLE, "", List[String](), List[String](), self.line
                    ),
                    how,
                )
                continue
            ref e = self.doc.entries[i]
            if e.how == _ARRAY_HEADER:
                continue  # `[[x]]`'s array: the path goes on with an index
            if e.value.kind != TABLE:
                self.fail(String(_dotted(p), " is a value, not a table"))
            if e.how == _INLINE and how != _INLINE:
                self.fail(String(_dotted(p), " is an inline table, closed"))
            if how == _DOTTED and (e.how == _HEADER or e.how == _IMPLICIT):
                self.fail(
                    String(
                        _dotted(p),
                        " is a table a header defined; a dotted key can't add",
                        " to it",
                    )
                )

    def inline_table(mut self, path: List[String]) raises:
        """`{ k = v, ... }` at `path` (already checked free), from its `{`."""
        self.pos += 1
        self.doc._add(
            path.copy(),
            TomlValue(TABLE, "", List[String](), List[String](), self.line),
            _INLINE,
        )
        self.skip_space()
        if self.peek() == ord("}"):
            self.pos += 1
            return
        while True:
            var key = self.key()
            self.skip_space()
            if self.peek() != ord("="):
                self.fail("expected '=' after a key")
            self.pos += 1
            self.skip_space()
            self.pair(path, key, _INLINE)
            self.skip_space()
            if self.peek() == ord(","):
                self.pos += 1
                self.skip_space()
                if self.peek() == ord("}"):
                    self.fail("an inline table can't end with a comma")
                continue
            if self.peek() == ord("}"):
                self.pos += 1
                return
            self.fail("expected ',' or '}' in an inline table")

    def pair(mut self, base: List[String], key: List[String], how: Int) raises:
        """The value after `key =`, set in the table `base`."""
        self._parents(base, key, how)
        var path = base.copy()
        for k in key:
            path.append(k)
        if self.doc.find(path) >= 0:
            self.fail(String(_dotted(path), " is defined twice"))
        if self.peek() == ord("{"):
            self.inline_table(path)
            return
        if self.peek() == ord("[") and self._tables_ahead():
            self.table_array(path, how)
            return
        var v = self.array() if self.peek() == ord("[") else self.scalar()
        self.doc._add(path^, v^, how)

    def _parents(
        mut self, base: List[String], key: List[String], how: Int
    ) raises:
        """The tables a dotted `key` makes below `base`, before its last."""
        var path = base.copy()
        for k in key:
            path.append(k)
        for n in range(len(base) + 1, len(path)):
            var p = List[String](path[:n])
            var i = self.doc.find(p)
            if i < 0:
                self.doc._add(
                    p^,
                    TomlValue(
                        TABLE, "", List[String](), List[String](), self.line
                    ),
                    how,
                )
                continue
            ref e = self.doc.entries[i]
            if e.value.kind != TABLE:
                self.fail(String(_dotted(p), " is a value, not a table"))
            if e.how != how:
                self.fail(
                    String(
                        _dotted(p),
                        " is defined already; a dotted key can't add to it",
                    )
                )

    def array_header(mut self) raises -> List[String]:
        """`[[a.b]]`, from its `[[`: a new element of the array of tables
        `a.b`, which it opens. A key on the way that is an array of tables
        means its last element, as TOML has it: `[[version.step]]` adds a
        step to the last `[[version]]`."""
        self.pos += 2
        var path = self.key()
        if self.peek() != ord("]") or self.peek(1) != ord("]"):
            self.fail("expected ']]' after an array of tables' name")
        self.pos += 2
        var at = List[String]()
        for n in range(len(path) - 1):
            at.append(path[n])
            var i = self.doc.find(at)
            if i >= 0 and self.doc.entries[i].how == _ARRAY_HEADER:
                ref items = self.doc.entries[i].value.items
                at.append(items[len(items) - 1])
        at.append(path[len(path) - 1])
        self.table_at(at, _IMPLICIT)
        var i = self.doc.find(at)
        if i < 0:
            i = len(self.doc.entries)
            self.doc._add(
                at.copy(),
                TomlValue(ARRAY, "", List[String](), List[String](), self.line),
                _ARRAY_HEADER,
            )
        elif self.doc.entries[i].how != _ARRAY_HEADER:
            self.fail(
                String(
                    _dotted(at),
                    " is defined already, not as [[",
                    _dotted(path),
                    "]]",
                )
            )
        var n = String(len(self.doc.entries[i].value.items))
        self.doc.entries[i].value.items.append(n)
        self.doc.entries[i].value.item_kinds.append(TABLE)
        var el = at.copy()
        el.append(n)
        self.doc._add(
            el.copy(),
            TomlValue(TABLE, "", List[String](), List[String](), self.line),
            _HEADER,
        )
        return el^

    def header(mut self) raises -> List[String]:
        """`[a.b]`, from its `[`: the table it opens."""
        if self.peek(1) == ord("["):
            return self.array_header()
        self.pos += 1
        var path = self.key()
        if self.peek() != ord("]"):
            self.fail("expected ']' after a table's name")
        self.pos += 1
        self.table_at(path, _IMPLICIT)
        var i = self.doc.find(path)
        if i < 0:
            self.doc._add(
                path.copy(),
                TomlValue(TABLE, "", List[String](), List[String](), self.line),
                _HEADER,
            )
        else:
            ref e = self.doc.entries[i]
            if e.value.kind != TABLE:
                self.fail(String(_dotted(path), " is a value, not a table"))
            if e.how != _IMPLICIT:
                self.fail(
                    String("the table ", _dotted(path), " is defined twice")
                )
            e.how = _HEADER
            e.value.line = self.line
        return path^

    def finish(deinit self) -> TomlDoc:
        return self.doc^

    def document(mut self) raises:
        var table = List[String]()
        while True:
            self.skip_blank()
            if self.at_end():
                return
            if self.peek() == ord("["):
                table = self.header()
            else:
                var key = self.key()
                if self.peek() != ord("="):
                    self.fail("expected '=' after a key")
                self.pos += 1
                self.skip_space()
                self.pair(table, key, _DOTTED)
            self.end_of_line()


def _dotted(path: List[String]) -> String:
    var out = String()
    for i in range(len(path)):
        out.write("." if i > 0 else "", toml_key(path[i]))
    return out^


def parse_toml(text: String) raises -> TomlDoc:
    """`text` as a document; raises `<line>: <why>` if it isn't one this
    subset reads."""
    var p = _Parser(text)
    p.document()
    return p^.finish()
