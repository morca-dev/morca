#!/bin/sh
# One run over two workers of a pool (morca.run_cluster, #268): fanout,
# registered with --workers 1 on pool t, is started by worker a as a dista
# cluster (head, a dista worker, the driver); worker b, with room and
# nothing to start, joins it as a member; both run its tasks:
#
# - a's run reports its head, b joins it, and b's dista worker runs tasks;
# - the result is the one a run on one machine gets;
# - a dista worker without the run's cluster token can't join;
# - once the run ends, b's member is ended and its process gone.
#
# Then worker groups (docs/groups.md): gpufan has tasks with no group and
# tasks of group gpu, `workers = 1` and `[pipelines.gpufan.groups.gpu]`
# with `workers = 1, gpus = 1`, on pool g:
#
# - a worker without --advertise isn't given its run, which says why;
# - ga (no GPUs) starts two runs as clusters; gb (MORCA_HOST_GPUS=1) joins
#   each as the member of group gpu, granted its GPU, and gc (no GPUs) as
#   the member with no group, both runs at once;
# - the gpu tasks ran only in gb's members, with DISTA_GROUP=gpu and
#   CUDA_VISIBLE_DEVICES=0, and no task without a group ran there;
# - orca.run_members records the group and the GPU; gb, with a slot free
#   while gc had room, never joined as a member with no group;
# - gb's GPU is free again once the first run ends: the second gets it.
#
# Then demand per group: gpufan on pool h with its group gpu at "0..1" and
# no GPUs. Its head's host ha reports the head's status; hb joins as the
# group's member only after that, once the gpu tasks wait; the run's JSON
# says what the group wants; and the run gets the same answer. A head
# whose worker reports no demand (MORCA_SCALE_REPORT_SECONDS=0) wants the
# group's MAX at once, as before demand.
#
# Needs MORCA_DATABASE_URL (pixi run test-run-cluster).
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
one_cluster_test
mkdir -p build
scripts/pipelines.sh fanout gpufan
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca
log=build/run-cluster.log
: > "$log"
dir=$PWD/build/run-cluster
rm -rf "$dir"
mkdir -p "$dir"
export MORCA_WAREHOUSE="$dir/wh" MORCA_LOGS="$dir/logs"
export MORCA_STALE_SECONDS=5 MORCA_START_SECONDS=20 MORCA_SAMPLE_SECONDS=0 MORCA_WATCHDOG_SECONDS=0
export MORCA_FANOUT_SLEEP=4 MORCA_FANOUT_SHOW_HOST=1
# No node store: results go between the workers over sockets, as between
# two hosts, so the token guards those fetches too.
export DISTA_SHM=0
unset MORCA_RUNNER MORCA_CONFIG MORCA_WORKER_ADVERTISE
pids=
cleanup() { for p in $pids; do kill "$p" 2> /dev/null || true; done; }
trap cleanup EXIT
fail() {
    echo "FAIL: $*"
    tail -20 "$log"
    for f in build/run-cluster-*.out; do [ -f "$f" ] && { echo "== $f"; tail -12 "$f"; }; done
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
is() { [ "$(q "$1")" = "$2" ]; }
until_() {
    t=$1; what=$2; shift 2
    i=0
    until "$@"; do
        i=$((i + 1)); [ "$i" -lt $((t * 10)) ] || fail "$what"; sleep 0.1
    done
}
free_port uport
base="http://127.0.0.1:$uport"
MORCA_UI_ADDR="127.0.0.1:$uport" ./build/morca ui >> "$log" 2>&1 &
pids="$pids $!"
until_ 10 "morca ui didn't start" curl -fs "$base/" -o /dev/null
./build/morca register --no-config --placement worker:t --workers 1 ./build/fanout >> "$log" 2>&1 || fail "register"
is "SELECT ec2_workers FROM orca.pipelines WHERE name = 'fanout'" 1 || fail "fanout's workers"
ta=$(./build/morca worker-token create --pool t --label a 2>> "$log") || fail "token a"
tb=$(./build/morca worker-token create --pool t --label b 2>> "$log") || fail "token b"
./build/morca scheduler > build/run-cluster-sched.out 2>&1 &
pids="$pids $!"
worker() { # NAME TOKEN [POOL [GPUS [ADVERTISE]]]
    env -u MORCA_DATABASE_URL HOSTNAME="w$1" MORCA_WORKER_TOKEN="$2" MORCA_HOST_GPUS="${4:-0}" \
        ./build/morca worker --pool "${3:-t}" --remote "$base" --poll-seconds 0.3 --name "$1" \
        --advertise "${5-127.0.0.1}" --max-runs 2 --dir "$dir/$1" > "build/run-cluster-$1.out" 2>&1 &
    pids="$pids $!"
    eval "pid_$1=$!"
}
stop_worker() { # NAME
    eval "p=\$pid_$1"
    kill "$p" 2> /dev/null || true
    wait "$p" 2> /dev/null || true
}

# a starts the run as a cluster.
worker a "$ta"
./build/morca backfill fanout 2024-01 >> "$log" 2>&1 || fail "backfill"
run=$(q "SELECT max(id) FROM orca.runs")
head_known() { [ -n "$(q "SELECT coalesce(cluster_head, '') FROM orca.runs WHERE id = $run")" ]; }
until_ 30 "no head reported: $(q "SELECT status, held FROM orca.runs WHERE id = $run")" head_known
head=$(q "SELECT cluster_head FROM orca.runs WHERE id = $run")
case "$head" in 127.0.0.1:*) ;; *) fail "the head: $head" ;; esac
echo "ok   worker a starts the run as a cluster and reports its head ($head)"
# b, with room and nothing to start, joins.
worker b "$tb"

