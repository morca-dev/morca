"""Which architectures a container image has (#267): the pool autoscaler
makes a machine only of a type the worker image runs on.

    var r = Registry.from_env()
    r.arches("ghcr.io/morca-dev/census:e82807b")   # ["amd64", "arm64"]

An image's tag names a manifest; a multi-architecture image's is an index
(OCI) or a manifest list (Docker), whose entries each name a platform, and
a single-architecture image's has its architecture in its config blob.
This reads the registry's v2 API with a pull token: anonymous, or from
`MORCA_REGISTRY_USER` and the secret `MORCA_REGISTRY_TOKEN_SECRET` names
(`morca._internal.control.fetch_secret`) for a private image, never in an error.
`MORCA_REGISTRY_ENDPOINT` points every image's registry at one URL, for
tests' fake.
"""

from std.base64 import b64encode
from std.os import getenv

from json import Value, loads
from objectstore.http import Header, HttpClient, RetryPolicy

from morca._internal.control import fetch_secret

comptime _ACCEPT = (
    "application/vnd.oci.image.index.v1+json,"
    " application/vnd.docker.distribution.manifest.list.v2+json,"
    " application/vnd.oci.image.manifest.v1+json,"
    " application/vnd.docker.distribution.manifest.v2+json"
)


@fieldwise_init
struct ImageRef(Copyable, Movable):
    """`host/repo:tag` taken apart."""

    var host: String
    var repo: String
    var tag: String

    @staticmethod
    def parse(image: String) raises -> ImageRef:
        """`ghcr.io/morca-dev/census:tag` (a tag is needed; a host too)."""
        var slash = image.find("/").or_else(-1)
        if slash <= 0:
            raise Error("morca: not an image with its registry: ", image)
        var host = String(image[byte=:slash])
        var rest = String(image[byte = slash + 1 :])
        var colon = rest.rfind(":").or_else(-1)
        if colon <= 0 or "@" in rest:
            raise Error("morca: not an image with a tag: ", image)
        return ImageRef(
            host^, String(rest[byte=:colon]), String(rest[byte = colon + 1 :])
        )


def _http() -> HttpClient:
    var h = HttpClient()
    h.follow_redirects = True
    h.verify_tls = True
    h.timeout_ms = 10000
    h.retry = RetryPolicy.none()
    return h^


def _get(
    url: String, headers: List[Header], what: String
) raises -> Tuple[Int, String]:
    try:
        var r = _http().request("GET", url, headers)
        return (Int(r.status), String(from_utf8_lossy=Span(r.body)))
    except:
        raise Error("morca: can't reach the registry for ", what)


def platform_arches(manifest: Value) raises -> List[String]:
    """The architectures of an index's or manifest list's entries for
    Linux, without attestation entries (`unknown`), in order; empty for a
    single-architecture manifest."""
    var out = List[String]()
    if "manifests" not in manifest:
        return out^
    for m in manifest["manifests"].array_items():
        if "platform" not in m or not m["platform"].is_object():
            continue
        var p = m["platform"]
        var os = p["os"].string_value() if "os" in p else String()
        var arch = (
            p["architecture"].string_value() if "architecture"
            in p else String()
        )
        if os == "linux" and arch and arch != "unknown" and arch not in out:
            out.append(arch)
    return out^


struct Registry(Movable):
    var endpoint: String
    """Every registry at this URL (tests), or empty for `https://<host>`."""
    var user: String
    var _token: String

    def __init__(out self, endpoint: String, user: String, token: String):
        self.endpoint = String(endpoint.rstrip("/"))
        self.user = user
        self._token = token

    @staticmethod
    def from_env() raises -> Registry:
        var token = String()
        var id = getenv("MORCA_REGISTRY_TOKEN_SECRET")
        if id:
            token = fetch_secret(id)
        return Registry(
            getenv("MORCA_REGISTRY_ENDPOINT"),
            getenv("MORCA_REGISTRY_USER"),
            token,
        )

    def has_credentials(self) -> Bool:
        return Bool(self.user) and Bool(self._token)

    def credentials(self) -> Tuple[String, String]:
        """The user and token to log in to pull the image (the pool
        machines' boot, `morca._internal.pool_boot`); empty for none."""
        return (self.user, self._token)

    def _base(self, img: ImageRef) -> String:
        if self.endpoint:
            return self.endpoint
        return String("https://", img.host)

    def _pull_token(self, img: ImageRef) raises -> String:
        """A bearer token to pull `img.repo`: from the registry's token
        endpoint (ghcr.io's `/token`), with the credentials if any."""
        var h = List[Header]()
        if self.has_credentials():
            var basic = b64encode(String(self.user, ":", self._token))
            h.append(Header("Authorization", String("Basic ", basic)))
        var got = _get(
            String(
                self._base(img),
                "/token?scope=repository:",
                img.repo,
                ":pull&service=",
                img.host,
            ),
            h,
            img.repo,
        )
        if got[0] != 200:
            raise Error(
                "morca: the registry refused a pull token for ",
                img.repo,
                ": HTTP ",
                got[0],
            )
        var v = loads(got[1])
        if "token" in v and v["token"].is_string():
            return v["token"].string_value()
        if "access_token" in v and v["access_token"].is_string():
            return v["access_token"].string_value()
        raise Error("morca: the registry's token answer has no token")

    def arches(self, image: String) raises -> List[String]:
        """The Linux architectures `image` has a variant for, Docker's names
        (`amd64`, `arm64`)."""
        var img = ImageRef.parse(image)
        var h: List[Header] = [
            Header("Authorization", String("Bearer ", self._pull_token(img))),
            Header("Accept", _ACCEPT),
        ]
        var got = _get(
            String(self._base(img), "/v2/", img.repo, "/manifests/", img.tag),
            h,
            image,
        )
        if got[0] != 200:
            raise Error(
                "morca: the registry has no manifest for ",
                image,
                ": HTTP ",
                got[0],
            )
        var m = loads(got[1])
        var out = platform_arches(m)
        if len(out) > 0:
            return out^
        # One architecture: it's in the config blob.
        if "config" in m and m["config"].is_object():
            var digest = m["config"]["digest"].string_value()
            var blob = _get(
                String(self._base(img), "/v2/", img.repo, "/blobs/", digest),
                h,
                image,
            )
            if blob[0] == 200:
                var c = loads(blob[1])
                if "architecture" in c and c["architecture"].is_string():
                    out.append(c["architecture"].string_value())
        if len(out) == 0:
            raise Error("morca: can't tell the architectures of ", image)
        return out^
