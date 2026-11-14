#!/bin/sh
# The watchdog (morca.watchdog, MORCA_WATCHDOG_SECONDS), over toy and fanout.
#
# Against the stand-in EC2 API (tests/fake_ec2.py), with a limit of 2
# launches an hour:
#
# - a run of fanout launches 3 instances, which trips "launches": both
#   pipelines are paused (the run going on finishes), with audit rows from
#   `watchdog`, a trip row, a red banner on /, /ops/pools and /ops/control, /watchdog,
#   /api/watchdog, `morca watchdog status`, and /metrics gauges;
# - a run queued for a paused pipeline stays queued;
# - snoozing the rule (the command, and the UI's form) is audited, and
#   unpausing then clears the banner and the gauge, and the rule doesn't
#   trip again while snoozed; a snooze can be ended.
#
# Then rows seeded in Postgres, ticked by `morca tick` with the local runner:
#
# - idle workers pause the pipeline that owns them only;
# - failing attempts pause the pipeline they belong to only;
# - a run quiet for 30 minutes on sampled instances pauses its pipeline;
# - a run waiting 10 minutes for more memory than the host grants at most
#   pauses its pipeline ("unmet", #462);
# - a cost over $3 an hour pauses everything;
# - a snoozed rule doesn't trip, a pipeline paused already isn't recorded
#   again, and with MORCA_WATCHDOG_SECONDS=0 nothing is checked.
#
# Needs MORCA_DATABASE_URL (pixi run test-watchdog starts a throwaway
# server), python3, curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
one_cluster_test
mkdir -p build
scripts/pipelines.sh toy
scripts/pipelines.sh fanout
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca
log=build/watchdog.log
: > "$log"
dir=$PWD/build/fake-ec2-watchdog
rm -rf "$dir" build/watchdog-logs
mkdir -p "$dir"
free_port port
free_port uport
base="http://127.0.0.1:$uport"
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
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
until_true() {
    i=0
    until [ "$(q "$1")" = t ]; do
        i=$((i + 1)); [ "$i" -lt "$2" ] || fail "waited for: $1"; sleep 0.5
    done
}
paused() { q "SELECT paused FROM orca.pipelines WHERE name = '$1'"; }
tripped() { curl -fsS "$base/metrics" | grep "^morca_watchdog_tripped{rule=\"$1\"}" | cut -d' ' -f2; }
export MORCA_RUNNER=ec2 MORCA_EC2_MODE=direct MORCA_EC2_ENDPOINT="http://127.0.0.1:$port"
export AWS_REGION=us-east-2 AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test MORCA_EC2_AMI=ami-test
export MORCA_STALE_SECONDS=10 MORCA_START_SECONDS=60
export MORCA_LOGS=$PWD/build/watchdog-logs MORCA_CLUSTER_LOG_SECONDS=1 MORCA_SAMPLE_SECONDS=1
export MORCA_FANOUT_SLEEP=0.2 MORCA_TOY_SLEEP=0
export MORCA_RUN_ENV=MORCA_FANOUT_SLEEP,MORCA_TOY_SLEEP
export MORCA_EC2_POOL_SECONDS=0
export MORCA_WATCHDOG_SECONDS=1 MORCA_WATCHDOG_LAUNCHES=2
python3 tests/fake_ec2.py "$port" "$dir" >> "$log" 2>&1 &
fake=$!
i=0
until curl -s -o /dev/null "$MORCA_EC2_ENDPOINT/"; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "the stand-in EC2 didn't start"; sleep 0.1
done
MORCA_UI_ADDR="127.0.0.1:$uport" ./build/morca ui >> "$log" 2>&1 &
ui=$!
i=0
until curl -fs "$base/" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
done
./build/morca register --image morca:test ./build/toy >> "$log" 2>&1 || fail "register the toy"
./build/morca register --image morca:test --workers 2 ./build/fanout >> "$log" 2>&1 || fail "register fanout"
# Nothing yet: the rules are fine and nothing is shown.
curl -fsS "$base/" | grep -q 'alert--trip' && fail "a banner with nothing tripped"
./build/morca scheduler >> "$log" 2>&1 &
sched=$!

