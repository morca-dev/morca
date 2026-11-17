#!/bin/sh
# Hourly partitions (morca.hour, morca.partitions.Hourly): a `*/5 * * * *`
# schedule with fire=Current runs the hour its fire falls in, again on each
# fire once the hour's last run has ended; backfills take hour ranges; the
# coverage calendar is a day of hours. Needs MORCA_DATABASE_URL (pixi run
# test-hourly starts a throwaway server), curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build
scripts/pipelines.sh hourly
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca

log=build/hourly.log
: > "$log"
ui=
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    [ -z "$ui" ] || kill "$ui" 2> /dev/null || true
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -qAtc "$1"; }
settle() {
    i=0
    while [ "$(q "SELECT count(*) FROM orca.runs WHERE status IN ('queued', 'running')")" -gt 0 ]; do
        MORCA_NOW="$1" ./build/morca tick >> "$log" 2>&1
        i=$((i + 1)); [ "$i" -lt 300 ] || fail "runs didn't finish"; sleep 0.2
    done
}
runs() { q "SELECT string_agg(partitions, ' ' ORDER BY id) FROM orca.runs WHERE pipeline = 'hourly'"; }

out=$(MORCA_NOW=2024-03-01T10:02Z ./build/morca register ./build/hourly 2>&1) || fail "register: $out"
echo "$out" >> "$log"
[ "$(q "SELECT describe->'partitions'->>'kind' FROM orca.pipelines WHERE name = 'hourly'")" = hourly ] \
    || fail "not registered as hourly"
# Twelve fires an hour for one partition: warned of.
echo "$out" | grep -q "fires more than once for 2024-03-01T1" || fail "no warning: $out"

# 10:05 fires for 10:00-11:00.
MORCA_NOW=2024-03-01T10:05Z ./build/morca tick >> "$log" 2>&1 || fail "tick 10:05"
[ "$(runs)" = "2024-03-01T10" ] || fail "the 10:05 fire's run: $(runs)"
settle 2024-03-01T10:05Z
[ "$(q "SELECT status FROM orca.runs WHERE pipeline = 'hourly'")" = succeeded ] || fail "the run didn't succeed"

# 10:10 runs the same hour again; 11:00 the next one.
MORCA_NOW=2024-03-01T10:10Z ./build/morca tick >> "$log" 2>&1 || fail "tick 10:10"
settle 2024-03-01T10:10Z
MORCA_NOW=2024-03-01T11:00Z ./build/morca tick >> "$log" 2>&1 || fail "tick 11:00"
settle 2024-03-01T11:00Z
[ "$(runs)" = "2024-03-01T10 2024-03-01T10 2024-03-01T11" ] || fail "runs: $(runs)"

# A backfill over hours skips the done ones.
MORCA_NOW=2024-03-01T11:30Z ./build/morca backfill hourly 2024-03-01T08..2024-03-01T11 >> "$log" 2>&1 \
    || fail "backfill"
[ "$(runs)" = "2024-03-01T10 2024-03-01T10 2024-03-01T11 2024-03-01T08 2024-03-01T09" ] \
    || fail "backfill runs: $(runs)"
settle 2024-03-01T11:30Z

# The UI's coverage: a day of hours.
free_port port
base="http://127.0.0.1:$port"
MORCA_NOW=2024-03-01T11:30Z MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
ui=$!
i=0
until curl -fs "$base/" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
done
cal=$(curl -fs "$base/pipelines/hourly/calendar?month=2024-03-01") || fail "calendar"
echo "$cal" | jq -e '.unit == "hour" and (.cells | length) == 24' > /dev/null || fail "calendar: $cal"
echo "$cal" | jq -e '[.cells[] | select(.state == "done") | .key]
    == ["2024-03-01T08", "2024-03-01T09", "2024-03-01T10", "2024-03-01T11"]' > /dev/null \
    || fail "done hours: $cal"
page=$(curl -fs "$base/pipelines/hourly?tab=operate") || fail "pipeline page"
echo "$page" | grep -q 'Hours of hourly' || fail "no hours on the coverage card"
kill "$ui"
wait "$ui" 2> /dev/null || true
ui=
echo "ok   hourly: */5 fires run the current hour, backfills take hour ranges, coverage is a day of hours"
