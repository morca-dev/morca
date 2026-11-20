"""Hetzner Cloud's API, as the pool autoscaler needs it (#267,
`morca._internal.pool_scale`): make a server, list a pool's, delete one, and the
architecture of a server type.

    var h = HCloud.from_env()        # raises without a token
    var got = h.create(spec)         # Created: ok, or no stock, or why not
    for s in h.servers("orca-pool=lab"): ...
    _ = h.delete(s.id)               # True if it's gone, already or now
    h.arch("cax31")                  # "arm"

The token is `MORCA_HCLOUD_TOKEN`, or the secret `MORCA_HCLOUD_TOKEN_SECRET`
names (`morca._internal.control.fetch_secret`: `MORCA_SECRET_FETCH` on a Hetzner
stack); it's sent as a bearer token and never put in an error. A call
isn't retried and times out after 10 s: the scheduler calls these from its
tick and tries again on the next.
`MORCA_HCLOUD_ENDPOINT` (`https://api.hetzner.cloud/v1`) is for tests'
fake. Hetzner says a type can't be had in a location now with
`resource_unavailable` or `placement_error`, or `server_type_unavailable`
for one it doesn't offer there: `Created.no_stock`, which the autoscaler
waits on, apart from any other refusal, which it reports.
"""

from std.os import getenv

from json import Value, loads
from objectstore.http import Header, HttpClient, RetryPolicy

from morca._internal.control import fetch_secret
from morca._internal.json import quote

comptime DEFAULT_ENDPOINT = "https://api.hetzner.cloud/v1"
comptime TOKEN = "MORCA_HCLOUD_TOKEN"
comptime TOKEN_SECRET = "MORCA_HCLOUD_TOKEN_SECRET"
comptime ENDPOINT = "MORCA_HCLOUD_ENDPOINT"
comptime NO_STOCK = [
    "resource_unavailable",
    "placement_error",
    "server_type_unavailable",
]
"""Hetzner's error codes for "not now, not here"."""


def configured() -> Bool:
    """Whether this process has a Hetzner token to use."""
    return Bool(getenv(TOKEN)) or Bool(getenv(TOKEN_SECRET))


@fieldwise_init
struct ServerSpec(Copyable, Movable):
    """A server to make."""

    var name: String
    """1 to 63 of a-z, 0-9 and `-`: a host name."""
    var server_type: String
    var location: String
    var image: String
    """The OS image, e.g. `ubuntu-24.04`."""
    var user_data: String
    """cloud-init."""
    var labels: List[Tuple[String, String]]
    var ssh_keys: List[String]
    """Names of the project's SSH keys to put on it; may be empty."""
    var firewall: String
    """A firewall's name to apply, or empty."""
    var network: String
    """A private network's id to attach it to, or empty."""


@fieldwise_init
struct Created(Copyable, Movable):
    """What a create came to: `ok` with the server's `id` and `address`, or
    `no_stock` (wait and try again, or elsewhere), or neither, with
    `why`."""

    var ok: Bool
    var no_stock: Bool
    var id: String
    var address: String
    var why: String

    def quota(self) -> Bool:
        """Whether it was refused for the project's quota (Hetzner's
        `resource_limit_exceeded`, EC2's `VcpuLimitExceeded` or
        `InstanceLimitExceeded`): a smaller type may still fit."""
        return (
            "resource_limit_exceeded" in self.why
            or "VcpuLimitExceeded" in self.why
            or "InstanceLimitExceeded" in self.why
        )


@fieldwise_init
struct Server(Copyable, Movable):
    var id: String
    var name: String
    var status: String
    """`initializing`, `starting`, `running`, `stopping`, `off`, ..."""
    var server_type: String
    var location: String
    var address: String
    var pool: String
    """Its `orca-pool` label, or empty."""


def _labels_json(labels: List[Tuple[String, String]]) -> String:
    var out = String("{")
    for i in range(len(labels)):
        out.write(
            ", " if i > 0 else "",
            quote(labels[i][0]),
            ": ",
            quote(labels[i][1]),
        )
    out.write("}")
    return out^


