"""`morca aws replace-control`: a blue/green replacement of the stack's
control instance by a new one booted from the current template, with the
old one's database (DESIGN.md, "Replacing the control instance").

    morca aws replace-control [--stack S] [--plan] [--wait] [--keep-old 24h]
                             [--smoke PIPELINE=KEY] [--env KEY=VALUE ...]
    morca aws replace-control --resume      # after a failure, or to retire
    morca aws replace-control --rollback    # back to the old instance

The control instance is in one of two slots, blue and green
(deploy/aws/morca.yaml); the Elastic IP is on the active one. The steps,
each logged to `build/morca-aws/replace-<stack>.log` and recorded in
`build/morca-aws/replace-<stack>.state` once done, so `--resume` goes on
from the first one that isn't:

1. **quiet**: every pipeline paused and no run running, else it refuses,
   printing which; `--wait` waits for the runs (it pauses nothing).
2. **freeze**: the old instance's scheduler and UI stop (and won't restart
   with it), so nothing writes to its database; the UI is down from here.
3. **backup**: `pg_dump -Fc` of morca's schema to
   `s3://<bucket>/backups/<stack>/<UTC time>.dump`, verified by restoring it
   into a scratch database and comparing pipelines, runs, the last run and
   the schema version; beside it the image tag, Caddy's data (its
   certificates), the apps (`orca-app`), the non-secret settings
   (`/etc/orca.env` without URLs with passwords) and a manifest. Then
   `backups/<stack>/restore-<new slot>` points at it.
4. **launch**: `cloudformation deploy` turning the other slot on, its AMI
   the latest of the stack's `Ami`, the old slot's pinned to its own, and
   `--env` as `ControlEnv` if given.
5. **boot**: waits for the new instance's boot script, which restores the
   backup before it starts the scheduler and the UI.
6. **check**: on the new instance, over SSM: restored from this backup, the
   same pipelines, runs and last run, a schema version no older, every
   pipeline still paused, the containers running, the UI and each app
   answering, `/system` samples in the last 10 minutes, `morca status`, and
   the old instance's settings all there. `--smoke P=KEY` also unpauses P,
   starts a run of KEY, waits for it to succeed and pauses P again.
7. **switch**: `cloudformation deploy` with `ActiveControl` the new slot,
   which moves the Elastic IP; it checks the address is on the new
   instance, stops the old one and fetches the UI from outside.
8. **retire**: once `--keep-old` (24h; 0 at once) has passed, `--resume`
   turns the old slot off, which terminates its instance.

`--rollback` before the switch turns the new slot off and starts the old
scheduler and UI again. After it, it does the replacement backwards: the
new instance quiet and frozen, a backup of its database restored on the old
one (started again), the Elastic IP moved back, and the new slot off.
`--plan` prints the steps for this stack without doing any. The pipelines
stay paused throughout: unpause them once it's done.
"""

from std.os import getenv
from std.os.path import exists
from std.time import sleep

from morca._internal.aws import (
    _DIR,
    _Opts,
    _out,
    _outputs,
    _q,
    _system,
    control_env,
    deploy,
    image_of,
    slot_pins,
    ssm_run,
)
from morca.civil import Civil, now

comptime _CORE = "postgres|scheduler|ui|caddy|sampler"
"""The control instance's own containers; any other is an app."""
comptime _SAFE_ENV = (
    "grep -vE '^(MORCA_DATABASE_URL|MORCA_EC2_DATABASE_URL|MORCA_EC2_AMI)='"
    " /etc/orca.env | grep -viE 'PASSWORD|SECRET|TOKEN' | sort"
)
"""The settings a manifest keeps: none with a password, nor the AMI and
addresses that are the instance's own."""
comptime _SITES = (
    "sed -n 's/^\\([^{ #][^{]*\\){.*/\\1/p' /var/lib/orca/Caddyfile | tr ', '"
    " '\\n\\n' | grep . | sort -u"
)
"""The hostnames Caddy serves, a line each."""
comptime _COUNTS = (
    "SELECT (SELECT count(*) FROM orca.pipelines) || ' ' || (SELECT count(*)"
    " FROM orca.runs) || ' ' || (SELECT coalesce(max(id), 0) FROM orca.runs)"
    " || ' ' || (SELECT max(version) FROM orca.schema_version)"
)
"""Pipelines, runs, the last run's id and the schema version, which a
restored database has to match (the version may be newer)."""


def _steps() -> List[String]:
    return [
        "quiet",
        "freeze",
        "backup",
        "launch",
        "boot",
        "check",
        "switch",
        "retire",
    ]


def _cap(slot: String) -> String:
    return String("Green") if slot == "green" else String("Blue")


