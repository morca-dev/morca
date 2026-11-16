#!/bin/sh
# Weekly partitions (morca.week, morca.partitions.Weekly): a Monday 06:00
# schedule with fills=Previous runs the ISO week that just ended; backfills
# take week ranges; the coverage calendar is an ISO year of weeks. Needs
# MORCA_DATABASE_URL (pixi run test-weekly starts a throwaway server), curl
# and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build
scripts/pipelines.sh weekly
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca

log=build/weekly.log
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
runs() { q "SELECT string_agg(partitions, ' ' ORDER BY id) FROM orca.runs WHERE pipeline = 'weekly'"; }

out=$(MORCA_NOW=2026-11-16T05:00Z ./build/morca register ./build/weekly 2>&1) || fail "register: $out"
echo "$out" >> "$log"
[ "$(q "SELECT describe->'partitions'->>'kind' FROM orca.pipelines WHERE name = 'weekly'")" = weekly ] \
    || fail "not registered as weekly"

# Monday 2026-11-16 06:00 fills the week that just ended, 2026-W46.
MORCA_NOW=2026-11-16T06:00Z ./build/morca tick >> "$log" 2>&1 || fail "tick W47 Monday"
[ "$(runs)" = "2026-W46" ] || fail "the first Monday's run: $(runs)"
settle 2026-11-16T06:00Z
[ "$(q "SELECT status FROM orca.runs WHERE pipeline = 'weekly'")" = succeeded ] || fail "the run didn't succeed"

# Nothing more that week; the next Monday fills W47.
MORCA_NOW=2026-11-19T12:00Z ./build/morca tick >> "$log" 2>&1 || fail "tick Thursday"
[ "$(runs)" = "2026-W46" ] || fail "a run mid-week: $(runs)"
MORCA_NOW=2026-11-23T06:00Z ./build/morca tick >> "$log" 2>&1 || fail "tick W48 Monday"
settle 2026-11-23T06:00Z
[ "$(runs)" = "2026-W46 2026-W47" ] || fail "runs: $(runs)"

# A backfill over weeks skips the done ones and refuses weeks before the start.
MORCA_NOW=2026-11-23T07:00Z ./build/morca backfill weekly 2026-W43..2026-W47 >> "$log" 2>&1 \
    || fail "backfill"
[ "$(runs)" = "2026-W46 2026-W47 2026-W43 2026-W44 2026-W45" ] \
    || fail "backfill runs: $(runs)"
settle 2026-11-23T07:00Z
if MORCA_NOW=2026-11-23T07:00Z ./build/morca backfill weekly 2026-W39 >> "$log" 2>&1; then
    fail "a week before the start was backfilled"
fi

# The UI's coverage: the 53 weeks of ISO year 2026.
free_port port
base="http://127.0.0.1:$port"
MORCA_NOW=2026-11-23T07:00Z MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
ui=$!
i=0
until curl -fs "$base/" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
done
cal=$(curl -fs "$base/pipelines/weekly/calendar?month=2026") || fail "calendar"
echo "$cal" | jq -e '.unit == "week" and .today == "2026-W48" and (.cells | length) == 53
    and .cells[52].key == "2026-W53" and .next == null and .prev == null' > /dev/null || fail "calendar: $cal"
echo "$cal" | jq -e '[.cells[] | select(.state == "done") | .key]
    == ["2026-W43", "2026-W44", "2026-W45", "2026-W46", "2026-W47"]' > /dev/null \
    || fail "done weeks: $cal"
page=$(curl -fs "$base/pipelines/weekly?tab=operate") || fail "pipeline page"
echo "$page" | grep -q 'Weeks of weekly' || fail "no weeks on the coverage card"
kill "$ui"
wait "$ui" 2> /dev/null || true
ui=
echo "ok   weekly: Monday fires run the week that ended, backfills take week ranges, coverage is a year of weeks"
