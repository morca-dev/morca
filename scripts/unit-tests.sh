#!/bin/sh
# The Mojo unit tests (tests/test_*.mojo), built once per CI shard and run
# from that one binary:
#
#   scripts/unit-tests.sh build SHARD     # build/unit-tests-SHARD and its links
#   scripts/unit-tests.sh run NAME        # run build/NAME, check its count
#
# Each test file of a shard goes into build/unit-tests-SHARD, and build/NAME
# (the name its pixi task always built, build/test-steps for
# tests/test_steps.mojo) is a link to it. The binary runs the tests of the
# file its name says, `basename "$0"`, so each test file still runs as its
# own process, under its own name, with whatever its task runs around it
# (scripts/with-postgres.sh, the shell test after it). The code the files of
# a shard share (morca, dista, postgres...) compiles once per shard, not once
# per test file. This follows census's scripts/test.sh.
#
# The shards are pixi.toml's: test-executor-core, test-executor-workers and
# test-scheduler-ui (CI runs each on a runner of its own) and the data
# environment's test-data-tables. A test file is in the shard whose task runs
# it, so a CI job builds only its own shard's binary. The build goes through
# scripts/mojo-build.sh like every other: an unchanged binary is a copy from
# build/.mojo-build (or MOJO_BUILD_CACHE_DIR), and under `ouromo` the split
# cache is used. The test and example pipelines' multi-call binary
# (scripts/pipelines.sh) is separate and unchanged.
#
# Not in a shard binary, each built on its own by its task:
# - tests/test_source.mojo: built with its own -D MORCA_SOURCE and
#   -D MORCA_COMMIT, which would be the source of every test in the binary.
# - tests/test_append_files.mojo: its tests take the dista runtime its main
#   starts before any connection, as an argument, so they can't be run by
#   name from another main.
# - tests/test_datacache.mojo: tests/dataview.sh also runs its binary as a
#   tool (`test-datacache plant ...`).
# test-tables-source and test-lake-batch-source build test_tables and
# test_lake_batch again with -D MORCA_LAKE_SOURCE=1: they are a shard of
# their own, data-tables-source.
#
# The tests are registered by name, each `def test_...` at column 0, not
# found with `__functions_in_module()`: in a module that is imported, rather
# than compiled as the main file, that list comes back incomplete (Mojo
# 1.2.0), and a test file would pass having run nothing. `run` checks the
# count the binary reports against the functions found here. A test file's
# `main` is therefore not called: it may only run the tests, and what a file
# needs done around them goes in `def before_tests() raises` and
# `def after_tests() raises`, called here and by its main
# (tests/test_replace.mojo).
#
# One file alone, without this: scripts/mojo-build.sh -I src -I tests
# $DEP_INC tests/test_steps.mojo -o build/x && ./build/x
# Run inside `pixi run`.
set -eu
cd "$(dirname "$0")/.."

# shard:file:name, one test file per line.
all='executor-core:tests/test_sample.mojo:test-sample
executor-core:tests/test_steps.mojo:test-steps
executor-core:tests/test_cron.mojo:test-cron
executor-core:tests/test_warehouse.mojo:test-warehouse
executor-core:tests/test_store.mojo:test-store
executor-core:tests/test_formal_pins.mojo:test-formal-pins
executor-core:tests/test_state.mojo:test-state
executor-core:tests/test_formal_migrate.mojo:test-formal-migrate
executor-core:tests/test_formal_fence.mojo:test-formal-fence
executor-core:tests/test_crash.mojo:test-crash
executor-core:tests/test_tasks.mojo:test-tasks
executor-core:tests/test_logs.mojo:test-logs
executor-core:tests/test_kube.mojo:test-kube
executor-core:tests/test_usage.mojo:test-usage
executor-core:tests/test_resources.mojo:test-resources
executor-core:tests/test_recommend.mojo:test-recommend
executor-core:tests/test_cgroup.mojo:test-cgroup
executor-core:tests/test_highlight.mojo:test-highlight
executor-core:tests/test_step_cards.mojo:test-step-cards
executor-core:tests/test_graph.mojo:test-graph
executor-core:tests/test_locate.mojo:test-locate
executor-core:tests/test_timeline.mojo:test-timeline
executor-workers:tests/test_control.mojo:test-control
executor-workers:tests/test_pressure.mojo:test-pressure
executor-workers:tests/test_hcloud.mojo:test-hcloud
scheduler-ui:tests/test_toml.mojo:test-toml
scheduler-ui:tests/test_upgrade.mojo:test-upgrade
scheduler-ui:tests/test_config.mojo:test-config
scheduler-ui:tests/test_fill.mojo:test-fill
scheduler-ui:tests/test_metrics.mojo:test-metrics
scheduler-ui:tests/test_terms.mojo:test-terms
scheduler-ui:tests/test_remote.mojo:test-remote
scheduler-ui:tests/test_worker.mojo:test-worker-api
scheduler-ui:tests/test_watchdog.mojo:test-watchdog
scheduler-ui:tests/test_limit.mojo:test-limit
scheduler-ui:tests/test_turnstile.mojo:test-turnstile
scheduler-ui:tests/test_data_cache.mojo:test-data-cache
data-tables:tests/test_tables.mojo:test-tables
data-tables:tests/test_lake_batch.mojo:test-lake-batch
data-tables:tests/test_replace.mojo:test-replace
data-tables:tests/test_formal_retry.mojo:test-formal-retry
data-tables:tests/test_run_token.mojo:test-run-token
data-tables-source:tests/test_tables.mojo:test-tables-source
data-tables-source:tests/test_lake_batch.mojo:test-lake-batch-source'

