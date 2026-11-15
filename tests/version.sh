#!/bin/sh
# morca._internal.version's MORCA_VERSION is the package's version, as
# pixi.toml's [package] and shelf.toml say it (#455): `morca version`, each
# pipeline's describe and `morca register`'s check read it, so a release
# bumps it with them. `sh tests/version.sh --fix` writes pixi.toml's into it.
set -eu
cd "$(dirname "$0")/.."
f=src/morca/_internal/version.mojo
pkg=$(sed -n '/^\[package\]/,/^\[/s/^version = "\(.*\)"$/\1/p' pixi.toml)
shelf=$(sed -n 's/^version = "\(.*\)"$/\1/p' shelf.toml)
src=$(sed -n 's/^comptime MORCA_VERSION = "\(.*\)"$/\1/p' "$f")
if [ "${1:-}" = --fix ]; then
    sed "s/^comptime MORCA_VERSION = \".*\"\$/comptime MORCA_VERSION = \"$pkg\"/" "$f" > "$f.new" && mv "$f.new" "$f"
    src=$pkg
fi
[ "$pkg" = "$shelf" ] || { echo "pixi.toml's [package] is $pkg and shelf.toml's $shelf"; exit 1; }
[ "$src" = "$pkg" ] || { echo "$f says $src and pixi.toml $pkg: sh tests/version.sh --fix"; exit 1; }
echo "ok   version: $pkg"
