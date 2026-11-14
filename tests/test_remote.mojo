"""`morca login`'s pieces that need no server: API tokens' form, digest and
lifetime (`morca._internal.tokens`), which URLs a token may be sent to, and the
credentials file and its mode (`morca._internal.remote`). tests/remote.sh runs the
whole of it against `morca ui`."""

from std.os import getenv, listdir, remove, setenv, stat
from std.os.path import exists
from json import loads
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from morca._internal.remote import (
    Credential,
    find_credential,
    read_credentials,
    remote_url,
    waiting_line,
    write_credentials,
)
from morca._internal.tokens import (
    TOKEN_PREFIX,
    clean_label,
    is_token,
    new_token,
    token_days,
    token_hash,
)


def test_tokens_are_random_and_well_formed() raises:
    var a = new_token()
    var b = new_token()
    assert_true(a.startswith(TOKEN_PREFIX))
    # orca_ and 32 bytes in hex: 256 bits.
    assert_equal(a.byte_length(), 5 + 64)
    assert_true(is_token(a))
    assert_true(a != b)


def test_is_token_refuses_others() raises:
    var t = new_token()
    assert_false(is_token(""))
    assert_false(is_token(String(t, "0")))
    assert_false(is_token(String(t[byte=1:])))
    assert_false(is_token(t.upper()))
    assert_false(is_token(String("orcb_", t[byte=5:])))
    assert_false(is_token(String(t[byte = : t.byte_length() - 1], "g")))


