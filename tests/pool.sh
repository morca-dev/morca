#!/bin/sh
# The ec2 runner's warm pool (morca.ec2, morca.pool, MORCA_EC2_POOL_SECONDS),
# against the stand-in EC2 API (tests/fake_ec2.py), where each instance is a
# local process running its user data. With the scheduler running:
#
# - three runs of fanout, one after another, all run on the first run's head
#   and 2 workers, launched once; each run's worker logs hold its own tasks
#   only, and each instance's samples are under each run;
# - /api/fleet and /ops/pools show the idle instances as "idle (pooled)", with their idle
#   time;
# - a toy run beside them gets an instance of its own (another pipeline);
# - the idle instances shut down after MORCA_EC2_POOL_SECONDS;
# - then, with 2 worker processes per instance (--worker-procs 2), a run on
#   1 worker, then one on 3 takes the pooled head and worker and launches 2
#   more; then a run on 1 leaves the other 2 pooled until they shut down;
# - idle workers killed before a run are passed over for new ones;
# - two toy runs starting at once (max_runs=2) don't share the one pooled
#   head;
# - a pooled head handed a run that doesn't take it up (stopped) is
#   replaced by a new one, and the run succeeds;
# - with MORCA_EC2_POOL_SECONDS=0 each run gets instances of its own, which
#   shut themselves down, as before (tests/ec2.sh is all of that), and what
#   the pool had is terminated after the head's grace (MORCA_EC2_HEAD_GRACE).
#
# The pool's grace is 15 s: each hand-over below comes within a few seconds
# of the instances going idle, and a check that needs them still pooled is
# made as soon as the run that takes the others has them.
#
# Needs MORCA_DATABASE_URL (pixi run test-pool starts a throwaway server),
# python3, curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
one_cluster_test
mkdir -p build
scripts/pipelines.sh toy
scripts/pipelines.sh fanout
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca
log=build/pool.log
: > "$log"
dir=$PWD/build/fake-ec2-pool
rm -rf "$dir" build/pool-logs
mkdir -p "$dir"
free_port port
fake=
sched=
ui=
stop() {
    [ -z "$sched" ] || kill "$sched" 2> /dev/null || true
    [ -z "$ui" ] || kill "$ui" 2> /dev/null || true
    [ -z "$fake" ] || kill "$fake" 2> /dev/null || true
    sched=
    ui=
    fake=
}
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    stop
    exit 1
}
. "$PWD/tests/wait_log.sh"
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
export MORCA_RUNNER=ec2 MORCA_EC2_MODE=direct MORCA_EC2_ENDPOINT="http://127.0.0.1:$port"
export AWS_REGION=us-east-2 AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test MORCA_EC2_AMI=ami-test
export MORCA_STALE_SECONDS=10 MORCA_START_SECONDS=60
export MORCA_LOGS=$PWD/build/pool-logs MORCA_CLUSTER_LOG_SECONDS=1 MORCA_SAMPLE_SECONDS=1
export MORCA_FANOUT_SHOW_HOST=1 MORCA_FANOUT_SLEEP=0.2 MORCA_TOY_SLEEP=0
export MORCA_RUN_ENV=MORCA_FANOUT_SHOW_HOST,MORCA_FANOUT_SLEEP,MORCA_TOY_SLEEP
export MORCA_EC2_POOL_SECONDS=15
python3 tests/fake_ec2.py "$port" "$dir" >> "$log" 2>&1 &
fake=$!
i=0
until curl -s -o /dev/null "$MORCA_EC2_ENDPOINT/"; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "the stand-in EC2 didn't start"; sleep 0.1
done
ec2() { a=$1; shift; curl -s -d "Action=$a$(printf '&%s' "$@")" "$MORCA_EC2_ENDPOINT/"; }
until_true() {
    i=0
    until [ "$(q "$1")" = t ]; do
        i=$((i + 1)); [ "$i" -lt "$2" ] || fail "waited for: $1"; sleep 0.5
    done
}
scheduler() {
    [ -z "$sched" ] || { kill "$sched"; wait "$sched" 2> /dev/null || true; }
    ./build/morca scheduler >> "$log" 2>&1 &
    sched=$!
}
launches() { grep -c '"RunInstances"' "$dir/calls.jsonl" || true; }
# The RunInstances of run $1: "<role> <count>" each.
launched_for() {
    grep '"RunInstances"' "$dir/calls.jsonl" | python3 -c "
import json, sys
for line in sys.stdin:
    p = json.loads(line)['params']
    tags = {p[k]: p[k.replace('Key', 'Value')] for k in p if k.startswith('TagSpecification.1.Tag.') and k.endswith('.Key')}
    if tags.get('orca.run') == '$1':
        print(tags['orca.role'], p['MaxCount'])
"
}
ids() { q "SELECT coalesce(string_agg(id, ',' ORDER BY id), '') FROM orca.instances WHERE run = $1 AND role = '$2'"; }
done_ok() {  # waits for run $1 to end, and checks it succeeded
    until_true "SELECT status IN ('succeeded', 'failed', 'cancelled') FROM orca.runs WHERE id = $1" 360
    [ "$(q "SELECT status FROM orca.runs WHERE id = $1")" = succeeded ] || fail "run $1: $(q "SELECT status || ' ' || coalesce(error, '') FROM orca.runs WHERE id = $1")"
}
idle_ok() {  # waits for the instances run $1 ended on to be idle in the pool
    until_true "SELECT count(*) > 0 AND bool_and(idle IS NOT NULL) FROM orca.instances WHERE run = $1 AND ended IS NULL" 120
}
trips_of() {  # the tasks run $1 ran on its workers, from its workers' logs
    cat "$MORCA_LOGS/$2/$1/cluster/"worker-*.log 2> /dev/null | grep -c "^trips on" || true
}

