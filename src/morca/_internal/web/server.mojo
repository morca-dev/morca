"""`morca ui`'s server: one handler that looks each request up in the route
table (`morca._internal.web.routes`), checks who it's from (`morca._internal.web.auth`) and
answers it as its route's kind says.

```
MORCA_DATABASE_URL=postgresql:///morca ./build/morca ui     # 127.0.0.1:8270
```

A request goes through, in order:

1. The stylesheet, `/healthz` (200 once the database answers, without a
   login: what a deploy waits for before it retires the old UI; 503
   `draining` once a drain has started), and the
   worker API (`POST /api/worker/...`, `morca._internal.api.worker`, its own token),
   answered before anything else.
2. The route. A `POST` that's no action, or another method than `GET`,
   `HEAD` or `POST`, is 405.
3. A `POST` whose `Origin` (or `Referer`) isn't the UI's own is refused
   (403), unless it's a script's with no `Origin` (`morca._internal.web.auth`).
4. The database, per request; `/api/login` is answered here, before any
   token is looked at.
5. Who it's from: an API token or a session. A token that's no use is 401.
6. By the route's kind (`morca._internal.web.router`): logging in or out as the
   handler says; a page with who's logged in (or a way to log in) in its
   header; an action, once login is on only with a session, audited as its
   user's.

The UI holds no state: its actions are rows the scheduler acts on, and it
can run beside the scheduler or anywhere else that reaches the database.
`MORCA_UI_ADDR` (`host:port`) moves it; it binds to localhost unless told
otherwise. `MORCA_WORKER_ADDR` serves the worker API on a listener of its
own as well (`morca._internal.api.worker`). SIGTERM or SIGINT drains it: no new
connections, `/healthz` 503, the requests in flight answered, then exit 0 within
`MORCA_UI_DRAIN_SECONDS` (8; `morca._internal.web.drain`).

It answers on `MORCA_UI_WORKERS` threads (default 1; the Hetzner stack runs 4),
sharing one listening socket (flare's `FLARE_REUSEPORT_WORKERS=0`, unless
that's set), so a new connection goes to a thread that's free rather than
one a slow page holds up.
Each request but `/healthz` and the stylesheet is logged as one line: method,
path, status, milliseconds, the client (`client`), Cloudflare's
`CF-Connecting-IP` when there is one, and the User-Agent.
"""

from std.os import getenv, setenv
from std.time import perf_counter_ns

from flare.http import (
    Handler,
    HttpServer,
    Request,
    Response,
    ResponseImpl,
    ServerConfig,
)
from flare.net import SocketAddr
import morca._internal.db.health as health_db
from threads import AtomicFlag

from morca._internal.api import worker as worker_api
from morca._internal.auth import audit, login_required
from morca._internal.html import Html, query_param, url_encode
from morca._internal.json import quote
from morca._internal.state import State
from morca._internal.ui.coverage import COVERAGE_STYLE
from morca._internal.ui.data_chart import CHART_STYLE
from morca._internal.ui.layout import AUTH_SLOT, HERE_SLOT, USER_SLOT, page_html
from morca._internal.ui.errors import bad_request, not_found
from morca._internal.ui.style import STYLE
from morca._internal.ui.viz import VIZ_STYLE
from morca._internal.web.auth import (
    API_LOGIN,
    client,
    content_type,
    cross_origin,
    json_error,
    json_form,
    login_needed,
    same_origin,
    scripted,
    sign_in,
    token_refused,
)
from morca._internal.web.drain import Drain
from morca._internal.web.page import Page, respond
from morca._internal.web.router import (
    ACTION,
    AUTH,
    Call,
    PAGE,
    Route,
    answer,
    find,
)
from morca._internal.web.routes import routes

comptime DEFAULT_ADDR = "127.0.0.1:8270"
comptime STYLESHEET = "/static/morca.css"
comptime HEALTHZ = "/healthz"


def _path_of(url: String) -> String:
    var q = url.find("?")
    return String(url[byte=:q]) if q >= 0 else url


def _not_allowed() -> Response:
    var resp = Response(status=405, reason="Method Not Allowed")
    try:
        resp.headers.set("Allow", "GET, HEAD")
    except:
        pass
    return resp^


def _with_user(
    var page: Page,
    json: Bool,
    user: String,
    required: Bool,
    here: String = "/",
) -> Response:
    """The page, with who's logged in (or a way to log in, back to `here`)
    in its header."""
    var slot: String
    if user:
        var h = Html()
        h.raw('<span class="top__user">')
        h.text(user)
        h.raw(
            ' <form method="post" action="/logout"><button type="submit">',
            "Log out</button></form></span>",
        )
        slot = h^.finish()
    elif required:
        slot = String('<a class="top__user" href="/login">Log in</a>')
    else:
        slot = String()
    page.html = page.html.replace(USER_SLOT, slot)
    page.html = page.html.replace(
        String('<body class="', AUTH_SLOT, '">'),
        '<body class="anon">' if required and not user else "<body>",
    )
    page.html = page.html.replace(HERE_SLOT, url_encode(here))
    return respond(page, json)


