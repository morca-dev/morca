#!/bin/sh
# What a run's processes use (morca.usage), over tests/usage/hog.mojo, whose
# step holds 200 MiB while a child of its own holds 100 MiB more, each
# burning a core for 4 s:
#
# - a run on the local runner and a control-placed one, which the scheduler
#   samples each tick, and one on `morca worker`, which samples it and sends
#   the samples with /api/worker/exited, each record on their attempt a
#   peak within a margin of what was held (on Linux the tree's, both
#   processes; on macOS wait4's largest process), their CPU seconds, and
#   on Linux the most cores they kept busy;
# - the run's page, the attempt's and the pipeline's (its Resources card:
#   p50 and max of each) show them, and their JSON has them; `morca status
#   hog` and `hog status <run>` print them;
# - from the three, the request they suggest (morca.recommend): the largest
#   peak plus 15% in quarter GBs, on the card, in the JSON and in `morca
#   config show`, not applied;
# - registered with `memory_gb = "auto"`, a run on the local runner is
#   granted it, recording that it's learned from 3 runs, and the card and
#   `morca config show` say it's applied; with `learn = false`, the next run
#   has no request, recording `default`;
# - on a host that grants a run less than it learned, the next run starts
#   capped at what the host grants, logged once and shown (#462).
#
# Needs MORCA_DATABASE_URL (pixi run test-usage starts a throwaway server),
# curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build
scripts/pipelines.sh hog &
b1=$!
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca &
b2=$!
wait "$b1"
wait "$b2"
log=build/usage.log
: > "$log"
rm -rf build/usage-stage build/usage-*.out
export MORCA_STALE_SECONDS=5 MORCA_START_SECONDS=20 MORCA_SAMPLE_SECONDS=0
export MORCA_CONTROL_MEMORY_MB=2048
pids=
cleanup() {
    for p in $pids; do kill "$p" 2> /dev/null || true; done
}
trap cleanup EXIT
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    for f in build/usage-*.out; do [ -f "$f" ] && { echo "== $f"; tail -15 "$f"; }; done
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
linux=false
[ "$(uname)" = Linux ] && linux=true
MB=1048576

# check RUN WHERE: the run succeeded, and its one attempt's usage is within
# the margins.
check() {
    run=$1; where=$2
    until_ 60 "$where: run $run didn't succeed: $(q "SELECT id, status, error FROM orca.runs WHERE id = $run")" \
        is "SELECT status FROM orca.runs WHERE id = $run" succeeded
    # Recorded when the process is reaped, just after it ends.
    until_ 10 "$where: no usage: $(q "SELECT * FROM orca.attempts")" \
        is "SELECT count(*) FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $run AND a.cpu_seconds IS NOT NULL" 1
    row=$(q "SELECT a.peak_rss_bytes, a.cpu_seconds, coalesce(a.peak_cpus, -1) FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $run")
    echo "$where: run $run: $row" >> "$log"
    peak=$(echo "$row" | cut -d'|' -f1)
    cpu=$(echo "$row" | cut -d'|' -f2)
    cores=$(echo "$row" | cut -d'|' -f3)
    if $linux; then
        # Both processes' 300 MiB, sampled together, and the runtimes'.
        lo=$((300 * MB)); hi=$((500 * MB))
    else
        # wait4's largest process: the step's 200 MiB.
        lo=$((200 * MB)); hi=$((400 * MB))
    fi
    [ "$peak" -ge "$lo" ] && [ "$peak" -le "$hi" ] \
        || fail "$where: run $run's peak $peak isn't within $lo..$hi"
    awk -v c="$cpu" 'BEGIN { exit !(c >= 6 && c <= 14) }' \
        || fail "$where: run $run's CPU $cpu s isn't within 6..14 (2 cores for 4 s)"
    if $linux; then
        awk -v c="$cores" 'BEGIN { exit !(c >= 1.3 && c <= 3.0) }' \
            || fail "$where: run $run's peak cores $cores isn't within 1.3..3.0"
    else
        [ "$cores" = -1 ] || fail "$where: macOS gave run $run peak cores: $cores"
    fi
}

free_port port
base="http://127.0.0.1:$port"
./build/morca register ./build/hog >> "$log" 2>&1 || fail "register"
MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
pids="$pids $!"
until_ 10 "morca ui didn't start" curl -fs "$base/" -o /dev/null
./build/morca scheduler > build/usage-sched.out 2>&1 &
sched=$!
pids="$pids $sched"

# On the local runner.
./build/morca backfill hog 2024-01 >> "$log" 2>&1 || fail "backfill 2024-01"
r1=$(q "SELECT max(id) FROM orca.runs")
check "$r1" local

