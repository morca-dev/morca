#!/bin/sh
# Concurrency keys (#397), over tests/outdated_pipeline.mojo (a step that
# polls morca.outdated(), max_runs = 4) built as longpoll and longpoll2,
# on one Postgres:
#
# - without a key, longpoll's runs start side by side, as before;
# - the key is checked by `config check`, shown by `config show`, written
#   by `config export`, and needs MORCA_HANDOVER_WAIT_SECONDS: register, a
#   tick and a scheduler refuse to go without it, or with 0, a negative
#   number or not a number;
# - two schedulers at once (MORCA_OVERLAP=off), and a key shared by
#   longpoll and longpoll2 with limit 1: only one of their runs runs at a
#   time; the others are queued saying which run they wait on, in
#   `morca status`, the run's JSON and page, and the runs list;
# - with overlapping schedulers, a run of the older version sees
#   outdated(), hands over and ends, and the run waiting on the key starts
#   on the new version;
# - a run waiting on a key an outdated run holds fails at the wait limit,
#   "timed out waiting for run N (version V)", and that run runs on, its
#   heartbeat going, one start: nothing is killed.
#
# Needs MORCA_DATABASE_URL (pixi run test-concurrency starts a throwaway
# server), curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build
c1=aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111
c2=bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222
scripts/pipelines.sh --as longpoll-1 longpoll MORCA_COMMIT=$c1 &
b1=$!
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca &
b2=$!
wait "$b1"
wait "$b2"
scripts/pipelines.sh --as longpoll-2 longpoll MORCA_COMMIT=$c2
scripts/pipelines.sh --as longpoll2-1 longpoll2 MORCA_COMMIT=$c1
log=build/concurrency.log
: > "$log"
rm -rf build/concurrency-*.out build/concurrency-stop build/concurrency-project
mkdir build/concurrency-stop build/concurrency-project
out=$PWD/build/concurrency-runs.out
: > "$out"
proj=$PWD/build/concurrency-project
export MORCA_STALE_SECONDS=5 MORCA_SAMPLE_SECONDS=0 MORCA_WATCHDOG_SECONDS=0
export MORCA_NOW=2024-01-15T00:00Z MORCA_OVERLAP=off
export OUTDATED_OUT=$out OUTDATED_STOP=$PWD/build/concurrency-stop OUTDATED_HANDOVER=2024-06
export MORCA_DRAIN_SECONDS=3600 MORCA_HANDOVER_WAIT_SECONDS=600
unset MORCA_LOGS MORCA_CONFIG MORCA_CONFIG_OVERLAY
pids=
cleanup() {
    for p in $pids; do kill "$p" 2> /dev/null || true; done
}
trap cleanup EXIT
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    echo "== $out"
    cat "$out"
    for f in build/concurrency-*.out; do [ -f "$f" ] && { echo "== $f"; tail -20 "$f"; }; done
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -qAtc "$1"; }
until_() {
    t=$1; what=$2; shift 2
    i=0
    until "$@"; do
        i=$((i + 1)); [ "$i" -lt $((t * 10)) ] || fail "$what"; sleep 0.1
    done
}
is() { [ "$(q "$1")" = "$2" ]; }
said() { grep -q "$2" "build/concurrency-$1.out"; }
wrote() { grep -q "$1" "$out"; }
runs() { q "SELECT id, pipeline, partitions, status, starts, coalesce(held, ''), coalesce(error, '') FROM orca.runs ORDER BY id"; }
scheduler() {
    name=$1; shift
    env "$@" ./build/morca scheduler > "build/concurrency-$name.out" 2>&1 &
    eval "pid_$name=$!"
    pids="$pids $!"
}
stop() { touch "build/concurrency-stop/$1"; }
run_of() { q "SELECT id FROM orca.runs WHERE pipeline = '$1' AND partitions = '$2'"; }
status_of() { q "SELECT status || ' ' || starts FROM orca.runs WHERE id = $1"; }
# overlaps FROM P...: how many pairs of runs of the pipelines P, from run
# FROM on, ran at once.
overlaps() {
    from=$1; shift
    list=$(printf "'%s'," "$@")
    q "SELECT count(*) FROM orca.runs a JOIN orca.runs b ON a.id < b.id WHERE a.id >= $from AND a.pipeline IN (${list%,}) AND b.pipeline IN (${list%,}) AND a.started IS NOT NULL AND b.started IS NOT NULL AND a.started < coalesce(b.ended, now()) AND b.started < coalesce(a.ended, now())"
}
conf() {  # conf TEXT: the project's morca.toml
    printf '%s\n' "$1" > "$proj/morca.toml"
}
reg() {  # reg BINARY: registered from the project's morca.toml
    ./build/morca register --config "$proj/morca.toml" "./build/$1" >> "$log" 2>&1 \
        || fail "register $1: $(tail -3 "$log")"
}

