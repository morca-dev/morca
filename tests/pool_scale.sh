#!/bin/sh
# The pool autoscaler (morca.pool_scale, #267) end to end: a [pools.t] of
# hetzner machines against tests/fake_hcloud.py (each "server" a local
# process running its boot script, which asks morca ui for what it needs and
# runs `morca worker`), with plain (tests/grants/grantee.mojo) placed on it:
#
# - a type the worker image has no variant for is skipped, saying so;
# - with no stock of the first type, it keeps trying it for its wait, then
#   makes the next, in the first location that has it;
# - the machine boots, joins as a worker and runs the runs; with plain's
#   max_runs = 1 one machine is all the demand there is;
# - idle for idle_seconds, it's removed: token revoked, server deleted;
#   drained on request (morca host drain), it's removed once idle;
# - a server with the pool's and the stack's labels that morca doesn't know
#   is deleted;
# - /api/worker/boot answers only a token the autoscaler made;
# - one run over two machines (#268, milestone B): fanout, with workers = 1
#   on another pool, s, from empty: the first machine is made for the queued
#   run and starts it as a cluster; the run's want of a member grows a
#   second, which joins the private network the first did, and the run;
#   both run its tasks, the total is one machine's; idle once the run ends,
#   both are removed. (This was tests/pool_spread.sh, #447.)
# - a mixed pool (docs/groups.md, PR 4b): m has machines and gpu_machines,
#   and gpufan's group gpu ("0..1", one GPU) is placed on it. The queued
#   run grows a machine without GPUs, which starts it; the group's demand
#   grows one with a GPU, which joins as its member; idle once the gpu
#   tasks are done, the member is drained while the run goes on, and the
#   GPU machine is removed while the other runs on.
#
# Each fake server runs its boot script, which runs `morca worker` with the
# address MORCA_BOOT_ADVERTISE gives it (127.0.0.1 here; the private one
# from the provider's metadata on a real machine).
#
# Needs MORCA_DATABASE_URL (pixi run test-pool-scale starts a throwaway
# server), curl, jq and python3.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
one_cluster_test
mkdir -p build
scripts/pipelines.sh plain fanout gpufan
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca
log=build/pool-scale.log
: > "$log"
dir=$PWD/build/pool-scale
rm -rf "$dir"
mkdir -p "$dir"
export MORCA_WAREHOUSE="$dir/wh" MORCA_LOGS="$dir/logs" GRANTEE_OUT="$dir/out" GRANTEE_SLEEP=2
mkdir -p "$GRANTEE_OUT"
export MORCA_STALE_SECONDS=5 MORCA_START_SECONDS=20 MORCA_SAMPLE_SECONDS=0 MORCA_WATCHDOG_SECONDS=0
export MORCA_FANOUT_SLEEP=4 MORCA_FANOUT_SHOW_HOST=1 DISTA_SHM=0
export MORCA_BOOT_ADVERTISE=127.0.0.1
# gpufan's tail, in its runs on the fake's servers, and an idle time the
# UI decides with that drains its member within it.
export GPUFAN_SLEEP=2 GPUFAN_TAIL=60 MORCA_SCALE_IDLE=3
unset MORCA_RUNNER MORCA_CONFIG MORCA_WORKER_ADVERTISE
free_port hport
free_port uport
base="http://127.0.0.1:$uport"
export MORCA_HCLOUD_ENDPOINT="http://127.0.0.1:$hport/v1" MORCA_HCLOUD_TOKEN=test-token
export MORCA_REGISTRY_ENDPOINT="http://127.0.0.1:$hport"
export MORCA_WORKER_IMAGE="ghcr.io/morca-dev/census:t1"
pids=
sched=
cleanup() {
    for p in $pids $sched; do kill "$p" 2> /dev/null || true; done
}
trap cleanup EXIT
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    tail -20 build/pool-scale-sched.out 2> /dev/null || true
    for f in "$dir"/server-*.log; do [ -f "$f" ] && { echo "== $f"; tail -10 "$f"; }; done
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
status() { q "SELECT coalesce(status, '') FROM orca.pools WHERE name = 't'"; }
has_status() { status | grep -qF "$1"; }
servers() { curl -fsS -H 'Authorization: Bearer test-token' "$MORCA_HCLOUD_ENDPOINT/servers?label_selector=orca-pool%3Dt" | jq -r '[.servers[].name] | join(" ")'; }

