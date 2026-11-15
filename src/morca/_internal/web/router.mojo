"""The router: a table of routes, each a method, a path pattern, what kind
of request it is and the handler that answers it. `morca._internal.web.routes` is the
table; `morca._internal.web.server` looks a request up here and wraps the handler in
what its kind needs.

A pattern is the path's segments: a literal (`runs`), a parameter
(`{name}`: any segment but an empty one, URL-decoded) or a number
(`{id:int}`). A path matches a route of its length whose literals are its
segments and whose numbers parse. A path that would match but for a number
that isn't one (`/runs/x`, `/runs/1/attempts/x/log`) is answered 404,
"no run x", from the route's `noun`.

A `GET` route answers `HEAD` too. A read (`GET`) that matches nothing is
404, "nothing at <path>"; a `POST` that matches nothing is 405, since only
the actions take one, unless it's an action's but for its number, which
is 404.
"""

from morca._internal.html import query_param, url_decode
from morca._internal.state import State
from morca._internal.ui.errors import not_found
from morca._internal.web.page import Page

comptime GET = 1
"""`GET`, and `HEAD` with it."""
comptime POST = 2

comptime PAGE = 0
"""A read: the page, its JSON or a fragment of it. Its header says who's
logged in."""
comptime ACTION = 1
"""A `POST` that changes something (`morca._internal.api.actions`): it needs a session
once login is on, and is audited as its user's."""
comptime AUTH = 2
"""Logging in and out (`morca._internal.web.auth`), answered as the handler says."""


struct Call(Movable):
    """A request as its handler sees it: where it went, the route's
    parameters, its form and who sent it."""

    var url: String
    """The path and its query, as asked."""
    var path: String
    var params: Dict[String, String]
    var form: String
    """A `POST`'s fields, `application/x-www-form-urlencoded` (a JSON body
    is converted, `morca._internal.web.auth.json_form`)."""
    var body: String
    """The body as it was sent."""
    var user: String
    """Who's logged in (a session or an API token), or empty
    (`morca._internal.web.auth.sign_in`)."""
    var source: String
    """How they're logged in: "ui" (a session) or "cli" (an API token)."""
    var bearer: String
    """The API token it was sent with, or empty."""
    var session: String
    """The session cookie it was sent with, or empty."""
    var address: String
    """The address it came from (`morca._internal.web.auth.client`)."""

    def __init__(out self, url: String, path: String):
        self.url = url
        self.path = path
        self.params = Dict[String, String]()
        self.form = String()
        self.body = String()
        self.user = String()
        self.source = String("ui")
        self.bearer = String()
        self.session = String()
        self.address = String()

    def query(self, name: StringSlice) -> String:
        """A query parameter's value, decoded, or empty."""
        return query_param(self.url, name)

    def field(self, name: StringSlice) -> String:
        """A field of the form, decoded, or empty."""
        return query_param(String("?", self.form), name)

    def param(self, name: String) raises -> String:
        """A `{name}` of the route's pattern, decoded."""
        return self.params[name]

    def int(self, name: String) raises -> Int:
        """A `{name:int}` of the route's pattern."""
        return Int(self.params[name])


comptime Endpoint = def(mut State, Call) thin raises -> Page
"""What answers a route: a page, its JSON and where to go, as `Page`."""


@fieldwise_init
struct Route(Copyable, Movable):
    var methods: Int
    """`GET`, `POST` or both (`GET | POST`)."""
    var pattern: StaticString
    var kind: Int
    """`PAGE`, `ACTION` or `AUTH`."""
    var handler: Endpoint
    var noun: StaticString
    """What the pattern's number names, for the 404 of one that isn't:
    "run" answers "no run x"."""


def page(
    pattern: StaticString, handler: Endpoint, noun: StaticString = ""
) -> Route:
    """A read at `pattern`."""
    return Route(GET, pattern, PAGE, handler, noun)


def action(
    pattern: StaticString, handler: Endpoint, noun: StaticString = ""
) -> Route:
    """A `POST` at `pattern` that changes something."""
    return Route(POST, pattern, ACTION, handler, noun)


def auth(pattern: StaticString, handler: Endpoint) -> Route:
    """Logging in or out at `pattern`, by `GET` or `POST`."""
    return Route(GET | POST, pattern, AUTH, handler, "")


def _segments(path: StringSlice) -> List[String]:
    var out = List[String]()
    var rest = path[byte=1:] if path.startswith("/") else path
    for s in rest.split("/"):
        out.append(String(s))
    return out^


struct Found(Movable):
    """The route a request matched, with its parameters; or, without one,
    the 404 of a number that isn't one (`miss`), or nothing."""

    var route: Optional[Route]
    var params: Dict[String, String]
    var miss: String

    def __init__(out self):
        self.route = None
        self.params = Dict[String, String]()
        self.miss = String()


def _method_bit(method: String) -> Int:
    if method == "GET" or method == "HEAD":
        return GET
    if method == "POST":
        return POST
    return 0


def find(routes: List[Route], method: String, path: String) -> Found:
    """The first route of `routes` for `method` that `path` matches."""
    var found = Found()
    var bit = _method_bit(method)
    if bit == 0:
        return found^
    var segs = _segments(path)
    for r in routes:
        if not (r.methods & bit):
            continue
        var pat = _segments(r.pattern)
        if len(pat) != len(segs):
            continue
        var params = Dict[String, String]()
        var ok = True
        var bad_number = Optional[String]()
        for i in range(len(pat)):
            ref p = pat[i]
            ref s = segs[i]
            if not p.startswith("{"):
                if p != s:
                    ok = False
                    break
                continue
            var spec = p[byte = 1 : p.byte_length() - 1]
            var name = String(spec.removesuffix(":int"))
            if spec.endswith(":int"):
                try:
                    _ = Int(s)
                except:
                    if not bad_number:
                        bad_number = s
                    continue
                params[name] = s
            else:
                if not s:
                    ok = False
                    break
                params[name] = url_decode(s)
        if not ok:
            continue
        if bad_number:
            if not found.miss:
                found.miss = String("no ", r.noun, " ", bad_number.value())
            continue
        found.route = r.copy()
        found.params = params^
        return found^
    return found^


def answer(
    routes: List[Route], mut db: State, var call: Call, kind: Int
) raises -> Optional[Page]:
    """What the `PAGE` or `ACTION` route `call.path` names answers, for
    `morca` commands over the database (`morca._internal.web.server.read_page`, `act`):
    for no such page a 404, and for no such action None."""
    var found = find(routes, "GET" if kind == PAGE else "POST", call.path)
    if not found.route or found.route.value().kind != kind:
        if kind != PAGE:
            return None
        if found.miss:
            return not_found(found.miss)
        return not_found(String("nothing at ", call.path))
    call.params = found.params.copy()
    return found.route.value().handler(db, call)
