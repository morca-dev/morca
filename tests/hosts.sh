#!/bin/sh
# Self-hosted pools and `morca host` (#220): morca ui and a `morca worker` of
# pool t, with no database, over tests/pool/fillwk.mojo placed worker:t, and
# a [pools.t] with no provider:
#
# - the pool is registered (orca.pool_settings) and isn't one morca grows
#   (orca.pools);
# - a claim's spec carries the pool's env and secret IDs under the
#   pipeline's own, and the pool's max_runs, and a worker started without
#   --max-runs takes it: two runs at once, held by FILLWK_HOLD, which only
#   the pool's env sets;
# - `morca host list` shows the host; `morca host remove` is refused while
#   it runs;
# - `morca host drain` (audited): the worker finishes its runs and claims no
#   more, the queued run waits, and Ops and /api/workers say draining;
#   `morca host undrain` and it claims again;
# - `morca host remove` (audited) revokes the token, and the worker exits.
#
# Needs MORCA_DATABASE_URL (pixi run test-hosts starts a throwaway server),
# curl and jq.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
scripts/pipelines.sh fillwk &
b1=$!
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca &
b2=$!
wait "$b1"
wait "$b2"
log=build/hosts.log
: > "$log"
proj=$PWD/build/hosts-project
export MORCA_LOGS="$PWD/build/hosts-logs"
rm -rf "$proj" "$MORCA_LOGS" build/hosts-stage build/hosts-*.out
mkdir -p "$proj"
export MORCA_STALE_SECONDS=5 MORCA_START_SECONDS=10 MORCA_SAMPLE_SECONDS=0
unset MORCA_IMAGE
hold="$PWD/build/hosts-hold"
pids=
cleanup() {
    for p in $pids; do kill "$p" 2> /dev/null || true; done
    rm -f "$hold"
}
trap cleanup EXIT
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    for f in build/hosts-*.out; do [ -f "$f" ] && { echo "== $f"; tail -15 "$f"; }; done
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
# until_ SECONDS WHAT CONDITION...: waits for the condition, or fails.
until_() {
    t=$1; what=$2; shift 2
    i=0
    until "$@"; do
        i=$((i + 1)); [ "$i" -lt $((t * 10)) ] || fail "$what"; sleep 0.1
    done
}
is() { [ "$(q "$1")" = "$2" ]; }
. "$PWD/tests/port.sh"
free_port port
base="http://127.0.0.1:$port"
queue() {
    q "INSERT INTO orca.runs (pipeline, registry_hash, partitions, trigger, status) SELECT name, registry_hash, '$1', 'ui', 'queued' FROM orca.pipelines WHERE name = 'fillwk' RETURNING id" | head -1
}
running() { q "SELECT count(*) FROM orca.runs WHERE status = 'running' AND heartbeat IS NOT NULL"; }

# --- A pool with no provider is registered, with its settings ---
cat > "$proj/morca.toml" << EOF
[pools.t]
max_runs = 2
env = { FILLWK_HOLD = "$hold", WHO = "pool" }
secrets = { GH_PAT = "orca/gh" }

[pipelines.fillwk]
placement = "worker:t"
max_runs = 4
env = { WHO = "pipeline" }
EOF
./build/morca config check "$proj/morca.toml" >> "$log" 2>&1 || fail "config check"
./build/morca register --config "$proj/morca.toml" ./build/fillwk >> "$log" 2>&1 || fail "register"
is "SELECT count(*) FROM orca.pool_settings WHERE name = 't' AND provider IS NULL AND max_runs = 2" 1 \
    || fail "the pool's settings: $(q "SELECT * FROM orca.pool_settings")"
is "SELECT count(*) FROM orca.pools" 0 || fail "a self-hosted pool is in orca.pools"
grep -q '^pool t (self-hosted)$' "$log" || fail "register didn't say it recorded pool t"
echo "ok   a pool with no provider is registered, and not grown"

MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
pids="$pids $!"
until_ 10 "morca ui didn't start" curl -fs "$base/" -o /dev/null
tok=$(./build/morca worker-token create --pool t --label bgent 2>> "$log") || fail "worker-token create"
probe=$(./build/morca worker-token create --pool t --label probe 2>> "$log") || fail "worker-token create"
id=$(q "SELECT id FROM orca.workers WHERE label = 'bgent'")

# --- A claim's spec has the pool's env and secrets, and its max_runs ---
r0=$(queue 2024-01)
got=$(curl -fsS -H "Authorization: Bearer $probe" -d '{"pool": "t", "slots": 8, "name": "probe", "image": "", "running": ""}' \
    "$base/api/worker/claim") || fail "the probe's claim"
[ "$(echo "$got" | jq -r .run.run)" = "$r0" ] || fail "the probe got: $got"
echo "$got" | jq -e --arg h "$hold" '.max_runs == 2
    and ([.run.env[] | select(.name == "FILLWK_HOLD") | .value] == [$h])
    and ([.run.env[] | select(.name == "WHO") | .value] == ["pipeline"])
    and ([.run.secrets[] | select(.name == "GH_PAT") | .id] == ["orca/gh"])' > /dev/null \
    || fail "the spec: $got"
# At the pool's max_runs already: given nothing.
full=$(curl -fsS -H "Authorization: Bearer $probe" -d '{"pool": "t", "slots": 8, "name": "probe", "image": "", "running": "1,2"}' \
    "$base/api/worker/claim") || fail "the probe's second claim"
