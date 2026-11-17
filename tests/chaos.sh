#!/bin/bash
# Randomized end-to-end test of runs that keep getting interrupted. For each
# seed in CHAOS_SEEDS (default "1 2 3"), one run of the chaos pipeline
# (tests/chaos_pipeline.mojo, or CHAOS_SRC) is driven to the end through a
# seeded mix of:
#
#   - kill -9 of the process running it, at a random moment, which takes its
#     dista head and workers with it;
#   - a restart of the Postgres server under it (pg_ctl -m immediate), or,
#     with MORCA_DATABASE_URL=sqlite:<path>, another writer holding the
#     file's lock for up to 1.9 s, past the store's one-second busy timeout,
#     so the run's writes fail and are retried on the file opened again;
#   - two `resume`s started at once, racing to claim the run;
#   - steps that fail at random (CHAOS_FLAKY percent of attempts) and are
#     retried, then resumed.
#
# Afterwards the run must have succeeded with: every step succeeded by
# exactly one attempt, no attempt left running, no two attempts by different
# processes overlapping in time, the same total as an uninterrupted run, and
# no process of the pipeline left behind. With CHAOS_CHECK=1 the binary's own
# `check <run>` also runs (chaos_tables.mojo checks its Iceberg table).
# Each seed's first interruption is a kill early in its run, and at least
# one must have landed. Then, without CHAOS_CHECK, a failed run's `resume`
# with other code is refused (exit 3, saying which code ran it) unless
# --allow-new-code, which resumes it to the end (what tests/kill.sh checked
# before it was folded in here, #447).
#
# With CHAOS_BIN, the conformance suite's mode (tests/conformance.py,
# docs/pipeline-protocol.md): CHAOS_BIN is a prebuilt binary of the chaos
# pipeline, in any language, with its knobs (CHAOS_NAP, CHAOS_FLAKY,
# CHAOS_SEED and a `TOTAL <n>` log line), and every run, the reference one
# too, is started as the runners start one: a run row as the scheduler
# makes it (`conformance.py new-run`) and `resume`, never `run`. The keys are
# CHAOS_KEYS, comma-separated (the twelve months of 2024).
#
# Needs MORCA_DATABASE_URL and MORCA_PGDATA (pixi run test-chaos starts a
# throwaway server), or MORCA_DATABASE_URL=sqlite:<path>, a file it starts
# afresh (pixi run test-chaos-sqlite). CHAOS_TIMEOUT (default 120) seconds
# per seed.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
src=${CHAOS_SRC:-tests/chaos_pipeline.mojo}
# By its full path, so the check for processes left behind (pgrep) sees
# only this checkout's, not another job's on the same machine.
bin=$PWD/build/$(basename "$src" .mojo)
if [ -n "${CHAOS_BIN:-}" ]; then
    bin=$(cd "$(dirname "$CHAOS_BIN")" && pwd)/$(basename "$CHAOS_BIN")
elif [ "$src" = tests/chaos_pipeline.mojo ]; then
    scripts/pipelines.sh chaos_pipeline
else
    # shellcheck disable=SC2086
    scripts/mojo-build.sh -I src $DEP_INC "$src" -o "$bin"
fi