def _url_part(s: String) -> String:
    """`s` percent-encoded for a query string."""
    comptime hexd = "0123456789ABCDEF"
    var out = String()
    for b in s.as_bytes():
        var c = Int(b)
        if (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("A") and c <= ord("Z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord("-")
            or c == ord("_")
            or c == ord(".")
        ):
            out.write(chr(c))
        else:
            out.write("%", hexd[byte=c >> 4], hexd[byte=c & 15])
    return out^


def _text(v: Value, key: String) raises -> String:
    """`v[key]` as text: a string's value, a number's digits; empty for
    none or null."""
    if key not in v or v[key].is_null():
        return ""
    if v[key].is_string():
        return v[key].string_value()
    if v[key].is_int():
        return String(v[key].int_value())
    return ""


def _server(v: Value) raises -> Server:
    var t = String()
    if "server_type" in v and v["server_type"].is_object():
        t = _text(v["server_type"], "name")
    var loc = String()
    if "datacenter" in v and v["datacenter"].is_object():
        var dc = v["datacenter"]
        if "location" in dc and dc["location"].is_object():
            loc = _text(dc["location"], "name")
    var addr = String()
    if "public_net" in v and v["public_net"].is_object():
        var pn = v["public_net"]
        if "ipv4" in pn and pn["ipv4"].is_object():
            addr = _text(pn["ipv4"], "ip")
    var pool = String()
    if "labels" in v and v["labels"].is_object():
        pool = _text(v["labels"], "orca-pool")
    return Server(
        _text(v, "id"), _text(v, "name"), _text(v, "status"), t, loc, addr, pool
    )


def error_of(body: String) -> Tuple[String, String]:
    """A Hetzner error body's `error.code` and `error.message`, or empty."""
    try:
        var v = loads(body)
        if "error" in v and v["error"].is_object():
            return (_text(v["error"], "code"), _text(v["error"], "message"))
    except:
        pass
    return (String(), String())


def is_no_stock(code: String) -> Bool:
    for c in materialize[NO_STOCK]():
        if c == code:
            return True
    return False


struct HCloud(Movable):
    var endpoint: String
    var _token: String
    var timeout_ms: Int

    def __init__(out self, endpoint: String, token: String):
        self.endpoint = String(endpoint.rstrip("/"))
        self._token = token
        self.timeout_ms = 10000

    @staticmethod
    def from_env() raises -> HCloud:
        """From `MORCA_HCLOUD_TOKEN` (or the secret `MORCA_HCLOUD_TOKEN_SECRET`
        names) and `MORCA_HCLOUD_ENDPOINT`."""
        var token = getenv(TOKEN)
        if not token:
            var id = getenv(TOKEN_SECRET)
            if not id:
                raise Error(
                    "morca: no Hetzner token: set ", TOKEN, " or ", TOKEN_SECRET
                )
            token = fetch_secret(id)
        if not token:
            raise Error("morca: the Hetzner token is empty")
        return HCloud(getenv(ENDPOINT, DEFAULT_ENDPOINT), token)

    def _call(
        self, method: String, path: String, body: String = ""
    ) raises -> Tuple[Int, String]:
        """`method` on `path` (from `/`), with `body` as JSON: the status and
        the body. Raises only when Hetzner can't be reached, saying so
        without the token."""
        var h: List[Header] = [
            Header("Authorization", String("Bearer ", self._token)),
            Header("User-Agent", "morca"),
        ]
        if body:
            h.append(Header("Content-Type", "application/json"))
        var http = HttpClient()
        http.follow_redirects = False
        http.verify_tls = True
        http.timeout_ms = self.timeout_ms
        # No retries here: the scheduler calls this from its tick, and tries
        # again on the next, so an outage at Hetzner never holds it up.
        http.retry = RetryPolicy.none()
        try:
            var r = http.request(
                method, String(self.endpoint, path), h, body.as_bytes()
            )
            return (Int(r.status), String(from_utf8_lossy=Span(r.body)))
        except:
            raise Error("morca: can't reach Hetzner's API at ", self.endpoint)

    def _refused(self, what: String, got: Tuple[Int, String]) raises:
        var e = error_of(got[1])
        raise Error(
            "morca: Hetzner refused ",
            what,
            ": HTTP ",
            got[0],
            String(" ", e[0]) if e[0] else String(),
            String(": ", e[1]) if e[1] else String(),
        )

    def arch(self, server_type: String) raises -> String:
        """The architecture of `server_type` (`arm` or `x86`); raises for a
        type Hetzner doesn't have."""
        var got = self._call(
            "GET", String("/server_types?name=", _url_part(server_type))
        )
        if got[0] != 200:
            self._refused(String("server type ", server_type), got)
        var v = loads(got[1])
        for t in v["server_types"].array_items():
            if _text(t, "name") == server_type:
                return _text(t, "architecture")
        raise Error("morca: Hetzner has no server type ", server_type)

    def firewall_id(self, name: String) raises -> String:
        """The id of the firewall named `name`; raises for none."""
        var got = self._call("GET", String("/firewalls?name=", _url_part(name)))
        if got[0] != 200:
            self._refused(String("firewall ", name), got)
        var v = loads(got[1])
        for f in v["firewalls"].array_items():
            if _text(f, "name") == name:
                return _text(f, "id")
        raise Error("morca: Hetzner has no firewall named ", name)

    def network_id(
        self, name: String, zone: String, ip_range: String
    ) raises -> String:
        """The id of the private network `name`, made if there's none: one
        `ip_range` with a cloud subnet of its first /24 in network zone
        `zone` (`eu-central`: fsn1, nbg1 and hel1)."""
        var got = self._call("GET", String("/networks?name=", _url_part(name)))
        if got[0] != 200:
            self._refused(String("network ", name), got)
        for n in loads(got[1])["networks"].array_items():
            if _text(n, "name") == name:
                return _text(n, "id")
        var slash = ip_range.find("/").or_else(-1)
        var base = String(ip_range[byte=:slash]) if slash > 0 else ip_range
        var made = self._call(
            "POST",
            "/networks",
            String(
                '{"name": ',
                quote(name),
                ', "ip_range": ',
                quote(ip_range),
                ', "labels": {"orca": "pool"}, "subnets": [{"type": "cloud",',
                ' "network_zone": ',
                quote(zone),
                ', "ip_range": ',
                quote(String(base, "/24")),
                "}]}",
            ),
        )
        if made[0] != 201 and made[0] != 200:
            self._refused(String("making network ", name), made)
        return _text(loads(made[1])["network"], "id")

    def create(self, spec: ServerSpec) raises -> Created:
        """Makes the server `spec` says. Hetzner out of `spec`'s type in its
        location is `no_stock`; any other refusal is `why`."""
        var body = String(
            '{"name": ',
            quote(spec.name),
            ', "server_type": ',
            quote(spec.server_type),
            ', "location": ',
            quote(spec.location),
            ', "image": ',
            quote(spec.image),
            ', "user_data": ',
            quote(spec.user_data),
            ', "labels": ',
            _labels_json(spec.labels),
            ', "start_after_create": true',
            ', "public_net": {"enable_ipv4": true, "enable_ipv6": false}',
        )
        if len(spec.ssh_keys) > 0:
            body.write(', "ssh_keys": [')
            for i in range(len(spec.ssh_keys)):
                body.write(", " if i > 0 else "", quote(spec.ssh_keys[i]))
            body.write("]")
        if spec.firewall:
            body.write(
                ', "firewalls": [{"firewall": ',
                self.firewall_id(spec.firewall),
                "}]",
            )
        if spec.network:
            body.write(', "networks": [', spec.network, "]")
        body.write("}")
        var got = self._call("POST", "/servers", body)
        if got[0] == 201 or got[0] == 200:
            var s = _server(loads(got[1])["server"])
            return Created(True, False, s.id, s.address, "")
        var e = error_of(got[1])
        var why = String(
            "HTTP ", got[0], String(" ", e[0]) if e[0] else String()
        )
        if e[1]:
            why.write(": ", e[1])
        return Created(False, is_no_stock(e[0]), "", "", why^)

    def servers(self, label_selector: String) raises -> List[Server]:
        """The servers with labels `label_selector` matches
        (`orca-pool=lab`), every page."""
        var out = List[Server]()
        var page = 1
        while True:
            var got = self._call(
                "GET",
                String(
                    "/servers?label_selector=",
                    _url_part(label_selector),
                    "&per_page=50&page=",
                    page,
                ),
            )
            if got[0] != 200:
                self._refused("listing servers", got)
            var v = loads(got[1])
            for s in v["servers"].array_items():
                out.append(_server(s))
            var next = 0
            if "meta" in v and v["meta"].is_object():
                var m = v["meta"]
                if "pagination" in m and m["pagination"].is_object():
                    var n = m["pagination"]
                    if "next_page" in n and n["next_page"].is_int():
                        next = Int(n["next_page"].int_value())
            if next <= page:
                break
            page = next
        return out^

    def delete(self, id: String) raises -> Bool:
        """Deletes server `id`: True once it's gone, now or before (404)."""
        var got = self._call("DELETE", String("/servers/", id))
        if got[0] == 200 or got[0] == 204 or got[0] == 404:
            return True
        self._refused(String("deleting server ", id), got)
        return False
