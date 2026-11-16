#!/bin/sh
# A sensor whose datasets hold something it can't run doesn't stop
# (tests/fake_sensor stands in for its binary, so no warehouse is needed):
#
# - a snapshot whose morca.partitions isn't a partition key (a quarter) is
#   recorded as seen with no run and why, and a snapshot of another dataset
#   seen in the same tick still starts its run;
# - the next ticks start nothing more, and say nothing more of it;
# - a sense that fails is kept as the pipeline's sense_error, printed once
#   however many ticks see it, shown by morca ui, and cleared once sensing
#   works again.
#
# Needs MORCA_DATABASE_URL (pixi run test-sense-errors starts a throwaway
# server), curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca
log=build/sense-errors.log
: > "$log"
export MORCA_SENSE_SECONDS=0 FAKE_SENSE="$PWD/build/sense-errors.txt"
rm -f "$FAKE_SENSE.fail"
ui=
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    [ -z "$ui" ] || kill "$ui" 2> /dev/null || true
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
tick() { ./build/morca tick >> "$log" 2>&1 || fail "a tick failed"; }

printf 'raw.a 1 other 2024-01\nraw.b -1 other -\n' > "$FAKE_SENSE"
./build/morca register ./tests/fake_sensor >> "$log" 2>&1 || fail "register"

# raw.a gets a snapshot another writer says holds a quarter (no partition key), raw.b a month.
printf 'raw.a 2 other 2024-Q01\nraw.b 3 other 2024-03\n' > "$FAKE_SENSE"
tick
[ "$(q "SELECT partitions FROM orca.runs WHERE pipeline = 'fake_sensor'")" = 2024-03 ] \
    || fail "raw.b@3 started no run for 2024-03: $(q "SELECT id, partitions FROM orca.runs")"
[ "$(q "SELECT run IS NULL AND error LIKE '%not a partition key: ''2024-Q01''%' FROM orca.sensed WHERE dataset = 'raw.a' AND snapshot_id = 2")" = t ] \
    || fail "raw.a@2 isn't seen with why: $(q "SELECT * FROM orca.sensed")"
[ "$(q "SELECT run IS NOT NULL AND error IS NULL FROM orca.sensed WHERE dataset = 'raw.b' AND snapshot_id = 3")" = t ] \
    || fail "raw.b@3 isn't seen with its run"
grep -q "sensed raw.a@2 for fake_sensor and ran nothing: morca: not a partition key: '2024-Q01'" "$log" \
    || fail "the unusable snapshot isn't said"
tick
tick
[ "$(q "SELECT count(*) FROM orca.runs")" -eq 1 ] || fail "more ticks started more runs"
[ "$(grep -c "raw.a@2" "$log")" -eq 1 ] || fail "raw.a@2 was said more than once"
grep -q "can't sense" "$log" && fail "a pass failed"

# A sense that fails: kept, and said once.
touch "$FAKE_SENSE.fail"
tick
tick
tick
[ "$(grep -c "fake_sensor can't sense" "$log")" -eq 1 ] || fail "the failing sense was said $(grep -c "can't sense" "$log") times"
[ "$(q "SELECT sense_error LIKE 'sense exited 1: can''t reach the warehouse%' AND sense_error_at IS NOT NULL FROM orca.pipelines WHERE name = 'fake_sensor'")" = t ] \
    || fail "sense_error: $(q "SELECT sense_error FROM orca.pipelines")"

free_port port
base="http://127.0.0.1:$port"
MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
ui=$!
i=0
until curl -fs "$base/" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
done
page=$(curl -fsS -H 'Accept: application/json' "$base/pipelines/fake_sensor") || fail "GET /pipelines/fake_sensor"
printf "%s" "$page" | jq -e '.pipeline.sense_error.error | startswith("sense exited 1")' > /dev/null || fail "the UI's sense_error: $page"
[ "$(printf "%s" "$page" | jq -c '[.not_run[] | [.dataset, .snapshot]]')" = '[["raw.a",2]]' ] || fail "the UI's snapshots not run: $page"
curl -fsS "$base/pipelines/fake_sensor" | grep -q "Snapshots not run" || fail "the page doesn't list the snapshot not run"
kill "$ui"
ui=

# Sensing again clears it.
rm "$FAKE_SENSE.fail"
tick
[ "$(q "SELECT sense_error IS NULL AND sense_error_at IS NULL FROM orca.pipelines WHERE name = 'fake_sensor'")" = t ] \
    || fail "sense_error wasn't cleared"
echo "ok   sense errors"
