#!/bin/sh
# Hindcast (examples/hindcast, #392): GFS 2 m temperature forecasts fetched
# and decoded by a Rust worker, then scored by a Mojo step, over a local
# warehouse and the committed fixtures (offline; nothing is fetched):
#
# - cargo test: the .idx lookup, and the fixtures decode to the 1° grid
#   with the values ecCodes gives;
# - the library exports the four morca_worker_* functions, std linked in;
# - cycles run one per run in either order (as a backfill's runs may) end
#   with the same scores: the forecast of 2026-11-12 +24h is scored against
#   2026-11-13's analysis whichever came first;
# - the grid-wide bias, MAE and RMSE (cos-latitude weighted) and the city
#   scorecard match the numbers examples/hindcast/tools/skill_ref.py gets
#   from ecCodes and numpy;
# - a cycle whose analyses aren't fetched yet is reported as incomplete;
# - a rerun replaces a cycle's rows and its scores, leaving one copy;
# - a cycle that isn't in the bucket defers when it's recent, and fails
#   when it's old.
#
# Run in the data environment (pixi run -e data test-hindcast); cargo runs
# in the rust environment (scripts/cargo.sh).
set -eu
cd "$(dirname "$0")/.."
dir=build/hindcast
mkdir -p "$dir"
export CARGO_TARGET_DIR=$PWD/build/cargo
log=$dir/test.log
: > "$log"
fail() {
    echo "FAIL: $*"
    tail -40 "$log"
    exit 1
}

scripts/cargo.sh test --quiet --manifest-path examples/hindcast/Cargo.toml >> "$log" 2>&1 || fail "cargo test of the worker"
scripts/cargo.sh build --quiet --release --manifest-path examples/hindcast/Cargo.toml >> "$log" 2>&1 || fail "cargo build"
echo "ok   cargo test: the .idx lookup, and the fixtures decode as ecCodes does"

case $(uname) in
Darwin)
    lib=$CARGO_TARGET_DIR/release/libhindcast_worker.dylib
    syms=$(nm -gU "$lib" | awk '{print $3}' | sed 's/^_//')
    deps=$(otool -L "$lib")
    ;;
*)
    lib=$CARGO_TARGET_DIR/release/libhindcast_worker.so
    syms=$(nm -D --defined-only "$lib" | awk '{print $3}')
    deps=$(ldd "$lib")
    ;;
esac
want="morca_worker_abi_version
morca_worker_describe
morca_worker_free
morca_worker_run"
[ "$(echo "$syms" | sort)" = "$want" ] || fail "the library exports: $syms"
echo "$deps" | grep -q libstd && fail "the library links Rust's std dynamically: $deps"
echo "$deps" | grep -qi 'ssl\|crypto' && fail "the library links a TLS library: $deps"
echo "ok   the library exports only morca_worker_*, and links no Rust std or OpenSSL"

scripts/embed-json.sh examples/hindcast/schemas/t2m.json T2M_SCHEMA > "$dir/t2m_schema.mojo"
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src -I "$dir" -I examples/hindcast $DEP_INC examples/hindcast/hindcast.mojo -o "$dir/hindcast"
bin=./$dir/hindcast

export MORCA_WAREHOUSE=$PWD/$dir/wh HINDCAST_LIB=$lib HINDCAST_SOURCE=$PWD/examples/hindcast/fixtures HINDCAST_LEADS=0,24
unset MORCA_DATABASE_URL MORCA_LOGS MORCA_NOW
out=$dir/run.out
run() {
    day=$1; shift
    env "$@" "$bin" run --partitions "$day" > "$out" 2>&1
}
report() { "$bin" report 2026-11-12 > "$dir/report.out" 2>&1 || { cat "$dir/report.out" >> "$log"; fail "the report failed"; }; }
# near <file> <pattern> <field> <want> <tolerance>: the number after
# <field> on the line matching <pattern> is within <tolerance> of <want>.
near() {
    awk -v pat="$2" -v f="$3" -v want="$4" -v tol="$5" '
        $0 ~ pat { for (i = 1; i < NF; i++) if ($i == f) { got = $(i + 1); seen = 1 } }
        END {
            if (!seen) { print "no " f " on a line matching " pat; exit 1 }
            d = got - want; if (d < 0) d = -d
            if (d > tol) { print f " is " got ", not " want " (+-" tol ") on " pat; exit 1 }
        }' "$1"
}

