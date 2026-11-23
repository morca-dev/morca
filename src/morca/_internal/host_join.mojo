"""`morca host join`: sets this machine up as a worker of a pool, as a
service that keeps it running (#220).

```
morca host join <url> --pool <pool> --token-file <path>
                [--name <name>] [--service systemd|launchd] [--container]
                [--image <image>] [--env-file <path>]... [--set NAME=value]...
                [--advertise <address>] [--dir <dir>] [--user <user>]
                [--binary <path>] [--root <dir>] [--dry-run]
morca host join --uninstall --pool <pool> [--root <dir>] [--dry-run]
```

It runs on the machine, with no database. It asks the UI's
`/api/worker/join` with the token (`morca worker-token create` on the
server, in a file of mode 600 on its first line) for the pool's volumes and
`max_runs` and the server's worker image, which also checks the token is a
live one of that pool, then writes:

| | |
|---|---|
| `/etc/morca/worker-<pool>.env` | the worker's own settings (`MORCA_REMOTE`, `--set`s), mode 600; no secret |
| `/etc/morca/host-<pool>.json` | what was installed, for `--uninstall`; in a container, the image it runs |
| systemd (Linux) | `/etc/systemd/system/morca-worker-<pool>.service`, `Restart=always` but not after exit 3 (its token refused) |
| launchd (macOS) | `/Library/LaunchDaemons/dev.morca.worker.<pool>.plist`, `KeepAlive`, its log in `/var/log/morca-worker-<pool>.log` |
| `--container` | `/etc/morca/worker-<pool>-container.sh`, a loop that runs the image (`docker run --rm`) with the token file, the env files and the pool's volumes mounted, and moves it to the server's image after a deploy (`morca._internal.host_follow`); the systemd unit or launchd job above runs the script instead of `morca worker` |

and starts it (`systemctl enable` and `restart`, or `launchctl
bootstrap`). A service's worker gets `--host-service <kind>`, a
container's `--host-image <image>`: what it reports of the server's image,
and whether it follows it (`morca._internal.host_follow`). The token stays in the file the user named, which the service
reads (`morca worker --token-file`); the bucket's keys and other secrets
stay in the user's own `--env-file`s (mode 600 too), which the service
reads in place. Nothing printed or written holds a secret.

`--root <dir>` writes every file under `<dir>` instead of `/`, with the
paths in them under it too, and starts nothing; `--dry-run` prints the
files and what it would run, and writes nothing. `--uninstall` stops the
service and removes what `host-<pool>.json` lists; the token stays live on
the server until `morca host remove`.
"""

from std.ffi import c_int, external_call
from std.os import getenv, makedirs, remove
from std.os.path import exists
from std.sys import argv
from std.sys.info import CompilationTarget

from json import Value, loads

from morca._common.paths import absolute
from morca._internal.control import pool_problem
from morca._internal.host_follow import container_script
from morca._internal.http_store import Body, StateApi
from morca._internal.json import quote
from morca._internal.pool_boot import JOIN_PATH
from morca._internal.pool_config import volume_problem
from morca._internal.proc import capture
from morca._internal.sample import _hostname
from morca._internal.secrets import env_name_problem
from morca._internal.store import FINAL
from morca._internal.tokens import is_token

comptime SYSTEMD = "systemd"
comptime LAUNCHD = "launchd"
comptime CONTAINER = "container"
comptime TOKEN_IN_CONTAINER = "/etc/morca/token"
"""Where a container has the token file, read-only."""
comptime STAGE_IN_CONTAINER = "/var/lib/morca/stage"
comptime JOIN_USAGE = """usage:
  morca host join <url> --pool <pool> --token-file <path> [--name <name>]
                  [--service systemd|launchd] [--container] [--image <image>]
                  [--env-file <path>]... [--set NAME=value]...
                  [--advertise <address>] [--dir <dir>] [--user <user>]
                  [--binary <path>] [--root <dir>] [--dry-run]
  morca host join --uninstall --pool <pool> [--root <dir>] [--dry-run]"""


