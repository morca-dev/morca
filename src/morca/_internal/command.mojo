"""The `morca` command: the scheduler, the UI and registration, in a binary
that links no pipeline. A project builds its own from two lines:

    from morca.command import morca_command

    def main() raises:
        morca_command()

Its commands:

    pixi run morca
    ./build/morca locate ./build/taxi --root .   # taxi.source.json, for the UI's links
    ./build/morca register ./build/taxi [...]   # with ./morca.toml (morca.config)
    ./build/morca config show taxi   # its settings, and where each came from
    ./build/morca config export      # a morca.toml from the registrations
    ./build/morca backfill taxi 2011-01..2024-12
    ./build/morca backfill --rerun taxi 2024-03     # again, though it succeeded
    ./build/morca cancel taxi @all   # its queued, running and retrying runs
    ./build/morca pause taxi         # start none of its runs; morca unpause taxi
    ./build/morca tick
    ./build/morca scheduler
    ./build/morca ui                 # http://127.0.0.1:8270, or MORCA_UI_ADDR
                                    # (the worker API on MORCA_WORKER_ADDR too)
    ./build/morca sample --out m.jsonl --pid 1234   # machine metrics
    ./build/morca lineage lake.report [<snapshot>]
    ./build/morca rebuild raw.events 2024-03
    ./build/morca status taxi        # its state and latest runs
    ./build/morca login https://morca.example.com   # then --remote, below
    ./build/morca --remote morca.example.com backfill taxi 2024-03

Needs `MORCA_DATABASE_URL`, but for the commands `--remote` (or
`MORCA_REMOTE`) sends to a deployed `morca ui` instead (`morca._internal.remote`). See
`morca._internal.scheduler` for what a tick does, and `morca._internal.web` for the pages,
`morca._internal.lineage` for what `lineage` prints, and `morca._internal.sensors` for what
`rebuild` plans.
Exit codes: 0, 2 for a usage error, 3 for any other error.
"""

from std.ffi import c_int
from std.os import getenv
from std.os.path import exists
from std.sys import argv, exit, stderr

import morca._internal.db.notify as notify_db

from morca._internal.actions import cancel_runs, pause_pipeline
from morca._internal.auth import add_user, remove_user, users
from morca._internal.aws import aws_command
from morca._internal.aws_replace import replace_control
from morca.civil import now
from morca._internal.expiry import expirable, expire_argv, maintain_binary
from morca._internal.lineage import Made, SnapshotRef, back, forward, latest
from morca._internal.locate import locate
from morca._internal.pause import retire
from morca._internal.notify import (
    alert,
    configured as notify_configured,
    flush as flush_notify,
    resolve as resolve_alert,
    send_now,
)
from morca._internal.proc import absolute, binary_seconds, capture
from morca._internal.remote import (
    Api,
    api_command,
    is_remote_command,
    login_command,
    logout_command,
    remote_api,
    remote_target,
)
from morca._internal.sample import sample_main
from morca._internal.upgrade import upgrade_command
from morca._internal.apps_config import apps_text
from morca._internal.config import (
    ProjectConfig,
    RegisterFlags,
    canonical_flag,
    refuse_orca_toml,
)
from morca._internal.config_show import (
    export_toml,
    show_json,
    shown,
)
from morca._internal.instances import (
    ask_drain,
    drain_limit,
    instances,
    overlap_on,
    overlap_refusal,
    wait_for_lead,
)
from morca._internal.dataset_config import read_datasets, record_datasets
from morca._internal.pool_config import read_pools, record_pools
from morca._internal.registering import register_pipeline
from morca._internal.registered import Registered, registered
from morca._internal.fill_requesting import cancel_fill, request_fill
from morca._internal.scheduler import Scheduler
from morca._internal.tick import tick
from morca._internal.control import fetch_secret
from morca._internal.ec2 import vcpus
from morca._internal.fleet import hourly_price
from morca._internal.secrets import secret_problem
from morca._internal.sensors import rebuild, rebuilds
from morca._internal.state import State
from morca._internal.watchdog import acknowledge, snooze as snooze_rule
from morca._internal.auth import audit
from morca._internal.tokens import revoke_user_tokens, user_tokens
from morca._internal.web.server import DEFAULT_ADDR, serve_ui
from morca._internal.web.drain import stop_asked, stop_signals
from morca._internal.worker import worker_command
from morca._internal.workers import (
    create_worker_token,
    revoke_worker_token,
    worker_rows,
    worker_token_days,
)

