"""A dataset's current snapshot, read from its table's metadata file
without iceberg, for `<binary> sense`.

A dataset `ns.table` is the filesystem catalog's table at
`<MORCA_WAREHOUSE>/ns/table`, as in `morca.tables`. Its current metadata file
is the one `metadata/version-hint.text` names, or else the highest version
under `metadata/`, ties broken by `last-updated-ms`, as iceberg's catalog
finds it. Of that file, `current_snapshot` reads the current snapshot's ID
and two properties of its summary: whether a morca step made it
(`orca.run`), and the partition keys it holds (`orca.partitions`), which a
writer that isn't morca can set too.

The warehouse is a directory or a location in object storage
(`s3://bucket/warehouse`), listed and read through objectstore's
`FileIOResolver`, from the `AWS_*` environment.

morca's pipelines import iceberg only if they use tables, and every binary
answers `sense`, so this reads the JSON itself: just enough of it to walk
objects and arrays to the fields it needs.
"""

from std.os import listdir
from std.os.path import exists

from objectstore.fileio import FileIOResolver


@fieldwise_init
struct Sensed(Copyable, Movable):
    """A dataset's current snapshot, as `sense` prints it."""

    var dataset: String
    var snapshot: Int64
    """-1 when the table doesn't exist or has no snapshot."""
    var by_morca: Bool
    """Whether a morca step committed the snapshot."""
    var partitions: String
    """The snapshot summary's `orca.partitions`, or empty."""


def current_snapshot(warehouse: String, dataset: String) raises -> Sensed:
    """The dataset's current snapshot in the warehouse at `warehouse`."""
    var dot = dataset.rfind(".").or_else(-1)
    if dot <= 0 or dot == dataset.byte_length() - 1:
        raise Error("morca: a dataset is named namespace.table, not ", dataset)
    var dir = String(
        warehouse.rstrip("/"),
        "/",
        dataset[byte=:dot],
        "/",
        dataset[byte = dot + 1 :],
        "/metadata",
    )
    var names = _names(dir)
    if len(names) == 0:
        return Sensed(dataset, -1, False, "")
    return current_of(dataset, _read(_latest(dir, names)))


def _remote(location: String) -> Bool:
    return "://" in location and not location.startswith("file://")


def _names(dir: String) raises -> List[String]:
    """The files in `dir`, by name; none if it doesn't exist."""
    if not _remote(dir):
        if not exists(dir):
            return List[String]()
        return listdir(dir)
    var prefix = String(dir, "/")
    var out = List[String]()
    for loc in FileIOResolver().list(prefix):
        if loc.startswith(prefix):
            var name = String(loc[byte = prefix.byte_length() :])
            if name and "/" not in name:
                out.append(name^)
    return out^


def _read(location: String) raises -> String:
    if _remote(location):
        return String(from_utf8_lossy=Span(FileIOResolver().read_all(location)))
    with open(location, "r") as f:
        return f.read()


def _latest(dir: String, names: List[String]) raises -> String:
    if "version-hint.text" in names:
        var v = String(_read(String(dir, "/version-hint.text")).strip())
        for name in [
            String("v", v, ".metadata.json"),
            String(v, ".metadata.json"),
        ]:
            if name in names:
                return String(dir, "/", name)
    var best = -1
    var best_updated = Int64(-1)
    var path = String()
    for name in names:
        var v = _version_of(name)
        if v < 0 or v < best:
            continue
        var p = String(dir, "/", name)
        var updated = Int64(-1)
        try:
            var t = _read(p)
            var b = t.as_bytes()
            var at = _field(b, _ws(b, 0), "last-updated-ms")
            if at >= 0:
                updated = Int64(Int(_scalar(b, at)))
        except:
            pass
        if v > best or updated > best_updated:
            best = v
            best_updated = updated
            path = p^
    if best < 0:
        raise Error("morca: no *.metadata.json under ", dir)
    return path^


def _version_of(name: String) -> Int:
    """The leading version of `v4.metadata.json` or `00004-<uuid>.metadata.json`,
    or -1."""
    if not name.endswith(".metadata.json"):
        return -1
    var b = name.as_bytes()
    var i = 1 if len(b) > 0 and b[0] == UInt8(ord("v")) else 0
    var v = 0
    var digits = 0
    while i < len(b) and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
        v = v * 10 + Int(b[i]) - ord("0")
        digits += 1
        i += 1
    return v if digits > 0 else -1


def current_of(dataset: String, text: String) raises -> Sensed:
    """The current snapshot a table metadata document names, and its
    summary's morca properties."""
    var b = text.as_bytes()
    var top = _ws(b, 0)
    var at = _field(b, top, "current-snapshot-id")
    if at < 0 or b[at] == UInt8(ord("n")):
        return Sensed(dataset, -1, False, "")
    var id = Int64(Int(_scalar(b, at)))
    if id < 0:
        return Sensed(dataset, -1, False, "")
    var snaps = _field(b, top, "snapshots")
    if snaps >= 0:
        for s in _elements(b, snaps):
            var sid = _field(b, s, "snapshot-id")
            if sid < 0 or Int64(Int(_scalar(b, sid))) != id:
                continue
            var summary = _field(b, s, "summary")
            if summary < 0:
                break
            var run = _field(b, summary, "orca.run")
            var keys = _field(b, summary, "orca.partitions")
            return Sensed(
                dataset,
                id,
                run >= 0,
                _string(b, keys)[0] if keys >= 0 else String(),
            )
    return Sensed(dataset, id, False, "")


# ── just enough JSON ─────────────────────────────────────────────────────────