# --- no key: runs start side by side, as before ---
conf '[pipelines.longpoll]'
reg longpoll-1
scheduler a
./build/morca backfill longpoll 2024-01..2024-02 >> "$log" 2>&1 || fail "backfill"
r1=$(run_of longpoll 2024-01)
r2=$(run_of longpoll 2024-02)
until_ 30 "the runs didn't both start: $(runs)" wrote "^run $r2 started on aaaa1111aaaa$"
until_ 30 "the runs didn't both start: $(runs)" wrote "^run $r1 started on aaaa1111aaaa$"
[ "$(overlaps 0 longpoll)" = 1 ] || fail "without a key the runs didn't run at once: $(runs)"
is "SELECT count(*) FROM orca.runs WHERE waits_on IS NOT NULL OR concurrency_key IS NOT NULL" 0 \
    || fail "a run without a key recorded one: $(runs)"
stop 2024-01
stop 2024-02
until_ 20 "the runs didn't end: $(runs)" is "SELECT count(*) FROM orca.runs WHERE status = 'succeeded'" 2
kill "$pid_a"
wait "$pid_a" 2> /dev/null || true
echo "ok   without a key, runs start side by side"

# --- the setting: checked, shown, exported, required ---
conf '[pipelines.longpoll]
concurrency = { key = "k", limit = 1 }

[pipelines.longpoll2]
concurrency = { key = "k", limit = 1 }'
./build/morca config check "$proj/morca.toml" >> "$log" 2>&1 || fail "config check"
printf '[pipelines.longpoll]\nconcurrency = { key = "k" }\n' > "$proj/bad.toml"
./build/morca config check "$proj/bad.toml" > build/concurrency-check.out 2>&1 && fail "config check took a key without a limit"
grep -q "concurrency needs both key and limit" build/concurrency-check.out || fail "config check: $(cat build/concurrency-check.out)"
env -u MORCA_HANDOVER_WAIT_SECONDS ./build/morca register --config "$proj/morca.toml" ./build/longpoll-1 > build/concurrency-reg.out 2>&1 \
    && fail "registered a key without MORCA_HANDOVER_WAIT_SECONDS"
grep -q "MORCA_HANDOVER_WAIT_SECONDS isn't set.*(longpoll declares concurrency key k)" build/concurrency-reg.out \
    || fail "register without the setting: $(cat build/concurrency-reg.out)"
is "SELECT count(*) FROM orca.pipelines WHERE concurrency_key IS NOT NULL" 0 || fail "the refused register recorded the key"
reg longpoll-1
reg longpoll2-1
is "SELECT string_agg(name || ' ' || concurrency_key || ' ' || concurrency_limit, ',' ORDER BY name) FROM orca.pipelines" \
    "longpoll k 1,longpoll2 k 1" || fail "registered: $(q "SELECT name, concurrency_key, concurrency_limit FROM orca.pipelines")"
./build/morca config show longpoll > build/concurrency-show.out 2>&1 || fail "config show"
grep -q 'concurrency.*{ key = "k", limit = 1 }' build/concurrency-show.out || fail "config show: $(cat build/concurrency-show.out)"
./build/morca config export --out - > build/concurrency-export.out 2>&1 || fail "config export"
grep -q '^concurrency = { key = "k", limit = 1 }$' build/concurrency-export.out || fail "config export: $(cat build/concurrency-export.out)"
for v in unset 0 -5 soon; do
    if [ "$v" = unset ]; then
        env -u MORCA_HANDOVER_WAIT_SECONDS ./build/morca tick > build/concurrency-tick.out 2>&1 && fail "a tick ran without the setting"
        want="isn't set"
    else
        MORCA_HANDOVER_WAIT_SECONDS=$v ./build/morca tick > build/concurrency-tick.out 2>&1 && fail "a tick ran with MORCA_HANDOVER_WAIT_SECONDS=$v"
        case $v in soon) want="isn't a number of seconds" ;; *) want="isn't above 0" ;; esac
    fi
    grep -q "MORCA_HANDOVER_WAIT_SECONDS $want.*(pipeline longpoll declares one)" build/concurrency-tick.out \
        || fail "tick with $v: $(cat build/concurrency-tick.out)"
