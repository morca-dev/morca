"""The data view's disk cache (morca._internal.datacache, #483): what it
writes ends with its length and hash, and a file cut short or changed is a
miss that removes it; statvfs reads the same free space as df; below the
free space to keep it writes nothing and empties itself; and a write to a
full disk is a False, not an abort.

    test_datacache                     the tests
    test_datacache plant DIR KEY TEXT  keeps TEXT for KEY in DIR, for
                                       tests/dataview.sh's broken entries
"""

from std.os import listdir, makedirs, remove
from std.os.path import exists
from std.sys import argv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from morca._internal.datacache import (
    DataCache,
    cache_name,
    checked,
    free_space,
    write_file,
)

comptime DIR = "build/datacache-test"


def _fresh(name: String) raises -> String:
    var d = String(DIR, "/", name)
    if exists(d):
        for f in listdir(d):
            remove(String(d, "/", f))
    makedirs(d, exist_ok=True)
    return d^


def _read(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def _cache(dir: String, min_free: Int = 0) -> DataCache:
    """A cache that keeps no free space unless asked to."""
    return DataCache(dir, 1 << 20, min_free)


def test_a_kept_file_comes_back() raises:
    var d = _fresh("back")
    var c = _cache(d)
    c.put_text("s3://b/t/metadata/snap-1.avro", "hello")
    var got = c.get_text("s3://b/t/metadata/snap-1.avro")
    assert_true(Bool(got))
    assert_equal(got.value(), "hello")
    assert_equal(len(c.used), 1)
    assert_false(Bool(c.get_text("s3://b/t/metadata/snap-2.avro")))


def test_a_cut_short_or_changed_file_is_a_miss_and_removed() raises:
    var d = _fresh("broken")
    var c = _cache(d)
    var key = String("s3://b/t/metadata/m0.avro")
    c.put_text(key, "manifest bytes")
    var path = String(d, "/", cache_name(key))
    var whole = _read(path)
    # Cut short: every length from nothing to one byte less.
    for n in [0, 3, len(whole) // 2, len(whole) - 1]:
        assert_false(Bool(checked(List[UInt8](Span(whole)[:n]))))
    _ = write_file(path, Span(whole)[: len(whole) - 5])
    assert_false(Bool(c.get(key)))
    assert_false(exists(path))
    # One byte changed.
    c.put_text(key, "manifest bytes")
    var bad = whole.copy()
    bad[2] = bad[2] ^ 1
    _ = write_file(path, Span(bad))
    assert_false(Bool(c.get(key)))
    assert_false(exists(path))


def test_statvfs_reads_the_disk() raises:
    var got = free_space(".")
    assert_true(got[0] > 0)
    assert_true(got[1] >= got[0])
    assert_equal(free_space("/no/such/dir")[0], -1)


def test_below_the_free_space_to_keep_nothing_is_written_and_it_empties() raises:
    var d = _fresh("low")
    var c = _cache(d)
    for i in range(5):
        c.put_text(String("s3://b/t/m", i, ".avro"), "some manifest")
    assert_equal(len(listdir(d)), 5)
    # More free space to keep than the disk has.
    var low = _cache(d, free_space(d)[1] + 1)
    assert_true(low.short()[0])
    low.put_text("s3://b/t/m9.avro", "another")
    assert_false(exists(String(d, "/", cache_name("s3://b/t/m9.avro"))))
    low.prune()
    assert_equal(len(listdir(d)), 0)


def test_a_write_to_a_full_disk_is_false() raises:
    # Linux's /dev/full fails every write with ENOSPC; Mojo's own file
    # write aborts the process on it, so the cache doesn't use it.
    if not exists("/dev/full"):
        print("skip: no /dev/full here")
        return
    assert_false(write_file("/dev/full", "x".as_bytes()))


def main() raises:
    var args = argv()
    if len(args) == 5 and String(args[1]) == "plant":
        var c = DataCache(String(args[2]), 1 << 30, 0)
        c.put_text(String(args[3]), String(args[4]))
        return
    TestSuite.discover_tests[__functions_in_module()]().run()