# The fake's servers run workers, which refuse a database URL.
env -u MORCA_DATABASE_URL python3 tests/fake_hcloud.py "$hport" "$dir" &
pids="$pids $!"
until_ 10 "the fake didn't start" curl -s -o /dev/null "$MORCA_HCLOUD_ENDPOINT/server_types"
MORCA_UI_ADDR="127.0.0.1:$uport" ./build/morca ui >> "$log" 2>&1 &
pids="$pids $!"
until_ 10 "morca ui didn't start" curl -fs "$base/" -o /dev/null

cat > build/pool-scale.toml << 'EOF'
[pools.t]
provider = "hetzner"
machines = [{ type = "cax31", wait = 3 }, { type = "cpx32" }]
locations = ["hel1", "nbg1"]
max_machines = 2
idle_seconds = 10

[pipelines.plain]
placement = "worker:t"
EOF
./build/morca register --config build/pool-scale.toml ./build/plain >> "$log" 2>&1 || fail "register"
grep -q '^pool t (hetzner)$' "$log" || fail "register didn't say it recorded pool t"
is "SELECT provider || ' ' || max_machines FROM orca.pools WHERE name = 't'" "hetzner 2" || fail "orca.pools"

start_sched() {
    MORCA_POOL_REMOTE="$base" MORCA_POOL_WORKER_COMMAND="$PWD/build/morca" \
    MORCA_POOL_SCALE_SECONDS=0.5 MORCA_POOL_GROW_AFTER=0 MORCA_POOL_TRY_SECONDS=0.5 MORCA_POOL_IMAGE_SECONDS=0 \
        ./build/morca scheduler >> build/pool-scale-sched.out 2>&1 &
    sched=$!
}
: > build/pool-scale-sched.out
start_sched

# The image has arm64 only: cpx32 (x86) is skipped, and cax31 is out of stock.
echo arm64 > "$dir/arches"
echo "cpx32 hel1" > "$dir/stock"
./build/morca backfill plain 2024-01..2024-03 >> "$log" 2>&1 || fail "backfill"
until_ 20 "no waiting status: $(status)" has_status "waiting: no cax31 in hel1, nbg1 yet"
has_status "cpx32 skipped: ghcr.io/morca-dev/census:t1 has no linux/amd64" || fail "the skip isn't said: $(status)"
[ -z "$(servers)" ] || fail "made a server: $(servers)"
echo "ok   a type the image has no variant for is skipped, saying so"

# Both architectures: cax31 for its 3 s, then cpx32, in hel1.
echo "amd64 arm64" > "$dir/arches"
until_ 30 "no cpx32 made: $(status)" has_status "made orca-pool-t-"
# Ops > Pools shows the pool: its types, its machine, the last try.
curl -fsS "$base/ops/pools" | grep -q 'id="autoscaled"' || fail "no Autoscaled pools card on Ops > Pools"
curl -fsS -H 'Accept: application/json' "$base/api/pools" > "$dir/pools.json" || fail "GET /api/pools"
jq -e '.autoscaled | length == 1 and .[0].name == "t" and .[0].provider == "hetzner" and .[0].live == 1 and .[0].max_machines == 2 and (.[0].machines | map(.type)) == ["cax31", "cpx32"] and .[0].machines[0].wait == 3 and (.[0].status | test("made orca-pool-t-"))' "$dir/pools.json" > /dev/null \
    || fail "the autoscaled pools JSON: $(jq -c .autoscaled "$dir/pools.json")"
has_status ": cpx32 in hel1" || fail "made the wrong one: $(status)"
is "SELECT server_type || ' ' || arch || ' ' || location FROM orca.pool_machines" "cpx32 amd64 hel1" \
    || fail "the machine: $(q "SELECT server_type, arch, location FROM orca.pool_machines")"
tried() { jq -r 'select(.method == "POST" and .path == "/v1/servers") | .body | fromjson | "\(.server_type) \(.location)"' "$dir/calls.jsonl" | sort -u | tr '\n' ' '; }
[ "$(tried)" = "cax31 hel1 cax31 nbg1 cpx32 hel1 " ] || fail "tried: $(tried)"
echo "ok   after cax31's wait with none in stock, cpx32 is made in hel1"

# It boots, joins and runs plain's three runs; max_runs = 1 needs one machine.
until_ 120 "the runs didn't succeed: $(q "SELECT id, status, held FROM orca.runs")" \
    is "SELECT count(*) FILTER (WHERE status = 'succeeded') FROM orca.runs" 3