# On the control host.
./build/morca register --placement control ./build/hog >> "$log" 2>&1 || fail "register control"
./build/morca backfill hog 2024-02 >> "$log" 2>&1 || fail "backfill 2024-02"
r2=$(q "SELECT max(id) FROM orca.runs")
check "$r2" control
is "SELECT placement FROM orca.runs WHERE id = $r2" control \
    || fail "run $r2 wasn't placed on the control host: $(q "SELECT id, placement FROM orca.runs")"

# On a remote worker, whose samples reach the database through the UI.
./build/morca register --placement worker:u ./build/hog >> "$log" 2>&1 || fail "register worker"
tok=$(./build/morca worker-token create --pool u --label usage 2>> "$log") || fail "worker-token create"
./build/morca backfill hog 2024-03 >> "$log" 2>&1 || fail "backfill 2024-03"
r3=$(q "SELECT max(id) FROM orca.runs")
env -u MORCA_DATABASE_URL -u MORCA_PGDATA MORCA_WORKER_TOKEN="$tok" \
    ./build/morca worker --pool u --remote "$base" --poll-seconds 0.3 \
    --dir "$PWD/build/usage-stage" > build/usage-worker.out 2>&1 &
pids="$pids $!"
check "$r3" worker
is "SELECT placement FROM orca.runs WHERE id = $r3" worker:u \
    || fail "run $r3 didn't run on the worker: $(q "SELECT id, placement FROM orca.runs")"

# The pages and their JSON.
curl -fs "$base/runs/$r1" > build/usage-run.out || fail "GET /runs/$r1"
grep -q 'Peak memory<span class="help">' build/usage-run.out || fail "the run's page has no Peak memory"
grep -q 'CPU used<span class="help">' build/usage-run.out || fail "the run's page has no CPU used"
curl -fs -H 'Accept: application/json' "$base/runs/$r1" > build/usage-run.json || fail "GET /runs/$r1 JSON"
jq -e '.run.usage.peak_rss_bytes > 0 and .run.usage.cpu_seconds > 0 and .steps[0].usage.peak_rss_bytes == .run.usage.peak_rss_bytes' \
    build/usage-run.json > /dev/null || fail "the run's JSON: $(cat build/usage-run.json)"
a1=$(q "SELECT a.id FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $r1")
curl -fs -H 'Accept: application/json' "$base/runs/$r1/attempts/$a1" > build/usage-attempt.json \
    || fail "GET the attempt's JSON"
jq -e '.attempt.usage.peak_rss_bytes > 0' build/usage-attempt.json > /dev/null \
    || fail "the attempt's JSON: $(cat build/usage-attempt.json)"
curl -fs "$base/runs/$r1/attempts/$a1" | grep -q 'Peak memory<span class="help">' \
    || fail "the attempt's page has no Peak memory"
curl -fs "$base/pipelines/hog" > build/usage-pipeline.out || fail "GET /pipelines/hog"
grep -q 'id="resources"><h2>Resources' build/usage-pipeline.out || fail "the pipeline's page has no Resources card"
grep -q 'its last 3 runs' build/usage-pipeline.out || fail "the Resources card: $(grep -o 'id="resources".*' build/usage-pipeline.out | head -c 2000)"
curl -fs -H 'Accept: application/json' "$base/pipelines/hog" > build/usage-pipeline.json \
    || fail "GET /pipelines/hog JSON"
jq -e '.usage.runs == 3 and .usage.peak_rss_bytes.max >= .usage.peak_rss_bytes.p50 and .usage.peak_rss_bytes.p50 > 0 and .usage.cpu_seconds.max > 0' \
    build/usage-pipeline.json > /dev/null || fail "the pipeline's JSON: $(jq .usage build/usage-pipeline.json)"
if $linux; then
    jq -e '.usage.peak_cpus.max > 1' build/usage-pipeline.json > /dev/null \
        || fail "the pipeline's peak cores: $(jq .usage build/usage-pipeline.json)"
fi
# The request learned from them: of three runs, p95 is the largest.
grep -qE 'Learned<span class="help">.*learned from 3 runs: [0-9.]+ GB' build/usage-pipeline.out \
    || fail "the Resources card's Learned: $(grep -o 'id="resources".*' build/usage-pipeline.out | head -c 3000)"
jq -e '.learned.runs == 3 and .learned.applied == false and .learned.clamped == null
    and .learned.memory_mb == ((.usage.peak_rss_bytes.max / 1048576 * 1.15 / 256 | ceil) * 256)' \
    build/usage-pipeline.json > /dev/null || fail "the pipeline's learned: $(jq '{usage, learned}' build/usage-pipeline.json)"
