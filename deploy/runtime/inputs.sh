#!/bin/sh
# The key of what deploy/runtime.Dockerfile builds the runtime image from at
# a commit (default HEAD): the Dockerfile and every path it COPYs or ADDs
# from the build context, by their git object ids. Two commits with the same
# key build the same image, whatever else differs between them (#353):
#
#     sh deploy/runtime/inputs.sh [<commit>]   # prints inputs-<hex>
#
# CI pushes each image it tests for main or a release PR under this key too
# (morca-runtime:inputs-<key>, .github/workflows/runtime-image.yml), and a
# release tags the image whose key is its commit's, so the release PR's
# image, already built and tested, is the release's in seconds. The image
# compiles in the version (MORCA_VERSION in src/morca/_internal/version.mojo,
# pixi.toml's [package]), so the commit before the version bump has another
# key: only an image built from the bumped sources can be the release's.
#
# The sources are read from the Dockerfile itself, so a new COPY is in the
# key with no change here; a COPY of a path git doesn't track fails here
# rather than being left out.
set -eu
cd "$(dirname "$0")/../.."
rev=${1:-HEAD}
df=deploy/runtime.Dockerfile
git rev-parse -q --verify "$rev^{commit}" > /dev/null || { echo "inputs.sh: no commit $rev" >&2; exit 1; }
# COPY/ADD lines without --from: every word but the first (the instruction)
# and the last (the destination). No source here spans a continued line.
srcs=$(git show "$rev:$df" | awk '
    { k = toupper($1) }
    (k == "COPY" || k == "ADD") && $2 !~ /^--from=/ {
        for (i = 2; i < NF; i++) if ($i !~ /^--/) print $i
    }' | sort -u)
[ -n "$srcs" ] || { echo "inputs.sh: no COPY sources in $df at $rev" >&2; exit 1; }
list=$(for p in $df $srcs; do
    oid=$(git rev-parse -q --verify "$rev:${p%/}") || { echo "inputs.sh: $df copies $p, which git doesn't track at $rev" >&2; exit 1; }
    printf '%s %s\n' "$oid" "${p%/}"
done) || exit 1
if command -v sha256sum > /dev/null; then sum=sha256sum; else sum='shasum -a 256'; fi
key=$(printf '%s\n' "$list" | $sum | cut -c1-32)
echo "inputs-$key"