is "SELECT count(*) FROM orca.pool_machines" 1 || fail "more machines than the demand: $(q "SELECT name FROM orca.pool_machines")"
m=$(q "SELECT name FROM orca.pool_machines")
is "SELECT count(DISTINCT r.worker) FROM orca.runs r JOIN orca.pool_machines m ON m.worker = r.worker" 1 \
    || fail "the runs didn't run on the machine"
echo "ok   the machine boots as a worker and runs the runs; one is all max_runs = 1 needs"

# Idle 10 s: removed.
until_ 40 "the idle machine wasn't removed: $(q "SELECT name, ended, why FROM orca.pool_machines")" \
    is "SELECT why FROM orca.pool_machines WHERE ended IS NOT NULL" "idle 10 s"
is "SELECT count(*) FROM orca.workers w JOIN orca.pool_machines m ON m.worker = w.id WHERE w.revoked IS NOT NULL" 1 \
    || fail "its token isn't revoked"
[ -z "$(servers)" ] || fail "its server is still there: $(servers)"
echo "ok   an idle machine is removed: token revoked, server deleted ($m)"

# A server with the pool's and the stack's labels that morca doesn't know.
owner=$(q "SELECT id FROM orca.stack_identity")
touch "$dir/no-run"
echo "cax31 hel1" > "$dir/stock"
curl -fsS -X POST -H 'Authorization: Bearer test-token' -H 'Content-Type: application/json' \
    -d "{\"name\": \"stray-1\", \"server_type\": \"cax31\", \"location\": \"hel1\", \"labels\": {\"orca-pool\": \"t\", \"orca-owner\": \"$owner\"}}" \
    "$MORCA_HCLOUD_ENDPOINT/servers" > /dev/null || fail "make a stray"
curl -fsS -X POST -H 'Authorization: Bearer test-token' -H 'Content-Type: application/json' \
    -d '{"name": "other-stack", "server_type": "cax31", "location": "hel1", "labels": {"orca-pool": "t", "orca-owner": "someone-else"}}' \
    "$MORCA_HCLOUD_ENDPOINT/servers" > /dev/null || fail "make another stack's"
only_other() { [ "$(servers)" = "other-stack" ]; }
until_ 20 "the stray wasn't deleted: $(servers)" only_other
rm -f "$dir/no-run"
echo "ok   a stray of this stack's is deleted, another stack's left alone"

# Over the project's quota for cax31: the next type, at once, saying why.
rm -f "$dir/no-run"
printf 'cax31 hel1\ncpx32 hel1\n' > "$dir/stock"
echo cax31 > "$dir/quota"
before=$(q "SELECT count(*) FROM orca.pool_machines")
./build/morca backfill plain 2024-04 >> "$log" 2>&1 || fail "backfill 2024-04"
# The status still says the last step's "made ...: cpx32 in hel1", so wait
# for this step's machine, then for the pass that made it to say why.
made_one() { is "SELECT count(*) FROM orca.pool_machines" $((before + 1)); }
until_ 30 "no machine after the quota refusal: $(status) / $(q "SELECT name, server_type FROM orca.pool_machines")" made_one
until_ 10 "the quota refusal isn't said: $(status)" has_status "cax31 refused for quota"
has_status ": cpx32 in hel1" || fail "not cpx32: $(status)"
rm -f "$dir/quota"
echo "ok   a type refused for the project's quota: the next is made at once, saying why"

# Drained on request (morca host drain, #220): removed once idle, without
# waiting for idle_seconds.
until_ 60 "2024-04 didn't succeed: $(q "SELECT id, status, held FROM orca.runs")" \
    is "SELECT count(*) FROM orca.runs WHERE status = 'succeeded'" 4
mw=$(q "SELECT worker FROM orca.pool_machines WHERE ended IS NULL")
./build/morca host drain "$mw" >> "$log" 2>&1 || fail "host drain $mw"
until_ 8 "the drained machine wasn't removed: $(q "SELECT name, ended, why FROM orca.pool_machines")" \
    is "SELECT why FROM orca.pool_machines WHERE worker = $mw" "drained on request (morca host drain)"
echo "ok   a machine drained on request is removed once idle"

# /api/worker/boot only for a token the autoscaler made.
tok=$(./build/morca worker-token create --pool t --label hand 2>> "$log") || fail "worker-token create"
code=$(curl -s -o "$dir/boot.out" -w '%{http_code}' -X POST -H "Authorization: Bearer $tok" \
    -H 'Content-Type: application/json' -d '{"pool": "t"}' "$base/api/worker/boot")
