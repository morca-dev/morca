#!/bin/sh
# Requests and grants (morca.resources), over tests/grants/grantee.mojo built
# as three pipelines, on the local runner against a host of 4 CPUs and 8 GB
# (MORCA_HOST_CPUS, MORCA_HOST_MEMORY_MB) with no reserve:
#
# - `morca config check` refuses bad ranges, `morca register` bad flags, and
#   `morca config show` gives each request with its source;
# - wide (1..3 CPUs, 5..6 GB) and narrow (5 GB) don't both fit: their runs
#   go one after the other, the one waiting held saying why;
# - with narrow at 1..2 GB they run at once;
# - each start's grant reaches its process (MORCA_GRANT_*, DISTA_WORKER_SLOTS
#   = "auto" as it is, for dista to size itself, morca.auto_count) and is
#   recorded on the run, its page and its JSON;
# - plain, with no request, is started as before: with no check, no grant,
#   while wide waits for more memory than the host has, which the
#   pipeline's page, the run's, their JSON and `morca status` say;
# - max_runs = "auto" runs as many at once as fit (4 of 2 GB in 8 GB), and
#   with no request to weigh, one at a time;
# - a remote worker (`morca worker`) admits a run against its own host the
#   same way, and passes the grant; one more than any worker of the pool
#   grants waits saying so.
#
# Needs MORCA_DATABASE_URL (pixi run test-grants starts a throwaway server),
# curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build
scripts/pipelines.sh wide narrow plain
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca
log=build/grants.log
: > "$log"
out=$PWD/build/grants-out
rm -rf "$out" build/grants-stage build/grants-*.out
mkdir -p "$out"
export GRANTEE_OUT="$out" GRANTEE_SLEEP=3
export MORCA_STALE_SECONDS=5 MORCA_START_SECONDS=20 MORCA_SAMPLE_SECONDS=0 MORCA_WATCHDOG_SECONDS=0
export MORCA_HOST_CPUS=4 MORCA_HOST_MEMORY_MB=8192 MORCA_RESERVE_CPUS=0 MORCA_RESERVE_MEMORY_MB=0
export MORCA_WORKERS=1
unset MORCA_RUNNER MORCA_CONFIG
pids=
sched=
cleanup() {
    for p in $pids $sched; do kill "$p" 2> /dev/null || true; done
}
trap cleanup EXIT
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    for f in build/grants-*.out; do [ -f "$f" ] && { echo "== $f"; tail -15 "$f"; }; done
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
start_sched() {
    ./build/morca scheduler >> build/grants-sched.out 2>&1 &
    sched=$!
}
stop_sched() {
    [ -z "$sched" ] || kill "$sched" 2> /dev/null || true
    [ -z "$sched" ] || wait "$sched" 2> /dev/null || true
    sched=
}
# Every run has ended.
ended() {
    is "SELECT count(*) FROM orca.runs WHERE status NOT IN ('succeeded', 'failed', 'cancelled')" 0
}

# Bad requests are refused, by the file's check and by a flag.
check() { env -u MORCA_DATABASE_URL ./build/morca config check "$@"; }
bad() {
    printf '[pipelines.wide]\n%s\n' "$1" > build/grants-bad.toml
    if check build/grants-bad.toml > build/grants-bad.out 2>&1; then
        fail "config check passed $1"
    fi
    grep -q "build/grants-bad.toml:2: \[pipelines.wide\] $2" build/grants-bad.out \
        || fail "config check of $1: $(cat build/grants-bad.out)"
}
bad 'memory_gb = "4..2"' "memory_gb: is GB over 0 and up to 65536"
bad 'memory_gb = 0' "memory_gb: is GB over 0"
bad 'memory_gb = true' "memory_gb: is GB, a number or a string"
bad 'cpus = 0' "cpus: is CPUs from 1 to 1024"
bad 'cpus = "2..1"' "cpus: is CPUs from 1 to 1024"
bad 'cpus = 1.5' "cpus: is a count or a string"
bad 'cpus = "many"' "cpus: is CPUs, N, MIN..MAX, auto or auto..MAX, not many"
bad 'memory_gb = "2..auto"' "memory_gb: is GB with auto as a range's lower end only"
bad 'cpus = "auto..0"' "cpus: is CPUs, auto..MAX with MAX from 1"
bad 'learn = "no"' "learn: is true or false"
if ./build/morca register --no-config --cpus 0 ./build/plain >> "$log" 2>&1; then
    fail "registered --cpus 0"