functions() { sed -n 's/^def \(test_[A-Za-z0-9_]*\)(.*/\1/p' "$1"; }
usage() {
    echo "usage: unit-tests.sh build SHARD | run NAME" >&2
    exit 2
}

build() {
    shard=$1
    lines=$(printf '%s\n' "$all" | grep "^$shard:") || {
        echo "unit-tests.sh: no shard $shard" >&2
        exit 2
    }
    defines=
    [ "$shard" != data-tables-source ] || defines="-D MORCA_LAKE_SOURCE=1"
    gen=build/unit-tests-gen/$shard
    mkdir -p "$gen"
    main=$gen/unit_tests_main.mojo
    {
        echo '"""Generated by scripts/unit-tests.sh: the tests of the file'
        echo 'basename(argv[0]) names, of the shard '"$shard"'."""'
        echo
        echo 'from std.sys import argv'
        echo 'from std.testing import TestSuite'
        echo
        for l in $lines; do
            f=${l#*:}
            f=${f%%:*}
            m=$(basename "$f" .mojo)
            for t in $(functions "$f"); do echo "from $m import $t as ${m}__$t"; done
            if grep -q '^def before_tests()' "$f"; then
                echo "from $m import before_tests as ${m}__before_tests"
                echo "from $m import after_tests as ${m}__after_tests"
            fi
        done
        echo
        echo
        echo 'def main() raises:'
        echo '    var me = String(argv()[0])'
        echo '    var slash = me.rfind("/")'
        echo '    var name = String(me[byte = slash + 1 :]) if slash >= 0 else me'
        kw=if
        for l in $lines; do
            name=${l##*:}
            f=${l#*:}
            f=${f%%:*}
            m=$(basename "$f" .mojo)
            list=""
            for t in $(functions "$f"); do list="$list${m}__$t, "; done
            [ -n "$list" ] || {
                echo "unit-tests.sh: $f has no test" >&2
                exit 1
            }
            echo "    $kw name == \"$name\":"
            if grep -q '^def before_tests()' "$f"; then
                echo "        ${m}__before_tests()"
                echo '        var failed = False'
                echo '        try:'
                echo "            TestSuite.discover_tests[($list)]().run()"
                echo '        except e:'
                echo '            failed = True'
                echo '            print(e)'
                echo "        ${m}__after_tests()"
                echo '        if failed:'
                echo "            raise Error(\"$m failed\")"
            else
                # Its main is not called, so it may only run the tests.
                [ "$(sed -n '/^def main()/,$p' "$f" | grep -vc '^[[:space:]]*$')" = 2 ] || {
                    echo "unit-tests.sh: $f: main does more than run the tests; move that to before_tests() and after_tests()" >&2
                    exit 1
                }
                echo "        TestSuite.discover_tests[($list)]().run()"
            fi
            kw=elif
        done
        echo '    else:'
        echo '        raise Error(name, ": not a test of this binary")'
    } > "$main.tmp"
    # Rewritten only when it changed: scripts/mojo-build.sh keys on it.
    if cmp -s "$main.tmp" "$main"; then rm -f "$main.tmp"; else mv -f "$main.tmp" "$main"; fi
    bin=unit-tests-$shard
    # shellcheck disable=SC2086
    scripts/mojo-build.sh $defines -I src -I tests $DEP_INC "$main" -o "build/$bin"
    for l in $lines; do
        name=${l##*:}
        # A link made beside it and moved into place: a test running
        # build/<name> never sees it missing.
        ln -sf "$bin" "build/$name.tmp.$$"
        mv -f "build/$name.tmp.$$" "build/$name"
    done
}

run() {
    name=$1
    l=$(printf '%s\n' "$all" | grep ":$name\$") || {
        echo "unit-tests.sh: no test binary $name" >&2
        exit 2
    }
    f=${l#*:}
    f=${f%%:*}
    want=$(functions "$f" | wc -l | tr -d ' ')
    log=$(mktemp "${TMPDIR:-/tmp}/unit-tests.XXXXXX")
    if "./build/$name" > "$log" 2>&1; then rc=0; else rc=$?; fi
    cat "$log"
    ran=$(sed -n 's/.* \([0-9][0-9]*\) tests run:.*/\1/p' "$log" | tail -1)
    rm -f "$log"
    if [ "$rc" != 0 ]; then
        exit "$rc"
    fi
    if [ "${ran:-0}" != "$want" ]; then
        echo "unit-tests.sh: $f has $want tests and build/$name ran ${ran:-0}" >&2
        exit 1
    fi
}

[ "$#" = 2 ] || usage
case "$1" in
build) build "$2" ;;
run) run "$2" ;;
*) usage ;;
esac