def word_problem(what: String, s: String) -> String:
    """Why `s` can't be a word of a service file or a shell line as it is,
    or empty: no space, quote, backslash, `$`, backtick, `%` (systemd's
    specifiers), `;`, `&`, `<`, `>` or control character."""
    if not s:
        return String(what, " is empty")
    for b in s.as_bytes():
        if (
            b <= 0x20
            or b == 0x7F
            or b == UInt8(ord("'"))
            or b == UInt8(ord('"'))
            or b == UInt8(ord("\\"))
            or b == UInt8(ord("$"))
            or b == UInt8(ord("`"))
            or b == UInt8(ord("%"))
            or b == UInt8(ord(";"))
            or b == UInt8(ord("&"))
            or b == UInt8(ord("<"))
            or b == UInt8(ord(">"))
        ):
            return String(
                what,
                " can't have a space, a quote or ",
                "$ ` % ; & < > \\: ",
                quote(s),
            )
    return ""


def _xml(s: String) -> String:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


@fieldwise_init
struct JoinPlan(Copyable, Movable):
    """What `morca host join` installs, and where."""

    var service: String
    """`SYSTEMD`, `LAUNCHD` or `CONTAINER`."""
    var pool: String
    var remote: String
    var name: String
    var binary: String
    """The `morca` the service runs (not in a container: the image's)."""
    var token_file: String
    var env_files: List[String]
    """The user's own env files, read in place."""
    var settings: List[Tuple[String, String]]
    """`--set`s, written to its own env file."""
    var root: String
    """Where the files go: `/`, or a directory to write them under."""
    var dir: String
    """Where the worker stages runs' output; empty for the default."""
    var advertise: String
    var image: String
    """The container's image (empty for a service)."""
    var volumes: List[String]
    """The pool's, mounted in a container."""
    var user: String
    """The user a service runs as; empty for root."""
    var supervisor: String
    """In a container, `SYSTEMD` or `LAUNCHD`: what runs its script."""

    def _kind(self) -> String:
        """`SYSTEMD` or `LAUNCHD`: what keeps it running."""
        return self.supervisor if self.service == CONTAINER else self.service

    def _prefix(self) -> String:
        return String("") if self.root == "/" else String(self.root.rstrip("/"))

    def unit_name(self) -> String:
        """The systemd unit's and the container's name."""
        return String("morca-worker-", self.pool)

    def label(self) -> String:
        """The launchd job's label."""
        return String("dev.morca.worker.", self.pool)

    def etc(self) -> String:
        return String(self._prefix(), "/etc/morca")

    def record_path(self) -> String:
        return String(self.etc(), "/host-", self.pool, ".json")

    def env_path(self) -> String:
        return String(self.etc(), "/worker-", self.pool, ".env")

    def service_path(self) -> String:
        """The unit, the plist or the container's script."""
        if self.service == CONTAINER:
            return self.script_path()
        return self.unit_path()

    def script_path(self) -> String:
        return String(self.etc(), "/worker-", self.pool, "-container.sh")

    def unit_path(self) -> String:
        """The systemd unit or the plist that keeps it running."""
        if self._kind() == SYSTEMD:
            return String(
                self._prefix(),
                "/etc/systemd/system/",
                self.unit_name(),
                ".service",
            )
        return String(
            self._prefix(),
            "/Library/LaunchDaemons/",
            self.label(),
            ".plist",
        )

    def log_path(self) -> String:
        return String(self._prefix(), "/var/log/", self.unit_name(), ".log")

    def stage(self) -> String:
        if self.dir:
            return self.dir
        return String(self._prefix(), "/var/lib/morca/", self.pool, "/stage")

    def problem(self) -> String:
        """Why this can't be installed, or empty."""
        var why = pool_problem(self.pool)
        if why:
            return why
        if not self.remote.startswith(
            "https://"
        ) and not self.remote.startswith("http://"):
            return String(
                "the UI's URL is https:// or http://, not ", self.remote
            )
        if not self.token_file.startswith("/"):
            return "the token file's path is absolute"
        var words: List[Tuple[String, String]] = [
            ("the UI's URL", self.remote),
            ("the name", self.name),
            ("the token file's path", self.token_file),
            ("the root", self.root),
            ("the stage directory", self.stage()),
        ]
        if self.service != CONTAINER:
            words.append(("the morca binary's path", self.binary))
        else:
            words.append(("the image", self.image))
        if self.advertise:
            words.append(("--advertise", self.advertise))
        if self.user:
            words.append(("--user", self.user))
        for f in self.env_files:
            words.append(("an env file's path", f))
        for w in words:
            var p = word_problem(w[0], w[1])
            if p:
                return p
        for s in self.settings:
            var p = env_name_problem(s[0])
            if p:
                return String("--set ", p)
            for b in s[1].as_bytes():
                if b < 0x20 or b == 0x7F:
                    return String("--set ", s[0], " has a control character")
        for v in self.volumes:
            var p = volume_problem(v)
            if p:
                return String("the pool's volumes: ", p)
        return ""

    def env_text(self) -> String:
        """Its own env file: what the worker needs that isn't a secret."""
        var out = String(
            "# morca host join: pool ",
            self.pool,
            "'s worker (morca._internal.host_join).\n",
            "# No secrets: the token is in ",
            self.token_file,
            ", the rest in the env files the service names.\n",
            "MORCA_REMOTE=",
            self.remote,
            "\n",
        )
        for s in self.settings:
            out.write(s[0], "=", s[1], "\n")
        return out^

    def worker_args(self) -> List[String]:
        """The service's command line (not in a container)."""
        var out: List[String] = [
            self.binary,
            "worker",
            "--pool",
            self.pool,
            "--remote",
            self.remote,
            "--token-file",
            self.token_file,
            "--name",
            self.name,
            "--dir",
            self.stage(),
            "--env-file",
            self.env_path(),
        ]
        for f in self.env_files:
            out.append("--env-file")
            out.append(f)
        if self.advertise:
            out.append("--advertise")
            out.append(self.advertise)
        out.append("--host-service")
        out.append(self.service)
        return out^

    def program_args(self) -> List[String]:
        """What the unit or the plist runs: the worker, or the container's
        script."""
        if self.service == CONTAINER:
            return ["/bin/sh", self.script_path()]
        return self.worker_args()

    def unit_text(self) -> String:
        """The systemd unit."""
        var out = String(
            "# morca host join: pool ",
            self.pool,
            "'s worker (morca._internal.host_join).\n",
            "[Unit]\n",
            "Description=morca worker ",
            self.name,
            " of pool ",
            self.pool,
            "\n",
            "After=network-online.target",
            " docker.service\n" if self.service == CONTAINER else "\n",
            "Wants=network-online.target\n\n",
            "[Service]\n",
            "ExecStart=",
            " ".join(self.program_args()),
            "\n",
            "Restart=always\n",
            "RestartSec=5\n",
            "# Exit 3: its token was refused (revoked: morca host remove).\n",
            "RestartPreventExitStatus=3\n",
        )
        if self.service == CONTAINER:
            out.write(
                'ExecStopPost=-/bin/sh -c "docker rm -f ',
                self.unit_name(),
                ' > /dev/null 2>&1"\n',
            )
        if self.user:
            out.write("User=", self.user, "\n")
        out.write("\n[Install]\nWantedBy=multi-user.target\n")
        return out^

    def plist_text(self) -> String:
        """The launchd job."""
        var out = String(
            '<?xml version="1.0" encoding="UTF-8"?>\n',
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"',
            ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n',
            "<!-- morca host join: pool ",
            _xml(self.pool),
            "'s worker (morca._internal.host_join). -->\n",
            '<plist version="1.0">\n<dict>\n',
            "  <key>Label</key>\n  <string>",
            _xml(self.label()),
            "</string>\n",
            "  <key>ProgramArguments</key>\n  <array>\n",
        )
        for a in self.program_args():
            out.write("    <string>", _xml(a), "</string>\n")
        out.write(
            "  </array>\n",
            "  <key>RunAtLoad</key>\n  <true/>\n",
            "  <key>KeepAlive</key>\n  <true/>\n",
            "  <key>ThrottleInterval</key>\n  <integer>30</integer>\n",
            "  <key>StandardOutPath</key>\n  <string>",
            _xml(self.log_path()),
            "</string>\n",
            "  <key>StandardErrorPath</key>\n  <string>",
            _xml(self.log_path()),
            "</string>\n",
        )
        if self.user:
            out.write(
                "  <key>UserName</key>\n  <string>",
                _xml(self.user),
                "</string>\n",
            )
        out.write("</dict>\n</plist>\n")
        return out^

    def docker_head(self) -> List[String]:
        """`docker run` of the worker up to its image: the token file, its
        stage and the pool's volumes mounted, its env files given, in the
        foreground (its script starts it again)."""
        var out: List[String] = [
            "docker",
            "run",
            "--rm",
            "--name",
            self.unit_name(),
            "--env-file",
            self.env_path(),
        ]
        for f in self.env_files:
            out.append("--env-file")
            out.append(f)
        out.append("-v")
        out.append(String(self.token_file, ":", TOKEN_IN_CONTAINER, ":ro"))
        out.append("-v")
        out.append(String(self.stage(), ":", STAGE_IN_CONTAINER))
        for v in self.volumes:
            out.append("-v")
            out.append(v)
        if self.advertise:
            # A run spread over the pool's machines reaches dista's ports
            # on this address.
            out.append("--network")
            out.append("host")
        return out^

    def docker_tail(self) -> List[String]:
        """The worker's arguments, after the image (`--host-image` last)."""
        var out: List[String] = [
            "worker",
            "--pool",
            self.pool,
            "--remote",
            self.remote,
            "--token-file",
            TOKEN_IN_CONTAINER,
            "--name",
            self.name,
            "--dir",
            STAGE_IN_CONTAINER,
        ]
        if self.advertise:
            out.append("--advertise")
            out.append(self.advertise)
        return out^

    def docker_args(self) -> List[String]:
        """The container's `docker run`, on the image it runs now."""
        var out = self.docker_head()
        out.append(self.image)
        for a in self.docker_tail():
            out.append(a)
        out.append("--host-image")
        out.append(self.image)
        return out^

    def container_script(self) -> String:
        """The loop that runs the container, and replaces it on the
        server's image (`morca._internal.host_follow`)."""
        comptime AT = "@IMAGE@"
        var rec = self._record(AT)
        var at = rec.find(AT).or_else(0)
        return container_script(
            self.pool,
            self.unit_name(),
            self.record_path(),
            self.stage(),
            self.docker_head(),
            self.docker_tail(),
            String(rec[byte=:at]),
            String(rec[byte = at + AT.byte_length() :]),
        )

    def service_text(self) -> String:
        if self.service == SYSTEMD:
            return self.unit_text()
        if self.service == LAUNCHD:
            return self.plist_text()
        return self.container_script()

    def unit_file_text(self) -> String:
        """A container's unit or plist, which runs its script."""
        if self.supervisor == SYSTEMD:
            return self.unit_text()
        return self.plist_text()

    def _record(self, image: String) -> String:
        var b = (
            Body()
            .text("pool", self.pool)
            .text("service", self.service)
            .text("remote", self.remote)
            .text("name", self.name)
            .text("image", image)
            .text("token_file", self.token_file)
            .text("service_file", self.service_path())
            .text("env_file", self.env_path())
            .text("unit", self.unit_name())
            .text("label", self.label())
        )
        if self.service == CONTAINER:
            b = b^.text("supervisor", self.supervisor).text(
                "unit_file", self.unit_path()
            )
        return b^.finish()

    def record_json(self) -> String:
        """`host-<pool>.json`: what was installed (in a container, the
        image it runs, which its script rewrites when it moves)."""
        return self._record(self.image)

    def start_commands(self) -> List[List[String]]:
        """What starts it, once its files are in place."""
        var out = List[List[String]]()
        if self._kind() == SYSTEMD:
            out.append(["systemctl", "daemon-reload"])
            out.append(["systemctl", "enable", self.unit_name()])
            out.append(["systemctl", "restart", self.unit_name()])
        else:
            out.append(
                ["launchctl", "bootout", String("system/", self.label())]
            )
            out.append(["launchctl", "bootstrap", "system", self.unit_path()])
        return out^


