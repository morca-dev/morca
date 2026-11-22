"""What a handler answers, `Page`: its status, its JSON and its HTML,
where to send a browser, and `respond`, which sends it: the HTML, or the
JSON to a script; a fragment or a file as itself, whatever was asked for.
"""

from flare.http import Response

from morca._internal.ui.layout import with_header_help


struct Page(Movable):
    """What a handler answers: a page, its JSON, a fragment or a file, or
    where to go."""

    var status: Int
    var json: String
    var html: String
    var content_type: String
    """Set for what isn't a page or its JSON (a fragment, a file): `html` is
    sent as this, whatever was asked for."""
    var location: String
    """Set for an action that was done: a browser is sent there with 303,
    and a script gets `json` with 200."""
    var poll_every: Int
    """Set for a live fragment: the seconds until the page asks again, sent
    as `X-Poll-Every` (`_POLL`)."""
    var here: String
    """Where a login link on it comes back to; empty for its own URL."""
    var headers: List[Tuple[String, String]]
    """More headers to send: a cookie, `WWW-Authenticate`."""
    var audited: Bool
    """Set by an action that wrote its own `orca.audit` row (`morca host`'s
    actions), so the server doesn't add one by its path."""

    def __init__(
        out self,
        status: Int,
        var json: String,
        var html: String,
        content_type: String = "",
        location: String = "",
        poll_every: Int = 0,
    ):
        self.status = status
        self.json = json^
        self.html = html^
        self.content_type = content_type
        self.location = location
        self.poll_every = poll_every
        self.here = String()
        self.headers = List[Tuple[String, String]]()
        self.audited = False


def _reason(status: Int) -> String:
    if status == 200:
        return "OK"
    if status == 286:
        return "Done"
    if status == 301:
        return "Moved Permanently"
    if status == 302:
        return "Found"
    if status == 303:
        return "See Other"
    if status == 400:
        return "Bad Request"
    if status == 403:
        return "Forbidden"
    if status == 401:
        return "Unauthorized"
    if status == 429:
        return "Too Many Requests"
    if status == 404:
        return "Not Found"
    if status == 409:
        return "Conflict"
    return "Internal Server Error"


def respond(page: Page, json: Bool) -> Response:
    var raw = page.content_type != ""
    var body = page.json if json and not raw else page.html
    if not (json and not raw) and (
        not raw or page.content_type.startswith("text/html")
    ):
        # A fragment's ids apart from its page's.
        body = with_header_help(body, String("thf") if raw else String("th"))
    # An action's 303, and a moved page that kept its JSON (`morca._internal.ui.ops.
    # to_pools`), answer a script its JSON there, with no redirect.
    var here = (
        Bool(page.location)
        and json
        and (page.status == 303 or (page.status == 301 and page.json != ""))
    )
    var status = 200 if here else page.status
    var resp = Response(
        status=status,
        reason=_reason(status),
        body=List[UInt8](body.as_bytes()),
    )
    try:
        if page.location and not here:
            resp.headers.set("Location", page.location)
        resp.headers.set(
            "Content-Type",
            page.content_type if raw else (
                "application/json" if json else "text/html; charset=utf-8"
            ),
        )
        resp.headers.set("Cache-Control", "no-store")
        if page.poll_every > 0:
            resp.headers.set("X-Poll-Every", String(page.poll_every))
        # A run's timeline, which Perfetto fetches from its own page.
        if raw and page.content_type == "application/json":
            resp.headers.set(
                "Access-Control-Allow-Origin", "https://ui.perfetto.dev"
            )
        for h in page.headers:
            resp.headers.set(h[0], h[1])
    except:
        pass
    return resp^