# --- out of order: the later cycle first, as a backfill's runs may go ---
rm -rf "$MORCA_WAREHOUSE"
run 2026-11-13 || { cat "$out" >> "$log"; fail "the run of 2026-11-13 failed"; }
cat "$out" >> "$log"
grep -q "f024: 74342 bytes at 0, 65160 points" "$out" || fail "no log line of the worker's fetch"
grep -q "the Rust worker wrote 130320 rows in 2 data files to hindcast.t2m" "$out" || fail "the worker's rows"
grep -q "nothing to score yet" "$out" || fail "2026-11-13 alone scored something"
run 2026-11-12 || { cat "$out" >> "$log"; fail "the run of 2026-11-12 failed"; }
cat "$out" >> "$log"
grep -q "2026-11-12 +24h, valid 2026-11-13: bias" "$out" || fail "the forecast wasn't scored when its cycle came second"
grep -q "1 forecasts scored, valid on 1 days" "$out" || fail "the scoring step's result"
report
cat "$dir/report.out" >> "$log"
echo "ok   cycles in either order: the forecast is scored once both cycles are fetched"

# --- the numbers: ecCodes and numpy got these (tools/skill_ref.py) ---
r=$dir/report.out
grep -q "skill 2026-11-12 +24h valid 2026-11-13 points 65160 " "$r" || fail "no skill row: $(cat "$r")"
e=$(near "$r" "^skill 2026-11-12" bias -0.002982 0.0002) || fail "$e"
e=$(near "$r" "^skill 2026-11-12" mae 0.360490 0.0002) || fail "$e"
e=$(near "$r" "^skill 2026-11-12" rmse 0.642565 0.0002) || fail "$e"
echo "ok   grid-wide skill matches ecCodes and numpy: bias -0.0030 K, MAE 0.3605 K, RMSE 0.6426 K"

for c in "New_York 41 -74 283.3716 282.8011 0.5705" "London 52 0 274.7716 274.9411 -0.1695" \
    "Tokyo 36 140 288.0316 287.8311 0.2005" "Sydney -34 151 296.8516 296.7311 0.1205" \
    "Sao_Paulo -24 -47 291.7116 291.2611 0.4505" "Cairo 30 31 289.3916 289.3011 0.0905" \
    "Mumbai 19 73 297.1216 297.0211 0.1005" "Moscow 56 38 273.8816 273.8911 -0.0095" \
    "Lagos 7 3 297.2916 297.0111 0.2805" "Anchorage 61 -150 275.4016 276.8011 -1.3995"; do
    set -- $c
    grep -q "^city +24h $1 $2 $3 " "$r" || fail "$1 isn't at its grid point ($2, $3): $(grep "$1" "$r")"
    e=$(near "$r" "^city .24h $1 " forecast "$4" 0.001) || fail "$e"
    e=$(near "$r" "^city .24h $1 " analysis "$5" 0.001) || fail "$e"
    e=$(near "$r" "^city .24h $1 " error "$6" 0.001) || fail "$e"
done
[ "$(grep -c '^city ' "$r")" = 10 ] || fail "city rows: $(grep -c '^city ' "$r")"
echo "ok   the city scorecard: ten cities at their nearest grid points, as ecCodes has them"

grep -qx "cycle 2026-11-13 has 0 of 1 leads scored" "$r" || fail "the waiting cycle: $(cat "$r")"
grep -qx "1 of 2 cycles complete" "$r" || fail "complete cycles: $(cat "$r")"
grep -qx "rows: t2m 260640 skill 1 cities 10" "$r" || fail "rows: $(grep rows: "$r")"
echo "ok   a cycle waiting for its analyses is reported incomplete"

# --- a rerun replaces, and the scores are the same ---
run 2026-11-13 || { cat "$out" >> "$log"; fail "the rerun failed"; }
cat "$out" >> "$log"
grep -q "1 forecasts scored, valid on 1 days" "$out" || fail "the rerun didn't rescore 2026-11-13"
report
grep -qx "rows: t2m 260640 skill 1 cities 10" "$r" || fail "rows after a rerun: $(grep rows: "$r")"
e=$(near "$r" "^skill 2026-11-12" rmse 0.642565 0.0002) || fail "$e"
echo "ok   a rerun replaces the cycle's rows and its scores"

# --- a cycle that isn't there: wait for a recent one, fail an old one ---
run 2026-11-14 MORCA_NOW=2026-11-14T03:00Z || true
cat "$out" >> "$log"
grep -q "deferred" "$out" || fail "a recent missing cycle didn't defer: $(tail -5 "$out")"
run 2026-11-01 MORCA_NOW=2026-11-14T03:00Z && fail "an old missing cycle succeeded"
cat "$out" >> "$log"
grep -q "not published yet" "$out" || fail "the missing file's error"
grep -q "deferred" "$out" && fail "an old missing cycle deferred"
echo "ok   a missing cycle defers when it's recent, and fails when it's old"