# A dista worker without the token can't join.
rogue=0
env -u MORCA_DATABASE_URL DISTA_ROLE=worker DISTA_HEAD="$head" DISTA_CONNECT_TIMEOUT=3 \
    ./build/fanout > build/run-cluster-rogue.out 2>&1 || rogue=$?
[ "$rogue" != 0 ] || fail "a dista worker without the token ran: $(tail -3 build/run-cluster-rogue.out)"
grep -q "trips on" build/run-cluster-rogue.out && fail "the rogue ran tasks"
echo "ok   a dista worker without the run's token can't join (exit $rogue)"

joined() { is "SELECT count(*) FROM orca.run_members m JOIN orca.workers w ON w.id = m.worker WHERE m.run = $run AND w.label = 'b'" 1; }
until_ 30 "b didn't join: $(q "SELECT id, worker, ended, why FROM orca.run_members")" joined
until_ 120 "the run didn't succeed: $(q "SELECT status, error FROM orca.runs WHERE id = $run")" \
    is "SELECT status FROM orca.runs WHERE id = $run" succeeded
b_ran=$(cat "$dir"/b/fanout-"$run"-*-member-*.log 2> /dev/null | grep -c "trips on wb" || true)
a_ran=$(cat "$dir"/a/fanout-"$run"-*-worker.log 2> /dev/null | grep -c "trips on wa" || true)
[ "${b_ran:-0}" -gt 0 ] || fail "b's member ran no task (a ran $a_ran)"
[ "${a_ran:-0}" -gt 0 ] || fail "a's dista worker ran no task (b ran $b_ran)"
echo "ok   b joins as a member; both run tasks (a $a_ran, b $b_ran of 31)"

# The result: what any one machine computes, fanout's sum of its days.
# The driver's log is kept once its process has ended, a moment after.
logged() { grep -q "trips in 1 months" "$MORCA_LOGS/fanout/$run/driver.log" 2> /dev/null; }
until_ 30 "no total in run $run's driver log" logged
spread=$(grep -ho "[0-9]* trips in 1 months" "$MORCA_LOGS/fanout/$run/driver.log" | head -1)
want=$(awk 'BEGIN { t = 0; for (d = 1; d <= 31; d++) t += (2024 * 13 + 31 + d * 7) % 1000; print t " trips in 1 months" }')
[ "$spread" = "$want" ] || fail "spread: '$spread', one machine: '$want'"
echo "ok   the same result as on one machine ($spread)"

