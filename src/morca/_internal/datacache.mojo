"""What the UI's data view (`morca._internal.dataread`) keeps on local disk
between reads (#478): files of a table that never change once written,
by their location (manifest lists and manifests), and what was worked out
from one snapshot (its partitions), by the table and the snapshot. A
snapshot is immutable, so neither goes stale; a table dropped and made
again writes new files under new names, and has a new uuid.

Each `morca_maintain data` is a process of its own, so without it every
page of a table read every manifest again from object storage.

| Variable | Default | |
|---|---|---|
| `MORCA_DATA_CACHE` | `$TMPDIR/morca-data-cache` | the directory; `off` for none |
| `MORCA_DATA_CACHE_MB` | 256 | what it keeps; the files used least recently go first |
| `MORCA_DATA_CACHE_MIN_FREE_MB` | 1 GB or 5% of the disk, the larger | the space it leaves free (#483) |

`$TMPDIR` is on a disk other services share, so the cache keeps out of
the way when it fills: below the free space it leaves, nothing more is
written and the cache shrinks, to half its limit or less, as far as it
takes to free that space again.

A file is written beside its name with plain syscalls (Mojo's file
writes abort the process on a full disk), its size checked and then
renamed onto its name, so a read running at the same time sees all of it
or nothing. Each file ends with its length and a hash of its bytes, and
one that doesn't match (truncated, or changed) is removed and read as a
miss. A file that can't be read or written is a miss, never an error; a
read that fails on what the cache gave it is read again without it
(`morca._internal.dataread`), the files it used removed.
"""

from std.ffi import c_int, external_call
from std.os import getenv, listdir, makedirs, remove, stat
from std.os.path import exists
from std.sys import CompilationTarget

comptime _MAGIC = "MDC1"
comptime _TRAILER = 20
"""`MDC1`, the data's length and its FNV-1a hash, each 8 bytes little-endian."""
comptime _GB = 1 << 30

comptime _FNV_OFFSET: UInt64 = 0xCBF29CE484222325
comptime _FNV_PRIME: UInt64 = 0x100000001B3


def _fnv64(s: String) -> UInt64:
    return _fnv64_bytes(s.as_bytes())


def _fnv64_bytes(b: Span[UInt8, _]) -> UInt64:
    var h = _FNV_OFFSET
    for i in range(len(b)):
        h = (h ^ UInt64(b[i])) * _FNV_PRIME
    return h


def _le(mut out: List[UInt8], v: UInt64):
    for k in range(8):
        out.append(UInt8((v >> UInt64(8 * k)) & 0xFF))


def _read_le(b: Span[UInt8, _], at: Int, n: Int) -> UInt64:
    var v: UInt64 = 0
    for k in range(n):
        v |= UInt64(b[at + k]) << UInt64(8 * k)
    return v


def _trailer(data: Span[UInt8, _]) -> List[UInt8]:
    var t = List[UInt8](capacity=_TRAILER)
    for c in _MAGIC.as_bytes():
        t.append(c)
    _le(t, UInt64(len(data)))
    _le(t, _fnv64_bytes(data))
    return t^


def checked(var file: List[UInt8]) -> Optional[List[UInt8]]:
    """A cache file's data, its trailer checked and taken off; nothing
    when it's truncated or its bytes changed."""
    var n = len(file) - _TRAILER
    if n < 0:
        return None
    var s = Span(file)
    for k in range(4):
        if s[n + k] != _MAGIC.as_bytes()[k]:
            return None
    if Int(_read_le(s, n + 4, 8)) != n:
        return None
    if _read_le(s, n + 12, 8) != _fnv64_bytes(s[:n]):
        return None
    file.shrink(n)
    return file^