def stop_commands(
    service: String, unit: String, label: String, supervisor: String = ""
) -> List[List[String]]:
    """What stops an installed one, before its files are removed (a
    container `supervisor` runs: its service, then the container)."""
    var out = List[List[String]]()
    var kind = supervisor if service == CONTAINER else service
    if kind == SYSTEMD:
        out.append(["systemctl", "disable", "--now", unit])
    elif kind == LAUNCHD:
        out.append(["launchctl", "bootout", String("system/", label)])
    if service == CONTAINER:
        out.append(["docker", "rm", "-f", unit])
    return out^


def default_service() -> String:
    comptime if CompilationTarget.is_linux():
        return SYSTEMD
    else:
        return LAUNCHD


def private_problem(path: String) -> String:
    """Why the file at `path` isn't a private file (only its owner may read
    or write it), or empty."""
    if not exists(path):
        return String(path, " doesn't exist")
    var got: Tuple[Int, String]
    try:
        got = capture(["ls", "-ln", path], 10)
    except e:
        return String("can't read ", path, "'s mode: ", e)
    var out = got[1]
    if got[0] != 0 or out.byte_length() < 10:
        return String("can't read ", path, "'s mode")
    var group_other = String(out[byte=4:10])
    if group_other != "------":
        return String(
            path,
            " is readable by others (",
            String(out[byte=0:10]),
            "): chmod 600 it",
        )
    return ""


