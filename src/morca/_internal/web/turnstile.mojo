"""Cloudflare Turnstile in front of the data reads (a Data tab, `data.csv`,
`data.json`): a visitor who isn't logged in passes a check once a day
before the UI runs one for them. Crawlers that come from a new address
each time get past the per-client limits (`morca._internal.web.limit`);
they don't get past this.

| Variable | |
|---|---|
| `MORCA_UI_TURNSTILE_SITEKEY` | the widget's site key (public) |
| `MORCA_UI_TURNSTILE_SECRET` | the id of its secret key (`morca._internal.control.fetch_secret`) |
| `MORCA_UI_TURNSTILE_HOSTNAMES` | the hostnames a pass may come from, comma separated |

It's off unless the site key and the secret are both set. On, a data read
without a valid `morca_human` cookie is answered 403: a page with the
widget, or for `data.csv`, `data.json` and JSON a line of text. The widget
posts its token to `POST /turnstile`, which asks Cloudflare's siteverify
and needs `success`, the action `data` and one of the hostnames; it then
sets `morca_human` (a day, signed with a key the UI makes when it starts,
so a restart asks again) and sends the browser back. The same requests as
the limits' (`exempt`: sessions, API tokens, the worker API) never see it.
"""

from std.ffi import external_call
from std.os import getenv

from flare.crypto.random import random_bytes
from flare.http import Request, Response
from json import loads
from objectstore.crypto import hmac_sha256_hex
from objectstore.http import Header, HttpClient, RetryPolicy

from morca._internal.control import fetch_secret
from morca._internal.html import Html, escape, query_param, url_encode
from morca._internal.ui.layout import page_html
from morca._internal.web.auth import client, cookie
from morca._internal.web.limit import exempt, is_data_read
from morca._internal.web.page import Page

comptime HUMAN_COOKIE = "morca_human"
comptime VERIFY_PATH = "/turnstile"
comptime ACTION = "data"
comptime COOKIE_SECONDS = 86400
comptime MAX_TOKEN = 2048
comptime SITEVERIFY = (
    "https://challenges.cloudflare.com/turnstile/v0/siteverify"
)
comptime SCRIPT = "https://challenges.cloudflare.com/turnstile/v0/api.js"


def _now() -> Int:
    return Int(external_call["time", Int64](Int(0)))


def sign(key: Span[UInt8, _], expiry: Int) -> String:
    """The cookie's value: when it expires (seconds since the epoch) and its
    HMAC-SHA256 under `key`."""
    var e = String(expiry)
    return String(e, ".", hmac_sha256_hex(key, e))


def _same(a: String, b: String) -> Bool:
    """`a == b`, in time that doesn't depend on where they differ."""
    var x = a.as_bytes()
    var y = b.as_bytes()
    if len(x) != len(y):
        return False
    var d: UInt8 = 0
    for i in range(len(x)):
        d |= x[i] ^ y[i]
    return d == 0


def valid(key: Span[UInt8, _], value: String, now: Int) -> Bool:
    """Whether `value` is a cookie `sign` made with `key` that hasn't
    expired by `now`."""
    var dot = value.find(".")
    if dot <= 0:
        return False
    var expiry: Int
    try:
        expiry = Int(value[byte=:dot])
    except:
        return False
    if expiry <= now:
        return False
    return _same(value, sign(key, expiry))


def safe_next(next: String) -> String:
    """Where to send the browser after a pass: `next` if it's a path on
    this site (starts with one `/`, no backslash), else `/`."""
    if (
        not next.startswith("/")
        or next.startswith("//")
        or "\\" in next
        or "\n" in next
        or "\r" in next
    ):
        return "/"
    return next


def _wants_text(req: Request, path: String) -> Bool:
    return (
        path.endswith("/data.csv")
        or path.endswith("/data.json")
        or query_param(req.url, "format") == "json"
        or "application/json" in req.headers.get("Accept")
    )


def challenge_page(sitekey: String, next: String) -> Page:
    """The 403 page with the widget, which posts its token on to `next`."""
    var h = Html()
    h.raw(
        (
            "<h1>One moment</h1><p>Check that you're not a crawler to see the"
            " data."
        ),
        " It lasts a day; logging in skips it.</p>",
    )
    h.raw('<form id="ts" method="post" action="', VERIFY_PATH, '">')
    h.raw('<input type="hidden" name="next" value="', escape(next), '">')
    h.raw('<div class="cf-turnstile" data-sitekey="', escape(sitekey), '"')
    h.raw(' data-action="', ACTION, '" data-callback="morcaHuman"></div>')
    h.raw("<noscript><p>The check needs JavaScript.</p></noscript></form>")
    h.raw('<script src="', SCRIPT, '" async defer></script>')
    h.raw(
        "<script>function morcaHuman(){",
        "document.getElementById('ts').submit()}</script>",
    )
    return Page(
        403,
        String('{"error": "check that you are not a crawler first"}'),
        page_html("One moment", "", h),
    )


def _text(status: Int, reason: String, body: String) -> Response:
    var resp = Response(
        status=status, reason=reason, body=List[UInt8](body.as_bytes())
    )
    try:
        resp.headers.set("Content-Type", "text/plain; charset=utf-8")
        resp.headers.set("Cache-Control", "no-store")
    except:
        pass
    return resp^


