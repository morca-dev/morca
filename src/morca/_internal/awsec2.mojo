"""The few EC2 calls the `ec2` runner makes (`morca._internal.ec2`), over objectstore's
SigV4 signing and HTTP.

EC2's API is a form `POST` of `Action=...&Version=...` to
`https://ec2.<region>.amazonaws.com/`, answered in XML. Credentials come
from the `AWS_*` environment, else the instance role (IMDSv2); the region
from `AWS_REGION`. `MORCA_EC2_ENDPOINT` points the calls elsewhere, as the
tests do at a stand-in (`tests/fake_ec2.py`).

The answers are read for the fields the runner uses and nothing else: an
instance's ID, type, private address, state, why it's in that state, launch
time and tags.
"""

from std.os import getenv

from objectstore.crypto import sha256_hex
from objectstore.http import Header, HttpClient, Response
from objectstore.s3 import S3Credentials, instance_credentials
from objectstore.sigv4 import AmzTime, QueryParam, sign_request

comptime EC2_VERSION = "2016-11-15"


@fieldwise_init
struct Instance(Copyable, Movable):
    var id: String
    var instance_type: String
    var private_ip: String
    var state: String
    """`pending`, `running`, `shutting-down`, `terminated`, ..."""
    var state_reason: String
    """Why it's stopping or stopped, as EC2's code:
    `Client.InstanceInitiatedShutdown` (it shut itself down),
    `Client.UserInitiatedShutdown` (TerminateInstances),
    `Server.SpotInstanceTermination`, ...; empty while it runs."""
    var launch_time: String
    """ISO 8601, UTC."""
    var tags: Dict[String, String]


