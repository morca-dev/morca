#!/bin/sh
# Pipeline priority and the order of a pass (#421), on the local runner
# against a host with room for one run of 2 GB (MORCA_HOST_MEMORY_MB, no
# reserve), each pass one `morca tick`. Over tests/grants/grantee.mojo built
# as alpha, bravo and zulu, and examples/daily.mojo:
#
# - `priority` is checked by `config check` (an integer), recorded by
#   register, shown by `config show` with its source, laid over by an
#   overlay, written by `config export`, and on the pipeline's page;
# - the higher priority starts first whatever the names, and the run that
#   waits names the pipeline holding the room; equal priorities go by name;
# - a scheduled run starts before a fill run, though the fill pipeline's
#   name sorts first;
# - a due retry starts before a newer queued run of its pipeline.
#
# Needs MORCA_DATABASE_URL (pixi run test-priority starts a throwaway
# server), curl, jq and python3.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build
for b in alpha bravo zulu; do
    # shellcheck disable=SC2086
    scripts/mojo-build.sh -I src $DEP_INC -D GRANTEE=$b tests/grants/grantee.mojo -o "build/$b"
done
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC examples/daily.mojo -o build/daily
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca
log=build/priority.log
: > "$log"
proj=$PWD/build/priority-project
out=$PWD/build/priority-out
rm -rf "$proj" "$out"
mkdir -p "$proj" "$out"
export GRANTEE_OUT="$out" GRANTEE_SLEEP=3 MORCA_DAILY_SLEEP=3
export MORCA_STALE_SECONDS=30 MORCA_SAMPLE_SECONDS=0 MORCA_WATCHDOG_SECONDS=0
export MORCA_HOST_CPUS=4 MORCA_HOST_MEMORY_MB=2048 MORCA_RESERVE_CPUS=0 MORCA_RESERVE_MEMORY_MB=0
export MORCA_WORKERS=1
unset MORCA_RUNNER MORCA_CONFIG MORCA_CONFIG_OVERLAY
ui=
cleanup() { [ -z "$ui" ] || kill "$ui" 2> /dev/null || true; }
trap cleanup EXIT
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
is() { [ "$(q "$1")" = "$2" ]; }
T0=2024-03-08T12:00Z
T1=2024-03-09T12:00Z  # after daily's fire at 02:30 New York time
tick() { MORCA_NOW="$1" ./build/morca tick >> "$log" 2>&1 || fail "tick at $1 exited $?"; }
reg() {  # reg BINARY...: registered from $proj/morca.toml at T0
    for b in "$@"; do
        regout=$(MORCA_NOW=$T0 ./build/morca register --config "$proj/morca.toml" "./build/$b" 2>&1) \
            || { echo "$regout" >> "$log"; fail "register $b: $regout"; }
        echo "$regout" >> "$log"
    done
}
running() { q "SELECT coalesce(string_agg(pipeline, ',' ORDER BY id), '') FROM orca.runs WHERE status = 'running'"; }
quiet() {  # until no run is running
    i=0
    while [ "$(q "SELECT count(*) FROM orca.runs WHERE status = 'running'")" -gt 0 ]; do
        i=$((i + 1)); [ "$i" -lt 600 ] || fail "runs didn't finish: $(q "SELECT id, pipeline, status FROM orca.runs WHERE status = 'running'")"
        sleep 0.1
    done
}
# drain: ticks until no run is queued or running.
drain() {
    i=0
    while [ "$(q "SELECT count(*) FROM orca.runs WHERE status IN ('queued', 'running')")" -gt 0 ]; do
        i=$((i + 1)); [ "$i" -lt 60 ] || fail "runs didn't drain: $(q "SELECT id, pipeline, status, held FROM orca.runs WHERE status IN ('queued', 'running')")"
        tick "$T1"
        quiet
    done
    is "SELECT count(*) FROM orca.runs WHERE status NOT IN ('succeeded', 'cancelled')" 0 \
        || fail "runs that didn't succeed: $(q "SELECT id, pipeline, status, error FROM orca.runs WHERE status NOT IN ('succeeded', 'cancelled')")"
}
check() { env -u MORCA_DATABASE_URL ./build/morca config check "$@"; }

# --- The key: checked, recorded, shown, overlaid, exported ---
for bad in 'priority = "high"' 'priority = 1.5' 'priority = 1001'; do
    printf '[pipelines.alpha]\n%s\n' "$bad" > build/priority-bad.toml
    if check build/priority-bad.toml > build/priority-bad.out 2>&1; then
        fail "config check passed $bad"
    fi
    grep -q "build/priority-bad.toml:2: \[pipelines.alpha\] priority: " build/priority-bad.out \
        || fail "config check of $bad: $(cat build/priority-bad.out)"
done
cat > "$proj/morca.toml" << 'EOF'
[pipelines.alpha]
memory_gb = 2

[pipelines.zulu]
memory_gb = 2
priority = 10
EOF
[ "$(check "$proj/morca.toml" 2>&1)" = "$proj/morca.toml: ok, 2 pipelines" ] \
    || fail "config check: $(check "$proj/morca.toml" 2>&1)"
reg alpha zulu
is "SELECT string_agg(name || '=' || priority, ',' ORDER BY name) FROM orca.pipelines" "alpha=0,zulu=10" \
    || fail "registered priorities: $(q "SELECT name, priority FROM orca.pipelines")"
./build/morca config show zulu > build/priority-show.out 2>&1 || fail "config show zulu"
grep -qE '^  priority +10 +morca.toml \[pipelines.zulu\]' build/priority-show.out \
    || fail "config show zulu: $(cat build/priority-show.out)"
