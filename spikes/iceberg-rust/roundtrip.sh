#!/bin/sh
# Rust and Mojo committing to and reading one morca table (#520), on the
# warehouse MORCA_WAREHOUSE names (an absolute directory, or s3://... with
# the AWS_* environment; scripts/with-minio.sh sets one up).
#
#   1. Rust creates the table and commits (step load, run 1, 2024-01).
#   2. Mojo reads it, and find_commit recognises the Rust commit; a Mojo
#      retry of that step returns it and commits nothing.
#   3. Mojo commits 2024-02 with a new column (score, id 4).
#   4. Rust commits 2024-03 with a new column (note, id 5); a Rust retry of
#      Mojo's 2024-02 step recognises Mojo's commit.
#   5. Both read the current snapshot and every earlier one, pinned.
#   6. ROUNDS rounds of WRITERS processes, alternately Rust and Mojo, commit
#      a month each to a new table at once: every one commits, once. One
#      that runs out of commit retries is run again as its step's second
#      attempt, as morca would retry it.
#   7. ROUNDS rounds of a Rust and a Mojo writer creating one table at once.
#
# Usage: roundtrip.sh   (from the worktree root, after build.sh)
set -eu
mojo=${MOJO_SIDE:-./build/spike-side}
rust=${RUST_SIDE:-./build/cargo/release/rside}
: "${MORCA_WAREHOUSE:?}"
writers=${WRITERS:-8}
rounds=${ROUNDS:-5}
tag=$(date +%s)$$
ds=spike.t$tag
fail() {
    echo "FAIL: $*"
    exit 1
}
num() { echo "$1" | tail -1 | awk '{print $NF}'; }
last() { echo "$1" | tail -1; }
expect() { # expect <what> <got line> <want line>
    [ "$2" = "$3" ] || fail "$1: got '$2', want '$3'"
    echo "ok   $1"
}
count_snapshots() { $rust read "$1" | grep -c '^snapshot ' || true; }

echo "warehouse $MORCA_WAREHOUSE, dataset $ds"

r1=$(num "$($rust write "$ds" 1 2024-01 1 2024-01 5)")
expect "mojo reads rust's commit" "$(last "$($mojo read "$ds")")" \
    "rows 5 id_sum 10 columns id,ts,name note 0 score 0"
expect "mojo find_commit recognises rust's commit" "$($mojo find "$ds" 1 2024-01)" "found $r1"
expect "mojo find_commit ignores another partition" "$($mojo find "$ds" 1 2024-02)" "found -1"
again=$(num "$($mojo write "$ds" 1 2024-01 2 2024-01 5)")
expect "a mojo retry returns rust's commit" "$again" "$r1"
expect "and commits nothing" "$(count_snapshots "$ds")" 1

m1=$(num "$($mojo write "$ds" 1 2024-02 1 2024-02 4 4)")
r2=$(num "$($rust write "$ds" 1 2024-03 1 2024-03 3 note)")
expect "rust find_commit recognises mojo's commit" "$($rust write "$ds" 1 2024-02 2 2024-02 4)" "found $m1"
expect "and commits nothing" "$(count_snapshots "$ds")" 3

all="rows 12 id_sum 19 columns id,ts,name,score,note note 3 score 4"
expect "mojo reads the current snapshot" "$(last "$($mojo read "$ds")")" "$all"
expect "rust reads the current snapshot" "$(last "$($rust read "$ds")")" "$all"
for who in mojo rust; do
    eval "side=\$$who"
    expect "$who reads rust's first snapshot (use_snapshot)" \
        "$(last "$($side read "$ds" "$r1")" | cut -d' ' -f1-4)" "rows 5 id_sum 10"
    expect "$who reads mojo's snapshot (use_snapshot)" \
        "$(last "$($side read "$ds" "$m1")" | cut -d' ' -f1-4)" "rows 9 id_sum 16"
done
expect "mojo reads rust's first snapshot (a step's pin)" \
    "$(last "$($mojo pinned "$ds" "$r1")" | cut -d' ' -f1-4)" "rows 5 id_sum 10"
expect "mojo reads rust's second snapshot (a step's pin)" \
    "$(last "$($mojo pinned "$ds" "$r2")" | cut -d' ' -f1-4)" "rows 12 id_sum 19"
echo "summaries, as rust reads them:"
$rust read "$ds" | grep '^snapshot' | sed 's/^/  /'

round=1
while [ "$round" -le "$rounds" ]; do
    cds=spike.c${tag}r$round
    # One writer creates the table first: concurrent creation is a separate
    # race (write_first_metadata), tried below.
    $rust write "$cds" 2 2025-00 1 2025-01 1 > /dev/null
    pids=
    i=1
    while [ "$i" -le "$writers" ]; do
        m=$(printf %02d "$i")
        if [ $((i % 2)) -eq 0 ]; then side=$mojo; else side=$rust; fi
        $side write "$cds" 2 "2025-$m" 1 "2025-$m" 3 > "build/rt-$i.log" 2>&1 &
        pids="$pids $i:$!"
        i=$((i + 1))
    done
    # A writer that ran out of commit retries fails its step attempt; the
    # step's next attempt (as morca retries it) commits or finds its commit.
    retried=0
    for ip in $pids; do
        i=${ip%%:*}
        wait "${ip#*:}" && continue
        grep -q "can't commit\|CatalogCommitConflicts" "build/rt-$i.log" || { cat "build/rt-$i.log"; fail "round $round: writer $i failed"; }
        m=$(printf %02d "$i")
        if [ $((i % 2)) -eq 0 ]; then side=$mojo; else side=$rust; fi
        $side write "$cds" 2 "2025-$m" 2 "2025-$m" 3 > /dev/null
        retried=$((retried + 1))
    done
    [ "$retried" -eq 0 ] || echo "     round $round: $retried writers ran out of commit retries; their steps' second attempts committed"
    out=$($rust read "$cds")
    n=$(echo "$out" | grep -c '^snapshot ')
    parts=$(echo "$out" | grep '^snapshot ' | grep -o 'orca.partition=[^ ]*' | sort -u | wc -l | tr -d ' ')
    [ "$n" -eq $((writers + 1)) ] || { echo "$out"; fail "round $round: $n snapshots, not $((writers + 1))"; }
    [ "$parts" -eq $((writers + 1)) ] || { echo "$out"; fail "round $round: $parts partitions"; }
    want="rows $((3 * writers + 1)) id_sum $((3 * writers))"
    expect "round $round: $writers writers (rust and mojo) at once, rust reads" \
        "$(last "$out" | cut -d' ' -f1-4)" "$want"
    expect "round $round: mojo reads" "$(last "$($mojo read "$cds")" | cut -d' ' -f1-4)" "$want"
    round=$((round + 1))
done

# Two creators of one new table at once, one Rust and one Mojo.
round=1
while [ "$round" -le "$rounds" ]; do
    nds=spike.n${tag}r$round
    $rust write "$nds" 3 a 1 2025-01 2 > build/rt-a.log 2>&1 &
    a=$!
    $mojo write "$nds" 3 b 1 2025-02 2 > build/rt-b.log 2>&1 &
    b=$!
    wait $a || { cat build/rt-a.log; fail "create round $round: rust failed"; }
    wait $b || { cat build/rt-b.log; fail "create round $round: mojo failed"; }
    expect "create round $round: rust and mojo create one table at once" \
        "$(last "$($rust read "$nds")" | cut -d' ' -f1-4)" "rows 4 id_sum 2"
    round=$((round + 1))
done
rm -f build/rt-*.log
echo "ok   roundtrip"