def _other(slot: String) -> String:
    return String("blue") if slot == "green" else String("green")


def _seconds(text: String) raises -> Int:
    """`24h`, `30m`, `2d`, `90s` or `0`, in seconds."""
    if text == "0":
        return 0
    var units = String(text[byte = text.byte_length() - 1 :])
    var n: Int
    try:
        n = Int(text[byte = : text.byte_length() - 1])
    except:
        raise Error("morca aws: --keep-old is like 24h, 30m or 2d: ", text)
    if units == "s":
        return n
    if units == "m":
        return n * 60
    if units == "h":
        return n * 3600
    if units == "d":
        return n * 86400
    raise Error("morca aws: --keep-old is like 24h, 30m or 2d: ", text)


def _keep(o: _Opts) -> String:
    """`--keep-old`, by default 24h."""
    return o.keep_old if o.keep_old else String("24h")


def _stamp(t: Int64) -> String:
    """`YYYYMMDDTHHMMSSZ`, for a backup's name."""
    var s = String(Civil.of(t))
    return String(s.replace("-", "").replace(":", ""), "Z")


def _when(t: Int64) -> String:
    return String(Civil.of(t), "Z")


def _poll() -> Float64:
    """Seconds between checks (`MORCA_REPLACE_POLL`, 30; the tests' 0)."""
    var v = getenv("MORCA_REPLACE_POLL")
    if v:
        try:
            return Float64(Int(v))
        except:
            pass
    return 30.0


struct _State(Movable):
    """The replacement's progress, `key=value` lines in a file."""

    var path: String
    var log: String
    var keys: List[String]
    var values: List[String]

    def __init__(out self, stack: String) raises:
        self.path = String(_DIR, "/replace-", stack, ".state")
        self.log = String(_DIR, "/replace-", stack, ".log")
        self.keys = List[String]()
        self.values = List[String]()
        if exists(self.path):
            var text: String
            with open(self.path, "r") as f:
                text = f.read()
            for line in text.split("\n"):
                var eq = line.find("=").or_else(-1)
                if eq > 0:
                    self.keys.append(String(line[byte=:eq]))
                    self.values.append(String(line[byte = eq + 1 :]))

    def started(self) -> Bool:
        return len(self.keys) > 0

    def get(self, key: String) -> String:
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return self.values[i]
        return ""

    def set(mut self, key: String, value: String) raises:
        var found = False
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                self.values[i] = value
                found = True
        if not found:
            self.keys.append(key)
            self.values.append(value)
        _ = _system(String("mkdir -p ", _q(_DIR)))
        with open(self.path, "w") as f:
            for i in range(len(self.keys)):
                f.write(self.keys[i], "=", self.values[i], "\n")

    def done(self, step: String) -> Bool:
        return self.get(String("done.", step)) != ""

    def mark(mut self, step: String) raises:
        self.set(String("done.", step), _when(now()))
        self.note(String(step, ": done"))

    def note(self, msg: String) raises:
        """Prints `msg` and logs it, with the time."""
        var line = String(_when(now()), " ", msg)
        print("replace-control:", msg)
        _ = _system(String("mkdir -p ", _q(_DIR)))
        with open(self.log, "a") as f:
            f.write(line, "\n")

    def end(mut self, how: String) raises:
        """Keeps the state file as `<state>.<how>-<time>`."""
        self.note(String("the replacement is ", how))
        _ = _system(
            String(
                "mv ",
                _q(self.path),
                " ",
                _q(String(self.path, ".", how, "-", _stamp(now()))),
            )
        )
        self.keys = List[String]()
        self.values = List[String]()


def _on(
    o: _Opts, st: _State, instance: String, step: String, body: List[String]
) raises -> Tuple[Int, String]:
    """Runs `body` on `instance` over SSM, as step `step`."""
    st.note(String(step, ": on ", instance))
    var lines: List[String] = [
        String("# morca-replace ", step),
        String("export AWS_DEFAULT_REGION=", _q(_region(o))),
        'q() { docker exec postgres psql -U orca -d orca -Atc "$1"; }',
    ]
    for l in body:
        lines.append(l)
    return ssm_run(o, instance, lines)


def _region(o: _Opts) raises -> String:
    if o.region:
        return o.region
    return _out("aws configure get region")


def _quiet() -> List[String]:
    return [
        (
            "up=$(q \"SELECT coalesce(string_agg(name, ' ' ORDER BY name), '')"
            ' FROM orca.pipelines WHERE NOT paused")'
        ),
        (
            "live=$(q \"SELECT coalesce(string_agg(pipeline || ' run ' || id,"
            " ', ' ORDER BY id), '') FROM orca.runs WHERE status ="
            " 'running'\")"
        ),
        '[ -z "$up" ] || echo "not paused: $up"',
        '[ -z "$live" ] || echo "running: $live"',
        '[ -z "$up$live" ] || exit 1',
        "echo quiet",
    ]