[ "$code" = 403 ] || fail "a hand-made token booted: $code $(cat "$dir/boot.out")"
echo "ok   /api/worker/boot refuses a token the autoscaler didn't make"
# One run over two machines of pool s, from empty.
calls=$(wc -l < "$dir/calls.jsonl" | tr -d ' ')
cat build/pool-scale.toml - > build/pool-scale-spread.toml << 'EOF'

[pools.s]
provider = "hetzner"
machines = [{ type = "cax31" }]
locations = ["hel1"]
max_machines = 2
idle_seconds = 10

[pipelines.fanout]
placement = "worker:s"
workers = 1
EOF
echo "cax31 hel1" > "$dir/stock"
./build/morca register --config build/pool-scale-spread.toml ./build/fanout >> "$log" 2>&1 || fail "register fanout"
./build/morca backfill fanout 2024-01 >> "$log" 2>&1 || fail "backfill fanout"
run=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'fanout'")
head_known() { [ -n "$(q "SELECT coalesce(cluster_head, '') FROM orca.runs WHERE id = $run")" ]; }
until_ 60 "no head: $(q "SELECT status, held FROM orca.runs WHERE id = $run") / $(q "SELECT status FROM orca.pools WHERE name = 's'")" head_known
echo "ok   the first machine is made for the run and starts it as a cluster"

two() { is "SELECT count(*) FROM orca.pool_machines WHERE pool = 's'" 2; }
until_ 60 "no second machine: $(q "SELECT status FROM orca.pools WHERE name = 's'")" two
member() { is "SELECT count(*) FROM orca.run_members WHERE run = $run" 1; }
until_ 60 "the second machine didn't join the run" member
since() { tail -n +$((calls + 1)) "$dir/calls.jsonl"; }
# One private network for the stack, made for pool t's first machine.
nets=$(jq -r 'select(.method == "POST" and .path == "/v1/networks") | .path' "$dir/calls.jsonl" | wc -l | tr -d ' ')
[ "$nets" = 1 ] || fail "networks made: $nets"
attached=$(since | jq -r 'select(.method == "POST" and .path == "/v1/servers") | .body | fromjson | .networks | length' | sort -u | tr '\n' ' ')
[ "$attached" = "1 " ] || fail "servers not all on the network: $attached"
echo "ok   the run's want of a member grows a second machine, on the same private network, which joins"

until_ 120 "the run didn't succeed: $(q "SELECT status, error FROM orca.runs WHERE id = $run")" \
    is "SELECT status FROM orca.runs WHERE id = $run" succeeded
ran_on=$(cat "$dir"/boot-*/stage/fanout-"$run"-*.log 2> /dev/null | grep -o "trips on orca-pool-s-[0-9]*" | sort -u | wc -l | tr -d ' ')
[ "$ran_on" = 2 ] || fail "tasks ran on $ran_on machines"
# The driver's log is kept once its process has ended, a moment after.
logged() { grep -q "trips in 1 months" "$MORCA_LOGS/fanout/$run/driver.log" 2> /dev/null; }
until_ 30 "no total in run $run's driver log" logged
spread=$(grep -ho "[0-9]* trips in 1 months" "$MORCA_LOGS/fanout/$run/driver.log" | head -1)
want=$(awk 'BEGIN { t = 0; for (d = 1; d <= 31; d++) t += (2024 * 13 + 31 + d * 7) % 1000; print t " trips in 1 months" }')
[ "$spread" = "$want" ] || fail "spread: '$spread', one machine: '$want'"
echo "ok   both machines run its tasks, and the total is one machine's ($spread)"

gone() { is "SELECT count(*) FROM orca.pool_machines WHERE pool = 's' AND ended IS NULL" 0; }
until_ 60 "the machines weren't removed: $(q "SELECT name, ended, why FROM orca.pool_machines WHERE pool = 's'")" gone
echo "ok   idle once the run ends, both machines are removed ($(q "SELECT string_agg(DISTINCT why, ', ') FROM orca.pool_machines WHERE pool = 's'"))"

# A mixed pool: m's GPU machines grow and shrink by its gpu group's demand.
cat build/pool-scale-spread.toml - > build/pool-scale-gpu.toml << 'EOF'

[pools.m]
provider = "hetzner"
machines = [{ type = "cax31" }]
gpu_machines = [{ type = "gex44" }]
locations = ["hel1"]
max_machines = 2
idle_seconds = 10

[pipelines.gpufan]
placement = "worker:m"
max_runs = 1