echo "$full" | jq -e '.run == null' > /dev/null || fail "a worker at the pool's max_runs was given a run: $full"
start=$(echo "$got" | jq -r .run.start)
curl -fsS -H "Authorization: Bearer $probe" -d "{\"pool\": \"t\", \"run\": $r0, \"start\": $start, \"why\": \"probe\"}" \
    "$base/api/worker/release" > /dev/null || fail "the release"
is "SELECT status FROM orca.runs WHERE id = $r0" queued || fail "run $r0 wasn't put back"
echo "ok   a claim carries the pool's env and secret IDs under the pipeline's, and its max_runs"

# --- A worker without --max-runs takes the pool's: two at once ---
touch "$hold"
r1=$(queue 2024-02)
r2=$(queue 2024-03)
env -u MORCA_DATABASE_URL -u MORCA_PGDATA -u FILLWK_HOLD MORCA_WORKER_TOKEN="$tok" \
    MORCA_SECRET_FETCH="sh $PWD/tests/fake_secret.sh" \
    ./build/morca worker --pool t --remote "$base" --poll-seconds 0.3 \
    --dir "$PWD/build/hosts-stage" --name bgent > build/hosts-w.out 2>&1 &
w=$!
pids="$pids $w"
until_ 20 "the worker didn't run two at once: $(q "SELECT id, status, heartbeat FROM orca.runs")" \
    is "SELECT count(*) FROM orca.runs WHERE status = 'running' AND heartbeat IS NOT NULL" 2
sleep 2
[ "$(running)" = 2 ] || fail "the held runs didn't hold (the pool's env): $(q "SELECT id, status FROM orca.runs")"
is "SELECT count(*) FROM orca.runs WHERE status = 'queued'" 1 || fail "more than the pool's max_runs: $(q "SELECT id, status FROM orca.runs")"
grep -q "up to 2 runs at once (the pool's max_runs)" build/hosts-w.out || fail "the worker didn't take the pool's max_runs"
echo "ok   a worker without --max-runs runs the pool's max_runs at once, with the pool's env"

# --- morca host list, and remove refused while it runs ---
./build/morca host list --pool t > build/hosts-list.out 2>> "$log" || fail "host list"
grep -q "^$id t bgent live .* runs=2 " build/hosts-list.out || fail "host list: $(cat build/hosts-list.out)"
if ./build/morca host remove "$id" > build/hosts-remove.out 2>&1; then fail "remove of a busy host wasn't refused"; fi
grep -q "drain it first" build/hosts-remove.out || fail "the refusal: $(cat build/hosts-remove.out)"
is "SELECT count(*) FROM orca.workers WHERE id = $id AND revoked IS NULL" 1 || fail "the refused remove revoked it"
echo "ok   morca host list shows it, and remove is refused while it runs"

# --- Drain: it finishes its runs, claims no more ---
./build/morca host drain "$id" >> "$log" 2>&1 || fail "host drain"
is "SELECT count(*) FROM orca.audit WHERE action = 'host drain' AND detail = 'id=$id' AND source = 'local'" 1 \
    || fail "the drain's audit: $(q "SELECT username, action, detail FROM orca.audit")"
until_ 10 "the worker didn't say it drains" grep -q "asked to drain" build/hosts-w.out
./build/morca host list > build/hosts-list.out 2>> "$log" || fail "host list"
grep -q "^$id t bgent draining " build/hosts-list.out || fail "host list: $(cat build/hosts-list.out)"
curl -fsS "$base/api/workers" | jq -e --argjson id "$id" '.workers[] | select(.id == $id) | .draining' > /dev/null \
    || fail "/api/workers: $(curl -fsS "$base/api/workers")"
curl -fsS "$base/api/pools" | grep -q draining || fail "/api/pools doesn't say draining"
rm -f "$hold"
until_ 30 "the drained worker didn't finish its runs: $(q "SELECT id, status, error FROM orca.runs")" \
    is "SELECT count(*) FROM orca.runs WHERE status = 'succeeded'" 2
sleep 2
is "SELECT count(*) FROM orca.runs WHERE status = 'queued' AND starts = 0" 1 \
    || fail "a draining worker claimed: $(q "SELECT id, status, starts FROM orca.runs")"
kill -0 "$w" 2> /dev/null || fail "the draining worker exited"
echo "ok   morca host drain: the worker finishes its runs and claims no more"

./build/morca host undrain "$id" >> "$log" 2>&1 || fail "host undrain"
until_ 30 "the undrained worker didn't finish the last run: $(q "SELECT id, status, error FROM orca.runs")" \
    is "SELECT count(*) FROM orca.runs WHERE status = 'succeeded'" 3
grep -q "no longer draining" build/hosts-w.out || fail "the worker didn't say it claims again"
echo "ok   morca host undrain: it claims again"

# --- Remove: the token is revoked, and the worker exits ---
./build/morca host remove "$id" >> "$log" 2>&1 || fail "host remove"
is "SELECT count(*) FROM orca.audit WHERE action = 'host remove' AND detail = 'id=$id running=0'" 1 \
    || fail "the remove's audit: $(q "SELECT username, action, detail FROM orca.audit")"
code=0
i=0
while kill -0 "$w" 2> /dev/null; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "the removed host's worker didn't exit"; sleep 0.1
done
wait "$w" || code=$?
[ "$code" = 3 ] || fail "the removed host's worker exited $code, not 3"
./build/morca host list > build/hosts-list.out 2>> "$log" || fail "host list"
grep -q "^$id t bgent revoked " build/hosts-list.out || fail "host list: $(cat build/hosts-list.out)"
echo "ok   morca host remove revokes its token, and its worker exits"
grep -q "$tok" "$log" build/hosts-*.out && fail "a token is in a log"
echo "hosts: ok"
