#!/bin/sh
# Containment (morca.cgroup), Linux only: a run whose step holds more than its
# cgroup's memory.max is killed by the kernel, it alone; its attempt fails
# "out of memory at <limit>"; its retry has a bigger limit and succeeds; the
# pipeline's next run starts from that limit; the run page, its JSON and
# Ops > Control's show the limits; no run cgroup or process is left; and a
# scheduler that starts removes an empty cgroup a dead one left; and a run
# held at memory.high short of memory.max is killed as out of memory; and
# one killed at its memory_gb's maximum fails, unretried; and one let offload
# to swap (MORCA_RUN_SWAP_PCT) instead succeeds and records it; and, with the
# cpu controller, a run's cgroup has its cpu.weight.
#
# The scheduler makes the cgroups under its own cgroup, which it has to be
# able to write (delegated). Where it isn't, and `sudo -n` works (GitHub's
# runners), this makes a delegated one: a cgroup under the root owned by
# this user, which this shell moves into, as systemd's Delegate=yes would.
# Elsewhere (macOS, cgroup v1, no delegation and no sudo) it says why and
# skips.
#
# Needs MORCA_DATABASE_URL (pixi run test-cgroups starts a throwaway server),
# curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"

skip() {
    echo "cgroups: skipped: $*"
    exit 0
}
[ "$(uname)" = Linux ] || skip "cgroups are Linux's ($(uname))"
grep -q '^0::' /proc/self/cgroup || skip "no cgroup v2 hierarchy (cgroup v1?)"
[ -f /sys/fs/cgroup/cgroup.controllers ] || skip "no cgroup v2 at /sys/fs/cgroup"