def free_space(dir: String) -> Tuple[Int, Int]:
    """The bytes free to an unprivileged writer on `dir`'s filesystem, and
    its size; -1 and -1 when statvfs can't say. `struct statvfs` differs:
    glibc's counts are 64-bit (`f_blocks` at 16, `f_bavail` at 32), macOS's
    32-bit (at 16 and 24); `f_frsize` is at 8 on both."""
    var buf = List[UInt8](length=256, fill=0)
    var p = dir
    if (
        external_call["statvfs", c_int](p.as_c_string_span(), buf.unsafe_ptr())
        != 0
    ):
        return (-1, -1)
    var b = Span(buf)
    var frsize = Int(_read_le(b, 8, 8))
    comptime if CompilationTarget.is_macos():
        return (
            frsize * Int(_read_le(b, 24, 4)),
            frsize * Int(_read_le(b, 16, 4)),
        )
    else:
        return (
            frsize * Int(_read_le(b, 32, 8)),
            frsize * Int(_read_le(b, 16, 8)),
        )


def write_file(path: String, data: Span[UInt8, _]) -> Bool:
    """Writes `data` to `path` with creat/write/close, so a full disk is a
    False, not an abort as in Mojo's file writes; then checks the file
    holds all of it."""
    var p = path
    var fd = external_call["creat", c_int](p.as_c_string_span(), c_int(0o644))
    if fd < 0:
        return False
    var done = 0
    var ok = True
    var ptr = data.unsafe_ptr()
    while done < len(data):
        var n = external_call["write", Int](
            fd, ptr.unsafe_offset(done), len(data) - done
        )
        if n <= 0:
            ok = False
            break
        done += n
    if external_call["close", c_int](fd) != 0:
        ok = False
    if not ok:
        return False
    try:
        return Int(stat(path).st_size) == len(data)
    except:
        return False


def _hex(v: UInt64) -> String:
    var digits = "0123456789abcdef".as_bytes()
    var out = List[UInt8]()
    for k in range(16):
        out.append(digits[Int((v >> UInt64(60 - 4 * k)) & 15)])
    return String(from_utf8_lossy=Span(out))


def cache_name(key: String) -> String:
    """The file a key is kept in: a hash of the whole key, then the end of
    its last segment, in characters any filesystem takes."""
    var tail = String(key[byte = key.rfind("/") + 1 :])
    var safe = List[UInt8]()
    for b in tail.as_bytes():
        var ok = (
            (b >= 48 and b <= 57)
            or (b >= 65 and b <= 90)
            or (b >= 97 and b <= 122)
            or b == 45
            or b == 46
            or b == 95
        )
        safe.append(b if ok else 95)
    var start = max(0, len(safe) - 80)
    var t = String(from_utf8_lossy=Span(safe)[start:])
    return String(_hex(_fnv64(key)), "-", t)


