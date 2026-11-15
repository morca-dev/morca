#!/bin/sh
# package.sh VERSION [OUTDIR] [MORCA_VERSION]
#
# The deploy tooling as a release asset, so that deploying needs no checkout
# of morca: OUTDIR (default .) gets morca-hetzner-VERSION.tar.gz and the
# same content as morca-hetzner.tar.gz (for releases/latest/download/). Both
# unpack to morca-hetzner-VERSION/: the scripts, server/, cloud-init.yaml,
# hetzner.env.example, a README and a VERSION file, which the scripts print
# beside the stack's name and check images against (check_tools, #461). The
# scripts read hetzner.env next to them, or $HETZNER_ENV, as from the
# checkout. .github/workflows/release.yml runs this with VERSION the tools'
# own (deploy/hetzner/VERSION) and MORCA_VERSION the morca release they're
# attached to, whose docs the README links (default VERSION).
set -eu
[ $# -ge 1 ] && [ -n "$1" ] || {
    echo "usage: package.sh VERSION [OUTDIR] [MORCA_VERSION]" >&2
    exit 2
}
version=${1#v}
out=${2:-.}
release=${3:-$version}
release=${release#v}
src=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
name=morca-hetzner-$version

tmp=$(mktemp -d "${TMPDIR:-/tmp}/morca-hetzner-package.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM
dir=$tmp/$name
mkdir -p "$dir/server"
for f in up.sh deploy.sh promote.sh down.sh rescale.sh backup.sh lib.sh cloud-init.yaml hetzner.env.example; do
    cp -p "$src/$f" "$dir/$f"
done
for f in morca-stack secret-fetch orca-backup.service orca-backup.timer; do
    cp -p "$src/server/$f" "$dir/server/$f"
done
echo "$version" > "$dir/VERSION"
cat > "$dir/README.md" << EOF
# morca on Hetzner Cloud, tools $version

morca's deploy/hetzner, tools version $version (as of morca $release): the
scripts that make, deploy, rescale, back up and tear down a morca stack on
one Hetzner Cloud server. They stop before deploying an image that needs
newer ones, saying which.
The guide: https://github.com/morca-dev/morca/blob/v$release/docs/hetzner.md

\`\`\`sh
cp hetzner.env.example hetzner.env   # or point HETZNER_ENV at a copy outside this directory
./up.sh --dry-run                    # prints every hcloud and ssh command; runs none
./up.sh
./deploy.sh <morca-tag> [<app>=<tag> ...]   # ends with morca-stack check
HETZNER_ENV=prod.env ./promote.sh --from dev.env   # what dev checked, to production
\`\`\`

Needs hcloud (with a context), ssh, jq and a POSIX sh.
EOF

# Sorted names, so the archive's order doesn't depend on the file system;
# COPYFILE_DISABLE keeps macOS's tar from adding ._ files.
(cd "$tmp" && find "$name" -type f | LC_ALL=C sort > files)
(cd "$tmp" && COPYFILE_DISABLE=1 tar -cf - -T files | gzip -9n > "$out/$name.tar.gz")
cp "$out/$name.tar.gz" "$out/morca-hetzner.tar.gz"
echo "$out/$name.tar.gz"
echo "$out/morca-hetzner.tar.gz"