own=$(sed -n 's/^0:://p' /proc/self/cgroup)
made=
back=
# Whether morca, in this shell's cgroup, could make cgroups there: the files
# it writes are this user's (or root's, for root) and memory is delegated.
writable() {
    d=/sys/fs/cgroup${own%/}
    [ "$own" = / ] && d=/sys/fs/cgroup
    case "$d" in */morca) d=${d%/morca} ;; esac
    grep -qw memory "$d/cgroup.controllers" 2> /dev/null && [ -w "$d/cgroup.procs" ] \
        && [ -w "$d/cgroup.subtree_control" ] && touch "$d/cgroup.procs" 2> /dev/null
}
if ! writable; then
    if sudo -n true 2> /dev/null && grep -qw memory /sys/fs/cgroup/cgroup.subtree_control; then
        made=/sys/fs/cgroup/morca-test-$$
        sudo mkdir "$made"
        sudo chown -R "$(id -u):$(id -g)" "$made"
        back=/sys/fs/cgroup${own}
        sudo sh -c "echo $$ > $made/cgroup.procs"
        own=${made#/sys/fs/cgroup}
        echo "cgroups: made $made, delegated to $(id -un) with sudo"
    else
        skip "this shell's cgroup ($own) isn't writable, and there's no sudo to make one"
    fi
fi

mkdir -p build
scripts/pipelines.sh grower &
b1=$!
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca &
b2=$!
wait "$b1"
wait "$b2"
log=build/cgroups.log
: > "$log"
rm -f build/cgroups-*.out
export MORCA_STALE_SECONDS=5 MORCA_START_SECONDS=20 MORCA_SAMPLE_SECONDS=0 MORCA_RETRY_SECONDS=1
# A run without a request has 200 MB, and is killed past it (no margin, so
# no throttling between memory.high and memory.max); after a
# kill it asks for twice that. Its step holds 300 MiB: over the first limit,
# under the second.
export MORCA_RUN_MEMORY_MB=200 MORCA_RUN_MEMORY_MARGIN=0 MORCA_RUN_MEMORY_GROWTH=2 GROW_MB=300
pids=
sched=
cleanup() {
    for p in $pids $sched; do kill "$p" 2> /dev/null || true; done
    if [ -n "$made" ]; then
        sleep 1
        sudo sh -c "echo $$ > $back/cgroup.procs" 2> /dev/null || true
        for d in "$made"/*/; do [ -d "$d" ] && sudo rmdir "$d" 2> /dev/null; done
        sudo rmdir "$made" 2> /dev/null || echo "cgroups: $made is left"
    fi
}
trap cleanup EXIT
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    for f in build/cgroups-*.out; do [ -f "$f" ] && { echo "== $f"; tail -25 "$f"; }; done
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
until_() {
    t=$1; what=$2; shift 2
    i=0
    until "$@"; do
        i=$((i + 1)); [ "$i" -lt $((t * 10)) ] || fail "$what"; sleep 0.1
    done
}
is() { [ "$(q "$1")" = "$2" ]; }
said() { grep -q "$1" build/cgroups-sched.out; }
start_scheduler() {
    ./build/morca scheduler >> build/cgroups-sched.out 2>&1 &
    sched=$!
    until_ 20 "the scheduler didn't say whether runs get cgroups" said "morca: run cgroups"
}

free_port port
base="http://127.0.0.1:$port"
./build/morca register ./build/grower >> "$log" 2>&1 || fail "register"
MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
pids="$pids $!"
until_ 10 "morca ui didn't start" curl -fs "$base/" -o /dev/null
start_scheduler
if ! said "morca: run cgroups on"; then
    why=$(grep "morca: run cgroups" build/cgroups-sched.out | head -1)
    [ -z "$made" ] || fail "morca can't use the cgroup made for it: $why"
    skip "$why"
fi
cgbase=$(sed -n "s/^morca: run cgroups on: runs' cgroups go in //p" build/cgroups-sched.out | head -1)
echo "cgroups: runs' cgroups go in $cgbase" >> "$log"

# Killed at 200 MB, then retried at 400.
./build/morca backfill grower 2024-01 >> "$log" 2>&1 || fail "backfill 2024-01"
r1=$(q "SELECT max(id) FROM orca.runs")
until_ 120 "run $r1 didn't succeed: $(q "SELECT id, status, starts, error FROM orca.runs WHERE id = $r1")" \
    is "SELECT status FROM orca.runs WHERE id = $r1" succeeded
kill -0 "$sched" 2> /dev/null || fail "the out-of-memory kill took the scheduler with it"
# The limits go on the attempts when the process is reaped, just after.
until_ 10 "run $r1's last attempt has no limit" \
    is "SELECT count(*) FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $r1 AND a.status = 'succeeded' AND a.memory_limit_mb IS NOT NULL" 1
attempts="SELECT a.attempt, a.status, coalesce(a.memory_limit_mb, 0), coalesce(a.error, '') FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $r1 ORDER BY a.attempt"
q "$attempts" >> "$log"
first=$(q "$attempts" | head -1)
case "$first" in
    "1|failed|200|out of memory at 200 MB: "*"memory.max (200 MB)"*"its retry asks for 400 MB") ;;
    *) fail "run $r1's first attempt isn't an out-of-memory kill at 200 MB: $first" ;;
esac
last=$(q "$attempts" | tail -1)
case "$last" in
    *"|succeeded|400|") ;;
    *) fail "run $r1's last attempt didn't succeed at 400 MB: $last" ;;
esac
is "SELECT memory_raised_mb FROM orca.pipelines WHERE name = 'grower'" 400 \
    || fail "the pipeline's memory wasn't raised: $(q "SELECT memory_raised_mb FROM orca.pipelines")"
is "SELECT memory_limit_mb || ' ' || memory_max_mb FROM orca.runs WHERE id = $r1" "400 400" \
    || fail "run $r1's limit: $(q "SELECT memory_limit_mb, memory_max_mb FROM orca.runs WHERE id = $r1")"

# The next run starts from the raised value.
./build/morca backfill grower 2024-02 >> "$log" 2>&1 || fail "backfill 2024-02"
r2=$(q "SELECT max(id) FROM orca.runs")
until_ 60 "run $r2 didn't succeed: $(q "SELECT id, status, starts, error FROM orca.runs WHERE id = $r2")" \
    is "SELECT status FROM orca.runs WHERE id = $r2" succeeded
until_ 10 "run $r2's attempt has no limit" \
    is "SELECT count(*) FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $r2 AND a.memory_limit_mb = 400" 1
is "SELECT starts || ' ' || memory_limit_mb FROM orca.runs WHERE id = $r2" "1 400" \
    || fail "run $r2 didn't start at 400 MB: $(q "SELECT starts, memory_limit_mb FROM orca.runs WHERE id = $r2")"

# The pages and their JSON.
curl -fs "$base/runs/$r1" > build/cgroups-run.out || fail "GET /runs/$r1"
grep -q 'Memory limit<span class="help">' build/cgroups-run.out || fail "the run's page has no Memory limit"
grep -q '<span class="muted"> / 400 MB</span>' build/cgroups-run.out || fail "the steps table has no limit beside the peak"
curl -fs -H 'Accept: application/json' "$base/runs/$r1" > build/cgroups-run.json || fail "GET /runs/$r1 JSON"
jq -e '.run.memory_limit.limit_mb == 400 and .run.memory_limit.max_mb == 400 and .steps[0].memory_limit_mb == 400' \
    build/cgroups-run.json > /dev/null || fail "the run's JSON: $(cat build/cgroups-run.json)"
a1=$(q "SELECT a.id FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $r1 AND a.attempt = 1")
curl -fs -H 'Accept: application/json' "$base/runs/$r1/attempts/$a1" > build/cgroups-attempt.json || fail "GET the attempt's JSON"
jq -e '.attempt.memory_limit_mb == 200 and (.attempt.error | startswith("out of memory at 200 MB"))' \
    build/cgroups-attempt.json > /dev/null || fail "the attempt's JSON: $(cat build/cgroups-attempt.json)"

# Ops > Control lists a run going with its memory against its limit.
./build/morca backfill grower 2024-03 >> "$log" 2>&1 || fail "backfill 2024-03"
r3=$(q "SELECT max(id) FROM orca.runs")
until_ 30 "run $r3 didn't start" is "SELECT status FROM orca.runs WHERE id = $r3" running
# Its CPU priority (#229): with the cpu controller, its cgroup's cpu.weight is
# MORCA_RUN_CPU_WEIGHT (20), and Ops > Control says so.
cpu=
if said "morca: runs' CPU priority: cpu.weight 20"; then
    weight() {
        w=$(cat "$cgbase"/orca-run-"$r3"-*/cpu.weight 2> /dev/null | head -1)
        [ "$w" = 20 ]
    }
    until_ 10 "run $r3's cgroup has no cpu.weight 20: $(cat "$cgbase"/orca-run-"$r3"-*/cpu.weight 2> /dev/null)" weight
    cpu=' and .cpu_weight == 20 and .nice == 0'
