#!/bin/sh
# Fill requests (#465): `morca backfill --rerun --as-fill` records a re-run
# for the scheduler to run as fill runs, within the fill's limits, with
# fills off. Over examples/daily.mojo on the local runner, MORCA_NOW
# stepping time; each tick is a new process, so what a request has done
# is read back from the database every time, as after a restart:
#
# - the request queues nothing itself; its runs start inside fill_window
#   only, keys_per_run keys each, oldest first, fill_max_runs at once;
# - a backfill's queued run starts first, and the request waits for it;
# - a second request adds its new keys, one without --rerun is refused;
# - morca status and /api/pipelines/<name> show its progress;
# - it resumes after a `morca scheduler` is killed mid-run;
# - it ends once every key ran; --cancel cancels one and its runs.
#
# Needs MORCA_DATABASE_URL (pixi run test-fill-requests starts a throwaway
# server), curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build
scripts/pipelines.sh daily
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca

log=build/fill-requests.log
: > "$log"
proj=$PWD/build/fill-requests-project
rm -rf "$proj"
mkdir -p "$proj"
export MORCA_WATCHDOG_SECONDS=0 MORCA_SAMPLE_SECONDS=0 MORCA_STALE_SECONDS=2
ui=
sched=
stop() {
    [ -z "$sched" ] || kill "$sched" 2> /dev/null || true
    [ -z "$ui" ] || kill "$ui" 2> /dev/null || true
    sched=
    ui=
}
fail() {
    echo "FAIL: $*"
    tail -40 "$log"
    stop
    exit 1
}
trap stop EXIT
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
now=
tick() {
    now=$1
    MORCA_NOW="$1" ./build/morca tick >> "$log" 2>&1 || fail "tick at $1 exited $?"
}
fills() { q "SELECT coalesce(string_agg(partitions, ' ' ORDER BY id), '') FROM orca.runs WHERE pipeline = 'daily' AND trigger = 'fill'"; }
quiet() {  # until no run is running
    i=0
    while [ "$(q "SELECT count(*) FROM orca.runs WHERE status = 'running'")" -gt 0 ]; do
        i=$((i + 1)); [ "$i" -lt 600 ] || fail "runs didn't finish"; sleep 0.1
    done
}
drain() {  # drain TIME: ticks at TIME until nothing is queued or running, and no request is open
    n=0
    while :; do
        tick "$1"
        quiet
        [ "$(q "SELECT (SELECT count(*) FROM orca.runs WHERE status IN ('running', 'queued')) + (SELECT count(*) FROM orca.fill_requests WHERE ended IS NULL)")" -gt 0 ] || return 0
        n=$((n + 1)); [ "$n" -lt 50 ] || fail "runs left queued: $(q "SELECT string_agg(id || ':' || partitions || ':' || coalesce(held, ''), ' ') FROM orca.runs WHERE status = 'queued'")"
    done
}
api() {  # api FIELD: the fill's FIELD in /api/pipelines/daily, on the last tick's clock
    free_port port
    MORCA_NOW="$now" MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
    ui=$!
    i=0
    until curl -fs "http://127.0.0.1:$port/" > /dev/null 2>&1; do
        i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
    done
    got=$(curl -fsS "http://127.0.0.1:$port/api/pipelines/daily" | jq -r ".fill.$1") || fail "GET /api/pipelines/daily"
    kill "$ui" 2> /dev/null || true
    wait "$ui" 2> /dev/null || true
    ui=
    echo "$got"
}

# Fills stay off (since_registration); the request alone fills.
cat > "$proj/morca.toml" << 'EOF'
[pipelines.daily]
keys_per_run = 2
fill_max_runs = 1
fill_window = "22..6"
EOF
T0=2024-01-08T08:00Z  # 03:00 in New York: today's fire, 2024-01-07's, has passed
MORCA_NOW="$T0" ./build/morca register --config "$proj/morca.toml" ./build/daily >> "$log" 2>&1 || fail "register"
[ "$(./build/morca backfill daily 2024-01-01..2024-01-06 2>> "$log")" = "queued 3 runs" ] || fail "the first backfill"
drain "$T0"

# --- The request queues nothing; outside fill_window nothing starts ---
got=$(./build/morca backfill --rerun --as-fill daily 2024-01-01..2024-01-06 2>> "$log") || fail "the request"
case "$got" in "fill request "*" of daily: 6 keys, as fill runs (keys_per_run 2, fill_max_runs 1, 22:00–06:00 UTC)"*) ;; *) fail "the request said: $got" ;; esac
[ "$(fills)" = "" ] || fail "the request queued runs: $(fills)"
tick 2024-01-08T12:00Z
[ "$(fills)" = "" ] || fail "fill runs outside fill_window: $(fills)"
case "$(api idle)" in "outside its window"*) ;; *) fail "idle: $(api idle)" ;; esac
[ "$(api request.total) $(api request.left)" = "6 6" ] || fail "the request's progress: $(api request)"
echo "ok   a request queues nothing, and nothing starts outside fill_window"