fi
if ./build/morca register --no-config --memory-gb 3..1 ./build/plain >> "$log" 2>&1; then
    fail "registered --memory-gb 3..1"
fi
cat > build/grants.toml << 'EOF'
[pipelines.wide]
cpus = "1..3"
memory_gb = "5..6"
env = { DISTA_WORKER_SLOTS = "auto", GRANTEE_PARALLEL = "auto" }

[pipelines.narrow]
memory_gb = 5

[pipelines.plain]
EOF
[ "$(check build/grants.toml 2>&1)" = "build/grants.toml: ok, 3 pipelines" ] \
    || fail "config check of grants.toml: $(check build/grants.toml 2>&1)"
for b in wide narrow plain; do
    ./build/morca register --config build/grants.toml "./build/$b" >> "$log" 2>&1 || fail "register $b"
done
./build/morca config show wide > build/grants-show.out 2>&1 || fail "config show wide"
grep -qE '^  cpus +1\.\.3 +morca.toml \[pipelines.wide\]$' build/grants-show.out \
    || fail "config show wide: $(cat build/grants-show.out)"
grep -qE '^  memory_gb +5\.\.6 +morca.toml \[pipelines.wide\]$' build/grants-show.out \
    || fail "config show wide: $(cat build/grants-show.out)"
./build/morca config show plain > build/grants-show.out 2>&1 || fail "config show plain"
if grep -qE '^  (cpus|memory_gb) ' build/grants-show.out; then
    fail "config show plain shows a request: $(cat build/grants-show.out)"
fi
is "SELECT coalesce(cpus, '-') || ' ' || memory_gb FROM orca.pipelines WHERE name = 'narrow'" "- 5" \
    || fail "narrow's request: $(q "SELECT cpus, memory_gb FROM orca.pipelines WHERE name = 'narrow'")"
echo "ok   bad requests are refused; config show gives a request and its source"

free_port port
base="http://127.0.0.1:$port"
MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
pids="$pids $!"
until_ 10 "morca ui didn't start" curl -fs "$base/" -o /dev/null
json() { curl -fsS -H 'Accept: application/json' "$base$1" || fail "GET $1"; }

# watch: until every run has ended, the most of wide's and narrow's runs
# running at once, and whether one was held for room.
watch() {
    most=0
    held=
    i=0
    while ! ended; do
        i=$((i + 1)); [ "$i" -lt 600 ] || fail "the runs didn't end: $(q "SELECT id, pipeline, status, held FROM orca.runs")"
        n=$(q "SELECT count(*) FROM orca.runs WHERE status = 'running' AND pipeline IN ('wide', 'narrow')")
        [ "$n" -le "$most" ] || most=$n
        h=$(q "SELECT held FROM orca.runs WHERE status = 'queued' AND held LIKE 'waiting: needs%' LIMIT 1")
        [ -z "$h" ] || held=$h
        sleep 0.1
    done
    [ "$(q "SELECT count(*) FROM orca.runs WHERE status <> 'succeeded'")" -eq 0 ] \
        || fail "runs that didn't succeed: $(q "SELECT id, pipeline, status, error FROM orca.runs WHERE status <> 'succeeded'")"
}

# Minimums that don't both fit: one after the other.
start_sched
./build/morca backfill narrow 2024-01 >> "$log" 2>&1 || fail "backfill narrow"
./build/morca backfill wide 2024-01 >> "$log" 2>&1 || fail "backfill wide"
watch
[ "$most" -eq 1 ] || fail "$most of wide's and narrow's runs ran at once in 8 GB"
echo "$held" | grep -qE '^waiting: needs 5 GB, [23] GB free of grants$' || fail "held: '$held'"
w1=$(q "SELECT id FROM orca.runs WHERE pipeline = 'wide'")
n1=$(q "SELECT id FROM orca.runs WHERE pipeline = 'narrow'")
echo "ok   runs whose minimums don't both fit run one after the other ($held)"