# A launch storm.
./build/morca backfill fanout 2024-01 >> "$log" 2>&1 || fail "backfill fanout"
r1=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'fanout'")
until_true "SELECT count(*) = 2 FROM orca.pipelines WHERE paused" 120
[ "$(q "SELECT count(*) FROM orca.watchdog_trips WHERE rule = 'launches'")" -eq 1 ] || fail "the trip rows"
[ "$(q "SELECT count(*) FROM orca.audit WHERE username = 'watchdog' AND action IN ('/pipelines/toy/pause', '/pipelines/fanout/pause') AND detail LIKE 'watchdog rule launches: 3 instances launched in the last hour (limit 2)' AND source = 'watchdog'")" -eq 2 ] \
    || fail "the audit rows: $(q "SELECT username, action, detail FROM orca.audit")"
echo "ok   a launch storm pauses every pipeline, audited as watchdog"

# The run going on finishes; a new one stays queued behind the pause.
until_true "SELECT status IN ('succeeded', 'failed') FROM orca.runs WHERE id = $r1" 240
[ "$(q "SELECT status FROM orca.runs WHERE id = $r1")" = succeeded ] || fail "run $r1: $(q "SELECT status || ' ' || coalesce(error, '') FROM orca.runs WHERE id = $r1")"
./build/morca backfill toy 2024-01 >> "$log" 2>&1 || fail "backfill the toy"
sleep 4
[ "$(q "SELECT status FROM orca.runs WHERE pipeline = 'toy'")" = queued ] || fail "the toy's run isn't queued"
[ "$(q "SELECT count(*) FROM orca.watchdog_trips")" -eq 1 ] || fail "paused pipelines were recorded again"
echo "ok   a run going on finishes; a new one waits behind the pause"

# What it looks like.
for p in / /ops/pools /ops/control; do
    page=$(curl -fsS "$base$p")
    echo "$page" | grep -q 'class="alert alert--trip"' || fail "no banner on $p"
    echo "$page" | grep -q 'Watchdog paused pipelines: launches' || fail "the banner on $p names no rule"
    echo "$page" | grep -q '3 instances launched in the last hour (limit 2)' || fail "the banner on $p has no numbers"
    echo "$page" | grep -q 'href="/pipelines/fanout"' || fail "the banner on $p doesn't link fanout"
    echo "$page" | grep -q 'href="/pipelines/toy"' || fail "the banner on $p doesn't link toy"
done
curl -fsS -H 'Accept: application/json' "$base/" | jq -e '.watchdog | length == 1 and .[0].rule == "launches" and (.[0].pipelines | sort) == ["fanout", "toy"]' > /dev/null || fail "/ JSON"
curl -fsS "$base/watchdog" | grep -q 'tripped' || fail "/watchdog"
api=$(curl -fsS "$base/api/watchdog")
echo "$api" | jq -e '(.rules | map(.rule)) == ["launches", "cost", "idle", "failing", "stuck", "unmet", "control"]
    and (.rules[0] | .tripped and .value == 3 and .threshold == 2) and (.rules | map(select(.tripped)) | length) == 1' > /dev/null \
    || fail "/api/watchdog: $api"
m=$(curl -fsS "$base/metrics")
[ "$(tripped launches)" = 1 ] && [ "$(tripped cost)" = 0 ] && [ "$(tripped failing)" = 0 ] || fail "the tripped gauges: $(echo "$m" | grep watchdog_tripped)"
echo "$m" | grep -q '^morca_watchdog_value{rule="launches"} 3' || fail "the value gauge"
echo "$m" | grep -q '^morca_watchdog_threshold{rule="launches"} 2' || fail "the threshold gauge"
out=$(./build/morca watchdog status 2>&1) || fail "morca watchdog status: $out"
echo "$out" | grep -q '^launches .*TRIPPED' || fail "morca watchdog status: $out"
echo "$out" | grep -q '^trip launches at .*paused fanout toy' || fail "morca watchdog status trips: $out"
./build/morca --remote "$base" watchdog status | grep -q '^launches .*TRIPPED' || fail "morca --remote watchdog status"
./build/morca watchdog status --json | jq -e '.trips | length == 1' > /dev/null || fail "morca watchdog status --json"
echo "ok   the banner on /, /ops/pools and /ops/control, /watchdog, /metrics and the status command show the trip"

