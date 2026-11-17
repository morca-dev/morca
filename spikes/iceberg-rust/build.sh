#!/bin/sh
# Builds both sides of the spike into build/: liblake and the Mojo side
# (build/spike-side) in the data environment, and the Rust side
# (build/cargo/release/rside) with a stable Rust >= 1.95 (iceberg 0.11.0's
# MSRV; `rustup toolchain install stable`). From the worktree root:
#
#   spikes/iceberg-rust/build.sh
#   MORCA_WAREHOUSE=$PWD/build/wh spikes/iceberg-rust/roundtrip.sh
#   pixi run -e data scripts/with-minio.sh sh -c \
#       'MORCA_WAREHOUSE=s3://morca/wh spikes/iceberg-rust/roundtrip.sh'
set -eu
cd "$(dirname "$0")/../.."
# shellcheck disable=SC2016
pixi run -e data sh -c 'scripts/build-liblake.sh && scripts/mojo-build.sh -I src $DEP_INC spikes/iceberg-rust/mojo/side.mojo -o build/spike-side'
CARGO_TARGET_DIR=$PWD/build/cargo cargo +stable build --release \
    --manifest-path spikes/iceberg-rust/Cargo.toml
