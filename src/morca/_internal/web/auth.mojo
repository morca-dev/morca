"""Who a request is from, and whether it may act: the session cookie of a
browser, the API token of a script (`morca --remote`), and the checks that
keep another site's page from posting to the UI. Also the endpoints that
log in and out. The users, sessions and audit rows themselves are
`morca._internal.auth`; API tokens are `morca._internal.tokens`; a worker's token is checked by
`morca._internal.api.worker` instead, and gets nothing here.

| Path | |
|---|---|
| `/login` | `GET`: the form; `POST` `name`, `password`, `next`: a session, as the cookie `morca_session` |
| `/logout` | ends the session and clears the cookie |
| `/api/login` | JSON `name`, `password`, `label`, `days`: an API token for `morca login` |
| `/api/logout` | revokes the API token it's sent with |

A script's request is one with an `Authorization` header (or a JSON login
for a token). A browser sends neither to another site without a CORS
preflight, which the UI never answers, so a script's `POST` with no
`Origin` needn't be the UI's own; the token, not a cookie, is what it acts
with. A request with an `Authorization` header is answered 401 unless it's
a live token, whatever cookie it has.
"""

from std.os import getenv

from flare.http import Request, Response
from json import loads

from morca._internal.auth import (
    SESSION_COOKIE,
    audit,
    close_session,
    login_failed,
    open_session,
    password_ok,
    session_user,
    too_many_failures,
)
from morca._internal.html import Html, url_encode
from morca._internal.json import quote
from morca._internal.state import State
from morca._internal.tokens import (
    clean_label,
    issue_token,
    revoke_token,
    token_days,
    token_user,
)
from morca._internal.ui.layout import page_html
from morca._internal.ui.login import login_page, safe_next
from morca._internal.web.page import Page, respond
from morca._internal.web.router import Call

comptime LOGIN = "/login"
comptime LOGOUT = "/logout"
comptime API_LOGIN = "/api/login"
comptime API_LOGOUT = "/api/logout"


# ── who it's from ────────────────────────────────────────────────────────────


def bearer(authorization: String) -> String:
    """The token of `Authorization: Bearer <token>`, or empty for any other
    header."""
    var a = String(authorization.strip())
    if not a.lower().startswith("bearer "):
        return ""
    return String(a[byte=7:].strip())


def cookie(req: Request, name: StringSpan) -> String:
    """A cookie the request sent, or empty."""
    for part in req.headers.get("Cookie").split(";"):
        var kv = part.strip()
        var eq = kv.find("=").or_else(-1)
        if eq > 0 and kv[byte=:eq] == name:
            return String(kv[byte = eq + 1 :])
    return ""


def sign_in(mut db: State, req: Request, mut call: Call) raises -> Bool:
    """Fills in who `call` is from: the user of its API token (source
    "cli"), or of its session cookie (source "ui"), or nobody. False for an
    `Authorization` that isn't a live API token, whose request is refused
    (cookies are never looked at instead)."""
    var authorization = req.headers.get("Authorization")
    if authorization:
        call.bearer = bearer(authorization)
        call.user = token_user(db, call.bearer)
        call.source = "cli"
        return call.user != ""
    call.session = cookie(req, SESSION_COOKIE)
    call.user = session_user(db, call.session)
    return True


def client(req: Request) -> String:
    """The address a request came from: the connection's peer, or behind a
    proxy (`MORCA_UI_TRUST_PROXY=1`) the first address of
    `X-Forwarded-For`, which only a proxy in front can be trusted to set."""
    if getenv("MORCA_UI_TRUST_PROXY") == "1":
        var fwd = req.headers.get("X-Forwarded-For")
        if fwd:
            return String(fwd.split(",")[0].strip())
    return String(req.peer.ip)


def content_type(req: Request) -> String:
    """The request's media type, lower case, without its parameters, which
    a cross-site page may set however it likes."""
    var t = req.headers.get("Content-Type")
    var semi = t.find(";").or_else(-1)
    var essence = String(t[byte=:semi]) if semi >= 0 else t
    return String(essence.strip()).lower()


def scripted(req: Request, path: String) -> Bool:
    """Whether `req` is a script's (`morca._internal.remote`): it has an
    `Authorization` header, or is a JSON login for a token. `/login` and
    `/logout` are a browser's whatever they're sent with."""
    if path == LOGIN or path == LOGOUT:
        return False
    return req.headers.get("Authorization") != "" or (
        path == API_LOGIN and content_type(req) == "application/json"
    )