if $linux; then
    jq -e '.learned.cpus >= 1 and .learned.cpus <= 3' build/usage-pipeline.json > /dev/null \
        || fail "the learned CPUs: $(jq .learned build/usage-pipeline.json)"
else
    jq -e '.learned.cpus == null' build/usage-pipeline.json > /dev/null \
        || fail "macOS learned CPUs: $(jq .learned build/usage-pipeline.json)"
fi

# What the commands print.
./build/morca status hog > build/usage-status.out 2>&1 || fail "morca status hog"
grep -qE "^  $r1 succeeded backfill 2024-01 .* peak [0-9]+ MB, CPU [0-9.]+ s" build/usage-status.out \
    || fail "morca status: $(cat build/usage-status.out)"
./build/hog status "$r2" > build/usage-binary.out 2>&1 || fail "hog status"
grep -qE "^hog 2024-02 succeeded \(peak [0-9]+ MB, CPU [0-9.]+ s" build/usage-binary.out \
    || fail "hog status: $(cat build/usage-binary.out)"
./build/morca config show hog > build/usage-config.out 2>&1 || fail "morca config show hog"
grep -qE "^  learned from 3 runs: [0-9.]+ GB.*; shown, not applied: its request isn't auto$" build/usage-config.out \
    || fail "config show: $(cat build/usage-config.out)"
[ "$(./build/morca config show hog --json | jq -r .learned.memory_mb)" = "$(jq -r .learned.memory_mb build/usage-pipeline.json)" ] \
    || fail "config show --json: $(./build/morca config show hog --json)"

# "auto" (morca.recommend): the next run on the local runner is granted the
# learned memory, and records where it came from.
mb=$(jq -r .learned.memory_mb build/usage-pipeline.json)
./build/morca register --placement default --memory-gb auto ./build/hog >> "$log" 2>&1 \
    || fail "register --memory-gb auto"
./build/morca backfill hog 2024-04 >> "$log" 2>&1 || fail "backfill 2024-04"
r4=$(q "SELECT max(id) FROM orca.runs")
check "$r4" auto
is "SELECT placement || ' ' || request_source || ' ' || request_runs || ' ' || grant_memory_mb FROM orca.runs WHERE id = $r4" \
    "local learned 3 $mb" \
    || fail "run $r4's learned request: $(q "SELECT placement, request_cpus, request_memory_gb, request_source, request_runs, grant_memory_mb FROM orca.runs WHERE id = $r4")"
# Cached on the pipeline, learned again once r4's peaks were recorded.
is "SELECT (learned->>'runs') || ' ' || (learned->>'key') FROM orca.pipelines WHERE name = 'hog'" "4 ${r4}m/0//auto" \
    || fail "the cached learned request: $(q "SELECT learned FROM orca.pipelines WHERE name = 'hog'")"
grep -q "granted hog run $r4 .* learned from 3 runs" build/usage-sched.out \
    || fail "the scheduler's log: $(grep granted build/usage-sched.out)"
curl -fs -H 'Accept: application/json' "$base/runs/$r4" > build/usage-run.json || fail "GET /runs/$r4 JSON"
jq -e --argjson mb "$mb" '.run.request_source == {"source": "learned", "runs": 3, "text": "learned from 3 runs"}
    and .run.grant.memory_mb == $mb and (.run.request.memory_gb | test("^[0-9.]+$"))' \
    build/usage-run.json > /dev/null || fail "run $r4's JSON: $(jq -c .run build/usage-run.json)"
curl -fs "$base/runs/$r4" | grep -qE 'Requested<span class="help">.*[0-9.]+ GB <span class="muted">· learned from 3 runs' \
    || fail "run $r4's page: $(curl -fs "$base/runs/$r4" | grep -o 'Requested<span.\{0,600\}')"
curl -fs -H 'Accept: application/json' "$base/pipelines/hog" | jq -e '.learned.applied == true' > /dev/null \
    || fail "the pipeline's learned isn't applied: $(curl -fs -H 'Accept: application/json' "$base/pipelines/hog" | jq -c .learned)"
curl -fs "$base/pipelines/hog" | grep -q '· applied' || fail "the Resources card doesn't say applied"
./build/morca config show hog | grep -qE '^  learned from 4 runs: .*; applied: its request is auto$' \
    || fail "config show auto: $(./build/morca config show hog)"

