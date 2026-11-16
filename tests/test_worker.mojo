"""Remote workers' encoding (morca.http_store, orca.workers): what a run's
store calls send and get back over `morca ui`'s API, the spec a worker is
given, and the checks made on both sides. tests/worker.sh runs it all
against morca ui, the scheduler and a worker."""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from json import loads

from morca._internal.control import pool_of, pool_problem
from morca.resources import Grant
from morca._internal.http_store import (
    Body,
    bytes_of_hex,
    check_state_url,
    hex_of,
    pins_json,
    pins_of,
    prior_json,
    prior_of,
    refusal,
    run_info_json,
    run_info_of,
    steps_json,
    steps_of,
)
from morca._internal.store import RunResult, StepRun, SUCCEEDED
from morca._internal.db.run_rows import RunInfo, StepInfo, Usage
from morca._internal.sample import machine_name
from morca._internal.workers import (
    WorkerRun,
    version_refusal,
    worker_run_json,
    worker_run_of,
)


def test_hex() raises:
    var b: List[UInt8] = [0, 1, 15, 16, 127, 128, 254, 255]
    assert_equal(hex_of(Span(b)), "00010f107f80feff")
    var back = bytes_of_hex("00010f107f80feff")
    assert_equal(len(back), len(b))
    for i in range(len(b)):
        assert_equal(back[i], b[i])
    assert_equal(len(bytes_of_hex("")), 0)
    assert_equal(len(bytes_of_hex("ABcd")), 2)
    with assert_raises(contains="odd number"):
        _ = bytes_of_hex("abc")
    with assert_raises(contains="not hex"):
        _ = bytes_of_hex("zz")


def test_body() raises:
    var empty: List[UInt8] = []
    var json = (
        Body()
        .int("run", 42)
        .text("owner", 'host:1 "q"\n')
        .bool("commit", True)
        .float("stale", 1.5)
        .bytes("input", Span(empty))
        .raw("describe", '{"name": "toy"}')
        .finish()
    )
    var v = loads(json)
    assert_equal(v["run"].int_value(), 42)
    assert_equal(v["owner"].string_value(), 'host:1 "q"\n')
    assert_true(v["commit"].bool_value())
    assert_equal(v["stale"].float_value(), 1.5)
    assert_equal(v["input"].string_value(), "")
    assert_equal(v["describe"]["name"].string_value(), "toy")
    assert_equal(Body().finish(), "{}")


def test_run_info() raises:
    var r = RunInfo(7, "toy", "abc", "2024-01,2024-02", "running", "h:1", "")
    var got = run_info_of(loads(run_info_json(r)))
    assert_equal(got.id, 7)
    assert_equal(got.pipeline, "toy")
    assert_equal(got.registry_hash, "abc")
    assert_equal(got.partitions, "2024-01,2024-02")
    assert_equal(got.status, "running")
    assert_equal(got.owner, "h:1")
    assert_equal(got.error, "")


def test_steps() raises:
    var steps: List[StepInfo] = [
        StepInfo(
            "load",
            "2024-01",
            "succeeded",
            1,
            "",
            "/logs/a",
            Usage(209715200, 6.25, 2.5),
        ),
        StepInfo("sum", "", "failed", 3, "boom: é", "", Usage.unknown()),
    ]
    var got = steps_of(loads(steps_json(steps)))
    assert_equal(len(got), 2)
    assert_equal(got[0].step, "load")
    assert_equal(got[0].log, "/logs/a")
    assert_equal(got[1].partition, "")
    assert_equal(got[1].attempts, 3)
    assert_equal(got[1].error, "boom: é")
    assert_equal(got[0].usage.peak_rss_bytes, 209715200)
    assert_equal(got[0].usage.cpu_seconds, 6.25)
    assert_equal(got[0].usage.peak_cpus, 2.5)
    assert_false(got[1].usage.known())
    assert_equal(got[1].usage.peak_cpus, -1.0)
    assert_equal(len(steps_of(loads(steps_json(List[StepInfo]())))), 0)