def _forbidden(why: String) -> Response:
    return _text(403, "Forbidden", String(why, "\n"))


struct Turnstile(Copyable, Movable):
    """The check's settings and the key its cookies are signed with."""

    var sitekey: String
    var secret: String
    var hostnames: List[String]
    var key: List[UInt8]
    var verify_url: String
    """Cloudflare's siteverify; `MORCA_UI_TURNSTILE_VERIFY_URL` (tests only)
    points it at a stand-in."""

    def __init__(out self) raises:
        """From the environment (the module doc); off if either the site key
        or the secret is missing, or the secret can't be read."""
        self.sitekey = getenv("MORCA_UI_TURNSTILE_SITEKEY")
        self.secret = String()
        var id = getenv("MORCA_UI_TURNSTILE_SECRET")
        if self.sitekey and id:
            try:
                self.secret = fetch_secret(id)
            except e:
                print("morca ui: Turnstile is off: its secret:", e)
        self.hostnames = List[String]()
        for h in getenv("MORCA_UI_TURNSTILE_HOSTNAMES").split(","):
            var s = String(h.strip())
            if s:
                self.hostnames.append(s)
        self.key = random_bytes(32)
        var url = getenv("MORCA_UI_TURNSTILE_VERIFY_URL")
        self.verify_url = url if url else String(SITEVERIFY)
        if self.on() and not self.hostnames:
            print(
                "morca ui: MORCA_UI_TURNSTILE_HOSTNAMES is empty: no check",
                " will pass",
                sep="",
            )

    def on(self) -> Bool:
        return Bool(self.sitekey) and Bool(self.secret)

    def _asked(self, req: Request, path: String) -> Bool:
        """Whether `req` is a data read that must pass the check first."""
        if not self.on() or not is_data_read(req.url) or exempt(req, path):
            return False
        return not valid(self.key, cookie(req, HUMAN_COOKIE), _now())

    def asked(self, req: Request, path: String) -> Bool:
        """Whether `req` must pass the check before its data read (a kept
        one too, `morca._internal.web.cache`)."""
        return self._asked(req, path)

    def needs_page(self, req: Request, path: String) -> Bool:
        """Whether `req` gets the widget's page (`challenge_page`)."""
        return self._asked(req, path) and not _wants_text(req, path)

    def check(self, req: Request, path: String) -> Optional[Response]:
        """The 403 in text for a data read of a file or JSON that hasn't
        passed the check, or None (`needs_page` covers the pages)."""
        if not self._asked(req, path) or not _wants_text(req, path):
            return None
        return _forbidden(
            String(
                "check that you're not a crawler first: open the dataset's",
                " Data tab in a browser, or log in",
            )
        )

    def _siteverify(self, token: String, ip: String) raises -> Bool:
        var form = String(
            "secret=",
            url_encode(self.secret),
            "&response=",
            url_encode(token),
            "&remoteip=",
            url_encode(ip),
        )
        var http = HttpClient()
        http.follow_redirects = False
        http.verify_tls = True
        http.timeout_ms = 10_000
        http.retry = RetryPolicy.none()
        var h: List[Header] = [
            Header("Content-Type", "application/x-www-form-urlencoded"),
            Header("User-Agent", "morca"),
        ]
        var r = http.request("POST", self.verify_url, h, form.as_bytes())
        if r.status != 200:
            print("morca ui: Turnstile siteverify answered", r.status)
            return False
        var v = loads(String(from_utf8_lossy=Span(r.body)))
        if not v.is_object():
            return False
        if "success" not in v or not v["success"].bool_value():
            return False
        if "action" not in v or not v["action"].is_string():
            return False
        if v["action"].string_value() != ACTION:
            return False
        if "hostname" not in v or not v["hostname"].is_string():
            return False
        var host = v["hostname"].string_value()
        for allowed in self.hostnames:
            if host == allowed:
                return True
        return False

    def verify(self, req: Request) -> Response:
        """`POST /turnstile`: the cookie and a 303 to `next` if Cloudflare
        says the token passed, else 403. Fails closed: no answer is no
        pass."""
        var form = String("?", String(from_utf8_lossy=Span(req.body)))
        var token = query_param(form, "cf-turnstile-response")
        var next = safe_next(query_param(form, "next"))
        if not self.on():
            return _forbidden("there's no check here")
        var tl = token.byte_length()
        if tl == 0 or tl > MAX_TOKEN:
            return _forbidden(
                "the check didn't send a token: go back and try again"
            )
        var ok = False
        try:
            ok = self._siteverify(token, client(req))
        except e:
            print("morca ui: Turnstile siteverify:", e)
        if not ok:
            return _forbidden("the check didn't pass: go back and try again")
        var resp = _text(303, "See Other", "")
        try:
            resp.headers.set("Location", next)
            resp.headers.set(
                "Set-Cookie",
                String(
                    HUMAN_COOKIE,
                    "=",
                    sign(self.key, _now() + COOKIE_SECONDS),
                    "; Path=/; HttpOnly; SameSite=Lax; Max-Age=",
                    COOKIE_SECONDS,
                    "; Secure" if getenv("MORCA_UI_SECURE_COOKIES")
                    == "1" else "",
                ),
            )
        except:
            return _forbidden(
                "the check passed, but its cookie couldn't be set"
            )
        return resp^