def _ws(b: Span[Byte, _], i: Int) -> Int:
    var j = i
    while j < len(b) and (
        b[j] == UInt8(ord(" "))
        or b[j] == UInt8(ord("\n"))
        or b[j] == UInt8(ord("\r"))
        or b[j] == UInt8(ord("\t"))
    ):
        j += 1
    return j


def _bad(i: Int) -> Error:
    return Error("morca: bad table metadata JSON at byte ", i)


def _skip(b: Span[Byte, _], i: Int) raises -> Int:
    """The index after the value at `i`."""
    if i >= len(b):
        raise _bad(i)
    var c = b[i]
    if c == UInt8(ord('"')):
        return _string(b, i)[1]
    if c == UInt8(ord("{")) or c == UInt8(ord("[")):
        var depth = 0
        var j = i
        while j < len(b):
            var d = b[j]
            if d == UInt8(ord('"')):
                j = _string(b, j)[1]
                continue
            if d == UInt8(ord("{")) or d == UInt8(ord("[")):
                depth += 1
            elif d == UInt8(ord("}")) or d == UInt8(ord("]")):
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        raise _bad(i)
    var j = i
    while j < len(b) and not (
        b[j] == UInt8(ord(","))
        or b[j] == UInt8(ord("}"))
        or b[j] == UInt8(ord("]"))
        or b[j] == UInt8(ord(" "))
        or b[j] == UInt8(ord("\n"))
        or b[j] == UInt8(ord("\r"))
        or b[j] == UInt8(ord("\t"))
    ):
        j += 1
    if j == i:
        raise _bad(i)
    return j


def _scalar(b: Span[Byte, _], i: Int) raises -> String:
    """The text of the number or literal at `i`."""
    return String(from_utf8_lossy=b[i : _skip(b, i)])


def _hex(c: Byte, i: Int) raises -> Int:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return Int(c) - ord("a") + 10
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return Int(c) - ord("A") + 10
    raise _bad(i)


def _utf8(mut out: List[Byte], cp: Int):
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def _string(b: Span[Byte, _], i: Int) raises -> Tuple[String, Int]:
    """The string at `i`, unescaped, and the index after it."""
    if i >= len(b) or b[i] != UInt8(ord('"')):
        raise _bad(i)
    var out = List[Byte]()
    var j = i + 1
    while j < len(b):
        var c = b[j]
        if c == UInt8(ord('"')):
            return (String(from_utf8_lossy=Span(out)), j + 1)
        if c != UInt8(ord("\\")):
            out.append(c)
            j += 1
            continue
        if j + 1 >= len(b):
            break
        var e = b[j + 1]
        j += 2
        if e == UInt8(ord("n")):
            out.append(UInt8(ord("\n")))
        elif e == UInt8(ord("t")):
            out.append(UInt8(ord("\t")))
        elif e == UInt8(ord("r")):
            out.append(UInt8(ord("\r")))
        elif e == UInt8(ord("b")):
            out.append(UInt8(8))
        elif e == UInt8(ord("f")):
            out.append(UInt8(12))
        elif e == UInt8(ord("u")):
            if j + 4 > len(b):
                break
            var cp = 0
            for k in range(4):
                cp = cp * 16 + _hex(b[j + k], j + k)
            j += 4
            # A high surrogate and the low one after it are one code point.
            if (
                cp >= 0xD800
                and cp < 0xDC00
                and j + 6 <= len(b)
                and b[j] == UInt8(ord("\\"))
                and b[j + 1] == UInt8(ord("u"))
            ):
                var lo = 0
                for k in range(4):
                    lo = lo * 16 + _hex(b[j + 2 + k], j + 2 + k)
                if lo >= 0xDC00 and lo < 0xE000:
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    j += 6
            _utf8(out, cp)
        else:
            out.append(e)  # \" \\ \/
    raise _bad(i)


def _field(b: Span[Byte, _], obj: Int, key: StringSpan) raises -> Int:
    """Where the value of `key` in the object at `obj` starts, or -1."""
    if obj >= len(b) or b[obj] != UInt8(ord("{")):
        return -1
    var j = _ws(b, obj + 1)
    if j < len(b) and b[j] == UInt8(ord("}")):
        return -1
    while j < len(b):
        var k = _string(b, j)
        j = _ws(b, k[1])
        if j >= len(b) or b[j] != UInt8(ord(":")):
            raise _bad(j)
        j = _ws(b, j + 1)
        if j >= len(b):
            raise _bad(j)  # a key with no value (found by fuzz_metadata)
        if k[0] == key:
            return j
        j = _ws(b, _skip(b, j))
        if j < len(b) and b[j] == UInt8(ord(",")):
            j = _ws(b, j + 1)
            continue
        if j < len(b) and b[j] == UInt8(ord("}")):
            return -1
        raise _bad(j)
    raise _bad(obj)


def _elements(b: Span[Byte, _], arr: Int) raises -> List[Int]:
    """Where each element of the array at `arr` starts."""
    var out = List[Int]()
    if arr >= len(b) or b[arr] != UInt8(ord("[")):
        return out^
    var j = _ws(b, arr + 1)
    if j < len(b) and b[j] == UInt8(ord("]")):
        return out^
    while j < len(b):
        out.append(j)
        j = _ws(b, _skip(b, j))
        if j < len(b) and b[j] == UInt8(ord(",")):
            j = _ws(b, j + 1)
            continue
        if j < len(b) and b[j] == UInt8(ord("]")):
            return out^
        raise _bad(j)
    raise _bad(arr)
