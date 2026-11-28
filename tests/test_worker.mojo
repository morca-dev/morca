"""Remote workers' encoding (morca.http_store, orca.workers): what a run's
store calls send and get back over `morca ui`'s API, the spec a worker is
given, and the checks made on both sides. tests/worker.sh runs it all
against morca ui, the scheduler and a worker."""

from std.os import getenv, makedirs, remove
from std.os.path import exists
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
from morca._internal.host_join import (
    CONTAINER,
    LAUNCHD,
    SYSTEMD,
    JoinPlan,
    stop_commands,
    word_problem,
)
from morca._internal.host_follow import (
    FAILED_FILE,
    WANT_FILE,
    Follow,
    image_problem,
)
from morca._internal.run_cluster import (
    MemberSpec,
    member_spec_json,
    member_spec_of,
)
from morca._internal.sample import machine_name
from morca._internal.worker import env_file_pairs
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


def test_member_spec() raises:
    var env: List[Tuple[String, String]] = [("A", "1")]
    var m = MemberSpec(
        7,
        12,
        2,
        "embed",
        "/app/bin/embed",
        "10.0.0.2:4100",
        "secret",
        env^,
        List[Tuple[String, String]](),
        Grant(4, 16384, 1),
        "gpu",
    )
    var got = member_spec_of(loads(member_spec_json(m)))
    assert_equal(got.member, 7)
    assert_equal(got.head, "10.0.0.2:4100")
    assert_equal(got.grant.gpus, 1)
    assert_equal(got.group, "gpu")
    # From a UI before groups: no group.
    var old = loads(
        '{"member": 1, "run": 2, "start": 1, "pipeline": "p", "binary": "b",'
        ' "head": "h:1", "token": "t", "env": [], "secrets": [],'
        ' "grant_cpus": 0, "grant_memory_mb": 0}'
    )
    var o = member_spec_of(old)
    assert_equal(o.group, "")
    assert_equal(o.grant.gpus, 0)


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


def _plan(service: String, root: String = "/") -> JoinPlan:
    return JoinPlan(
        service,
        "bgent",
        "https://morca.example.com",
        "lab",
        "/opt/morca/bin/morca",
        "/home/m/.morca/token",
        ["/home/m/worker.env"],
        [("MORCA_RESERVE_CPUS", "2")],
        root,
        "",
        "",
        "ghcr.io/morca-dev/census:1.2.3" if service == CONTAINER else "",
        ["census-work:/work"] if service == CONTAINER else List[String](),
        "",
        SYSTEMD if service == CONTAINER else "",
    )


def test_env_files() raises:
    # `morca worker --env-file` reads them as Docker does (#220).
    var got = env_file_pairs(
        "# a comment\n\nA=1\nMORCA_SECRET_FETCH=sh /etc/orca/fetch\nB=x=y\r\n"
    )
    assert_equal(len(got), 3)
    assert_equal(got[1][1], "sh /etc/orca/fetch")
    assert_equal(got[2][0], "B")
    assert_equal(got[2][1], "x=y")
    with assert_raises(contains="line 2 isn't NAME=value"):
        _ = env_file_pairs("A=1\nnot a pair\n")


