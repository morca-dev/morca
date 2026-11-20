#!/bin/sh
# morca-sdk (#521): whole pipelines in Rust, with no Mojo toolchain
# (docs/rust-pipelines.md):
#
# - cargo test: the crate's own tests (keys, the builder's checks, describe
#   and the registry hash, the crash summary), with and without tables;
# - examples/toy-rust, examples/toy.mojo rebuilt in Rust, links no Mojo
#   runtime;
# - the conformance suite (tests/conformance.py) passes for the Rust toy,
#   for the Rust sensor with tables (rust/morca-sdk/examples/clean.rs, the
#   twin of tests/sensors/clean.mojo), and for the Rust sensor that replaces
#   its partitions (examples/replace.rs, the twin of
#   tests/sensors/replace.mojo), whose table Mojo's morca.tables
#   (tests/sensors/rows_by.mojo) and iceberg-rust then read as one copy of
#   each month, over SQLite and Postgres;
# - side by side: the Mojo toy and the Rust toy registered with one morca
#   scheduler (the Rust one placed on the control host), fired by the same
#   schedule, then a backfill each, every run succeeding; `morca status`
#   and the UI's pages list both, and the control run's driver log was kept
#   by the Rust binary's `keep-log`.
#
# Run in the data environment, which has Mojo (for the scheduler and the
# Mojo toy), with a throwaway Postgres; cargo runs in the rust environment
# (scripts/cargo.sh, which also picks the C compiler a crate builds with):
#   pixi run -e data test-rust-sdk
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build/rust-sdk
export CARGO_TARGET_DIR=$PWD/build/cargo
log=build/rust-sdk/test.log
: > "$log"
ui=
sched=
fail() {
    echo "FAIL: $*"
    tail -40 "$log"
    [ -z "$ui" ] || kill "$ui" 2> /dev/null || true
    [ -z "$sched" ] || kill "$sched" 2> /dev/null || true
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -qAtc "$1"; }

# The scheduler and the Mojo toy, while cargo builds.
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca >> "$log" 2>&1 &
mojo_morca=$!
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC examples/toy.mojo -o build/rust-sdk/toy >> "$log" 2>&1 &
mojo_toy=$!
# The Mojo reader of the table the Rust replace example writes.
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC tests/sensors/rows_by.mojo -o build/sn-rows_by >> "$log" 2>&1 &
mojo_rows=$!

scripts/cargo.sh test --manifest-path rust/morca-sdk/Cargo.toml >> "$log" 2>&1 || fail "cargo test"
scripts/cargo.sh test --manifest-path rust/morca-sdk/Cargo.toml --features tables >> "$log" 2>&1 \
    || fail "cargo test --features tables"
echo "ok   the crate's tests, with and without tables"
scripts/cargo.sh build --release --manifest-path examples/toy-rust/Cargo.toml >> "$log" 2>&1 || fail "build the Rust toy"
scripts/cargo.sh build --release --features tables --examples --manifest-path rust/morca-sdk/Cargo.toml >> "$log" 2>&1 \
    || fail "build the table examples"
rtoy=$CARGO_TARGET_DIR/release/toy_rust
case "$(uname)" in
Darwin) libs=$(otool -L "$rtoy") ;;
*) libs=$(ldd "$rtoy" || true) ;;
esac
if echo "$libs" | grep -Eqi 'KGEN|mojo|liblake'; then
    fail "the Rust toy links Mojo: $libs"
fi
echo "ok   the Rust toy builds with cargo alone ($(wc -c < "$rtoy" | tr -d ' ') bytes) and links no Mojo runtime"

wait "$mojo_morca" || fail "build morca"
wait "$mojo_toy" || fail "build the Mojo toy"
wait "$mojo_rows" || fail "build the Mojo reader (tests/sensors/rows_by.mojo)"

python3 tests/conformance.py "$rtoy" tests/conformance/toy-rust.json || fail "conformance: the Rust toy"
python3 tests/conformance.py "$CARGO_TARGET_DIR/release/examples/clean" tests/conformance/clean-rust.json \
    || fail "conformance: the Rust sensor with tables"
python3 tests/conformance.py "$CARGO_TARGET_DIR/release/examples/replace" tests/conformance/replace-rust.json \
    || fail "conformance: the Rust sensor that replaces its partitions"

# Side by side under one scheduler, in a database of their own.
db=morca_side_by_side
q "DROP DATABASE IF EXISTS $db" > /dev/null
q "CREATE DATABASE $db" > /dev/null
MORCA_DATABASE_URL=$(echo "$MORCA_DATABASE_URL" | sed "s|///morca?|///$db?|")
export MORCA_DATABASE_URL
export MORCA_LOGS=$PWD/build/rust-sdk/logs MORCA_STALE_SECONDS=2
rm -rf "$MORCA_LOGS"
# `<binary> sample` runs the morca on the path.
PATH=$PWD/build:$PATH
export PATH
settle() {
    i=0
    while [ "$(q "SELECT count(*) FROM orca.runs WHERE status IN ('queued', 'running')")" -gt 0 ]; do
        i=$((i + 1))
        [ "$i" -lt 600 ] || fail "runs didn't finish: $(q "SELECT id, pipeline, status FROM orca.runs")"
        sleep 0.1
    done
}
# The scheduler's clock stands at 03:00 on 2024-02-02, when both fire.
export MORCA_NOW=2024-02-02T03:00Z
MORCA_NOW=2024-01-15T00:00Z ./build/morca register ./build/rust-sdk/toy >> "$log" 2>&1 || fail "register the Mojo toy"
MORCA_NOW=2024-01-15T00:00Z ./build/morca register --placement control "$rtoy" >> "$log" 2>&1 \
    || fail "register the Rust toy"