def _binary() raises -> String:
    """This `morca`'s path: argv[0], made absolute, else found on PATH."""
    var a = String(argv()[0])
    if "/" in a:
        return absolute(a)
    for d in getenv("PATH").split(":"):
        var p = String(d, "/", a)
        if d and exists(p):
            return absolute(p)
    return a


def _cstr(s: String) -> List[UInt8]:
    var b = List[UInt8](capacity=s.byte_length() + 1)
    for c in s.as_bytes():
        b.append(c)
    b.append(0)
    return b^


def _dir_of(path: String) -> String:
    var i = path.rfind("/").or_else(-1)
    return String(path[byte=:i]) if i > 0 else String("/")


def write_file(path: String, text: String, mode: Int) raises:
    """Writes `text` to `path`, made with no access for others, then
    `mode`."""
    makedirs(_dir_of(path), exist_ok=True)
    var old = external_call["umask", c_int](c_int(0o077))
    try:
        with open(path, "w") as f:
            f.write(text)
    finally:
        _ = external_call["umask", c_int](old)
    var c = _cstr(path)
    if external_call["chmod", c_int](c.unsafe_ptr(), c_int(mode)) != 0:
        raise Error("morca: can't chmod ", path)


def _mode_text(mode: Int) -> String:
    return String((mode >> 6) & 7, (mode >> 3) & 7, mode & 7)


