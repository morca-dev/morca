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

A file is written beside its name and renamed onto it, so a read running
at the same time sees all of it or nothing. A file that can't be read or
written is a miss, never an error.
"""

from std.ffi import c_int, external_call
from std.os import getenv, listdir, makedirs, remove, stat
from std.os.path import exists

comptime _FNV_OFFSET: UInt64 = 0xCBF29CE484222325
comptime _FNV_PRIME: UInt64 = 0x100000001B3


def _fnv64(s: String) -> UInt64:
    var h = _FNV_OFFSET
    for b in s.as_bytes():
        h = (h ^ UInt64(b)) * _FNV_PRIME
    return h


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

    def __init__(out self, dir: String, max_bytes: Int):
        self.dir = String(dir.rstrip("/")) if dir else String()
        self.max_bytes = max_bytes

    @staticmethod
    def from_env() -> DataCache:
        var dir = String()
        var mb = 256.0
        try:
            dir = getenv("MORCA_DATA_CACHE")
            if not dir:
                dir = String(
                    getenv("TMPDIR", "/tmp").rstrip("/"), "/morca-data-cache"
                )
            var m = getenv("MORCA_DATA_CACHE_MB")
            if m:
                mb = Float64(m)
        except:
            pass
        if dir == "off" or mb <= 0:
            dir = String()
        return DataCache(dir, Int(mb * 1024 * 1024))

    def on(self) -> Bool:
        return Bool(self.dir)

    def _path(self, key: String) -> String:
        return String(self.dir, "/", cache_name(key))

    def get(self, key: String) -> Optional[List[UInt8]]:
        """The bytes kept for `key`, if any."""
        if not self.dir:
            return None
        var p = self._path(key)
        try:
            if not exists(p):
                return None
            var data: List[UInt8]
            with open(p, "r") as f:
                data = f.read_bytes()
            _touch(p)
            return data^
        except:
            return None

    def get_text(self, key: String) -> Optional[String]:
        var got = self.get(key)
        if not got:
            return None
        return String(from_utf8_lossy=Span(got.value()))

    def put(mut self, key: String, data: Span[UInt8, _]):
        """Keeps `data` for `key`; does nothing if it can't."""
        if not self.dir or len(data) > self.max_bytes:
            return
        var p = self._path(key)
        var tmp = String(p, ".", Int(external_call["getpid", c_int]()), ".tmp")
        try:
            makedirs(self.dir, exist_ok=True)
            with open(tmp, "w") as f:
                f.write_bytes(data)
            if (
                external_call["rename", c_int](
                    tmp.as_c_string_span(), p.as_c_string_span()
                )
                != 0
            ):
                remove(tmp)
        except:
            try:
                remove(tmp)
            except:
                pass

    def put_text(mut self, key: String, text: String):
        self.put(key, text.as_bytes())

    def prune(self):
        """Removes the files used least recently until what's left is
        within `max_bytes`: after each read, so a lower limit applies at
        once."""
        if not self.dir:
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
            if total <= self.max_bytes:
                return
            # Oldest first: a selection, since pruning is rare and the
            # directory holds what fits in max_bytes.
            var gone = List[Bool](length=len(files), fill=False)
            while total > self.max_bytes:
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