def test_host_join_files() raises:
    # What `morca host join` writes (#220): no secret in any of it.
    var u = _plan(SYSTEMD)
    assert_equal(u.problem(), "")
    assert_equal(
        u.service_path(), "/etc/systemd/system/morca-worker-bgent.service"
    )
    assert_equal(u.env_path(), "/etc/morca/worker-bgent.env")
    var unit = u.unit_text()
    assert_true(
        String(
            "ExecStart=/opt/morca/bin/morca worker --pool bgent --remote",
            " https://morca.example.com --token-file /home/m/.morca/token",
            " --name lab --dir /var/lib/morca/bgent/stage --env-file",
            " /etc/morca/worker-bgent.env --env-file /home/m/worker.env",
            " --host-service systemd\n",
        )
        in unit,
        unit,
    )
    assert_true("RestartPreventExitStatus=3\n" in unit)
    assert_true("WantedBy=multi-user.target" in unit)
    assert_true("MORCA_RESERVE_CPUS=2\n" in u.env_text())
    assert_equal(len(u.start_commands()), 3)
    # Under a root, every path is under it.
    var rooted = _plan(SYSTEMD, "/tmp/r/")
    assert_equal(rooted.record_path(), "/tmp/r/etc/morca/host-bgent.json")
    assert_true("--dir /tmp/r/var/lib/morca/bgent/stage" in rooted.unit_text())
    var l = _plan(LAUNCHD)
    var plist = l.plist_text()
    assert_equal(
        l.service_path(), "/Library/LaunchDaemons/dev.morca.worker.bgent.plist"
    )
    assert_true(
        "<string>--token-file</string>\n   "
        " <string>/home/m/.morca/token</string>"
        in plist,
        plist,
    )
    assert_true("<key>KeepAlive</key>\n  <true/>" in plist)
    assert_equal(l.start_commands()[1][1], "bootstrap")
    var c = _plan(CONTAINER)
    assert_equal(c.problem(), "")
    var d = " ".join(c.docker_args())
    assert_true(
        String(
            "docker run --rm --name morca-worker-bgent",
            " --env-file /etc/morca/worker-bgent.env --env-file",
            " /home/m/worker.env -v /home/m/.morca/token:/etc/morca/token:ro",
            " -v /var/lib/morca/bgent/stage:/var/lib/morca/stage -v",
            " census-work:/work ghcr.io/morca-dev/census:1.2.3 worker --pool",
            " bgent --remote https://morca.example.com --token-file",
            " /etc/morca/token --name lab --dir /var/lib/morca/stage",
            " --host-image ghcr.io/morca-dev/census:1.2.3",
        )
        == d,
        d,
    )
    # Its script runs the image its record names, and its unit the script.
    var script = c.container_script()
    assert_true(
        "'--network'" not in script
        and "\"$image\" 'worker' '--pool'" in script,
        script,
    )
    assert_true("'--host-image' \"$image\"\n" in script, script)
    assert_true("RECORD='/etc/morca/host-bgent.json'\n" in script, script)
    assert_true('docker pull "$want"' in script, script)
    assert_true("ghcr.io/morca-dev/census:1.2.3" not in script, script)
    var rec = c.record_json()
    assert_true('"service": "container"' in rec)
    assert_true('"image": "ghcr.io/morca-dev/census:1.2.3"' in rec, rec)
    assert_true('"supervisor": "systemd"' in rec, rec)
    # The record, as its script writes it back, is the record.
    var at = rec.find('"image": "').or_else(-1) + 10
    var end = rec.find('"', at).or_else(-1)
    assert_true(
        String(
            "printf '%s%s%s\\n' '",
            rec[byte=:at],
            "' \"$1\" '",
            rec[byte=end:],
            "'",
        )
        in script,
        script,
    )
    assert_equal(
        c.unit_path(), "/etc/systemd/system/morca-worker-bgent.service"
    )
    var cu = c.unit_file_text()
    assert_true(
        "ExecStart=/bin/sh /etc/morca/worker-bgent-container.sh\n" in cu, cu
    )
    assert_true("After=network-online.target docker.service\n" in cu, cu)
    assert_true("RestartPreventExitStatus=3\n" in cu, cu)
    assert_equal(c.start_commands()[2][2], "morca-worker-bgent")
    var stops = stop_commands(CONTAINER, "morca-worker-bgent", "x", SYSTEMD)
    assert_equal(len(stops), 2)
    assert_equal(stops[0][0], "systemctl")
    assert_equal(stops[1][2], "-f")
    # A record from before the script had a supervisor: the container only.
    assert_equal(len(stop_commands(CONTAINER, "morca-worker-bgent", "x")), 1)
    # What can't go in a service file as it is.
    assert_true("can't have a space" in word_problem("a path", "/a b"))
    assert_true("can't have" in word_problem("a path", "/a%b"))
    var bad = _plan(SYSTEMD)
    bad.token_file = "token"
    assert_equal(bad.problem(), "the token file's path is absolute")
    bad = _plan(SYSTEMD)
    bad.settings = [("API_TOKEN", "x")]
    assert_true("looks like a secret" in bad.problem())
    bad = _plan(CONTAINER)
    bad.volumes = ["a:b"]
    assert_true("the pool's volumes" in bad.problem())


