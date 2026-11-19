"""A stand-in for Cloudflare Turnstile's siteverify, for tests/ui_drain.sh.

    python3 tests/fake_siteverify.py <port> <file>

Every POST's form is appended to <file> as a line of JSON. The token `pass`
passes (action `data`, hostname 127.0.0.1); any other fails. Nothing is
ever sent anywhere else.
"""

import http.server
import json
import sys
import urllib.parse

PORT = int(sys.argv[1])
FILE = sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        form = urllib.parse.parse_qs(self.rfile.read(n).decode("utf-8", "replace"))
        form = {k: v[0] for k, v in form.items()}
        with open(FILE, "a") as f:
            f.write(json.dumps(form) + "\n")
        if form.get("response") == "pass":
            out = {"success": True, "action": "data", "hostname": "127.0.0.1"}
        else:
            out = {"success": False, "error-codes": ["invalid-input-response"]}
        b = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