comptime USAGE = """usage:
  morca locate <pipeline binary> [...] [--root <dir>]
  morca upgrade [--file <upgrade.toml>] [--from V] --to V [--when before|after]
                (a release's upgrade steps, a line each, for deploy.sh;
                the file defaults to MORCA_UPGRADE or /opt/morca/upgrade.toml)
  morca aws up|push|register|app|status|replace-control|down ...
                                    (morca aws for more)
  morca register [--image <image>] [--head-type T] [--worker-type T]
                [--workers N|MIN..MAX] [--worker-procs N|auto] [--spot]
                [--secret NAME=ID ...]
                [--placement control|ec2|worker:<pool>|default]
                [--max-runs N|auto] [--cpus N|MIN..MAX] [--memory-gb N|MIN..MAX]
                [--config <morca.toml>|--no-config] [--overlay <file>]
                [<pipeline binary> ...]
                (no binaries: every [pipelines.<name>] of the file not
                enabled = false, in
                MORCA_PIPELINES_DIR or pipelines/ next to it; how its runs run comes from morca.toml, ./morca.toml or
                MORCA_CONFIG unless --config names another, with the stack's
                overlay laid on it, --overlay or MORCA_CONFIG_OVERLAY;
                flags over it; morca config show)
                (--worker-procs: dista worker processes per EC2 worker
                instance, auto = one per vCPU; default 1. --placement
                control: runs on the scheduler's own host, morca.control;
                default: the scheduler's runner)
                <pipeline binary> [...]
  morca backfill [--rerun [--allow-append]] [--preview|--as-fill]
                <pipeline> KEY[..KEY][,...]
                (keyed: NAME[,...]|@all|@file:<path>; --rerun: done ones too,
                refused for steps that append unless --allow-append;
                --preview: what it would queue, queueing nothing;
                --as-fill: a fill request, which the scheduler runs as fill
                runs within keys_per_run, fill_max_runs, fill_window and
                fill_budget_per_day, after the other runs: morca-toml.md)
  morca backfill --cancel <pipeline>  (its fill request, and its runs)
  morca start <pipeline> KEY[..KEY][,...]   (one run over them all)
  morca cancel <pipeline> KEY[..KEY][,...]|@all
                (its queued, running and retrying runs over those keys)
  morca cancel <run>
  morca resume [--allow-new-code] <run>
  morca rerun [--allow-append] <run> <step>
                                    (a new run, from that step on)
  morca pause|unpause <pipeline>     (the scheduler starts none of its runs)
  morca retire <pipeline>            (no longer registered: none of its runs
                                    start, and status leaves it out; its
                                    runs and tables stay; morca register
                                    brings it back)
  morca status [<pipeline>] [--json]
  morca config show [<pipeline>] [--json]
                (how each runs, and where each value came from: code
                default, morca.toml, flag, environment)
  morca config export [--out <path>|-] [--force]
                (a morca.toml from what's registered; default ./morca.toml)
  morca config show --file [<morca.toml>] [--overlay <file>]
                (the file as register reads it, the overlay laid on it, with
                no database; each value the overlay set says so)
  morca config apps [<morca.toml>] [--overlay <file>]
                (its [apps.<name>] tables, a line per fact, as the stack's
                script reads them; secrets by ID; no database)
  morca config check [<morca.toml>] [--overlay <file>] [--secrets]
                (checks a file as register does, and its instance types,
                with no database; --secrets reads each secret too)
  morca watchdog status [--json]     (rules, each threshold and value, trips)
  morca watchdog snooze <rule> <duration>   (2h, 30m, 1d; off ends it)
  morca watchdog ack [--all|<trip id>]   (keep a trip's pipelines paused and
                                    clear its banner; status still lists it)
  morca alerts [--kind K] [--open|--resolved] [--limit N] [--json]
                                    (the alerts sent, newest first: Ops ›
                                    Alerts)
  morca notify test                  (sends a test message to MORCA_NOTIFY_URL,
                                    morca.notify)
  morca notify --kind K [--subject S] [--title T] [--priority high|default|
              low] [--tags a,b] [--click URL] [--resolved] [message ...]
                                    (an alert from a script, held back like
                                    the scheduler's: once per kind and subject
                                    in MORCA_NOTIFY_MIN_SECONDS)
  morca tick
  morca scheduler                    (with MORCA_OVERLAP=on an instance that
                                    leads, or drains once a newer one runs,
                                    for at most MORCA_DRAIN_SECONDS, which
                                    it needs: docs/overlap.md)
  morca scheduler status             (the instances: role, runs, last seen)
  morca scheduler drain <id>         (asks instance <id> to drain and exit)
  morca scheduler can-overlap        (exit 0 if this binary can start beside
                                    the scheduler going now, 1 if a deploy
                                    must stop it first; doesn't migrate)
  morca scheduler wait-lead [--timeout S]   (until the newest instance leads)
  morca ui
  morca sample --out <location>|- [--pid PID] [--match PATH] [--dirs D,...]
              [--seconds S] [--count N] [--keep N]
                                      (machine metrics, morca.sample)
  morca lineage <dataset> [<snapshot>]
  morca rebuild <dataset> KEY[..KEY][,...]
  morca expire <dataset>|--all [--older-than 30d|12h|90m] [--keep N]
              [--dry-run] [--report]   (snapshot expiry, via morca_maintain)
  morca user add|remove <name>       (add reads the password from stdin)
  morca user list
  morca user tokens <name>           (its API tokens, from morca login)
  morca user revoke <name> <id>|@all
  morca worker-token create --pool <pool> [--days N] [--label L]
  morca worker-token list
  morca worker-token revoke <id>
  morca worker --pool <pool> [--remote <url>] [--token-file <path>]
              [--max-runs N] [--poll-seconds S] [--dir <dir>]
              [--image <image>] [--name <name>] [--advertise <address>]
                (runs pool's runs here, over the UI's API: morca.worker)
  morca login [<url>] [--user NAME] [--days N] [--label L]
  morca logout [<url>]
  morca --remote <url> backfill|start|cancel|pause|unpause|resume|rerun|
                      rebuild|status|lineage|watchdog|alerts ...
                (to a deployed morca ui, as the user morca login logged in;
                or MORCA_REMOTE=<url>)"""


