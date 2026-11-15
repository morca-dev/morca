# The image `morca aws push` builds for a project that added morca with
# `pixi shelf add morca-mojo`, on morca's runtime image,
# ghcr.io/morca-dev/morca-runtime:<MORCA_VERSION> (deploy/runtime.Dockerfile).
# The runtime has morca's own `morca` and `morca_maintain`, git, libcurl, the CA
# bundles, llvm-symbolizer and the /opt/morca layout and environment; this
# adds only the project's programs:
#
# - its apps, every bin/*.mojo, at /opt/morca/bin/<name> (`morca aws app` runs
#   them). A project needs no `morca` of its own: the runtime's
#   /opt/morca/bin/morca and morca_maintain are the morca-mojo package's,
#   the ones its environment has in bin/ too (docs/binaries.md). A
#   bin/scheduler.mojo, the two lines calling morca.command, still becomes
#   /opt/morca/bin/morca in place of the runtime's, and
#   bin/morca_maintain.mojo /opt/morca/bin/morca_maintain.
# - its pipelines, every pipelines/*.mojo, at /opt/morca/pipelines/<name>,
#   with the source map `morca locate` writes beside each.
# - its morca.toml, if it has one, at /opt/morca/morca.toml, which
#   MORCA_CONFIG names: a bare `morca register` (morca-stack register) reads
#   it. A project without one has nothing there, and registers with
#   --no-config or a --config of its own.
# - its upgrade.toml, if it has one, at /opt/morca/upgrade.toml, which
#   MORCA_UPGRADE names: the steps a deploy of each release needs, which
#   deploy/hetzner's deploy.sh reads (`morca upgrade`,
#   docs/hetzner.md#a-releases-upgrade-steps). Without one a deploy has none.
# - its CHANGELOG.md, if it has one, at /opt/morca/CHANGELOG.md.
# - the pixi environment's libraries those link or dlopen, in /opt/morca/lib
#   over the runtime's, so the project's own versions win.
#
# `src/` is on the import path if the project has one. A project with a
# Dockerfile.morca of its own builds that instead, and can start it the same
# way: `ARG MORCA_VERSION` and `FROM ghcr.io/morca-dev/morca-runtime:${MORCA_VERSION}`.
#
# MORCA_VERSION is the morca-mojo the project pins, which `morca aws push`
# reads from pixi.lock; the runtime and the project's pipelines are then the
# same morca. The build checks it: it stops when the runtime's `morca
# version` isn't the project environment's (#455). By hand:
#
#     docker build -f project.Dockerfile --build-arg MORCA_VERSION=0.24.0 \
#         -t ghcr.io/<owner>/<project>:<version> .
#
# Name the image after the project (ghcr.io/morca-dev/census, not
# ghcr.io/morca-dev/morca), and set MORCA_IMAGE in deploy/hetzner's
# hetzner.env to it. MORCA_RUNTIME names another runtime repository, such as
# one built locally (`docker build -f deploy/runtime.Dockerfile -t
# morca-runtime:0.24.0 .` in morca, then --build-arg MORCA_RUNTIME=morca-runtime).
#
# MORCA_SOURCE and MORCA_COMMIT say what the pipelines were built from, which
# each run records and morca ui links. They're set in the image's environment,
# not compiled in.
#
# Everything is built with line tables (-g1) and the image has
# llvm-symbolizer, so a crash's stack dump in a run's driver.log names each
# frame's function, file and line (morca.crash). The line tables, compressed,
# make a binary about half as big again (mojo-census's gharchive: 4.2 MB,
# 6.5 MB with them, 25 MB uncompressed) and leave its speed as it was.
#
# The binaries are built for MOJO_TARGET_CPU, not for the CPU of the machine
# building them (`mojo build` defaults to that). GitHub's arm64 runners are
# Neoverse N2, which has SVE2; Hetzner's CAX servers are Neoverse N1, which
# has not, so a binary built there dies on the server with SIGILL (exit
# 132). N1 code runs on N2, V1, V2 and Graviton. Build for something else
# with --build-arg MOJO_TARGET_CPU=<cpu> (x86-64-v3 for linux/amd64).
# No default version: the error for a build without one names what's missing.
ARG MORCA_VERSION=needs-build-arg-morca-version
ARG MORCA_RUNTIME=ghcr.io/morca-dev/morca-runtime
FROM ${MORCA_RUNTIME}:${MORCA_VERSION} AS runtime

