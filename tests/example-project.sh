#!/bin/sh
# A scratch morca project, for CI to call morca's reusable project workflows
# on (.github/workflows/project-image.yml and project-test.yml, from ci.yml's
# project-* jobs) as a project's own CI would:
#
#     sh tests/example-project.sh build/example-project
#
# It adds this commit of morca-mojo as `pixi shelf add` pins it, by revision,
# which must be on GitHub (CI's commit; MORCA_REV and MORCA_REPO say another).
# Its one pipeline is examples/toy.mojo, its morca.toml configures it, its
# upgrade.toml has a step for 0.1.0 and a CHANGELOG.md, which the image ships
# (#472), and its `test` task builds the toy and runs a partition. Needs
# pixi, for the lock.
set -eu
cd "$(dirname "$0")/.."
dir=${1:?usage: sh tests/example-project.sh <dir>}
rev=${MORCA_REV:-$(git rev-parse HEAD)}
repo=${MORCA_REPO:-https://github.com/morca-dev/morca}
rm -rf "$dir"
mkdir -p "$dir/pipelines"
cp examples/toy.mojo "$dir/pipelines/"
cat > "$dir/pixi.toml" << EOF
[workspace]
name = "example-project"
channels = ["https://conda.modular.com/max-nightly", "conda-forge"]
platforms = ["linux-64", "linux-aarch64"]
preview = ["pixi-build"]

[dependencies]
mojo-compiler = "==1.2.0"
morca-mojo = { git = "$repo", rev = "$rev" }

[tasks]
test = "mkdir -p build && mojo build pipelines/toy.mojo -o build/toy && ./build/toy describe && ./build/toy run --partitions 2024-01"
EOF
cat > "$dir/morca.toml" << 'EOF'
[defaults]
placement = "control"

[pipelines.toy]
max_runs = 2
cpus = "1..2"
memory_gb = "0.5..2"
EOF
cat > "$dir/upgrade.toml" << 'EOF'
[[version]]
version = "0.1.0"

[[version.step]]
id = "0.1.0-toy"
run = "morca backfill --rerun toy 2024-01"
EOF
cat > "$dir/CHANGELOG.md" << 'EOF'
# Changelog

## 0.1.0 (2026-11-14)

- **The toy**: a first pipeline.
EOF
pixi lock --manifest-path "$dir/pixi.toml"