# Snoozing, and unpausing clears.
./build/morca watchdog snooze nope 1h > /dev/null 2>&1 && fail "snoozing no rule"
./build/morca watchdog snooze launches 1x > /dev/null 2>&1 && fail "snoozing for 1x"
./build/morca watchdog snooze launches 1h >> "$log" 2>&1 || fail "snooze launches"
[ "$(q "SELECT count(*) FROM orca.audit WHERE action = '/watchdog/launches/snooze' AND detail = 'duration=1h' AND source = 'local'")" -eq 1 ] || fail "the snooze isn't audited"
curl -fsS -o /dev/null -H "Origin: $base" -d duration=30m "$base/watchdog/cost/snooze" || fail "the UI's snooze"
[ "$(q "SELECT snoozed_until > now() + interval '25 minutes' AND snoozed_until < now() + interval '31 minutes' FROM orca.watchdog_rules WHERE rule = 'cost'")" = t ] || fail "the UI's snooze isn't stored"
curl -s -o /dev/null -w '%{http_code}' -H "Origin: $base" -d duration=nonsense "$base/watchdog/cost/snooze" | grep -q 409 || fail "a bad duration"
curl -fsS "$base/api/watchdog" | jq -e '(.rules[] | select(.rule == "launches") | .snoozed_until != null)' > /dev/null || fail "the snooze isn't shown"
./build/morca watchdog status | grep -q '^cost .*snoozed until' || fail "status shows no snooze"
./build/morca unpause toy > /dev/null || fail "unpause toy"
curl -fsS "$base/" | grep -q 'Paused: <a href="/pipelines/fanout">fanout</a>\. ' || fail "toy unpaused: the trip should list only fanout"
./build/morca unpause fanout > /dev/null || fail "unpause fanout"
curl -fsS "$base/" | grep -q 'alert--trip' && fail "the banner stays after unpausing"
curl -fsS "$base/ops/pools" | grep -q 'alert--trip' && fail "the banner stays on /ops/pools"
[ "$(tripped launches)" = 0 ] || fail "the gauge stays 1"
# The toy's queued run starts, and nothing pauses again while snoozed.
t1=$(q "SELECT id FROM orca.runs WHERE pipeline = 'toy'")
until_true "SELECT status IN ('succeeded', 'failed') FROM orca.runs WHERE id = $t1" 240
[ "$(q "SELECT status FROM orca.runs WHERE id = $t1")" = succeeded ] || fail "the toy's run"
[ "$(q "SELECT count(*) FROM orca.pipelines WHERE paused")" -eq 0 ] || fail "a snoozed rule paused again"
[ "$(q "SELECT count(*) FROM orca.watchdog_trips")" -eq 1 ] || fail "a snoozed rule recorded a trip"
echo "ok   snoozing is audited and stops the rule; unpausing clears the banner and the gauge"

# A snooze ended trips it again (the launches are still in the hour).
./build/morca watchdog snooze launches off >> "$log" 2>&1 || fail "snooze off"
until_true "SELECT count(*) = 2 FROM orca.pipelines WHERE paused" 60
curl -fsS "$base/" | grep -q 'alert--trip' || fail "no banner after the snooze ended"
echo "ok   a snooze that ends lets the rule trip again"

# Keep paused: acknowledging a trip hides its banner and leaves the
# pipelines paused; status still lists it, marked.
trip=$(q "SELECT max(id) FROM orca.watchdog_trips")
paused_before=$(q "SELECT count(*) FROM orca.pipelines WHERE paused")
curl -s -o /dev/null -w '%{http_code}' -H "Origin: $base" -d '' "$base/watchdog/nope/ack" | grep -q 404 || fail "a bad trip id"
curl -fsS -o /dev/null -H "Origin: $base" -d '' "$base/watchdog/all/ack" || fail "the UI's keep paused"
curl -fsS "$base/" | grep -q 'alert--trip' && fail "the banner shows an acknowledged trip"
[ "$(q "SELECT count(*) FROM orca.pipelines WHERE paused")" = "$paused_before" ] || fail "keep paused unpaused something"
[ "$(q "SELECT acknowledged_by FROM orca.watchdog_trips WHERE id = $trip")" = ui ] || fail "the trip isn't acknowledged"
./build/morca watchdog status | grep -q '^trip launches .*(acknowledged by ui)' || fail "status doesn't mark the acknowledged trip"
./build/morca watchdog status --json | jq -e '.trips | map(select(.id == '"$trip"' and .acknowledged_by == "ui")) | length == 1' > /dev/null || fail "status --json"
again=$(q "INSERT INTO orca.watchdog_trips (rule, value, threshold, detail, pipelines) VALUES ('launches', 3, 2, 'again', 'toy') RETURNING id" | head -1)
curl -fsS "$base/" | grep -q 'Keep paused' || fail "no Keep paused button on the banner"
./build/morca watchdog ack nonsense > /dev/null 2>&1 && fail "ack of nonsense"
./build/morca watchdog ack "$again" >> "$log" 2>&1 || fail "morca watchdog ack"
curl -fsS "$base/" | grep -q 'alert--trip' && fail "the banner shows a trip acknowledged by the command"
[ "$(q "SELECT count(*) FROM orca.audit WHERE action = '/watchdog/$again/ack' AND source = 'local'")" -eq 1 ] || fail "the ack isn't audited"
[ "$(q "SELECT count(*) FROM orca.pipelines WHERE paused")" = "$paused_before" ] || fail "ack unpaused something"
echo "ok   keep paused hides a trip's banner and leaves its pipelines paused"
stop
grep -q "can't check the watchdog" "$log" && fail "the watchdog raised"

