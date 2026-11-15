#!/bin/sh
# scripts/hetzner-version.sh [BASE]
#
# The deploy tools' own version (#461), deploy/hetzner/VERSION, kept honest
# against BASE (default origin/main; CI gives the pull request's base):
#
# - it is a version, X.Y.Z;
# - a change to anything under deploy/hetzner since BASE (their merge base)
#   raises it, so a morca release that changes nothing there ships the
#   tools under the same version, and one that does, under a new one;
# - deploy/runtime.Dockerfile's dev.morca.hetzner-min, the oldest tools the
#   image works with, is a version no newer than VERSION: no image can ask
#   for tools that don't exist.
#
# Run from the repository's root, or anywhere in it.
set -eu
cd "$(git rev-parse --show-toplevel)"
base=${1:-origin/main}
fail() {
    echo "hetzner-version: $*" >&2
    exit 1
}
is_version() { echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }
# lt A B: version A is older than B.
lt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
        exit 1 }'
}

[ -s deploy/hetzner/VERSION ] || fail "no deploy/hetzner/VERSION"
now=$(cat deploy/hetzner/VERSION)
is_version "$now" || fail "deploy/hetzner/VERSION is '$now', not a version (X.Y.Z)"

mb=$(git merge-base "$base" HEAD) || fail "no merge base with $base"
changed=$(git diff --name-only "$mb" HEAD -- deploy/hetzner | grep -vx deploy/hetzner/VERSION || true)
if [ -z "$changed" ]; then
    said="deploy/hetzner unchanged since $base: the tools stay $now"
else
    was=$(git show "$mb:deploy/hetzner/VERSION" 2> /dev/null || echo 0.0.0)
    lt "$was" "$now" || fail "deploy/hetzner changed since $base ($(echo "$changed" | tr '\n' ' ' | sed 's/ $//')), but deploy/hetzner/VERSION is still $now, not above $was: raise it (and dev.morca.hetzner-min in deploy/runtime.Dockerfile if morca now needs these tools)"
    said="deploy/hetzner changed since $base, and the tools go from $was to $now"
fi

min=$(sed -n 's/^LABEL dev\.morca\.hetzner-min="\(.*\)"$/\1/p' deploy/runtime.Dockerfile)
[ -n "$min" ] || fail "deploy/runtime.Dockerfile has no LABEL dev.morca.hetzner-min=\"X.Y.Z\""
is_version "$min" || fail "deploy/runtime.Dockerfile's dev.morca.hetzner-min is '$min', not a version (X.Y.Z)"
! lt "$now" "$min" || fail "deploy/runtime.Dockerfile asks for morca-hetzner >= $min, but deploy/hetzner/VERSION is $now: no such tools"

echo "hetzner-version: $said"