./build/morca scheduler >> "$log" 2>&1 &
sched=$!
i=0
until [ "$(q "SELECT count(*) FROM orca.runs WHERE trigger = 'schedule'")" -eq 2 ]; do
    i=$((i + 1)); [ "$i" -lt 300 ] || fail "the schedule didn't fire both"; sleep 0.1
done
settle
for p in toy toy_rust; do
    [ "$(q "SELECT count(*) FROM orca.runs WHERE pipeline = '$p' AND partitions = '2024-01' AND status = 'succeeded' AND trigger = 'schedule'")" -eq 1 ] \
        || fail "$p's scheduled run for 2024-01 didn't succeed: $(q "SELECT id, status, error FROM orca.runs WHERE pipeline = '$p'")"
done
for p in toy toy_rust; do
    ./build/morca backfill "$p" 2024-02..2024-04 >> "$log" 2>&1 || fail "backfill $p"
done
sleep 0.5
settle
for p in toy toy_rust; do
    n=$(q "SELECT count(*) FROM orca.runs WHERE pipeline = '$p' AND status = 'succeeded'")
    [ "$n" -eq 4 ] || fail "$p has $n succeeded runs, not 4: $(q "SELECT id, partitions, status, error FROM orca.runs WHERE pipeline = '$p'")"
done
first=$(q "SELECT min(id) FROM orca.runs WHERE pipeline = 'toy_rust'")
# The scheduler hands a control run's output to the binary's keep-log once
# its process has ended.
i=0
until [ -s "$MORCA_LOGS/toy_rust/$first/driver.log" ]; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "no driver log for control run $first (keep-log)"; sleep 0.1
done
kill "$sched" 2> /dev/null || true
wait "$sched" 2> /dev/null || true
[ "$(q "SELECT count(*) FROM orca.runs WHERE status <> 'succeeded'")" -eq 0 ] || fail "a run didn't succeed"
[ "$(q "SELECT DISTINCT placement FROM orca.runs WHERE pipeline = 'toy_rust'")" = control ] \
    || fail "the Rust toy's runs weren't placed on the control host"
grep -q "^--- start " "$MORCA_LOGS/toy_rust/$first/driver.log" || fail "the driver log has no start line"
[ -s "$MORCA_LOGS/toy_rust/$first/measure/2024-01/1.log" ] || fail "no attempt log for run $first"
echo "--- morca status"
./build/morca status | tee -a "$log"
./build/morca status | grep -q "^toy_rust .*last run [0-9]* succeeded" || fail "status doesn't list the Rust toy"
./build/morca status | grep -q "^toy .*last run [0-9]* succeeded" || fail "status doesn't list the Mojo toy"
echo "--- runs"
q "SELECT id, pipeline, partitions, trigger, status, placement FROM orca.runs ORDER BY id" | tee -a "$log"

free_port port
base="http://127.0.0.1:$port"
MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
ui=$!
i=0
until curl -fs "$base/" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
done
for p in toy toy_rust; do
    curl -fsS -H 'Accept: application/json' "$base/pipelines/$p" > "build/rust-sdk/$p.json" || fail "GET /pipelines/$p"
done
for p in toy toy_rust; do
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert [s["name"] for s in d["steps"]] == ["days", "measure", "total"], d["steps"]
assert d["pipeline"]["last_run"]["status"] == "succeeded", d["pipeline"]["last_run"]
assert len(d["runs"]) == 4 and all(r["status"] == "succeeded" for r in d["runs"]), d["runs"]
print("  /pipelines/%s: steps %s, %d runs succeeded, placement %s" % (d["pipeline"]["name"],
      ",".join(s["name"] for s in d["steps"]), len(d["runs"]), d["pipeline"]["placement"]))
' "build/rust-sdk/$p.json" || fail "/pipelines/$p's JSON"
done
curl -fsS "$base/pipelines/toy_rust" | grep -q "measure" || fail "the Rust toy's page doesn't show its steps"
curl -fsS "$base/runs/$first" | grep -q "succeeded" || fail "run $first's page"
curl -fsS "$base/runs" > build/rust-sdk/runs.html || fail "GET /runs"
for p in toy toy_rust; do
    grep -q "/pipelines/$p\"" build/rust-sdk/runs.html || fail "/runs doesn't list $p's runs"
done
kill "$ui" 2> /dev/null || true
ui=
echo "ok   the Mojo toy and the Rust toy ran side by side under one scheduler (status, /runs and their pages)"