else
    echo "cgroups: no cpu controller: $(grep "CPU priority" build/cgroups-sched.out | head -1)"
fi
until_ 20 "Ops > Control has no run $r3: $(curl -fs -H 'Accept: application/json' "$base/ops/control" | jq -c .runs)" \
    sh -c "curl -fs -H 'Accept: application/json' '$base/ops/control' | jq -e '.runs[] | select(.run == $r3 and .memory_limit_mb == 400 and .memory_max_mb == 400$cpu)' > /dev/null"
until_ 60 "run $r3 didn't succeed" is "SELECT status FROM orca.runs WHERE id = $r3" succeeded

# Nothing is left: no run's cgroup, no grower process.
until_ 10 "run cgroups are left: $(ls -d "$cgbase"/morca-run-* 2> /dev/null)" \
    sh -c "! ls -d '$cgbase'/morca-run-* > /dev/null 2>&1"
if ps -eo args | grep -q '^[^ ]*build/grower resume'; then
    fail "grower processes are left: $(ps -eo pid,args | grep 'build/grower')"
fi

# A run held at memory.high short of memory.max (a margin of 100%: 300 MB at
# a 200 MB limit is throttled, and never reaches the 400 MB kill) is killed
# after MORCA_RUN_MEMORY_HELD_SECONDS and counts as out of memory: its retry
# asks for 400 MB and succeeds. Needs the cgroup's PSI (memory.pressure).
if [ -f "$cgbase/memory.pressure" ]; then
    kill "$sched"
    wait "$sched" 2> /dev/null || true
    q "UPDATE orca.pipelines SET memory_raised_mb = NULL WHERE name = 'grower'" > /dev/null
    export MORCA_RUN_MEMORY_MARGIN=100 MORCA_RUN_MEMORY_HELD_SECONDS=3
    start_scheduler
    ./build/morca backfill grower 2024-04 >> "$log" 2>&1 || fail "backfill 2024-04"
    r4=$(q "SELECT max(id) FROM orca.runs")
    until_ 120 "run $r4 didn't succeed: $(q "SELECT id, status, starts, error FROM orca.runs WHERE id = $r4")" \
        is "SELECT status FROM orca.runs WHERE id = $r4" succeeded
    held=$(q "SELECT a.attempt || '|' || a.status || '|' || coalesce(a.error, '') FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $r4 ORDER BY a.attempt" | head -1)
    case "$held" in
        "1|failed|out of memory at 200 MB: "*"held at their cgroup's memory.high"*"its retry asks for 400 MB") ;;
        *) fail "run $r4's first attempt isn't a kill for being held at 200 MB: $held" ;;
    esac
    said "of grower run $r4 (held at its memory limit (200 MB) for 3 s)" || fail "the held kill wasn't said"
    # It waited on memory for most of those seconds, and its attempt says so.
    stalled=$(q "SELECT coalesce(a.memory_stall_full_ms, -1) FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $r4 AND a.attempt = 1")
    [ "$stalled" -ge 1000 ] || fail "run $r4's held attempt's memory stall: $stalled ms"
    export MORCA_RUN_MEMORY_MARGIN=0
    unset MORCA_RUN_MEMORY_HELD_SECONDS