# ---- Seeded rows, ticked locally ----------------------------------------
# MORCA_RUNNER unset is the local runner too, with the cost rule on; set to
# local, the cost rule is off (the last section below).
unset MORCA_RUNNER
unset MORCA_EC2_MODE MORCA_EC2_ENDPOINT MORCA_EC2_AMI MORCA_LOGS MORCA_RUN_ENV
export MORCA_WATCHDOG_LAUNCHES=1000 MORCA_STALE_SECONDS=3600
reset() {
    q "DELETE FROM orca.fleet_samples; DELETE FROM orca.instances; DELETE FROM orca.attempts WHERE host = 'seed';
       DELETE FROM orca.steps WHERE step LIKE 'seed%'; DELETE FROM orca.runs WHERE trigger = 'seed';
       DELETE FROM orca.watchdog_trips; DELETE FROM orca.watchdog_rules; DELETE FROM orca.audit;
       UPDATE orca.pipelines SET paused = false" > /dev/null
}
tick() { MORCA_WATCHDOG_SECONDS=1 ./build/morca tick >> "$log" 2>&1 || fail "tick"; }
tick_off() { MORCA_WATCHDOG_SECONDS=0 ./build/morca tick >> "$log" 2>&1 || fail "tick"; }
only() {  # the paused pipelines, comma-separated
    q "SELECT coalesce(string_agg(name, ',' ORDER BY name), '') FROM orca.pipelines WHERE paused"
}
run_of() { q "SELECT max(id) FROM orca.runs WHERE pipeline = '$1' AND trigger <> 'seed'"; }
toyrun=$(run_of toy)
fanrun=$(run_of fanout)
hash=$(q "SELECT registry_hash FROM orca.pipelines WHERE name = 'toy'")

# Off: nothing is checked, however far over.
reset
q "INSERT INTO orca.instances (id, run, start, role, instance_type, market, launched)
   SELECT 'i-seed-' || n, $fanrun, 1, 'worker', 'c7g.4xlarge', 'on-demand', now() - interval '20 minutes' FROM generate_series(1, 8) n" > /dev/null
tick_off
[ "$(only)" = "" ] || fail "paused with the watchdog off"
[ "$(q "SELECT count(*) FROM orca.watchdog_rules")" -eq 0 ] || fail "the watchdog off kept readings"
[ "$(q "SELECT count(*) FROM orca.audit")" -eq 0 ] || fail "the watchdog off audited"
echo "ok   MORCA_WATCHDOG_SECONDS=0: nothing checked, nothing paused"

# Cost: 8 x $0.58 up for 20 minutes is over $3 an hour, sustained: everything.
tick
[ "$(only)" = "fanout,toy" ] || fail "cost paused: $(only)"
[ "$(q "SELECT count(*) FROM orca.watchdog_trips WHERE rule = 'cost' AND detail LIKE 'estimated \$4.64/h, over \$3.00/h for 15 minutes%'")" -eq 1 ] \
    || fail "the cost trip: $(q "SELECT rule, detail FROM orca.watchdog_trips")"
# Up for 5 minutes only: a spike, not sustained.
reset
q "INSERT INTO orca.instances (id, run, start, role, instance_type, market, launched)
   SELECT 'i-seed-' || n, $fanrun, 1, 'worker', 'c7g.4xlarge', 'on-demand', now() - interval '5 minutes' FROM generate_series(1, 8) n" > /dev/null
