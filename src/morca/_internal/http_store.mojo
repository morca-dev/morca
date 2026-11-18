"""`HttpStore`: a run's state over `morca ui`'s API, for a run on a remote
worker (`morca worker`, `morca._internal.worker`), which holds no database credentials.

A pipeline binary given `MORCA_STATE_URL` (the UI, `https://...`, or `http`
to this machine only) and `MORCA_STATE_TOKEN` (a worker token,
`orca.workers`) in place of `MORCA_DATABASE_URL` records its run through
this store: each `RunStore` call is a `POST` of JSON to
`<MORCA_STATE_URL>/api/worker/store/<call>` with `Authorization: Bearer
<token>`, which the UI answers by making the same call on `morca._internal.state.PgStore`
(`orca.workers.store_call`), so what is recorded, and every check made on
the way (the run still this process's, not cancelled, its heartbeat fresh
enough to commit), is the same code as for a run that writes to Postgres
itself. Encoded inputs and outputs travel as hex.

**Retries.** A call that can't reach the UI, or that it answers with a 5xx,
is retried as `PgStore` retries Postgres (`morca._internal.store.Backoff`, for
`MORCA_DB_RETRY_SECONDS`); one refused (401 or 403: the token was revoked,
or the run is another worker's now; 409: the run was lost or cancelled) is
final, and the run stops. A fence (`Store.fence`) that can't be made within
half the stale limit refuses the commit, as over Postgres.

**The heartbeat** is a `POST .../beat` from a thread every beat, which the UI
answers with why the run must stop now, if the watchdog says so
(`morca._internal.state.beat_run`); the process then exits, as over Postgres. The
answer also says whether the run is outdated (`morca.outdated`). With
`MORCA_WORKER_PID` set, the beat also checks that the worker that started
this process is still its parent: if it isn't (the worker was killed), the
process exits rather than go on beating, so the server sees the run's
heartbeat go stale and requeues it.

Only `resume`, `status <run>` and `keep-log` work over this store: a
worker's run resumes the run it was given, so `run`, which creates one,
and `status` without a run need the database.
"""

from std.ffi import external_call
from std.os import getenv

from json import Value, loads
from objectstore.http import Header, HttpClient, Response

from morca._internal.heartbeat import Beater, Heartbeat
from morca._internal.json import quote
from morca._internal.handover import set_outdated
from morca._internal.store import (
    FINAL,
    Backoff,
    RunResult,
    RunStore,
    StepRun,
    SUCCEEDED,
    TableSnapshot,
)
from morca._internal.db.run_rows import RunInfo, StepInfo, Usage

comptime STORE_PATH = "/api/worker/store/"
"""Where a store call goes on the UI: this and the call's name."""


# ── encoding ─────────────────────────────────────────────────────────────────


def hex_of(b: Span[UInt8, _]) -> String:
    """`b` in lower-case hex, as encoded inputs and outputs travel."""
    comptime digits = "0123456789abcdef"
    var out = String(capacity_bytes=2 * len(b))
    for c in b:
        out.write(digits[byte=Int(c >> 4)], digits[byte=Int(c & 15)])
    return out^


