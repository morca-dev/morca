#!/bin/sh
# The conformance suite (tests/conformance.py) on morca's own Mojo
# pipelines, so the suite is known to be right before a binary in another
# language relies on it (#519):
#
#   examples   toy, daily and fanout (the multi-call test binary,
#              scripts/pipelines.sh), then tests/chaos.sh in the suite's
#              mode, over Postgres and SQLite
#   tables     the sensors tests/sensors/clean.mojo, which reads raw.events
#              and commits to lake.clean, and tests/sensors/replace.mojo,
#              which replaces its months of lake.monthly, in the data
#              environment
#
# Each pipeline runs over SQLite and over the Postgres MORCA_DATABASE_URL
# names (pixi run test-conformance starts a throwaway server).
#
# Usage: tests/conformance.sh [examples|tables]
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
fail=0
case ${1:-examples} in
examples)
    scripts/build-shared.sh
    for p in toy daily fanout; do
        python3 tests/conformance.py "build/$p" "tests/conformance/$p.json" || fail=1
    done
    echo "conformance: tests/chaos.sh, Postgres"
    CHAOS_BIN=build/chaos_pipeline tests/chaos.sh || fail=1
    echo "conformance: tests/chaos.sh, SQLite"
    rm -f build/chaos-conformance.db*
    CHAOS_BIN=build/chaos_pipeline MORCA_DATABASE_URL=sqlite:build/chaos-conformance.db \
        tests/chaos.sh || fail=1
    ;;
tables)
    pids=
    for p in source clean replace rows_by; do
        # shellcheck disable=SC2086
        scripts/mojo-build.sh -I src -I tests/sensors -I tests/lineage $DEP_INC "tests/sensors/$p.mojo" -o "build/sn-$p" &
        pids="$pids $!"
    done
    scripts/build-shared.sh morca &
    for pid in $pids $!; do wait "$pid"; done
    python3 tests/conformance.py build/sn-clean tests/conformance/clean.json || fail=1
    python3 tests/conformance.py build/sn-replace tests/conformance/replace.json || fail=1
    ;;
*)
    echo "usage: tests/conformance.sh [examples|tables]" >&2
    exit 2
    ;;
esac
exit "$fail"