def _freeze() -> List[String]:
    return [
        "docker update --restart=no scheduler ui",
        "docker stop scheduler ui",
        "live=$(q \"SELECT count(*) FROM orca.runs WHERE status = 'running'\")",
        (
            '[ "$live" = 0 ] || { echo "a run started: $live running";'
            " docker update --restart=always scheduler ui; docker start"
            " scheduler ui; exit 1; }"
        ),
        "echo 'the scheduler and the UI are stopped'",
    ]


def _unfreeze() -> List[String]:
    return [
        "docker update --restart=always scheduler ui",
        "docker start scheduler ui",
        "echo 'the scheduler and the UI are running'",
    ]


def _backup(
    prefix: String, pointer: String, console_host: String
) -> List[String]:
    """Backs up the control instance to `prefix`.*, and points `pointer` at
    it if it isn't empty."""
    var p = _q(prefix)
    var out: List[String] = [
        "set -eu",
        "b=/var/lib/orca/backup",
        "rm -rf $b && mkdir -p $b",
        "docker exec postgres pg_dump -U orca -d orca -n orca -Fc > $b/b.dump",
        # Verified before anything depends on it: restored into a scratch
        # database, which has to match.
        "docker exec postgres dropdb -U orca --if-exists morca_verify",
        "docker exec postgres createdb -U orca morca_verify",
        (
            "docker exec -i postgres pg_restore -U orca -d morca_verify"
            " --no-owner --exit-on-error < $b/b.dump"
        ),
        String(
            'counts() { docker exec postgres psql -U orca -d "$1" -Atc ',
            _q(_COUNTS),
            "; }",
        ),
        "have=$(counts morca)",
        "got=$(counts morca_verify)",
        "docker exec postgres dropdb -U orca morca_verify",
        (
            '[ "$have" = "$got" ] || { echo "the dump restores as $got, not'
            ' $have"; exit 1; }'
        ),
        'echo "verified: pipelines, runs, last run, schema: $have"',
        "cp /var/lib/orca/tag $b/b.tag",
        "tar -czf $b/b.caddy.tgz -C /var/lib/orca/caddy .",
        "[ ! -f /var/lib/orca/apps ] || cp /var/lib/orca/apps $b/b.apps",
        "touch $b/b.apps",
    ]
    if console_host:
        # A console started before orca-app recorded its apps.
        out.append(
            String(
                "grep -q '^console ' $b/b.apps || ! docker ps --format",
                " '{{.Names}}' | grep -qx console || echo 'console ",
                console_host,
                " 8080' >> $b/b.apps",
            )
        )
    out.append(
        String(
            "for c in $(docker ps --format '{{.Names}}' | grep -vxE '",
            _CORE,
            '\'); do grep -q "^$c " $b/b.apps || echo "not carried over: the',
            ' container $c (run morca aws app $c --host H after)"; done',
        )
    )
    out.append(String(_SAFE_ENV, " > $b/b.env"))
    out.append(String(_SITES, " > $b/b.sites"))
    out.append(
        String(
            '{ echo "counts $have"; echo "tag $(cat $b/b.tag)"; echo',
            ' "instance $(cat /var/lib/cloud/data/instance-id 2> /dev/null)";',
            ' echo "apps:"; cat $b/b.apps; echo "pipelines:"; q "SELECT name',
            " || CASE WHEN paused THEN ' (paused)' ELSE '' END FROM",
            ' orca.pipelines ORDER BY name"; echo "containers:"; docker ps',
            " --format '{{.Names}} {{.Image}}'; } > $b/b.manifest",
        )
    )
    out.append(
        String(
            "for e in dump tag caddy.tgz apps env sites manifest; do aws s3 cp",
            " --only-show-errors $b/b.$e ",
            p,
            ".$e; done",
        )
    )
    if pointer:
        out.append(
            String(
                "echo ", p, " | aws s3 cp --only-show-errors - ", _q(pointer)
            )
        )
    out.append("cat $b/b.manifest")
    out.append("rm -rf $b")
    out.append(String("echo backed up to ", p))
    return out^