# learn = false: auto falls back to no request, recorded as the default.
printf '[pipelines.hog]\nmemory_gb = "auto"\nlearn = false\n' > build/usage-morca.toml
[ "$(env -u MORCA_DATABASE_URL ./build/morca config check build/usage-morca.toml 2>&1)" = "build/usage-morca.toml: ok, 1 pipeline" ] \
    || fail "config check: $(env -u MORCA_DATABASE_URL ./build/morca config check build/usage-morca.toml 2>&1)"
./build/morca register --config build/usage-morca.toml ./build/hog >> "$log" 2>&1 || fail "register learn = false"
./build/morca backfill hog 2024-05 >> "$log" 2>&1 || fail "backfill 2024-05"
r5=$(q "SELECT max(id) FROM orca.runs")
check "$r5" "learn = false"
is "SELECT request_source || ' ' || coalesce(request_runs, 0) || ' ' || coalesce(grant_memory_mb, 0) FROM orca.runs WHERE id = $r5" "default 0 0" \
    || fail "run $r5's request: $(q "SELECT request_memory_gb, request_source, request_runs, grant_memory_mb FROM orca.runs WHERE id = $r5")"
curl -fs -H 'Accept: application/json' "$base/runs/$r5" | jq -e '.run.request == null and .run.request_source.source == "default"' > /dev/null \
    || fail "run $r5's JSON: $(curl -fs -H 'Accept: application/json' "$base/runs/$r5" | jq -c .run)"
./build/morca config show hog > build/usage-config.out 2>&1 || fail "config show learn = false"
grep -qE '^  learn +false +morca.toml \[pipelines.hog\]$' build/usage-config.out \
    && grep -qE '^  learned from 5 runs: .*; not applied: learn = false$' build/usage-config.out \
    || fail "config show learn = false: $(cat build/usage-config.out)"
curl -fs "$base/pipelines/hog" | grep -q '· not applied' || fail "the Resources card doesn't say not applied"

# Learned more than the host grants (#462): capped at its most, the run
# starts rather than waiting forever, and the cap is logged once and shown.
printf '[pipelines.hog]\nmemory_gb = "auto"\n' > build/usage-morca.toml
./build/morca register --config build/usage-morca.toml ./build/hog >> "$log" 2>&1 \
    || fail "register memory_gb = auto, learning"
mb=$(./build/morca config show hog --json | jq -r .learned.memory_mb)
cap=$((mb - 64))
kill "$sched" 2> /dev/null || true
wait "$sched" 2> /dev/null || true
MORCA_HOST_MEMORY_MB=$cap MORCA_RESERVE_MEMORY_MB=0 ./build/morca scheduler > build/usage-sched-capped.out 2>&1 &
sched=$!
pids="$pids $sched"
./build/morca backfill hog 2024-06 >> "$log" 2>&1 || fail "backfill 2024-06"
r6=$(q "SELECT max(id) FROM orca.runs")
until_ 60 "run $r6 didn't start capped: $(q "SELECT status, held FROM orca.runs WHERE id = $r6")" \
    is "SELECT status <> 'queued' FROM orca.runs WHERE id = $r6" t
is "SELECT request_source || ' ' || grant_memory_mb FROM orca.runs WHERE id = $r6" "learned $cap" \
    || fail "run $r6's capped request: $(q "SELECT request_memory_gb, request_source, grant_memory_mb FROM orca.runs WHERE id = $r6")"
[ "$(grep -c "morca: pipeline hog memory: learned .* GB, capped at .* GB, this host's most" build/usage-sched-capped.out)" -eq 1 ] \
    || fail "the cap wasn't logged once: $(grep -n -e memory: -e granted build/usage-sched-capped.out)"
grep -q "granted hog run $r6 .* (learned .* GB, capped at .* GB, this host's most)" build/usage-sched-capped.out \
    || fail "the grant's log: $(grep granted build/usage-sched-capped.out)"
./build/morca config show hog | grep -qE "^  learned from [0-9]+ runs: .*, capped at [0-9.]+ GB, this host's most \(" \
    || fail "config show capped: $(./build/morca config show hog)"
curl -fs -H 'Accept: application/json' "$base/pipelines/hog" | jq -e '.learned.capped | test("^capped at [0-9.]+ GB, this host.s most$")' > /dev/null \
    || fail "the pipeline's JSON: $(curl -fs -H 'Accept: application/json' "$base/pipelines/hog" | jq -c .learned)"
curl -fs "$base/pipelines/hog" | grep -q "capped at [0-9.]* GB, this host" \
    || fail "the Resources card doesn't say capped"
until_ 60 "run $r6 didn't end: $(q "SELECT status FROM orca.runs WHERE id = $r6")" \
    is "SELECT status IN ('succeeded', 'failed') FROM orca.runs WHERE id = $r6" t
echo "usage: ok"