def test_prior() raises:
    var res = RunResult()
    var out: List[UInt8] = [8, 0, 0, 0, 0, 0, 0, 0, 255]
    res.steps.append(StepRun("load", "2024-01", SUCCEEDED, out.copy(), ""))
    res.steps.append(StepRun("sum", "", SUCCEEDED, List[UInt8](), ""))
    var got = prior_of(loads(prior_json(res)))
    assert_equal(len(got.steps), 2)
    assert_equal(got.steps[0].status, SUCCEEDED)
    assert_equal(len(got.steps[0].output), len(out))
    for i in range(len(out)):
        assert_equal(got.steps[0].output[i], out[i])
    assert_equal(len(got.steps[1].output), 0)
    assert_equal(got.find("sum", ""), 1)


def test_pins() raises:
    var pins = Dict[String, Int64]()
    pins["/wh/lake/raw"] = 1234567890123456789
    pins["/wh/lake/none"] = -1
    var got = pins_of(loads(pins_json(pins)))
    assert_equal(len(got), 2)
    assert_equal(got["/wh/lake/raw"], 1234567890123456789)
    assert_equal(got["/wh/lake/none"], -1)


def test_worker_run() raises:
    var env: List[Tuple[String, String]] = [("A", "1"), ("B", "x=y")]
    var secrets: List[Tuple[String, String]] = [("TOKEN", "prod/token")]
    var w = WorkerRun(
        12,
        2,
        "toy",
        "/app/bin/toy",
        "deadbeef",
        "2024-01",
        True,
        "ghcr.io/x/morca:0.11.0",
        env^,
        secrets^,
        Grant(3, 2048),
        2,
    )
    var got = worker_run_of(loads(worker_run_json(w)))
    assert_equal(got.members, 2)
    assert_equal(got.grant.cpus, 3)
    assert_equal(got.grant.memory_mb, 2048)
    assert_equal(got.run, 12)
    assert_equal(got.start, 2)
    assert_equal(got.binary, "/app/bin/toy")
    assert_equal(got.registry_hash, "deadbeef")
    assert_true(got.allow_new_code)
    assert_equal(got.image, "ghcr.io/x/morca:0.11.0")
    assert_equal(len(got.env), 2)
    assert_equal(got.env[1][0], "B")
    assert_equal(got.env[1][1], "x=y")
    assert_equal(got.secrets[0][0], "TOKEN")
    assert_equal(got.secrets[0][1], "prod/token")


def test_versions() raises:
    assert_equal(version_refusal("morca:1", "morca:1"), "")
    assert_equal(version_refusal("", ""), "")
    assert_true("needs image morca:2" in version_refusal("morca:2", "morca:1"))
    assert_true("MORCA_IMAGE isn't set" in version_refusal("morca:2", ""))
    assert_true("needs image (none)" in version_refusal("", "morca:1"))


def test_pools() raises:
    assert_equal(pool_of("worker:bgent"), "bgent")
    assert_equal(pool_of("control"), "")
    assert_equal(pool_problem("bgent"), "")
    assert_true(pool_problem("") != "")
    assert_true(pool_problem("BGENT") != "")


def test_urls() raises:
    assert_equal(
        check_state_url("https://orca.mlake.dev/"), "https://orca.mlake.dev"
    )
    assert_equal(
        check_state_url("http://127.0.0.1:8270"), "http://127.0.0.1:8270"
    )
    assert_equal(check_state_url("http://localhost:1"), "http://localhost:1")
    for bad in ["http://orca.mlake.dev", "ftp://x", "orca.mlake.dev"]:
        with assert_raises(contains="https://"):
            _ = check_state_url(bad)


def test_machine_name() raises:
    assert_equal(machine_name("bgent"), "worker-bgent")
    assert_equal(machine_name("ip-10-0-1-5.local"), "worker-ip-10-0-1-5.local")
    assert_equal(machine_name("a/b c"), "worker-a_b_c")


def test_refusal() raises:
    assert_equal(refusal('{"error": "morca: lost run 3"}'), "morca: lost run 3")
    assert_equal(refusal("<html>bad gateway</html>"), "")
    assert_equal(refusal('{"ok": true}'), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