def _check(prefix: String, smoke: String) -> List[String]:
    var p = _q(prefix)
    var out: List[String] = [
        "set -u",
        "fail=0",
        'bad() { echo "FAIL: $*"; fail=1; }',
        (
            "answers() { for _ in $(seq 60); do docker exec caddy wget -qO"
            ' /dev/null "$1" && return 0; sleep 2; done; return 1; }'
        ),
        String(
            '[ "$(cat /var/lib/orca/restored 2> /dev/null)" = ',
            p,
            ' ] || bad "the database is not the one restored from ',
            prefix,
            '"',
        ),
        String(
            "aws s3 cp --only-show-errors ",
            p,
            ".manifest /var/lib/orca/replaced.manifest",
        ),
        String(
            "aws s3 cp --only-show-errors ",
            p,
            ".env /var/lib/orca/replaced.env",
        ),
        String(
            "aws s3 cp --only-show-errors ",
            p,
            ".sites /var/lib/orca/replaced.sites",
        ),
        "set -- $(sed -n 's/^counts //p' /var/lib/orca/replaced.manifest)",
        'want="$1 $2 $3"',
        "want_schema=$4",
        String("set -- $(q ", _q(_COUNTS), ")"),
        (
            '[ "$1 $2 $3" = "$want" ] || bad "pipelines, runs, last run: $1'
            ' $2 $3, not $want"'
        ),
        (
            '[ "$4" -ge "$want_schema" ] || bad "schema version $4, older than'
            ' $want_schema"'
        ),
        'echo "pipelines, runs, last run: $1 $2 $3; schema version $4"',
        (
            "up=$(q \"SELECT coalesce(string_agg(name, ' '), '') FROM"
            ' orca.pipelines WHERE NOT paused")'
        ),
        '[ -z "$up" ] || bad "not paused: $up"',
        String(
            "for c in $(echo '",
            _CORE,
            (
                "' | tr '|' ' '); do docker ps --format '{{.Names}}' | grep -qx"
                ' $c || bad "$c is not running"; done'
            ),
        ),
        "answers http://ui:8270/ || bad 'the UI does not answer'",
        (
            "answers http://ui:8270/api/system || bad '/api/system does not"
            " answer'"
        ),
        (
            "[ ! -f /var/lib/orca/apps ] || while read -r name host port; do"
            ' answers "http://$name:$port/" || bad "the app $name does not'
            ' answer"; grep -q "^$host {" /var/lib/orca/Caddyfile || bad'
            ' "Caddy has no site $host"; done < /var/lib/orca/apps'
        ),
        (
            'samples() { q "SELECT count(*) FROM orca.system_minutes WHERE'
            " minute > now() - interval '10 minutes'\"; }"
        ),
        (
            'for _ in $(seq 30); do [ "$(samples)" -gt 0 ] && break; sleep 10;'
            " done"
        ),
        (
            '[ "$(samples)" -gt 0 ] || bad "/system has no samples from the'
            ' last 10 minutes"'
        ),
        (
            "docker exec scheduler morca status > /dev/null || bad 'morca"
            " status fails'"
        ),
        String(_SAFE_ENV, " > /var/lib/orca/new.env"),
        "missing=$(comm -23 /var/lib/orca/replaced.env /var/lib/orca/new.env)",
        (
            '[ -z "$missing" ] || { bad "settings the old instance had that'
            " this one hasn't (give them with --env, or morca aws up --env):\";"
            ' echo "$missing"; }'
        ),
        String(_SITES, " > /var/lib/orca/new.sites"),
        (
            "missing=$(comm -23 /var/lib/orca/replaced.sites"
            " /var/lib/orca/new.sites)"
        ),
        (
            '[ -z "$missing" ] || bad "hostnames the old instance served that'
            " this one doesn't (--hostname, --console-hostname):\" $missing"
        ),
    ]
    if smoke:
        var eq = smoke.find("=").or_else(-1)
        var pipeline = String(smoke[byte=:eq])
        var key = String(smoke[byte = eq + 1 :])
        var last = String(
            "q \"SELECT coalesce(max(id), 0) FROM orca.runs WHERE pipeline = '",
            pipeline,
            "'\"",
        )
        out.append(String("before=$(", last, ")"))
        out.append(String("docker exec scheduler morca unpause ", _q(pipeline)))
        out.append(
            String(
                "docker exec scheduler morca start ",
                _q(pipeline),
                " ",
                _q(key),
            )
        )
        out.append(
            String(
                "status=none; for _ in $(seq 360); do run=$(",
                last,
                '); [ "$run" -gt "$before" ] && status=$(q "SELECT status FROM',
                ' orca.runs WHERE id = $run"); case $status in queued|running)',
                " sleep 10;; none) sleep 10;; *) break;; esac; done",
            )
        )
        out.append(String("docker exec scheduler morca pause ", _q(pipeline)))
        out.append(
            String(
                '[ "$status" = succeeded ] || bad "the smoke run of ',
                pipeline,
                ' is $status"',
            )
        )
        out.append(String('echo "smoke run of ', pipeline, ': $status"'))
    out.append("[ $fail = 0 ] && echo healthy")
    out.append("exit $fail")
    return out^


