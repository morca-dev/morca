"""`/code?u=`: a file at a commit on GitHub, its lines coloured as HTML
(`morca._internal.highlight`), for the code shown on hover; the UI fetches it, so a
browser needn't reach GitHub.
"""

from objectstore.http import Header, HttpClient

from morca._internal.highlight import highlight
from morca._internal.json import quote
from morca._internal.source import is_hex
from morca._internal.ui.step_cards import def_json
from morca._internal.web.page import Page


comptime _CODE_MAX = 1 << 20
"""The largest file `/code` colours: 1 MiB."""


def _code_part(s: StringSpan, path: Bool) -> Bool:
    """Whether `s` is a safe owner, repository or (with `path`) file path
    in a GitHub URL: letters, digits, `.`, `_`, `-` (and `/` in a path),
    with no `..` segment."""
    if not s or s.startswith(".") or "/." in s or "./" in s:
        return False
    for b in s.as_bytes():
        var ok = (
            (b >= UInt8(ord("a")) and b <= UInt8(ord("z")))
            or (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
            or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
            or b == UInt8(ord("."))
            or b == UInt8(ord("_"))
            or b == UInt8(ord("-"))
            or (path and b == UInt8(ord("/")))
        )
        if not ok:
            return False
    return True


def raw_code_url(href: String) -> String:
    """`https://raw.githubusercontent.com/<o>/<r>/<sha>/<path>` for a link
    to a file at a commit on GitHub (`https://github.com/<o>/<r>/blob/
    <sha>/<path>`, as the UI's code links are, without `#L`), or "" for
    anything else, so `/code` fetches nothing but such files."""
    comptime head = "https://github.com/"
    if not href.startswith(head):
        return ""
    var rest = String(href[byte = head.byte_length() :])
    var parts = List[String]()
    for p in rest.split("/", 4):
        parts.append(String(p))
    if len(parts) != 5 or parts[2] != "blob":
        return ""
    var sha = parts[3]
    if sha.byte_length() < 7 or sha.byte_length() > 40 or not is_hex(sha):
        return ""
    if not (
        _code_part(parts[0], False)
        and _code_part(parts[1], False)
        and _code_part(parts[4], True)
    ):
        return ""
    return String(
        "https://raw.githubusercontent.com/",
        parts[0],
        "/",
        parts[1],
        "/",
        sha,
        "/",
        parts[4],
    )


def code_page(href: String, at: String = "") -> Page:
    """`/code?u=<a GitHub link to a file at a commit>`: the file's lines and
    each coloured as HTML (`morca._internal.highlight`), as JSON, for the code shown on
    hover. 400 for any other URL, 502 when GitHub doesn't give it (a
    private repository), 413 past `_CODE_MAX`. With `at`, a line, only
    the signature of the `def` there and its docstring's first paragraph
    (`morca._internal.ui.step_cards.def_json`), for a step's card; 400 for an `at` that
    isn't a line number."""
    var raw = raw_code_url(href)
    var line = 0
    if at:
        try:
            line = Int(at)
        except:
            line = 0
        if line < 1:
            raw = ""
    if not raw:
        return Page(
            400,
            String('{"error": "not a GitHub file at a commit"}'),
            String('{"error": "not a GitHub file at a commit"}'),
            "application/json",
        )
    var body: List[UInt8]
    try:
        var http = HttpClient()
        http.follow_redirects = False
        http.verify_tls = True
        http.timeout_ms = 5000
        var resp = http.request(
            "GET",
            raw,
            [Header("User-Agent", "morca-ui")],
            List[UInt8]().copy(),
        )
        if resp.status != 200:
            raise Error("HTTP ", resp.status)
        body = resp.body.copy()
    except:
        var e = String('{"error": "GitHub didn\'t give the file"}')
        return Page(502, e.copy(), e^, "application/json")
    if len(body) > _CODE_MAX:
        var e = String('{"error": "the file is too large"}')
        return Page(413, e.copy(), e^, "application/json")
    var text = String(from_utf8_lossy=Span(body))
    if line > 0:
        var d = def_json(text, line)
        return Page(200, d.copy(), d^, "application/json")
    var out = String('{"lines": [')
    var first = True
    for line in text.split("\n"):
        out.write("" if first else ", ", quote(String(line)))
        first = False
    out.write('], "html": [')
    var lines = highlight(text)
    for i in range(len(lines)):
        out.write(", " if i else "", quote(lines[i]))
    out.write("]}")
    return Page(200, out.copy(), out^, "application/json")
