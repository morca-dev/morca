"""A hand-joined host following the server's worker image after a deploy
(#220): the worker's side, and the script that replaces its container.

The UI's claim answer carries the image the server's pool workers run
(`"worker_image"`, its `MORCA_WORKER_IMAGE`, when it has one), and
`"upgrade": true` once after `morca host upgrade <id>`. A worker that
doesn't know them ignores them, and an older UI sends neither: nothing
changes.

**In a container** (`morca host join --container`), the worker is started
with `--host-image <image>`, the image its container runs. When the
server's differs it drains itself: it claims nothing new, finishes the runs
it has, then writes the image it wants to `<dir>/.host-upgrade` and exits
`UPGRADE_EXIT` (4). A process can't replace its own container, so the
container is run by `container_script`, a loop that `morca host join`
installs under systemd or launchd: on exit 4 it pulls the new image, writes
it into `host-<pool>.json` and starts the container on it. When the pull
fails (no login for the registry, say), or the new container exits within
`START_GRACE` seconds, it writes why to `<dir>/.host-upgrade-failed` and
starts the old image again; the worker reads that file, says why, claims
again, and doesn't try that image again until it's asked to (`morca host
upgrade`) or the server's image moves on. A worker started again on its old
image with `.host-upgrade` still there (nothing replaced its container)
counts that as a failure too, so it never drains in a loop. No login is
written anywhere: a pull uses what `docker login` keeps.

**As a service** (systemd or launchd, `--host-service <kind>`) the worker
is a binary it can't swap. When the server's image isn't its own
(`MORCA_IMAGE`) it says so once, reports `needs-upgrade`, and keeps
working.

Each claim reports `host_image` and `host_upgrade` (`state()`: `current`,
`draining`, `failed` or `needs-upgrade`, then the server's image), which
`orca.workers` keeps for `morca host list`.
"""

from std.os import remove
from std.os.path import exists

from json import Value

comptime UPGRADE_EXIT = 4
"""The worker's exit code once it drained to move to the server's image."""
comptime WANT_FILE = ".host-upgrade"
"""In the worker's `--dir`: the image it exited to be started on."""
comptime FAILED_FILE = ".host-upgrade-failed"
"""In the worker's `--dir`: an image the host couldn't move to, then why."""
comptime START_GRACE = 60
"""Seconds a new image's container must run for its start to count."""


