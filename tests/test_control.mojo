"""Placement and the control runner's rules (morca.control): the
`--placement` values, the limits from the environment, when the control
instance's samples hold a run, what a run's process is given, and secrets
read with `MORCA_SECRET_FETCH`. tests/placement.sh runs it all under the
scheduler.
"""

from std.os import getenv, setenv, unsetenv
from std.os.path import exists
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from morca._internal.control import (
    ControlLimits,
    control_stage,
    fetch_secret,
    keep_log_ended,
    parse_placement,
    pressure_reason,
    run_env,
    slots_reason,
)
from morca._internal.system import Now
from morca._internal.db.system import Container


def _now(age: Float64, mem: Float64, disk: Float64) -> Now:
    return Now(
        age,
        10.0,
        20.0,
        mem,
        1,
        2,
        disk,
        3,
        4,
        "/var/lib/orca/stage",
        0.0,
        0.0,
        List[Container](),
    )


def test_placements() raises:
    assert_equal(parse_placement("control"), "control")
    assert_equal(parse_placement("ec2"), "ec2")
    assert_equal(parse_placement("default"), "default")
    for bad in ["", "Control", "local", "kubernetes"]:
        with assert_raises(contains="control, ec2, worker:<pool> or default"):
            _ = parse_placement(bad)
    # A pool of remote workers (orca.workers).
    assert_equal(parse_placement("worker:bgent"), "worker:bgent")
    assert_equal(parse_placement("worker:a_b-9"), "worker:a_b-9")
    var long = String("worker:")
    for _ in range(33):
        long.write("x")
    for bad in ["worker:", "worker:Bgent", "worker:a b", long]:
        with assert_raises(contains="a pool's name"):
            _ = parse_placement(bad)


def test_limits() raises:
    for n in [
        "MORCA_CONTROL_MAX_RUNS",
        "MORCA_CONTROL_MEMORY_MB",
        "MORCA_CONTROL_WORKERS",
        "MORCA_CONTROL_NICE",
    ]:
        _ = unsetenv(n)
    var d = ControlLimits.from_env()
    assert_equal(d.max_runs, 2)
    assert_equal(d.memory_mb, 1024)
    assert_equal(d.workers, 1)
    assert_equal(d.nice, 10)
    _ = setenv("MORCA_CONTROL_MAX_RUNS", "0")
    _ = setenv("MORCA_CONTROL_WORKERS", "3")
    var l = ControlLimits.from_env()
    assert_equal(l.max_runs, 0)
    assert_equal(l.workers, 3)
    _ = setenv("MORCA_CONTROL_WORKERS", "0")
    with assert_raises(contains="MORCA_CONTROL_WORKERS"):
        _ = ControlLimits.from_env()
    _ = setenv("MORCA_CONTROL_WORKERS", "lots")
    with assert_raises(contains="MORCA_CONTROL_WORKERS"):
        _ = ControlLimits.from_env()
    _ = unsetenv("MORCA_CONTROL_WORKERS")
    _ = unsetenv("MORCA_CONTROL_MAX_RUNS")


def test_pressure() raises:
    # No samples, or old ones, hold nothing.
    assert_equal(pressure_reason(None), "")
    assert_equal(pressure_reason(_now(601.0, 99.0, 99.0)), "")
    assert_equal(pressure_reason(_now(5.0, 85.0, 85.0)), "")
    var mem = pressure_reason(_now(5.0, 91.4, 10.0))
    assert_equal(
        mem, "held: the control instance's memory is 91% used, over 85%"
    )
    var disk = pressure_reason(_now(5.0, 30.0, 86.0))
    assert_equal(
        disk,
        (
            "held: the control instance's disk /var/lib/orca/stage is 86%"
            " full, over 85%"
        ),
    )
    assert_true("2 of 2 control-placed runs" in slots_reason(2, 2))


def test_run_env() raises:
    var l = ControlLimits(2, 512, 1, 10)
    var none = run_env(l, "", List[Tuple[String, String]]())
    assert_equal(len(none), 1)
    assert_equal(none[0], "MORCA_WORKERS=1")
    var e = run_env(
        l, "repo/morca:v1", [("GITHUB_TOKEN", "tok"), ("API_KEY", "key")]
    )
    assert_equal(len(e), 5)
    assert_equal(e[1], "MORCA_IMAGE=repo/morca:v1")
    assert_equal(e[2], "GITHUB_TOKEN=tok")
    assert_equal(e[3], "API_KEY=key")
    assert_equal(e[4], "MORCA_SECRETS=GITHUB_TOKEN,API_KEY")


def test_stage() raises:
    _ = setenv("MORCA_LOG_STAGE", "/var/lib/orca/stage")
    assert_equal(
        control_stage("toy", 12, 3),
        "/var/lib/orca/stage/control/toy-12-3-driver.log",
    )
    _ = unsetenv("MORCA_LOG_STAGE")
    var tmp = getenv("TMPDIR")
    _ = setenv("TMPDIR", "/tmp/x/")
    assert_equal(
        control_stage("toy", 1, 1),
        "/tmp/x/morca-logs/control/toy-1-1-driver.log",
    )
    if tmp:
        _ = setenv("TMPDIR", tmp)
    else:
        _ = unsetenv("TMPDIR")


def test_keep_log_ended() raises:
    # A keep-log that failed leaves the staging file, as it says (#526);
    # one that kept the output removes it.
    var stage = String(
        getenv("TMPDIR", "/tmp").rstrip("/"), "/morca-test-keep-log-stage"
    )
    with open(stage, "w") as f:
        f.write("output\n")
    assert_false(keep_log_ended(stage, 1))
    assert_true(exists(stage), "a failed keep-log removed its stage")
    assert_true(keep_log_ended(stage, 0))
    assert_false(exists(stage), "a kept stage stayed")


def test_fetch() raises:
    _ = setenv("MORCA_SECRET_FETCH", "printf '%s-value\\n\\n'")
    assert_equal(fetch_secret("orca/it's"), "orca/it's-value")
    _ = setenv("MORCA_SECRET_FETCH", "false")
    with assert_raises(contains="can't read secret orca/x: exit 1"):
        _ = fetch_secret("orca/x")
    _ = unsetenv("MORCA_SECRET_FETCH")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
