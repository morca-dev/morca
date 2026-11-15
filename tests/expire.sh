#!/bin/sh
# Snapshot expiry (morca expire, morca_maintain, the scheduler's sweep) over
# two pipelines on warehouse tables (tests/expire/): ingest writes
# lake.events a month at a time and asks for two snapshots of history
# (ensure_table properties); count reads it and writes lake.counts.
#
# - ensure_table gave both tables morca's defaults: old metadata files
#   deleted after commit, a hundred kept, thirty days of history;
# - a count run that can still resume (failed) keeps the lake.events
#   snapshot it read, however old: `morca expire` retains it;
# - the last ingest run's snapshots survive, the ones between go, and the
#   rows are all still there;
# - `morca tick` sweeps every dataset by its own policy, and leaves
#   lake.counts (thirty days) alone;
# - the snapshot a run read is still in morca lineage once it's expired;
# - morca_maintain expires through liblake (#471): it has none of
#   iceberg's code, and decides as the -D MORCA_LAKE_SOURCE=1 build does.
#
# Needs MORCA_DATABASE_URL (pixi run -e data test-expire starts a throwaway
# server) and jq.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
pids=
for p in ingest count; do
    # shellcheck disable=SC2086
    scripts/mojo-build.sh -I src -I tests/expire -I tests/lineage $DEP_INC "tests/expire/$p.mojo" -o "build/ex-$p" &
    pids="$pids $!"
done
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca &
pids="$pids $!"
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/morca_maintain.mojo -o build/morca_maintain &
pids="$pids $!"
# shellcheck disable=SC2086
scripts/mojo-build.sh -D MORCA_LAKE_SOURCE=1 -I src $DEP_INC bin/morca_maintain.mojo -o build/morca_maintain-source &
for pid in $pids $!; do wait "$pid"; done
log=build/expire.log
: > "$log"
export MORCA_WAREHOUSE=build/expire-wh
rm -rf "$MORCA_WAREHOUSE"
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
meta() { ls "$MORCA_WAREHOUSE/lake/$1/metadata/"*.metadata.json | sort | tail -1; }
snapshots() { jq -r '[.snapshots[]."snapshot-id"] | join(" ")' "$(meta "$1")"; }
nsnap() { jq '.snapshots | length' "$(meta "$1")"; }
rows() {
    jq -r '."current-snapshot-id" as $c | .snapshots[] | select(."snapshot-id" == $c) | .summary["total-records"]' "$(meta "$1")"
}

./build/morca register ./build/ex-ingest ./build/ex-count >> "$log" 2>&1 || fail "register"
for m in 2024-01 2024-02 2024-03; do
    ./build/ex-ingest run --partitions $m >> "$log" 2>&1 || fail "ingest $m"
done
./build/ex-count run --partitions 2024-01 >> "$log" 2>&1 || fail "count 2024-01"
P=$(q "SELECT snapshot_id FROM orca.reads WHERE dataset = 'lake.events' ORDER BY attempt DESC LIMIT 1")
[ -n "$P" ] || fail "count recorded no read of lake.events"
# As if it had failed after reading: a run that can still resume.
q "UPDATE orca.runs SET status = 'failed' WHERE pipeline = 'count'" > /dev/null
for m in 2024-04 2024-05 2024-06 2024-07; do
    ./build/ex-ingest run --partitions $m >> "$log" 2>&1 || fail "ingest $m"
done
[ "$(nsnap events)" -eq 7 ] || fail "lake.events has $(nsnap events) snapshots, not 7"

# morca's defaults, and the pipeline's own policy, on the table.
props=$(jq -c '.properties' "$(meta events)")
echo "$props" | jq -e '."write.metadata.delete-after-commit.enabled" == "true"
    and ."write.metadata.previous-versions-max" == "100"
    and ."history.expire.max-snapshot-age-ms" == "0"
    and ."history.expire.min-snapshots-to-keep" == "2"' > /dev/null || fail "lake.events properties: $props"
jq -e '.properties."history.expire.max-snapshot-age-ms" == "2592000000"' "$(meta counts)" > /dev/null \
    || fail "lake.counts hasn't the thirty-day default: $(jq -c .properties "$(meta counts)")"