def _lines(path: String) raises -> List[String]:
    var out = List[String]()
    with open(path, "r") as f:
        for l in f.read().split("\n"):
            out.append(String(l))
    return out^


def test_follow() raises:
    # A host following the server's worker image (#220).
    var dir = String(getenv("TMPDIR", "/tmp").rstrip("/"), "/morca-follow-test")
    makedirs(dir, exist_ok=True)
    for name in [WANT_FILE, FAILED_FILE]:
        if exists(String(dir, "/", name)):
            remove(String(dir, "/", name))
    # An older UI says no image: nothing changes.
    var f = Follow("img:1", "", "", dir)
    f.start()
    f.observe(loads('{"run": null}'), 0)
    assert_false(f.draining())
    assert_equal(f.state(), "")
    f.observe(loads('{"run": null, "worker_image": "img:1"}'), 0)
    assert_false(f.draining())
    assert_equal(f.state(), "current img:1")
    # The server moved on: it drains, then says what to start.
    f.observe(loads('{"run": null, "worker_image": "img:2"}'), 1)
    assert_true(f.draining())
    assert_equal(f.state(), "draining img:2")
    f.leave()
    assert_equal(_lines(String(dir, "/", WANT_FILE))[0], "img:2")
    # Started again on img:1 with that still there: nothing replaced it, and
    # it doesn't drain for img:2 again.
    var again = Follow("img:1", "", "", dir)
    again.start()
    assert_false(exists(String(dir, "/", WANT_FILE)))
    assert_equal(_lines(String(dir, "/", FAILED_FILE))[0], "img:2")
    again.observe(loads('{"run": null, "worker_image": "img:2"}'), 0)
    assert_false(again.draining())
    assert_equal(again.state(), "failed img:2")
    # Until it's asked to (morca host upgrade), or the server moves on.
    again.observe(
        loads('{"run": null, "worker_image": "img:2", "upgrade": true}'), 0
    )
    assert_true(again.draining())
    assert_false(exists(String(dir, "/", FAILED_FILE)))
    var later = Follow("img:1", "", "", dir)
    later.failed = "img:2"
    later.observe(loads('{"run": null, "worker_image": "img:3"}'), 0)
    assert_true(later.draining())
    # Started on the image it asked for: done.
    f.leave()
    var moved = Follow("img:2", "", "", dir)
    moved.start()
    assert_false(exists(String(dir, "/", WANT_FILE)))
    assert_equal(moved.failed, "")
    # A failure the script wrote (a pull it couldn't make), with why.
    with open(String(dir, "/", FAILED_FILE), "w") as out:
        out.write("img:3\ncan't pull img:3 (unauthorized)\n")
    var refused = Follow("img:2", "", "", dir)
    refused.start()
    assert_equal(refused.failed, "img:3")
    assert_true("unauthorized" in refused.why)
    refused.observe(loads('{"run": null, "worker_image": "img:3"}'), 0)
    assert_false(refused.draining())
    remove(String(dir, "/", FAILED_FILE))
    # A service reports, and never drains.
    var svc = Follow("", "systemd", "", dir)
    svc.observe(loads('{"run": null, "worker_image": "img:2"}'), 0)
    assert_false(svc.draining())
    assert_equal(svc.state(), "needs-upgrade img:2")
    var same = Follow("", "launchd", "img:2", dir)
    same.observe(loads('{"run": null, "worker_image": "img:2"}'), 0)
    assert_equal(same.state(), "current img:2")
    # A plain worker (the autoscaler's, or by hand) says nothing.
    var plain = Follow("", "", "img:1", dir)
    plain.observe(loads('{"run": null, "worker_image": "img:2"}'), 0)
    assert_false(plain.draining())
    assert_equal(plain.state(), "")
    # An image that isn't a plain reference is ignored.
    var odd = Follow("img:1", "", "", dir)
    odd.observe(loads('{"run": null, "worker_image": "img:2; rm -rf /"}'), 0)
    assert_false(odd.draining())
    assert_true("not an image reference" in image_problem("a b"))
    assert_equal(image_problem("ghcr.io/morca-dev/census:1.2.3"), "")
    assert_equal(image_problem("r.io/x@sha256:ab12"), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
