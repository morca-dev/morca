#!/bin/sh
# Runs cargo in the rust environment, from a test that runs in the data
# environment (tests/rust_worker.sh, tests/hindcast.sh, tests/rust_sdk.sh).
#
# The Rust toolchain has an environment of its own because no environment
# can hold both conda-forge's `rust` and `mojo-compiler`: on osx-arm64 both
# ship lib/libLLVM.dylib, rust's overwrites the compiler's, and mojo then
# crashes on start. A Rust worker is a library the Mojo step dlopens at run
# time, so the two halves meet only through the files cargo writes.
#
# Usage: scripts/cargo.sh <cargo arguments...>
set -eu
if [ "${MORCA_CARGO_ENV:-}" != rust ]; then
    MORCA_CARGO_ENV=rust exec pixi run --manifest-path "$(dirname "$0")/../pixi.toml" -e rust "$0" "$@"
fi
# On Linux, cargo links with conda-forge's compiler (it comes with `rust`),
# against its older glibc. C code a crate builds (aws-lc-sys, under
# morca-sdk's tables feature) must use that compiler too: the system's gcc
# compiles against the system's glibc headers and leaves symbols
# (__isoc23_sscanf) the link can't find.
if [ "$(uname)" = Linux ] && [ -z "${CC:-}" ]; then
    for c in "${CONDA_TOOLCHAIN_HOST:-none}-cc" x86_64-conda-linux-gnu-cc aarch64-conda-linux-gnu-cc; do
        if command -v "$c" > /dev/null 2>&1; then
            CC=$c
            CXX=${c%-cc}-c++
            export CC CXX
            break
        fi
    done
fi
exec cargo "$@"
