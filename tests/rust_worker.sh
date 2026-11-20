#!/bin/sh
# Rust workers (docs/rust-workers.md, #392): the morca-worker crate's tests,
# then examples/rust-worker, a Rust worker and its Mojo proxy pipeline, over
# a local warehouse:
#
# - cargo test: the crate's ABI and schema rule, and the example's check of
#   its schema against schemas/numbers.json;
# - the library exports the four morca_worker_* functions and nothing else,
#   with Rust's standard library linked in;
# - a run writes the worker's rows in one commit, with its log lines;
# - a panic in the stream, and a schema that doesn't fit the table, fail
#   the attempt, naming the panic or the column, and commit nothing;
# - the stop flag ends the worker's stream early, and what came is
#   committed;
# - an error in the stream reaches the log in the worker's words;
# - Parquet files the worker writes itself are checked, uploaded and
#   committed in one snapshot; a file whose column doesn't fit, one holding
#   two partitions, and one reported but not there fail the attempt and
#   commit nothing; a worker may stream and write files in one run;
# - a run whose process dies after the commit is resumed, streamed or in
#   files: the retry finds the commit, the worker doesn't run again, and
#   the table has one snapshot of the run;
# - each call's output directory is gone after it;
# - the proxy pipeline compiles no iceberg: the stream and the worker's
#   files go through liblake (#474), and a -D MORCA_LAKE_SOURCE=1 build,
#   with the library's code compiled in, runs the same.
#
# Run in the data environment (pixi run -e data test-rust-worker); cargo
# runs in the rust environment (scripts/cargo.sh).
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/rust-worker
export CARGO_TARGET_DIR=$PWD/build/cargo
log=build/rust-worker/test.log
: > "$log"
fail() {
    echo "FAIL: $*"
    tail -40 "$log"
    exit 1
}

scripts/cargo.sh test --quiet --manifest-path rust/morca-worker/Cargo.toml >> "$log" 2>&1 || fail "cargo test of morca-worker"
scripts/cargo.sh test --quiet --manifest-path examples/rust-worker/Cargo.toml >> "$log" 2>&1 || fail "cargo test of the example"
scripts/cargo.sh build --quiet --release --manifest-path examples/rust-worker/Cargo.toml >> "$log" 2>&1 || fail "cargo build"
echo "ok   cargo test, and the worker builds"

case $(uname) in
Darwin)
    lib=$CARGO_TARGET_DIR/release/libnumbers_worker.dylib
    syms=$(nm -gU "$lib" | awk '{print $3}' | sed 's/^_//')
    deps=$(otool -L "$lib")
    ;;
*)
    lib=$CARGO_TARGET_DIR/release/libnumbers_worker.so
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
echo "ok   the library exports only morca_worker_*, std linked in"

scripts/embed-json.sh examples/rust-worker/schemas/numbers.json NUMBERS_SCHEMA > build/rust-worker/numbers_schema.mojo
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src -I build/rust-worker $DEP_INC examples/rust-worker/numbers.mojo -o build/numbers &
# shellcheck disable=SC2086
scripts/mojo-build.sh -D MORCA_LAKE_SOURCE=1 -I src -I build/rust-worker $DEP_INC examples/rust-worker/numbers.mojo -o build/numbers-source &
wait
wait
bin=./build/numbers
# Functions of iceberg's own (see tests/lake.sh).
iceberg_fns() { nm "$1" | awk '$3 ~ /^_?iceberg::/' | wc -l; }
[ "$(iceberg_fns build/numbers)" -eq 0 ] || fail "build/numbers links iceberg's code"
[ "$(iceberg_fns build/numbers-source)" -gt 0 ] || fail "-D MORCA_LAKE_SOURCE=1 didn't compile the library's code in"
echo "ok   the proxy pipeline has none of iceberg's code; the source build has it"

export MORCA_WAREHOUSE=$PWD/build/rust-worker/wh NUMBERS_LIB=$lib
unset MORCA_DATABASE_URL MORCA_LOGS
rm -rf "$MORCA_WAREHOUSE"
# Where the calls' output directories go, to check they're removed.
export TMPDIR=$PWD/build/rust-worker/tmp
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"
out=build/rust-worker/run.out
rows() { "$bin" check | sed -n 's/^rows \([0-9]*\) .*/\1/p'; }
snaps() { "$bin" check | sed -n 's/^all snapshots \([0-9]*\)$/\1/p'; }
run() {
    month=$1; shift
    env "$@" "$bin" run --partitions "$month" > "$out" 2>&1
}

# --- success ---
run 2024-01 NUMBERS_PARAMS='{"rows": 1000, "batch_rows": 100}' || { cat "$out" >> "$log"; fail "the run failed"; }
cat "$out" >> "$log"
grep -q "numbers worker 0.1.0: 1000 rows for 2024-01, attempt 1" "$out" || fail "no log line from the worker"
grep -q "progress 1000/1000" "$out" || fail "no progress line"
grep -q "numbers: 1000 rows, 0 files of its own, snapshot [0-9]*, stopped=False, resumed=False" "$out" || fail "the step's result"
[ "$(rows)" = 1000 ] || fail "rows: $(rows)"
"$bin" check | grep -qx "ids 499500" || fail "the ids: $("$bin" check)"
echo "ok   a run commits the worker's 1000 rows, with its logs and progress"