def _run_of(location: String, path: String) -> Int:
    """The run an action made or acted on, from where it sent the browser or
    its own path; 0 for none."""
    for p in [location, path]:
        if p.startswith("/runs/"):
            var rest = p[byte=6:]
            var end = rest.find("/")
            try:
                return Int(rest[byte=:end] if end >= 0 else rest)
            except:
                pass
    return 0


def _error(e: Error, json: Bool) -> Response:
    """A 500: what went wrong, as the page or its JSON."""
    var h = Html()
    h.raw("<h1>Error</h1><pre>")
    h.text(e)
    h.raw("</pre>")
    var page = Page(
        500,
        String('{"error": ', quote(String(e)), "}"),
        page_html("Error", "", h),
    )
    var resp = respond(page, json)
    resp.reason = "Internal Server Error"
    return resp^


def _stylesheet() raises -> Response:
    """`/static/morca.css`: the pages' rules and the views'."""
    var resp = Response(
        status=200,
        reason="OK",
        body=List[UInt8](
            String(STYLE, VIZ_STYLE, COVERAGE_STYLE, CHART_STYLE).as_bytes()
        ),
    )
    resp.headers.set("Content-Type", "text/css; charset=utf-8")
    return resp^


def _healthz(url: String, draining: Bool) -> Response:
    """`/healthz`: 200 `ok` once the database answers a query, 503 if it
    doesn't, and 503 `draining` without asking it once SIGTERM or SIGINT
    has started a drain (`morca._internal.web.drain`), so a checker or proxy on a
    kept-alive connection stops sending requests here. No login, and
    nothing else in it: `morca-stack apply` waits for it before it stops the
    old UI (docs/hetzner.md#deploying-code)."""
    var status = 200
    var reason = String("OK")
    var body = String("ok\n")
    try:
        if draining:
            status = 503
            reason = String("Service Unavailable")
            body = String("draining\n")
        else:
            var db = State(url)
            health_db.ping(db.conn)
    except e:
        print("morca ui: /healthz: the database doesn't answer:", e)
        status = 503
        reason = String("Service Unavailable")
        body = String("the database doesn't answer\n")
    var resp = Response(
        status=status, reason=reason, body=List[UInt8](body.as_bytes())
    )
    try:
        resp.headers.set("Content-Type", "text/plain; charset=utf-8")
        resp.headers.set("Cache-Control", "no-store")
    except:
        pass
    return resp^


struct Ui(Copyable, Handler):
    """The pages, the API and the actions, over the database at `url`."""

    var url: String
    var table: List[Route]
    var draining: AtomicFlag
    """Set once a drain has started (`morca._internal.web.drain.Drain.draining`)."""

    def __init__(out self, url: String, draining: AtomicFlag):
        self.url = url
        self.table = routes()
        self.draining = draining

    def serve(self, req: Request) raises -> Response:
        var path = _path_of(req.url)
        var post = req.method == "POST"
        if path == STYLESHEET:
            return _stylesheet()
        if path == HEALTHZ and (req.method == "GET" or req.method == "HEAD"):
            return _healthz(self.url, self.draining.is_set())
        if post and path.startswith("/api/worker/"):
            return worker_api.worker_response(self.url, req)
        var found = find(self.table, req.method, path)
        var reading = req.method == "GET" or req.method == "HEAD"
        if not found.route and not (reading or (post and found.miss)):
            return _not_allowed()

        var by_script = scripted(req, path)
        var json = (
            "application/json" in req.headers.get("Accept")
            or query_param(req.url, "format") == "json"
            or by_script
            or path.startswith("/api/")
        )
        if (
            post
            and not (by_script and not req.headers.get("Origin"))
            and not same_origin(req)
        ):
            return respond(cross_origin(), json)
        if path == API_LOGIN and not by_script:
            return respond(json_error(400, "a login for a token is JSON"), True)

        try:
            var db = State(self.url)
            var call = Call(req.url, path)
            call.body = String(from_utf8_lossy=Span(req.body))
            call.form = call.body
            call.address = client(req)
            if path == API_LOGIN:
                return respond(found.route.value().handler(db, call), True)
            if not sign_in(db, req, call):
                return respond(token_refused(), True)
            var required = login_required(db)
            if post and content_type(req) == "application/json":
                # The site's own forms never post JSON: the command does.
                call.source = "cli"
                try:
                    call.form = json_form(call.body)
                except e:
                    return respond(bad_request(String(e)), json)

            if not found.route and post:
                # An action's path, but for a number that isn't one.
                if required and not call.user:
                    return login_needed(req, json)
                return respond(not_found(String("nothing at ", path)), json)
            if not found.route:
                var miss = found.miss if found.miss else String(
                    "nothing at ", path
                )
                return _with_user(
                    not_found(miss), json, call.user, required, req.url
                )
            ref route = found.route.value()
            call.params = found.params.copy()
            if route.kind == AUTH:
                return respond(route.handler(db, call), json)
            if route.kind == PAGE:
                var page = route.handler(db, call)
                var here = page.here if page.here else req.url
                return _with_user(page^, json, call.user, required, here)
            # An action.
            if required and not call.user:
                return login_needed(req, json)
            var page = route.handler(db, call)
            if page.status == 303 and call.user:
                audit(
                    db,
                    call.user,
                    path,
                    _run_of(page.location, path),
                    call.form,
                    call.source,
                )
            return _with_user(page^, json, call.user, required)
        except e:
            return _error(e, json)


