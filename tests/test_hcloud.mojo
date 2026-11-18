"""morca.hcloud against tests/fake_hcloud.py: run by tests/hcloud.sh, which
starts the fake and sets MORCA_HCLOUD_ENDPOINT, MORCA_HCLOUD_TOKEN and
HCLOUD_DIR (the fake's directory)."""

from std.os import getenv, remove
from std.os.path import exists
from std.time import sleep
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from morca._internal.hcloud import (
    HCloud,
    ServerSpec,
    error_of,
    is_no_stock,
)
from morca._internal.machines import MachineSpec, Provider, docker_arch


def _dir() -> String:
    return getenv("HCLOUD_DIR")


def _write(name: String, text: String) raises:
    with open(String(_dir(), "/", name), "w") as f:
        f.write(text)


def _spec(
    name: String, t: String, loc: String, data: String = ""
) -> ServerSpec:
    return ServerSpec(
        name,
        t,
        loc,
        "ubuntu-24.04",
        data,
        [("orca-pool", "lab"), ("morca", "true")],
        ["morca-lab"],
        "morca-lab",
        "",
    )


def test_types_and_firewalls() raises:
    var h = HCloud.from_env()
    assert_equal(h.arch("cax31"), "arm")
    assert_equal(h.arch("cpx32"), "x86")
    with assert_raises(contains="no server type nope"):
        _ = h.arch("nope")
    assert_equal(h.firewall_id("morca-lab"), "42")
    with assert_raises(contains="no firewall named other"):
        _ = h.firewall_id("other")


def test_create_list_delete() raises:
    var h = HCloud.from_env()
    _write("stock", "")
    var got = h.create(_spec("morca-lab-1", "cax31", "hel1"))
    assert_false(got.ok)
    assert_true(got.no_stock)
    assert_true("resource_unavailable" in got.why)
    _write("stock", "cax31 hel1\n")
    got = h.create(
        _spec("morca-lab-1", "cax31", "hel1", "echo ran > $SERVER_NAME.ran\n")
    )
    assert_true(got.ok, got.why)
    assert_equal(got.address, "127.0.0.1")
    var id = got.id
    # The same name again: refused, and not for stock.
    var again = h.create(_spec("morca-lab-1", "cax31", "hel1"))
    assert_false(again.ok)
    assert_false(again.no_stock)
    assert_true("uniqueness_error" in again.why, again.why)
    # A type or location it doesn't have is no stock's opposite: a mistake.
    var bad = h.create(_spec("morca-lab-2", "cax99", "hel1"))
    assert_false(bad.no_stock)
    var listed = h.servers("orca-pool=lab")
    assert_equal(len(listed), 1)
    assert_equal(listed[0].id, id)
    assert_equal(listed[0].name, "morca-lab-1")
    assert_equal(listed[0].server_type, "cax31")
    assert_equal(listed[0].location, "hel1")
    assert_equal(listed[0].pool, "lab")
    assert_equal(len(h.servers("orca-pool=other")), 0)
    # Its user data ran, with SERVER_NAME its name.
    var ran = String(_dir(), "/morca-lab-1.ran")
    for _ in range(100):
        if exists(ran):
            break
        sleep(0.05)
    assert_true(exists(ran), "the server's user data didn't run")
    assert_true(h.delete(id))
    assert_true(h.delete(id))  # gone already: 404 is done
    assert_equal(len(h.servers("orca-pool=lab")), 0)


def test_every_page() raises:
    var h = HCloud.from_env()
    _write("no-run", "")
    _write("stock", "cx23 nbg1\n")
    for i in range(55):
        assert_true(h.create(_spec(String("p-", i), "cx23", "nbg1")).ok)
    var all = h.servers("orca-pool=lab")
    assert_equal(len(all), 55)
    for s in all:
        _ = h.delete(s.id)
    remove(String(_dir(), "/no-run"))


def test_errors_keep_the_token_out() raises:
    var h = HCloud(getenv("MORCA_HCLOUD_ENDPOINT"), "not-the-token")
    try:
        _ = h.servers("orca-pool=lab")
        raise Error("accepted a bad token")
    except e:
        var m = String(e)
        assert_true("HTTP 401 unauthorized" in m, m)
        assert_false("not-the-token" in m, m)
    var gone = HCloud("http://127.0.0.1:1", "secret")
    with assert_raises(contains="can't reach Hetzner's API"):
        _ = gone.servers("x")


def test_the_provider() raises:
    """morca.machines over Hetzner: Docker's architecture names, a pool's
    machines by label, and EC2 needing its region."""
    var p = Provider.of("hetzner")
    assert_equal(p.arch("cax21"), "arm64")
    assert_equal(p.arch("cx33"), "amd64")
    assert_equal(docker_arch("x86_64"), "amd64")
    _write("stock", "cpx32 fsn1\n")
    var got = p.create(MachineSpec("morca-p-1", "cpx32", "fsn1", "", "p"))
    assert_true(got.ok, got.why)
    var ms = p.machines("p")
    assert_equal(len(ms), 1)
    assert_equal(ms[0].machine_type, "cpx32")
    assert_equal(ms[0].location, "fsn1")
    assert_equal(ms[0].pool, "p")
    assert_equal(len(p.machines("other")), 0)
    assert_true(p.delete(ms[0].id))
    with assert_raises(contains="needs AWS_REGION"):
        _ = Provider.of("ec2")


def test_error_bodies() raises:
    var e = error_of('{"error": {"code": "placement_error", "message": "no"}}')
    assert_equal(e[0], "placement_error")
    assert_equal(e[1], "no")
    assert_equal(error_of("not json")[0], "")
    assert_true(is_no_stock("resource_unavailable"))
    assert_true(is_no_stock("placement_error"))
    assert_false(is_no_stock("uniqueness_error"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
