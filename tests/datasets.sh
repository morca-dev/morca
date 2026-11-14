#!/bin/sh
# Datasets on steps, without tables: describe lists each step's reads and
# writes, and `morca register` refuses a pipeline that would close a cycle
# across pipelines (tests/datasets/: first reads what third writes, second
# what first writes, third what second writes), but not one that reads
# and writes one dataset. A rerun of a done key (`morca backfill --rerun`,
# `morca rerun`) of a pipeline whose steps append is refused without
# --allow-append; one whose steps replace (replacer's `replaces=`) isn't.
# Needs MORCA_DATABASE_URL (pixi run test-datasets starts a throwaway
# server) and jq.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
# The pipelines (scripts/pipelines.sh) and morca compile at once.
scripts/pipelines.sh ds-first ds-second ds-third ds-compacts ds-replacer &
pids=$!
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca &
for pid in $pids $!; do wait "$pid"; done
log=build/datasets.log
: > "$log"
fail() {
    echo "FAIL: $*"
    tail -20 "$log"
    exit 1
}

[ "$(./build/ds-second describe | jq -c '.steps[0] | [.reads, .writes]')" = '[["lake.a"],["lake.b"]]' ] \
    || fail "describe doesn't list the step's datasets"
./build/morca register ./build/ds-first ./build/ds-second ./build/ds-compacts >> "$log" 2>&1 \
    || fail "registering first, second and compacts"
if out=$(./build/morca register ./build/ds-third 2>&1); then
    fail "third, which closes a cycle, was registered"
fi
echo "$out" | grep -qF "third writes lake.c, which first reads; first writes lake.a, which second reads; second writes lake.b, which third reads" \
    || { echo "$out"; fail "the refusal doesn't name the cycle"; }
[ "$(psql "$MORCA_DATABASE_URL" -Atc "SELECT count(*) FROM orca.pipelines WHERE name = 'third'")" -eq 0 ] \
    || fail "third is in orca.pipelines"
# Registering a pipeline again, unchanged, isn't a cycle with itself.
./build/morca register ./build/ds-second >> "$log" 2>&1 || fail "registering second again"

# Reruns of a done month: first appends to lake.a, replacer replaces lake.r.
[ "$(./build/ds-replacer describe | jq -c '.steps[0] | [.writes, .replaces]')" = '[["lake.r"],["lake.r"]]' ] \
    || fail "describe doesn't list the step's replaces"
[ "$(./build/ds-first describe | jq -c '.steps[0] | has("replaces")')" = false ] \
    || fail "describe lists replaces for a step without them"
./build/morca register ./build/ds-replacer >> "$log" 2>&1 || fail "registering replacer"
./build/ds-first run --partitions 2024-01 >> "$log" 2>&1 || fail "running first"
./build/ds-replacer run --partitions 2024-01 >> "$log" 2>&1 || fail "running replacer"
if out=$(./build/morca backfill --rerun first 2024-01 2>&1); then
    fail "backfill --rerun of first, which appends, wasn't refused: $out"
fi
echo "$out" | grep -qF "rerunning 2024-01 (done) appends again to what first appended to before, duplicating those rows: step step writes lake.a. Declare a dataset in its step's replaces=" \
    || { echo "$out"; fail "the refusal doesn't say why"; }
echo "$out" | grep -qF -- "--allow-append" || fail "the refusal doesn't name --allow-append"
# --dry-run (#475) refuses it the same, and so does a request; nothing is written.
runs() { psql "$MORCA_DATABASE_URL" -Atc "SELECT (SELECT count(*) FROM orca.runs) || ' ' || (SELECT count(*) FROM orca.fill_requests)"; }
before=$(runs)
for fill in "" --as-fill; do
    # shellcheck disable=SC2086
    if dry=$(./build/morca backfill --dry-run --rerun $fill first 2024-01 2>&1); then
        fail "backfill --dry-run --rerun $fill of first wasn't refused: $dry"
    fi
    [ "$dry" = "$out" ] || fail "--dry-run --rerun $fill said '$dry', the real one '$out'"
done
dry=$(./build/morca backfill --dry-run --rerun --allow-append first 2024-01) || fail "--dry-run --allow-append exited $?"
[ "$dry" = "dry run: would queue 1 runs over 1 keys of first (keys_per_run 1); nothing queued" ] || fail "--dry-run --allow-append: $dry"
[ "$(runs)" = "$before" ] || fail "--dry-run wrote: $before, then $(runs)"
# A backfill without --rerun leaves the done month, so there's nothing to refuse.
out=$(./build/morca backfill first 2024-01 2>/dev/null) || fail "backfill of first exited $?"
[ "$out" = "queued 0 runs" ] || fail "backfill of first: $out"
out=$(./build/morca backfill --rerun --allow-append first 2024-01) || fail "backfill --rerun --allow-append exited $?"
[ "$out" = "queued 1 runs" ] || fail "backfill --rerun --allow-append: $out"
out=$(./build/morca backfill --rerun replacer 2024-01) || fail "backfill --rerun of replacer exited $?"
[ "$out" = "queued 1 runs" ] || fail "backfill --rerun of replacer: $out"
# `morca rerun` of a run whose steps append, the same.
run=$(psql "$MORCA_DATABASE_URL" -Atc "SELECT min(id) FROM orca.runs WHERE pipeline = 'first'")
if out=$(./build/morca rerun "$run" step 2>&1); then
    fail "rerun of first's run $run wasn't refused: $out"
fi
echo "$out" | grep -qF "rerunning run $run from step step appends again" || { echo "$out"; fail "the rerun refusal"; }
./build/morca rerun --allow-append "$run" step >> "$log" 2>&1 || fail "rerun --allow-append"
echo "ok   datasets"