def _form_escape(s: String) -> String:
    comptime hex = "0123456789ABCDEF"
    var out = String()
    for b in s.as_bytes():
        if (
            (b >= UInt8(ord("a")) and b <= UInt8(ord("z")))
            or (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
            or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
            or b == UInt8(ord("-"))
            or b == UInt8(ord("_"))
            or b == UInt8(ord("."))
            or b == UInt8(ord("~"))
        ):
            out.write(chr(Int(b)))
        else:
            out.write("%", hex[byte=Int(b >> 4)], hex[byte=Int(b & 15)])
    return out^


def _between(xml: String, tag: String, start: Int = 0) -> Tuple[String, Int]:
    """The text of the first `<tag>` at or after `start`, and where its
    closing tag ends; ("", -1) if there's none."""
    var open = String("<", tag, ">")
    var close = String("</", tag, ">")
    var a = xml.find(open, start).or_else(-1)
    if a < 0:
        return (String(), -1)
    var b = xml.find(close, a).or_else(-1)
    if b < 0:
        return (String(), -1)
    return (
        _unescape(String(xml[byte = a + open.byte_length() : b])),
        b + close.byte_length(),
    )


def _unescape(s: String) -> String:
    return (
        s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", '"')
        .replace("&apos;", "'")
        .replace("&amp;", "&")
    )


def parse_instances(xml: String) -> List[Instance]:
    """The instances a `RunInstances` or `DescribeInstances` answer lists:
    each `<instanceId>` begins one, up to the next."""
    var out = List[Instance]()
    var marks = List[Int]()
    var at = 0
    while True:
        var i = xml.find("<instanceId>", at).or_else(-1)
        if i < 0:
            break
        marks.append(i)
        at = i + 1
    for k in range(len(marks)):
        var end = marks[k + 1] if k + 1 < len(marks) else xml.byte_length()
        var item = String(xml[byte = marks[k] : end])
        var tags = Dict[String, String]()
        var ts = item.find("<tagSet>").or_else(-1)
        if ts >= 0:
            var te = item.find("</tagSet>", ts).or_else(-1)
            var t = ts
            while True:
                var key = _between(item, "key", t)
                if key[1] < 0 or (te >= 0 and key[1] > te):
                    break
                var value = _between(item, "value", key[1])
                tags[key[0]] = value[0]
                t = value[1] if value[1] > 0 else key[1]
        var state = String()
        var si = item.find("<instanceState>").or_else(-1)
        if si >= 0:
            state = _between(item, "name", si)[0]
        var reason = String()
        var ri = item.find("<stateReason>").or_else(-1)
        if ri >= 0:
            reason = _between(item, "code", ri)[0]
        out.append(
            Instance(
                _between(item, "instanceId")[0],
                _between(item, "instanceType")[0],
                _between(item, "privateIpAddress")[0],
                state^,
                reason^,
                _between(item, "launchTime")[0],
                tags^,
            )
        )
    return out^


def _error(xml: String) -> String:
    """`Code: Message` of an EC2 error answer, or the answer itself."""
    var code = _between(xml, "Code")[0]
    var msg = _between(xml, "Message")[0]
    return String(code, ": ", msg) if code else xml


struct Ec2(Movable):
    var region: String
    var endpoint: String
    var host: String
    var http: HttpClient

    def __init__(out self) raises:
        self.region = getenv("AWS_REGION", getenv("AWS_DEFAULT_REGION"))
        if not self.region:
            raise Error("morca: the ec2 runner needs AWS_REGION")
        self.endpoint = String(
            getenv(
                "MORCA_EC2_ENDPOINT",
                String("https://ec2.", self.region, ".amazonaws.com"),
            ).rstrip("/")
        )
        var h = self.endpoint[
            byte = self.endpoint.find("://").or_else(-1) + 3 :
        ]
        self.host = String(h)
        self.http = HttpClient()

    def _credentials(self) raises -> S3Credentials:
        var c = S3Credentials(
            getenv("AWS_ACCESS_KEY_ID"),
            getenv("AWS_SECRET_ACCESS_KEY"),
            getenv("AWS_SESSION_TOKEN"),
        )
        if c.is_set():
            return c^
        # The instance role's, fetched each call, as they rotate.
        var role = instance_credentials()
        if not role:
            raise Error(
                "morca: no AWS credentials (AWS_ACCESS_KEY_ID, or an instance"
                " role)"
            )
        return role.take()

    def call(
        self, action: String, params: List[Tuple[String, String]]
    ) raises -> String:
        """The answer to `action` with `params`; raises with EC2's error."""
        var body = String(
            "Action=", _form_escape(action), "&Version=", EC2_VERSION
        )
        for p in params:
            body.write("&", _form_escape(p[0]), "=", _form_escape(p[1]))
        var cred = self._credentials()
        var when = AmzTime.now()
        var payload = sha256_hex(body)
        var headers: List[Header] = [
            Header(
                "content-type",
                "application/x-www-form-urlencoded; charset=utf-8",
            ),
            Header("host", self.host),
            Header("x-amz-date", when.amz_date),
        ]
        if cred.session_token:
            headers.append(Header("x-amz-security-token", cred.session_token))
        var signed = sign_request(
            "POST",
            "/",
            List[QueryParam](),
            headers,
            payload,
            cred.access_key_id,
            cred.secret_access_key,
            self.region,
            "ec2",
            when,
        )
        headers.append(Header("authorization", signed.authorization))
        var resp: Response
        try:
            resp = self.http.post(
                String(self.endpoint, "/"), body.as_bytes(), headers
            )
        except e:
            raise Error("morca: EC2 ", action, ": ", e)
        var text = String(from_utf8_lossy=Span(resp.body))
        if resp.status != 200:
            raise Error(
                "morca: EC2 ",
                action,
                " answered ",
                resp.status,
                ": ",
                _error(text),
            )
        return text^

    def run_instances(
        self, params: List[Tuple[String, String]]
    ) raises -> List[Instance]:
        return parse_instances(self.call("RunInstances", params))

    def describe(
        self, filters: List[Tuple[String, List[String]]]
    ) raises -> List[Instance]:
        """The instances matching every filter, any of its values."""
        var params = List[Tuple[String, String]]()
        for i in range(len(filters)):
            params.append((String("Filter.", i + 1, ".Name"), filters[i][0]))
            for j in range(len(filters[i][1])):
                params.append(
                    (
                        String("Filter.", i + 1, ".Value.", j + 1),
                        filters[i][1][j],
                    )
                )
        return parse_instances(self.call("DescribeInstances", params))

    def terminate(self, ids: List[String]) raises:
        if len(ids) == 0:
            return
        var params = List[Tuple[String, String]]()
        for i in range(len(ids)):
            params.append((String("InstanceId.", i + 1), ids[i]))
        _ = self.call("TerminateInstances", params)

    def instance_type_arches(
        self, instance_type: String
    ) raises -> List[String]:
        """The architectures `instance_type` supports (`arm64`, `x86_64`,
        ...), as `DescribeInstanceTypes` lists them."""
        var xml = self.call(
            "DescribeInstanceTypes", [("InstanceType.1", instance_type)]
        )
        var block = _between(xml, "supportedArchitectures")[0]
        var out = List[String]()
        var at = 0
        while True:
            var got = _between(block, "item", at)
            if got[1] < 0:
                break
            out.append(got[0])
            at = got[1]
        if len(out) == 0:
            raise Error("morca: EC2 has no instance type ", instance_type)
        return out^