def _backfill_flags(args: List[String]) -> Bool:
    """Whether `morca backfill` has its two arguments after flags it knows
    here: `--rerun`, `--allow-append` with it, and `--as-fill`."""
    if len(args) < 4:
        return False
    var rerun = False
    var allow = False
    var as_fill = False
    for i in range(2, len(args) - 2):
        if args[i] == "--rerun" and not rerun:
            rerun = True
        elif args[i] == "--allow-append" and not allow:
            allow = True
        elif args[i] == "--as-fill" and not as_fill:
            as_fill = True
        else:
            return False
    return rerun or not allow


def _registered_one(mut db: State, name: String) raises -> Registered:
    var ps = registered(db, name)
    if len(ps) == 0:
        raise Error("morca: pipeline ", name, " isn't registered")
    return ps[0].copy()


def _usage(msg: String = ""):
    if msg:
        print(msg)
    print(USAGE)
    exit(2)


def _locate(args: List[String]) raises -> Int:
    """`morca locate`: each binary's `<binary>.source.json`."""
    var root = String(".")
    var binaries = List[String]()
    var i = 2
    while i < len(args):
        if args[i] == "--root" and i + 1 < len(args):
            root = args[i + 1]
            i += 2
        else:
            binaries.append(args[i])
            i += 1
    if len(binaries) == 0:
        _usage("locate needs a pipeline binary")
    for b in binaries:
        var got = capture([b, "describe"], binary_seconds())
        if got[0] != 0:
            raise Error("morca: ", b, " describe exited ", got[0], ": ", got[1])
        var map = locate(got[1], root)
        with open(String(b, ".source.json"), "w") as f:
            f.write(map, "\n")
        print("located", b, map)
    return 0


def _notify(args: List[String]) raises -> Int:
    """`morca notify`: a message to the person MORCA_NOTIFY_URL reaches
    (`morca._internal.notify`). `test` sends one at once. Otherwise it's an alert of a
    kind and subject: recorded in Postgres, so it isn't sent twice in
    `MORCA_NOTIFY_MIN_SECONDS` and is tried again by the scheduler if ntfy is
    down; or sent at once when there is no database."""
    if not notify_configured():
        print(
            (
                "morca: alerts are off: set MORCA_NOTIFY_URL (and the topic's"
                " secret with MORCA_NOTIFY_SECRET)"
            ),
            file=stderr,
        )
        return 1
    if len(args) == 3 and args[2] == "test":
        try:
            send_now(
                "morca: test alert",
                "If you can read this, morca's alerts reach you.",
                "default",
                "white_check_mark",
            )
        except e:
            print("morca: the test alert wasn't sent:", e, file=stderr)
            return 1
        print("sent")
        return 0
    var kind = String()
    var subject = String("default")
    var title = String()
    var priority = String("default")
    var tags = String()
    var click = String()
    var resolved = False
    var words = List[String]()
    var i = 2
    while i < len(args):
        var a = args[i]
        if a == "--resolved":
            resolved = True
            i += 1
        elif (
            a == "--kind"
            or a == "--subject"
            or a == "--title"
            or a == "--priority"
            or a == "--tags"
            or a == "--click"
        ) and i + 1 < len(args):
            var v = args[i + 1]
            if a == "--kind":
                kind = v
            elif a == "--subject":
                subject = v
            elif a == "--title":
                title = v
            elif a == "--priority":
                priority = v
            elif a == "--tags":
                tags = v
            else:
                click = v
            i += 2
        else:
            words.append(a)
            i += 1
    if not kind:
        _usage("morca notify needs test, or --kind")
    if priority not in ["high", "default", "low", "urgent", "min"]:
        _usage("morca notify --priority is high, default or low")
    var body = String()
    for k in range(len(words)):
        body.write(" " if k else "", words[k])
    if not title:
        title = String("morca: ", kind)
    var url = getenv("MORCA_DATABASE_URL")
    if url:
        try:
            var db = State(url)
            db.migrate()
            if resolved:
                resolve_alert(db, kind, subject, title, body, click)
                _ = flush_notify(db)
                print("resolved")
                return 0
            var queued = alert(
                db, kind, subject, priority, tags, title, body, click
            )
            if not queued:
                print("held back: the same alert was sent lately")
                return 0
            if notify_db.is_pending(db.conn, kind, subject):
                print(
                    (
                        "not sent yet: ntfy didn't answer; the scheduler tries"
                        " again"
                    ),
                    file=stderr,
                )
                return 1
            print("sent")
            return 0
        except e:
            print(
                "morca: no database for the alert's record (",
                e,
                ")",
                file=stderr,
            )
    try:
        send_now(title, body, priority, tags, click)
    except e:
        print("morca: the alert wasn't sent:", e, file=stderr)
        return 1
    print("sent")
    return 0