# The grants, passed and recorded.
is "SELECT request_cpus || ' ' || request_memory_gb || ' ' || grant_cpus || ' ' || grant_memory_mb FROM orca.runs WHERE id = $w1" "1..3 5..6 3 6144" \
    || fail "wide's run: $(q "SELECT request_cpus, request_memory_gb, grant_cpus, grant_memory_mb FROM orca.runs WHERE id = $w1")"
is "SELECT coalesce(request_cpus, '-') || ' ' || request_memory_gb || ' ' || coalesce(grant_cpus, 0) || ' ' || grant_memory_mb FROM orca.runs WHERE id = $n1" "- 5 0 5120" \
    || fail "narrow's run: $(q "SELECT request_cpus, request_memory_gb, grant_cpus, grant_memory_mb FROM orca.runs WHERE id = $n1")"
printf 'MORCA_GRANT_CPUS=3\nMORCA_GRANT_MEMORY_MB=6144\nDISTA_WORKER_SLOTS=auto\nGRANTEE_PARALLEL=3\n' > build/grants-want.out
cmp -s build/grants-want.out "$out/wide-2024-01.env" || fail "wide's process got: $(cat "$out/wide-2024-01.env")"
printf 'MORCA_GRANT_CPUS=-\nMORCA_GRANT_MEMORY_MB=5120\nDISTA_WORKER_SLOTS=-\nGRANTEE_PARALLEL=16\n' > build/grants-want.out
cmp -s build/grants-want.out "$out/narrow-2024-01.env" || fail "narrow's process got: $(cat "$out/narrow-2024-01.env")"
json "/runs/$w1" | jq -e '.run.request == {"cpus": "1..3", "memory_gb": "5..6"} and .run.grant == {"cpus": 3, "memory_mb": 6144}' > /dev/null \
    || fail "wide's run's JSON: $(json "/runs/$w1" | jq -c '.run')"
json "/runs/$n1" | jq -e '.run.grant == {"cpus": null, "memory_mb": 5120}' > /dev/null \
    || fail "narrow's run's JSON: $(json "/runs/$n1" | jq -c '.run')"
curl -fsS "$base/runs/$w1" > build/grants-run.out || fail "GET /runs/$w1"
grep -q '3 CPUs, 6 GB' build/grants-run.out || fail "wide's run's page doesn't show its grant"
grep -q '1..3 CPUs, 5..6 GB' build/grants-run.out || fail "wide's run's page doesn't show its request"
curl -fsS "$base/pipelines/wide" | grep -q '1..3 CPUs, 5..6 GB' || fail "wide's page doesn't show its request"
json /pipelines/wide | jq -e '.pipeline.request == {"cpus": "1..3", "memory_gb": "5..6"} and .pipeline.waiting == null' > /dev/null \
    || fail "wide's JSON: $(json /pipelines/wide | jq -c '.pipeline')"
echo "ok   each start's grant reaches its process and is recorded, shown and in the JSON"

# With room for both: at once.
./build/morca register --config build/grants.toml --memory-gb 1..2 ./build/narrow >> "$log" 2>&1 || fail "register narrow at 1..2 GB"
./build/morca backfill narrow 2024-02 >> "$log" 2>&1 || fail "backfill narrow"
./build/morca backfill wide 2024-02 >> "$log" 2>&1 || fail "backfill wide"
watch
[ "$most" -eq 2 ] || fail "$most of wide's and narrow's runs ran at once with room for both"
[ -z "$held" ] || fail "a run was held with room for both: $held"
is "SELECT sum(grant_memory_mb) FROM orca.runs WHERE partitions = '2024-02'" 8192 \
    || fail "the grants: $(q "SELECT id, pipeline, grant_cpus, grant_memory_mb FROM orca.runs WHERE partitions = '2024-02'")"
