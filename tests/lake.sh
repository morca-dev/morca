#!/bin/sh
# liblake (#454) from the outside: a library of another ABI version is
# refused, naming both versions; a missing one names where it looked; an
# iceberg error inside the library reaches the step's log intact, the same
# as with the library's code compiled in (-D MORCA_LAKE_SOURCE=1); and, on
# Linux, the library's line tables name a source line (what a crash's stack
# dump needs). Needs the data environment and LAKE_LIB (pixi.toml).
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
fail() {
    echo "FAIL: $*"
    exit 1
}
case "$(uname -s)" in
Darwin) ext=dylib ;;
*) ext=so ;;
esac
# shellcheck disable=SC2086
mojo build --emit shared-lib tests/lake/fake_lake.mojo -o "build/libfake_lake.$ext"
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC tests/lake/load_one.mojo -o build/lake-load-one &
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC tests/lake/failing.mojo -o build/lake-failing &
# shellcheck disable=SC2086
scripts/mojo-build.sh -D MORCA_LAKE_SOURCE=1 -I src $DEP_INC tests/lake/failing.mojo -o build/lake-failing-source &
wait
wait
wait

out=$(LAKE_LIB="$PWD/build/libfake_lake.$ext" ./build/lake-load-one a.b)
echo "$out" | grep -q "has ABI version 999, and this morca speaks 3" \
    || fail "a library of another ABI version wasn't refused: $out"
out=$(LAKE_LIB="$PWD/build/no-such-liblake.$ext" ./build/lake-load-one a.b)
echo "$out" | grep -q "can't load $PWD/build/no-such-liblake.$ext" \
    || fail "a missing library wasn't named: $out"
echo "ok   lake: another ABI version and a missing library are refused"

root=build/lake-test
for v in failing failing-source; do
    rm -rf "$root"
    out=$(MORCA_WAREHOUSE="$root/wh" "./build/lake-$v" run --partitions 2024-01 2>&1) && fail "$v succeeded"
    line=$(echo "$out" | grep -m1 'attempt 1 failed') || fail "$v logged no failure: $out"
    echo "$line" > "build/lake-$v.line"
done
echo "$(cat build/lake-failing.line)" | grep -q "iceberg" \
    || fail "the failure isn't iceberg's: $(cat build/lake-failing.line)"
cmp -s build/lake-failing.line build/lake-failing-source.line \
    || fail "the library's error differs from the compiled-in code's:
  $(cat build/lake-failing.line)
  $(cat build/lake-failing-source.line)"
echo "ok   lake: an iceberg error reaches the step's log as it would compiled in"
# Functions of iceberg's own (a std function instantiated on a type of the
# same layout may carry an iceberg type's name from Mojo's compile cache).
iceberg_fns() { nm "$1" | awk '$3 ~ /^_?iceberg::/' | wc -l; }
[ "$(iceberg_fns build/lake-failing)" -eq 0 ] \
    || fail "build/lake-failing links iceberg's code"
[ "$(iceberg_fns build/lake-failing-source)" -gt 0 ] \
    || fail "-D MORCA_LAKE_SOURCE=1 didn't compile the library's code in"
echo "ok   lake: only the -D MORCA_LAKE_SOURCE=1 build has iceberg's code"

if [ "$ext" = so ] && command -v addr2line > /dev/null 2>&1; then
    addr=$(nm "$LAKE_LIB" | awk '$3 == "lake_table" {print $1; exit}')
    [ -n "$addr" ] || fail "no lake_table in $LAKE_LIB"
    where=$(addr2line -e "$LAKE_LIB" "0x$addr")
    echo "$where" | grep -q '_lake/liblake.mojo:[0-9]' \
        || fail "$LAKE_LIB's line tables don't name lake_table's line: $where"
    echo "ok   lake: liblake's line tables name its source ($where)"
else
    echo "skip lake: line tables (checked on Linux; macOS keeps them in a .dSYM)"
fi