tick
[ "$(only)" = "" ] || fail "a spike paused: $(only)"
# Snoozed: not even sustained.
reset
q "INSERT INTO orca.instances (id, run, start, role, instance_type, market, launched)
   SELECT 'i-seed-' || n, $fanrun, 1, 'worker', 'c7g.4xlarge', 'on-demand', now() - interval '20 minutes' FROM generate_series(1, 8) n" > /dev/null
./build/morca watchdog snooze cost 1h >> "$log" 2>&1
tick
[ "$(only)" = "" ] || fail "a snoozed rule paused: $(only)"
[ "$(q "SELECT value > 4.6 AND value < 4.7 FROM orca.watchdog_rules WHERE rule = 'cost'")" = t ] || fail "the cost reading"
echo "ok   cost: sustained over the rate pauses all; a spike or a snoozed rule doesn't"

# Idle: 4 workers of fanout idle for 10 minutes; toy's untouched.
reset
q "INSERT INTO orca.instances (id, run, start, role, instance_type, market, launched)
   SELECT 'i-seed-' || n, $fanrun, 1, 'worker', 'c7g.large', 'spot', now() - interval '20 minutes' FROM generate_series(1, 4) n;
   INSERT INTO orca.fleet_samples (host, t, cores, cpu, busiest, mem, disk, net_in, net_out)
   SELECT 'i-seed-' || n, now() - make_interval(secs => s * 30), 2, 4, 6, 30, 30, 0, 0
   FROM generate_series(1, 4) n, generate_series(0, 20) s" > /dev/null
tick
[ "$(only)" = "fanout" ] || fail "idle paused: '$(only)'"
[ "$(q "SELECT count(*) FROM orca.audit WHERE username = 'watchdog' AND action = '/pipelines/fanout/pause' AND detail LIKE 'watchdog rule idle: 4 workers averaged 4.0% CPU for 10 minutes%'")" -eq 1 ] \
    || fail "the idle audit: $(q "SELECT action, detail FROM orca.audit")"
# Busy enough, and 3 workers, don't trip.
reset
q "INSERT INTO orca.instances (id, run, start, role, instance_type, market, launched)
   SELECT 'i-seed-' || n, $fanrun, 1, 'worker', 'c7g.large', 'spot', now() - interval '20 minutes' FROM generate_series(1, 4) n;
   INSERT INTO orca.fleet_samples (host, t, cores, cpu, busiest, mem, disk, net_in, net_out)
   SELECT 'i-seed-' || n, now() - make_interval(secs => s * 30), 2, CASE WHEN n = 1 THEN 90 ELSE 4 END, 6, 30, 30, 0, 0
   FROM generate_series(1, 4) n, generate_series(0, 20) s" > /dev/null
tick
[ "$(only)" = "" ] || fail "a fleet averaging 25% paused: $(only)"
echo "ok   idle: workers under 15% CPU pause the pipeline that owns them"

# Failing: 12 attempts of toy in the last hour, 11 failed; fanout has none.
reset
q "INSERT INTO orca.steps (run, step, partition, ord, status)
   SELECT $toyrun, 'seed' || n, '', 100 + n, 'failed' FROM generate_series(1, 12) n;
   INSERT INTO orca.attempts (step, attempt, status, host, registry_hash, started, ended, error)
   SELECT s.id, 1, CASE WHEN s.step = 'seed1' THEN 'succeeded' ELSE 'failed' END, 'seed', '$hash',
          now() - interval '5 minutes', now() - interval '4 minutes', 'boom'
   FROM orca.steps s WHERE s.step LIKE 'seed%'" > /dev/null
tick
[ "$(only)" = "toy" ] || fail "failing paused: '$(only)'"
[ "$(q "SELECT detail LIKE 'toy: 11 of 1_ attempts failed in the last hour' FROM orca.watchdog_trips WHERE rule = 'failing'")" = t ] \
    || fail "the failing trip: $(q "SELECT detail FROM orca.watchdog_trips")"
# Ticking again records nothing more for a pipeline paused already.
tick
[ "$(q "SELECT count(*) FROM orca.watchdog_trips")" -eq 1 ] || fail "a trip was recorded twice"
[ "$(q "SELECT count(*) FROM orca.audit WHERE username = 'watchdog'")" -eq 1 ] || fail "audited twice"
echo "ok   failing: only the failing pipeline is paused, once"

