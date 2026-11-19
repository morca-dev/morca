"""The Turnstile cookie and where a pass sends the browser
(`morca._internal.web.turnstile`)."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from morca._internal.web.turnstile import safe_next, sign, valid


def _key() -> List[UInt8]:
    var k = List[UInt8]()
    for i in range(32):
        k.append(UInt8(i))
    return k^


def test_good_cookie() raises:
    var k = _key()
    assert_true(valid(k, sign(k, 2000), 1000))


def test_expired_cookie() raises:
    var k = _key()
    assert_false(valid(k, sign(k, 1000), 1000))
    assert_false(valid(k, sign(k, 999), 1000))


def test_tampered_cookie() raises:
    var k = _key()
    var c = sign(k, 2000)
    # A later expiry with the old signature.
    assert_false(valid(k, String("3000", c[byte=4:]), 1000))
    var other = _key()
    other[0] = 99
    assert_false(valid(other, c, 1000))
    assert_false(valid(k, "", 1000))
    assert_false(valid(k, "2000", 1000))
    assert_false(valid(k, "x.y", 1000))
    assert_false(valid(k, String(c, "0"), 1000))


def test_safe_next() raises:
    assert_equal(safe_next("/datasets/a?tab=data"), "/datasets/a?tab=data")
    assert_equal(safe_next(""), "/")
    assert_equal(safe_next("//evil.example/"), "/")
    assert_equal(safe_next("https://evil.example/"), "/")
    assert_equal(safe_next("/\\evil.example"), "/")
    assert_equal(safe_next("/a\r\nSet-Cookie: x"), "/")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