# ── posted from the UI's own pages ───────────────────────────────────────────


def _scheme(req: Request) raises -> String:
    """The scheme the browser used: behind a proxy (`MORCA_UI_TRUST_PROXY=1`)
    the first of `X-Forwarded-Proto`, else `https` with
    `MORCA_UI_SECURE_COOKIES=1` (secure cookies imply TLS in front), else
    `http`."""
    if getenv("MORCA_UI_TRUST_PROXY") == "1":
        var fwd = req.headers.get("X-Forwarded-Proto")
        if fwd:
            var first = String(fwd.split(",")[0].strip()).lower()
            if first == "http" or first == "https":
                return first
    if getenv("MORCA_UI_SECURE_COOKIES") == "1":
        return "https"
    return "http"


def _without_default_port(origin: String) -> String:
    """`origin` (`scheme://host[:port]`), lower case, without the scheme's
    default port, which a browser leaves out of `Origin`."""
    var o = origin.lower()
    if o.startswith("https://") and o.endswith(":443"):
        return String(o[byte = : o.byte_length() - 4])
    if o.startswith("http://") and o.endswith(":80"):
        return String(o[byte = : o.byte_length() - 3])
    return o^


def same_origin(req: Request) raises -> Bool:
    """Whether a `POST` came from the UI's own pages: its `Origin`, or
    without one its `Referer`, is this server as the browser addressed it,
    by `Host` and the scheme `_scheme` gives. Host and scheme compare in
    any case."""
    var host = req.headers.get("Host")
    if not host:
        return False
    var own = _without_default_port(String(_scheme(req), "://", host))
    var origin = req.headers.get("Origin")
    if origin:
        return _without_default_port(origin) == own
    var referer = req.headers.get("Referer")
    if not referer:
        return False
    # The Referer's origin is what comes before the path's first '/'.
    var path_from = referer.find("://").or_else(-1) + 3
    var rest = referer.find("/", path_from).or_else(-1)
    var ref_origin = String(referer[byte=:rest]) if rest >= 0 else referer
    return _without_default_port(ref_origin) == own


def cross_origin() -> Page:
    var why = String(
        "this form wasn't posted from morca ui's own pages (its Origin or",
        " Referer isn't this server), so it's refused",
    )
    var h = Html()
    h.raw("<h1>Refused</h1><p>")
    h.text(why)
    h.raw("</p>")
    return Page(
        403, String('{"error": ', quote(why), "}"), page_html("Refused", "", h)
    )


def login_needed(req: Request, json: Bool) raises -> Response:
    """An action without a session: 401 for a script, to the login page for
    a browser, which comes back to the page the form was on."""
    if json:
        return respond(
            Page(
                401,
                String('{"error": "log in first", "login": "/login"}'),
                String(),
            ),
            json,
        )
    var back = String("/")
    var referer = req.headers.get("Referer")
    var host = String("http://", req.headers.get("Host"))
    if referer.startswith(String(host, "/")):
        back = String(referer[byte = host.byte_length() :])
    var out = Response(status=303, reason="See Other")
    out.headers.set("Location", String("/login?next=", url_encode(back)))
    return out^


# ── JSON in and out ──────────────────────────────────────────────────────────


def json_form(body: String) raises -> String:
    """A JSON object of strings, numbers and booleans (`morca._internal.remote`'s
    actions) as the form the UI's own pages post, so both are handled and
    audited alike: true is `1`, false and null are left out."""
    var v = loads(body if body.strip() else "{}")
    if not v.is_object():
        raise Error("an action's JSON is an object of its fields")
    var form = String()
    for kv in v.object_items():
        var val: String
        if kv[1].is_string():
            val = kv[1].string_value()
        elif kv[1].is_bool():
            if not kv[1].bool_value():
                continue
            val = "1"
        elif kv[1].is_int():
            val = String(kv[1].int_value())
        elif kv[1].is_null():
            continue
        else:
            raise Error("an action's fields are strings, numbers or booleans")
        form.write("&" if form else "", url_encode(kv[0]), "=", url_encode(val))
    return form^


def json_error(status: Int, why: String) -> Page:
    """An error as JSON only, for a script."""
    return Page(status, String('{"error": ', quote(why), "}"), String())