def _restore_here(prefix: String) -> List[String]:
    """Replaces the database here with the backup at `prefix` and starts
    the scheduler and the UI at its image tag (a rollback's last part)."""
    var p = _q(prefix)
    return [
        "set -eu",
        "docker update --restart=no scheduler ui",
        "docker stop scheduler ui || true",
        String(
            "aws s3 cp --only-show-errors ",
            p,
            ".dump /var/lib/orca/restore.dump",
        ),
        (
            "docker exec postgres dropdb -U orca --maintenance-db=postgres"
            " --force morca"
        ),
        "docker exec postgres createdb -U orca --maintenance-db=postgres morca",
        (
            "docker exec -i postgres pg_restore -U orca -d orca --no-owner"
            " --exit-on-error < /var/lib/orca/restore.dump"
        ),
        "rm -f /var/lib/orca/restore.dump",
        String("aws s3 cp --only-show-errors ", p, ".tag /var/lib/orca/tag"),
        String("echo ", p, " > /var/lib/orca/restored"),
        "orca-refresh",
        String("echo restored ", p),
    ]


def _instance_of(outs: Dict[String, String], slot: String) -> String:
    var id = outs.get(String(_cap(slot), "Instance"), "")
    if not id and slot == "blue" and "ActiveControl" not in outs:
        id = outs.get("ControlInstance", "")
    return id^


def _deploy(
    o: _Opts, st: _State, step: String, var params: List[String]
) raises:
    for p in slot_pins(o, _outputs(o)):
        var key = String(p[byte = : p.find("=").or_else(-1) + 1])
        var given = False
        for q in params:
            if q.startswith(key):
                given = True
        if not given:
            params.append(p)
    var shown = String()
    for p in params:
        shown.write(" ", p)
    st.note(String(step, ": cloudformation deploy", shown))
    deploy(o, params, True)


def _s3_rm(o: _Opts, uri: String) raises:
    _ = _system(o.aws(String("s3 rm --only-show-errors ", _q(uri))))


def _plan(o: _Opts, st: _State) raises -> Int:
    var outs = _outputs(o)
    var old = st.get("old")
    if not old:
        old = outs.get("ActiveControl", "blue")
    var new = _other(old)
    var old_id = st.get("old_instance")
    if not old_id:
        old_id = _instance_of(outs, old)
    var bucket = outs.get("Bucket", "<bucket>")
    var prefix = st.get("prefix")
    if not prefix:
        prefix = String("s3://", bucket, "/backups/", o.stack, "/<UTC time>")
    var new_id = st.get("new_instance")
    if not new_id:
        new_id = String("the new instance")
    print(
        "morca aws replace-control --stack ",
        o.stack,
        ": replace ",
        old_id,
        " (slot ",
        old,
        ") with a new instance in slot ",
        new,
        sep="",
    )
    if st.started():
        print("in progress since", st.get("started"), "; done:", end="")
        for s in _steps():
            if st.done(s):
                print("", s, end="")
        print()
    var env = String()
    if len(o.env) > 0:
        env = String(" ", control_env(o))
    if o.hostname:
        env.write(" Hostname=", o.hostname)
    if o.console_hostname:
        env.write(" ConsoleHostname=", o.console_hostname)
    var smoke = String()
    if o.smoke:
        smoke = String("; a smoke run, ", o.smoke)
    var lines: List[String] = [
        String(
            (
                "quiet   refuse unless every pipeline is paused and no run is"
                " running"
            ),
            String(" (--wait: wait for the runs)") if o.wait else String(),
        ),
        String(
            "freeze  stop the scheduler and the UI on ",
            old_id,
            ": the UI is down from here to the switch",
        ),
        String(
            "backup  pg_dump -Fc of morca to ",
            prefix,
            ".dump, verified by a restore into a scratch database; the tag,",
            " Caddy's data, the apps, the settings and a manifest beside it;",
            " s3://",
            bucket,
            "/backups/",
            o.stack,
            "/restore-",
            new,
            " points at it",
        ),
        String(
            "launch  cloudformation deploy ",
            _cap(new),
            "Slot=true ",
            _cap(new),
            "Ami=<the latest Ami> ",
            _cap(old),
            "Ami=<",
            old_id,
            "'s> ActiveControl=",
            old,
            env,
        ),
        String(
            "boot    wait for ",
            new_id,
            (
                " to boot; it restores the backup before the scheduler and the"
                " UI start"
            ),
        ),
        String(
            "check   on ",
            new_id,
            (
                ": the restore, pipelines, runs, schema version, all paused,"
                " the containers, the UI and apps answering, /system samples,"
                " morca status, the old settings"
            ),
            smoke,
        ),
        String(
            "switch  cloudformation deploy ActiveControl=",
            new,
            " (the Elastic IP moves), then stop ",
            old_id,
        ),
        String(
            "retire  after --keep-old ",
            _keep(o),
            " (replace-control --resume): cloudformation deploy ",
            _cap(old),
            "Slot=false, which terminates ",
            old_id,
        ),
    ]
    var names = _steps()
    for i in range(len(lines)):
        var mark = String("done ") if st.done(names[i]) else String()
        print("  ", i + 1, ". ", mark, lines[i], sep="")
    print(
        "  rollback (--rollback): before the switch, turn slot",
        new,
        "off and start",
        old_id,
        "'s scheduler and UI again; after it, back up",
        new_id,
        ", restore it on",
        old_id,
        "(started again), move the Elastic IP back and turn slot",
        new,
        "off",
    )
    return 0