FROM ghcr.io/prefix-dev/pixi:0.78.0-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src/project
COPY pixi.toml pixi.lock ./
RUN pixi install --locked
# The runtime's morca: to check it's the project's morca-mojo (below), and
# for `morca locate` with a morca-mojo from before it shipped one.
COPY --from=runtime /opt/morca /opt/morca-runtime
ARG MOJO_TARGET_CPU=neoverse-n1
COPY . .
RUN mkdir -p /out/bin /out/pipelines /out/config \
    && for c in morca.toml upgrade.toml CHANGELOG.md; do [ ! -f "$c" ] || cp "$c" "/out/config/$c" || exit 1; done \
    && pixi run sh -c 'if [ -x "$CONDA_PREFIX/bin/morca" ]; then ours=$("$CONDA_PREFIX/bin/morca" version) || exit 1; \
            theirs=$(LD_LIBRARY_PATH="$CONDA_PREFIX/lib:/opt/morca-runtime/lib" /opt/morca-runtime/bin/morca version 2> /dev/null) \
                || theirs="a morca from before morca version"; \
            [ "$ours" = "$theirs" ] || { echo "the runtime is $theirs and the project pins $ours: build with --build-arg MORCA_VERSION=${ours#morca }" >&2; exit 1; }; fi; \
        inc=""; [ -d src ] && inc="-I src"; \
        for f in bin/*.mojo; do [ -f "$f" ] || continue; n=$(basename "$f" .mojo); [ "$n" = scheduler ] && n=morca; \
            mojo build -g1 --target-cpu "$MOJO_TARGET_CPU" $inc "$f" -o "/out/bin/$n" || exit 1; done; \
        for p in pipelines/*.mojo; do [ -f "$p" ] || continue; n=$(basename "$p" .mojo); \
            mojo build -g1 --target-cpu "$MOJO_TARGET_CPU" $inc \
                "$p" -o "/out/pipelines/$n" || exit 1; done; \
        morca=/out/bin/morca; [ -x "$morca" ] || morca="$CONDA_PREFIX/bin/morca"; \
        [ -x "$morca" ] || morca=/opt/morca-runtime/bin/morca; \
        if ls /out/pipelines/* > /dev/null 2>&1; then \
            LD_LIBRARY_PATH="$CONDA_PREFIX/lib:/opt/morca-runtime/lib" "$morca" locate /out/pipelines/* --root .; fi'
# The line tables compressed, which llvm-symbolizer reads as they are.
RUN for b in /out/bin/* /out/pipelines/*; do [ -x "$b" ] || continue; \
        objcopy --compress-debug-sections=zlib "$b" || exit 1; done
# Only the pixi environment's libraries the binaries link or dlopen: libpq
# (postgres), flare's shims (morca ui, apps), and every tin's shim, such as
# objectstore's and the codecs' (zstd, for Iceberg writes). Not conda's
# libpsl and ICU, which only libcurl links: the runtime has Debian's libpsl5.
RUN env=/src/project/.pixi/envs/default && mkdir -p /out/lib \
    && loaded=$(ls $env/lib/libpq.so* $env/lib/libflare_*.so $env/lib/lib*mojo*.so 2>/dev/null) \
    && ldd /out/bin/* /out/pipelines/* $loaded 2> /dev/null | awk -v e="$env" '$3 ~ "^"e {print $3}' \
        | grep -v -e '/libicu' -e '/libpsl' | sort -u | xargs -r cp -L -t /out/lib \
    && cp -L -t /out/lib $loaded

FROM runtime
COPY --from=build /out/lib /opt/morca/lib
COPY --from=build /out/bin /opt/morca/bin
COPY --from=build /out/pipelines /opt/morca/pipelines
COPY --from=build /out/config/ /opt/morca/
ENV MORCA_CONFIG=/opt/morca/morca.toml MORCA_UPGRADE=/opt/morca/upgrade.toml
# What the pipelines were built from, read at run time (morca.source), not
# compiled in: a new commit then changes no program, and the build above
# stays cacheable. Declared last, so a new commit reruns only this layer.
ARG MORCA_SOURCE=""
ARG MORCA_COMMIT=""
ENV MORCA_SOURCE=${MORCA_SOURCE} MORCA_COMMIT=${MORCA_COMMIT}