# Stuck: a run on sampled instances, nothing moving for 40 minutes.
reset
q "INSERT INTO orca.runs (pipeline, registry_hash, partitions, trigger, status, owner, heartbeat, created, started, starts)
   VALUES ('fanout', '$hash', '2024-09', 'seed', 'running', 'seed:1', now() + interval '1 hour', now() - interval '40 minutes', now() - interval '40 minutes', 1);
   INSERT INTO orca.steps (run, step, partition, ord, status)
   SELECT max(id), 'seed-s', '', 1, 'running' FROM orca.runs WHERE trigger = 'seed';
   INSERT INTO orca.attempts (step, attempt, status, host, registry_hash, started)
   SELECT id, 1, 'running', 'seed', '$hash', now() - interval '40 minutes' FROM orca.steps WHERE step = 'seed-s';
   INSERT INTO orca.instances (id, run, start, role, instance_type, market, launched)
   SELECT 'i-seed-head', max(id), 1, 'head', 'c7g.large', 'on-demand', now() - interval '40 minutes' FROM orca.runs WHERE trigger = 'seed';
   INSERT INTO orca.fleet_samples (host, t, cores, cpu, busiest, mem, disk, net_in, net_out)
   SELECT 'i-seed-head', now() - make_interval(secs => s * 30), 2, 1, 2, 30, 30, 0, 0 FROM generate_series(0, 20) s" > /dev/null
tick
[ "$(only)" = "fanout" ] || fail "stuck paused: '$(only)'"
[ "$(q "SELECT detail LIKE 'fanout run %: no progress for 4_ minutes' FROM orca.watchdog_trips WHERE rule = 'stuck'")" = t ] \
    || fail "the stuck trip: $(q "SELECT detail FROM orca.watchdog_trips")"
# The same host busy a few minutes ago is progress.
reset
q "INSERT INTO orca.runs (pipeline, registry_hash, partitions, trigger, status, owner, heartbeat, created, started, starts)
   VALUES ('fanout', '$hash', '2024-09', 'seed', 'running', 'seed:1', now() + interval '1 hour', now() - interval '40 minutes', now() - interval '40 minutes', 1);
   INSERT INTO orca.steps (run, step, partition, ord, status)
   SELECT max(id), 'seed-s', '', 1, 'running' FROM orca.runs WHERE trigger = 'seed';
   INSERT INTO orca.attempts (step, attempt, status, host, registry_hash, started)
   SELECT id, 1, 'running', 'seed', '$hash', now() - interval '40 minutes' FROM orca.steps WHERE step = 'seed-s';
   INSERT INTO orca.instances (id, run, start, role, instance_type, market, launched)
   SELECT 'i-seed-head', max(id), 1, 'head', 'c7g.large', 'on-demand', now() - interval '40 minutes' FROM orca.runs WHERE trigger = 'seed';
   INSERT INTO orca.fleet_samples (host, t, cores, cpu, busiest, mem, disk, net_in, net_out)
   SELECT 'i-seed-head', now() - make_interval(secs => s * 30), 2, CASE WHEN s < 20 THEN 1 ELSE 80 END, 2, 30, 30, 0, 0 FROM generate_series(0, 20) s" > /dev/null
tick
[ "$(only)" = "" ] || fail "a run busy 10 minutes ago paused: $(only)"
echo "ok   stuck: a run with nothing moving pauses its pipeline; a busy host is progress"

# Control (#180): memory over its 90 with disk under its 85 pauses everything;
# status, /api/watchdog's JSON and the trip show both thresholds and that
# memory is the one that tripped.
reset
q "DELETE FROM orca.system_minutes;
   INSERT INTO orca.system_minutes (minute, n, last_t, cpu_sum, cpu_max, mem_sum, mem_max, mem_used, mem_total,
     disk_max, disk_used, disk_total, disk_path, net_in_sum, net_out_sum)
   VALUES (date_trunc('minute', now()), 1, now(), 10, 10, 98.3, 98.3, 983, 1000, 10.6, 106, 1000, '/', 0, 0)" > /dev/null
tick
[ "$(only)" = "fanout,toy" ] || fail "control paused: '$(only)'"
[ "$(q "SELECT count(*) FROM orca.watchdog_trips WHERE rule = 'control' AND detail = 'control instance memory 98.3% (limit 90%)'
        AND checks @> '[{\"name\": \"memory\", \"past\": true}, {\"name\": \"disk\", \"past\": false}]'")" -eq 1 ] \
    || fail "the control trip: $(q "SELECT detail, checks FROM orca.watchdog_trips")"