def _clip(s: String, n: Int) -> String:
    if s.byte_length() <= n:
        return s
    return String(s[byte=:n], "...")


def _log(req: Request, status: Int, start_ns: Int):
    var ms = (Int(perf_counter_ns()) - start_ns) // 1_000_000
    var cf = req.headers.get("CF-Connecting-IP")
    print(
        "morca ui: ",
        req.method,
        " ",
        _clip(req.url, 200),
        " ",
        status,
        " ",
        ms,
        " ms ",
        client(req),
        String(" cf=", _clip(cf, 64)) if cf else String(),
        ' "',
        _clip(req.headers.get("User-Agent"), 120),
        '"',
        sep="",
        flush=True,
    )


struct Logged[H: Handler & Copyable](Copyable, Handler):
    """`H`, logging each request but `/healthz` and the stylesheet as it's
    answered."""

    comptime BodyType = Self.H.BodyType

    var inner: Self.H

    def __init__(out self, var inner: Self.H):
        self.inner = inner^

    def serve(self, req: Request) raises -> ResponseImpl[Self.BodyType]:
        var start = Int(perf_counter_ns())
        var path = _path_of(req.url)
        var quiet = path == HEALTHZ or path == STYLESHEET
        try:
            var resp = self.inner.serve(req)
            if not quiet:
                _log(req, resp.status, start)
            return resp^
        except e:
            if not quiet:
                _log(req, 500, start)
            raise e^


def ui_workers() -> Int:
    """`MORCA_UI_WORKERS`, or 1 if it's unset or not a number of at least 1.
    One worker's drain refuses new connections at once; several keep
    answering them until the loop stops (docs/ui.md#stopping)."""
    var raw = getenv("MORCA_UI_WORKERS")
    if not raw:
        return 1
    try:
        var n = Int(raw)
        if n >= 1:
            return n
    except:
        pass
    print(
        "morca ui: MORCA_UI_WORKERS isn't a number of workers:",
        raw,
        "- using 1",
    )
    return 1


def read_page(mut db: State, url: String) raises -> Page:
    """What `GET url` answers, for `morca` commands that print a page's JSON
    over the database (`morca._internal.remote`)."""
    var got = answer(routes(), db, Call(url, _path_of(url)), PAGE)
    return got.take()


def act(mut db: State, path: String, form: String) raises -> Optional[Page]:
    """The action `path` with the fields of `form`, as the UI's button does
    it, or None if `path` names none (`morca._internal.remote`). Not audited: the
    command acts as whoever can reach the database."""
    var call = Call(path, path)
    call.form = form
    call.body = form
    call.source = "cli"
    return answer(routes(), db, call^, ACTION)


def serve_ui(url: String, addr: String, worker_addr: String = "") raises:
    """Serves the pages on `addr` until SIGTERM or SIGINT drains them
    (`morca._internal.web.drain`), and the worker API on `worker_addr` too, if one is
    given (`morca._internal.api.worker`), until the process ends."""
    var cfg = ServerConfig()
    cfg.idle_timeout_ms = 30_000
    cfg.write_timeout_ms = 30_000
    var server = HttpServer.bind(SocketAddr.parse(addr), cfg^)
    if worker_addr:
        worker_api.listen(url, worker_addr)
        print("morca ui: the worker API on http://", worker_addr, sep="")
    var drain = Drain(server)
    var workers = ui_workers()
    if workers > 1 and not getenv("FLARE_REUSEPORT_WORKERS"):
        # Per-worker listeners would hash some new connections to a worker
        # that's busy with a slow page.
        _ = setenv("FLARE_REUSEPORT_WORKERS", "0")
    print("morca ui on http://", addr, " (", workers, " workers)", sep="")
    server.serve(Logged(drain.counting(Ui(url, drain.draining()))), workers)
    _ = drain^
    print("morca ui: stopped")