done
env -u MORCA_HANDOVER_WAIT_SECONDS ./build/morca scheduler > build/concurrency-nolimit.out 2>&1 &
nl=$!
pids="$pids $nl"
until_ 30 "a scheduler without the setting kept going" sh -c "! kill -0 $nl 2> /dev/null"
wait "$nl" 2> /dev/null && fail "a scheduler without the setting exited 0"
grep -q "MORCA_HANDOVER_WAIT_SECONDS isn't set" build/concurrency-nolimit.out || fail "scheduler: $(cat build/concurrency-nolimit.out)"
echo "ok   the key is checked, shown and exported; register, tick and scheduler need the wait limit"

# --- two schedulers, one key across two pipelines, limit 1 ---
scheduler a
scheduler b
./build/morca backfill longpoll 2024-03..2024-04 >> "$log" 2>&1 || fail "backfill"
./build/morca backfill longpoll2 2024-05 >> "$log" 2>&1 || fail "backfill longpoll2"
r3=$(run_of longpoll 2024-03)
r4=$(run_of longpoll 2024-04)
r5=$(run_of longpoll2 2024-05)
until_ 30 "no run started: $(runs)" is "SELECT count(*) FROM orca.runs WHERE status = 'running'" 1
first=$(q "SELECT id FROM orca.runs WHERE status = 'running'")
until_ 20 "the others don't say they wait: $(runs)" \
    is "SELECT count(*) FROM orca.runs WHERE status = 'queued' AND waits_on = $first AND held LIKE 'waiting: for concurrency key k (limit 1): run $first of % holds it'" 2
sleep 3
is "SELECT count(*) FROM orca.runs WHERE status = 'running'" 1 || fail "more than one run of the key: $(runs)"
[ "$(overlaps "$r3" longpoll longpoll2)" = 0 ] || fail "runs of the key overlapped: $(runs)"
waiting=$(q "SELECT min(id) FROM orca.runs WHERE status = 'queued'")
./build/morca status "$(q "SELECT pipeline FROM orca.runs WHERE id = $waiting")" > build/concurrency-status.out 2>&1 || fail "morca status"
grep -q "^  $waiting queued .*(waiting: for concurrency key k (limit 1): run $first of .* holds it)" build/concurrency-status.out \
    || fail "morca status: $(cat build/concurrency-status.out)"
free_port port
MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
pids="$pids $!"
base="http://127.0.0.1:$port"
until_ 30 "the UI didn't answer" curl -fs "$base/" -o /dev/null
[ "$(curl -fsS -H 'Accept: application/json' "$base/runs/$waiting" | jq -r .run.waits_on)" = "$first" ] \
    || fail "the run's JSON: $(curl -fsS -H 'Accept: application/json' "$base/runs/$waiting")"
curl -fsS "$base/runs/$waiting" | grep -q "waiting: for concurrency key k (limit 1): run $first of .* holds it <a class=\"chip\" href=\"/runs/$first\">run $first</a>" \
    || fail "the run's page doesn't say what it waits on"
curl -fsS "$base/runs" | grep -q ">for run</span> <a class=\"chip\" href=\"/runs/$first\">$first</a>" \
    || fail "the runs list doesn't say what it waits on"
echo "ok   two schedulers, a key shared by two pipelines: one run at a time; the others say which run they wait on"

# Each ends in turn; the next starts only after.
for turn in 1 2 3; do
    cur=$(q "SELECT id FROM orca.runs WHERE status = 'running'")
    [ -n "$cur" ] || fail "nothing running at turn $turn: $(runs)"
    stop "$(q "SELECT partitions FROM orca.runs WHERE id = $cur")"
    until_ 20 "run $cur didn't succeed: $(runs)" is "SELECT status FROM orca.runs WHERE id = $cur" succeeded
    [ "$turn" = 3 ] || until_ 30 "the next run didn't start after $cur: $(runs)" \
        is "SELECT count(*) FROM orca.runs WHERE status = 'running'" 1
done
is "SELECT count(*) FROM orca.runs WHERE id IN ($r3, $r4, $r5) AND status = 'succeeded' AND starts = 1" 3 || fail "runs: $(runs)"
[ "$(overlaps "$r3" longpoll longpoll2)" = 0 ] || fail "runs of the key overlapped: $(runs)"
is "SELECT count(*) FROM orca.runs WHERE waits_on IS NOT NULL OR key_wait_since IS NOT NULL" 0 || fail "left waiting: $(runs)"
kill "$pid_a" "$pid_b"
wait "$pid_a" "$pid_b" 2> /dev/null || true
echo "ok   each starts once the run before it ended, never two at once"

