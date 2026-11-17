#!/usr/bin/env python3
"""The conformance suite (#519): drives any pipeline binary as morca's
runners and scheduler do, and checks it against docs/pipeline-protocol.md.

    tests/conformance.py [options] <binary> <manifest>
    tests/conformance.py new-run [options] <binary> <keys>

The manifest (tests/conformance/*.json) says what the pipeline is, so the
suite knows what to expect without reading the binary's code:

    {"pipeline": "toy",
     "registry_hash": "0xa3bcc571ad7c6939",     optional: pins the hash
     "partitions": "monthly",
     "keys": ["2024-01", "2024-02"],             the keys a run covers
     "steps": [{"name": "days", "kind": "mapped",
                "reads": [], "writes": []}, ...],   in run order
     "sensor": false,
     "env": {...},              set for every command
     "slow_env": {...},         makes the first step's attempts take 3 s or
                                more, longer than the stale limit (2 s here);
                                without it the kill, cancel and lost-run
                                checks are skipped
     "warehouse": true,         runs get a fresh MORCA_WAREHOUSE
     "setup": [[cmd...]],       run once per warehouse, before anything
     "commit_input": [cmd...]}  commits a new snapshot to a table a step
                                reads; "{warehouse}" in these is replaced

Runs are started only as a runner starts them: the suite inserts the run
row the way the scheduler does (`running`, owner `scheduler`, no
heartbeat) and runs `<binary> resume <run>`. `run --partitions` is never
used. Over Postgres (MORCA_DATABASE_URL, which `pixi run conformance`
gives) the pipeline is registered with `morca register`; over SQLite (a
file of the suite's own, always) the suite registers it itself, since no
scheduler runs there.

Every check prints one line: `ok`, `FAIL` (with the rule it tests and
what was wrong), `xfail` for a check known to fail until its issue lands
(KNOWN below), `XPASS` for one of those that passes (drop it from KNOWN),
or `skip` with why. The exit status is 1 if any check failed.

`new-run` is for tests/chaos.sh's conformance mode: it registers the
binary if it isn't yet, inserts a run over the comma-separated keys as
the scheduler would, and prints its ID.
"""

import argparse
import json
import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import uuid

DOC = "docs/pipeline-protocol.md"

# Checks known to fail until an issue lands: id -> issue. None now.
KNOWN: dict[str, str] = {}

STALE = 2.0
"""MORCA_STALE_SECONDS for every command: the suite is the scheduler."""

STATUSES = {"running", "succeeded", "failed", "skipped", "deferred", "cancelled"}

# A Mojo abort's stack dump, as a driver's output holds it (tests/test_crash.mojo).
CRASH = """ABORT: /src/project/pipelines/c2.mojo:6:14: the input is bad
 #0 0x0000000102be67b8 (/x/lib/libKGENCompilerRTShared.dylib+0xba7b8)
 #1 0x0000000187771744 (/usr/lib/system/libsystem_platform.dylib+0x180509744)
 #2 0x000000010286863c _abort_base Mojo/stdlib/std/os/os.mojo:242:31
 #3 0x000000010286863c abort Mojo/stdlib/std/os/os.mojo:261:16
 #4 0x000000010286863c main /src/project/pipelines/c2.mojo:6:14
 #5 0x000000010286863c __wrap_and_execute_raising_main Mojo/stdlib/std/builtin/_startup.mojo:107:18
"""


class Fail(Exception):
    pass


class Skip(Exception):
    pass


def need(cond, msg):
    if not cond:
        raise Fail(msg)


# --- Reporting ---


class Report:
    def __init__(self):
        self.counts = {"ok": 0, "FAIL": 0, "xfail": 0, "XPASS": 0, "skip": 0}

    def check(self, cid, section, rule, fn, where=""):
        """Runs `fn`, a check of `rule` (the doc's `section`), and prints
        its line. Returns whether it passed."""
        name = f"{where}/{cid}" if where else cid
        cite = f"{DOC}#{section}"
        known = KNOWN.get(cid)
        try:
            fn()
        except Skip as e:
            self._line("skip", name, cite, str(e))
            return False
        except Fail as e:
            if known:
                self._line("xfail", name, cite, f"until {known}: {rule}: {e}")
            else:
                self._line("FAIL", name, cite, f"{rule}: {e}")
            return False
        except Exception as e:  # the suite's own error counts as a failure
            self._line("FAIL", name, cite, f"{rule}: {type(e).__name__}: {e}")
            return False
        if known:
            self._line("XPASS", name, cite, f"passes: drop it from KNOWN ({known})")
        else:
            self._line("ok", name, cite, "")
        return True

    def _line(self, what, name, cite, msg):
        self.counts[what] += 1
        tail = f": {msg}" if msg else ""
        print(f"{what:<5} {name}  ({cite}){tail}", flush=True)

    def summary(self):
        c = self.counts
        print(
            f"conformance: {c['ok']} ok, {c['FAIL']} failed, {c['xfail']} known "
            f"to fail, {c['XPASS']} unexpectedly passing, {c['skip']} skipped",
            flush=True,
        )
        return c["FAIL"] == 0


# --- The run stores ---


def lit(s):
    if s is None:
        return "NULL"
    return "'" + str(s).replace("'", "''") + "'"


