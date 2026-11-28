"""A stand-in for Hetzner Cloud's API, for tests/hcloud.sh and the pool
autoscaler's tests: servers (create, list by label, delete), server types
and firewalls, with each "server" a local process running its user data
under sh, from <dir>.

    python3 tests/fake_hcloud.py <port> <dir>

Requests must carry `Authorization: Bearer test-token`, else 401. Every
call is appended to <dir>/calls.jsonl as {"method", "path", "body"}.

Stock: a create succeeds only for a type and location named in
<dir>/stock, a line `<type> <location>` each (read on every create, so a
test can change it); any other is refused 412 `resource_unavailable`, as
Hetzner refuses a type it's out of. A location not in hel1, nbg1, fsn1 is
`invalid_input`. Types starting with `cax` are `arm`, the rest `x86`; the
types are cax11..cax41, cx23..cx53, cpx12..cpx62 and ccx13..ccx63, and
gex44 and gex130, which have one GPU: their servers run with
MORCA_HOST_GPUS=1. A type named in <dir>/quota (words) is
refused 403 `resource_limit_exceeded`, as a project over its core quota is.
The one
firewall is `morca-lab`, id 42. Networks are made by POST /v1/networks and
listed by name; a server attached to one shows a private address in it.

Each server's user data runs as <dir>/server-<id>.sh with output in
<dir>/server-<id>.log and SERVER_NAME (and HOSTNAME, which bash resets) set
to its name, unless <dir>/no-run
exists; deleting the server kills its process group, and so does its
script's end, as a machine's would: nothing it started outlives it (#403). A server's address is
127.0.0.1, and its MORCA_BOOT_DIR is <dir>/boot-<id> (morca.pool_boot's
script keeps its files there rather than /etc/orca).

It's a container registry too, for morca.registry: GET /token gives the
pull token `reg-token`, and GET /v2/<repo>/manifests/<tag> with it an OCI
index whose Linux platforms are the words of <dir>/arches ("amd64 arm64"
without the file).
"""

import http.server
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.parse

PORT = int(sys.argv[1])
DIR = sys.argv[2]
LOCK = threading.Lock()
SERVERS = {}  # id -> {"name", "type", "location", "labels", "proc", "status", "networks"}
NETWORKS = {}  # id -> {"name", "ip_range", "zone"}
COUNTER = [1000]
LOCATIONS = ("hel1", "nbg1", "fsn1")
GPU_TYPES = ["gex44", "gex130"]
TYPES = (
    [f"cax{n}1" for n in range(1, 5)]
    + [f"cx{n}3" for n in range(2, 6)]
    + [f"cpx{n}2" for n in range(1, 7)]
    + [f"ccx{n}3" for n in range(1, 7)]
    + GPU_TYPES
)


def _arch(t):
    return "arm" if t.startswith("cax") else "x86"


def _stock():
    try:
        with open(os.path.join(DIR, "stock")) as f:
            return {tuple(l.split()[:2]) for l in f if len(l.split()) >= 2}
    except FileNotFoundError:
        return set()


def _server(sid, s):
    status = s["status"]
    if s["proc"] is not None and s["proc"].poll() is not None and status == "running":
        status = "off"
    return {
        "id": int(sid),
        "name": s["name"],
        "status": status,
        "server_type": {"name": s["type"], "architecture": _arch(s["type"])},
        "datacenter": {"location": {"name": s["location"]}},
        "public_net": {"ipv4": {"ip": "127.0.0.1"}},
        "private_net": [{"network": n, "ip": f"10.77.0.{int(sid) % 250 + 2}"} for n in s.get("networks", [])],
        "labels": s["labels"],
    }


def _error(code, message, status):
    return status, {"error": {"code": code, "message": message}}


def _matches(labels, selector):
    for part in selector.split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            if labels.get(k) != v:
                return False
        elif part and part not in labels:
            return False
    return True


def _create(body):
    t, loc, name = body.get("server_type"), body.get("location"), body.get("name", "")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", name):
        return _error("invalid_input", f"invalid name {name}", 400)
    if t not in TYPES:
        return _error("invalid_input", f"server type {t} not found", 400)
    if loc not in LOCATIONS:
        return _error("invalid_input", f"location {loc} not found", 400)
    if any(s["name"] == name for s in SERVERS.values()):
        return _error("uniqueness_error", "server name is already used", 409)
    try:
        with open(os.path.join(DIR, "quota")) as f:
            refused = f.read().split()
    except FileNotFoundError:
        refused = []
    if t in refused:
        return _error("resource_limit_exceeded", "shared core limit exceeded", 403)
    if (t, loc) not in _stock():
        return _error("resource_unavailable", f"{t} is unavailable in {loc}", 412)
    for f in body.get("firewalls", []):
        if f.get("firewall") != 42:
            return _error("not_found", "firewall not found", 404)
    COUNTER[0] += 1
    sid = str(COUNTER[0])
    proc = None
    if not os.path.exists(os.path.join(DIR, "no-run")):
        script = os.path.join(DIR, f"server-{sid}.sh")
        with open(script, "w") as f:
            f.write(body.get("user_data", ""))
        log = open(os.path.join(DIR, f"server-{sid}.log"), "w")
        env = dict(os.environ, HOSTNAME=name, SERVER_NAME=name,
                   MORCA_BOOT_DIR=os.path.join(DIR, f"boot-{sid}"),
                   MORCA_HOST_GPUS="1" if t in GPU_TYPES else "0")
        proc = subprocess.Popen(["sh", script], stdout=log, stderr=log, env=env, cwd=DIR,
                                start_new_session=True)
    for n in body.get("networks", []):
        if str(n) not in NETWORKS:
            return _error("not_found", f"network {n} not found", 404)
    SERVERS[sid] = {"name": name, "type": t, "location": loc,
                    "labels": body.get("labels", {}), "proc": proc, "status": "running",
                    "networks": [int(n) for n in body.get("networks", [])]}
    return 201, {"server": _server(sid, SERVERS[sid]), "action": {"id": 1, "status": "running"}}