# --- a panic, and schemas that don't fit: nothing committed ---
run 2024-02 NUMBERS_PARAMS='{"panic": "batch"}' && fail "a panic didn't fail the run"
cat "$out" >> "$log"
grep -q "the Rust worker .* failed: .*the worker panicked: asked to panic in batch 1" "$out" || fail "the panic's message"
run 2024-02 NUMBERS_PARAMS='{"panic": "run"}' && fail "a panic in run didn't fail the run"
cat "$out" >> "$log"
grep -q "the Rust worker .* failed: the worker panicked: asked to panic in run" "$out" || fail "the panic in run's message"
run 2024-02 NUMBERS_PARAMS='{"fail": true}' && fail "an error in the stream didn't fail the run"
cat "$out" >> "$log"
grep -q "the Rust worker .* failed: asked to fail in the stream" "$out" || fail "the stream error's message"
grep -q "External error\|get_next failed" "$out" && fail "the stream error isn't in the worker's words: $(grep 'asked to fail' "$out")"
[ "$(rows)" = 1000 ] || fail "a failed run committed: $(rows) rows"
echo "ok   a panic or an error fails the attempt with the worker's message, and commits nothing"

for m in type:"column square is string in the worker's schema, which doesn't fit the table's double" \
    extra:"column cube is in the worker's schema but not in the table" \
    missing:"column partition is in the table but not in the worker's schema"; do
    run 2024-03 NUMBERS_PARAMS="{\"mismatch\": \"${m%%:*}\"}" && fail "mismatch ${m%%:*} didn't fail"
    cat "$out" >> "$log"
    grep -qi "doesn't fit demo.numbers: ${m#*:}" "$out" || fail "mismatch ${m%%:*}: $(grep -i fit "$out" | head -3)"
done
[ "$(rows)" = 1000 ] || fail "a mismatch committed: $(rows) rows"
echo "ok   a schema that doesn't fit fails before writing, naming the column"

# --- a stop ---
stop=$PWD/build/rust-worker/stop
rm -f "$stop"
run 2024-04 NUMBERS_STOP_FILE="$stop" NUMBERS_PARAMS='{"rows": 100000, "batch_rows": 100, "sleep_ms": 100}' &
pid=$!
i=0
until grep -q "batch 3" "$out" 2> /dev/null; do
    i=$((i + 1)); [ "$i" -lt 300 ] || { kill "$pid"; fail "the slow worker didn't start"; }
    sleep 0.1
done
touch "$stop"
wait "$pid" || { cat "$out" >> "$log"; fail "the stopped run failed"; }
cat "$out" >> "$log"
grep -q "stopping after [0-9]* rows, as morca asks" "$out" || fail "the worker didn't stop"
got=$(sed -n 's/.*numbers: \([0-9]*\) rows, 0 files of its own, snapshot [0-9]*, stopped=True.*/\1/p' "$out")
[ -n "$got" ] && [ "$got" -gt 0 ] && [ "$got" -lt 100000 ] || fail "the stopped run's rows: [$got]"
[ "$(rows)" = $((1000 + got)) ] || fail "rows after the stop: $(rows), not $((1000 + got))"
echo "ok   the stop flag ends the stream early: $got rows committed"

# --- Parquet files written by the worker ---
base=$(rows)
before=$(snaps)
run 2024-06 NUMBERS_PARAMS='{"mode": "files", "rows": 1000, "file_rows": 300}' || { cat "$out" >> "$log"; fail "the files run failed"; }
cat "$out" >> "$log"
grep -q "wrote file 3" "$out" || fail "the worker didn't write its files"
grep -q "numbers: 1000 rows, 4 files of its own, snapshot [0-9]*, stopped=False, resumed=False" "$out" || fail "the files run's result"
grep -q "the Rust worker wrote 1000 rows in 4 data files (4 of its own) to demo.numbers" "$out" || fail "the files run's log"
[ "$(rows)" = $((base + 1000)) ] || fail "rows after the files run: $(rows)"
[ "$(snaps)" = $((before + 1)) ] || fail "the files run made $(($(snaps) - before)) snapshots"
"$bin" check | grep -qx "ids $((499500 + got * (got - 1) / 2 + 499500))" || fail "the ids after the files run: $("$bin" check)"
n=$(find "$MORCA_WAREHOUSE" -path "*partition=2024-06*" -name "*-w0000[0-3].parquet" | wc -l | tr -d ' ')
[ "$n" = 4 ] || fail "the worker's files in the partition's data/: $n"
echo "ok   the worker's own Parquet files are uploaded to their partition and committed in one snapshot"

for m in type:"doesn't fit demo.numbers: column square is string in the file, which doesn't fit the table's double" \
    partition:"doesn't fit demo.numbers: it holds rows of more than one partition: column partition goes from" \
    missing:"the Rust worker reported the file .*/not-written.parquet, which doesn't exist"; do
    run 2024-07 NUMBERS_PARAMS="{\"mode\": \"files\", \"file_mismatch\": \"${m%%:*}\"}" && fail "file_mismatch ${m%%:*} didn't fail"
    cat "$out" >> "$log"
    grep -q "${m#*:}" "$out" || fail "file_mismatch ${m%%:*}: $(grep -i "fit\|reported" "$out" | head -3)"