def _command(args: List[String], target: String) raises -> Int:
    if args[1] == "login":
        return login_command(args, target)
    if args[1] == "logout":
        return logout_command(args, target)
    if target and is_remote_command(args[1]):
        var api = remote_api(target)
        return api_command(api, args)
    if args[1] == "locate":
        return _locate(args)
    if args[1] == "upgrade":
        # A file only, for deploy.sh: no database (morca.upgrade).
        return upgrade_command(args)
    if args[1] == "aws":
        if len(args) > 2 and args[2] == "replace-control":
            return replace_control(args)
        return aws_command(args)
    if args[1] == "sample":
        return sample_main(args)
    if args[1] == "notify":
        return _notify(args)
    if args[1] == "worker":
        # Talks only to the UI's API, with no database (morca.worker).
        return worker_command(args, target)
    if args[1] == "config" and len(args) >= 3 and args[2] == "check":
        # A file only, for a project's CI: no database.
        return _config_check(args)
    if (
        args[1] == "config"
        and len(args) >= 4
        and args[2] == "show"
        and args[3] == "--file"
    ):
        return _config_check(args, show=True)
    if args[1] == "config" and len(args) >= 3 and args[2] == "apps":
        # What a stack builds an app's environment from (morca-stack).
        return _config_check(args, apps=True)
    var url = getenv("MORCA_DATABASE_URL")
    if not url:
        _usage("morca needs MORCA_DATABASE_URL")
    var cmd = args[1]
    # Commands that print what a page of the UI shows, or do what its
    # buttons do, over the database here as `--remote` does over HTTPS.
    if (
        cmd == "watchdog"
        and (len(args) == 3 or len(args) == 4)
        and args[2] == "ack"
    ):
        var db = State(url)
        db.migrate()
        var which = String("all")
        if len(args) == 4 and args[3] != "--all":
            which = args[3]
        var trip = 0
        if which != "all":
            try:
                trip = Int(which)
            except:
                _usage("morca watchdog ack [--all|<trip id>]")
        var who = getenv("USER", "local")
        var n = acknowledge(db, trip, who)
        audit(db, who, String("/watchdog/", which, "/ack"), 0, "", "local")
        print("acknowledged", n, "trip" if n == 1 else "trips")
        return 0
    if cmd == "watchdog" and len(args) == 5 and args[2] == "snooze":
        # Audited as the local user, since there is no session or token.
        var db = State(url)
        db.migrate()
        var secs = snooze_rule(db, args[3], args[4], "cli")
        var who = getenv("USER", "local")
        audit(
            db,
            who,
            String("/watchdog/", args[3], "/snooze"),
            0,
            String("duration=", args[4]),
            "local",
        )
        if secs:
            print("snoozed", args[3], "for", args[4])
        else:
            print("unsnoozed", args[3])
        return 0
    if (
        cmd == "watchdog"
        or cmd == "alerts"
        or cmd == "status"
        or cmd == "start"
        or cmd == "resume"
        or cmd == "rerun"
        or (cmd == "cancel" and len(args) == 3)
        or (cmd == "backfill" and "--preview" in args)
    ):
        var api = Api(url)
        return api_command(api, args)
    if cmd == "register":
        return _register(url, args)
    if cmd == "config" and len(args) >= 3:
        return _config(url, args)
    if cmd == "backfill" and len(args) == 4 and args[2] == "--cancel":
        var db = State(url)
        db.migrate()
        print(cancel_fill(db, _registered_one(db, args[3])))
        return 0
    if cmd == "backfill" and _backfill_flags(args) and "--as-fill" in args:
        # A fill request (#465): the scheduler runs its keys as fill runs.
        var db = State(url)
        db.migrate()
        print(
            request_fill(
                db,
                _registered_one(db, args[len(args) - 2]),
                args[len(args) - 1],
                "--rerun" in args,
                "--allow-append" in args,
            )
        )
        return 0
    if cmd == "backfill" and _backfill_flags(args):
        # --rerun queues keys that are done as well; a key in a queued or
        # running run is still left to it. --allow-append lets a rerun
        # append again to what its steps don't replace.
        var rerun = "--rerun" in args
        var s = Scheduler(url)
        var got = s.backfill(
            args[len(args) - 2],
            args[len(args) - 1],
            rerun,
            "--allow-append" in args,
        )
        # Why keys weren't queued goes to stderr, so the count stays the
        # one line of output.
        for line in got.skipped():
            print(line, file=stderr)
        print("queued", len(got.runs), "runs")
        return 0
    if cmd == "cancel" and len(args) == 4:
        var db = State(url)
        db.migrate()
        var o = cancel_runs(db, args[2], args[3])
        if o.refused:
            raise Error("morca: ", o.refused)
        print("cancelled", o.queued, "runs")
        return 0
    if (cmd == "pause" or cmd == "unpause") and len(args) == 3:
        var db = State(url)
        db.migrate()
        var o = pause_pipeline(db, args[2], cmd == "pause")
        if o.refused:
            raise Error("morca: ", o.refused)
        print(cmd + "d", args[2])
        return 0
    if cmd == "retire" and len(args) == 3:
        var db = State(url)
        db.migrate()
        var why = retire(db, args[2])
        if why:
            raise Error("morca: ", why)
        print("retired", args[2])
        return 0
    if cmd == "tick" and len(args) == 2:
        var s = Scheduler(url)
        s.wait_for_binaries = True
        tick(s, now())
        return 0
    if cmd == "scheduler" and len(args) >= 3:
        return _scheduler(url, args)
    if cmd == "scheduler" and len(args) == 2:
        # An instance needs its drain limit (#390): refused before anything,
        # the schema's migration included.
        if overlap_on():
            _ = drain_limit()
        var s = Scheduler(url)
        s.say_pressure()
        s.contain()
        s.join()
        # An instance ends its row on SIGTERM (docker stop) or SIGINT
        # before it exits (#426). A scheduler that isn't one dies on them
        # at once, as before, mid-tick included.
        var stop_fd = c_int(-1)
        if s.instance > 0:
            stop_fd = stop_signals()
        while not s.finished:
            # A tick that fails (the database is down) is tried again; the
            # state it would have changed is all in Postgres.
            try:
                tick(s, now())
            except e:
                print("morca: tick failed:", e)
                try:
                    if s.instance > 0:
                        # Its processes stay its own (docs/overlap.md).
                        s.reconnect(url)
                    else:
                        s = Scheduler(url)
                        s.contain()
                except:
                    pass
            if not s.finished and stop_asked(stop_fd, 1000):
                print("morca: scheduler: stopping (SIGTERM or SIGINT)")
                try:
                    s.stop()
                except e:
                    print("morca: scheduler: couldn't end its instance:", e)
                    return 1
        return 0
    if cmd == "lineage" and (len(args) == 3 or len(args) == 4):
        var db = State(url)
        db.migrate()
        var id: Int64
        if len(args) == 4:
            try:
                id = Int64(Int(args[3]))
            except:
                _usage(String("not a snapshot: ", args[3]))
                return 2
        else:
            id = latest(db, args[2])
            if id < 0:
                raise Error("morca: no snapshot of ", args[2], " is recorded")
        var start = SnapshotRef(args[2], id)
        print(start)
        print("made from:")
        _print_made(back(db, start))
        print("made from it:")
        _print_made(forward(db, start))
        return 0
    if cmd == "rebuild" and len(args) == 4:
        var db = State(url)
        db.migrate()
        var id = rebuild(db, args[2], args[3])
        print("rebuild", id)
        for p in rebuilds(db, id)[0].plan:
            print("  level", p.level, p.pipeline, p.partitions)
        return 0
    if cmd == "expire" and len(args) >= 3:
        return _expire(url, args)
    if cmd == "user" and len(args) >= 3:
        var db = State(url)
        db.migrate()
        if args[2] == "list" and len(args) == 3:
            for u in users(db):
                print(u)
            return 0
        if args[2] == "add" and len(args) == 4:
            var password = String(input().rstrip("\r\n"))
            if add_user(db, args[3], password):
                print("added", args[3])
            else:
                print(
                    "changed the password of",
                    args[3],
                    "and ended their sessions",
                )
            return 0
        if args[2] == "remove" and len(args) == 4:
            if not remove_user(db, args[3]):
                raise Error("morca: no user ", args[3])
            print("removed", args[3])
            return 0
        if args[2] == "tokens" and len(args) == 4:
            var ts = user_tokens(db, args[3])
            if len(ts) == 0:
                print("no tokens")
            for t in ts:
                print(
                    t.id,
                    t.label,
                    "created",
                    t.created,
                    "used",
                    t.last_used if t.last_used else String("never"),
                    "expired" if t.expired else "expires",
                    t.expires,
                )
            return 0
        if args[2] == "revoke" and len(args) == 5:
            var id = 0
            if args[4] != "@all":
                try:
                    id = Int(args[4])
                except:
                    id = -1
                if id <= 0:
                    _usage(String("not a token's id, or @all: ", args[4]))
            var n = revoke_user_tokens(db, args[3], id)
            if n == 0 and id > 0:
                raise Error("morca: ", args[3], " has no token ", id)
            print("revoked", n, "tokens of" if n != 1 else "token of", args[3])
            return 0
    if cmd == "worker-token" and len(args) >= 3:
        return _worker_token(url, args)
    if cmd == "ui" and len(args) == 2:
        var db = State(url)
        db.migrate()
        serve_ui(
            url,
            getenv("MORCA_UI_ADDR", DEFAULT_ADDR),
            getenv("MORCA_WORKER_ADDR"),
        )
        return 0
    _usage()
    return 2