export MORCA_STALE_SECONDS=1
export MORCA_WORKERS=2
export CHAOS_NAP=${CHAOS_NAP:-0.05}
export CHAOS_FLAKY=${CHAOS_FLAKY:-30}
months=${CHAOS_MONTHS:-2024-01..2024-12}
keys=${CHAOS_KEYS:-2024-01,2024-02,2024-03,2024-04,2024-05,2024-06,2024-07,2024-08,2024-09,2024-10,2024-11,2024-12}
case $MORCA_DATABASE_URL in
sqlite:*)
    # The same queries, on Postgres's tables without the morca schema.
    db=${MORCA_DATABASE_URL#sqlite:}
    db=${db#//}
    rm -f "$db" "$db-wal" "$db-shm"
    what="lock holds"
    # Past the stale limit, so a write the lock held up past the busy
    # timeout is retried on the file opened again, not given up on.
    export MORCA_DB_RETRY_SECONDS=${MORCA_DB_RETRY_SECONDS:-5}
    q() { sqlite3 -cmd '.timeout 5000' "$db" "$(echo "$1" | sed 's/orca\.//g')"; }
    ;;
*)
    q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
    what="postgres restarts"
    ;;
esac

# A new run of the pipeline over its months, left for `resume` as the
# scheduler leaves one (conformance mode only).
new_run() { python3 tests/conformance.py new-run "$bin" "$keys" "$@"; }

# A fresh warehouse for a pipeline with tables.
fresh_warehouse() {
    CHAOS_WH=$(pwd)/build/chaos-wh-$1-$$
    export CHAOS_WH
    rm -rf "$CHAOS_WH"
    "$bin" init > /dev/null
}

# What an uninterrupted run gives: its total and its number of steps.
[ "${CHAOS_CHECK:-0}" = 1 ] && fresh_warehouse ref
if [ -n "${CHAOS_BIN:-}" ]; then
    ref_run=$(new_run) || { echo "FAIL: no reference run"; exit 1; }
    ref=$(CHAOS_FLAKY=0 CHAOS_NAP= "$bin" resume "$ref_run" 2>&1)
else
    ref=$(env -u MORCA_DATABASE_URL CHAOS_FLAKY=0 CHAOS_NAP= "$bin" run --partitions "$months" 2>&1)
fi
want=$(echo "$ref" | sed -n 's/.*TOTAL //p')
steps=$(echo "$ref" | grep ' succeeded$' | grep -vc '^run ')
[ -n "$want" ] || { echo "FAIL: the reference run printed no total"; echo "$ref"; exit 1; }

pids=()
cleanup() {
    [ ${#pids[@]} -eq 0 ] || kill -9 ${pids[@]+"${pids[@]}"} 2> /dev/null || true
    rm -rf build/chaos-wh-*-$$
}
trap cleanup EXIT

alive() {
    local p
    for p in ${pids[@]+"${pids[@]}"}; do
        if kill -0 "$p" 2> /dev/null; then return 0; fi
    done
    return 1
}
reap() {
    local p
    for p in ${pids[@]+"${pids[@]}"}; do wait "$p" 2> /dev/null || true; done
    pids=()
}

all_kills=0
for seed in ${CHAOS_SEEDS:-1 2 3}; do
    RANDOM=$seed
    export CHAOS_SEED=$seed
    log=build/chaos-$seed.log
    : > "$log"
    fail() {
        echo "FAIL (seed $seed, run ${run:-?}): $*"
        tail -40 "$log"
        exit 1
    }
    if [ "${CHAOS_CHECK:-0}" = 1 ]; then
        fresh_warehouse "$seed" || fail "init failed"
    fi
    started=$SECONDS
    run=""
    if [ -n "${CHAOS_BIN:-}" ]; then
        run=$(new_run) || fail "no run"
        "$bin" resume "$run" >> "$log" 2>&1 &
    else
        "$bin" run --partitions "$months" >> "$log" 2>&1 &
    fi
    pids=($!)
    until [ -n "$run" ]; do
        run=$(sed -n 's/^run \([0-9][0-9]*\)$/\1/p' "$log" | head -1)
        [ $((SECONDS - started)) -lt 20 ] || fail "the run never started"
        alive || [ -n "$run" ] || fail "the run exited before starting"
    done
    kills=0 restarts=0 races=0 resumes=0
    while true; do
        [ $((SECONDS - started)) -lt "${CHAOS_TIMEOUT:-120}" ] \
            || fail "not done after ${CHAOS_TIMEOUT:-120}s ($kills kills, $restarts restarts, $races races)"
        if ! alive; then
            reap
            status=$(q "SELECT status FROM orca.runs WHERE id = $run")
            [ -n "$status" ] || fail "the run's row is gone: the database lost a commit"
            [ "$status" != succeeded ] || break
            # Let the dead owner's heartbeat go stale, then resume, sometimes
            # twice at once.
            sleep 1.1
            "$bin" resume "$run" >> "$log" 2>&1 &
            pids=($!)
            resumes=$((resumes + 1))
            if [ $((RANDOM % 4)) = 0 ]; then
                "$bin" resume "$run" >> "$log" 2>&1 &
                pids+=($!)
                races=$((races + 1))
            fi
        fi
        # First a kill at 0.2-0.8 s, inside the run, so every seed has one
        # (tests/kill.sh's check), then a server restart, so every seed has
        # one of those too; after that mostly kills, at 0.1-1.9 s; some
        # restarts; now and then the run is left alone until it ends.
        action=$((RANDOM % 10))
        early=
        if [ "$kills" = 0 ] && [ "$restarts" = 0 ]; then
            action=0
            early=1
        elif [ "$restarts" = 0 ]; then
            action=7
        fi
        if [ "$action" -lt 7 ]; then
            if [ -n "$early" ]; then
                sleep "0.$((RANDOM % 7 + 2))"
            else
                sleep "$((RANDOM % 2)).$((RANDOM % 9 + 1))"
            fi
            if alive; then
                kill -9 ${pids[@]+"${pids[@]}"} 2> /dev/null || true
                kills=$((kills + 1))
            fi
            reap
        elif [ "$action" -lt 9 ]; then
            sleep "0.$((RANDOM % 8 + 1))"
            if [ -n "${db:-}" ]; then
                printf 'BEGIN EXCLUSIVE;\n.shell sleep %s\nCOMMIT;\n' \
                    "$((RANDOM % 2)).$((RANDOM % 9 + 1))" \
                    | sqlite3 -cmd '.timeout 5000' "$db" > /dev/null \
                    || fail "couldn't lock the file"
            else
                pg_ctl -D "$MORCA_PGDATA" -m immediate -w restart > /dev/null 2>&1 \
                    || fail "postgres didn't restart"
            fi
            restarts=$((restarts + 1))
            reap
        else
            reap
        fi
    done

    # The run, checked.
    [ "$(q "SELECT count(*) FROM orca.steps WHERE run = $run AND status = 'succeeded'")" = "$steps" ] \
        || fail "not $steps succeeded steps"
    [ "$(q "SELECT count(*) FROM orca.steps s WHERE s.run = $run AND (SELECT count(*) FROM orca.attempts a WHERE a.step = s.id AND a.status = 'succeeded') <> 1")" = 0 ] \
        || fail "a step succeeded more or less than once"
    [ "$(q "SELECT count(*) FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $run AND a.status = 'running'")" = 0 ] \
        || fail "an attempt was left running"
    overlaps=$(q "SELECT count(*) FROM orca.attempts a JOIN orca.steps sa ON sa.id = a.step, orca.attempts b JOIN orca.steps sb ON sb.id = b.step WHERE sa.run = $run AND sb.run = $run AND a.id < b.id AND a.host <> b.host AND a.started < b.ended AND b.started < a.ended")
    [ "$overlaps" = 0 ] || fail "$overlaps pairs of attempts by different processes overlap"
    got=$(sed -n 's/.*TOTAL //p' "$log" | tail -1)
    [ "$got" = "$want" ] || fail "total $got, not $want"
    if [ "${CHAOS_CHECK:-0}" = 1 ]; then
        "$bin" check "$run" >> "$log" 2>&1 || fail "check failed"
    fi
    for _ in $(seq 50); do
        pgrep -f "$bin" > /dev/null || break
        sleep 0.1
    done
    if pgrep -f "$bin" > /dev/null; then
        pgrep -fl "$bin" || true
        fail "processes of the pipeline were left behind"
    fi
    all_kills=$((all_kills + kills))
    attempts=$(q "SELECT count(*) FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $run")
    owners=$(q "SELECT count(DISTINCT a.host) FROM orca.attempts a JOIN orca.steps s ON s.id = a.step WHERE s.run = $run")
    echo "seed $seed: run $run done in $((SECONDS - started))s: $kills kills, $restarts $what, $resumes resumes ($races raced), $attempts attempts by $owners processes"
done
[ "$all_kills" -gt 0 ] || { echo "FAIL: no run was killed mid-way"; exit 1; }

# Resuming with other code is refused unless asked for.
if [ "${CHAOS_CHECK:-0}" != 1 ]; then
    log=build/chaos-new-code.log
    run=
    fail() {
        echo "FAIL (new code, run ${run:-?}): $*"
        tail -40 "$log"
        exit 1
    }
    if [ -n "${CHAOS_BIN:-}" ]; then
        run=$(new_run --hash 0xdead) || fail "no run"
    else
        CHAOS_FLAKY=100 CHAOS_NAP= "$bin" run --partitions "$months" > "$log" 2>&1 && fail "a run whose flaky step always fails succeeded"
        run=$(sed -n 's/^run \([0-9][0-9]*\)$/\1/p' "$log" | head -1)
        [ -n "$run" ] || fail "the failing run never started"
        q "UPDATE orca.runs SET registry_hash = '0xdead' WHERE id = $run" > /dev/null
    fi
    set +e
    CHAOS_FLAKY=0 CHAOS_NAP= "$bin" resume "$run" > "$log" 2>&1
    code=$?
    set -e
    [ "$code" -eq 3 ] || fail "resume with new code exited $code, not 3"
    grep -q 'ran code 0xdead' "$log" || fail "resume with new code didn't say why"
    CHAOS_FLAKY=0 CHAOS_NAP= "$bin" resume "$run" --allow-new-code > "$log" 2>&1 || fail "--allow-new-code didn't resume"
    [ "$(q "SELECT status FROM orca.runs WHERE id = $run")" = succeeded ] || fail "not succeeded after --allow-new-code"
    got=$(sed -n 's/.*TOTAL //p' "$log" | tail -1)
    [ "$got" = "$want" ] || fail "total $got, not $want"
    echo "new code: run $run's resume refused, then resumed with --allow-new-code"
fi
echo "ok   chaos"