[pipelines.gpufan.groups.gpu]
workers = "0..1"
gpus = 1
EOF
printf 'cax31 hel1\ngex44 hel1\n' > "$dir/stock"
./build/morca register --config build/pool-scale-gpu.toml ./build/gpufan >> "$log" 2>&1 || fail "register gpufan"
is "SELECT gpu_machines::text FROM orca.pools WHERE name = 'm'" '[{"type": "gex44"}]' || fail "pool m's gpu_machines: $(q "SELECT gpu_machines FROM orca.pools WHERE name = 'm'")"
./build/morca backfill gpufan 2024-01 >> "$log" 2>&1 || fail "backfill gpufan"
gr=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'gpufan'")
m_head() { [ -n "$(q "SELECT coalesce(cluster_head, '') FROM orca.runs WHERE id = $gr")" ]; }
until_ 60 "no head for run $gr: $(q "SELECT status, held FROM orca.runs WHERE id = $gr") / $(q "SELECT status, gpu_status FROM orca.pools WHERE name = 'm'")" m_head
is "SELECT string_agg(server_type || ':' || gpu, ' ') FROM orca.pool_machines WHERE pool = 'm'" "cax31:false" \
    || fail "pool m's machines for the queued run: $(q "SELECT server_type, gpu FROM orca.pool_machines WHERE pool = 'm'")"
echo "ok   the queued run grows a machine without GPUs, which starts it"
gpu_machine() { is "SELECT count(*) FROM orca.pool_machines WHERE pool = 'm' AND gpu AND server_type = 'gex44'" 1; }
until_ 60 "no GPU machine: $(q "SELECT status, gpu_status FROM orca.pools WHERE name = 'm'") / $(q "SELECT worker_group, wanted FROM orca.run_wants WHERE run = $gr")" gpu_machine
gpu_member() { [ -n "$(q "SELECT m.id FROM orca.run_members m JOIN orca.pool_machines pm ON pm.worker = m.worker WHERE m.run = $gr AND pm.gpu AND m.worker_group = 'gpu' AND m.grant_gpus = 1")" ]; }
until_ 90 "the GPU machine didn't join run $gr: $(q "SELECT worker, worker_group, grant_gpus, ended, why FROM orca.run_members WHERE run = $gr")" gpu_member
gm=$(q "SELECT m.id FROM orca.run_members m JOIN orca.pool_machines pm ON pm.worker = m.worker WHERE m.run = $gr AND pm.gpu")
echo "ok   the group's demand grows a machine with a GPU, which joins as its member with the GPU"
drained_mid_run() {
    got=$(q "SELECT (m.ended IS NOT NULL)::int || ' ' || r.status FROM orca.run_members m JOIN orca.runs r ON r.id = m.run WHERE m.id = $gm")
    case "$got" in
    "1 running") return 0 ;;
    "1 "*) fail "member $gm ended only with its run: $got" ;;
    *) return 1 ;;
    esac
}
until_ 60 "member $gm wasn't drained: $(q "SELECT ended, draining, why, address FROM orca.run_members WHERE id = $gm")" drained_mid_run
is "SELECT why FROM orca.run_members WHERE id = $gm" "drained: group gpu wants 0 (0..1)" || fail "member $gm's why: $(q "SELECT why FROM orca.run_members WHERE id = $gm")"
echo "ok   idle, the member is drained while the run goes on"
gpu_removed() {
    got=$(q "SELECT coalesce(why, '') FROM orca.pool_machines WHERE pool = 'm' AND gpu")
    [ -n "$got" ] || return 1
    [ "$got" = "idle 10 s" ] || fail "the GPU machine was removed: $got"
    is "SELECT status FROM orca.runs WHERE id = $gr" running || fail "the run ended before the GPU machine was removed"
}
until_ 60 "the idle GPU machine wasn't removed: $(q "SELECT name, gpu, ended, why FROM orca.pool_machines WHERE pool = 'm'")" gpu_removed
is "SELECT count(*) FROM orca.pool_machines WHERE pool = 'm' AND NOT gpu AND ended IS NULL" 1 || fail "the machine without GPUs went with it"
echo "ok   the idle GPU machine is removed while the run goes on, on the other"
until_ 120 "run $gr didn't succeed: $(q "SELECT status, error FROM orca.runs WHERE id = $gr")" \
    is "SELECT status FROM orca.runs WHERE id = $gr" succeeded
m_gone() { is "SELECT count(*) FROM orca.pool_machines WHERE pool = 'm' AND ended IS NULL" 0; }
until_ 60 "pool m's machines weren't removed: $(q "SELECT name, ended, why FROM orca.pool_machines WHERE pool = 'm'")" m_gone
echo "ok   once the run ends, the other is removed too"
echo "pool scale: ok"