def _worker_token(url: String, args: List[String]) raises -> Int:
    """`morca worker-token create|list|revoke` (`orca.workers`)."""
    var db = State(url)
    db.migrate()
    var who = getenv("USER", "local")
    if args[2] == "create":
        var pool = String()
        var label = String()
        var days = 0
        var i = 3
        while i + 1 < len(args):
            if args[i] == "--pool":
                pool = args[i + 1]
            elif args[i] == "--label":
                label = args[i + 1]
            elif args[i] == "--days":
                try:
                    days = Int(args[i + 1])
                except:
                    _usage(String("not a count of days: ", args[i + 1]))
            else:
                _usage(String("unknown argument: ", args[i]))
            i += 2
        if i != len(args) or not pool:
            _usage("worker-token create needs --pool <pool>")
        var got = create_worker_token(
            db, pool, label, worker_token_days(days), who
        )
        var shown_label = label.copy() if label else pool.copy()
        audit(
            db,
            who,
            "worker-token create",
            0,
            String("pool=", pool, " label=", shown_label),
            "local",
        )
        # The token alone on stdout, for a script; the rest on stderr.
        print(got.token)
        print(
            "a worker token for pool", pool, "until", got.expires, file=stderr
        )
        return 0
    if args[2] == "list" and len(args) == 3:
        var rows = worker_rows(db)
        if len(rows) == 0:
            print("no worker tokens")
        for r in rows:
            print(
                r.id,
                r.pool,
                r.label,
                r.state,
                r.name if r.name else String("-"),
                "seen",
                r.last_seen if r.last_seen else String("never"),
                "expires",
                r.expires,
            )
        return 0
    if args[2] == "revoke" and len(args) == 4:
        var id: Int
        try:
            id = Int(args[3])
        except:
            _usage(String("not a worker token's id: ", args[3]))
            return 2
        if not revoke_worker_token(db, id):
            raise Error("morca: no live worker token ", id)
        audit(db, who, "worker-token revoke", 0, String("id=", id), "local")
        print("revoked worker token", id)
        return 0
    _usage()
    return 2


