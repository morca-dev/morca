"""How a machine the pool autoscaler made becomes a worker (#267): its
startup script, and the UI's answer to its `/api/worker/boot`.

The script (`boot_script`, the machine's cloud-init user data) holds one
secret, the machine's own worker token, which morca revokes when it removes
the machine. With it the machine asks the UI for the rest, over TLS:
`boot_answer` gives the worker image (`MORCA_WORKER_IMAGE`, the server's
own, as the autoscaler recorded it when it made the machine), the login to pull it (`morca._internal.registry`), and the variables a worker
needs to reach the bucket (`MORCA_WAREHOUSE`, `MORCA_LOGS`, the `AWS_*`
ones), as the UI's own environment has them. It answers only a token the
autoscaler made for a machine that's live, so a token someone made with
`morca worker-token create` gets nothing from it.

The machine then installs Docker if it hasn't it, logs in, and runs the
image as `morca worker --pool <pool> --name <machine>`, with run cgroups
(`docs/hetzner.md`, "A cgroup per run"). With `MORCA_POOL_WORKER_COMMAND`
set on the scheduler, the script runs that command as the worker instead
(tests, without Docker).

A machine joined by hand (`morca host join`, `morca._internal.host_join`)
asks `/api/worker/join` instead, with any live token of its pool:
`join_answer` gives the pool's volumes and `max_runs`, and the worker image
the server runs (`MORCA_WORKER_IMAGE`), which a container is started on
unless `--image` says otherwise. It holds no secret: the bucket's
variables stay on the machine, in an env file of its own.
"""

from std.os import getenv

import morca._internal.db.pools as pools_db

from morca._internal.json import quote
from morca._internal.pool_config import pool_settings, pool_volumes
from morca._internal.registry import ImageRef, Registry
from morca._internal.state import State

comptime BOOT_PATH = "/api/worker/boot"
comptime JOIN_PATH = "/api/worker/join"
comptime CREATED_BY = "pool:"
"""`orca.workers.created_by` of a token the autoscaler made: `pool:<pool>`."""
comptime WORKER_IMAGE = "MORCA_WORKER_IMAGE"
comptime _BUCKET_VARS = [
    "MORCA_WAREHOUSE",
    "MORCA_LOGS",
    "MORCA_PUBLIC_WAREHOUSE",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_REGION",
    "AWS_DEFAULT_REGION",
    "AWS_ENDPOINT_URL_S3",
]


def _plain(s: String) -> Bool:
    """Whether `s` can sit in single quotes in sh, and on one line."""
    for b in s.as_bytes():
        if b == UInt8(ord("'")) or b < 0x20 or b == 0x7F:
            return False
    return True


