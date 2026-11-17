#!/bin/sh
# WRITERS processes commit a month each to a new table at once, ROUNDS
# times, and the table is checked against what each writer reported:
#
#   failed  a writer ran out of commit retries and said so (its step's next
#           attempt would commit); loud, not lost
#   lost    a writer reported a commit the table doesn't have: two writers
#           both won a metadata version, and readers took the other one
#
# SIDE: rust, mojo, or mix (alternately). MORCA_WAREHOUSE as for
# roundtrip.sh. From the worktree root, after build.sh.
set -eu
mojo=${MOJO_SIDE:-./build/spike-side}
rust=${RUST_SIDE:-./build/cargo/release/rside}
: "${MORCA_WAREHOUSE:?}"
w=${WRITERS:-8}
rounds=${ROUNDS:-10}
side=${SIDE:-mix}
tag=$(date +%s)$$
lost=0
failed=0
r=1
while [ "$r" -le "$rounds" ]; do
    ds=spike.race${tag}r$r
    $rust write "$ds" 2 2025-00 1 2025-01 1 > /dev/null
    pids=
    i=1
    while [ "$i" -le "$w" ]; do
        m=$(printf %02d "$i")
        case $side in
        rust) s=$rust ;;
        mojo) s=$mojo ;;
        *) if [ $((i % 2)) -eq 0 ]; then s=$mojo; else s=$rust; fi ;;
        esac
        $s write "$ds" 2 "2025-$m" 1 "2025-$m" 3 > "build/race-$tag-$i.log" 2>&1 &
        pids="$pids $i:$!"
        i=$((i + 1))
    done
    have=$(mktemp)
    f=0
    l=0
    for ip in $pids; do
        if ! wait "${ip#*:}"; then
            f=$((f + 1))
            continue
        fi
        printf '2025-%02d\n' "${ip%%:*}" >> "$have.ok"
    done
    $rust read "$ds" | grep -o 'orca.partition=[^ ]*' | cut -d= -f2 | sort > "$have"
    if [ -f "$have.ok" ]; then
        l=$(sort "$have.ok" | comm -23 - "$have" | wc -l | tr -d ' ')
    fi
    rm -f "$have" "$have.ok"
    [ "$f" -eq 0 ] && [ "$l" -eq 0 ] || echo "round $r: $f failed, $l lost"
    failed=$((failed + f))
    lost=$((lost + l))
    r=$((r + 1))
done
rm -f build/race-"$tag"-*.log
echo "$side on $MORCA_WAREHOUSE: $rounds rounds of $w writers: $failed failed, $lost lost"