def _expire(url: String, args: List[String]) raises -> Int:
    """`morca expire`: each dataset's `morca_maintain expire`, with the
    snapshots morca still needs retained (`morca._internal.expiry`)."""
    var older = String()
    var keep = String()
    var dry_run = False
    var report = False
    var i = 3
    while i < len(args):
        if args[i] == "--older-than" and i + 1 < len(args):
            older = args[i + 1]
            i += 2
        elif args[i] == "--keep" and i + 1 < len(args):
            keep = args[i + 1]
            i += 2
        elif args[i] == "--dry-run":
            dry_run = True
            i += 1
        elif args[i] == "--report":
            report = True
            i += 1
        else:
            _usage(String("unknown argument: ", args[i]))
    var binary = maintain_binary()
    if not binary:
        raise Error(
            "morca: no morca_maintain binary (set MORCA_MAINTAIN, or build"
            " bin/morca_maintain.mojo calling morca.maintain.maintain_main"
            " beside morca)"
        )
    var db = State(url)
    db.migrate()
    var datasets = List[String]()
    if args[2] == "--all":
        datasets = expirable(db)
    else:
        datasets.append(args[2])
    var code = 0
    for ds in datasets:
        var a = expire_argv(db, binary, ds, older, keep, dry_run, report)
        var got = capture(a, 0)
        var out = String(got[1].strip())
        if got[0] != 0:
            print("morca: expiring", ds, "failed:", out, file=stderr)
            code = 1
        elif out:
            print(out)
    return code


comptime _FLAG_KEYS = [
    ("--head-type", "head_type"),
    ("--worker-type", "worker_type"),
    ("--workers", "workers"),
    ("--worker-procs", "worker_procs"),
    ("--placement", "placement"),
    ("--max-runs", "max_runs"),
    ("--cpus", "cpus"),
    ("--memory-gb", "memory_gb"),
]
"""`morca register`'s flags for morca.toml's keys (`morca._internal.config`)."""


def _config_binaries(file: ProjectConfig) raises -> List[String]:
    """The binary of each `[pipelines.<name>]` in `file`, in the directory
    MORCA_PIPELINES_DIR, else `pipelines/` next to the file. Raises, before
    anything is registered, if there is no such directory or a binary is
    missing."""
    var names = List[String]()
    for n in file.pipelines():
        if file.enabled(n):
            names.append(n)
        else:
            print("morca: skipping", n, "(enabled = false)", file=stderr)
    if len(names) == 0:
        raise Error(
            "morca: ", file.path, " names no [pipelines.<name>] to register"
        )
    var dir = getenv("MORCA_PIPELINES_DIR")
    if not dir:
        var full = absolute(file.path)
        var slash = full.rfind("/")
        var beside = String(full[byte=:slash]) if slash > 0 else String("/")
        dir = String(beside, "/pipelines")
        if not exists(dir):
            raise Error(
                (
                    "morca: no pipeline binaries: set MORCA_PIPELINES_DIR, put"
                    " them"
                ),
                " in ",
                dir,
                ", or name them: morca register <binary>...",
            )
    var out = List[String]()
    var missing = String()
    for n in names:
        var p = String(dir, "/", n)
        if not exists(p):
            missing.write(" " if missing else "", n)
        out.append(p)
    if missing:
        raise Error(
            "morca: ",
            file.path,
            " names pipelines with no binary in ",
            dir,
            ":",
            missing,
        )
    return out^


def _scheduler(url: String, args: List[String]) raises -> Int:
    """`morca scheduler <status|drain|can-overlap|wait-lead>`: the scheduler
    instances (`orca.instances`, docs/overlap.md)."""
    var db = State(url)
    var sub = args[2]
    if sub == "can-overlap" and len(args) == 3:
        # Doesn't migrate: it's asked before the new image runs anything.
        var why = overlap_refusal(db)
        if why:
            print("no:", why)
            return 1
        print("yes")
        return 0
    db.migrate()
    if sub == "status" and len(args) == 3:
        for line in instances(db):
            print(line)
        return 0
    if sub == "drain" and len(args) == 4:
        var id: Int
        try:
            id = Int(args[3])
        except:
            _usage(String("not an instance: ", args[3]))
            return 2
        if not ask_drain(db, id):
            raise Error("morca: no live scheduler instance ", id)
        print("asked scheduler instance", id, "to drain")
        return 0
    if sub == "wait-lead" and (len(args) == 3 or len(args) == 5):
        var timeout = 600.0
        if len(args) == 5:
            if args[3] != "--timeout":
                _usage(String("unknown option: ", args[3]))
            timeout = Float64(args[4])
        if not wait_for_lead(db, timeout):
            raise Error(
                "morca: the newest scheduler instance doesn't lead after ",
                Int(timeout),
                " s",
            )
        print("the newest scheduler instance leads")
        return 0
    _usage(String("unknown scheduler command: ", sub))
    return 2