def _wait_reachable(
    o: _Opts, st: _State, instance: String, step: String, probe: String
) raises -> Bool:
    """Polls `instance` over SSM until `probe` succeeds there."""
    var tries = 60
    var t = getenv("MORCA_REPLACE_TRIES")
    if t:
        tries = Int(t)
    for i in range(tries):
        try:
            var got = ssm_run(
                o, instance, [String("# morca-replace ", step), probe]
            )
            if got[0] == 0:
                return True
        except e:
            st.note(String(step, ": ", instance, " not reachable yet: ", e))
        if i + 1 < tries:
            sleep(_poll())
    return False


def _forward(o: _Opts, mut st: _State) raises -> Int:
    var poll = _poll()
    var old = st.get("old")
    var new = st.get("new")
    var old_id = st.get("old_instance")
    var bucket = st.get("bucket")
    var prefix = st.get("prefix")
    var pointer = String(
        "s3://", bucket, "/backups/", o.stack, "/restore-", new
    )

    if not st.done("quiet"):
        while True:
            var got = _on(o, st, old_id, "quiet", _quiet())
            if got[0] == 0:
                break
            if "not paused:" in got[1] or not o.wait:
                st.note(
                    "quiet: refused; pause every pipeline (morca --remote <ui>"
                    " pause <pipeline>) and let its runs finish, or --wait"
                    " for them"
                )
                return 3
            st.note("quiet: waiting for the runs")
            sleep(poll)
        st.mark("quiet")
    if not st.done("freeze"):
        if _on(o, st, old_id, "freeze", _freeze())[0] != 0:
            st.note("freeze: a run started; nothing is stopped")
            return 3
        st.mark("freeze")
    if not st.done("backup"):
        var outs = _outputs(o)
        if (
            _on(
                o,
                st,
                old_id,
                "backup",
                _backup(
                    prefix,
                    pointer,
                    o.console_hostname if o.console_hostname else outs.get(
                        "ConsoleHostname", ""
                    ),
                ),
            )[0]
            != 0
        ):
            st.note("backup: failed; --resume tries again, --rollback undoes")
            return 3
        st.mark("backup")
    if not st.done("launch"):
        var ami_path = _out(
            o.aws(
                String(
                    "cloudformation describe-stacks --stack-name ",
                    _q(o.stack),
                    " --query \"Stacks[0].Parameters[?ParameterKey=='Ami']",
                    '.ParameterValue" --output text',
                )
            )
        )
        var latest = ami_path
        if ami_path.startswith("/"):
            latest = _out(
                o.aws(
                    String(
                        "ssm get-parameter --name ",
                        _q(ami_path),
                        " --query Parameter.Value --output text",
                    )
                )
            )
        var params: List[String] = [
            String(_cap(new), "Slot=true"),
            String(_cap(old), "Slot=true"),
            String("ActiveControl=", old),
            String(_cap(new), "Ami=", latest),
            String(_cap(old), "Ami=", image_of(o, old_id)),
        ]
        if len(o.env) > 0:
            params.append(control_env(o))
        if o.hostname:
            params.append(String("Hostname=", o.hostname))
        if o.console_hostname:
            params.append(String("ConsoleHostname=", o.console_hostname))
        _deploy(o, st, "launch", params^)
        var new_id = _instance_of(_outputs(o), new)
        if not new_id:
            raise Error("morca aws: the stack has no instance in slot ", new)
        st.set("new_instance", new_id)
        st.mark("launch")
    var new_id = st.get("new_instance")
    if not st.done("boot"):
        st.note(String("boot: waiting for ", new_id))
        if not _wait_reachable(
            o, st, new_id, "boot", "cat /var/lib/orca/booted"
        ):
            st.note(
                String(
                    "boot: ",
                    new_id,
                    (
                        " hasn't finished booting (its log:"
                        " /var/log/cloud-init-output.log); --resume waits"
                        " again, --rollback undoes"
                    ),
                )
            )
            return 3
        st.mark("boot")
    if not st.done("check"):
        if _on(o, st, new_id, "check", _check(prefix, o.smoke))[0] != 0:
            st.note(
                "check: the new instance isn't healthy (above); fix and"
                " --resume, or --rollback"
            )
            return 3
        st.mark("check")
    if not st.done("switch"):
        _deploy(o, st, "switch", [String("ActiveControl=", new)])
        var outs = _outputs(o)
        var on = _out(
            o.aws(
                String(
                    "ec2 describe-addresses --allocation-ids ",
                    _q(outs.get("AddressAllocation", "")),
                    " --query 'Addresses[0].InstanceId' --output text",
                )
            )
        )
        if on != new_id:
            st.note(
                String(
                    "switch: the Elastic IP is on ",
                    on,
                    ", not ",
                    new_id,
                    "; --resume tries again, --rollback undoes",
                )
            )
            return 3
        if (
            _system(
                o.aws(
                    String(
                        "ec2 stop-instances --instance-ids ",
                        _q(old_id),
                        " > /dev/null",
                    )
                )
            )
            != 0
        ):
            st.note(
                String(
                    "switch: ",
                    old_id,
                    " didn't stop; stop it by hand (aws ec2 stop-instances)",
                )
            )
        _s3_rm(o, pointer)
        var keep = _seconds(_keep(o))
        st.set("switched", String(now()))
        st.set("keep_until", String(now() + Int64(keep)))
        st.mark("switch")
        var url = outs.get("SslipUrl", "")
        if url:
            var answered = False
            for _ in range(10):
                if (
                    _system(
                        String("curl -fsS -o /dev/null --max-time 10 ", _q(url))
                    )
                    == 0
                ):
                    answered = True
                    break
                sleep(poll)
            st.note(
                String(
                    "switch: ",
                    url,
                    String(" answers") if answered else String(
                        " doesn't answer yet (DNS, or Caddy's certificate);"
                        " --rollback goes back"
                    ),
                )
            )
        st.note(
            String(
                (
                    "switch: done; the pipelines are still paused, unpause them"
                    " (morca --remote <ui> unpause <pipeline>). "
                ),
                old_id,
                " is kept, stopped, until ",
                _when(Int64(Int(st.get("keep_until")))),
            )
        )
    return _retire(o, st)


