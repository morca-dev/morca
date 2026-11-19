"""Answers to data reads that `morca ui` keeps, so asking again costs
nothing: a Data tab, `data.json` or `data.csv` at a named `?snapshot=`
(a snapshot never changes), asked by a visitor not logged in (with no
session cookie and no `Authorization` header, so the page is the same for
everyone who asks it).

| Variable | Default | |
|---|---|---|
| `MORCA_UI_DATA_CACHE_MB` | 64 | what the kept answers may hold, together; 0 keeps none |

A 200 is kept, and so is a 404 (a snapshot the table no longer has: the
ones crawlers ask for again and again). The least recently used go first
when a new one doesn't fit, and none is kept past `TTL_SECONDS`, so the
page around the data (its header, the nav) isn't stale for long. A kept
answer says so (`X-Morca-Cache: hit`); it counts toward the client's rate
(`morca._internal.web.limit`) but takes none of the data-read slots.

This is the UI's own; `morca_maintain data` keeps manifests on disk
(`MORCA_DATA_CACHE`, `MORCA_DATA_CACHE_MB`) apart from it.
"""

from std.ffi import external_call
from std.memory.alloc import unsafe_alloc
from std.os import getenv

from flare.http import Request, Response
from threads import Mutex

from morca._internal.html import query_param
from morca._internal.web.limit import exempt, is_data_read

comptime TTL_SECONDS = 600
comptime DEFAULT_MB = 64
comptime HIT_HEADER = "X-Morca-Cache"
comptime _KEPT_HEADERS = [
    "Content-Type",
    "Content-Disposition",
    "X-Morca-Rows",
    "X-Morca-Stopped",
    "Cache-Control",
]


def _now() -> Int:
    return Int(external_call["time", Int64](Int(0)))


def cache_bytes() -> Int:
    """`MORCA_UI_DATA_CACHE_MB`, in bytes; 0 is no cache."""
    var raw = getenv("MORCA_UI_DATA_CACHE_MB")
    if not raw:
        return DEFAULT_MB * 1024 * 1024
    try:
        var n = Int(raw)
        if n >= 0:
            return n * 1024 * 1024
    except:
        pass
    print(
        "morca ui: MORCA_UI_DATA_CACHE_MB isn't a count:",
        raw,
        "- using",
        DEFAULT_MB,
    )
    return DEFAULT_MB * 1024 * 1024


@fieldwise_init
struct Kept(Copyable, Movable):
    """One kept answer: its status, body and the headers that go with it."""

    var status: Int
    var body: List[UInt8]
    var names: List[String]
    var values: List[String]
    var made: Int
    """When it was kept (seconds)."""
    var used: Int
    """The cache's tick when it was last asked for."""

    def size(self, key: String) -> Int:
        var n = len(self.body) + key.byte_length() + 64
        for i in range(len(self.names)):
            n += self.names[i].byte_length() + self.values[i].byte_length()
        return n


struct DataCache(Movable):
    """The answers, least recently used dropped first past `max_bytes`."""

    var max_bytes: Int
    var bytes: Int
    var tick: Int
    var kept: Dict[String, Kept]

    def __init__(out self, max_bytes: Int):
        self.max_bytes = max_bytes
        self.bytes = 0
        self.tick = 0
        self.kept = Dict[String, Kept]()

    def get(mut self, key: String, now: Int) -> Optional[Kept]:
        if key not in self.kept:
            return None
        try:
            ref k = self.kept[key]
            if now - k.made > TTL_SECONDS:
                self._drop(key)
                return None
            self.tick += 1
            k.used = self.tick
            return k.copy()
        except:
            return None

    def put(mut self, key: String, var k: Kept):
        var size = k.size(key)
        if self.max_bytes <= 0 or size > self.max_bytes:
            return
        if key in self.kept:
            self._drop(key)
        while self.bytes + size > self.max_bytes and len(self.kept) > 0:
            self._drop(self._oldest())
        self.tick += 1
        k.used = self.tick
        self.bytes += size
        self.kept[key] = k^

    def _oldest(self) -> String:
        var best = String()
        var at = -1
        for e in self.kept.items():
            if at < 0 or e.value.used < at:
                at = e.value.used
                best = e.key
        return best^

    def _drop(mut self, key: String):
        try:
            var k = self.kept.pop(key)
            self.bytes -= k.size(key)
        except:
            pass


struct _Shared(Movable):
    var lock: Mutex
    var cache: DataCache

    def __init__(out self, max_bytes: Int) raises:
        self.lock = Mutex()
        self.cache = DataCache(max_bytes)


comptime _SharedPtr = Pointer[_Shared, MutUntrackedOrigin]


def _reason(status: Int) -> String:
    return String("OK") if status == 200 else String("Not Found")


def cache_key(req: Request, path: String) -> String:
    """What `req` is kept under, or empty if its answer isn't kept: a GET
    data read at a named snapshot by a visitor not logged in."""
    if req.method != "GET" or not is_data_read(req.url) or exempt(req, path):
        return String()
    var snap = query_param(req.url, "snapshot")
    if not snap:
        return String()
    try:
        _ = Int(snap)
    except:
        return String()
    var json = "application/json" in req.headers.get("Accept")
    return String(req.url, "\n", "json" if json else "html")


@fieldwise_init
struct CacheHandle(Copyable, ImplicitlyCopyable, Movable):
    """What a handler on any worker thread uses the cache with; the
    `ResponseCache` that gave it out must outlive it."""

    var shared: Int
    var on: Bool

    def get(self, key: String) -> Optional[Response]:
        if not self.on or not key:
            return None
        ref s = _SharedPtr(unsafe_from_address=self.shared)[]
        s.lock.lock()
        var k = s.cache.get(key, _now())
        s.lock.unlock()
        if not k:
            return None
        ref got = k.value()
        var resp = Response(
            status=got.status, reason=_reason(got.status), body=got.body.copy()
        )
        try:
            for i in range(len(got.names)):
                resp.headers.set(got.names[i], got.values[i])
            resp.headers.set(HIT_HEADER, "hit")
        except:
            pass
        return resp^

    def put(self, key: String, resp: Response):
        """Keeps `resp` under `key`, if it's a 200 or a 404 that sets no
        cookie."""
        if not self.on or not key:
            return
        if resp.status != 200 and resp.status != 404:
            return
        var names = List[String]()
        var values = List[String]()
        if resp.headers.get("Set-Cookie"):
            return
        for n in materialize[_KEPT_HEADERS]():
            var v = resp.headers.get(n)
            if v:
                names.append(String(n))
                values.append(v)
        var k = Kept(resp.status, resp.body.copy(), names^, values^, _now(), 0)
        ref s = _SharedPtr(unsafe_from_address=self.shared)[]
        s.lock.lock()
        s.cache.put(key, k^)
        s.lock.unlock()


struct ResponseCache(Movable):
    """The cache every `CacheHandle` it gives out shares; it must outlive
    the server whose handlers use them."""

    var _shared: Int
    var max_bytes: Int

    def __init__(out self) raises:
        self.max_bytes = cache_bytes()
        var p = unsafe_alloc[_Shared](1)
        p.unsafe_write(_Shared(self.max_bytes))
        self._shared = Int(p)

    def handle(self) -> CacheHandle:
        return CacheHandle(self._shared, self.max_bytes > 0)

    def __deinit__(deinit self):
        var p = _SharedPtr(unsafe_from_address=self._shared)
        p.unsafe_deinit_pointee()
        p.unsafe_free()