./build/morca register --image morca:test ./build/toy >> "$log" 2>&1 || fail "register the toy"
./build/morca register --image morca:test --workers 2 ./build/fanout >> "$log" 2>&1 || fail "register fanout"
scheduler

# Three runs, one after another, on the instances the first launched.
./build/morca backfill fanout 2024-01..2024-03 >> "$log" 2>&1 || fail "backfill fanout"
r1=$(q "SELECT min(id) FROM orca.runs WHERE pipeline = 'fanout'")
r2=$((r1 + 1))
r3=$((r1 + 2))
for r in $r1 $r2 $r3; do done_ok "$r"; done
[ "$(launches)" -eq 2 ] || fail "3 runs launched: $(launched_for "$r1") / $(launched_for "$r2") / $(launched_for "$r3")"
[ "$(launched_for "$r1")" = "head 1
worker 2" ] || fail "run $r1's launches: $(launched_for "$r1")"
head=$(ids "$r1" head)
workers=$(ids "$r1" worker)
[ "$(echo "$workers" | tr ',' '\n' | wc -l | tr -d ' ')" -eq 2 ] || fail "run $r1's workers: $workers"
for r in $r2 $r3; do
    [ "$(ids "$r" head)" = "$head" ] || fail "run $r's head: $(ids "$r" head), not $head"
    [ "$(ids "$r" worker)" = "$workers" ] || fail "run $r's workers: $(ids "$r" worker), not $workers"
    [ "$(q "SELECT bool_and(pooled AND joined IS NOT NULL) FROM orca.instances WHERE run = $r")" = t ] \
        || fail "run $r's instances weren't handed over"
done
[ "$(q "SELECT string_agg(DISTINCT why, ',') FROM orca.instances WHERE run = $r1")" = "pooled: on to run $r2" ] \
    || fail "run $r1's instances ended: $(q "SELECT string_agg(DISTINCT why, ',') FROM orca.instances WHERE run = $r1")"
# Each run's worker logs: its own month's tasks, a task a day, no more;
# the last run's are complete once its instances are back in the pool.
idle_ok "$r3"
# Idle in the pool, on the fleet page (at once: the grace is short).
free_port uport
MORCA_UI_ADDR="127.0.0.1:$uport" ./build/morca ui >> "$log" 2>&1 &
ui=$!
i=0
until curl -fs "http://127.0.0.1:$uport/" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
done
curl -fsS "http://127.0.0.1:$uport/api/fleet" | jq -e '[.hosts[] | select(.state == "idle (pooled)" and .idle_seconds >= 0)] | length == 3' > /dev/null \
    || fail "/api/fleet: $(curl -fsS "http://127.0.0.1:$uport/api/fleet" | jq -c '[.hosts[] | {id, state, idle_seconds}]')"
curl -fsS "http://127.0.0.1:$uport/ops/pools?kind=ec2" | grep -q 'idle (pooled)' || fail "/ops/pools shows no idle host"
kill "$ui"
ui=
for x in "$r1 31" "$r2 29" "$r3 31"; do
    set -- $x
    [ "$(trips_of "$1" fanout)" -eq "$2" ] || fail "run $1's worker logs have $(trips_of "$1" fanout) tasks, not $2"
    wait_log "$MORCA_LOGS/fanout/$1/driver.log" "^run succeeded" || fail "run $1's driver log"
    [ "$(grep -c "^--- start" "$MORCA_LOGS/fanout/$1/driver.log")" -eq 1 ] || fail "run $1's driver log has more than its start"
    wait_log "$MORCA_LOGS/fanout/$1/cluster/head-$head.log" || fail "run $1's head log"
    for i in "head-$head" $(echo "$workers" | tr ',' '\n' | sed 's/^/worker-/'); do
        python3 tests/metrics_ok.py "$MORCA_LOGS/fanout/$1/metrics/$i.jsonl" > /dev/null || fail "run $1's metrics of $i"
    done
done
echo "ok   3 runs of fanout on one head and 2 workers, launched once, each run's logs its own"
echo "ok   /api/fleet and /ops/pools show the idle instances as idle (pooled)"

# Another pipeline: a toy run gets a head of its own.
before=$(launches)
./build/morca backfill toy 2024-01 >> "$log" 2>&1 || fail "backfill the toy"
t1=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'toy'")
done_ok "$t1"
[ "$(launched_for "$t1")" = "head 1" ] || fail "the toy's launches: $(launched_for "$t1")"
[ "$(ids "$t1" head)" != "$head" ] || fail "the toy ran on fanout's head"
[ "$(launches)" -eq $((before + 1)) ] || fail "the toy launched $(($(launches) - before))"
echo "ok   another pipeline's run doesn't take the pool's instances"

# The grace: fanout's idle instances shut down after 15 s.
until_true "SELECT bool_and(ended IS NOT NULL) FROM orca.instances WHERE run = $r3" 120
[ "$(q "SELECT string_agg(DISTINCT why, ',') FROM orca.instances WHERE run = $r3")" = "pooled: idle 15 s, shut down" ] \
    || fail "run $r3's instances ended: $(q "SELECT string_agg(DISTINCT why, ',') FROM orca.instances WHERE run = $r3")"
[ "$(q "SELECT bool_and(ended - idle >= interval '14 seconds' AND ended - idle < interval '60 seconds') FROM orca.instances WHERE run = $r3")" = t ] \
    || fail "run $r3's instances were idle: $(q "SELECT string_agg((ended - idle)::text, ',') FROM orca.instances WHERE run = $r3")"
for i in $head $(echo "$workers" | tr ',' ' '); do
    ec2 DescribeInstances Filter.1.Name=instance-id "Filter.1.Value.1=$i" | grep -q "<name>terminated</name>" || fail "$i is still up"
done
echo "ok   idle instances shut down after MORCA_EC2_POOL_SECONDS"

# 2 worker processes each, on new instances: scaling up from 1 pooled
# worker to 3; then down to 1, the other 2 left pooled.
./build/morca register --image morca:test --workers 1 --worker-procs 2 ./build/fanout >> "$log" 2>&1 \
    || fail "register fanout with 2 processes a worker"
./build/morca backfill fanout 2024-04 >> "$log" 2>&1 || fail "backfill 2024-04"
r4=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'fanout'")
done_ok "$r4"
[ "$(launched_for "$r4")" = "head 1
worker 1" ] || fail "run $r4's launches: $(launched_for "$r4")"
idle_ok "$r4"
[ "$(trips_of "$r4" fanout)" -eq 30 ] || fail "run $r4's worker logs have $(trips_of "$r4" fanout) tasks"
./build/morca register --image morca:test --workers 3 ./build/fanout >> "$log" 2>&1 || fail "register fanout on 3"
./build/morca backfill fanout 2024-05 >> "$log" 2>&1 || fail "backfill 2024-05"
r5=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'fanout'")
done_ok "$r5"
[ "$(launched_for "$r5")" = "worker 2" ] || fail "run $r5's launches: $(launched_for "$r5")"
[ "$(ids "$r5" head)" = "$(ids "$r4" head)" ] || fail "run $r5's head isn't run $r4's"
w4=$(ids "$r4" worker)
echo ",$(ids "$r5" worker)," | grep -q ",$w4," || fail "run $r5's workers $(ids "$r5" worker) don't include $w4"
[ "$(q "SELECT count(*) FROM orca.instances WHERE run = $r5 AND role = 'worker' AND procs = 2")" -eq 3 ] \
    || fail "run $r5's workers' processes"
idle_ok "$r5"
./build/morca register --image morca:test --workers 1 ./build/fanout >> "$log" 2>&1 || fail "register fanout on 1"
before=$(launches)
./build/morca backfill fanout 2024-06 >> "$log" 2>&1 || fail "backfill 2024-06"
r6=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'fanout'")
# Once run r6 has its head and worker, the other 2 are still in the pool.
until_true "SELECT count(*) = 2 AND bool_and(joined IS NOT NULL) FROM orca.instances WHERE run = $r6" 120
[ "$(q "SELECT count(*) FROM orca.instances WHERE run = $r5 AND role = 'worker' AND why IS NULL AND idle IS NOT NULL")" -eq 2 ] \
    || fail "run $r5's 2 other workers aren't pooled: $(q "SELECT string_agg(coalesce(why, 'up'), ',') FROM orca.instances WHERE run = $r5")"
[ "$(trips_of "$r5" fanout)" -eq 31 ] || fail "run $r5's worker logs have $(trips_of "$r5" fanout) tasks"
grep -q "^== morca-$r5-1-worker-$w4.log.p2 ==" "$MORCA_LOGS/fanout/$r5/cluster/worker-$w4.log" \
    || fail "run $r5's log of $w4: $(head -3 "$MORCA_LOGS/fanout/$r5/cluster/worker-$w4.log")"
done_ok "$r6"
[ "$(launches)" -eq "$before" ] || fail "run $r6 launched: $(launched_for "$r6")"
until_true "SELECT bool_and(ended IS NOT NULL AND why = 'pooled: idle 15 s, shut down') FROM orca.instances WHERE run = $r5 AND role = 'worker' AND why <> 'pooled: on to run $r6'" 120
echo "ok   with 2 processes a worker: a new registration launches anew, 1 pooled worker grows to 3, 2 stay pooled until they shut down"

# Idle workers killed: passed over for new ones; the head is still taken.
idle_ok "$r6"
killed=$(q "SELECT string_agg(id, ',') FROM orca.instances WHERE ended IS NULL AND role = 'worker' AND idle IS NOT NULL")
[ -n "$killed" ] || fail "no idle worker to kill"
for k in $(echo "$killed" | tr ',' ' '); do ec2 TerminateInstances "InstanceId.1=$k" > /dev/null; done
./build/morca backfill fanout 2024-07 >> "$log" 2>&1 || fail "backfill 2024-07"
r7=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'fanout'")
done_ok "$r7"
[ "$(launched_for "$r7")" = "worker 1" ] || fail "run $r7's launches: $(launched_for "$r7")"
for k in $(echo "$killed" | tr ',' ' '); do
    echo ",$(ids "$r7" worker)," | grep -q ",$k," && fail "run $r7 took the killed worker $k"
done
[ "$(ids "$r7" head)" = "$(ids "$r6" head)" ] || fail "run $r7 didn't take the pooled head"
echo "ok   a pooled worker killed while idle isn't handed out; a new one is launched"

# Two toy runs at once, one pooled head between them. The toy's sleep is
# in its instances' environment, so it's set before the run that fills the
# pool: a run with another environment wouldn't take its head.
export MORCA_TOY_SLEEP=2
scheduler
./build/morca backfill toy 2024-02 >> "$log" 2>&1 || fail "backfill the toy's 2024-02"
t2=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'toy'")
done_ok "$t2"
idle_ok "$t2"
./build/morca backfill toy 2024-03..2024-04 >> "$log" 2>&1 || fail "backfill the toy's 2024-03..04"
t4=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'toy'")
t3=$((t4 - 1))
done_ok "$t3"
done_ok "$t4"
[ "$(q "SELECT count(*) FROM orca.runs a JOIN orca.runs b ON a.id = $t3 AND b.id = $t4 WHERE a.started < b.ended AND b.started < a.ended")" -eq 1 ] \
    || fail "runs $t3 and $t4 didn't run at once"
h3=$(ids "$t3" head)
h4=$(ids "$t4" head)
[ "$h3" != "$h4" ] || fail "runs $t3 and $t4 shared head $h3"
[ "$(q "SELECT count(*) FROM orca.instances WHERE run IN ($t3, $t4) AND pooled")" -eq 1 ] \
    || fail "runs $t3 and $t4: not one pooled head"
echo ",$h3,$h4," | grep -q ",$(ids "$t2" head)," || fail "neither took run $t2's head"
echo "ok   two runs starting at once don't share a pooled instance"

# A pooled head that doesn't take its run up (stopped) is replaced.
idle_ok "$t3"
idle_ok "$t4"
export MORCA_EC2_POOL_LIVE_SECONDS=600 MORCA_EC2_POOL_JOIN_SECONDS=4
scheduler
for h in $h3 $h4; do
    pid=$(pgrep -f "$dir/$h.sh" | head -1)
    [ -n "$pid" ] || fail "no process for $h"
    # The instance's whole process group (dash's kill takes no group).
    python3 -c 'import os, signal, sys; os.killpg(os.getpgid(int(sys.argv[1])), signal.SIGSTOP)' "$pid"
done
./build/morca backfill toy 2024-05 >> "$log" 2>&1 || fail "backfill the toy's 2024-05"
t5=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'toy'")
done_ok "$t5"
q "SELECT why FROM orca.instances WHERE run = $t5 AND pooled" | grep -q "^pooled: never took the run up$" \
    || fail "run $t5's pooled head: $(q "SELECT string_agg(id || ' ' || coalesce(why, 'up'), ',') FROM orca.instances WHERE run = $t5")"
[ "$(launched_for "$t5")" = "head 1" ] || fail "run $t5's launches: $(launched_for "$t5")"
[ "$(q "SELECT starts FROM orca.runs WHERE id = $t5")" -eq 1 ] || fail "run $t5 was started again"
echo "ok   a pooled head that never took its run up is replaced by a new one"

# The pool off: each run on its own instance, which shuts itself down. A
# head's grace of 15 s, not 60, for what the pool had (below).
export MORCA_EC2_POOL_SECONDS=0 MORCA_EC2_HEAD_GRACE=15
unset MORCA_EC2_POOL_LIVE_SECONDS MORCA_EC2_POOL_JOIN_SECONDS
scheduler
./build/morca backfill toy 2024-06 >> "$log" 2>&1 || fail "backfill the toy's 2024-06"
t6=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'toy'")
done_ok "$t6"
./build/morca backfill toy 2024-07 >> "$log" 2>&1 || fail "backfill the toy's 2024-07"
t7=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'toy'")
done_ok "$t7"
until_true "SELECT bool_and(ended IS NOT NULL) FROM orca.instances WHERE run IN ($t6, $t7)" 60
[ "$(ids "$t6" head)" != "$(ids "$t7" head)" ] || fail "runs $t6 and $t7 shared a head with the pool off"
[ "$(q "SELECT string_agg(why, ',') FROM orca.instances WHERE run IN ($t6, $t7)")" = "shut itself down,shut itself down" ] \
    || fail "with the pool off: $(q "SELECT string_agg(why, ',') FROM orca.instances WHERE run IN ($t6, $t7)")"
[ "$(q "SELECT count(*) FROM orca.instances WHERE run IN ($t6, $t7) AND (pool_key IS NOT NULL OR pooled)")" -eq 0 ] \
    || fail "pooled rows with the pool off"
# What the pool had is terminated as any instance of a run that ended is
# (a head after its grace).
until_true "SELECT count(*) = 0 FROM orca.instances WHERE ended IS NULL" 120
echo "ok   with the pool off, each run gets its own instance"
stop
echo "ok   pool"