def test_token_hash_is_sha256() raises:
    # The SHA-256 of "abc" (FIPS 180-2's example).
    assert_equal(
        token_hash("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    )
    var t = new_token()
    assert_equal(token_hash(t), token_hash(String(t)))
    assert_true(token_hash(t) != token_hash(new_token()))
    # What's kept doesn't contain the token.
    assert_false(t[byte=5:] in token_hash(t))


def test_token_days() raises:
    var had = getenv("MORCA_API_TOKEN_DAYS")
    _ = setenv("MORCA_API_TOKEN_DAYS", "30")
    assert_equal(token_days(), 30)
    assert_equal(token_days(7), 7)
    assert_equal(token_days(31), 30)
    assert_equal(token_days(-1), 30)
    _ = setenv("MORCA_API_TOKEN_DAYS", "1")
    assert_equal(token_days(7), 1)
    _ = setenv("MORCA_API_TOKEN_DAYS", "0")
    with assert_raises(contains="MORCA_API_TOKEN_DAYS"):
        _ = token_days()
    _ = setenv("MORCA_API_TOKEN_DAYS", "a month")
    with assert_raises(contains="MORCA_API_TOKEN_DAYS"):
        _ = token_days()
    _ = setenv("MORCA_API_TOKEN_DAYS", had if had else "30")


def test_clean_label() raises:
    assert_equal(clean_label("laptop.local"), "laptop.local")
    assert_equal(clean_label(""), "cli")
    assert_equal(clean_label("a\nb\tc"), "a-b-c")
    assert_equal(clean_label(String("x") * 100).byte_length(), 64)


def test_remote_url_https() raises:
    assert_equal(remote_url("orca.mlake.dev"), "https://orca.mlake.dev")
    assert_equal(
        remote_url("https://orca.mlake.dev/"), "https://orca.mlake.dev"
    )
    assert_equal(remote_url("HTTPS://Orca.Mlake.Dev"), "https://orca.mlake.dev")
    assert_equal(
        remote_url("https://orca.mlake.dev:443"), "https://orca.mlake.dev"
    )
    assert_equal(
        remote_url("https://orca.mlake.dev:8443"), "https://orca.mlake.dev:8443"
    )
    assert_equal(remote_url(" orca.mlake.dev\n"), "https://orca.mlake.dev")


def test_remote_url_http_only_here() raises:
    assert_equal(remote_url("http://127.0.0.1:8270"), "http://127.0.0.1:8270")
    assert_equal(remote_url("http://localhost:8270/"), "http://localhost:8270")
    assert_equal(remote_url("http://[::1]:8270"), "http://[::1]:8270")
    assert_equal(remote_url("http://127.0.0.1:80"), "http://127.0.0.1")
    with assert_raises(contains="plain http"):
        _ = remote_url("http://orca.mlake.dev")
    # Not this machine, whatever it starts with.
    with assert_raises(contains="plain http"):
        _ = remote_url("http://127.0.0.1.evil.example")
    with assert_raises(contains="plain http"):
        _ = remote_url("http://localhost.evil.example:8270")


def test_remote_url_refuses_the_rest() raises:
    with assert_raises(contains="https, not ftp"):
        _ = remote_url("ftp://orca.mlake.dev")
    for bad in [
        "https://orca.mlake.dev/runs",
        "https://orca.mlake.dev?x=1",
        "https://orca.mlake.dev#x",
        "https://me@orca.mlake.dev",
        "https://127.0.0.1@evil.example",
        "https://morca mlake.dev",
        "https://orca.mlake.dev\\x",
    ]:
        with assert_raises(contains="no path"):
            _ = remote_url(bad)
    with assert_raises(contains="not a port"):
        _ = remote_url("https://orca.mlake.dev:x")
    with assert_raises(contains="not a port"):
        _ = remote_url("https://orca.mlake.dev:70000")
    with assert_raises(contains="no host"):
        _ = remote_url("https://:443")
    with assert_raises(contains="no UI"):
        _ = remote_url("  ")


def _mode(path: String) raises -> Int:
    return Int(stat(path).st_mode) & 0o777


def test_credentials_round_trip_mode_600() raises:
    var path = String("build/remote-creds/creds/credentials")
    if exists(path):
        remove(path)
    assert_equal(len(read_credentials(path)), 0)
    var cs: List[Credential] = [
        Credential("https://a.example", "alice", "2026-12-05T00:00:00Z", "t1"),
        Credential(
            "http://127.0.0.1:8270", "bob", "2026-12-06T00:00:00Z", "t2"
        ),
    ]
    write_credentials(path, cs)
    assert_equal(_mode(path), 0o600)
    assert_equal(_mode("build/remote-creds/creds"), 0o700)
    var got = read_credentials(path)
    assert_equal(len(got), 2)
    assert_equal(got[1].user, "bob")
    assert_equal(got[1].token, "t2")
    assert_equal(find_credential(got, "http://127.0.0.1:8270"), 1)
    assert_equal(find_credential(got, "https://b.example"), -1)
    # Writing again replaces the file and keeps its mode; no temporary
    # file is left beside it.
    _ = got.pop(0)
    write_credentials(path, got)
    assert_equal(_mode(path), 0o600)
    assert_equal(len(read_credentials(path)), 1)
    assert_equal(len(listdir("build/remote-creds/creds")), 1)


def test_credentials_others_can_read_refused() raises:
    var path = String("build/remote-creds/open/credentials")
    write_credentials(
        path, [Credential("https://a.example", "alice", "x", "t1")]
    )
    # As a careless copy would leave it.
    var p = path
    _ = external_chmod(p, 0o644)
    with assert_raises(contains="can be read by others"):
        _ = read_credentials(path)
    _ = external_chmod(p, 0o600)
    assert_equal(len(read_credentials(path)), 1)


def external_chmod(mut path: String, mode: Int) -> Int:
    from std.ffi import c_int, c_uint, external_call

    return Int(
        external_call["chmod", c_int](path.as_c_string_span(), c_uint(mode))
    )


def test_status_says_why_queued_runs_wait() raises:
    # `morca status`'s line under a pipeline whose queued runs wait (#462).
    var why = "waiting: needs 5 GB, more than the 1 GB this host grants at most"
    assert_equal(
        waiting_line(loads(String('{"queued": 1, "waiting": "', why, '"}'))),
        String("  ", why),
    )
    assert_equal(waiting_line(loads('{"queued": 1, "waiting": null}')), "")
    assert_equal(
        waiting_line(loads(String('{"queued": 0, "waiting": "', why, '"}'))),
        "",
    )
    # A server before `waiting`.
    assert_equal(waiting_line(loads('{"queued": 2}')), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