def _register(url: String, args: List[String]) raises -> Int:
    """`morca register`: each binary's pipeline, with how its runs run from
    the project's morca.toml and the flags (`morca._internal.config`)."""
    var flags = RegisterFlags()
    var config_path = String()
    var no_config = False
    var b64 = String()
    var commit = String()
    var dirty = False
    var name = String("morca.toml")
    var overlay = getenv("MORCA_CONFIG_OVERLAY")
    var i = 2
    while i < len(args) and args[i].startswith("--"):
        var a = args[i]
        if a == "--spot" or a == "--no-config" or a == "--config-dirty":
            if a == "--spot":
                flags.spot = True
            elif a == "--no-config":
                no_config = True
            else:
                dirty = True
            i += 1
            continue
        if i + 1 >= len(args):
            _usage(String(a, " needs a value"))
        var v = args[i + 1]
        var key = String()
        for fk in materialize[_FLAG_KEYS]():
            if a == fk[0]:
                key = String(fk[1])
        if key:
            try:
                flags.values[key] = canonical_flag(key, v)
            except e:
                if key == "workers":
                    _usage(String("not a count or a range MIN..MAX: ", v))
                if key == "cpus" or key == "memory_gb":
                    _usage(String(a, " ", e))
                _usage(String(e))
        elif a == "--image":
            flags.image = v
        elif a == "--secret":
            # NAME=ID: the run's NAME is Secrets Manager's secret ID.
            var why = secret_problem(v)
            if why:
                _usage(why)
            flags.secrets.append(v)
        elif a == "--config":
            config_path = v
        elif a == "--overlay":
            overlay = v
        elif a == "--config-b64":
            # The file itself, from `morca aws register` on another machine.
            b64 = v
        elif a == "--config-commit":
            commit = v
        elif a == "--config-name":
            name = v
        else:
            _usage(String("unknown option: ", a))
        i += 2
    var explicit_paths = i < len(args)
    var file: ProjectConfig
    if b64:
        file = ProjectConfig.from_b64(b64, name, commit, dirty)
    elif no_config:
        file = ProjectConfig()
    elif config_path:
        file = ProjectConfig.load(config_path, overlay)
    elif getenv("MORCA_CONFIG"):
        file = ProjectConfig.load(getenv("MORCA_CONFIG"), overlay)
    elif exists("morca.toml"):
        file = ProjectConfig.load("morca.toml", overlay)
    else:
        refuse_orca_toml()
        file = ProjectConfig()
    if file.is_file():
        print(
            "morca: registering with",
            file.path,
            "(sha256 " + String(file.hash[byte=:12]) + ")",
            String("and the overlay ", file.overlay) if file.overlay else "",
            file=stderr,
        )
    var paths = List[String]()
    for k in range(i, len(args)):
        paths.append(args[k])
    if not explicit_paths:
        if not file.is_file():
            _usage("register needs a pipeline binary, or a morca.toml")
        paths = _config_binaries(file)
    var s = Scheduler(url)
    # Registered under an instance that drains, the new code could start
    # under the old image (docs/overlap.md#deploying): with MORCA_OVERLAP=on
    # a handover going on is waited for, MORCA_REGISTER_WAIT_SECONDS (120).
    var wait = Float64(getenv("MORCA_REGISTER_WAIT_SECONDS", "120"))
    if overlap_on() and not wait_for_lead(s.db, wait):
        raise Error(
            "morca: a scheduler handover is going on and the newest instance",
            " doesn't lead after ",
            Int(wait),
            " s; register once it does (morca scheduler status)",
        )
    for k in range(len(paths)):
        var got = register_pipeline(s, paths[k], now(), flags, file)
        if file.is_file() and not file.has(got):
            print(
                String(
                    "morca: warning: ",
                    got,
                    " isn't in ",
                    file.path,
                    "; flags left out keep what it was registered with",
                ),
                file=stderr,
            )
        print("registered", got)
    if file.is_file():
        # Its worker pools (morca.pool_config): the file's, and only those.
        var pools = read_pools(file.doc)
        var gone = record_pools(s.db, pools)
        for p in pools:
            print("pool", p.name, String("(", p.provider, ")"))
        for g in gone:
            print("pool", g, "removed: its machines go once idle")
        # Its datasets' settings (morca.dataset_config): the file's only.
        var sets = read_datasets(file.doc)
        var unset = record_datasets(s.db, sets)
        for d in sets:
            if not d.public:
                print("dataset", d.name, "(data not public)")
        for g in unset:
            print("dataset", g, "settings removed: its data is public")
    return 0


def _without_morca(e: String) -> String:
    return String(e[byte=7:]) if e.startswith("morca: ") else e