def token_refused() -> Page:
    """A request with a token that's no use: unknown, expired or revoked,
    or an `Authorization` that isn't a bearer token."""
    var page = json_error(
        401,
        (
            "this token is unknown, expired or revoked (morca login again), or"
            " Authorization isn't Bearer <token>"
        ),
    )
    page.headers.append(("WWW-Authenticate", 'Bearer realm="morca"'))
    return page^


# ── the endpoints ────────────────────────────────────────────────────────────


def _cookie_header(token: String, max_age: Int) -> String:
    """The session cookie: only for this site's requests (`SameSite`), out
    of scripts' reach (`HttpOnly`), and with `MORCA_UI_SECURE_COOKIES=1`
    (behind HTTPS) never sent in the clear."""
    return String(
        SESSION_COOKIE,
        "=",
        token,
        "; Path=/; HttpOnly; SameSite=Strict; Max-Age=",
        max_age,
        "; Secure" if getenv("MORCA_UI_SECURE_COOKIES") == "1" else "",
    )


def login_form(mut db: State, call: Call) raises -> Page:
    """`GET /login`: the form, which goes on to `?next=`."""
    var page = login_page(call.query("next"), "")
    page.here = "/"
    return page^


def login(mut db: State, call: Call) raises -> Page:
    """`POST /login`: a session for `name` and `password`, as a cookie,
    then on to `next`."""
    var name = call.field("name")
    if too_many_failures(db, name, call.address):
        return login_page(
            call.field("next"),
            "Too many failed logins; try again in 15 minutes.",
            429,
        )
    var token = open_session(db, name, call.field("password"))
    if not token:
        login_failed(db, name, call.address)
        return login_page(call.field("next"), "Wrong name or password.", 401)
    var hours = Float64(getenv("MORCA_UI_SESSION_HOURS", "12"))
    var page = Page(
        303,
        String('{"user": ', quote(name), "}"),
        String(),
        location=safe_next(call.field("next")),
    )
    page.headers.append(
        ("Set-Cookie", _cookie_header(token, Int(hours * 3600.0)))
    )
    return page^


def logout(mut db: State, call: Call) raises -> Page:
    """`/logout`: ends the session, if there is one, and clears the
    cookie."""
    if call.session:
        close_session(db, call.session)
    var page = Page(303, String('{"user": null}'), String(), location="/")
    page.headers.append(("Set-Cookie", _cookie_header("", 0)))
    return page^


def api_login(mut db: State, call: Call) raises -> Page:
    """`POST /api/login`: a new API token for a JSON `name` and `password`,
    labelled `label`, lasting `days` (at most `MORCA_API_TOKEN_DAYS`).
    Failures count against the same limit as `/login`'s, and the token is
    in this answer only. A token it was sent with isn't looked at."""
    var name: String
    var password: String
    var label = String()
    var days = 0
    try:
        var v = loads(call.body)
        name = v["name"].string_value()
        password = v["password"].string_value()
        if String("label") in v and v["label"].is_string():
            label = v["label"].string_value()
        if String("days") in v and v["days"].is_int():
            days = Int(v["days"].int_value())
    except:
        return json_error(
            400, "a login is a JSON object with a name and a password"
        )
    if too_many_failures(db, name, call.address):
        return json_error(
            429, "Too many failed logins; try again in 15 minutes."
        )
    if not password_ok(db, name, password):
        login_failed(db, name, call.address, "cli")
        return json_error(401, "Wrong name or password.")
    var got = issue_token(db, name, label, token_days(days))
    audit(
        db,
        name,
        API_LOGIN,
        0,
        String(clean_label(label), " from ", call.address),
        "cli",
    )
    return Page(
        200,
        String(
            '{"user": ',
            quote(name),
            ', "token": ',
            quote(got.token),
            ', "expires": ',
            quote(got.expires),
            "}",
        ),
        String(),
    )


def api_logout(mut db: State, call: Call) raises -> Page:
    """`POST /api/logout`: revokes the API token it's sent with; a session
    has none to revoke."""
    if not call.bearer:
        return token_refused()
    _ = revoke_token(db, call.bearer)
    audit(db, call.user, API_LOGOUT, 0, "", call.source)
    return Page(200, String('{"revoked": true}'), String())
