#!/bin/sh
# scripts/hetzner-version.sh, the CI rule for the deploy tools' own version
# (#461), in a scratch repository:
#
# - deploy/hetzner unchanged since the base: passes, the tools' version as it was;
# - deploy/hetzner changed without raising deploy/hetzner/VERSION: fails,
#   naming the files; with it raised: passes; lowered: fails;
# - the commit that adds VERSION (none at the base) passes;
# - VERSION not X.Y.Z, or deploy/runtime.Dockerfile's dev.morca.hetzner-min
#   missing or above VERSION: fails;
# - a change outside deploy/hetzner (a Dockerfile, docs) needs no bump.
set -eu
cd "$(dirname "$0")/.."
root=$PWD
R=$(mktemp -d "${TMPDIR:-/tmp}/morca-hetzner-version.XXXXXX")
trap 'rm -rf "$R"' EXIT INT TERM
fail() {
    echo "FAIL: $*"
    [ ! -f "$R/out" ] || cat "$R/out"
    exit 1
}
has() { grep -q -- "$1" "$R/out" || fail "no '$1' in the output"; }
check() { (cd "$R/repo" && sh "$root/scripts/hetzner-version.sh" main) > "$R/out" 2>&1; }
g() { git -C "$R/repo" "$@" > /dev/null; }
commit() { g add -A && g -c user.name=t -c user.email=t@example.invalid commit -q -m "$1"; }

mkdir -p "$R/repo/deploy/hetzner"
g init -q -b main
echo 'echo deploy' > "$R/repo/deploy/hetzner/deploy.sh"
printf 'FROM base\nLABEL dev.morca.hetzner-min="0.31.0"\n' > "$R/repo/deploy/runtime.Dockerfile"
commit "before VERSION"

# The commit that adds VERSION, beside a change to the scripts.
g checkout -q -b add
echo 0.31.0 > "$R/repo/deploy/hetzner/VERSION"
echo 'echo deploy, checked' > "$R/repo/deploy/hetzner/deploy.sh"
commit "VERSION"
check || fail "adding VERSION"
has "the tools go from 0.0.0 to 0.31.0"
g checkout -q main
g merge -q --ff-only add

# Nothing under deploy/hetzner changed: passes.
g checkout -q -b docs
echo docs > "$R/repo/README.md"
echo '# a comment' >> "$R/repo/deploy/runtime.Dockerfile"
commit "docs"
check || fail "a change outside deploy/hetzner"
has "deploy/hetzner unchanged since main: the tools stay 0.31.0"

# A script changed, VERSION not: fails, naming it.
g checkout -q -b script main
echo 'echo deploy, faster' > "$R/repo/deploy/hetzner/deploy.sh"
commit "faster"
check && fail "deploy/hetzner changed without a VERSION bump"
has "deploy/hetzner changed since main (deploy/hetzner/deploy.sh), but deploy/hetzner/VERSION is still 0.31.0, not above 0.31.0: raise it"
# A file added there counts too.
echo x > "$R/repo/deploy/hetzner/new.sh"
commit "new"
check && fail "a new file in deploy/hetzner without a bump"
has "deploy/hetzner/deploy.sh deploy/hetzner/new.sh"
# Raised: passes; lowered: fails.
echo 0.32.0 > "$R/repo/deploy/hetzner/VERSION"
commit "bump"
check || fail "deploy/hetzner changed with a bump"
has "the tools go from 0.31.0 to 0.32.0"
echo 0.30.9 > "$R/repo/deploy/hetzner/VERSION"
commit "lower"
check && fail "a lowered VERSION"
has "not above 0.31.0"

# VERSION and the label must be versions, the label no newer than VERSION.
echo 0.32.0 > "$R/repo/deploy/hetzner/VERSION"
echo v0.32 > "$R/repo/deploy/hetzner/VERSION"
check && fail "VERSION v0.32"
has "deploy/hetzner/VERSION is 'v0.32', not a version"
echo 0.32.0 > "$R/repo/deploy/hetzner/VERSION"
printf 'FROM base\nLABEL dev.morca.hetzner-min="0.33.0"\n' > "$R/repo/deploy/runtime.Dockerfile"
check && fail "a minimum above VERSION"
has "asks for morca-hetzner >= 0.33.0, but deploy/hetzner/VERSION is 0.32.0: no such tools"
printf 'FROM base\n' > "$R/repo/deploy/runtime.Dockerfile"
check && fail "no label"
has "has no LABEL dev.morca.hetzner-min"
printf 'FROM base\nLABEL dev.morca.hetzner-min="0.32.0"\n' > "$R/repo/deploy/runtime.Dockerfile"
commit "label"
check || fail "the minimum raised to VERSION"
echo "ok   hetzner-version"
