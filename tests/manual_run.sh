#!/bin/sh
# `<binary> run` against a pipeline `morca register` gave a binary: it never
# changes the registration, which is what the scheduler queues, and a
# binary with other code is refused unless --allow-new-code.
# Needs MORCA_DATABASE_URL (pixi run test-manual-run starts a throwaway
# server).
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
scripts/pipelines.sh toy
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca

log=build/manual-run.log
: > "$log"
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    exit 1
}
hash=$(./build/toy describe | jq -r .registry_hash)

# Not registered yet: a run records the pipeline, as it always has.
./build/toy run --partitions 2024-01 >> "$log" 2>&1 || fail "a run before registering"
[ "$(q "SELECT registry_hash FROM orca.pipelines WHERE name = 'toy'")" = "$hash" ] \
    || fail "the run didn't record the pipeline"

# Registered, and then the registered build is another one (a fix pushed
# and registered since this binary was built, or a dev build run by hand).
MORCA_NOW=2024-01-15T00:00Z ./build/morca register ./build/toy >> "$log" 2>&1 || fail "register"
q "UPDATE orca.pipelines SET registry_hash = '0xregistered', describe = jsonb_set(describe, '{registry_hash}', '\"0xregistered\"')" > /dev/null
version=$(q "SELECT version FROM orca.pipelines WHERE name = 'toy'")
runs=$(q "SELECT count(*) FROM orca.runs")
code=0
./build/toy run --partitions 2024-02 > build/manual-run.out 2>&1 || code=$?
cat build/manual-run.out >> "$log"
[ "$code" -eq 2 ] || fail "a run of other code exited $code, not 2"
grep -q "registered with code 0xregistered and this binary is $hash" build/manual-run.out \
    || fail "the refusal doesn't say why"
grep -q -- "--allow-new-code" build/manual-run.out || fail "the refusal doesn't say how"
[ "$(q "SELECT count(*) FROM orca.runs")" = "$runs" ] || fail "the refused run was created"

check_registration() {
    [ "$(q "SELECT registry_hash || ' ' || (describe->>'registry_hash') || ' ' || version FROM orca.pipelines WHERE name = 'toy'")" \
        = "0xregistered 0xregistered $version" ] \
        || fail "$1 changed the registration: $(q "SELECT registry_hash, version FROM orca.pipelines")"
}
check_registration "the refused run"

# Allowed, it runs as its own code and leaves the registration alone.
./build/toy run --partitions 2024-02 --allow-new-code >> "$log" 2>&1 || fail "a run with --allow-new-code"
check_registration "a run with --allow-new-code"
run=$(q "SELECT max(id) FROM orca.runs")
[ "$(q "SELECT status || ' ' || registry_hash || ' ' || trigger FROM orca.runs WHERE id = $run")" = "succeeded $hash manual" ] \
    || fail "the run: $(q "SELECT status, registry_hash, trigger FROM orca.runs WHERE id = $run")"
[ "$(q "SELECT v.registry_hash FROM orca.runs r JOIN orca.pipeline_versions v ON v.id = r.version WHERE r.id = $run")" = "$hash" ] \
    || fail "the run's version isn't its own code"
# Its code has the registered code's data version (no step sets version=),
# so it makes 2024-02 done, as the fill counts it (#508).
out=$(MORCA_NOW=2024-03-01T00:00Z ./build/morca backfill toy 2024-02) || fail "backfill exited $?"
[ "$out" = "queued 0 runs" ] || fail "the manual run of the same data version didn't count: $out"

# The registered code itself runs by hand as before, still without
# re-registering.
q "UPDATE orca.runs SET status = 'cancelled' WHERE status = 'queued'" > /dev/null
q "UPDATE orca.pipelines SET registry_hash = '$hash', describe = jsonb_set(describe, '{registry_hash}', '\"$hash\"')" > /dev/null
seen=$(q "SELECT last_seen FROM orca.pipelines WHERE name = 'toy'")
./build/toy run --partitions 2024-03 >> "$log" 2>&1 || fail "a run of the registered code"
[ "$(q "SELECT last_seen FROM orca.pipelines WHERE name = 'toy'")" = "$seen" ] \
    || fail "a run of the registered code re-registered it"
echo "ok   manual run: leaves the registration alone, refuses other code"
