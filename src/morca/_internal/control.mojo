"""Placement: where a pipeline's runs run (`morca register --placement`), and
the control runner, which runs them on the scheduler's own host.

A pipeline's placement is `default` (stored as null: the scheduler's runner,
`MORCA_RUNNER`, as before), `ec2` (instances of their own, `morca._internal.ec2`; on a
scheduler whose runner isn't `ec2` such runs wait, saying why),
`worker:<pool>` (a remote worker of that pool starts them, `orca.workers`,
never the scheduler) or `control`:
the scheduler starts the run as a child process of its own, the pipeline's
binary with `resume <run>` as the local runner does, which on AWS is in the
scheduler's container on the control instance (the binary is the project's
image's). Small runs then start in a second, without an instance to boot.

**Limits**, so a run can't starve Postgres, the scheduler or the UI:

- **Memory.** Each tick the scheduler adds up the resident memory of each
  control-placed run's process tree (`morca._internal.sample.tree_rss`) and kills one
  over `MORCA_CONTROL_MEMORY_MB` (1024), failing its attempts with why. Its
  processes are also the first the kernel kills if memory runs out before
  that (`oom_score_adj` 1000, on Linux).
- **CPU.** Its processes run at `nice` `MORCA_CONTROL_NICE` (10), so the
  control instance's own processes win when the cores are busy.
- **How many.** At most `MORCA_CONTROL_MAX_RUNS` (2) control-placed runs, of
  all pipelines, run at once.
- **Pressure.** None starts while the control instance's newest minute
  (`morca._internal.system`, from its sampler) has memory or its fullest disk over 85%.

A run held by either of the last two stays queued with the reason in
`runs.held`, which its page and JSON show. dista inside such a run is in
local mode, `MORCA_CONTROL_WORKERS` (1) forked workers.

**Secrets** (`--secret NAME=ID`) are read by the scheduler when it starts
the run, with `MORCA_SECRET_FETCH` as the instances read them, else from
Secrets Manager's API with the scheduler's credentials (the image has no
`aws` command), and put in the run's environment only, with `MORCA_SECRETS`
naming them so its logs mask them. Its driver's output is kept in a staging
file and appended to the run's `driver.log`, masked, by `<binary> keep-log`
once the process has ended, as on an EC2 head.
"""

from std.os import getenv, remove

from json import loads

from morca._internal.awsjson import aws_json
from morca._internal.json import quote
from morca._internal.proc import binary_seconds, capture
from morca._internal.system import Now

comptime CONTROL = "control"
"""The placement, and the instance name of a control-placed run's samples."""

comptime HOLD_PERCENT: Float64 = 85.0
"""The control instance's memory or fullest disk, in percent, past which no
control-placed run starts."""


comptime WORKER_PREFIX = "worker:"
"""A placement on a pool of remote workers (`orca.workers`): this and the
pool's name."""
comptime MAX_POOL = 32


def pool_problem(pool: String) -> String:
    """Why `pool` can't name a pool of workers, or empty: 1 to 32 of
    `a-z`, `0-9`, `-` and `_`."""
    var b = pool.as_bytes()
    if len(b) == 0 or len(b) > MAX_POOL:
        return String("a pool's name is 1 to ", MAX_POOL, " characters")
    for c in b:
        if not (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("-"))
            or c == UInt8(ord("_"))
        ):
            return String(
                "a pool's name is a-z, 0-9, - and _, not ", quote(pool)
            )
    return ""


def pool_of(placement: String) -> String:
    """The pool a `worker:<pool>` placement names, or empty for any other."""
    if placement.startswith(WORKER_PREFIX):
        return String(placement[byte = WORKER_PREFIX.byte_length() :])
    return ""


def parse_placement(v: String) raises -> String:
    """`--placement`'s value: `control`, `ec2`, `worker:<pool>` or
    `default`."""
    if v == "control" or v == "ec2" or v == "default":
        return v
    if v.startswith(WORKER_PREFIX):
        var why = pool_problem(pool_of(v))
        if why:
            raise Error("--placement worker:<pool>: ", why)
        return v
    raise Error(
        "--placement is control, ec2, worker:<pool> or default, not ", v
    )


def _env_int(name: StaticString, default: Int, least: Int) raises -> Int:
    var s = getenv(name)
    if not s:
        return default
    try:
        var n = Int(s)
        if n >= least:
            return n
    except:
        pass
    raise Error("morca: ", name, " must be a number from ", least, ", not ", s)


@fieldwise_init
struct ControlLimits(Copyable, Movable):
    """What a control-placed run may use, from the scheduler's
    environment."""

    var max_runs: Int
    """`MORCA_CONTROL_MAX_RUNS` (2): control-placed runs at once."""
    var memory_mb: Int
    """`MORCA_CONTROL_MEMORY_MB` (1024): one run's resident memory."""
    var workers: Int
    """`MORCA_CONTROL_WORKERS` (1): its dista workers, forked locally."""
    var nice: Int
    """`MORCA_CONTROL_NICE` (10): its CPU priority, lowered by this."""

    @staticmethod
    def from_env() raises -> ControlLimits:
        return ControlLimits(
            _env_int("MORCA_CONTROL_MAX_RUNS", 2, 0),
            _env_int("MORCA_CONTROL_MEMORY_MB", 1024, 1),
            _env_int("MORCA_CONTROL_WORKERS", 1, 1),
            _env_int("MORCA_CONTROL_NICE", 10, 0),
        )


