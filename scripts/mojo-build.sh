#!/bin/sh
# `mojo build`, reusing the binary of an identical earlier build.
#
# Many tests build the same binaries: tests/*.sh built build/morca about 20
# times and build/toy 15 times in one `pixi run test`, each a full compile.
# This keys a build on everything it can read and keeps each result under
# build/.mojo-build/, so a second build with the same key is a copy:
#
# - the arguments but -o's (sources, -I, -D and the rest), the
#   environment's path (a binary's rpath names it) and its packages (the
#   file names in $CONDA_PREFIX/conda-meta name each one's version and
#   build);
# - the name and contents of every .mojo, .mojoc and .mojopkg file under the
#   -I directories and under each source's directory, .git, .pixi and build
#   left out;
# - the CPU: mojo compiles for the host's, so a binary built on one runner
#   can die with "Illegal instruction" on another (GitHub's runners differ).
#   On Linux its model name and feature flags, on macOS its brand string.
#   MOJO_TARGET_CPU (e.g. x86-64-v3) builds for that CPU instead, with
#   --target-cpu, and the key names it rather than the host's: CI sets it
#   so a binary built on one of GitHub's runners serves the others.
#
# A build that fails keeps nothing. Entries unused for two days are removed;
# rm -rf build/.mojo-build clears them all. MOJO_BUILD_CACHE=0 always builds.
# MOJO_BUILD_CACHE_DIR keeps them elsewhere: CI's self-hosted runners keep
# them outside the checkout, where a fresh checkout can't remove them. Entries are written to a
# temporary file and renamed, so builds running at once never see half of
# one, and a hit removed under a build (by another's pruning) is built again.
#
# In the `ouromo` environment (`pixi run -e ouromo ...`) the compiler is
# `ouromo`, an experimental build of the same compiler that keeps each
# function's object code under build/.split-cache (MOJO_SPLIT_CACHE_DIR
# moves it) and compiles only the functions an edit changed: a rebuild of
# build/morca takes about half the time. Its binaries run a few percent
# slower and are larger, so it is for development only: CI, the images and
# the releases build in the other environments, with `mojo`.
#
# Usage: scripts/mojo-build.sh <mojo build arguments...> -o <out>
set -eu

if command -v ouromo > /dev/null 2>&1; then
    compile() { ouromo build --split-cache-dir "${MOJO_SPLIT_CACHE_DIR:-build/.split-cache}" "$@"; }
else
    compile() { mojo build "$@"; }
fi

out=
prev=
dirs=
for a in "$@"; do
    case "$prev" in
    -o) out=$a ;;
    -I) dirs="$dirs $a" ;;
    esac
    case "$a" in
    *.mojo) dirs="$dirs $(dirname "$a")" ;;
    esac
    prev=$a
done
if [ -n "${MOJO_TARGET_CPU:-}" ]; then
    set -- "$@" --target-cpu "$MOJO_TARGET_CPU"
fi
if [ -z "$out" ] || [ "${MOJO_BUILD_CACHE:-1}" = 0 ]; then
    [ -z "$out" ] || [ ! -L "$out" ] || rm -f "$out"
    compile "$@"
    exit
fi

if command -v sha256sum > /dev/null 2>&1; then
    sha() { sha256sum | cut -c1-64; }
else
    sha() { shasum -a 256 | cut -c1-64; }
fi

list=$(mktemp "${TMPDIR:-/tmp}/mojo-build.XXXXXX")
trap 'rm -f "$list"' EXIT INT TERM
# shellcheck disable=SC2086
find $dirs \( -name .git -o -name .pixi -o -name build \) -prune -o -type f \
    \( -name '*.mojo' -o -name '*.mojoc' -o -name '*.mojopkg' \) -print \
    | LC_ALL=C sort -u > "$list"
key=$({
    # The arguments but -o's: one build serves every name it's copied to.
    skip=
    for a in "$@"; do
        if [ -n "$skip" ]; then
            skip=
        elif [ "$a" = -o ]; then
            skip=1
        else
            printf '%s\n' "$a"
        fi
    done
    printf '%s\n' "${CONDA_PREFIX:-}"
    uname -m
    if [ -n "${MOJO_TARGET_CPU:-}" ]; then
        :
    elif [ -r /proc/cpuinfo ]; then
        grep -m1 '^model name' /proc/cpuinfo || true
        grep -m1 -E '^(flags|Features)' /proc/cpuinfo || true
    else
        sysctl -n machdep.cpu.brand_string 2> /dev/null || true
    fi
    ls "${CONDA_PREFIX:-}/conda-meta" 2> /dev/null || true
    cat "${CONDA_PREFIX:-}/conda-meta/.pixi-environment-fingerprint" 2> /dev/null || true
    cat "$list"
    tr '\n' '\0' < "$list" | xargs -0 cat
} | sha)

cache=${MOJO_BUILD_CACHE_DIR:-build/.mojo-build}
hit=$cache/$key
mkdir -p "$cache" "$(dirname "$out")"
# A copy moved into place: a binary that's running keeps its old file.
if [ -f "$hit" ] && cp "$hit" "$out.tmp.$$" 2> /dev/null; then
    mv -f "$out.tmp.$$" "$out"
    touch "$hit" 2> /dev/null || true
    echo "mojo-build: $out reused" >&2
    exit 0
fi
rm -f "$out.tmp.$$"

start=$(date +%s)
# A link at -o (scripts/pipelines.sh's) is replaced, not written through.
[ -L "$out" ] && rm -f "$out"
compile "$@"
cp "$out" "$hit.tmp.$$"
mv -f "$hit.tmp.$$" "$hit"
echo "mojo-build: $out built in $(($(date +%s) - start))s" >&2
find "$cache" -type f -mtime +2 -delete 2> /dev/null || true