echo "ok   runs whose minimums fit run at once"

# No request: started as before, while wide waits for more than the host has.
stop_sched
export MORCA_HOST_MEMORY_MB=1024
start_sched
./build/morca backfill wide 2024-03 >> "$log" 2>&1 || fail "backfill wide"
w3=$(q "SELECT max(id) FROM orca.runs")
./build/morca backfill plain 2024-01 >> "$log" 2>&1 || fail "backfill plain"
p1=$(q "SELECT max(id) FROM orca.runs")
until_ 30 "plain's run didn't succeed: $(q "SELECT id, status, error FROM orca.runs WHERE id = $p1")" \
    is "SELECT status FROM orca.runs WHERE id = $p1" succeeded
want="waiting: needs 5 GB, more than the 1 GB this host grants at most"
is "SELECT status || ' ' || starts || ' ' || held FROM orca.runs WHERE id = $w3" "queued 0 $want" \
    || fail "wide's run: $(q "SELECT status, starts, held FROM orca.runs WHERE id = $w3")"
is "SELECT coalesce(request_cpus, request_memory_gb, grant_cpus::text, grant_memory_mb::text, 'none') FROM orca.runs WHERE id = $p1" none \
    || fail "plain's run has a request or a grant"
printf 'MORCA_GRANT_CPUS=-\nMORCA_GRANT_MEMORY_MB=-\nDISTA_WORKER_SLOTS=-\nGRANTEE_PARALLEL=16\n' > build/grants-want.out
cmp -s build/grants-want.out "$out/plain-2024-01.env" || fail "plain's process got: $(cat "$out/plain-2024-01.env")"
json "/runs/$p1" | jq -e '.run.request == null and .run.grant == null' > /dev/null || fail "plain's run's JSON"
json "/runs/$w3" | jq -e --arg w "$want" '.run.held == $w' > /dev/null || fail "wide's run's JSON: $(json "/runs/$w3" | jq -c .run)"
json /pipelines/wide | jq -e --arg w "$want" '.pipeline.waiting == $w' > /dev/null \
    || fail "wide's JSON: $(json /pipelines/wide | jq -c .pipeline)"
json /pipelines/plain | jq -e '.pipeline.request == null and .pipeline.waiting == null' > /dev/null || fail "plain's JSON"
curl -fsS "$base/pipelines/wide" | grep -q 'needs 5 GB, more than the 1 GB this host grants at most' \
    || fail "wide's page doesn't say why its run waits"
curl -fsS "$base/runs/$w3" | grep -q 'needs 5 GB, more than the 1 GB' || fail "wide's run's page doesn't say why it waits"
# And `morca status`, under the pipeline's line (#462).
./build/morca status > build/grants-status.out 2>&1 || fail "morca status"
grep -A1 '^wide ' build/grants-status.out | grep -qx "  $want" || fail "morca status: $(cat build/grants-status.out)"
./build/morca status wide > build/grants-status.out 2>&1 || fail "morca status wide"
grep -q "^  $w3 queued .* ($want)\$" build/grants-status.out || fail "morca status wide: $(cat build/grants-status.out)"
if curl -fsS "$base/pipelines/plain" | grep -q 'Requested<span'; then fail "plain's page shows a request"; fi
q "UPDATE orca.runs SET status = 'cancelled', ended = now() WHERE id = $w3" > /dev/null
stop_sched
echo "ok   a pipeline without a request is started as before, while one with a request waits"

# max_runs = "auto" (#266): as many at once as the host has room for, and
# with no request to weigh, one at a time.
export MORCA_HOST_MEMORY_MB=8192
cat > build/grants-auto.toml << 'EOF'
[pipelines.narrow]
memory_gb = 2
max_runs = "auto"

[pipelines.plain]
max_runs = "auto..3"
EOF
for b in narrow plain; do
    ./build/morca register --config build/grants-auto.toml "./build/$b" >> "$log" 2>&1 || fail "register $b with max_runs auto"
