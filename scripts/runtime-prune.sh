#!/bin/sh
# Prunes ghcr.io/morca-dev/morca-runtime's per-commit images (#353): every
# main commit leaves <sha>, <sha>-arm64 and <sha>-amd64, and every release
# PR inputs-<key> and its -arm64 and -amd64, and nothing else removes them.
# Run weekly by .github/workflows/runtime-retention.yml.
#
#     sh scripts/runtime-prune.sh            # say what it would delete
#     sh scripts/runtime-prune.sh --delete   # delete it
#
# It needs `gh` with read (and, to delete, delete) access to the package,
# `jq`, and `docker buildx imagetools` logged in to ghcr.io.
#
# Kept, always:
# - every version with a tag that isn't a per-commit one: the release tags
#   (0.33.0, ...) forever, and any tag someone made by hand;
# - the newest KEEP_NEWEST versions (20), and every version updated in the
#   last KEEP_DAYS days (30), so a release can still tag a recent commit's
#   image and a recent commit can be rolled back to;
# - every manifest a kept index lists: a release's index (the release PR's
#   or main's per-arch images, by digest) would break without them, tags or
#   no tags.
# Deleted: the rest of the versions whose tags are all per-commit ones
# (<40-hex sha> or inputs-<hex>, either with -arm64 or -amd64), and old
# untagged ones (an index or image a re-run pushed over), unless a kept
# index lists them.
set -eu
OWNER=${OWNER:-morca-dev}
PACKAGE=${PACKAGE:-morca-runtime}
KEEP_DAYS=${KEEP_DAYS:-30}
KEEP_NEWEST=${KEEP_NEWEST:-20}
image=ghcr.io/$OWNER/$PACKAGE
api=orgs/$OWNER/packages/container/$PACKAGE/versions
delete=false
[ "${1:-}" != --delete ] || delete=true

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# id, digest, updated_at, tags (comma-separated), newest first.
gh api --paginate "$api?per_page=100" \
    --jq '.[] | [.id, .name, .updated_at, ((.metadata.container.tags // []) | join(","))] | @tsv' \
    | sort -t "$(printf '\t')" -k3,3r > "$tmp/versions"
total=$(wc -l < "$tmp/versions" | tr -d ' ')
[ "$total" -gt 0 ] || { echo "no versions of $image: nothing to do"; exit 0; }

cutoff=$(date -u -d "$KEEP_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ 2> /dev/null \
    || date -u -v-"$KEEP_DAYS"d +%Y-%m-%dT%H:%M:%SZ)

# Each version kept, and why, or a candidate: "keep|cand <tab> why".
awk -F '\t' -v OFS='\t' -v cutoff="$cutoff" -v newest="$KEEP_NEWEST" '
    # No {40}: mawk, Ubuntu'"'"'s awk, may not take intervals.
    function percommit(t) {
        sub(/-(arm64|amd64)$/, "", t)
        return (length(t) == 40 && t ~ /^[0-9a-f]+$/) || t ~ /^inputs-[0-9a-f]+$/
    }
    {
        n = split($4, tags, ",")
        other = ""
        for (i = 1; i <= n; i++) if (!percommit(tags[i])) { other = tags[i]; break }
        if (other != "") why = "tag " other
        else if (NR <= newest) why = "newest " newest
        else if ($3 >= cutoff) why = "updated " $3
        else why = ""
        print $1, $2, $3, $4, (why == "" ? "cand" : "keep"), why
    }' "$tmp/versions" > "$tmp/classed"

# The manifests every kept index lists (an image's manifest lists none).
# Per-arch versions, whose tags all end in -arm64 or -amd64, are images.
awk -F '\t' '$5 == "keep" && $4 !~ /^([^,]*-(arm64|amd64),)*[^,]*-(arm64|amd64)$/ { print $2 }' "$tmp/classed" > "$tmp/roots"
: > "$tmp/children"
while read -r digest; do
    raw=$(docker buildx imagetools inspect --raw "$image@$digest") || {
        echo "::error::can't read $image@$digest, a kept version: stopping before deleting anything"
        exit 1
    }
    printf '%s\n' "$raw" | jq -r '.manifests[]?.digest' >> "$tmp/children"
done < "$tmp/roots"
sort -u -o "$tmp/children" "$tmp/children"

# The candidates no kept index lists.
awk -F '\t' -v OFS='\t' 'FILENAME == ARGV[1] { child[$1] = 1; next }
    $5 == "cand" && !($2 in child) { print $1, $2, $3, $4 }' "$tmp/children" "$tmp/classed" > "$tmp/delete"
kept=$(awk -F '\t' '$5 == "keep"' "$tmp/classed" | wc -l | tr -d ' ')
listed=$(awk -F '\t' 'FILENAME == ARGV[1] { child[$1] = 1; next } $5 == "cand" && ($2 in child)' "$tmp/children" "$tmp/classed" | wc -l | tr -d ' ')
gone=$(wc -l < "$tmp/delete" | tr -d ' ')
echo "$image: $total versions; keeping $kept (tags, the newest $KEEP_NEWEST, since $cutoff) and $listed a kept index lists; $gone to delete"
awk -F '\t' '$5 == "keep" && $6 ~ /^tag / { print "  keep", $2, $6 }' "$tmp/classed"

failed=0
while IFS="$(printf '\t')" read -r id digest updated tags; do
    if [ "$delete" = true ]; then
        if gh api -X DELETE "$api/$id" > /dev/null; then
            echo "  deleted $digest ($updated) ${tags:-untagged}"
        else
            echo "::warning::couldn't delete version $id ($digest)"
            failed=$((failed + 1))
        fi
    else
        echo "  would delete $digest ($updated) ${tags:-untagged}"
    fi
done < "$tmp/delete"
[ "$delete" = true ] || echo "dry run: nothing deleted (--delete deletes)"
[ "$failed" -eq 0 ] || { echo "::error::$failed versions not deleted"; exit 1; }