def _retire(o: _Opts, mut st: _State) raises -> Int:
    var until = Int64(Int(st.get("keep_until")))
    var old = st.get("old")
    var old_id = st.get("old_instance")
    if now() < until:
        st.note(
            String(
                "retire: ",
                old_id,
                " is kept until ",
                _when(until),
                (
                    "; then morca aws replace-control --resume terminates it,"
                    " or --rollback goes back to it"
                ),
            )
        )
        return 0
    _deploy(o, st, "retire", [String(_cap(old), "Slot=false")])
    st.mark("retire")
    st.end("done")
    return 0


def _rollback(o: _Opts, mut st: _State) raises -> Int:
    var old = st.get("old")
    var new = st.get("new")
    var old_id = st.get("old_instance")
    var new_id = st.get("new_instance")
    var bucket = st.get("bucket")
    var pointer = String(
        "s3://", bucket, "/backups/", o.stack, "/restore-", new
    )
    if st.done("retire"):
        print("morca aws replace-control: the old instance is gone")
        return 2
    if not st.done("switch"):
        st.note("rollback: before the switch")
        if _instance_of(_outputs(o), new):
            _deploy(o, st, "rollback", [String(_cap(new), "Slot=false")])
        if st.get("done.freeze"):
            if _on(o, st, old_id, "rollback", _unfreeze())[0] != 0:
                return 3
        _s3_rm(o, pointer)
        st.end("rolled-back")
        return 0
    st.note(String("rollback: after the switch, from ", new_id, " to ", old_id))
    var back = st.get("back")
    if not back:
        back = String(
            "s3://", bucket, "/backups/", o.stack, "/", _stamp(now()), "-back"
        )
        st.set("back", back)
    if not st.get("rb.quiet"):
        while True:
            var got = _on(o, st, new_id, "rollback-quiet", _quiet())
            if got[0] == 0:
                break
            if "not paused:" in got[1] or not o.wait:
                st.note(
                    "rollback: refused; pause every pipeline and let its runs"
                    " finish, or --wait for them"
                )
                return 3
            sleep(_poll())
        st.set("rb.quiet", _when(now()))
    if not st.get("rb.freeze"):
        if _on(o, st, new_id, "rollback-freeze", _freeze())[0] != 0:
            return 3
        st.set("rb.freeze", _when(now()))
    if not st.get("rb.backup"):
        if _on(o, st, new_id, "rollback-backup", _backup(back, "", ""))[0] != 0:
            return 3
        st.set("rb.backup", _when(now()))
    if not st.get("rb.start"):
        _ = _system(
            o.aws(String("ec2 start-instances --instance-ids ", _q(old_id)))
        )
        _ = _system(
            o.aws(
                String("ec2 wait instance-running --instance-ids ", _q(old_id))
            )
        )
        if not _wait_reachable(o, st, old_id, "rollback-start", "true"):
            st.note(
                String(
                    "rollback: ",
                    old_id,
                    " isn't reachable; --rollback tries again",
                )
            )
            return 3
        st.set("rb.start", _when(now()))
    if not st.get("rb.restore"):
        if _on(o, st, old_id, "rollback-restore", _restore_here(back))[0] != 0:
            return 3
        st.set("rb.restore", _when(now()))
    if not st.get("rb.switch"):
        _deploy(o, st, "rollback", [String("ActiveControl=", old)])
        st.set("rb.switch", _when(now()))
    _deploy(o, st, "rollback", [String(_cap(new), "Slot=false")])
    st.note(
        "rollback: done; the pipelines are still paused, unpause them once"
        " it's checked"
    )
    st.end("rolled-back")
    return 0