./build/morca config show alpha > build/priority-show.out 2>&1 || fail "config show alpha"
grep -qE '^  priority +0 +code default' build/priority-show.out \
    || fail "config show alpha: $(cat build/priority-show.out)"
./build/morca config export --out - > build/priority-export.toml 2>> "$log" || fail "config export"
grep -q '^priority = 10$' build/priority-export.toml || fail "config export: $(cat build/priority-export.toml)"
[ "$(grep -c '^priority' build/priority-export.toml)" -eq 1 ] || fail "config export wrote a default priority"
free_port port
base="http://127.0.0.1:$port"
MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
ui=$!
i=0
until curl -fs "$base/" -o /dev/null; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
done
curl -fsS "$base/pipelines/zulu" > build/priority-page.out || fail "GET /pipelines/zulu"
grep -q 'Higher starts first when room is short' build/priority-page.out || fail "zulu's page doesn't show its priority"
[ "$(curl -fsS "$base/api/pipelines/zulu" | jq -r '.config.settings[] | select(.key == "priority") | .value')" = 10 ] \
    || fail "zulu's JSON: $(curl -fsS "$base/api/pipelines/zulu" | jq -c .config)"
echo "ok   priority is checked, recorded, shown and exported"

# --- The higher priority first, whatever the names ---
./build/morca backfill alpha 2024-01 >> "$log" 2>&1 || fail "backfill alpha"
./build/morca backfill zulu 2024-01 >> "$log" 2>&1 || fail "backfill zulu"
tick "$T1"
[ "$(running)" = "zulu" ] || fail "running after the first pass: '$(running)', not zulu"
want="waiting: for capacity (zulu, priority 10): needs 2 GB, 0 GB free of grants"
is "SELECT held FROM orca.runs WHERE pipeline = 'alpha' AND status = 'queued'" "$want" \
    || fail "alpha's run is held: '$(q "SELECT held FROM orca.runs WHERE pipeline = 'alpha'")'"
drain
echo "ok   the higher priority starts first, and the run that waits says whose run holds the room"

# --- Equal priorities: by name. The overlay sets zulu's back to 0. ---
printf '[pipelines.zulu]\npriority = 0\n' > "$proj/morca.overlay.toml"
# Exported and unset around the call: in front of a function call, bash as
# sh (macOS) keeps the assignment afterwards and dash doesn't, and kept, it
# fails the next section's register, whose file has no zulu.
export MORCA_CONFIG_OVERLAY="$proj/morca.overlay.toml"
reg zulu
unset MORCA_CONFIG_OVERLAY
is "SELECT priority FROM orca.pipelines WHERE name = 'zulu'" 0 || fail "the overlay's priority wasn't registered"
./build/morca config show zulu 2>&1 | grep -qE '^  priority +0 +morca.toml \[pipelines.zulu\], overlay ' \
    || fail "config show zulu with the overlay: $(./build/morca config show zulu 2>&1)"
./build/morca backfill zulu 2024-02 >> "$log" 2>&1 || fail "backfill zulu"
./build/morca backfill alpha 2024-02 >> "$log" 2>&1 || fail "backfill alpha"
tick "$T1"
[ "$(running)" = "alpha" ] || fail "running with equal priorities: '$(running)', not alpha"
is "SELECT held FROM orca.runs WHERE pipeline = 'zulu' AND status = 'queued'" "waiting: needs 2 GB, 0 GB free of grants" \
    || fail "zulu's run is held: '$(q "SELECT held FROM orca.runs WHERE pipeline = 'zulu'")'"
drain
echo "ok   equal priorities go by name"

# --- A scheduled run before a fill run, though the fill sorts first ---
cat > "$proj/morca.toml" << 'EOF'
[pipelines.bravo]
memory_gb = 2
fills = "all"

[pipelines.daily]
memory_gb = 2
EOF
reg bravo daily
tick "$T1"
[ "$(running)" = "daily" ] || fail "running after the pass: '$(running)', not daily's scheduled run"
is "SELECT trigger FROM orca.runs WHERE pipeline = 'daily' AND status = 'running'" schedule \
    || fail "daily's run: $(q "SELECT id, trigger, status FROM orca.runs WHERE pipeline = 'daily'")"
is "SELECT count(*) FROM orca.runs WHERE pipeline = 'bravo' AND status = 'running'" 0 \
    || fail "a fill run of bravo started beside daily's"
quiet
tick "$T1"
is "SELECT trigger FROM orca.runs WHERE pipeline = 'bravo' AND status = 'running'" fill \
    || fail "bravo's fill run didn't start once daily's ended: $(q "SELECT id, trigger, status, held FROM orca.runs WHERE pipeline = 'bravo'")"
quiet
echo "ok   a scheduled run starts before a fill run whose pipeline's name sorts first"

# --- A due retry before a newer queued run ---
./build/morca backfill alpha 2024-04 >> "$log" 2>&1 || fail "backfill alpha 2024-04"
r1=$(q "SELECT max(id) FROM orca.runs")
./build/morca backfill alpha 2024-05 >> "$log" 2>&1 || fail "backfill alpha 2024-05"
r2=$(q "SELECT max(id) FROM orca.runs")
# r1 failed a start, its retry due now.
q "UPDATE orca.runs SET status = 'failed', starts = 1, started = now(), ended = now(), retry_at = 0, error = 'boom' WHERE id = $r1" > /dev/null
tick "$T1"
is "SELECT id FROM orca.runs WHERE status = 'running'" "$r1" \
    || fail "running: $(q "SELECT id, status FROM orca.runs WHERE id IN ($r1, $r2)"), not the retry $r1"
is "SELECT status FROM orca.runs WHERE id = $r2" queued || fail "run $r2 isn't queued"
quiet
echo "ok   a due retry starts before a newer queued run of its pipeline"