def _run(cmd: List[String]) raises -> Int:
    print("running:", " ".join(cmd))
    var got = capture(cmd, 120)
    if got[1]:
        print(got[1], end="")
    return got[0]


def _usage(msg: String) -> Int:
    print(msg)
    print(JOIN_USAGE)
    return 2


def _uninstall(pool: String, root: String, dry_run: Bool) raises -> Int:
    var probe = JoinPlan(
        SYSTEMD,
        pool,
        "",
        "",
        "",
        "",
        List[String](),
        List[Tuple[String, String]](),
        root,
        "",
        "",
        "",
        List[String](),
        "",
        "",
    )
    var record = probe.record_path()
    if not exists(record):
        raise Error(
            "morca: no morca host join of pool ", pool, " here (", record, ")"
        )
    var r: String
    with open(record, "r") as f:
        r = f.read()
    var v = loads(r)
    var service = v["service"].string_value()
    # A container's supervisor; none in a record from before it had one,
    # whose container ran on docker's restart policy alone.
    var supervisor = (
        v["supervisor"].string_value() if String("supervisor")
        in v else String()
    )
    if root == "/":
        for c in stop_commands(
            service,
            v["unit"].string_value(),
            v["label"].string_value(),
            supervisor,
        ):
            if dry_run:
                print("would run:", " ".join(c))
            else:
                _ = _run(c)  # gone already is fine
    var keys: List[String] = ["service_file", "unit_file", "env_file"]
    for key in keys:
        if key not in v:
            continue
        var p = v[key].string_value()
        if dry_run:
            print("would remove", p)
        elif exists(p):
            remove(p)
            print("removed", p)
    if dry_run:
        print("would remove", record)
    else:
        remove(record)
        print("removed", record)
        print(
            "pool",
            pool,
            "'s worker is uninstalled here; its token stays live on the",
            " server until morca host remove",
            sep="",
        )
    return 0