else
    echo "cgroups: no memory.pressure in $cgbase: the held case is skipped"
fi

# Offload (#282): with MORCA_RUN_SWAP_PCT=100 and swap on the host, the
# grower's 300 MB at a 200 MB limit (no margin) pushes what doesn't fit to
# swap and succeeds at once, where it was killed above; its attempt records
# the swap peak, and the pages show it. Needs swap (/proc/swaps) and swap
# accounting (memory.swap.max).
if [ -n "$(awk 'NR > 1' /proc/swaps)" ] && [ -f "$cgbase/memory.swap.max" ]; then
    kill "$sched"
    wait "$sched" 2> /dev/null || true
    q "UPDATE orca.pipelines SET memory_raised_mb = NULL WHERE name = 'grower'" > /dev/null
    export MORCA_RUN_SWAP_PCT=100
    start_scheduler
    # (start_scheduler returns on the first scheduler's lines: the file is appended to.)
    until_ 20 "the scheduler didn't say runs may swap: $(grep "runs' swap" build/cgroups-sched.out)" \
        said "morca: runs' swap: memory.swap.max at 100% of each run's limit"
    ./build/morca backfill grower 2024-06 >> "$log" 2>&1 || fail "backfill 2024-06"
    r6=$(q "SELECT max(id) FROM orca.runs")
    until_ 120 "run $r6 didn't succeed: $(q "SELECT id, status, starts, error FROM orca.runs WHERE id = $r6")" \
        is "SELECT status FROM orca.runs WHERE id = $r6" succeeded
    is "SELECT starts FROM orca.runs WHERE id = $r6" 1 \
        || fail "run $r6 wasn't let offload at 200 MB: $(q "SELECT a.attempt, a.status, a.error FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $r6")"
    until_ 10 "run $r6's attempt has no limit" \
        is "SELECT count(*) FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $r6 AND a.memory_limit_mb = 200" 1
    swapped=$(q "SELECT coalesce(a.memory_swap_peak_bytes, -1) FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $r6")
    q "SELECT a.memory_swap_peak_bytes, a.memory_zswapped_peak_bytes FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $r6" >> "$log"
    # At least most of the 100 MB that didn't fit.
    [ "$swapped" -ge $((50 * 1048576)) ] || fail "run $r6's attempt's swap peak: $swapped"
    curl -fs -H 'Accept: application/json' "$base/runs/$r6" > build/cgroups-run6.json || fail "GET /runs/$r6 JSON"
    jq -e ".steps[0].memory_swap_peak_bytes == $swapped" build/cgroups-run6.json > /dev/null \
        || fail "run $r6's JSON has no swap peak: $(jq -c '.steps' build/cgroups-run6.json)"
    a6=$(q "SELECT a.id FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $r6")
    curl -fs "$base/runs/$r6/attempts/$a6" > build/cgroups-attempt6.out || fail "GET the attempt"
    grep -q 'Offloaded<span class="help">' build/cgroups-attempt6.out || fail "the attempt's page has no Offloaded"
    curl -fs "$base/runs/$r6" | grep -q ' swap</span>' || fail "the steps table has no swap beside the peak"
    kill "$sched"
    wait "$sched" 2> /dev/null || true
    unset MORCA_RUN_SWAP_PCT
    start_scheduler