# --- Other runs first ---
# Two runs: max_runs 1 starts one, and the other stays queued.
[ "$(./build/morca backfill daily 2024-01-07..2024-01-10 2>> "$log")" = "queued 2 runs" ] || fail "the second backfill"
export MORCA_DAILY_SLEEP=3
tick 2024-01-08T23:00Z
[ "$(fills)" = "" ] || fail "a fill run started before the queued backfill: $(fills)"
case "$(api idle)" in "waiting: 1 scheduled or backfill runs are queued"*) ;; *) fail "idle: $(api idle)" ;; esac
quiet
echo "ok   a backfill's queued run goes before the request's"

# --- keys_per_run, oldest first, fill_max_runs ---
# The backfill's last run starts, nothing else is queued, and a fill run
# starts beside it.
tick 2024-01-08T23:01Z
[ "$(fills)" = "2024-01-01,2024-01-02" ] || fail "the first fill run: $(fills)"
[ "$(q "SELECT count(*) FROM orca.runs WHERE trigger = 'fill' AND fill_request IS NOT NULL")" -eq 1 ] || fail "the run isn't the request's"
tick 2024-01-08T23:02Z
[ "$(fills)" = "2024-01-01,2024-01-02" ] || fail "more than fill_max_runs: $(fills)"
st=$(MORCA_NOW=2024-01-08T23:02Z ./build/morca status daily 2>> "$log") || fail "morca status"
echo "$st" | grep -q "fill request .* (2024-01-01..2024-01-06, rerun): 0 of 6 done, 2 running, 4 left; next: 2024-01-03,2024-01-04" \
    || fail "morca status: $st"
quiet
echo "ok   keys_per_run keys a run, oldest first, fill_max_runs at once"

# --- Merging, and a refusal ---
got=$(./build/morca backfill --rerun --as-fill daily 2024-01-05..2024-01-08 2>> "$log") || fail "the second request"
case "$got" in "added 2 keys to fill request "*" of daily (2 already in it), 8 in all"*) ;; *) fail "the merge said: $got" ;; esac
./build/morca backfill --as-fill daily 2024-01-05 >> "$log" 2>&1 && fail "a request without --rerun beside one with it"
grep -q "has fill request .* going with --rerun" "$log" || fail "no reason for the refusal"
echo "ok   a second request adds its keys; one that differs in --rerun is refused"

# --- A scheduler killed mid-run: the next one goes on ---
MORCA_NOW=2024-01-08T23:10Z ./build/morca scheduler >> "$log" 2>&1 &
sched=$!
i=0
until [ "$(q "SELECT count(*) FROM orca.runs WHERE trigger = 'fill'")" -eq 2 ]; do
    i=$((i + 1)); [ "$i" -lt 300 ] || fail "the scheduler started no fill run: $(fills)"; sleep 0.1
done
kill -9 "$sched"
wait "$sched" 2> /dev/null || true
sched=
pkill -f "build/daily" 2> /dev/null || true
[ "$(fills)" = "2024-01-01,2024-01-02 2024-01-03,2024-01-04" ] || fail "the second fill run: $(fills)"
sleep 1
sleep 2
drain 2024-01-09T00:00Z
[ "$(q "SELECT count(*) FROM orca.fill_requests WHERE ended IS NULL")" -eq 0 ] \
    || fail "the request didn't end: $(fills); $(api request)"
[ "$(q "SELECT string_agg(DISTINCT partitions, ' ' ORDER BY partitions) FROM orca.runs WHERE trigger = 'fill' AND status = 'succeeded'")" \
    = "2024-01-01,2024-01-02 2024-01-03,2024-01-04 2024-01-05,2024-01-06 2024-01-07,2024-01-08" ] \
    || fail "not every key ran: $(q "SELECT string_agg(id || ':' || partitions || ':' || status, ' ' ORDER BY id) FROM orca.runs WHERE trigger = 'fill'")"
[ "$(api request)" = null ] || fail "an ended request still shows"
echo "ok   it resumes after the scheduler is killed, and ends once every key ran"

# --- Cancelling ---
export MORCA_DAILY_SLEEP=30 MORCA_CANCEL_KILL_SECONDS=1
./build/morca backfill --rerun --as-fill daily 2024-01-01..2024-01-04 >> "$log" 2>&1 || fail "the third request"
tick 2024-01-09T01:00Z
[ "$(q "SELECT count(*) FROM orca.runs WHERE trigger = 'fill' AND status = 'running'")" -eq 1 ] || fail "no fill run going"
got=$(./build/morca backfill --cancel daily 2>> "$log") || fail "--cancel"
case "$got" in "cancelled fill request "*" of daily and 1 runs") ;; *) fail "--cancel said: $got" ;; esac
drain 2024-01-09T01:01Z
last="SELECT max(id) FROM orca.fill_requests"
[ "$(q "SELECT string_agg(partitions || ':' || status, ' ') FROM orca.runs WHERE fill_request = ($last)")" = "2024-01-01,2024-01-02:cancelled" ] \
    || fail "the cancelled request's runs: $(q "SELECT string_agg(partitions || ':' || status, ' ') FROM orca.runs WHERE fill_request = ($last)")"
[ "$(q "SELECT count(*) FROM orca.fill_requests WHERE cancelled IS NOT NULL")" -eq 1 ] || fail "the request isn't cancelled"
./build/morca backfill --cancel daily >> "$log" 2>&1 && fail "a second --cancel"
grep -q "daily has no open fill request" "$log" || fail "no reason for the second --cancel"
echo "ok   --cancel ends the request and cancels its runs"