# The member ended with its run, and its process is gone.
ended() { is "SELECT count(*) FROM orca.run_members WHERE run = $run AND ended IS NULL" 0; }
until_ 30 "the member wasn't ended: $(q "SELECT id, ended, why FROM orca.run_members")" ended
gone() { ! pgrep -f "DISTA_ROLE=worker" > /dev/null 2>&1 || ! grep -q "joined fanout" "build/run-cluster-b.out" || grep -qE "^(member [0-9]+ pid [0-9]+ exited|stopping member)" build/run-cluster-b.out; }
until_ 30 "b's member is still running" gone
echo "ok   once the run ends, the member is ended ($(q "SELECT why FROM orca.run_members WHERE run = $run"))"
# The run's page and JSON show its cluster: the head, with its address, then
# the member.
page=$(curl -fsS "$base/runs/$run") || fail "GET /runs/$run"
echo "$page" | grep -q 'id="cluster"' || fail "no Cluster card on the run's page"
echo "$page" | grep -qF "$head" || fail "the Cluster card doesn't show the head's address"
curl -fsS -H 'Accept: application/json' "$base/runs/$run" > "$dir/run.json" || fail "the run's JSON"
jq -e --arg h "$head" '.cluster | length == 2 and .[0].role == "head" and .[0].address == $h and .[0].worker == "a" and .[1].role == "member" and .[1].worker == "b" and .[1].ended != null and .[1].why != null' "$dir/run.json" > /dev/null \
    || fail "the run's JSON cluster: $(jq -c .cluster "$dir/run.json")"
alone_page=$(curl -fsS -H 'Accept: application/json' "$base/runs/$(q "SELECT min(id) FROM orca.runs WHERE cluster_head IS NULL")" 2> /dev/null || echo '{"cluster": []}')
echo "$alone_page" | jq -e '.cluster == [] or .cluster == null' > /dev/null || fail "a run on one machine shows a cluster"
echo "ok   the run's page and JSON show its cluster: the head and its member"

# Worker groups (docs/groups.md), on pool g.
stop_worker a
stop_worker b
cat > build/run-cluster-gpufan.toml << 'EOF2'
[pipelines.gpufan]
placement = "worker:g"
workers = 1
max_runs = 2

[pipelines.gpufan.groups.gpu]
workers = 1
gpus = 1
EOF2
./build/morca register --config build/run-cluster-gpufan.toml ./build/gpufan >> "$log" 2>&1 || fail "register gpufan"
is "SELECT ec2_workers || ' ' || (groups->0->>'name') || ' ' || (groups->0->>'gpus') FROM orca.pipelines WHERE name = 'gpufan'" "1 gpu 1" \
    || fail "gpufan's groups: $(q "SELECT ec2_workers, groups FROM orca.pipelines WHERE name = 'gpufan'")"
gna=$(./build/morca worker-token create --pool g --label gn 2>> "$log") || fail "token gn"
gta=$(./build/morca worker-token create --pool g --label ga 2>> "$log") || fail "token ga"
gtb=$(./build/morca worker-token create --pool g --label gb 2>> "$log") || fail "token gb"
gtc=$(./build/morca worker-token create --pool g --label gc 2>> "$log") || fail "token gc"
marks=$dir/marks
mkdir -p "$marks"
export GPUFAN_OUT="$marks" GPUFAN_SLEEP=2

# A worker without an address can't run a pipeline with groups.
worker gn "$gna" g 0 ""
./build/morca backfill gpufan 2024-01 >> "$log" 2>&1 || fail "backfill gpufan 2024-01"
g1=$(q "SELECT max(id) FROM orca.runs")
held_why() { q "SELECT coalesce(held, '') FROM orca.runs WHERE id = $g1" | grep -q "started with --advertise"; }
until_ 20 "gpufan's run isn't held for an address: $(q "SELECT status, held FROM orca.runs WHERE id = $g1")" held_why
is "SELECT status FROM orca.runs WHERE id = $g1" queued || fail "a worker without --advertise ran gpufan"
stop_worker gn
echo "ok   a worker without --advertise isn't given a run with groups ($(q "SELECT held FROM orca.runs WHERE id = $g1"))"