def boot_script(
    remote: String,
    pool: String,
    name: String,
    token: String,
    command: String = "",
    gpus: Bool = False,
) raises -> String:
    """The startup script of machine `name` of `pool`: ask `remote` (the
    UI) for what it needs with `token`, then run the worker, in Docker or
    as `command` when given. A machine of the pool's `gpu_machines`
    (`gpus`) gives the container its GPUs (`--gpus all`, which needs
    NVIDIA's container toolkit on the machine's image), so the worker
    counts them."""
    for s in [remote, pool, name, token, command]:
        if not _plain(s):
            raise Error(
                "morca: can't put a quote or control character in a boot script"
            )
    var out = String(
        "#!/bin/sh\n",
        "# A morca pool machine (morca.pool_boot): pool ",
        pool,
        ", machine ",
        name,
        ".\n",
        "set -eu\n",
        "TOKEN='",
        token,
        "'\nREMOTE='",
        remote,
        "'\nPOOL='",
        pool,
        "'\nNAME='",
        name,
        "'\n",
        'DIR="${MORCA_BOOT_DIR:-/etc/orca}"\n',
        'mkdir -p "$DIR"\n',
        "umask 077\n",
        "# The rest, over TLS with its own token: never in this script.\n",
        'until curl -fsS -X POST -H "Authorization: Bearer $TOKEN"',
        ' -H \'Content-Type: application/json\' -d "{\\"pool\\": \\"$POOL\\"}"',
        ' "$REMOTE',
        BOOT_PATH,
        '" -o "$DIR/boot.json"; do sleep 5; done\n',
        "python3 - \"$DIR\" <<'PY'\n",
        "import json, os, sys\n",
        "d = sys.argv[1]\n",
        'b = json.load(open(os.path.join(d, "boot.json")))\n',
        'open(os.path.join(d, "worker.env"), "w").write(b["env_file"])\n',
        'open(os.path.join(d, "image"), "w").write(b["image"])\n',
        'r = b.get("registry") or {}\n',
        (
            'open(os.path.join(d, "registry"),'
            ' "w").write("\\n".join([r.get("host", ""), r.get("user", ""),'
            ' r.get("token", "")]) + "\\n")\n'
        ),
        "PY\n",
        'rm -f "$DIR/boot.json"\n',
        'echo "MORCA_WORKER_TOKEN=$TOKEN" >> "$DIR/worker.env"\n',
        # The address the pool's machines reach this one at, for a run that
        # spreads over them (#268): its private one, from Hetzner's or EC2's
        # metadata, waited for while the private network attaches.
        'ADV="${MORCA_BOOT_ADVERTISE:-}"\n',
        "MD=http://169.254.169.254\n",
        'if [ -z "$ADV" ] && curl -fsS -m 2 "$MD/hetzner/v1/metadata/hostname"',
        " > /dev/null 2>&1; then\n",
        # Hetzner: the private network can attach a little after boot.
        "    i=0\n",
        '    while [ -z "$ADV" ] && [ "$i" -lt 24 ]; do\n',
        (
            "        ADV=$(curl -fsS -m 3"
            ' "$MD/hetzner/v1/metadata/private-networks"'
        ),
        " 2> /dev/null | sed -n 's/^- ip: *//p' | head -1)\n",
        '        [ -n "$ADV" ] || { i=$((i + 1)); sleep 5; }\n',
        "    done\n",
        'elif [ -z "$ADV" ]; then\n',
        # EC2 (IMDSv2); anywhere else none, and runs aren't spread there.
        "    T=$(curl -fsS -m 2 -X PUT -H",
        " 'X-aws-ec2-metadata-token-ttl-seconds: 60' \"$MD/latest/api/token\"",
        ' 2> /dev/null) && ADV=$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token:',
        ' $T" "$MD/latest/meta-data/local-ipv4" 2> /dev/null) || ADV=\n',
        "fi\n",
        (
            '[ -z "$ADV" ] || echo "MORCA_WORKER_ADVERTISE=$ADV" >>'
            ' "$DIR/worker.env"\n'
        ),
    )
    if command:
        out.write(
            'rm -f "$DIR/registry"\n',
            'set -a; . "$DIR/worker.env"; set +a\n',
            "exec ",
            command,
            ' worker --pool "$POOL" --remote "$REMOTE" --name "$NAME"',
            " --max-runs 64 --poll-seconds 0.3",
            ' --dir "$DIR/stage"\n',
        )
        return out^
    out.write(
        "if ! command -v docker > /dev/null 2>&1; then\n",
        "    apt-get update -q\n",
        "    DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker.io\n",
        "fi\n",
        "systemctl enable --now docker 2> /dev/null || true\n",
        '{ read -r host; read -r user; read -r pass; } < "$DIR/registry"\n',
        'rm -f "$DIR/registry"\n',
        'if [ -n "$user" ]; then\n',
        (
            '    printf %s "$pass" | docker login "$host" -u "$user"'
            " --password-stdin\n"
        ),
        "fi\n",
        "mkdir -p /var/lib/orca/stage\n",
        "docker rm -f orca-worker > /dev/null 2>&1 || true\n",
        "docker run -d --name orca-worker --restart always --network host",
        " --gpus all" if gpus else "",
        ' --env-file "$DIR/worker.env"',
        " --cap-add SYS_ADMIN --security-opt apparmor=unconfined",
        " --cgroupns private -v /var/lib/orca/stage:/var/lib/orca/stage",
        ' --entrypoint sh "$(cat "$DIR/image")" -c',
        ' "mount -o remount,rw /sys/fs/cgroup && exec setpriv --bounding-set',
        " -sys_admin --inh-caps -sys_admin morca worker --pool $POOL --remote",
        ' $REMOTE --name $NAME --max-runs 64 --dir /var/lib/orca/stage"\n',
    )
    return out^


def _env_line(name: String, value: String) -> String:
    if not value or not _plain(value):
        return ""
    return String(name, "=", value, "\n")


def boot_answer(mut db: State, worker: Int) raises -> String:
    """The UI's answer to a machine's `/api/worker/boot`, for worker token
    `worker`: what its script needs, as JSON. Raises (the UI answers 403)
    for a token the autoscaler didn't make, or whose machine isn't live."""
    var machine = pools_db.booting_machine(db.conn, worker)
    if not machine:
        raise Error(
            "morca: this token isn't one the pool autoscaler made for a live",
            " machine",
        )
    # The image the autoscaler made it for (#356), which it compares with
    # its own to replace the machine after a deploy; the UI's for a machine
    # made before morca recorded it.
    var image = machine.value()
    if not image:
        image = getenv(WORKER_IMAGE)
    if not image:
        raise Error("morca: the UI has no ", WORKER_IMAGE, " to give")
    var env = String()
    for v in materialize[_BUCKET_VARS]():
        env.write(_env_line(v, getenv(v)))
    var reg = Registry.from_env()
    var login = reg.credentials()
    var host = ImageRef.parse(image).host
    return String(
        '{"image": ',
        quote(image),
        ', "env_file": ',
        quote(env),
        ', "registry": {"host": ',
        quote(host),
        ', "user": ',
        quote(login[0]),
        ', "token": ',
        quote(login[1]),
        "}}",
    )


def join_answer(mut db: State, pool: String) raises -> String:
    """The UI's answer to `/api/worker/join` for a token of `pool`: what
    `morca host join` sets its service up with, as JSON. No secret."""
    var vols = String("[")
    var vs = pool_volumes(db, pool)
    for i in range(len(vs)):
        vols.write(", " if i else "", quote(vs[i]))
    vols.write("]")
    return String(
        '{"pool": ',
        quote(pool),
        ', "image": ',
        quote(getenv(WORKER_IMAGE)),
        ', "volumes": ',
        vols,
        ', "max_runs": ',
        pool_settings(db, pool).max_runs,
        "}",
    )