def image_problem(s: String) -> String:
    """Why `s` isn't an image reference this can pass on, or empty: letters,
    digits and `. _ - / : @` only, at most 255 bytes."""
    if not s:
        return "no image"
    if s.byte_length() > 255:
        return "an image reference longer than 255 bytes"
    for b in s.as_bytes():
        var ok = (
            (b >= UInt8(ord("a")) and b <= UInt8(ord("z")))
            or (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
            or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
            or b == UInt8(ord("."))
            or b == UInt8(ord("_"))
            or b == UInt8(ord("-"))
            or b == UInt8(ord("/"))
            or b == UInt8(ord(":"))
            or b == UInt8(ord("@"))
        )
        if not ok:
            return String("not an image reference: ", s)
    return ""


def _read(path: String) -> List[String]:
    """`path`'s lines, or none if it can't be read."""
    var out = List[String]()
    try:
        with open(path, "r") as f:
            for l in f.read().split("\n"):
                out.append(String(l.strip()))
    except:
        pass
    return out^


struct Follow(Copyable, Movable):
    """What a worker `morca host join` installed knows of the server's
    image, and what it does about it."""

    var host_image: String
    """The image its container runs (`--host-image`); empty if none."""
    var service: String
    """`systemd` or `launchd` (`--host-service`); empty if none."""
    var own: String
    """The worker's own image (`MORCA_IMAGE`), for a service."""
    var dir: String
    """The worker's `--dir`, where the markers are."""
    var server: String
    """The server's worker image, as its last answer said; empty for none."""
    var failed: String
    """An image the host couldn't move to, not tried again unless asked."""
    var why: String
    """Why it couldn't."""

    def __init__(
        out self, host_image: String, service: String, own: String, dir: String
    ):
        self.host_image = host_image
        self.service = service
        self.own = own
        self.dir = dir
        self.server = String()
        self.failed = String()
        self.why = String()

    def following(self) -> Bool:
        return Bool(self.host_image) or Bool(self.service)

    def _path(self, name: String) -> String:
        return String(self.dir.rstrip("/"), "/", name)

    def start(mut self):
        """Reads what the script left in `--dir`: an upgrade that failed, or
        one it was asked for and didn't make."""
        if not self.host_image:
            return
        var failed = _read(self._path(FAILED_FILE))
        if len(failed) > 0 and failed[0]:
            if failed[0] == self.host_image:
                # It runs that image now after all.
                self._forget()
            else:
                self.failed = failed[0]
                self.why = failed[1] if len(failed) > 1 else String()
                self._say_failed()
        var want = _read(self._path(WANT_FILE))
        if len(want) > 0 and want[0]:
            try:
                remove(self._path(WANT_FILE))
            except:
                pass
            if want[0] == self.host_image:
                print("morca worker: the host moved to", want[0], flush=True)
            else:
                self._fail(
                    want[0],
                    String(
                        "its container was started again on ",
                        self.host_image,
                        ", not on ",
                        want[0],
                        ": nothing replaced it (is it run by the script",
                        " morca host join --container installed?)",
                    ),
                )

    def _say_failed(self):
        print(
            "morca worker: the host couldn't move to ",
            self.failed,
            String(" (", self.why, ")") if self.why else String(),
            ": it claims runs on ",
            self.host_image,
            ", and morca host upgrade tries again",
            sep="",
            flush=True,
        )

    def _forget(mut self):
        self.failed = String()
        self.why = String()
        try:
            if exists(self._path(FAILED_FILE)):
                remove(self._path(FAILED_FILE))
        except:
            pass

    def _fail(mut self, image: String, why: String):
        self.failed = image
        self.why = why
        self._say_failed()
        try:
            with open(self._path(FAILED_FILE), "w") as f:
                f.write(image, "\n", why, "\n")
        except:
            pass

    def draining(self) -> Bool:
        """Whether it claims nothing new, to move to the server's image."""
        return (
            Bool(self.host_image)
            and Bool(self.server)
            and self.server != self.host_image
            and self.server != self.failed
        )

    def state(self) -> String:
        """`host_upgrade` as a claim reports it: the state, then the
        server's image; empty when it doesn't follow or the server has
        none."""
        if not self.following() or not self.server:
            return String()
        var mine = self.host_image if self.host_image else self.own
        var word: String
        if self.server == mine:
            word = "current"
        elif not self.host_image:
            word = "needs-upgrade"
        elif self.server == self.failed:
            word = "failed"
        else:
            word = "draining"
        return String(word, " ", self.server)

    def observe(mut self, got: Value, running: Int) raises:
        """Takes the claim answer's `worker_image` and `upgrade`, saying
        what changes."""
        if not self.following():
            return
        var server = String()
        if String("worker_image") in got and got["worker_image"].is_string():
            server = got["worker_image"].string_value()
            if image_problem(server):
                server = String()
        var asked = String("upgrade") in got
        if server != self.server:
            self.server = server
            if server:
                self._said_new(running)
        if asked:
            self._asked()

    def _said_new(self, running: Int):
        if self.host_image:
            if self.server == self.host_image:
                return
            if self.server == self.failed:
                print(
                    "morca worker: the server's worker image is",
                    self.server,
                    "- the host couldn't move to it before; it stays on",
                    self.host_image,
                    flush=True,
                )
                return
            print(
                "morca worker: the server's worker image is",
                self.server,
                "and this host runs",
                self.host_image,
                "- draining to move to it: it finishes its",
                running,
                "runs, claims no more, then its container is replaced",
                flush=True,
            )
            return
        if self.server != self.own:
            print(
                "morca worker: the server's worker image is",
                self.server,
                "and this worker runs",
                self.own if self.own else String("its own binary"),
                "as a",
                self.service,
                "service, which can't change its binary itself: it keeps",
                "working; install the server's version by hand",
                flush=True,
            )

    def _asked(mut self):
        if not self.host_image:
            print(
                "morca worker: asked to upgrade (morca host upgrade), but it",
                " runs as a ",
                self.service,
                " service: install the server's version by hand",
                sep="",
                flush=True,
            )
            return
        if not self.server:
            print(
                "morca worker: asked to upgrade, but the server says no",
                "worker image",
                flush=True,
            )
            return
        if self.server == self.host_image:
            print(
                "morca worker: asked to upgrade, and it runs the server's",
                "image already:",
                self.server,
                flush=True,
            )
            return
        if self.failed:
            print(
                "morca worker: asked to upgrade (morca host upgrade): trying",
                self.server,
                "again",
                flush=True,
            )
            self._forget()
        print(
            "morca worker: draining to move to",
            self.server,
            "- it finishes its runs, claims no more, then its container is",
            "replaced",
            flush=True,
        )

    def leave(self) raises:
        """Writes the image to be started on, for the script, once
        drained."""
        with open(self._path(WANT_FILE), "w") as f:
            f.write(self.server, "\n")
        print(
            "morca worker: drained: exiting",
            UPGRADE_EXIT,
            "for its container to be started on",
            self.server,
            flush=True,
        )


def _sh(s: String) -> String:
    return String("'", s, "'")


def container_script(
    pool: String,
    unit: String,
    record: String,
    stage: String,
    head: List[String],
    tail: List[String],
    record_head: String,
    record_tail: String,
) -> String:
    """The script that runs a pool's worker container and replaces it on
    the server's image (above). `head` is `docker run`'s words up to the
    image, `tail` the worker's after it; `record_head` and `record_tail`
    are `host-<pool>.json` around its image. Every word has passed
    `host_join.word_problem`, so none has a quote."""
    var run = String()
    for w in head:
        run.write(_sh(w), " ")
    run.write('"$image"')
    for w in tail:
        run.write(" ", _sh(w))
    run.write(" '--host-image' \"$image\"")
    return String(
        "#!/bin/sh\n",
        "# morca host join: pool ",
        pool,
        "'s worker in a container (morca._internal.host_follow), run by\n",
        "# its ",
        unit,
        " service. It runs the image host-",
        pool,
        ".json names; when the\n",
        "# worker exits ",
        UPGRADE_EXIT,
        " (it drained to move to the server's worker image),",
        " it pulls\n",
        "# that image and starts it, or, when that fails, starts the old one",
        " again.\n",
        "set -u\n",
        "RECORD=",
        _sh(record),
        "\n",
        "STAGE=",
        _sh(stage),
        "\n",
        "NAME=",
        _sh(unit),
        "\n",
        'WANT="$STAGE/',
        WANT_FILE,
        '"\n',
        'FAILED="$STAGE/',
        FAILED_FILE,
        '"\n',
        'say() { echo "morca host: $*"; }\n',
        "valid() { case $1 in ''|*[!A-Za-z0-9._/:@-]*) return 1 ;; esac; }\n",
        (
            'image_of() { sed -n \'s/.*"image": "\\([^"]*\\)".*/\\1/p\''
            ' "$RECORD"; }\n'
        ),
        "record() {\n",
        "    (umask 077 && printf '%s%s%s\\n' ",
        _sh(record_head),
        ' "$1" ',
        _sh(record_tail),
        ' > "$RECORD.new") && mv "$RECORD.new" "$RECORD"\n',
        "}\n",
        "# failed IMAGE WHY BACK: it couldn't move to IMAGE, and runs BACK.\n",
        "failed() {\n",
        '    printf \'%s\\n%s\\n\' "$1" "$2" > "$FAILED"\n',
        '    say "$2: starting $3 again"\n',
        "}\n",
        'mkdir -p "$STAGE"\n',
        "prev=\n",
        "while :; do\n",
        "    image=$(image_of)\n",
        '    valid "$image" || { say "no image in $RECORD"; exit 1; }\n',
        '    docker rm -f "$NAME" > /dev/null 2>&1 || true\n',
        "    began=$(date +%s)\n",
        "    ",
        run,
        "\n",
        "    code=$?\n",
        '    if [ "$code" = 3 ]; then\n',
        "        say \"the worker's token was refused (morca host remove):",
        ' stopping"\n',
        "        exit 3\n",
        "    fi\n",
        '    if [ "$code" = ',
        UPGRADE_EXIT,
        " ]; then\n",
        '        want=$(head -n 1 "$WANT" 2> /dev/null || true)\n',
        '        if ! valid "$want" || [ "$want" = "$image" ]; then\n',
        '            say "the worker exited ',
        UPGRADE_EXIT,
        ' but asked for no new image"\n',
        '            rm -f "$WANT"\n',
        "            continue\n",
        "        fi\n",
        "        say \"pulling $want, the server's worker image, to replace",
        ' $image"\n',
        '        if out=$(docker pull "$want" 2>&1); then\n',
        '            if record "$want"; then\n',
        '                rm -f "$FAILED"\n',
        "                prev=$image\n",
        '                say "starting $want"\n',
        "            else\n",
        '                failed "$want" "can\'t write $RECORD" "$image"\n',
        '                rm -f "$WANT"\n',
        "            fi\n",
        "        else\n",
        "            why=$(printf '%s\\n' \"$out\" | tail -n 1)\n",
        '            failed "$want" "can\'t pull $want ($why)" "$image"\n',
        '            rm -f "$WANT"\n',
        "        fi\n",
        "        continue\n",
        "    fi\n",
        '    if [ -n "$prev" ] && [ $(($(date +%s) - began)) -lt ',
        START_GRACE,
        " ]; then\n",
        '        failed "$image" "$image exited $code within ',
        START_GRACE,
        ' s of starting" "$prev"\n',
        '        record "$prev" || exit 1\n',
        '        rm -f "$WANT"\n',
        "        prev=\n",
        "        continue\n",
        "    fi\n",
        "    prev=\n",
        '    say "the worker exited $code: starting it again in 5 s"\n',
        "    sleep 5\n",
        "done\n",
    )
