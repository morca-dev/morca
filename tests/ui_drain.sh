#!/bin/sh
# Stopping morca ui (morca.web.drain), as `docker stop` does when a deploy
# retires the old UI:
#
# - SIGTERM with a slow request in flight (its query waits on a lock this
#   test holds): new connections are refused at once, /healthz on a
#   connection kept alive from before answers 503 `draining`, the slow
#   request still gets its 200, and morca ui exits 0 soon after, well within
#   MORCA_UI_DRAIN_SECONDS;
# - SIGTERM with nothing in flight: it exits 0 at once;
# - SIGINT with a request that outlasts MORCA_UI_DRAIN_SECONDS: it exits
#   (1, the request cut) within the bound plus half a second;
# - on 2 workers (MORCA_UI_WORKERS), a new request is answered while a slow
#   one waits, both are logged, and SIGTERM still lets the slow one finish.
#
# The first three run on one worker: with several, each worker's connections
# keep being accepted until the drain stops the loop.
#
# Needs MORCA_DATABASE_URL (pixi run test-ui-drain starts a throwaway server),
# curl, and bash (its /dev/tcp holds the kept-alive connection).
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build
scripts/pipelines.sh toy
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca
log=build/ui-drain.log
: > "$log"
ui=
locker=
keep=
fail() {
    echo "FAIL: $*"
    tail -20 "$log"
    [ -z "$ui" ] || kill -9 "$ui" 2> /dev/null || true
    [ -z "$locker" ] || kill "$locker" 2> /dev/null || true
    [ -z "$keep" ] || kill "$keep" 2> /dev/null || true
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
./build/morca register ./build/toy >> "$log" 2>&1 || fail "register"

# start DRAIN_SECONDS [WORKERS]: morca ui on a free port (on 1 worker
# unless told), once it answers.
start() {
    free_port port
    base="http://127.0.0.1:$port"
    MORCA_UI_WORKERS=${2:-1} MORCA_UI_DRAIN_SECONDS=$1 MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
    ui=$!
    i=0
    until curl -fs "$base/" > /dev/null 2>&1; do
        i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
    done
}
# lock SECONDS: holds orca.runs from another session for that long, once
# the lock is taken, so a page that reads runs waits on it.
lock() {
    psql "$MORCA_DATABASE_URL" -q -c "BEGIN; LOCK TABLE orca.runs IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep($1); COMMIT;" > /dev/null 2>&1 &
    locker=$!
    i=0
    until [ "$(q "SELECT count(*) FROM pg_locks WHERE relation = 'orca.runs'::regclass AND mode = 'AccessExclusiveLock' AND granted")" = 1 ]; do
        i=$((i + 1)); [ "$i" -lt 100 ] || fail "the lock wasn't taken"; sleep 0.05
    done
}
# slow: GET /runs in the background, its status in build/ui-drain-slow.txt,
# once morca ui's query waits on the lock.
slow() {
    rm -f build/ui-drain-slow.txt
    curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$base/runs" > build/ui-drain-slow.txt 2>&1 &
    slow_curl=$!
    i=0
    until [ "$(q "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock'")" -ge 1 ]; do
        i=$((i + 1)); [ "$i" -lt 100 ] || fail "the slow request never waited"; sleep 0.05
    done
}
# keepalive: opens a connection to morca ui and sends GET /healthz on it,
# then again on the same connection once build/ui-drain-again exists;
# what comes back, until morca ui closes it, is in build/ui-drain-keep.txt.
# Returns once the first answer is in.
keepalive() {
    rm -f build/ui-drain-again build/ui-drain-keep.txt
    : > build/ui-drain-keep.txt
    bash -c '
        exec 3<> "/dev/tcp/127.0.0.1/$1" || exit 1
        cat <&3 > build/ui-drain-keep.txt &
        req="GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        printf "$req" >&3
        i=0
        until [ -e build/ui-drain-again ]; do
            i=$((i + 1)); [ "$i" -lt 300 ] || exit 1; sleep 0.1
        done
        printf "$req" >&3
        wait
    ' keepalive "$port" &
    keep=$!
    i=0
    until grep -q "^ok" build/ui-drain-keep.txt; do
        i=$((i + 1)); [ "$i" -lt 100 ] || fail "no answer on the kept-alive connection"; sleep 0.05
    done
}
# stopped TENTHS: waits up to that many tenths of a second for morca ui to
# exit; sets $took (tenths) and $code.
stopped() {
    took=0
    while kill -0 "$ui" 2> /dev/null; do
        took=$((took + 1))
        [ "$took" -le "$1" ] || fail "morca ui still running after $took tenths of a second"
        sleep 0.1
    done
    code=0
    wait "$ui" || code=$?
    ui=
}

# A slow request in flight, and a connection kept alive from before.
start 5
keepalive
grep -q "^HTTP/1.1 200" build/ui-drain-keep.txt || fail "/healthz before the drain: $(head -1 build/ui-drain-keep.txt)"
lock 2
slow
kill -TERM "$ui"
sleep 0.3
new=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$base/" 2> /dev/null || true)
[ "$new" = 000 ] || fail "a new connection after SIGTERM got $new"
# Read once the slow request is done, as the handler runs on the loop's
# thread; answered before the drain settles.
touch build/ui-drain-again
stopped 45
[ "$code" = 0 ] || fail "exited $code after draining"
wait "$keep" || true
keep=
statuses=$(grep "^HTTP/1.1 " build/ui-drain-keep.txt | cut -d' ' -f2 | tr -d '\r' | tr '\n' ' ')
[ "$statuses" = "200 503 " ] || fail "/healthz on the kept-alive connection got $statuses"
grep -q "^draining" build/ui-drain-keep.txt || fail "no draining body: $(cat build/ui-drain-keep.txt)"
wait "$slow_curl" || true
[ "$(cat build/ui-drain-slow.txt)" = 200 ] || fail "the request in flight got $(cat build/ui-drain-slow.txt)"
wait "$locker" || true
locker=
grep -q "morca ui: stopping: no new connections; waiting up to 5 s for 1 request(s) in flight" "$log" \
    || fail "no drain message"
grep -q "morca ui: stopped" "$log" || fail "no stopped message"

# Nothing in flight: at once.
start 5
curl -fs "$base/runs" > /dev/null || fail "GET /runs"
kill -TERM "$ui"
stopped 10
[ "$code" = 0 ] || fail "exited $code with nothing in flight"

# A request that outlasts the drain: the bound holds.
start 1
lock 6
slow
kill -INT "$ui"
stopped 25
[ "$code" = 1 ] || fail "exited $code with a request cut"
grep -q "a request is still running: exiting without it" "$log" || fail "no message for the cut request"
kill "$locker" 2> /dev/null || true
wait "$locker" 2> /dev/null || true
locker=
wait "$slow_curl" 2> /dev/null || true
# Two workers: a request gets its answer while the other waits on the lock.
start 5 2
grep -q "morca ui on http://127.0.0.1:$port (2 workers)" "$log" || fail "no 2 workers message"
lock 3
slow
fast=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 2 "$base/static/morca.css" 2> /dev/null || true)
[ "${fast% *}" = 200 ] || fail "a request beside the slow one got: $fast"
kill -TERM "$ui"
stopped 45
[ "$code" = 0 ] || fail "exited $code after draining on 2 workers"
wait "$slow_curl" || true
[ "$(cat build/ui-drain-slow.txt)" = 200 ] || fail "the slow request on 2 workers got $(cat build/ui-drain-slow.txt)"
wait "$locker" || true
locker=
grep -Eq '^morca ui: GET /runs 200 [0-9]+ ms 127\.0\.0\.1 "curl/' "$log" || fail "/runs wasn't logged"
echo "ui drain: ok"