# A dry run decides and changes nothing.
out=$(./build/morca expire lake.events --older-than 0s --keep 1 --dry-run) || fail "morca expire --dry-run: $out"
echo "$out" >> "$log"
echo "$out" | grep -q "^dry run lake.events: snapshots 7 -> 2 (5 expired" || fail "dry run: $out"
[ "$(nsnap events)" -eq 7 ] || fail "a dry run expired something"
# The library's expiry decides as the compiled-in code does, and only the
# compiled-in build has iceberg's code (see tests/lake.sh).
dry() { "./build/$1" expire lake.events --older-than 0s --keep 1 --dry-run --report | sed 's/; [0-9.e-]* s$//'; }
lib_out=$(dry morca_maintain) || fail "morca_maintain --dry-run: $lib_out"
src_out=$(dry morca_maintain-source) || fail "morca_maintain-source --dry-run: $src_out"
[ "$lib_out" = "$src_out" ] || fail "the library's expiry differs from the compiled-in code's:
  $lib_out
  $src_out"
iceberg_fns() { nm "$1" | awk '$3 ~ /^_?iceberg::/' | wc -l; }
[ "$(iceberg_fns build/morca_maintain)" -eq 0 ] || fail "build/morca_maintain links iceberg's code"
[ "$(iceberg_fns build/morca_maintain-source)" -gt 0 ] || fail "-D MORCA_LAKE_SOURCE=1 didn't compile the library's code in"

# The real one keeps the current snapshot (it is the last run's only one)
# and the snapshot the failed count run read.
out=$(./build/morca expire lake.events --older-than 0s --keep 1 --report) || fail "morca expire: $out"
echo "$out" >> "$log"
echo "$out" | grep -q "^expired lake.events: snapshots 7 -> 2 (5 expired)" || fail "expire: $out"
echo "$out" | grep -q "metadata files .* -> " || fail "--report counts no metadata files: $out"
snapshots events | tr ' ' '\n' | grep -qx "$P" || fail "the snapshot the failed run read ($P) was expired: $(snapshots events)"
[ "$(rows events)" = 21 ] || fail "lake.events has $(rows events) rows, not 21"
n=$(find "$MORCA_WAREHOUSE/lake/events/metadata" -name 'snap-*.avro' | wc -l | tr -d ' ')
[ "$n" -eq 2 ] || fail "$n manifest lists left for 2 snapshots"
./build/morca lineage lake.events "$P" > /dev/null || fail "lineage of an expired-around snapshot"

# Two more months, then the scheduler's sweep by each table's policy:
# lake.events keeps two (min-snapshots-to-keep) plus the pinned one, and
# lake.counts (thirty days) is left as it is.
for m in 2024-08 2024-09; do
    ./build/ex-ingest run --partitions $m >> "$log" 2>&1 || fail "ingest $m"
done
before_counts=$(nsnap counts)
MORCA_EXPIRE_DELAY_SECONDS=0 ./build/morca tick >> "$log" 2>&1 || fail "morca tick"
grep -q "^expired lake.events: snapshots 4 -> 3" "$log" || fail "the sweep didn't expire lake.events by its policy"
grep -q "^expired lake.counts: snapshots $before_counts -> $before_counts (0 expired" "$log" \
    || grep -q "^kept lake.counts" "$log" || fail "the sweep touched lake.counts"
snapshots events | tr ' ' '\n' | grep -qx "$P" || fail "the sweep expired the pinned snapshot"
[ "$(rows events)" = 27 ] || fail "lake.events has $(rows events) rows after the sweep, not 27"

# Once the run is done with, its snapshot can go.
q "UPDATE orca.runs SET status = 'succeeded' WHERE pipeline = 'count'" > /dev/null
out=$(./build/morca expire lake.events) || fail "morca expire by policy: $out"
echo "$out" >> "$log"
echo "$out" | grep -q "^expired lake.events: snapshots 3 -> 2" || fail "the released snapshot stayed: $out"
snapshots events | tr ' ' '\n' | grep -qx "$P" && fail "the released snapshot $P is still there"
# MORCA_EXPIRE_HOURS=0 turns the sweep off.
: > "$log"
MORCA_EXPIRE_HOURS=0 MORCA_EXPIRE_DELAY_SECONDS=0 ./build/morca tick >> "$log" 2>&1 || fail "morca tick"
grep -q "lake.events" "$log" && fail "MORCA_EXPIRE_HOURS=0 still expired"
echo "ok   expire"