def _kill_group(s):
    """Kills what's left of server `s`'s processes, once: its script's
    process group (its own session)."""
    if s["proc"] is None or s.get("gone"):
        return
    s["gone"] = True
    try:
        os.killpg(s["proc"].pid, signal.SIGKILL)
    except OSError:
        pass  # gone; macOS says EPERM for a group of only a zombie


def _reap():
    """A server whose script exited is off: what it left running goes
    with it."""
    while True:
        with LOCK:
            for s in SERVERS.values():
                if s["proc"] is not None and not s.get("gone") and s["proc"].poll() is not None:
                    _kill_group(s)
        time.sleep(0.2)


def _delete(sid):
    s = SERVERS.pop(sid, None)
    if s is None:
        return _error("not_found", "server not found", 404)
    _kill_group(s)
    return 200, {"action": {"id": 2, "command": "delete_server", "status": "running"}}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _reply(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode() if n else ""
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)
        with LOCK:
            with open(os.path.join(DIR, "calls.jsonl"), "a") as f:
                f.write(json.dumps({"method": method, "path": self.path, "body": raw}) + "\n")
            if url.path == "/token":
                return self._reply(200, {"token": "reg-token"})
            m = re.fullmatch(r"/v2/(.+)/manifests/([^/]+)", url.path)
            if m and method == "GET":
                if self.headers.get("Authorization") != "Bearer reg-token":
                    return self._reply(401, {"errors": [{"code": "UNAUTHORIZED"}]})
                try:
                    with open(os.path.join(DIR, "arches")) as f:
                        arches = f.read().split()
                except FileNotFoundError:
                    arches = ["amd64", "arm64"]
                ms = [{"mediaType": "application/vnd.oci.image.manifest.v1+json",
                       "digest": f"sha256:{a}", "size": 1,
                       "platform": {"architecture": a, "os": "linux"}} for a in arches]
                ms.append({"mediaType": "application/vnd.oci.image.manifest.v1+json",
                           "digest": "sha256:att", "size": 1,
                           "platform": {"architecture": "unknown", "os": "unknown"}})
                return self._reply(200, {"schemaVersion": 2,
                                         "mediaType": "application/vnd.oci.image.index.v1+json",
                                         "manifests": ms})
            if self.headers.get("Authorization") != "Bearer test-token":
                return self._reply(*_error("unauthorized", "unable to authenticate", 401))
            path = url.path
            if method == "GET" and path == "/v1/server_types":
                name = q.get("name", [""])[0]
                types = [{"name": t, "architecture": _arch(t)} for t in TYPES if not name or t == name]
                return self._reply(200, {"server_types": types})
            if method == "GET" and path == "/v1/firewalls":
                name = q.get("name", [""])[0]
                fws = [{"id": 42, "name": "morca-lab"}] if name in ("", "morca-lab") else []
                return self._reply(200, {"firewalls": fws})
            if method == "GET" and path == "/v1/networks":
                name = q.get("name", [""])[0]
                nets = [{"id": int(k), "name": v["name"], "ip_range": v["ip_range"]}
                        for k, v in NETWORKS.items() if not name or v["name"] == name]
                return self._reply(200, {"networks": nets})
            if method == "POST" and path == "/v1/networks":
                b = json.loads(raw or "{}")
                if any(v["name"] == b.get("name") for v in NETWORKS.values()):
                    return self._reply(*_error("uniqueness_error", "network name is already used", 409))
                nid = str(500 + len(NETWORKS))
                NETWORKS[nid] = {"name": b.get("name", ""), "ip_range": b.get("ip_range", ""),
                                 "zone": (b.get("subnets") or [{}])[0].get("network_zone", "")}
                return self._reply(201, {"network": {"id": int(nid), "name": NETWORKS[nid]["name"],
                                                     "ip_range": NETWORKS[nid]["ip_range"]}})
            if method == "POST" and path == "/v1/servers":
                return self._reply(*_create(json.loads(raw or "{}")))
            if method == "GET" and path == "/v1/servers":
                sel = q.get("label_selector", [""])[0]
                page = int(q.get("page", ["1"])[0])
                per = int(q.get("per_page", ["25"])[0])
                all_ = [_server(k, v) for k, v in sorted(SERVERS.items()) if _matches(v["labels"], sel)]
                chunk = all_[(page - 1) * per: page * per]
                nxt = page + 1 if page * per < len(all_) else None
                return self._reply(200, {"servers": chunk,
                                         "meta": {"pagination": {"page": page, "next_page": nxt}}})
            m = re.fullmatch(r"/v1/servers/(\d+)", path)
            if method == "DELETE" and m:
                return self._reply(*_delete(m.group(1)))
            return self._reply(*_error("not_found", f"{method} {path}", 404))

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_DELETE(self):
        self._handle("DELETE")


def _stop(*_):
    for s in list(SERVERS.values()):
        _kill_group(s)
    sys.exit(0)


signal.signal(signal.SIGTERM, _stop)
threading.Thread(target=_reap, daemon=True).start()
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