struct DataCache(Movable):
    """The cache directory (the module doc), or none."""

    var dir: String
    """Empty when the cache is off."""
    var max_bytes: Int
    var min_free: Int
    """The free space to leave on its disk; -1 for the default (the
    module doc)."""
    var reading: Bool
    """False to fetch everything again (and still keep it)."""
    var used: List[String]
    """The keys `get` answered, for a read that failed on them to remove."""

    def __init__(out self, dir: String, max_bytes: Int, min_free: Int = -1):
        self.dir = String(dir.rstrip("/")) if dir else String()
        self.max_bytes = max_bytes
        self.min_free = min_free
        self.reading = True
        self.used = List[String]()

    @staticmethod
    def from_env() -> DataCache:
        var dir = String()
        var mb = 256.0
        var floor = -1.0
        try:
            dir = getenv("MORCA_DATA_CACHE")
            if not dir:
                dir = String(
                    getenv("TMPDIR", "/tmp").rstrip("/"), "/morca-data-cache"
                )
            var m = getenv("MORCA_DATA_CACHE_MB")
            if m:
                mb = Float64(m)
            var f = getenv("MORCA_DATA_CACHE_MIN_FREE_MB")
            if f:
                floor = Float64(f)
        except:
            pass
        if dir == "off" or mb <= 0:
            dir = String()
        return DataCache(
            dir,
            Int(mb * 1024 * 1024),
            Int(floor * 1024 * 1024) if floor >= 0 else -1,
        )

    def short(self, extra: Int = 0) -> Tuple[Bool, Int]:
        """Whether writing `extra` more bytes would leave its disk below
        the free space to keep, and by how much (0 if not, or unknown)."""
        var got = free_space(self.dir)
        if got[0] < 0:
            return (False, 0)
        var floor = self.min_free
        if floor < 0:
            floor = max(_GB, got[1] // 20)
        var over = floor - (got[0] - extra)
        return (over > 0, max(over, 0))

    def on(self) -> Bool:
        return Bool(self.dir)

    def _path(self, key: String) -> String:
        return String(self.dir, "/", cache_name(key))

    def get(mut self, key: String) -> Optional[List[UInt8]]:
        """The bytes kept for `key`, if any."""
        if not self.dir:
            return None
        if not self.reading:
            return None
        var p = self._path(key)
        var raw: List[UInt8]
        try:
            if not exists(p):
                return None
            with open(p, "r") as f:
                raw = f.read_bytes()
        except:
            return None
        var data = checked(raw^)
        if not data:
            self.drop(key)
            return None
        _touch(p)
        self.used.append(key)
        return data^

    def drop(self, key: String):
        """Removes what's kept for `key`, if anything."""
        if not self.dir:
            return
        try:
            remove(self._path(key))
        except:
            pass

    def get_text(mut self, key: String) -> Optional[String]:
        var got = self.get(key)
        if not got:
            return None
        return String(from_utf8_lossy=Span(got.value()))

    def put(mut self, key: String, data: Span[UInt8, _]):
        """Keeps `data` for `key`; does nothing if it can't."""
        if not self.dir or len(data) + _TRAILER > self.max_bytes:
            return
        if self.short(len(data) + _TRAILER)[0]:
            return
        var p = self._path(key)
        var tmp = String(p, ".", Int(external_call["getpid", c_int]()), ".tmp")
        var file = List[UInt8](capacity=len(data) + _TRAILER)
        file.extend(data)
        file.extend(Span(_trailer(data)))
        try:
            makedirs(self.dir, exist_ok=True)
        except:
            return
        if not write_file(tmp, Span(file)) or (
            external_call["rename", c_int](
                tmp.as_c_string_span(), p.as_c_string_span()
            )
            != 0
        ):
            try:
                remove(tmp)
            except:
                pass

    def put_text(mut self, key: String, text: String):
        self.put(key, text.as_bytes())

    def prune(self):
        """Removes the files used least recently until what's left is
        within `max_bytes`: after each read, so a lower limit applies at
        once. Below the free space to keep, to half of `max_bytes`, or
        less, as far as frees that space."""
        if not self.dir or not exists(self.dir):
            return
        try:
            var files = List[Tuple[Int, Int, String]]()
            var total = 0
            for name in listdir(self.dir):
                var p = String(self.dir, "/", name)
                try:
                    var s = stat(p)
                    var size = Int(s.st_size)
                    files.append((Int(s.st_mtimespec.tv_sec), size, p^))
                    total += size
                except:
                    pass
            var keep = self.max_bytes
            var low = self.short()
            if low[0]:
                keep = min(self.max_bytes // 2, max(0, total - low[1]))
            if total <= keep:
                return
            # Oldest first: a selection, since pruning is rare and the
            # directory holds what fits in max_bytes.
            var gone = List[Bool](length=len(files), fill=False)
            while total > keep:
                var oldest = -1
                for i in range(len(files)):
                    if not gone[i] and (
                        oldest < 0 or files[i][0] < files[oldest][0]
                    ):
                        oldest = i
                if oldest < 0:
                    break
                gone[oldest] = True
                total -= files[oldest][1]
                try:
                    remove(files[oldest][2])
                except:
                    pass
        except:
            pass


def _touch(path: String):
    """Marks `path` used now, for `prune`: utimes with no times sets them
    to now."""
    var p = path
    _ = external_call["utimes", c_int](p.as_c_string_span(), Int(0))