class Db:
    """One run store, queried with SQL written for Postgres (`orca.` tables);
    `{NOW}`, `{AGO:<seconds>}`, `{AGE:<column>}` (seconds), `{T}` and `{F}`
    are each dialect's."""

    def __init__(self, url):
        self.url = url
        self.pg = not url.startswith("sqlite:")
        if not self.pg:
            path = url[len("sqlite:"):]
            if path.startswith("//"):
                path = path[2:]
            self.path = path
        self.where = "pg" if self.pg else "sqlite"

    def sql(self, s):
        if self.pg:
            now = "now()"
            s = s.replace("{T}", "true").replace("{F}", "false")
        else:
            now = "((julianday('now') - 2440587.5) * 86400.0)"
            s = s.replace("orca.", "").replace("{T}", "1").replace("{F}", "0")
        while "{AGO:" in s:
            i = s.index("{AGO:")
            j = s.index("}", i)
            n = s[i + 5 : j]
            rep = f"(now() - interval '{n} seconds')" if self.pg else f"({now} - {n})"
            s = s[:i] + rep + s[j + 1 :]
        while "{AGE:" in s:
            i = s.index("{AGE:")
            j = s.index("}", i)
            c = s[i + 5 : j]
            rep = f"extract(epoch FROM now() - {c})" if self.pg else f"({now} - {c})"
            s = s[:i] + rep + s[j + 1 :]
        return s.replace("{NOW}", now)

    def q(self, s):
        """The rows, each a tuple of text or None."""
        s = self.sql(s)
        if self.pg:
            p = subprocess.run(
                ["psql", self.url, "-XAtq", "-v", "ON_ERROR_STOP=1",
                 "-F", "\x1f", "-R", "\x1e", "-P", "null=\x01", "-c", s],
                capture_output=True, text=True,
            )
            if p.returncode != 0:
                raise RuntimeError(f"psql: {p.stderr.strip()} in: {s}")
            out = p.stdout.rstrip("\n")
            if not out:
                return []
            return [
                tuple(None if v == "\x01" else v for v in r.split("\x1f"))
                for r in out.split("\x1e")
            ]
        con = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        try:
            rows = con.execute(s).fetchall()
        finally:
            con.close()
        return [tuple(None if v is None else _text(v) for v in r) for r in rows]

    def one(self, s):
        rows = self.q(s)
        return rows[0][0] if rows else None

    def has_schema(self):
        if self.pg:
            return self.one("SELECT to_regclass('orca.runs') IS NOT NULL") == "t"
        if not os.path.exists(self.path):
            return False
        return self.one("SELECT count(*) FROM sqlite_master WHERE name = 'runs'") == "1"

    def registered(self, name):
        return self.one(f"SELECT registry_hash FROM orca.pipelines WHERE name = {lit(name)}")

    def register_row(self, name, hash, describe):
        """The registration a pipeline gets where no scheduler runs."""
        if self.pg:
            self.q(
                "INSERT INTO orca.pipelines (name, registry_hash, describe) VALUES "
                f"({lit(name)}, {lit(hash)}, {lit(describe)}::jsonb) ON CONFLICT (name) "
                "DO NOTHING"
            )
        else:
            self.q(
                "INSERT INTO pipelines (name, registry_hash, describe, first_seen, "
                f"last_seen) VALUES ({lit(name)}, {lit(hash)}, {lit(describe)}, "
                "{NOW}, {NOW}) ON CONFLICT (name) DO NOTHING"
            )

    def new_run(self, pipeline, hash, keys, status="running", owner="scheduler",
                heartbeat="NULL"):
        """A run as the scheduler makes and starts it (docs: A run's life,
        2-3): its keys comma-joined, `running` as `scheduler`'s with no
        heartbeat unless said otherwise."""
        parts = lit(",".join(keys))
        if self.pg:
            return self.one(
                "INSERT INTO orca.runs (pipeline, registry_hash, partitions, trigger, "
                f"status, owner, heartbeat, started, starts) VALUES ({lit(pipeline)}, "
                f"{lit(hash)}, {parts}, 'manual', {lit(status)}, {lit(owner)}, "
                f"{heartbeat}, now(), 1) RETURNING id"
            )
        return self.one(
            "INSERT INTO runs (pipeline, registry_hash, partitions, trigger, status, "
            f"owner, heartbeat, created, started, token) VALUES ({lit(pipeline)}, "
            f"{lit(hash)}, {parts}, 'manual', {lit(status)}, {lit(owner)}, "
            f"{self.sql(heartbeat)}, {{NOW}}, {{NOW}}, {lit(str(uuid.uuid4()))}) "
            "RETURNING id"
        )

    def fake_attempt(self, run, step, partition, ord, host, hash, status="running"):
        """A step row and its attempt 1 as a process that's gone left them."""
        sid = self.one(
            "INSERT INTO orca.steps (run, step, partition, ord, status) VALUES "
            f"({run}, {lit(step)}, {lit(partition)}, {ord}, {lit(status)}) RETURNING id"
        )
        return self.one(
            "INSERT INTO orca.attempts (step, attempt, status, host, registry_hash, "
            f"started) VALUES ({sid}, 1, {lit(status)}, {lit(host)}, {lit(hash)}, "
            "{NOW}) RETURNING id"
        )

    def run_row(self, run):
        r = self.q(
            "SELECT status, coalesce(owner, ''), heartbeat IS NULL, ended IS NULL, "
            f"coalesce(error, ''), version FROM orca.runs WHERE id = {run}"
        )
        if not r:
            return None
        s, o, hb_null, ended_null, err, v = r[0]
        return {"status": s, "owner": o, "heartbeat": not _true(hb_null),
                "ended": not _true(ended_null), "error": err, "version": v}

    def attempts(self, run):
        """(attempt id, step, partition, attempt, status, host, hash, error,
        log, ended is set), in the order they were made."""
        return self.q(
            "SELECT a.id, s.step, s.partition, a.attempt, a.status, a.host, "
            "a.registry_hash, coalesce(a.error, ''), a.log, a.ended IS NOT NULL "
            "FROM orca.attempts a JOIN orca.steps s ON s.id = a.step "
            f"WHERE s.run = {run} ORDER BY a.id"
        )


def _text(v):
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def _true(v):
    return v in ("t", "1", "true", "True")


# --- The binary ---