done
./build/morca config show narrow > build/grants-show.out 2>&1 || fail "config show narrow"
grep -qE '^  max_runs +auto +morca.toml \[pipelines.narrow\]$' build/grants-show.out \
    || fail "config show narrow: $(cat build/grants-show.out)"
is "SELECT max_runs || ' ' || max_runs_auto FROM orca.pipelines WHERE name = 'plain'" "3 true" \
    || fail "plain's max_runs: $(q "SELECT max_runs, max_runs_auto FROM orca.pipelines WHERE name = 'plain'")"
bad 'max_runs = "many"' 'max_runs: is a count, "auto" or "auto..N", not many'
bad 'max_runs = "auto..0"' 'max_runs: max_runs is a count from 1 to 10000, "auto" or "auto..N", not auto..0'
# most_of PIPELINE: until every run has ended, the most of its runs running
# at once, and why the last one held waited.
most_of() {
    most=0
    held=
    i=0
    while ! ended; do
        i=$((i + 1)); [ "$i" -lt 900 ] || fail "the runs didn't end: $(q "SELECT id, pipeline, status, held FROM orca.runs WHERE status NOT IN ('succeeded', 'failed', 'cancelled')")"
        n=$(q "SELECT count(*) FROM orca.runs WHERE status = 'running' AND pipeline = '$1'")
        [ "$n" -le "$most" ] || most=$n
        h=$(q "SELECT held FROM orca.runs WHERE status = 'queued' AND pipeline = '$1' AND held IS NOT NULL LIMIT 1")
        [ -z "$h" ] || held=$h
        sleep 0.1
    done
    [ "$(q "SELECT count(*) FROM orca.runs WHERE pipeline = '$1' AND status <> 'succeeded' AND partitions LIKE '2025-%'")" -eq 0 ] \
        || fail "$1's runs that didn't succeed: $(q "SELECT id, status, error FROM orca.runs WHERE pipeline = '$1' AND status <> 'succeeded'")"
}
start_sched
for m in 01 02 03 04 05 06; do
    ./build/morca backfill narrow 2025-$m >> "$log" 2>&1 || fail "backfill narrow 2025-$m"
done
most_of narrow
[ "$most" -eq 4 ] || fail "$most of narrow's 2 GB runs ran at once in 8 GB, not 4"
echo "$held" | grep -qE '^waiting: needs 2 GB, 0 GB free of grants$' || fail "narrow's held: '$held'"
echo "ok   max_runs = \"auto\" runs as many at once as the host has room for (4 of 2 GB in 8 GB)"
for m in 01 02 03; do
    ./build/morca backfill plain 2025-$m >> "$log" 2>&1 || fail "backfill plain 2025-$m"
done
most_of plain
[ "$most" -eq 1 ] || fail "$most of plain's runs ran at once with no request to weigh"
[ "$held" = 'waiting: max_runs = "auto" starts one run at a time until its runs have a request to weigh (cpus, memory_gb, learned or declared)' ] \
    || fail "plain's held: '$held'"
stop_sched
./build/morca register --config build/grants.toml ./build/narrow >> "$log" 2>&1 || fail "register narrow back"
./build/morca register --config build/grants.toml ./build/plain >> "$log" 2>&1 || fail "register plain back"
echo "ok   with no request to weigh, max_runs = \"auto\" starts one run at a time"

# fill_max_runs = "auto" (#322): fill runs too, as many as fit.
cat > build/grants-fill.toml << 'EOF'
[pipelines.narrow]
memory_gb = 2
fills = "all"
fill_max_runs = "auto"
EOF
./build/morca register --config build/grants-fill.toml ./build/narrow >> "$log" 2>&1 || fail "register narrow with fills"
is "SELECT fill_max_runs || ' ' || fill_max_runs_auto FROM orca.pipelines WHERE name = 'narrow'" "64 true" \
    || fail "narrow's fill_max_runs: $(q "SELECT fill_max_runs, fill_max_runs_auto FROM orca.pipelines WHERE name = 'narrow'")"