def _config_check(
    args: List[String], show: Bool = False, apps: Bool = False
) raises -> Int:
    """`morca config check [<file>] [--overlay <file>] [--secrets]`: `file`
    (`$MORCA_CONFIG`, else ./morca.toml), with the overlay (else
    `$MORCA_CONFIG_OVERLAY`) laid on it, as registering checks it, and each
    instance type sized; with `--secrets`, each secret read. 1 if anything
    is wrong. With `show` (`morca config show --file`), prints the file as
    register reads it instead; with `apps` (`morca config apps`), its
    `[apps.<name>]` tables, `morca._internal.apps_config.apps_text`'s lines."""
    var path = String()
    var overlay = getenv("MORCA_CONFIG_OVERLAY")
    var read_secrets = False
    var k = 4 if show else 3
    while k < len(args):
        if args[k] == "--secrets" and not show and not apps:
            read_secrets = True
        elif args[k] == "--overlay" and k + 1 < len(args):
            overlay = args[k + 1]
            k += 1
        elif not path and not args[k].startswith("--"):
            path = args[k]
        else:
            _usage(String("unknown argument: ", args[k]))
        k += 1
    if not path:
        if not getenv("MORCA_CONFIG"):
            refuse_orca_toml()
        path = getenv("MORCA_CONFIG", "morca.toml")
        if apps and not exists(path):
            # A project with no file has no apps declared.
            return 0
    var file: ProjectConfig
    try:
        file = ProjectConfig.load(path, overlay)
    except e:
        print(e, file=stderr)
        return 1
    if show:
        print(file.shown(), end="")
        return 0
    if apps:
        print(apps_text(file.apps()), end="")
        return 0
    var problems = 0
    for key in ["head_type", "worker_type"]:
        for e in file.entries(String(key)):
            try:
                _ = vcpus(e[1])
            except err:
                print(
                    e[0], ": ", _without_morca(String(err)), sep="", file=stderr
                )
                problems += 1
                continue
            if hourly_price(e[1]) < 0:
                print(
                    "morca: warning: ",
                    e[0],
                    ": ",
                    e[1],
                    " isn't in morca's price table (morca.fleet), so Ops >",
                    " Fleet and the watchdog's cost rule count it as $0 an",
                    " hour",
                    sep="",
                    file=stderr,
                )
    var secrets = file.entries("secrets")
    if read_secrets:
        for e in secrets:
            try:
                _ = fetch_secret(e[1])
            except err:
                print(
                    e[0], ": ", _without_morca(String(err)), sep="", file=stderr
                )
                problems += 1
    if problems > 0:
        print("morca:", path, "has", problems, "problem(s)", file=stderr)
        return 1
    var n = len(file.pipelines())
    var line = String(path)
    if file.overlay:
        line.write(" with ", file.overlay)
    line.write(": ok, ", n, " pipeline", "" if n == 1 else "s")
    var off = 0
    for p in file.pipelines():
        if not file.enabled(p):
            off += 1
    if off > 0:
        line.write(" (", off, " not enabled)")
    var napps = len(file.doc.tables(["apps"]))
    if napps > 0:
        line.write(", ", napps, " app", "" if napps == 1 else "s")
    if read_secrets:
        line.write(", ", len(secrets), " secret(s) readable")
    print(line)
    return 0


def _config(url: String, args: List[String]) raises -> Int:
    """`morca config show [<pipeline>] [--json]` and `morca config export
    [--out <path>|-] [--force]`."""
    var db = State(url)
    db.migrate()
    if args[2] == "show":
        var json = False
        var only = String()
        for k in range(3, len(args)):
            if args[k] == "--json":
                json = True
            elif not only and not args[k].startswith("--"):
                only = args[k]
            else:
                _usage(String("unknown argument: ", args[k]))
        var items = shown(db, only)
        if only and len(items) == 0:
            raise Error("morca: no pipeline ", only, " is registered")
        if json:
            print(show_json(items, only != ""))
        else:
            for k in range(len(items)):
                print(("\n" if k > 0 else "") + items[k].text(), end="")
        return 0
    if args[2] == "export":
        var out = String("morca.toml")
        var force = False
        var k = 3
        while k < len(args):
            if args[k] == "--out" and k + 1 < len(args):
                out = args[k + 1]
                k += 2
            elif args[k] == "--force":
                force = True
                k += 1
            else:
                _usage(String("unknown argument: ", args[k]))
        var text = export_toml(db)
        if out == "-":
            print(text, end="")
            return 0
        if exists(out) and not force:
            raise Error("morca: ", out, " exists; --force replaces it")
        with open(out, "w") as f:
            f.write(text)
        print("wrote", out)
        return 0
    _usage()
    return 2


def _print_made(ms: List[Made]):
    """One line per snapshot: how far it is, what made it, and from what."""
    if len(ms) == 0:
        print("  nothing")
    for m in ms:
        var line = String("  ", m.depth, " ", m.at, " by ", m.pipeline, " run ")
        line.write(m.run, " ", m.step)
        if m.partition:
            line.write(" ", m.partition)
        line.write(" code ", m.code)
        if len(m.inputs) > 0:
            line.write(" from")
            for i in m.inputs:
                line.write(" ", i)
        print(line)


def morca_command() raises:
    """The `morca` command: reads the command line, runs it, and exits with
    its code. A project's own `morca` binary is a `main` calling this."""
    var args = List[String]()
    for a in argv():
        args.append(String(a))
    var explicit = len(args) >= 2 and (
        args[1].startswith("--remote") or args[1].startswith("--url")
    )
    var target = String()
    try:
        target = remote_target(args)
    except e:
        print(e)
        exit(2)
    if len(args) < 2:
        _usage()
        return
    if explicit and not is_remote_command(args[1]):
        if args[1] != "login" and args[1] != "logout":
            _usage(
                String(
                    "morca ",
                    args[1],
                    " needs the database (MORCA_DATABASE_URL); --remote is for",
                    " the commands below that it lists",
                )
            )
    var code: Int
    try:
        code = _command(args, target)
    except e:
        var msg = String(e)
        if msg.startswith("usage: "):
            _usage(String(msg[byte=7:]))
        print(msg)
        code = 3
    exit(code)