def replace_control(args: List[String]) raises -> Int:
    """`morca aws replace-control ...`: `args` is the whole command line."""
    var o = _Opts(args, 3)
    if len(o.rest) > 0:
        print("morca aws replace-control: unknown arguments:", o.rest[0])
        return 2
    _ = _seconds(_keep(o))
    if o.smoke:
        var eq = o.smoke.find("=").or_else(-1)
        if eq <= 0 or eq + 1 >= o.smoke.byte_length():
            print("morca aws replace-control: --smoke is PIPELINE=KEY")
            return 2
        for b in String(o.smoke[byte=:eq]).as_bytes():
            var c = Int(b)
            if not (
                (c >= ord("a") and c <= ord("z"))
                or (c >= ord("A") and c <= ord("Z"))
                or (c >= ord("0") and c <= ord("9"))
                or c == ord("_")
                or c == ord("-")
                or c == ord(".")
            ):
                print(
                    "morca aws replace-control: not a pipeline name:", o.smoke
                )
                return 2
    var st = _State(o.stack)
    if o.plan:
        return _plan(o, st)
    if o.rollback:
        if not st.started():
            print(
                "morca aws replace-control: no replacement of",
                o.stack,
                "is in progress (",
                st.path,
                ")",
            )
            return 2
        return _rollback(o, st)
    if st.started() and not o.resume:
        print(
            "morca aws replace-control: a replacement of",
            o.stack,
            "is in progress since",
            st.get("started"),
            "(",
            st.path,
            "): --resume goes on, --rollback goes back",
        )
        return 2
    if not st.started():
        if o.resume:
            print("morca aws replace-control: nothing to resume")
            return 2
        var outs = _outputs(o)
        var old = outs.get("ActiveControl", "blue")
        var new = _other(old)
        var old_id = _instance_of(outs, old)
        if not old_id:
            raise Error("morca aws: the stack has no control instance")
        var other = _instance_of(outs, new)
        if other:
            print(
                String(
                    "morca aws replace-control: slot ",
                    new,
                    " has an instance already, ",
                    other,
                    ", from a replacement with no state file here (",
                    st.path,
                    "). Turn the slot off by hand (",
                    _cap(new),
                    "Slot=false; DESIGN.md, Replacing the control instance)",
                    " and run it again.",
                )
            )
            return 2
        var t = now()
        st.set("stack", o.stack)
        st.set("started", _when(t))
        st.set("old", old)
        st.set("new", new)
        st.set("old_instance", old_id)
        st.set("bucket", outs.get("Bucket", ""))
        st.set(
            "prefix",
            String(
                "s3://",
                outs.get("Bucket", ""),
                "/backups/",
                o.stack,
                "/",
                _stamp(t),
            ),
        )
        st.note(
            String(
                "start: replace ",
                old_id,
                " (slot ",
                old,
                ") with a new instance in slot ",
                new,
            )
        )
    elif o.keep_old and st.done("switch"):
        # --resume --keep-old: the window counted from the switch again.
        st.set(
            "keep_until",
            String(
                Int64(Int(st.get("switched"))) + Int64(_seconds(o.keep_old))
            ),
        )
    return _forward(o, st)