# ga starts both runs as clusters; gb and gc join them.
worker ga "$gta" g 0
./build/morca backfill gpufan 2024-02 >> "$log" 2>&1 || fail "backfill gpufan 2024-02"
g2=$(q "SELECT max(id) FROM orca.runs")
heads() { is "SELECT count(*) FROM orca.runs r JOIN orca.workers w ON w.id = r.worker WHERE r.id IN ($g1, $g2) AND r.cluster_head IS NOT NULL AND w.label = 'ga'" 2; }
until_ 30 "ga didn't start both runs: $(q "SELECT id, status, held, cluster_head FROM orca.runs WHERE id IN ($g1, $g2)")" heads
worker gb "$gtb" g 1
worker gc "$gtc" g 0
for r in $g1 $g2; do
    until_ 120 "gpufan's run $r didn't succeed: $(q "SELECT status, error FROM orca.runs WHERE id = $r") $(q "SELECT m.id, w.label, m.worker_group, m.grant_gpus, m.ended, m.why FROM orca.run_members m JOIN orca.workers w ON w.id = m.worker WHERE m.run = $r")" \
        is "SELECT status FROM orca.runs WHERE id = $r" succeeded
done
members() { # RUN
    q "SELECT w.label || ':' || coalesce(m.worker_group, '-') || ':' || coalesce(m.grant_gpus, 0) FROM orca.run_members m JOIN orca.workers w ON w.id = m.worker WHERE m.run = $1 ORDER BY w.label"
}
for r in $g1 $g2; do
    got=$(members "$r" | tr '\n' ' ')
    [ "$got" = "gb:gpu:1 gc:-:0 " ] || fail "run $r's members: $got"
done
echo "ok   gb joins each run as its member of group gpu with its GPU, gc as the one with no group"
is "SELECT count(*) FROM orca.run_members m JOIN orca.workers w ON w.id = m.worker WHERE w.label = 'gb' AND m.worker_group IS NULL" 0 \
    || fail "gb joined as a member with no group: $(members "$g1") / $(members "$g2")"
echo "ok   gb, with a slot free while gc had room, never joined as a member with no group"
models=$(ls "$marks"/model-*.env 2> /dev/null | wc -l | tr -d ' ')
[ "$models" -ge 2 ] || fail "the gpu tasks ran in $models processes: $(ls "$marks")"
for f in "$marks"/model-*.env; do
    printf 'DISTA_GROUP=gpu\nCUDA_VISIBLE_DEVICES=0\nMORCA_GRANT_GPUS=0\nHOSTNAME=wgb\n' | cmp -s - "$f" \
        || fail "a gpu task ran in $(basename "$f"): $(tr '\n' ' ' < "$f")"
done
for f in "$marks"/plain-*.env; do
    grep -qx 'DISTA_GROUP=-' "$f" && ! grep -qx 'HOSTNAME=wgb' "$f" \
        || fail "a task with no group ran in $(basename "$f"): $(tr '\n' ' ' < "$f")"
done
echo "ok   the gpu tasks ran only in gb's members (DISTA_GROUP=gpu, CUDA_VISIBLE_DEVICES=0, $models processes), the others never there"
grep -q "of group gpu" build/run-cluster-gb.out || fail "gb's log doesn't say its member's group"
for r in $g1 $g2; do
    logged_g() { grep -q "56 from plain and model tasks" "$MORCA_LOGS/gpufan/$r/driver.log" 2> /dev/null; }
    until_ 30 "no total in run $r's driver log" logged_g
done
echo "ok   both runs got the gpu member in turn: gb's GPU was free again once the first ended"
curl -fsS -H 'Accept: application/json' "$base/runs/$g1" > "$dir/g1.json" || fail "gpufan's run's JSON"
jq -e '[.cluster[] | select(.role == "member")] | length == 2 and any(.group == "gpu" and .grant.gpus == 1 and .worker == "gb") and any(.group == null and .grant.gpus == null and .worker == "gc")' "$dir/g1.json" > /dev/null \
    || fail "gpufan's run's JSON cluster: $(jq -c .cluster "$dir/g1.json")"
curl -fsS "$base/runs/$g1" | grep -qF '<code>gpu</code>' || fail "the Cluster card doesn't show the member's group"
curl -fsS "$base/runs/$g1" | grep -qF '1 GPU' || fail "the Cluster card doesn't show the member's GPU"
echo "ok   the run's page and JSON show each member's group and GPUs"