def host_join_command(args: List[String]) raises -> Int:
    """`morca host join ...` (`args` from `morca`)."""
    var url = String()
    var pool = String()
    var token_file = String()
    var name = _hostname()
    var service = String()
    var container = False
    var image = String()
    var root = String("/")
    var dir = String()
    var advertise = String()
    var user = String()
    var binary = String()
    var env_files = List[String]()
    var settings = List[Tuple[String, String]]()
    var dry_run = False
    var uninstall = False
    var i = 3
    while i < len(args):
        var a = args[i]
        if a == "--container":
            container = True
            i += 1
            continue
        if a == "--dry-run":
            dry_run = True
            i += 1
            continue
        if a == "--uninstall":
            uninstall = True
            i += 1
            continue
        if not a.startswith("--"):
            if url:
                return _usage(String("one URL, not also ", a))
            url = a
            i += 1
            continue
        if i + 1 >= len(args):
            return _usage(String(a, " needs a value"))
        var val = args[i + 1]
        if a == "--pool":
            pool = val
        elif a == "--token-file":
            token_file = absolute(val)
        elif a == "--name":
            name = val
        elif a == "--service":
            if val != SYSTEMD and val != LAUNCHD:
                return _usage("--service is systemd or launchd")
            service = val
        elif a == "--image":
            image = val
        elif a == "--root":
            root = absolute(val)
        elif a == "--dir":
            dir = absolute(val)
        elif a == "--advertise":
            advertise = val
        elif a == "--user":
            user = val
        elif a == "--binary":
            binary = absolute(val)
        elif a == "--env-file":
            env_files.append(absolute(val))
        elif a == "--set":
            var eq = val.find("=").or_else(-1)
            if eq <= 0:
                return _usage("--set is NAME=value")
            settings.append(
                (String(val[byte=:eq]), String(val[byte = eq + 1 :]))
            )
        else:
            return _usage(String("unknown argument: ", a))
        i += 2
    if not pool:
        return _usage("morca host join needs --pool <pool>")
    var why = pool_problem(pool)
    if why:
        return _usage(String("morca: ", why))
    if uninstall:
        return _uninstall(pool, root, dry_run)
    if not url:
        url = getenv("MORCA_REMOTE")
    if not url:
        return _usage("morca host join needs the UI's URL")
    if not url.startswith("http://") and not url.startswith("https://"):
        url = String("https://", url)
    var bare = String(url.rstrip("/"))
    url = bare^
    if not token_file:
        return _usage(
            "morca host join needs --token-file <path>: a file of mode 600"
            " with the token (morca worker-token create --pool <pool> on the"
            " server) on its first line"
        )
    # The token and the user's env files hold secrets: only their owner
    # may read them.
    var private: List[String] = [token_file]
    for f in env_files:
        private.append(f)
    for f in private:
        var p = private_problem(f)
        if p:
            raise Error("morca: ", p)
    var token: String
    with open(token_file, "r") as f:
        token = String(f.read().split("\n")[0].strip())
    if not is_token(token):
        raise Error("morca: ", token_file, "'s first line isn't a token")
    # The server checks the token is a live one of the pool, and says
    # what the pool's machines are set up with.
    var answer: Value
    try:
        answer = StateApi(url, token).request_once(
            JOIN_PATH,
            Body().text("pool", pool).text("name", name).finish(),
        )
    except e:
        var msg = String(e)
        if msg.startswith(FINAL):
            raise Error(
                "morca: the server refused the join: ",
                String(msg[byte = FINAL.byte_length() :]),
            )
        raise e^
    var vols = List[String]()
    if String("volumes") in answer:
        for v in answer["volumes"].array_items():
            vols.append(v.string_value())
    var kind = CONTAINER if container else (
        service if service else default_service()
    )
    # A container is run by a script, which the service keeps running.
    var supervisor = (service if service else default_service()) if (
        container
    ) else String()
    if kind == CONTAINER and not image:
        image = (
            answer["image"].string_value() if String("image")
            in answer else String()
        )
        if not image:
            raise Error(
                "morca: the server runs no MORCA_WORKER_IMAGE to start: give",
                " --image <image>",
            )
    if kind != CONTAINER:
        image = String()
        if not binary:
            binary = _binary()
        if len(vols) > 0:
            print(
                "note: pool",
                pool,
                "has volumes",
                ", ".join(vols),
                "- they apply only with --container",
            )
        vols = List[String]()
    var plan = JoinPlan(
        kind,
        pool,
        url,
        name,
        binary,
        token_file,
        env_files^,
        settings^,
        root,
        dir,
        advertise,
        image,
        vols^,
        user,
        supervisor,
    )
    var problem = plan.problem()
    if problem:
        raise Error("morca: ", problem)
    var files: List[Tuple[String, String, Int]] = [
        (plan.env_path(), plan.env_text(), 0o600),
        (
            plan.service_path(),
            plan.service_text(),
            0o700 if kind == CONTAINER else 0o644,
        ),
        (plan.record_path(), plan.record_json() + "\n", 0o600),
    ]
    if kind == CONTAINER:
        files.append((plan.unit_path(), plan.unit_file_text(), 0o644))
    var start = plan.start_commands()
    if dry_run:
        for f in files:
            print("== ", f[0], " (mode ", _mode_text(f[2]), ")", sep="")
            print(f[1], end="")
        if root == "/":
            for c in start:
                print("would run:", " ".join(c))
        return 0
    if kind != CONTAINER:
        makedirs(plan.stage(), exist_ok=True)
    for f in files:
        write_file(f[0], f[1], f[2])
        print("wrote", f[0])
    if root != "/":
        print("--root: the files only, under", root, "- nothing started")
        return 0
    for c in start:
        var code = _run(c)
        if code != 0 and c[1] != "bootout":
            raise Error("morca: ", " ".join(c), " exited ", code)
    print(
        "pool",
        pool,
        ": worker",
        name,
        "runs as",
        kind,
        String("(", plan.service_path(), ")"),
        "- morca host list on the server shows it",
    )
    return 0
