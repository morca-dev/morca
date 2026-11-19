"""What one client may ask of `morca ui` (#544): a number of requests a
minute, and how many of the expensive data reads (a Data tab, `data.csv`,
`data.json`) it and everyone together may have running at once.

A data read runs `morca_maintain data` and takes a second or more (more
under load), and a worker thread waits for it, so a crawler that asks for
many at once holds up every page behind them. The cap keeps threads free
for the rest.

| Variable | Default | |
|---|---|---|
| `MORCA_UI_RATE` | 0 (off) | requests a client may send a minute; the Hetzner stack sets 120 |
| `MORCA_UI_DATA_READS` | half the workers, at least 1 | data reads running at once, for all clients |

A client is the address `morca._internal.web.auth.client` gives (behind a
proxy, the first of `X-Forwarded-For`). One over its rate is answered 429
with `Retry-After` (the seconds left of its minute); a data read past the
cap, or a second one from a client that has one running, 503 with
`Retry-After: 5`. Neither limit applies to `/healthz`, the stylesheet,
`/robots.txt` or the worker API, nor to a request with a session cookie or
an `Authorization` header: people logged in and scripts aren't counted.

The counts live in one table, behind a mutex, that every worker thread
shares; minutes that have ended are dropped from it as it grows.
"""

from std.ffi import external_call
from std.memory.alloc import unsafe_alloc
from std.os import getenv

from flare.http import Request, Response
from threads import Mutex

from morca._internal.auth import SESSION_COOKIE
from morca._internal.web.auth import client, cookie

comptime WINDOW_SECONDS = 60
comptime BUSY_RETRY_SECONDS = 5
comptime _PRUNE_AT = 4096
"""Clients in the table past which minutes that have ended are dropped
(at least; `ClientTable.prune_at`)."""


def _now() -> Int:
    return Int(external_call["time", Int64](Int(0)))


def _env_count(name: StringSlice, dflt: Int) -> Int:
    var raw = getenv(String(name))
    if not raw:
        return dflt
    try:
        var n = Int(raw)
        if n >= 0:
            return n
    except:
        pass
    print("morca ui:", name, "isn't a count:", raw, "- using", dflt)
    return dflt


def ui_rate() -> Int:
    """`MORCA_UI_RATE`: requests a client may send a minute; 0 is no limit."""
    return _env_count("MORCA_UI_RATE", 0)