def _nibble(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + 10
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return c - UInt8(ord("A")) + 10
    raise Error("not hex")


def bytes_of_hex(s: String) raises -> List[UInt8]:
    """The bytes `hex_of` gave `s`; raises for anything else."""
    var b = s.as_bytes()
    if len(b) % 2 != 0:
        raise Error("morca: an odd number of hex digits")
    var out = List[UInt8](capacity=len(b) // 2)
    for i in range(0, len(b), 2):
        try:
            out.append((_nibble(b[i]) << 4) | _nibble(b[i + 1]))
        except:
            raise Error("morca: not hex: ", s)
    return out^


struct Body(Movable):
    """A JSON object, written a field at a time: what a call sends."""

    var out: String

    def __init__(out self):
        self.out = String("{")

    def _key(mut self, k: StringSlice):
        if self.out.byte_length() > 1:
            self.out.write(", ")
        self.out.write(quote(k), ": ")

    def text(var self, k: StringSlice, v: StringSlice) -> Self:
        self._key(k)
        self.out.write(quote(v))
        return self^

    def int(var self, k: StringSlice, v: Int64) -> Self:
        self._key(k)
        self.out.write(v)
        return self^

    def float(var self, k: StringSlice, v: Float64) -> Self:
        self._key(k)
        self.out.write(v)
        return self^

    def bool(var self, k: StringSlice, v: Bool) -> Self:
        self._key(k)
        self.out.write("true" if v else "false")
        return self^

    def bytes(var self, k: StringSlice, v: Span[UInt8, _]) -> Self:
        self._key(k)
        self.out.write('"', hex_of(v), '"')
        return self^

    def raw(var self, k: StringSlice, json: StringSlice) -> Self:
        """`json`, already JSON, as the value."""
        self._key(k)
        self.out.write(json)
        return self^

    def finish(deinit self) -> String:
        self.out.write("}")
        return self.out^


def _text(v: Value, key: String) raises -> String:
    """`v[key]` as a string; empty for null or missing."""
    if key not in v:
        return ""
    var x = v[key]
    if x.is_null():
        return ""
    return x.string_value()


def _int(v: Value, key: String) raises -> Int64:
    if key not in v:
        raise Error("morca: the answer has no ", key)
    return v[key].int_value()


def run_info_json(r: RunInfo) -> String:
    """A `RunInfo` as the UI answers it."""
    return (
        Body()
        .int("id", Int64(r.id))
        .text("pipeline", r.pipeline)
        .text("registry_hash", r.registry_hash)
        .text("partitions", r.partitions)
        .text("status", r.status)
        .text("owner", r.owner)
        .text("error", r.error)
        .finish()
    )


def run_info_of(v: Value) raises -> RunInfo:
    return RunInfo(
        Int(_int(v, "id")),
        _text(v, "pipeline"),
        _text(v, "registry_hash"),
        _text(v, "partitions"),
        _text(v, "status"),
        _text(v, "owner"),
        _text(v, "error"),
    )


def steps_json(steps: List[StepInfo]) -> String:
    var out = String("[")
    for i in range(len(steps)):
        ref s = steps[i]
        out.write(", " if i else "")
        out.write(
            Body()
            .text("step", s.step)
            .text("partition", s.partition)
            .text("status", s.status)
            .int("attempts", Int64(s.attempts))
            .text("error", s.error)
            .text("log", s.log)
            .int("peak_rss_bytes", Int64(s.usage.peak_rss_bytes))
            .float("cpu_seconds", s.usage.cpu_seconds)
            .float("peak_cpus", s.usage.peak_cpus)
            .finish()
        )
    out.write("]")
    return out^


def steps_of(v: Value) raises -> List[StepInfo]:
    var out = List[StepInfo]()
    for s in v.array_items():
        out.append(
            StepInfo(
                _text(s, "step"),
                _text(s, "partition"),
                _text(s, "status"),
                Int(_int(s, "attempts")),
                _text(s, "error"),
                _text(s, "log"),
                _usage_of(s),
            )
        )
    return out^


def _float_or(v: Value, key: String, default: Float64) raises -> Float64:
    if key not in v:
        return default
    var x = v[key]
    return Float64(x.int_value()) if x.is_int() else x.float_value()


def _usage_of(v: Value) raises -> Usage:
    """A step's usage; -1 for each field missing (a UI older than this)."""
    return Usage(
        Int(_float_or(v, "peak_rss_bytes", -1)),
        _float_or(v, "cpu_seconds", -1),
        _float_or(v, "peak_cpus", -1),
    )


def prior_json(res: RunResult) -> String:
    """A run's succeeded steps and their outputs, for resuming it."""
    var out = String("[")
    for i in range(len(res.steps)):
        ref s = res.steps[i]
        out.write(", " if i else "")
        out.write(
            Body()
            .text("step", s.step)
            .text("partition", s.partition)
            .bytes("output", Span(s.output))
            .finish()
        )
    out.write("]")
    return out^


def prior_of(v: Value) raises -> RunResult:
    var res = RunResult()
    for s in v.array_items():
        res.steps.append(
            StepRun(
                _text(s, "step"),
                _text(s, "partition"),
                SUCCEEDED,
                bytes_of_hex(_text(s, "output")),
                "",
            )
        )
    return res^


def pins_json(pins: Dict[String, Int64]) -> String:
    var out = String("[")
    var first = True
    for e in pins.items():
        out.write("" if first else ", ")
        first = False
        out.write(Body().text("table", e.key).int("snapshot", e.value).finish())
    out.write("]")
    return out^


def pins_of(v: Value) raises -> Dict[String, Int64]:
    var out = Dict[String, Int64]()
    for p in v.array_items():
        out[_text(p, "table")] = _int(p, "snapshot")
    return out^


def refusal(text: String) -> String:
    """The `error` of an answer's JSON, or empty."""
    try:
        var v = loads(text)
        if v.is_object() and String("error") in v:
            return v["error"].string_value()
    except:
        pass
    return ""


def check_state_url(url: String) raises -> String:
    """`url` without a trailing `/` if it's `https`, or `http` to this
    machine, where nothing is on the wire; raises otherwise, since the
    token would cross a network in the clear."""
    var u = String(url.strip().rstrip("/"))
    if u.startswith("https://"):
        return u^
    for local in [
        "http://127.0.0.1:",
        "http://localhost:",
        "http://[::1]:",
    ]:
        if u.startswith(local) or u == local.rstrip(":"):
            return u^
    raise Error(
        "morca: MORCA_STATE_URL is https://..., or http to this machine only,",
        " not ",
        url,
    )


# ── calls ────────────────────────────────────────────────────────────────────


struct StateApi(Copyable, Movable):
    """The UI's store calls, as a worker token."""

    var url: String
    var token: String
    var http: HttpClient

    def __init__(out self, url: String, token: String) raises:
        self.url = check_state_url(url)
        if not token:
            raise Error("morca: MORCA_STATE_URL needs MORCA_STATE_TOKEN")
        self.token = token
        self.http = HttpClient()
        # Retried here, as a whole, and never redirected: a redirect could
        # take the token somewhere else.
        self.http.follow_redirects = False
        self.http.verify_tls = True
        self.http.retry.max_retries = 0

    def post_once(self, call: String, body: String) raises -> Value:
        """Store call `call` once: its answer, or raises, with `FINAL` first
        when the UI refused it for good (the token, or the run, is no longer
        this worker's: 401, 403, 409)."""
        return self.request_once(String(STORE_PATH, call), body)

    def request_once(self, path: String, body: String) raises -> Value:
        """`POST path` once, as `post_once`."""
        var headers: List[Header] = [
            Header("accept", "application/json"),
            Header("content-type", "application/json"),
            Header("user-agent", "morca-worker"),
            Header("authorization", String("Bearer ", self.token)),
        ]
        var resp: Response
        try:
            resp = self.http.request(
                "POST",
                String(self.url, path),
                headers,
                body.as_bytes(),
            )
        except e:
            raise Error("morca: can't reach ", self.url, ": ", e)
        var text = String(from_utf8_lossy=Span(resp.body))
        if resp.status == 200:
            return loads(text)
        var why = refusal(text)
        if not why:
            why = String(resp.status, " ", resp.body_excerpt(200))
        if resp.status == 401 or resp.status == 403 or resp.status == 409:
            raise Error(FINAL, why)
        raise Error("morca: ", self.url, " answered ", why)

    def post(self, call: String, body: String) raises -> Value:
        """`call`, retried while it fails but isn't refused for good."""
        var b = Backoff("morca ui")
        while True:
            try:
                return self.post_once(call, body)
            except e:
                b.again(e)


# ── the heartbeat ────────────────────────────────────────────────────────────


def _exit_now(run: Int, why: String):
    print("run", run, why, flush=True)
    external_call["_exit", NoneType](Int32(1))


struct HttpBeat(Beater):
    """A run's heartbeat over the UI, with a client of its own."""

    var api: StateApi
    var run: Int
    var owner: String
    var timeouts: String
    var parent: Int
    """`MORCA_WORKER_PID`: the worker that started this process, or 0."""

    def __init__(
        out self,
        var api: StateApi,
        run: Int,
        owner: String,
        timeouts: String,
        parent: Int,
    ):
        self.api = api^
        self.run = run
        self.owner = owner
        self.timeouts = timeouts
        self.parent = parent

    def beat(mut self) raises:
        if (
            self.parent > 0
            and Int(external_call["getppid", Int32]()) != self.parent
        ):
            # The worker is gone: beating on would keep the run from being
            # requeued while nothing is left to report how it ends.
            _exit_now(
                self.run,
                String(
                    "stopping: its worker (pid ", self.parent, ") has stopped"
                ),
            )
        var got = self.api.post_once(
            "beat",
            Body()
            .int("run", Int64(self.run))
            .text("owner", self.owner)
            .text("timeouts", self.timeouts)
            .finish(),
        )
        var why = _text(got, "stop")
        if why:
            _exit_now(self.run, why)
        # A UI from before #397 doesn't say: the run is never outdated.
        if String("outdated") in got:
            set_outdated(
                got["outdated"].bool_value(),
                _text(got, "code_version"),
                _text(got, "desired_code_version"),
                _text(got, "outdated_why"),
            )

    def reset(mut self):
        pass


# ── the store ────────────────────────────────────────────────────────────────


def _worker_pid() -> Int:
    try:
        return Int(getenv("MORCA_WORKER_PID", "0"))
    except:
        return 0


struct HttpStore(Movable, RunStore):
    """A run's state over `morca ui`'s API (`MORCA_STATE_URL`)."""

    var api: StateApi
    var run: Int
    var owner: String
    var registry_hash: String
    var _attempt_id: Int64
    """The UI's row of the attempt last started, which `record` and
    `set_log` name."""
    var _heartbeat: Optional[Heartbeat[HttpBeat]]

    def __init__(out self, url: String, token: String) raises:
        self.api = StateApi(url, token)
        self.run = 0
        self.owner = String()
        self.registry_hash = String()
        self._attempt_id = 0
        self._heartbeat = None

    def _for_run(self) -> Body:
        return Body().int("run", Int64(self.run)).text("owner", self.owner)

    @staticmethod
    def _needs_db(what: StaticString) raises:
        raise Error(
            "morca: ",
            what,
            " needs MORCA_DATABASE_URL: a worker's run (MORCA_STATE_URL) only",
            " resumes the run it was given",
        )

    # --- RunStore ---

    def migrate(mut self) raises:
        pass  # the UI's database is the UI's to migrate

    def register(
        mut self, pipeline: String, registry_hash: String, describe: String
    ) raises:
        Self._needs_db("registering a pipeline")

    def scheduled_hash(mut self, pipeline: String) raises -> String:
        Self._needs_db("run")
        return ""

    def version(
        mut self,
        pipeline: String,
        registry_hash: String,
        describe: String,
        image: String,
    ) raises -> Int:
        var got = self.api.post(
            "version",
            Body()
            .int("run", Int64(self.run))
            .text("pipeline", pipeline)
            .text("registry_hash", registry_hash)
            .raw("describe", describe)
            .text("image", image)
            .finish(),
        )
        return Int(_int(got, "version"))

    def create_run(
        mut self,
        pipeline: String,
        registry_hash: String,
        partitions: String,
        trigger: String,
        owner: String,
    ) raises -> Int:
        Self._needs_db("run")
        return 0

    def claim(mut self, run: Int, owner: String, stale_seconds: Float64) raises:
        self.run = run
        _ = self.api.post(
            "claim",
            Body()
            .int("run", Int64(run))
            .text("owner", owner)
            .float("stale", stale_seconds)
            .finish(),
        )

    def ran_version(mut self, run: Int, version: Int) raises:
        _ = self.api.post(
            "ran_version",
            Body()
            .int("run", Int64(run))
            .int("version", Int64(version))
            .finish(),
        )

    def interrupt(mut self, run: Int, why: String = "") raises -> Int:
        var got = self.api.post(
            "interrupt",
            Body().int("run", Int64(run)).text("why", why).finish(),
        )
        return Int(_int(got, "n"))

    def prior(mut self, run: Int) raises -> RunResult:
        var got = self.api.post("prior", Body().int("run", Int64(run)).finish())
        return prior_of(got["steps"])

    def run_info(mut self, run: Int) raises -> RunInfo:
        self.run = run
        var got = self.api.post(
            "run_info", Body().int("run", Int64(run)).finish()
        )
        return run_info_of(got["run"])

    def runs(
        mut self, limit: Int, before: Int = 0, status: String = ""
    ) raises -> List[RunInfo]:
        Self._needs_db("status without a run")
        return List[RunInfo]()

    def steps(mut self, run: Int) raises -> List[StepInfo]:
        var got = self.api.post("steps", Body().int("run", Int64(run)).finish())
        return steps_of(got["steps"])

    def own(mut self, run: Int, owner: String, registry_hash: String) raises:
        self.run = run
        self.owner = owner
        self.registry_hash = registry_hash

    def start_heartbeat(
        mut self, interval: Float64, timeouts: String = ""
    ) raises:
        self._heartbeat = Heartbeat(
            HttpBeat(
                self.api.copy(), self.run, self.owner, timeouts, _worker_pid()
            ),
            interval,
        )

    def stop_heartbeat(mut self):
        self._heartbeat = None

    def finish_run(mut self, status: String) raises:
        _ = self.api.post(
            "finish_run", self._for_run().text("status", status).finish()
        )

    def defer_run(mut self, until: Int64) raises:
        _ = self.api.post(
            "defer_run", self._for_run().int("until", until).finish()
        )

    def cancel_requested(mut self) raises -> Bool:
        var got = self.api.post("cancel_requested", self._for_run().finish())
        return got["cancel"].bool_value()

    # --- Store ---

    def start_attempt(
        mut self,
        step: String,
        partition: String,
        ord: Int,
        input: Span[UInt8, _],
    ) raises -> Int:
        var got = self.api.post(
            "start_attempt",
            self._for_run()
            .text("registry_hash", self.registry_hash)
            .text("step", step)
            .text("partition", partition)
            .int("ord", Int64(ord))
            .bytes("input", input)
            .finish(),
        )
        self._attempt_id = _int(got, "attempt_id")
        return Int(_int(got, "attempt"))

    def finish_attempt(
        mut self,
        step: String,
        partition: String,
        attempt: Int,
        status: String,
        output: Span[UInt8, _],
        error: String,
    ) raises:
        _ = self.api.post(
            "finish_attempt",
            self._for_run()
            .text("registry_hash", self.registry_hash)
            .text("step", step)
            .text("partition", partition)
            .int("attempt", Int64(attempt))
            .text("status", status)
            .bytes("output", output)
            .text("error", error)
            .finish(),
        )

    def skip(
        mut self, step: String, partition: String, ord: Int, reason: String
    ) raises:
        _ = self.api.post(
            "skip",
            self._for_run()
            .text("step", step)
            .text("partition", partition)
            .int("ord", Int64(ord))
            .text("reason", reason)
            .finish(),
        )

    def pinned_reads(
        mut self, step: String, partition: String
    ) raises -> Dict[String, Int64]:
        var got = self.api.post(
            "pinned_reads",
            self._for_run()
            .text("step", step)
            .text("partition", partition)
            .finish(),
        )
        return pins_of(got["pins"])

    def run_token(mut self) raises -> String:
        # An `morca ui` from before run tokens refuses the call: then the
        # run has none here, and its commits are recognised as before them.
        try:
            var got = self.api.post("run_token", self._for_run().finish())
            return got["token"].string_value()
        except:
            return String()

    def record(mut self, commit: Bool, t: TableSnapshot) raises:
        _ = self.api.post(
            "record",
            self._for_run()
            .int("attempt_id", self._attempt_id)
            .bool("commit", commit)
            .text("table", t.table)
            .int("snapshot", t.snapshot_id)
            .text("dataset", t.dataset)
            .finish(),
        )

    def fence(mut self) raises:
        # As over Postgres: an unreachable UI is waited for while the
        # heartbeat could still be fresh, then the commit is off.
        var stale: Float64
        try:
            stale = Float64(getenv("MORCA_STALE_SECONDS", "30"))
        except:
            stale = 30.0
        var b = Backoff("morca ui")
        b.budget = stale / 2
        while True:
            try:
                _ = self.api.post_once("fence", self._for_run().finish())
                return
            except e:
                var msg = String(e)
                if msg.startswith(FINAL):
                    var bare = String(msg[byte = FINAL.byte_length() :])
                    msg = bare^
                if msg.startswith("morca: not committing"):
                    raise Error(msg)
                try:
                    b.again(e)
                except e2:
                    raise Error("morca: not committing: ", e2)

    def set_log(
        mut self, step: String, partition: String, attempt: Int, path: String
    ) raises:
        _ = self.api.post(
            "set_log",
            self._for_run()
            .int("attempt_id", self._attempt_id)
            .text("path", path)
            .finish(),
        )