# --- a newer version: the outdated run hands over, the next starts on it ---
export MORCA_OVERLAP=on
scheduler c
until_ 20 "c doesn't lead" said c "^morca: scheduler instance [0-9]* leads"
./build/morca backfill longpoll 2024-06 >> "$log" 2>&1 || fail "backfill"
r6=$(run_of longpoll 2024-06)
until_ 30 "run $r6 didn't start: $(runs)" wrote "^run $r6 started on aaaa1111aaaa$"
./build/morca backfill longpoll 2024-07 >> "$log" 2>&1 || fail "backfill"
r7=$(run_of longpoll 2024-07)
until_ 20 "run $r7 doesn't wait on $r6: $(runs)" is "SELECT waits_on FROM orca.runs WHERE id = $r7" "$r6"
is "SELECT key_wait_since IS NULL FROM orca.runs WHERE id = $r7" t || fail "it waits on a current run with a limit"
reg longpoll-2
until_ 20 "run $r6 didn't hand over: $(runs)" wrote "^run $r6 hands over$"
until_ 20 "run $r6 didn't succeed: $(runs)" is "SELECT status || ' ' || starts FROM orca.runs WHERE id = $r6" "succeeded 1"
until_ 30 "run $r7 didn't start on the new version: $(runs)" wrote "^run $r7 started on bbbb2222bbbb$"
is "SELECT r7.started >= r6.ended FROM orca.runs r6, orca.runs r7 WHERE r6.id = $r6 AND r7.id = $r7" t \
    || fail "run $r7 started before $r6 ended"
echo "ok   the outdated run hands over and ends; the run waiting on the key starts on the new version"

# --- the wait limit: a run waiting on an outdated run fails, that run runs on ---
# d joins and leads, so c drains and its run r7 is outdated; d's limit is 3 s.
scheduler d MORCA_HANDOVER_WAIT_SECONDS=3
until_ 20 "c didn't drain" said c "^morca: scheduler instance [0-9]* drains"
until_ 20 "run $r7 didn't see it's outdated" wrote "^run $r7 outdated=True code=bbbb2222bbbb "
./build/morca backfill longpoll 2024-08 >> "$log" 2>&1 || fail "backfill"
r8=$(run_of longpoll 2024-08)
until_ 20 "run $r8 doesn't wait on $r7 with a limit: $(runs)" \
    is "SELECT waits_on = $r7 AND key_wait_since IS NOT NULL AND held LIKE '%on older version bbbb2222bbbb: it fails if that run hasn''t ended within 3 s (MORCA_HANDOVER_WAIT_SECONDS)' FROM orca.runs WHERE id = $r8" t
h7=$(q "SELECT heartbeat FROM orca.runs WHERE id = $r7")
until_ 20 "run $r8 didn't time out: $(runs)" is "SELECT status FROM orca.runs WHERE id = $r8" failed
is "SELECT error LIKE 'timed out waiting for run $r7 (version bbbb2222bbbb)%' FROM orca.runs WHERE id = $r8" t \
    || fail "run $r8's error: $(q "SELECT error FROM orca.runs WHERE id = $r8")"
said d "^run $r8 of longpoll failed: timed out waiting for run $r7 (version bbbb2222bbbb)" || fail "d didn't say it"
sleep 2
is "SELECT status || ' ' || starts FROM orca.runs WHERE id = $r8" "failed 0" || fail "run $r8 was retried: $(runs)"
is "SELECT status || ' ' || starts FROM orca.runs WHERE id = $r7" "running 1" || fail "run $r7 isn't running on: $(runs)"
is "SELECT heartbeat > '$h7' FROM orca.runs WHERE id = $r7" t || fail "run $r7's heartbeat stopped"
# shellcheck disable=SC2154
kill -0 "$pid_c" 2> /dev/null || fail "c exited with its run going"
said c "^killed pid" && fail "c killed a run"
stop 2024-07
until_ 20 "run $r7 didn't succeed: $(runs)" is "SELECT status || ' ' || starts FROM orca.runs WHERE id = $r7" "succeeded 1"
is "SELECT count(*) FROM orca.audit WHERE run IN ($r6, $r7)" 0 || fail "audited: $(q "SELECT * FROM orca.audit")"
# shellcheck disable=SC2154
until_ 20 "c didn't exit once drained" sh -c "! kill -0 $pid_c 2> /dev/null"
echo "ok   a run waiting on an outdated run times out at the limit; that run runs on and succeeds, nothing killed"
