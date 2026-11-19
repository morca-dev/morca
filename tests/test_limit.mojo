"""The UI's limits per client (`morca._internal.web.limit`): which URLs are
data reads, a client's minute, and the cap on data reads at once."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from morca._internal.web.limit import (
    ADMIT,
    BUSY,
    TOO_MANY,
    ClientTable,
    admit,
    is_data_read,
    release,
)


def test_data_reads() raises:
    assert_true(is_data_read("/datasets/mojo.repos?tab=data"))
    assert_true(is_data_read("/datasets/mojo.repos?snapshot=1&tab=data&n=5"))
    assert_true(is_data_read("/datasets/mojo.repos/data.csv?snapshot=1"))
    assert_true(is_data_read("/datasets/mojo.repos/data.json"))
    assert_false(is_data_read("/datasets/mojo.repos"))
    assert_false(is_data_read("/datasets/mojo.repos?tab=database"))
    assert_false(is_data_read("/datasets/mojo.repos/snapshots/1"))
    assert_false(is_data_read("/runs?tab=data"))


def test_rate_per_minute() raises:
    var t = ClientTable()
    for _ in range(3):
        assert_equal(admit(t, "a", False, 3, 2, 1000).kind, ADMIT)
    var v = admit(t, "a", False, 3, 2, 1010)
    assert_equal(v.kind, TOO_MANY)
    assert_equal(v.retry_after, 50)
    # Another client has its own minute.
    assert_equal(admit(t, "b", False, 3, 2, 1010).kind, ADMIT)
    # A new minute starts the count again.
    assert_equal(admit(t, "a", False, 3, 2, 1060).kind, ADMIT)


def test_no_rate() raises:
    var t = ClientTable()
    for _ in range(1000):
        assert_equal(admit(t, "a", False, 0, 2, 1000).kind, ADMIT)


def test_data_read_cap() raises:
    var t = ClientTable()
    assert_equal(admit(t, "a", True, 0, 2, 1000).kind, ADMIT)
    # One at a time for a client.
    var v = admit(t, "a", True, 0, 2, 1000)
    assert_equal(v.kind, BUSY)
    assert_equal(v.retry_after, 5)
    # Other pages still go.
    assert_equal(admit(t, "a", False, 0, 2, 1000).kind, ADMIT)
    assert_equal(admit(t, "b", True, 0, 2, 1000).kind, ADMIT)
    # Two running: the cap.
    assert_equal(admit(t, "c", True, 0, 2, 1000).kind, BUSY)
    release(t, "a")
    assert_equal(admit(t, "c", True, 0, 2, 1000).kind, ADMIT)
    assert_equal(admit(t, "a", True, 0, 2, 1000).kind, BUSY)


def test_stale_clients_dropped() raises:
    var t = ClientTable()
    for i in range(5000):
        _ = admit(t, String("c", i), False, 0, 2, 1000)
    assert_equal(len(t.clients), 5000)
    # At 4096 the prune found nothing stale (the same minute), so the next
    # is at 8192, and drops the 5000 whose minute has ended.
    for i in range(5000, 8192):
        _ = admit(t, String("c", i), False, 0, 2, 1100)
    _ = admit(t, "late", False, 0, 2, 1100)
    assert_equal(len(t.clients), 3192 + 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
