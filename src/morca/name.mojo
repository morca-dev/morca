"""`Name`: the partition key of a keyed pipeline (`morca.keyed`).

A name is 1 to 128 bytes of `[A-Za-z0-9._:/-]` without two dots in a row,
such as a log's UUID or a repository's `owner/name`. A `/` separates
segments, so a name doesn't start or end with one or have two in a row.
Neither a comma nor `..` can appear in one, so a list of names on the
command line or in `runs.partitions` reads back unambiguously. Names order
by their bytes. A name has no next or previous name and falls in no date:
it's a `Key` but not a `TimeKey`.

Wherever a name becomes one segment of a path or a URL (an attempt's log,
`/pipelines/<name>/keys/<key>`), it goes through `path_segment`, which
writes `/` as `%2F`; no other byte of a name needs escaping.
"""

from morca.key import Key

comptime MAX_NAME = 128


def _name_byte(b: Byte) -> Bool:
    return (
        (b >= UInt8(ord("a")) and b <= UInt8(ord("z")))
        or (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
        or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
        or b == UInt8(ord("."))
        or b == UInt8(ord("_"))
        or b == UInt8(ord(":"))
        or b == UInt8(ord("-"))
        or b == UInt8(ord("/"))
    )


comptime _NAME_BYTES = "A-Z a-z 0-9 . _ : - /"


def path_segment(name: StringSpan) -> String:
    """`name` as one segment of a path: each `/` written `%2F`. A name holds
    no `%`, so this can't collide with another name."""
    return String(name).replace("/", "%2F")


struct Name(Key):
    var text: String

    def __init__(out self, var text: String):
        """A name already checked; `parse` checks one."""
        self.text = text^

    @staticmethod
    def parse(s: StringSpan) raises -> Name:
        var b = s.as_bytes()
        if len(b) == 0 or len(b) > MAX_NAME:
            raise Error(
                "not a name (1 to ",
                MAX_NAME,
                " bytes of ",
                _NAME_BYTES,
                "): '",
                s,
                "'",
            )
        comptime dot = UInt8(ord("."))
        comptime slash = UInt8(ord("/"))
        for i in range(len(b)):
            if not _name_byte(b[i]) or (
                i > 0 and b[i] == dot and b[i - 1] == dot
            ):
                raise Error(
                    "not a name (1 to ",
                    MAX_NAME,
                    " bytes of ",
                    _NAME_BYTES,
                    ", no '..'): '",
                    s,
                    "'",
                )
            if b[i] == slash and (
                i == 0 or i == len(b) - 1 or b[i - 1] == slash
            ):
                raise Error(
                    "not a name (a '/' only between other bytes, one at a",
                    " time): '",
                    s,
                    "'",
                )
        return Name(String(s))

    def __eq__(self, other: Self) -> Bool:
        return self.text == other.text

    def __lt__(self, other: Self) -> Bool:
        return self.text < other.text

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.text)


def parse_names(s: StringSpan) raises -> List[Name]:
    """A comma-separated list of names, each once. A range is refused."""
    if ".." in s:
        raise Error(
            "keyed partitions take a list of names, not a range: '", s, "'"
        )
    var out = List[Name]()
    var seen = Dict[String, Bool]()
    for part in s.split(","):
        var n = Name.parse(part.strip())
        if n.text in seen:
            raise Error(n, " given twice")
        seen[n.text] = True
        out.append(n^)
    return out^


def sort_texts(mut l: List[String]):
    """Sorts `l` in place, by bytes: a merge sort, as there can be thousands
    of keys."""
    if len(l) < 2:
        return
    var tmp = l.copy()
    var width = 1
    var n = len(l)
    while width < n:
        var i = 0
        while i < n:
            var mid = min(i + width, n)
            var hi = min(i + 2 * width, n)
            var a = i
            var b = mid
            var k = i
            while k < hi:
                if b >= hi or (a < mid and not (l[b] < l[a])):
                    tmp[k] = l[a]
                    a += 1
                else:
                    tmp[k] = l[b]
                    b += 1
                k += 1
            i += 2 * width
        for k in range(n):
            l[k] = tmp[k]
        width *= 2