out=$(./build/morca watchdog status 2>&1) || fail "morca watchdog status: $out"
echo "$out" | grep -q '^control   memory 98.30 % (trips over 90.00, past), disk 10.60 % (trips over 85.00)  TRIPPED on memory$' \
    || fail "status doesn't show both control thresholds: $out"
./build/morca watchdog status --json | jq -e '.rules[] | select(.rule == "control") | .tripped_on == ["memory"]
    and (.checks | map(.name)) == ["memory", "disk"] and (.checks | map(.limit)) == [90, 85]' > /dev/null \
    || fail "status --json: $(./build/morca watchdog status --json)"
./build/morca watchdog status --json | jq -e '.trips[0].tripped_on == ["memory"]' > /dev/null || fail "the trip's tripped_on"
# Memory back down while the pipelines stay paused: the reading is fine,
# the trip still says memory.
q "UPDATE orca.system_minutes SET mem_sum = 10.6, mem_max = 10.6" > /dev/null
tick
echo "$(./build/morca watchdog status)" | grep -q '^control   memory 10.60 % (trips over 90.00), disk 10.60 % (trips over 85.00)  TRIPPED on memory$' \
    || fail "status after memory came down: $(./build/morca watchdog status)"
q "DELETE FROM orca.system_minutes" > /dev/null
echo "ok   control: memory over its limit pauses all; status shows memory and disk and which one tripped"

# MORCA_RUNNER=local: no instances, a fixed price. The cost rule reads "fixed
# price" and never trips, with the same seeded instances that tripped it above.
reset
q "INSERT INTO orca.instances (id, run, start, role, instance_type, market, launched)
   SELECT 'i-seed-' || n, $fanrun, 1, 'worker', 'c7g.4xlarge', 'on-demand', now() - interval '20 minutes' FROM generate_series(1, 8) n" > /dev/null
MORCA_RUNNER=local MORCA_WATCHDOG_SECONDS=1 ./build/morca tick >> "$log" 2>&1 || fail "tick"
[ "$(only)" = "" ] || fail "the cost rule tripped on the local runner: $(only)"
[ "$(q "SELECT detail FROM orca.watchdog_rules WHERE rule = 'cost'")" = "fixed price" ] || fail "the cost rule's detail"
[ "$(q "SELECT count(*) FROM orca.watchdog_rules WHERE rule <> 'cost'")" -ge 5 ] || fail "the other rules weren't checked"
MORCA_RUNNER=local ./build/morca watchdog status 2>&1 | grep -q '^cost .*fixed price' || fail "status doesn't say fixed price"
echo "ok   MORCA_RUNNER=local: the cost rule reads fixed price and doesn't trip; the others run"

# Unmet (#462): a run queued 20 minutes ago for more than the host can ever
# grant, held so by the start pass, pauses its pipeline alone.
reset
q "UPDATE orca.pipelines SET memory_gb = '64' WHERE name = 'toy';
   INSERT INTO orca.runs (pipeline, registry_hash, partitions, trigger, status, created)
   VALUES ('toy', '$hash', '2024-10', 'seed', 'queued', now() - interval '20 minutes')" > /dev/null
unmet() { MORCA_RUNNER=local MORCA_HOST_MEMORY_MB=4096 MORCA_WATCHDOG_SECONDS=1 ./build/morca tick >> "$log" 2>&1 || fail "tick"; }
unmet
[ "$(only)" = "toy" ] || unmet  # the start pass holds it, the next pass sees it
[ "$(only)" = "toy" ] || fail "unmet paused: '$(only)': $(q "SELECT id, status, held FROM orca.runs WHERE pipeline = 'toy' AND status = 'queued'")"
[ "$(q "SELECT detail LIKE 'toy run %needs 64 GB, more than the 2.5 GB this host grants at most, for 2_ minutes%' FROM orca.watchdog_trips WHERE rule = 'unmet'")" = t ] \
    || fail "the unmet trip: $(q "SELECT rule, detail FROM orca.watchdog_trips")"
q "UPDATE orca.pipelines SET memory_gb = NULL WHERE name = 'toy'; UPDATE orca.runs SET status = 'cancelled', ended = now() WHERE pipeline = 'toy' AND status = 'queued'" > /dev/null
echo "ok   unmet: a run waiting for more than the host grants at most pauses its pipeline"

reset
grep -q "can't check the watchdog" "$log" && fail "the watchdog raised"
echo "ok   watchdog"