./build/morca config show narrow 2>&1 | grep -qE '^  fill_max_runs +auto ' || fail "config show: $(./build/morca config show narrow 2>&1)"
start_sched
most=0
i=0
until [ "$(q "SELECT count(*) FROM orca.runs WHERE pipeline = 'narrow' AND trigger = 'fill' AND status = 'succeeded'")" -ge 8 ]; do
    i=$((i + 1)); [ "$i" -lt 900 ] || fail "fill runs didn't run: $(q "SELECT status, count(*) FROM orca.runs WHERE trigger = 'fill' GROUP BY 1")"
    n=$(q "SELECT count(*) FROM orca.runs WHERE pipeline = 'narrow' AND trigger = 'fill' AND status = 'running'")
    [ "$n" -le "$most" ] || most=$n
    sleep 0.1
done
stop_sched
q "UPDATE orca.runs SET status = 'cancelled', ended = now() WHERE trigger = 'fill' AND status IN ('queued', 'running')" > /dev/null
q "UPDATE orca.pipelines SET fills = NULL WHERE name = 'narrow'" > /dev/null
[ "$most" -eq 4 ] || fail "$most of narrow's 2 GB fill runs ran at once in 8 GB, not 4"
./build/morca register --config build/grants.toml ./build/narrow >> "$log" 2>&1 || fail "register narrow back"
echo "ok   fill_max_runs = \"auto\" runs as many fill runs at once as fit (4 of 2 GB in 8 GB)"

# On a remote worker, against its own host.
export MORCA_HOST_MEMORY_MB=8192
./build/morca register --config build/grants.toml --placement worker:g ./build/wide >> "$log" 2>&1 || fail "register wide on a worker"
tok=$(./build/morca worker-token create --pool g --label grants 2>> "$log") || fail "worker-token create"
start_sched
./build/morca backfill wide 2024-04 >> "$log" 2>&1 || fail "backfill wide"
w4=$(q "SELECT max(id) FROM orca.runs")
env -u MORCA_DATABASE_URL -u MORCA_RESERVE_CPUS -u MORCA_RESERVE_MEMORY_MB \
    MORCA_HOST_MEMORY_MB=4096 MORCA_WORKER_TOKEN="$tok" \
    ./build/morca worker --pool g --remote "$base" --poll-seconds 0.3 --name small \
    --dir "$PWD/build/grants-stage" > build/grants-worker-small.out 2>&1 &
small=$!
pids="$pids $small"
# 4 GB less the worker's 512 MB reserve.
until_ 20 "the small worker didn't hold wide's run: $(q "SELECT status, held FROM orca.runs WHERE id = $w4")" \
    is "SELECT held FROM orca.runs WHERE id = $w4" "waiting: needs 5 GB, more than the 3.5 GB a worker of pool g grants at most"
kill "$small" 2> /dev/null || true
wait "$small" 2> /dev/null || true
env -u MORCA_DATABASE_URL MORCA_WORKER_TOKEN="$tok" \
    ./build/morca worker --pool g --remote "$base" --poll-seconds 0.3 --name big \
    --dir "$PWD/build/grants-stage" > build/grants-worker-big.out 2>&1 &
pids="$pids $!"
until_ 60 "wide's run didn't succeed on the worker: $(q "SELECT id, status, error, held FROM orca.runs WHERE id = $w4")" \
    is "SELECT status FROM orca.runs WHERE id = $w4" succeeded
is "SELECT placement || ' ' || grant_cpus || ' ' || grant_memory_mb FROM orca.runs WHERE id = $w4" "worker:g 3 6144" \
    || fail "wide's run on the worker: $(q "SELECT placement, grant_cpus, grant_memory_mb FROM orca.runs WHERE id = $w4")"
printf 'MORCA_GRANT_CPUS=3\nMORCA_GRANT_MEMORY_MB=6144\nDISTA_WORKER_SLOTS=auto\nGRANTEE_PARALLEL=3\n' > build/grants-want.out
cmp -s build/grants-want.out "$out/wide-2024-04.env" || fail "wide's process on the worker got: $(cat "$out/wide-2024-04.env")"
echo "ok   a worker admits a run against its own host, and passes the grant"
echo "grants: ok"