done
[ "$(rows)" = $((base + 1000)) ] || fail "a file that doesn't fit committed: $(rows) rows"
echo "ok   a file that doesn't fit, holds two partitions or isn't there fails the attempt, naming it"

before=$(snaps)
run 2024-08 NUMBERS_PARAMS='{"mode": "mix", "rows": 1000}' || { cat "$out" >> "$log"; fail "the mixed run failed"; }
cat "$out" >> "$log"
grep -q "numbers: 1000 rows, 1 files of its own" "$out" || fail "the mixed run's result"
grep -q "the Rust worker wrote 1000 rows in 2 data files (1 of its own)" "$out" || fail "the mixed run's log"
[ "$(rows)" = $((base + 2000)) ] || fail "rows after the mixed run: $(rows)"
[ "$(snaps)" = $((before + 1)) ] || fail "the mixed run made $(($(snaps) - before)) snapshots"
echo "ok   a worker that streams and writes files commits both in one snapshot"

# --- a crash after the commit, resumed ---
export MORCA_DATABASE_URL=sqlite:$PWD/build/rust-worker/runs.db MORCA_STALE_SECONDS=1
rm -f build/rust-worker/runs.db* build/rust-worker/crashed
run 2024-05 NUMBERS_CRASH_ONCE="$PWD/build/rust-worker/crashed" NUMBERS_PARAMS='{"rows": 500}' \
    && fail "the run didn't crash"
cat "$out" >> "$log"
[ -f build/rust-worker/crashed ] || fail "the step didn't get to its crash"
r=$(sed -n 's/^run \([0-9][0-9]*\)$/\1/p' "$out" | head -1)
[ -n "$r" ] || fail "no run number"
[ "$(rows)" = $((base + 2500)) ] || fail "rows after the crash: $(rows)"
sleep 1.5
"$bin" resume "$r" > "$out" 2>&1 || { cat "$out" >> "$log"; fail "the resume failed"; }
cat "$out" >> "$log"
grep -q "the worker's output is committed already; it doesn't run again" "$out" || fail "the retry didn't find its commit"
grep -q "numbers: 0 rows, 0 files of its own, snapshot [0-9]*, stopped=False, resumed=True" "$out" || fail "the resumed step's result"
grep -q "numbers worker 0.1.0" "$out" && fail "the worker ran again"
[ "$("$bin" check "$r" | head -1)" = "rows $((base + 2500)) snapshots 1" ] || fail "after the resume: $("$bin" check "$r")"
echo "ok   a crash after the commit is resumed: the commit is found, and the worker doesn't run again"

rm -f build/rust-worker/crashed
run 2024-09 NUMBERS_CRASH_ONCE="$PWD/build/rust-worker/crashed" NUMBERS_PARAMS='{"mode": "files", "rows": 500}' \
    && fail "the files run didn't crash"
cat "$out" >> "$log"
[ -f build/rust-worker/crashed ] || fail "the files step didn't get to its crash"
r=$(sed -n 's/^run \([0-9][0-9]*\)$/\1/p' "$out" | head -1)
[ -n "$r" ] || fail "no run number for the files run"
[ "$(rows)" = $((base + 3000)) ] || fail "rows after the files crash: $(rows)"
sleep 1.5
"$bin" resume "$r" > "$out" 2>&1 || { cat "$out" >> "$log"; fail "the files resume failed"; }
cat "$out" >> "$log"
grep -q "the worker's output is committed already; it doesn't run again" "$out" || fail "the files retry didn't find its commit"
grep -q "numbers worker 0.1.0" "$out" && fail "the files worker ran again"
[ "$("$bin" check "$r" | head -1)" = "rows $((base + 3000)) snapshots 1" ] || fail "after the files resume: $("$bin" check "$r")"
echo "ok   a crash after committing the worker's files is resumed without a second commit"

# The library's code compiled in: a run that streams and writes files.
base=$(rows)
before=$(snaps)
bin=./build/numbers-source
run 2024-10 NUMBERS_PARAMS='{"mode": "mix", "rows": 1000}' || { cat "$out" >> "$log"; fail "the source build's run failed"; }
cat "$out" >> "$log"
grep -q "the Rust worker wrote 1000 rows in 2 data files (1 of its own)" "$out" || fail "the source build's log"
[ "$(rows)" = $((base + 1000)) ] || fail "rows after the source build's run: $(rows)"
[ "$(snaps)" = $((before + 1)) ] || fail "the source build's run made $(($(snaps) - before)) snapshots"
echo "ok   with -D MORCA_LAKE_SOURCE=1 the same run commits the same"
bin=./build/numbers

left=$(find "$TMPDIR" -maxdepth 1 -name 'morca-rust-*' | head -3)
[ -z "$left" ] || fail "output directories left behind: $left"
echo "ok   every call's output directory is removed"