class Binary:
    def __init__(self, path, manifest, morca, work):
        self.path = os.path.abspath(path)
        self.m = manifest
        self.morca = morca
        self.work = work
        self.warehouse = ""
        self.describe_text = ""
        self.describe = {}

    def env(self, db=None, extra=None, slow=False):
        e = {k: v for k, v in os.environ.items()
             if k not in ("MORCA_DATABASE_URL", "MORCA_STATE_URL", "MORCA_WAREHOUSE",
                          "MORCA_LOGS", "MORCA_RUN", "MORCA_STATE_TOKEN")}
        e["MORCA_STALE_SECONDS"] = str(int(STALE))
        e["MORCA_SAMPLE_SECONDS"] = "0"
        e.update(self.m.get("env", {}))
        if slow:
            e.update(self.m.get("slow_env", {}))
        if db is not None:
            e["MORCA_DATABASE_URL"] = db.url
        if self.warehouse:
            e["MORCA_WAREHOUSE"] = self.warehouse
        if extra:
            e.update(extra)
        return e

    def run(self, args, db=None, extra=None, timeout=120, path=None):
        """Exit code, stdout and stderr of one command."""
        try:
            p = subprocess.run([path or self.path] + args, env=self.env(db, extra),
                               capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Fail(f"`{' '.join(args)}` didn't exit within {timeout} s")
        return p.returncode, p.stdout, p.stderr

    def start(self, args, db, slow=False, extra=None):
        log = open(os.path.join(self.work, "bg.log"), "a")
        return subprocess.Popen([self.path] + args, env=self.env(db, extra, slow),
                                stdout=log, stderr=subprocess.STDOUT,
                                start_new_session=True)

    def hash(self):
        return self.describe.get("registry_hash", "")

    def name(self):
        return self.m["pipeline"]

    def subst(self, cmd):
        return [a.replace("{warehouse}", self.warehouse) for a in cmd]


def kill_group(p):
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    p.wait()


def wait_exit(p, seconds):
    try:
        return p.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        kill_group(p)
        raise Fail(f"the process didn't exit within {seconds} s")


def until(fn, seconds, what):
    end = time.time() + seconds
    while time.time() < end:
        got = fn()
        if got:
            return got
        time.sleep(0.05)
    raise Fail(f"waited {seconds} s for {what}")


# --- Expectations from the manifest ---


def expected_steps(m):
    """(step, partition, ord) of a whole run over the manifest's keys."""
    out = set()
    for i, s in enumerate(m["steps"]):
        if s["kind"] == "mapped":
            for k in m["keys"]:
                out.add((s["name"], k, i))
        else:
            out.add((s["name"], "", i))
    return out


def sensed(m):
    """Each dataset a step reads and no step writes, once, in step order."""
    written = {d for s in m["steps"] for d in s.get("writes", [])}
    out = []
    for s in m["steps"]:
        for d in s.get("reads", []):
            if d not in written and d not in out:
                out.append(d)
    return out


# --- Iceberg metadata, read as morca's own readers do ---


def table_dir(location):
    return location[len("file://"):] if location.startswith("file://") else location


def metadata(location):
    """The table's current metadata, or None if it has none."""
    meta = os.path.join(table_dir(location), "metadata")
    if not os.path.isdir(meta):
        return None
    hint = os.path.join(meta, "version-hint.text")
    name = None
    if os.path.exists(hint):
        v = open(hint).read().strip()
        for cand in (f"v{v}.metadata.json", f"{v}.metadata.json"):
            if os.path.exists(os.path.join(meta, cand)):
                name = cand
    if name is None:
        best = -1
        for f in os.listdir(meta):
            if not f.endswith(".metadata.json"):
                continue
            stem = f[: -len(".metadata.json")]
            n = stem[1:] if stem.startswith("v") else stem.split("-")[0]
            if n.isdigit() and int(n) > best:
                best, name = int(n), f
    if name is None:
        return None
    return json.load(open(os.path.join(meta, name)))


def snapshots(location):
    md = metadata(location)
    return {} if md is None else {s["snapshot-id"]: s for s in md.get("snapshots", [])}


def dataset_location(warehouse, dataset):
    ns, t = dataset.split(".", 1)
    return os.path.join(warehouse, ns, t)


# --- The checks ---


class Suite:
    def __init__(self, binary, report):
        self.b = binary
        self.r = report

    def check(self, *a, **k):
        return self.r.check(*a, **k)

    # Commands that need no store.

    def static(self):
        b, m = self.b, self.b.m

        def usage():
            code, _, _ = b.run(["no-such-command"])
            need(code == 2, f"exited {code}, not 2")

        self.check("usage.unknown", "subcommands",
                   "an unknown command is a usage error, exit 2", usage)

        got = {}

        def describe_exit():
            code, out, err = b.run(["describe"], timeout=300)
            need(code == 0, f"exited {code}: {err.strip()[-300:]}")
            got["out"] = out

        if not self.check("describe.exit", "describe",
                          "`describe` exits 0 with no database and no warehouse",
                          describe_exit):
            self.r.summary()
            raise SystemExit(1)

        def describe_json():
            text = got["out"].strip()
            need(text and "\n" not in text, "not one line")
            try:
                d = json.loads(text)
            except ValueError as e:
                raise Fail(f"not JSON: {e}")
            need(isinstance(d, dict), "not a JSON object")
            b.describe_text, b.describe = text, d

        if not self.check("describe.json", "describe",
                          "`describe` prints one JSON object on one line (any spacing)",
                          describe_json):
            self.r.summary()
            raise SystemExit(1)

        d = b.describe
        self.check("describe.fields", "describe-and-the-registry-hash",
                   "describe's fields have the types the scheduler reads",
                   lambda: describe_fields(d))
        self.check("describe.manifest", "describe-and-the-registry-hash",
                   "describe's DAG is the pipeline's: name, partitions, steps, "
                   "datasets", lambda: describe_manifest(d, m))

        def stable():
            code, out, _ = b.run(["describe"], timeout=300)
            need(code == 0, f"the second describe exited {code}")
            again = json.loads(out)
            need(again.get("registry_hash") == d.get("registry_hash"),
                 f"{again.get('registry_hash')} the second time, "
                 f"{d.get('registry_hash')} the first")
            if "registry_hash" in m:
                need(d.get("registry_hash") == m["registry_hash"],
                     f"{d.get('registry_hash')}, not the manifest's {m['registry_hash']}")

        self.check("describe.hash", "the-registry-hash",
                   "the same DAG reports the same registry hash", stable)

        def morca_version():
            need(isinstance(d.get("morca"), str) and d["morca"],
                 "no `morca` key: register would check nothing")
            if not b.morca:
                raise Skip("no morca binary to compare with")
            code, out, _ = subprocess_run([b.morca, "version"])
            want = out.split()[-1] if code == 0 and out.split() else ""
            need(d["morca"] == want, f"`morca` is {d['morca']}, the scheduler is {want}")

        self.check("describe.morca", "versions",
                   "describe's `morca` is the morca the binary targets", morca_version)

        def protocol():
            need("protocol" in d, "describe names no protocol version")
            p = d["protocol"]
            need(isinstance(p, int) and not isinstance(p, bool) and p >= 1,
                 f"`protocol` is {p!r}, not a version number")

        self.check("describe.protocol", "versions",
                   "describe says which version of the protocol it implements",
                   protocol)

        def no_store():
            code, _, _ = b.run(["resume", "1"])
            need(code == 2, f"exited {code}, not 2")

        self.check("resume.no_store", "resume-run---allow-new-code",
                   "`resume` with no store is a usage error, exit 2", no_store)

        def keys_not_keyed():
            if d.get("partitions", {}).get("kind") == "keyed":
                raise Skip("the pipeline is keyed")
            code, _, _ = b.run(["keys"])
            need(code == 2, f"exited {code}, not 2")

        self.check("keys.not_keyed", "keys",
                   "`keys` on a pipeline that isn't keyed is a usage error, exit 2",
                   keys_not_keyed)

        def keep_log():
            stage = os.path.join(b.work, "stage.log")
            loc = os.path.join(b.work, "kept", "driver.log")
            os.makedirs(os.path.dirname(loc), exist_ok=True)
            open(stage, "w").write("first start\n")
            code, out, _ = b.run(["keep-log", stage, loc, "1"])
            need(code == 0, f"exited {code}: {out.strip()[-200:]}")
            open(stage, "w").write("second start\n")
            code, out, _ = b.run(["keep-log", stage, loc, "2"])
            need(code == 0, f"the second exited {code}")
            got = open(loc).read()
            want = "--- start 1\nfirst start\n--- start 2\nsecond start\n"
            need(got == want, f"the location holds {got!r}, not {want!r}")

        self.check("keep-log.append", "keep-log-stage-location-start",
                   "`keep-log` appends `--- start <start>` and the stage file",
                   keep_log)

        def put_log():
            src = os.path.join(b.work, "put.log")
            loc = os.path.join(b.work, "put", "copy.log")
            os.makedirs(os.path.dirname(loc), exist_ok=True)
            open(loc, "w").write("older\n")
            open(src, "w").write("newer\n")
            code, _, _ = b.run(["put-log", src, loc])
            need(code == 0, f"exited {code}")
            need(open(loc).read() == "newer\n", "the location wasn't replaced")

        self.check("put-log", "put-log-local-location",
                   "`put-log` copies a file to a location, replacing it", put_log)

    # Sensing, with a warehouse set up.

    def sense(self):
        b, m = self.b, self.b.m
        if not m.get("sensor"):
            return

        def lines():
            code, out, err = b.run(["sense"])
            need(code == 0, f"exited {code}: {(out + err).strip()[-300:]}")
            want = sensed(m)
            got = [l.split() for l in out.splitlines() if l.strip()]
            need(all(len(f) == 4 for f in got), f"a line hasn't four fields: {out!r}")
            need([f[0] for f in got] == want, f"datasets {[f[0] for f in got]}, not {want}")
            for ds, snap, by, parts in got:
                md = metadata(dataset_location(b.warehouse, ds))
                cur = -1 if md is None else md.get("current-snapshot-id", -1)
                cur = -1 if cur is None else cur
                need(int(snap) == cur, f"{ds}: snapshot {snap}, the table's is {cur}")
                if cur < 0:
                    continue
                summ = snapshots(dataset_location(b.warehouse, ds))[cur].get("summary", {})
                need(by == ("orca" if "orca.run" in summ else "other"),
                     f"{ds}: `{by}` for a summary {'with' if 'orca.run' in summ else 'without'} orca.run")
                need(parts == (summ.get("orca.partitions") or "-"),
                     f"{ds}: partitions `{parts}`, the summary's are "
                     f"`{summ.get('orca.partitions') or '-'}`")

        self.check("sense.lines", "sense",
                   "`sense` prints `<dataset> <snapshot> <orca|other> <partitions|->` "
                   "for each sensed dataset", lines)

        def no_warehouse():
            code, _, _ = b.run(["sense"], extra={"MORCA_WAREHOUSE": ""})
            need(code == 3, f"exited {code}, not 3")

        self.check("sense.no_warehouse", "sense",
                   "`sense` with sensed datasets and no MORCA_WAREHOUSE exits 3",
                   no_warehouse)

    # Registration, over Postgres.

    def register(self, db):
        b = self.b
        if not b.morca:
            self.check("register", "a-runs-life", "", lambda: _skip("no morca binary"))
            return False

        def reg(path):
            p = subprocess.run([b.morca, "register", path], env=b.env(db),
                               capture_output=True, text=True, timeout=300)
            return p.returncode, (p.stdout + p.stderr).strip()

        def real():
            code, out = reg(b.path)
            need(code == 0, f"`morca register` exited {code}: {out[-300:]}")
            r = db.q("SELECT registry_hash, describe::text, binary_path FROM "
                     f"orca.pipelines WHERE name = {lit(b.name())}")
            need(r, f"no orca.pipelines row for {b.name()}")
            need(r[0][0] == b.hash(), f"registered {r[0][0]}, describe says {b.hash()}")
            need(json.loads(r[0][1]) == b.describe, "the stored describe isn't describe's")
            need(r[0][2] == b.path, f"binary_path {r[0][2]}, not {b.path}")

        ok = self.check("register", "a-runs-life",
                        "`morca register` stores describe's JSON as the registration",
                        real, where=db.where)

        def compact():
            wrap = os.path.join(b.work, b.name())
            with open(wrap, "w") as f:
                f.write("#!/bin/sh\n"
                        f'if [ "$*" = describe ]; then "{b.path}" describe | '
                        f"{sys.executable} -c 'import json,sys; print(json.dumps("
                        "json.loads(sys.stdin.read()), separators=(\",\", \":\")))'; "
                        "exit; fi\n"
                        f'exec "{b.path}" "$@"\n')
            os.chmod(wrap, 0o755)
            code, out = reg(wrap)
            if code == 0:
                reg(b.path)  # back to the binary itself
            need(code == 0, "the same describe, compact, was refused: "
                 f"{out.split(': {')[0][-200:]}")

        if ok:
            self.check("register.compact", "describe-and-the-registry-hash",
                       "the registration doesn't depend on describe's spacing",
                       compact, where=db.where)
        return ok

    # Runs.

    def runs(self, db):
        b, m, w = self.b, self.b.m, db.where
        name, hash, keys = b.name(), b.hash(), m["keys"]
        logs = os.path.join(b.work, f"logs-{w}")
        ctx = {}

        def resume(run, *more, slow=False, extra=None, timeout=300):
            return b.run(["resume", str(run)] + list(more), db, extra=extra,
                         timeout=timeout)

        # A whole run, then its rows.
        def succeeds():
            run = db.new_run(name, hash, keys)
            ctx["run"] = run
            code, out, err = resume(run, extra={"MORCA_LOGS": logs})
            r = db.run_row(run)
            need(r["status"] == "succeeded",
                 f"run {run} is {r['status']} ({r['error']}), exit {code}: "
                 f"{(out + err).strip()[-300:]}")
            need(code == 0, f"exited {code} for a run that succeeded")

        if not self.check("resume.succeeds", "a-runs-life",
                          "`resume <run>` of a run the scheduler started claims it, "
                          "runs every step and ends it `succeeded`, exit 0",
                          succeeds, where=w):
            return
        run = ctx["run"]

        def run_row():
            r = db.run_row(run)
            need(r["owner"] and r["owner"] != "scheduler",
                 f"owner `{r['owner']}`: the run wasn't claimed")
            need(not r["heartbeat"], "its heartbeat wasn't cleared")
            need(r["ended"], "no `ended`")
            need(r["version"], "no `version`")
            v = db.q("SELECT pipeline, registry_hash FROM orca.pipeline_versions "
                     f"WHERE id = {r['version']}")
            need(v and v[0] == (name, hash),
                 f"its version row is {v[0] if v else None}, not ({name}, {hash})")

        self.check("resume.run_row", "the-rows-a-binary-writes",
                   "the run row ends owned, with no heartbeat, `ended` and its version",
                   run_row, where=w)

        def steps():
            rows = db.q("SELECT step, partition, ord, status, output IS NOT NULL "
                        f"FROM orca.steps WHERE run = {run}")
            got = {(s, p, int(o)) for s, p, o, _, _ in rows}
            want = expected_steps(m)
            need(got == want and len(rows) == len(want),
                 f"steps {sorted(got)}, not {sorted(want)}")
            bad = [(s, p, st) for s, p, _, st, out in rows if st != "succeeded" or not _true(out)]
            need(not bad, f"not succeeded with an output: {bad}")

        self.check("resume.steps", "the-rows-a-binary-writes",
                   "one step row per mapped step and key, one per gather step "
                   "(partition ''), `ord` its index in describe, succeeded with an output",
                   steps, where=w)

        def attempts():
            owner = db.run_row(run)["owner"]
            rows = db.attempts(run)
            need(len(rows) == len(expected_steps(m)), f"{len(rows)} attempts")
            for _, s, p, n, st, host, h, err, _, ended in rows:
                where = f"{s} [{p}]"
                need(n == "1", f"{where} is attempt {n}")
                need(st == "succeeded", f"{where} is {st}")
                need(host == owner, f"{where} by {host}, the run's owner is {owner}")
                need(h == hash, f"{where} ran {h}, describe says {hash}")
                need(_true(ended), f"{where} has no `ended`")
            back = db.one("SELECT count(*) FROM orca.attempts a JOIN orca.steps s ON "
                          f"s.id = a.step WHERE s.run = {run} AND a.ended < a.started")
            need(back == "0", "an attempt ended before it started")

        self.check("resume.attempts", "the-rows-a-binary-writes",
                   "each step's one attempt is numbered 1, by the run's owner, "
                   "with describe's registry hash", attempts, where=w)

        def order():
            for i, s in enumerate(m["steps"]):
                if i == 0:
                    continue
                up = m["steps"][i - 1]["name"]
                join = "AND u.partition = d.partition" if (
                    s["kind"] == "mapped" and m["steps"][i - 1]["kind"] == "mapped") else ""
                n = db.one(
                    "SELECT count(*) FROM orca.attempts da JOIN orca.steps d ON "
                    "d.id = da.step, orca.attempts ua JOIN orca.steps u ON u.id = ua.step "
                    f"WHERE d.run = {run} AND u.run = {run} AND d.step = {lit(s['name'])} "
                    f"AND u.step = {lit(up)} {join} AND da.started < ua.ended")
                need(n == "0", f"{s['name']} started before {up} ended ({n} times)")

        self.check("resume.order", "executing",
                   "each step runs after the step it follows has ended", order, where=w)

        def logs_check():
            for _, s, p, n, _, _, _, _, log, _ in db.attempts(run):
                need(log, f"{s} [{p}] attempt {n} has no log")
                need(os.path.exists(table_dir(log)), f"{s} [{p}]'s log {log} isn't there")

        self.check("resume.logs", "logs",
                   "with MORCA_LOGS, each attempt records a log that's there",
                   logs_check, where=w)

        if m.get("warehouse"):
            self.tables(db, run)

        def done():
            before = db.attempts(run)
            r0 = db.run_row(run)
            code, _, _ = resume(run)
            need(code == 3, f"exited {code}, not 3")
            need(db.run_row(run) == r0 and db.attempts(run) == before,
                 "the run's rows changed")

        self.check("claim.done", "claiming",
                   "a run that succeeded can't be claimed: exit 3, nothing written",
                   done, where=w)

        def statuses():
            for st, owner in (("queued", None), ("failed", "gone:1"), ("deferred", "gone:1")):
                r = db.new_run(name, hash, keys, status=st, owner=owner)
                code, out, _ = resume(r)
                got = db.run_row(r)["status"]
                need(got == "succeeded", f"a {st} run is {got} after resume, exit {code}: "
                     f"{out.strip()[-200:]}")

        self.check("claim.statuses", "claiming",
                   "a `queued`, `failed` or `deferred` run is claimed and run",
                   statuses, where=w)

        def live():
            r = db.new_run(name, hash, keys, owner="alive:1", heartbeat="{NOW}")
            code, _, _ = resume(r)
            need(code == 3, f"exited {code}, not 3")
            row = db.run_row(r)
            need(row["owner"] == "alive:1" and row["status"] == "running",
                 f"the run is now {row['status']}, owned by {row['owner']}")
            need(not db.attempts(r), "it wrote attempts")

        self.check("claim.live", "claiming",
                   "a run another process holds with a fresh heartbeat is refused, "
                   "exit 3, nothing written", live, where=w)

        def stale():
            r = db.new_run(name, hash, keys, owner="gone:1", heartbeat="{AGO:3600}")
            first = m["steps"][0]
            part = keys[0] if first["kind"] == "mapped" else ""
            old = db.fake_attempt(r, first["name"], part, 0, "gone:1", hash)
            code, out, _ = resume(r)
            row = db.run_row(r)
            need(row["status"] == "succeeded",
                 f"the stale run is {row['status']}, exit {code}: {out.strip()[-200:]}")
            a = [x for x in db.attempts(r) if x[1] == first["name"] and x[2] == part]
            need(a[0][0] == old and a[0][4] == "failed",
                 f"the gone process's attempt is {a[0][4]}, not failed")
            need(a[0][7], "the interrupted attempt has no error")
            need(_true(a[0][9]), "the interrupted attempt has no `ended`")
            need(len(a) == 2 and a[1][3] == "2" and a[1][4] == "succeeded",
                 f"the step's attempts after it: {[(x[3], x[4]) for x in a[1:]]}, "
                 "not attempt 2 succeeded")

        self.check("claim.stale", "interrupting",
                   "a run whose heartbeat is stale is claimed; what its old owner "
                   "left running fails, and the step runs again as attempt 2",
                   stale, where=w)

        def other_pipeline():
            other = "conformance-other"
            db.register_row(other, "0x0", "{}")
            r = db.new_run(other, hash, keys)
            code, _, _ = resume(r)
            need(code == 3, f"exited {code}, not 3")
            row = db.run_row(r)
            need(row["owner"] == "scheduler" and not db.attempts(r),
                 "it claimed or wrote to the run")

        self.check("resume.other_pipeline", "resume-run---allow-new-code",
                   "`resume` of another pipeline's run exits 3 and writes nothing",
                   other_pipeline, where=w)

        def other_code():
            r = db.new_run(name, "0xdead", keys)
            code, _, _ = resume(r)
            need(code == 3, f"exited {code}, not 3")
            row = db.run_row(r)
            need(row["owner"] == "scheduler" and not db.attempts(r),
                 "it claimed or wrote to the run")
            code, out, _ = resume(r, "--allow-new-code")
            row = db.run_row(r)
            need(row["status"] == "succeeded",
                 f"with --allow-new-code the run is {row['status']}, exit {code}")
            bad = [x for x in db.attempts(r) if x[6] != hash]
            need(not bad, f"attempts with hash {bad[0][6]}, not the binary's" if bad else "")

        self.check("resume.other_code", "the-registry-hash",
                   "a run of other code is refused (exit 3) unless --allow-new-code, "
                   "and its attempts carry the binary's hash", other_code, where=w)

        def crash():
            r = db.new_run(name, hash, keys, owner="driver:1", heartbeat="{NOW}")
            first = m["steps"][0]
            part = keys[0] if first["kind"] == "mapped" else ""
            db.fake_attempt(r, first["name"], part, 0, "driver:1", hash)
            stage = os.path.join(b.work, "crash.log")
            open(stage, "w").write(CRASH)
            loc = os.path.join(b.work, f"crash-{w}", "driver.log")
            os.makedirs(os.path.dirname(loc), exist_ok=True)
            code, out, _ = b.run(["keep-log", stage, loc, "1"], db,
                                 extra={"MORCA_RUN": str(r)})
            need(code == 0, f"exited {code}: {out.strip()[-200:]}")
            a = db.attempts(r)[0]
            need(a[4] == "failed" and a[7].startswith("crashed"),
                 f"the running attempt is {a[4]} ({a[7]}), not failed with the crash")

        self.check("keep-log.crash", "keep-log-stage-location-start",
                   "`keep-log` with MORCA_RUN fails the run's running attempts "
                   "with the crash its output holds", crash, where=w)

        self.slow_runs(db)

        def domain():
            for t in ("runs", "steps", "attempts"):
                for (s,) in db.q(f"SELECT DISTINCT status FROM orca.{t}"):
                    need(s in STATUSES, f"orca.{t} has status `{s}`")

        self.check("statuses", "statuses-and-identity",
                   "a binary writes only the protocol's statuses", domain, where=w)

    # Runs interrupted while a step runs.

    def slow_runs(self, db):
        b, m, w = self.b, self.b.m, db.where
        name, hash, keys = b.name(), b.hash(), m["keys"]
        if not m.get("slow_env"):
            for cid, section in (("kill.resume", "interrupting"),
                                 ("cancel.between", "cancelling"),
                                 ("cancel.due", "timeouts-and-a-cancel-that-ran-out"),
                                 ("lost.stops", "ownership-at-every-step")):
                self.check(cid, section, "", lambda: _skip("no slow_env in the manifest"),
                           where=w)
            return

        def counts(run):
            return dict(db.q(
                "SELECT a.status, count(*) FROM orca.attempts a JOIN orca.steps s ON "
                f"s.id = a.step WHERE s.run = {run} GROUP BY a.status"))

        def first_running(run):
            return until(lambda: counts(run).get("running"), 60, "an attempt to start")

        def kill_resume():
            run = db.new_run(name, hash, keys)
            p = b.start(["resume", str(run)], db, slow=True)
            ages, beats = [], set()

            def ready():
                hb = db.q("SELECT heartbeat, {AGE:heartbeat} FROM orca.runs "
                          f"WHERE id = {run}")[0]
                if hb[0] is not None:
                    beats.add(hb[0])
                    ages.append(float(hb[1]))
                c = counts(run)
                return c.get("succeeded") and c.get("running")

            try:
                until(ready, 90, "one attempt to succeed and another to run")
            finally:
                kill_group(p)
            need(len(beats) >= 3, f"the heartbeat moved {len(beats)} times in a step "
                 f"longer than the stale limit")
            need(max(ages) < STALE, f"the heartbeat got {max(ages):.1f} s old, past "
                 f"the stale limit ({STALE:.0f} s) while a step ran")
            row = db.run_row(run)
            need(row["status"] == "running" and row["owner"] != "scheduler",
                 f"the killed run is {row['status']} by {row['owner']}")
            before = db.attempts(run)
            done = {(x[1], x[2]) for x in before if x[4] == "succeeded"}
            left = {x[0] for x in before if x[4] == "running"}
            time.sleep(STALE + 0.3)
            code, out, _ = b.run(["resume", str(run)], db, timeout=300)
            row = db.run_row(run)
            need(row["status"] == "succeeded",
                 f"the resumed run is {row['status']}, exit {code}: {out.strip()[-200:]}")
            after = db.attempts(run)
            for s, p_ in done:
                n = [x for x in after if (x[1], x[2]) == (s, p_)]
                need(len(n) == 1, f"{s} [{p_}] had succeeded and ran again")
            for x in after:
                if x[0] in left:
                    need(x[4] == "failed" and x[7], f"{x[1]} [{x[2]}], running when "
                         f"killed, is {x[4]} ({x[7]}), not failed")
                    again = [y for y in after if (y[1], y[2]) == (x[1], x[2])
                             and int(y[3]) > int(x[3]) and y[4] == "succeeded"]
                    need(again, f"{x[1]} [{x[2]}] wasn't run again")
            need(not [x for x in after if x[4] == "running"], "an attempt was left running")

        self.check("kill.resume", "interrupting",
                   "a run killed mid-step keeps its heartbeat fresh until then; "
                   "`resume` interrupts what was running, skips what succeeded and "
                   "runs the rest", kill_resume, where=w)

        def cancel_between():
            run = db.new_run(name, hash, keys)
            p = b.start(["resume", str(run)], db, slow=True)
            try:
                first_running(run)
                at = "cancel_at = now() + interval '60 seconds', " if db.pg else ""
                db.q(f"UPDATE orca.runs SET {at}cancel_requested = {{T}} WHERE id = {run}")
                n = sum(int(v) for v in counts(run).values())
                code = wait_exit(p, 60)
            finally:
                kill_group(p)
            row = db.run_row(run)
            need(row["status"] == "cancelled", f"the run is {row['status']}, not cancelled")
            need(code == 1, f"exited {code}, not 1")
            need(not row["heartbeat"] and row["ended"], "no `ended`, or a heartbeat left")
            c = counts(run)
            need(sum(int(v) for v in c.values()) == n,
                 "an attempt started after the cancel")
            need(not c.get("running"), "an attempt was left running")

        self.check("cancel.between", "cancelling",
                   "a cancel asked for during an attempt ends the run `cancelled` "
                   "before the next one starts, exit 1", cancel_between, where=w)

        def cancel_due():
            if not db.pg:
                raise Skip("over SQLite the heartbeat handles no cancels")
            run = db.new_run(name, hash, keys)
            p = b.start(["resume", str(run)], db, slow=True)
            try:
                first_running(run)
                db.q("UPDATE orca.runs SET cancel_requested = true, cancel_at = now() "
                     f"- interval '1 second' WHERE id = {run}")
                code = wait_exit(p, 2 * STALE + 2)
            finally:
                kill_group(p)
            row = db.run_row(run)
            need(row["status"] == "cancelled", f"the run is {row['status']}, not cancelled")
            need(code == 1, f"exited {code}, not 1")
            need(not row["heartbeat"], "its heartbeat wasn't cleared")
            c = counts(run)
            need(not c.get("running") and not c.get("succeeded"),
                 f"attempts {c}: the one running wasn't failed")
            need(db.one("SELECT count(*) FROM orca.audit WHERE action = 'stop' AND "
                        f"run = {run}") == "1", "no orca.audit row for the stop")

        self.check("cancel.due", "timeouts-and-a-cancel-that-ran-out",
                   "a cancel whose cancel_at has passed stops the process from its "
                   "heartbeat: the running attempt fails and the run is `cancelled`",
                   cancel_due, where=w)

        def lost():
            run = db.new_run(name, hash, keys)
            p = b.start(["resume", str(run)], db, slow=True)
            try:
                first_running(run)
                db.q(f"UPDATE orca.runs SET owner = 'thief:1', heartbeat = {{NOW}} "
                     f"WHERE id = {run}")
                n = sum(int(v) for v in counts(run).values())
                code = wait_exit(p, 60)
            finally:
                kill_group(p)
            need(code != 0, "exited 0")
            row = db.run_row(run)
            need(row["owner"] == "thief:1" and row["status"] == "running",
                 f"the run is {row['status']} by {row['owner']}: the binary wrote "
                 "to a run it had lost")
            c = counts(run)
            need(sum(int(v) for v in c.values()) == n,
                 "it started an attempt after losing the run")
            need(c.get("running") == "1", f"attempts {c}: the one it was running "
                 "was finished after the run was lost")

        self.check("lost.stops", "ownership-at-every-step",
                   "a binary whose run another process took stops without writing more",
                   lost, where=w)

    # Tables: what a whole run committed and read, then a crash after a commit.

    def tables(self, db, run):
        b, m, w = self.b, self.b.m, db.where
        by_step = {s["name"]: s for s in m["steps"]}
        keys = m["keys"]
        tok = "token::text" if db.pg else "token"
        token = db.one(f"SELECT coalesce({tok}, '') FROM orca.runs WHERE id = {run}")

        def rows(kind, r):
            return db.q(
                f"SELECT a.id, s.step, s.partition, x.table_name, x.snapshot_id, "
                f"coalesce(x.dataset, '') FROM orca.{kind} x JOIN orca.attempts a ON "
                f"a.id = x.attempt JOIN orca.steps s ON s.id = a.step WHERE s.run = {r} "
                "ORDER BY a.id")

        def commits():
            got = rows("commits", run)
            seen = {}
            for aid, s, p, loc, snap, ds in got:
                need(ds in by_step[s].get("writes", []),
                     f"{s} committed to {ds or loc}, which describe doesn't list")
                summ = snapshots(loc).get(int(snap), {}).get("summary")
                need(summ is not None, f"{s} [{p}]: snapshot {snap} isn't in {loc}")
                i = seen.get((aid, loc), 0)
                seen[(aid, loc)] = i + 1
                want = {"orca.pipeline": b.name(), "orca.run": run, "orca.step": s,
                        "orca.partition": p, "orca.commit": str(i),
                        "orca.partitions": p if p else ",".join(keys)}
                if token:
                    want["orca.run-token"] = token
                bad = {k: summ.get(k) for k, v in want.items() if summ.get(k) != v}
                need(not bad, f"{s} [{p}]'s commit {snap}: {bad}, not "
                     f"{ {k: want[k] for k in bad} }")
            for s in m["steps"]:
                for ds in s.get("writes", []):
                    need(any(x[1] == s["name"] and x[5] == ds for x in got),
                         f"{s['name']} recorded no commit to {ds}")

        self.check("tables.commits", "summary-keys",
                   "each commit is recorded with its dataset and carries the orca.* "
                   "summary keys", commits, where=w)

        def reads():
            got = rows("reads", run)
            for aid, s, p, loc, snap, ds in got:
                need(ds in by_step[s].get("reads", []),
                     f"{s} read {ds or loc}, which describe doesn't list")
                need(int(snap) == -1 or int(snap) in snapshots(loc),
                     f"{s} [{p}] read snapshot {snap}, which {loc} hasn't")
            for s in m["steps"]:
                for ds in s.get("reads", []):
                    need(any(x[1] == s["name"] and x[5] == ds for x in got),
                         f"{s['name']} recorded no read of {ds}")

        self.check("tables.reads", "recording-reads-and-commits",
                   "each read is recorded with its dataset and the snapshot it scanned",
                   reads, where=w)

        # A crash after a step committed: its attempt left running, then a
        # new snapshot of what it reads, then a resume.
        writer = next((s for s in m["steps"] if s.get("writes")), None)
        ctx = {}

        def crashed_after_commit():
            if writer is None:
                raise Skip("no step writes a table")
            part = keys[0] if writer["kind"] == "mapped" else ""
            r = db.new_run(b.name(), b.hash(), keys)
            code, out, _ = b.run(["resume", str(r)], db, timeout=300)
            need(code == 0, f"the run exited {code}: {out.strip()[-200:]}")
            a1 = [x for x in db.attempts(r) if (x[1], x[2]) == (writer["name"], part)]
            need(len(a1) == 1, f"{len(a1)} attempts of {writer['name']} [{part}]")
            aid = a1[0][0]
            db.q(f"UPDATE orca.attempts SET status = 'running', ended = NULL WHERE id = {aid}")
            db.q(f"UPDATE orca.steps SET status = 'running' WHERE run = {r} AND "
                 f"step = {lit(writer['name'])} AND partition = {lit(part)}")
            db.q("UPDATE orca.runs SET status = 'running', owner = 'gone:1', "
                 f"heartbeat = {{AGO:3600}}, ended = NULL WHERE id = {r}")
            snaps = {loc: len(snapshots(loc)) for _, _, _, loc, _, _ in rows("commits", r)}
            if m.get("commit_input"):
                p = subprocess.run(b.subst(m["commit_input"]), env=b.env(),
                                   capture_output=True, text=True)
                need(p.returncode == 0, f"commit_input exited {p.returncode}: {p.stderr}")
            code, out, _ = b.run(["resume", str(r)], db, timeout=300)
            row = db.run_row(r)
            need(row["status"] == "succeeded",
                 f"the resumed run is {row['status']}, exit {code}: {out.strip()[-200:]}")
            a = [x for x in db.attempts(r) if (x[1], x[2]) == (writer["name"], part)]
            need(len(a) == 2 and a[1][4] == "succeeded",
                 f"{writer['name']} [{part}] wasn't run again as attempt 2")
            ctx.update(run=r, a1=aid, a2=a[1][0], snaps=snaps)

        self.check("tables.crash_resume", "finding-an-earlier-attempts-commit",
                   "a step that committed and then crashed runs again on resume",
                   crashed_after_commit, where=w)

        def found():
            if "run" not in ctx:
                raise Skip("no crashed run")
            got = rows("commits", ctx["run"])
            c1 = sorted((x[3], x[4]) for x in got if x[0] == ctx["a1"])
            c2 = sorted((x[3], x[4]) for x in got if x[0] == ctx["a2"])
            need(c1 == c2, f"attempt 2 recorded commits {c2}, attempt 1 made {c1}")
            for loc, n in ctx["snaps"].items():
                need(len(snapshots(loc)) == n, f"{loc} has a new snapshot: the "
                     "retry wrote again what attempt 1 had committed")

        self.check("tables.retry_finds_commit", "finding-an-earlier-attempts-commit",
                   "the retry finds the commit its crashed attempt made, records it "
                   "and doesn't write again", found, where=w)

        def pinned():
            if "run" not in ctx:
                raise Skip("no crashed run")
            if not writer.get("reads"):
                raise Skip(f"{writer['name']} reads no table")
            if not m.get("commit_input"):
                raise Skip("no commit_input to move what it reads")
            got = rows("reads", ctx["run"])
            r1 = sorted((x[3], x[4]) for x in got if x[0] == ctx["a1"])
            r2 = sorted((x[3], x[4]) for x in got if x[0] == ctx["a2"])
            need(r1 and r1 == r2, f"attempt 2 read {r2}, attempt 1 read {r1}")
            for loc, snap in r1:
                md = metadata(loc)
                need(md and md.get("current-snapshot-id") != int(snap),
                     f"{loc} has no newer snapshot, so this proves nothing")

        self.check("tables.pinned", "pinned-reads",
                   "a later attempt reads the snapshots the first attempt read, not "
                   "the newer ones", pinned, where=w)


def _skip(why):
    raise Skip(why)


def subprocess_run(args):
    p = subprocess.run(args, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def describe_fields(d):
    need(isinstance(d.get("pipeline"), str) and d["pipeline"], "no `pipeline`")
    need(isinstance(d.get("registry_hash"), str) and d["registry_hash"],
         "`registry_hash` isn't a non-empty string")
    steps = d.get("steps")
    need(isinstance(steps, list) and steps, "no `steps`")
    kinds = {"monthly", "weekly", "daily", "hourly", "keyed"}
    parts = d.get("partitions", {})
    need(isinstance(parts, dict) and parts.get("kind", "monthly") in kinds,
         f"`partitions` is {parts}")
    for k, t in (("max_runs", int), ("run_retries", int), ("keys_per_run", int),
                 ("workers", int), ("sensor", bool), ("tasks", list),
                 ("source", dict), ("protocol", int), ("morca", str)):
        if k in d:
            need(isinstance(d[k], t) and not (t is int and isinstance(d[k], bool)),
                 f"`{k}` is {d[k]!r}")
    if d.get("schedule") is not None:
        need(isinstance(d["schedule"].get("cron"), str), "`schedule` has no `cron`")
    names = []
    for s in steps:
        need(isinstance(s.get("name"), str) and s["name"], f"a step without a name: {s}")
        need(s.get("kind") in ("mapped", "gather"), f"{s['name']}: kind {s.get('kind')}")
        after = s.get("after")
        need(after is None if not names else after in names,
             f"{s['name']}: after {after!r}")
        for k in ("reads", "writes"):
            ds = s.get(k, [])
            need(isinstance(ds, list) and all(isinstance(x, str) and "." in x for x in ds),
                 f"{s['name']}: `{k}` isn't a list of `ns.table` names")
        names.append(s["name"])


def describe_manifest(d, m):
    need(d.get("pipeline") == m["pipeline"], f"pipeline {d.get('pipeline')}")
    kind = d.get("partitions", {}).get("kind", "monthly")
    need(kind == m.get("partitions", "monthly"), f"partitions are {kind}")
    need(bool(d.get("sensor", False)) == bool(m.get("sensor", False)),
         f"sensor is {d.get('sensor')}")
    got = [(s["name"], s["kind"], sorted(s.get("reads", [])), sorted(s.get("writes", [])))
           for s in d["steps"]]
    want = [(s["name"], s["kind"], sorted(s.get("reads", [])), sorted(s.get("writes", [])))
            for s in m["steps"]]
    need(got == want, f"steps {got}, not {want}")


# --- Main ---


def setup_warehouse(b, where):
    if not b.m.get("warehouse"):
        return
    b.warehouse = os.path.join(b.work, f"wh-{where}")
    shutil.rmtree(b.warehouse, ignore_errors=True)
    os.makedirs(b.warehouse)
    for cmd in b.m.get("setup", []):
        p = subprocess.run(b.subst(cmd), env=b.env(), capture_output=True, text=True)
        if p.returncode != 0:
            raise SystemExit(f"conformance: setup {cmd} exited {p.returncode}: {p.stderr}")


def ensure_schema(b, db, report=None):
    """Registers the pipeline: with `morca register` over Postgres (a check),
    by the suite over SQLite, where the binary makes the file's schema
    (Migrations) at its first `resume`."""
    if db.pg:
        if report is not None:
            return Suite(b, report).register(db)
        p = subprocess.run([b.morca, "register", b.path], env=b.env(db),
                           capture_output=True, text=True)
        if p.returncode != 0:
            raise SystemExit(f"conformance: morca register: {p.stdout}{p.stderr}")
        return True
    if not db.has_schema():
        b.run(["resume", "0"], db)
    if not db.has_schema():
        raise SystemExit(f"conformance: `resume` made no schema in {db.path}")
    db.register_row(b.name(), b.hash(), b.describe_text)
    return True


def default_morca():
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "morca")
    return os.path.normpath(p) if os.path.exists(p) else ""


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "new-run":
        return new_run_main(sys.argv[2:])
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("binary")
    ap.add_argument("manifest")
    ap.add_argument("--morca", default=default_morca(),
                    help="the morca binary that registers over Postgres (build/morca)")
    ap.add_argument("--store", choices=["all", "sqlite", "pg"], default="all")
    a = ap.parse_args()
    m = json.load(open(a.manifest))
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build",
                        "conformance")
    work = os.path.join(os.path.normpath(root), f"{m['pipeline']}-{os.getpid()}")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    b = Binary(a.binary, m, a.morca, work)
    report = Report()
    print(f"conformance: {b.path} as {a.manifest}", flush=True)
    suite = Suite(b, report)
    suite.static()

    stores = []
    if a.store in ("all", "sqlite"):
        stores.append(Db("sqlite://" + os.path.join(work, "runs.db")))
    url = os.environ.get("MORCA_DATABASE_URL", "")
    if a.store in ("all", "pg"):
        if url and not url.startswith("sqlite:"):
            stores.append(Db(url))
        else:
            print("skip  pg  (no MORCA_DATABASE_URL for Postgres: run it as "
                  "`pixi run conformance`)", flush=True)
            report.counts["skip"] += 1
    for i, db in enumerate(stores):
        setup_warehouse(b, db.where)
        if i == 0:
            suite.sense()
        if not ensure_schema(b, db, report):
            continue
        suite.runs(db)
    ok = report.summary()
    if ok:
        shutil.rmtree(work, ignore_errors=True)
    else:
        print(f"conformance: the binary's output and files are in {work}")
    return 0 if ok else 1


def new_run_main(args):
    ap = argparse.ArgumentParser(prog="conformance.py new-run")
    ap.add_argument("binary")
    ap.add_argument("keys")
    ap.add_argument("--morca", default=default_morca())
    ap.add_argument("--hash", default="")
    a = ap.parse_args(args)
    db = Db(os.environ["MORCA_DATABASE_URL"])
    b = Binary(a.binary, {"pipeline": "", "env": {}}, a.morca, ".")
    for k in ("MORCA_STALE_SECONDS",):
        b.m["env"][k] = os.environ.get(k, str(int(STALE)))
    code, out, err = b.run(["describe"], timeout=300)
    if code != 0:
        raise SystemExit(f"conformance: describe exited {code}: {err}")
    b.describe_text, b.describe = out.strip(), json.loads(out)
    b.m["pipeline"] = b.describe["pipeline"]
    if not db.has_schema() or db.registered(b.name()) != b.hash():
        ensure_schema(b, db)
    print(db.new_run(b.name(), a.hash or b.hash(), a.keys.split(",")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