# Demand per group: gpufan again, on pool h, with its group gpu a range of
# 0..1 asking for no GPU, and no workers of its own. hb is idle beside the
# head's host ha, and joins only once ha has reported that the head's gpu
# tasks are waiting for a worker of their group.
cat > build/run-cluster-demand.toml << 'EOF2'
[pipelines.gpufan]
placement = "worker:h"
max_runs = 2

[pipelines.gpufan.groups.gpu]
workers = "0..1"
EOF2
./build/morca register --config build/run-cluster-demand.toml ./build/gpufan >> "$log" 2>&1 || fail "register gpufan on h"
is "SELECT coalesce(ec2_workers, 0) || ' ' || (groups->0->>'workers') FROM orca.pipelines WHERE name = 'gpufan'" "0 0..1" \
    || fail "gpufan's range: $(q "SELECT ec2_workers, groups FROM orca.pipelines WHERE name = 'gpufan'")"
hta=$(./build/morca worker-token create --pool h --label ha 2>> "$log") || fail "token ha"
htb=$(./build/morca worker-token create --pool h --label hb 2>> "$log") || fail "token hb"
rm -f "$marks"/*.env
export GPUFAN_SLEEP=3 MORCA_SCALE_REPORT_SECONDS=2
worker ha "$hta" h 0
./build/morca backfill gpufan 2024-03 >> "$log" 2>&1 || fail "backfill gpufan 2024-03"
g3=$(q "SELECT max(id) FROM orca.runs")
h_head() { is "SELECT count(*) FROM orca.runs r JOIN orca.workers w ON w.id = r.worker WHERE r.id = $g3 AND r.cluster_head IS NOT NULL AND w.label = 'ha'" 1; }
until_ 30 "ha didn't start run $g3 as a cluster: $(q "SELECT status, held, cluster_head FROM orca.runs WHERE id = $g3")" h_head
worker hb "$htb" h 0
# Until the head's first status, the group wants its MIN, 0: no member.
gpu_members() { q "SELECT count(*) FROM orca.run_members WHERE run = $g3 AND worker_group = 'gpu'"; }
before=0
reported() {
    got=$(q "SELECT (demand_at IS NOT NULL)::int || ' ' || (SELECT count(*) FROM orca.run_members m WHERE m.run = r.id AND m.worker_group = 'gpu') FROM orca.runs r WHERE id = $g3")
    case "$got" in
    "0 0") before=$((before + 1)); return 1 ;;
    "0 "*) fail "a member of gpu joined before any demand: $got" ;;
    *) return 0 ;;
    esac
}
until_ 30 "ha reported no demand for run $g3" reported
echo "ok   no member of gpu joins run $g3 before its head reports demand ($before polls before)"
until_ 30 "hb didn't join run $g3's gpu group: $(q "SELECT worker_group, wanted, short_since FROM orca.run_wants WHERE run = $g3") $(q "SELECT demand FROM orca.runs WHERE id = $g3")" \
    is "SELECT count(*) FROM orca.run_members m JOIN orca.workers w ON w.id = m.worker WHERE m.run = $g3 AND m.worker_group = 'gpu' AND w.label = 'hb'" 1
is "SELECT wanted FROM orca.run_wants WHERE run = $g3 AND worker_group = 'gpu'" 1 \
    || fail "run $g3's gpu group doesn't want 1: $(q "SELECT worker_group, wanted FROM orca.run_wants WHERE run = $g3")"
is "SELECT count(*) FROM orca.run_wants WHERE run = $g3 AND worker_group = ''" 0 \
    || fail "run $g3 decided for workers with no group it doesn't have"
q "SELECT demand FROM orca.runs WHERE id = $g3" >> "$log"
q "SELECT demand FROM orca.runs WHERE id = $g3" | jq -e '.groups | any(.group == "gpu")' > /dev/null \
    || fail "run $g3's kept demand has no gpu group: $(q "SELECT demand FROM orca.runs WHERE id = $g3")"
curl -fsS -H 'Accept: application/json' "$base/runs/$g3" > "$dir/g3.json" || fail "run $g3's JSON"
jq -e '.cluster_wants == [{"group": "gpu", "min": 0, "max": 1, "live": 1, "wanted": 1, "decided": true, "demand_at": .cluster_wants[0].demand_at}] and (.cluster_wants[0].demand_at | type == "string")' "$dir/g3.json" > /dev/null \
    || fail "run $g3's JSON cluster_wants: $(jq -c .cluster_wants "$dir/g3.json")"
curl -fsS "$base/runs/$g3" | grep -qF '<th>Wanted</th>' || fail "the Cluster card doesn't show what each kind wants"
echo "ok   hb joins as gpu's member once the head reports its tasks waiting; the JSON shows it wanted ($(jq -c '.cluster_wants[0] | {live, wanted}' "$dir/g3.json"))"
until_ 120 "run $g3 didn't succeed: $(q "SELECT status, error FROM orca.runs WHERE id = $g3")" \
    is "SELECT status FROM orca.runs WHERE id = $g3" succeeded
logged_g3() { grep -q "56 from plain and model tasks" "$MORCA_LOGS/gpufan/$g3/driver.log" 2> /dev/null; }
until_ 30 "no total in run $g3's driver log" logged_g3
for f in "$marks"/model-*.env; do
    grep -qx 'DISTA_GROUP=gpu' "$f" && grep -qx 'HOSTNAME=whb' "$f" \
        || fail "a gpu task of run $g3 ran in $(basename "$f"): $(tr '\n' ' ' < "$f")"
done
echo "ok   run $g3 grew its gpu group from 0 by demand and got the right answer (56)"

# A head whose worker doesn't report demand (MORCA_SCALE_REPORT_SECONDS=0,
# as a worker from before demand): nothing would grow its group, so it
# wants its MAX at once, as before demand.
is "SELECT coalesce(reports_demand, false) FROM orca.workers WHERE label = 'ha'" t || fail "ha's claims don't say it reports demand"
stop_worker ha
stop_worker hb
htc=$(./build/morca worker-token create --pool h --label hc 2>> "$log") || fail "token hc"
MORCA_SCALE_REPORT_SECONDS=0
worker hc "$htc" h 0
MORCA_SCALE_REPORT_SECONDS=2
./build/morca backfill gpufan 2024-04 >> "$log" 2>&1 || fail "backfill gpufan 2024-04"
g4=$(q "SELECT max(id) FROM orca.runs")
hc_head() { is "SELECT count(*) FROM orca.runs r JOIN orca.workers w ON w.id = r.worker WHERE r.id = $g4 AND r.cluster_head IS NOT NULL AND w.label = 'hc'" 1; }
until_ 30 "hc didn't start run $g4 as a cluster: $(q "SELECT status, held, cluster_head FROM orca.runs WHERE id = $g4")" hc_head
is "SELECT coalesce(reports_demand, false) FROM orca.workers WHERE label = 'hc'" f || fail "hc says it reports demand with reporting off"
curl -fsS -H 'Accept: application/json' "$base/runs/$g4" > "$dir/g4.json" || fail "run $g4's JSON"
jq -e '.cluster_wants[0] | .group == "gpu" and .wanted == 1 and .decided == false' "$dir/g4.json" > /dev/null \
    || fail "run $g4's gpu group doesn't want its MAX: $(jq -c .cluster_wants "$dir/g4.json")"
worker hb "$htb" h 0
until_ 30 "hb didn't join run $g4's gpu group" \
    is "SELECT count(*) FROM orca.run_members m JOIN orca.workers w ON w.id = m.worker WHERE m.run = $g4 AND m.worker_group = 'gpu' AND w.label = 'hb'" 1
until_ 120 "run $g4 didn't succeed: $(q "SELECT status, error FROM orca.runs WHERE id = $g4")" \
    is "SELECT status FROM orca.runs WHERE id = $g4" succeeded
is "SELECT count(*) FROM orca.run_wants WHERE run = $g4" 0 || fail "run $g4 was decided on with no demand reported"
echo "ok   a head whose worker reports no demand wants its group's MAX at once (run $g4)"
echo "run cluster: ok"