def _pct(x: Float64) -> String:
    return String(Int(x + 0.5))


def pressure_reason(now: Optional[Now]) -> String:
    """Why no control-placed run may start now, given the control
    instance's newest minute, or empty if one may. Samples that are old or
    missing hold nothing: a scheduler without a sampler isn't stopped."""
    if not now or now.value().stale():
        return ""
    ref n = now.value()
    if n.mem_pct > HOLD_PERCENT:
        return String(
            "held: the control instance's memory is ",
            _pct(n.mem_pct),
            "% used, over ",
            Int(HOLD_PERCENT),
            "%",
        )
    if n.disk_pct > HOLD_PERCENT:
        return String(
            "held: the control instance's disk ",
            n.disk_path,
            " is ",
            _pct(n.disk_pct),
            "% full, over ",
            Int(HOLD_PERCENT),
            "%",
        )
    return ""


def slots_reason(running: Int, max_runs: Int) -> String:
    """Why a control-placed run waits for one of the others to end."""
    return String(
        "held: ",
        running,
        " of ",
        max_runs,
        " control-placed runs are running (MORCA_CONTROL_MAX_RUNS)",
    )


def control_stage(pipeline: String, run: Int, start: Int) -> String:
    """Where a control-placed run's start, or a local run's with secrets,
    writes its output before `keep-log` appends it to the run's
    `driver.log`: under `MORCA_LOG_STAGE` (else `$TMPDIR/morca-logs`), never
    in the logs themselves, since it isn't masked yet."""
    var root = getenv("MORCA_LOG_STAGE")
    if not root:
        root = String(getenv("TMPDIR", "/tmp").rstrip("/"), "/morca-logs")
    return String(
        root, "/control/", pipeline, "-", run, "-", start, "-driver.log"
    )


def keep_log_ended(stage: String, code: Int) -> Bool:
    """Once `keep-log` has ended with `code`: the staging file `stage` is
    removed if it kept the output (exit 0), and kept, unmasked output and
    all, if it didn't, so nothing is lost (#526). True if it was kept."""
    if code != 0:
        return False
    try:
        remove(stage)
    except:
        pass
    return True


def run_env(
    limits: ControlLimits,
    image: String,
    secrets: List[Tuple[String, String]],
) -> List[String]:
    """What a control-placed run's process gets beside the scheduler's
    environment: its local workers, its image (which its version records)
    and its secrets' values, `secrets` being (NAME, value) pairs, named in
    `MORCA_SECRETS`."""
    var out: List[String] = [String("MORCA_WORKERS=", limits.workers)]
    if image:
        out.append(String("MORCA_IMAGE=", image))
    out.extend(secrets_env(secrets))
    return out^


def secrets_env(secrets: List[Tuple[String, String]]) -> List[String]:
    """A run's secrets as environment entries, `secrets` being (NAME, value)
    pairs: each `NAME=value`, then `MORCA_SECRETS` naming them, which
    `morca._internal.logs.mask` masks the values by. Nothing for no secrets."""
    var out = List[String]()
    var names = String()
    for s in secrets:
        out.append(String(s[0], "=", s[1]))
        names.write("," if names else "", s[0])
    if names:
        out.append(String("MORCA_SECRETS=", names))
    return out^


def _sh_word(s: String) -> String:
    return String("'", s.replace("'", "'\\''"), "'")


def fetch_secret(id: String) raises -> String:
    """The value of the secret `id`: what `MORCA_SECRET_FETCH <id>` prints,
    as the instances' scripts read it (trailing newlines dropped, as `$(...)`
    drops them), else Secrets Manager's `GetSecretValue`."""
    var cmd = getenv("MORCA_SECRET_FETCH")
    if cmd:
        var got = capture(
            ["sh", "-c", String(cmd, " ", _sh_word(id))], binary_seconds()
        )
        if got[0] != 0:
            raise Error("can't read secret ", id, ": exit ", got[0])
        var n = got[1].byte_length()
        while n > 0 and got[1].as_bytes()[n - 1] == UInt8(ord("\n")):
            n -= 1
        return String(got[1][byte=:n])
    return get_secret_value(id)


def get_secret_value(id: String) raises -> String:
    """Secrets Manager's `GetSecretValue` of `id` (`morca._internal.awsjson`), with
    the credentials of the `AWS_*` environment or else the instance role;
    `MORCA_SECRETS_ENDPOINT` points it elsewhere, as the tests do at their
    stand-in (`tests/fake_ec2.py`)."""
    var got: Tuple[Int, String]
    try:
        got = aws_json(
            "secretsmanager",
            "secretsmanager.GetSecretValue",
            "MORCA_SECRETS_ENDPOINT",
            String('{"SecretId": ', quote(id), "}"),
        )
    except e:
        raise Error("can't read secret ", id, ": ", e)
    if got[0] != 200:
        # Its error names a type and a message, never a value.
        raise Error("can't read secret ", id, ": ", got[0], " ", got[1])
    return loads(got[1])["SecretString"].string_value()
