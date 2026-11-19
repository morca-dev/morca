"""The UI's cache of data reads (`morca._internal.web.cache.DataCache`)."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from morca._internal.web.cache import TTL_SECONDS, DataCache, Kept


def _kept(n: Int, status: Int = 200) -> Kept:
    var body = List[UInt8]()
    for _ in range(n):
        body.append(UInt8(120))
    return Kept(status, body^, ["Content-Type"], ["text/html"], 1000, 0)


def test_hit() raises:
    var c = DataCache(1 << 20)
    assert_false(Bool(c.get("a", 1000)))
    c.put("a", _kept(10))
    var k = c.get("a", 1001)
    assert_true(Bool(k))
    assert_equal(k.value().status, 200)
    assert_equal(len(k.value().body), 10)
    assert_equal(k.value().values[0], "text/html")


def test_404_kept() raises:
    var c = DataCache(1 << 20)
    c.put("gone", _kept(5, 404))
    assert_equal(c.get("gone", 1000).value().status, 404)


def test_evicts_least_recently_used() raises:
    # Room for two of these, not three.
    var one = _kept(400).size("a")
    var c = DataCache(one * 2 + one // 2)
    c.put("a", _kept(400))
    c.put("b", _kept(400))
    _ = c.get("a", 1000)  # b is now the least recently used
    c.put("c", _kept(400))
    assert_true(Bool(c.get("a", 1000)))
    assert_false(Bool(c.get("b", 1000)))
    assert_true(Bool(c.get("c", 1000)))
    assert_true(c.bytes <= c.max_bytes)


def test_replace_keeps_count() raises:
    var c = DataCache(1 << 20)
    c.put("a", _kept(100))
    var once = c.bytes
    c.put("a", _kept(100))
    assert_equal(c.bytes, once)
    assert_equal(len(c.kept), 1)


def test_too_big_not_kept() raises:
    var c = DataCache(100)
    c.put("a", _kept(1000))
    assert_false(Bool(c.get("a", 1000)))
    assert_equal(c.bytes, 0)


def test_off_at_zero() raises:
    var c = DataCache(0)
    c.put("a", _kept(1))
    assert_false(Bool(c.get("a", 1000)))


def test_expires() raises:
    var c = DataCache(1 << 20)
    c.put("a", _kept(10))
    assert_true(Bool(c.get("a", 1000 + TTL_SECONDS)))
    assert_false(Bool(c.get("a", 1001 + TTL_SECONDS)))
    assert_equal(c.bytes, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