else
    echo "cgroups: no swap on this host, or no memory.swap.max in $cgbase: the offload case is skipped"
fi

# Killed at the most it may ask for (memory_gb = 0.25: 256 MB, under the
# step's 300), a run fails then and there with the kill as its error: a
# retry would ask for the same and be killed again.
q "UPDATE orca.pipelines SET memory_raised_mb = NULL WHERE name = 'grower'" > /dev/null
./build/morca register --memory-gb 0.25 ./build/grower >> "$log" 2>&1 || fail "register --memory-gb 0.25"
./build/morca backfill grower 2024-05 >> "$log" 2>&1 || fail "backfill 2024-05"
r5=$(q "SELECT max(id) FROM orca.runs")
until_ 60 "run $r5 didn't fail: $(q "SELECT id, status, starts, error FROM orca.runs WHERE id = $r5")" \
    is "SELECT status FROM orca.runs WHERE id = $r5" failed
spent=$(q "SELECT starts || '|' || coalesce(error, '') FROM orca.runs WHERE id = $r5")
case "$spent" in
    "1|out of memory at 256 MB: "*"the most it may ask for"*) ;;
    *) fail "run $r5 wasn't failed by its kill at its maximum, unretried: $spent" ;;
esac
# And it stays so: no retry is scheduled (MORCA_RETRY_SECONDS is 1).
sleep 5
spent=$(q "SELECT status || '|' || starts || '|' || coalesce(retry_at::text, '') FROM orca.runs WHERE id = $r5")
[ "$spent" = "failed|1|" ] || fail "run $r5 was retried after its kill at its maximum: $spent"

# A scheduler that starts removes an empty cgroup a dead one left.
kill "$sched"
wait "$sched" 2> /dev/null || true
sched=
sh -c 'exit 0' &
dead=$!
wait "$dead"
mkdir "$cgbase/orca-run-999-1-$dead" || fail "can't make a stale cgroup in $cgbase"
start_scheduler
until_ 10 "the stale cgroup orca-run-999-1-$dead is left" sh -c "[ ! -d '$cgbase/orca-run-999-1-$dead' ]"
echo "cgroups: ok"