def ui_data_reads(workers: Int) -> Int:
    """`MORCA_UI_DATA_READS`, or half of `workers` (at least 1)."""
    return max(1, _env_count("MORCA_UI_DATA_READS", max(1, workers // 2)))


def is_data_read(url: String) -> Bool:
    """Whether `url` asks for a data read: `/datasets/<name>?tab=data`,
    `/datasets/<name>/data.csv` or `/datasets/<name>/data.json`."""
    if not url.startswith("/datasets/"):
        return False
    var q = url.find("?")
    var path = String(url[byte=:q]) if q >= 0 else url
    if path.endswith("/data.csv") or path.endswith("/data.json"):
        return True
    if q < 0:
        return False
    for part in String(url[byte = q + 1 :]).split("&"):
        if part == "tab=data":
            return True
    return False


def exempt(req: Request, path: String) -> Bool:
    """Whether neither limit applies to `req` (the module doc)."""
    if (
        path == "/healthz"
        or path == "/robots.txt"
        or path.startswith("/static/")
        or path.startswith("/api/worker/")
    ):
        return True
    if req.headers.get("Authorization"):
        return True
    return Bool(cookie(req, SESSION_COOKIE))


@fieldwise_init
struct _Client(Copyable, Movable):
    var minute: Int
    """When its current minute started, in seconds since the epoch."""
    var count: Int
    """Requests it has sent in that minute."""
    var reads: Int
    """Data reads of its that are running."""


struct ClientTable(Movable):
    var lock: Mutex
    var clients: Dict[String, _Client]
    var reads: Int
    """Data reads running, for all clients."""
    var prune_at: Int
    """The number of clients at which the next prune runs: twice what the
    last one left, so a busy minute doesn't scan the table on every
    request."""

    def __init__(out self) raises:
        self.lock = Mutex()
        self.clients = Dict[String, _Client]()
        self.reads = 0
        self.prune_at = _PRUNE_AT


comptime ADMIT = 0
comptime TOO_MANY = 1
comptime BUSY = 2


@fieldwise_init
struct Verdict(Copyable, Movable):
    """What `admit` decided: `ADMIT`, or why not and when to come back."""

    var kind: Int
    var retry_after: Int


def _prune(mut t: ClientTable, now: Int):
    var stale = List[String]()
    for e in t.clients.items():
        if e.value.reads == 0 and now - e.value.minute >= WINDOW_SECONDS:
            stale.append(e.key)
    for k in stale:
        try:
            _ = t.clients.pop(k)
        except:
            pass


def admit(
    mut t: ClientTable,
    who: String,
    is_read: Bool,
    rate: Int,
    max_reads: Int,
    now: Int,
) -> Verdict:
    """Counts a request from `who` (a data read if `read`) and says whether
    it may go on. The caller holds `t.lock`; one admitted as a read must be
    given back with `release`."""
    if len(t.clients) >= t.prune_at:
        _prune(t, now)
        t.prune_at = max(_PRUNE_AT, 2 * len(t.clients))
    var c = t.clients.get(who, _Client(now, 0, 0))
    if now - c.minute >= WINDOW_SECONDS:
        c.minute = now
        c.count = 0
    c.count += 1
    if rate > 0 and c.count > rate:
        var left = max(1, WINDOW_SECONDS - (now - c.minute))
        t.clients[who] = c^
        return Verdict(TOO_MANY, left)
    if is_read:
        if c.reads >= 1 or t.reads >= max_reads:
            t.clients[who] = c^
            return Verdict(BUSY, BUSY_RETRY_SECONDS)
        c.reads += 1
        t.reads += 1
    t.clients[who] = c^
    return Verdict(ADMIT, 0)


def release(mut t: ClientTable, who: String):
    """Gives back a data read `admit` let `who` start. The caller holds
    `t.lock`."""
    t.reads = max(0, t.reads - 1)
    try:
        var c = t.clients[who].copy()
        c.reads = max(0, c.reads - 1)
        t.clients[who] = c^
    except:
        pass


def _refusal(v: Verdict) -> Response:
    var status = 429 if v.kind == TOO_MANY else 503
    var body = String(
        "too many requests: try again in ",
        v.retry_after,
        " s\n",
    ) if v.kind == TOO_MANY else String(
        "the data views are busy: try again in ",
        v.retry_after,
        " s\n",
    )
    var resp = Response(
        status=status,
        reason="Too Many Requests" if v.kind
        == TOO_MANY else "Service Unavailable",
        body=List[UInt8](body.as_bytes()),
    )
    try:
        resp.headers.set("Content-Type", "text/plain; charset=utf-8")
        resp.headers.set("Retry-After", String(v.retry_after))
        resp.headers.set("Cache-Control", "no-store")
    except:
        pass
    return resp^


comptime _TablePtr = Pointer[ClientTable, MutUntrackedOrigin]


@fieldwise_init
struct Gate(Copyable, ImplicitlyCopyable, Movable):
    """What a handler on any worker thread checks the limits with: the
    `Limits`' table, which must outlive it, and the limits."""

    var table: Int
    var rate: Int
    var max_reads: Int

    def check(self, req: Request, path: String) -> Optional[Response]:
        """The refusal for `req`, or None if it may go on. One that goes on
        as a data read (`is_data_read`) must be given back with `done`."""
        if exempt(req, path):
            return None
        ref t = _TablePtr(unsafe_from_address=self.table)[]
        t.lock.lock()
        var v = admit(
            t,
            client(req),
            is_data_read(req.url),
            self.rate,
            self.max_reads,
            _now(),
        )
        t.lock.unlock()
        if v.kind != ADMIT:
            return _refusal(v)
        return None

    def done(self, req: Request, path: String):
        """Gives back the data read `check` let `req` start, if it was one."""
        if exempt(req, path) or not is_data_read(req.url):
            return
        ref t = _TablePtr(unsafe_from_address=self.table)[]
        t.lock.lock()
        release(t, client(req))
        t.lock.unlock()


struct Limits(Movable):
    """The table every `Gate` it gives out shares; it must outlive the
    server whose handlers use them."""

    var _table: Int
    var rate: Int
    var max_reads: Int

    def __init__(out self, workers: Int) raises:
        var p = unsafe_alloc[ClientTable](1)
        p.unsafe_write(ClientTable())
        self._table = Int(p)
        self.rate = ui_rate()
        self.max_reads = ui_data_reads(workers)

    def gate(self) -> Gate:
        return Gate(self._table, self.rate, self.max_reads)

    def __deinit__(deinit self):
        # The server that used the table has stopped.
        var p = _TablePtr(unsafe_from_address=self._table)
        p.unsafe_deinit_pointee()
        p.unsafe_free()
