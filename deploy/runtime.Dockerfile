# morca's runtime image, ghcr.io/morca-dev/morca-runtime:<morca version>, which
# a project's image builds FROM (deploy/project.Dockerfile): morca's own
# `morca` (bin/scheduler.mojo) and `morca_maintain` (bin/morca_maintain.mojo),
# git, libcurl, the CA bundles where libcurl, OpenSSL and flare look for
# them, llvm-symbolizer, and the /opt/morca layout and environment that
# deploy/hetzner and `morca aws` run. On distroless (glibc, libstdc++, CA
# certificates and tzdata, no shell), with a static busybox for `sh` and
# the tools the stacks run in it (`sys`, below). morca's CI builds and tests it on every
# pull request, and pushes main's as morca-runtime:<sha>, which a release
# tags <version> (.github/workflows/runtime-image.yml). Build it from the
# repository root:
#
#     docker build -f deploy/runtime.Dockerfile -t morca-runtime:dev .
#
# The binaries are the morca-mojo package's own (#455, docs/binaries.md):
# deploy/runtime/pixi.toml is a project that adds this checkout of
# morca-mojo, installed from its lock (deploy/runtime/lock.sh), and the
# package builds `morca` and `morca_maintain` into its bin/, so they link the
# same packages a project's pipelines do and are the binaries a project
# runs. Like the project's image, everything has line tables (-g1),
# compressed, and is built for a CPU every server of the platform has, not
# for the CPU of the machine building it (pixi.toml's package section):
# Neoverse N1 on arm64, since GitHub's arm64 runners are Neoverse N2, with
# SVE2, and Hetzner's CAX servers Neoverse N1, where an N2 binary dies with
# SIGILL (exit 132); N1 code runs on N2, V1, V2 and Graviton. x86-64-v3
# (AVX2) on amd64.
#
# The stages are ordered for the layer cache: `env` is the pixi environment
# and depends only on morca's pixi.toml, src/ and the lock; `curl` and
# `git` start from it.
FROM ghcr.io/prefix-dev/pixi:0.78.0-bookworm AS env
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY pixi.toml /src/morca/pixi.toml
COPY src /src/morca/src
# At /src/project, the directory deploy/project.Dockerfile builds a project
# in, so the CA bundle paths compiled into conda's libcurl and OpenSSL are
# the same in both (below).
COPY deploy/runtime/pixi.toml deploy/runtime/pixi.lock /src/project/
WORKDIR /src/project
RUN pixi install --locked

FROM env AS build
RUN env=/src/project/.pixi/envs/default && mkdir -p /out/bin /out/share && cp pixi.lock /out/share/pixi.lock \
    && cp -L $env/bin/morca $env/bin/morca_maintain /out/bin/
# The line tables compressed, which llvm-symbolizer reads as they are.
RUN for b in /out/bin/*; do objcopy --compress-debug-sections=zlib "$b" || exit 1; done
# Only the pixi environment's libraries the binaries link or dlopen: libpq
# (postgres), flare's shims (morca ui, apps) and every tin's shim, such as
# objectstore's and the codecs' (zstd, for Iceberg writes); and
# llvm-symbolizer, which Mojo's runtime runs to name a crash's frames, with
# what it links. Stripped of their symbol tables. Not conda's libpsl, which
# brings ICU (36 MB) and which libcurl alone links: the image has Debian's
# libpsl5. Not libsqlite3 either, which links ICU too: the image runs on
# Postgres. OpenSSL stays conda's: libcurl and libpq need 3.2. And liblake,
# which morca.tables loads (#454), from morca-mojo's lib/: not stripped,
# its line tables compressed like the binaries', so a crash inside it is
# symbolised. ldd reads the package's binaries where they're installed, not
# the copies in /out/bin: the package build gives them an rpath relative to
# themselves ($ORIGIN/../lib), which from /out/bin finds nothing, and Mojo's
# runtime (libKGENCompilerRTShared) would be left out (#455).
RUN env=/src/project/.pixi/envs/default && mkdir -p /out/lib /out/libexec \
    && cp -L $env/bin/llvm-symbolizer /out/libexec/ \
    && loaded=$(ls $env/lib/libpq.so.5 $env/lib/libflare_*.so $env/lib/lib*mojo*.so 2>/dev/null) \
    && ldd $env/bin/morca $env/bin/morca_maintain $env/lib/liblake.so /out/libexec/* $loaded 2> /dev/null \
        | awk -v e="$env" '$3 ~ "^"e {print $3}' | grep -v -e '/libicu' -e '/libpsl' \
        | sort -u | xargs -r cp -L -t /out/lib \
    && cp -L -t /out/lib $loaded \
    && ln -s libpq.so.5 /out/lib/libpq.so \
    && for f in /out/lib/*; do [ -L "$f" ] || strip --strip-unneeded "$f" || exit 1; done \
    && cp -L $env/lib/liblake.so /out/lib/ \
    && objcopy --compress-debug-sections=zlib /out/lib/liblake.so

# git, for pipelines that clone or fetch (mojo-census's mojo_history and
# mojo_versions): only the `git` binary (every builtin) and
# git-remote-https, without Perl, Tcl/Tk, gettext, Python or expat (Debian's
# git package and what it pulls in: 90 MB; this, 5 MB). Built on the image's
# Debian against the pixi environment's libcurl, which /opt/morca/lib ships
# anyway (objectstore links it). `curl` gathers libcurl, the pixi libraries
# it links (not libpsl or ICU, as above) and its headers from `env`, so git
# is built again only when the pixi environment changes.
FROM env AS curl
RUN env=/src/project/.pixi/envs/default && mkdir -p /deps/lib /deps/include \
    && cp -L $env/lib/libcurl.so.4 /deps/lib/ \
    && ldd $env/lib/libcurl.so.4 | awk -v e="$env" '$3 ~ "^"e {print $3}' \
        | grep -v -e '/libicu' -e '/libpsl' | sort -u | xargs -r cp -L -t /deps/lib \
    && cp -r $env/include/curl /deps/include/

FROM debian:bookworm-slim AS git
# The tarball is pinned by its sha256 (kernel.org's sha256sums.asc) and
# fetched with retries from kernel.org's mirrors in turn: edge timeouts
# failed image builds (morca #468). Bump GIT_SHA256 with GIT_VERSION.
ARG GIT_VERSION=2.51.2
ARG GIT_SHA256=233d7143a2d58e60755eee9b76f559ec73ea2b3c297f5b503162ace95966b4e3
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gcc make libc6-dev \
      zlib1g-dev libpsl5 xz-utils \
    && rm -rf /var/lib/apt/lists/*
COPY --from=curl /deps /deps
RUN f=git-$GIT_VERSION.tar.xz \
    && for m in https://mirrors.edge.kernel.org https://cdn.kernel.org https://www.kernel.org; do \
        curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 -o /tmp/$f $m/pub/software/scm/git/$f \
          && echo "$GIT_SHA256  /tmp/$f" | sha256sum -c - && break; \
        rm -f /tmp/$f; \
      done \
    && test -f /tmp/$f && tar xJf /tmp/$f -C /usr/src && rm /tmp/$f \
    && cd /usr/src/git-$GIT_VERSION && ln -s libcurl.so.4 /deps/lib/libcurl.so \
    && make -j"$(nproc)" prefix=/opt/morca gitexecdir=/opt/morca/libexec/git \
        template_dir=/opt/morca/libexec/git/templates \
        NO_PERL=1 NO_TCLTK=1 NO_GETTEXT=1 NO_PYTHON=1 NO_EXPAT=1 NO_OPENSSL=1 NO_INSTALL_HARDLINKS=1 \
        CURL_CFLAGS=-I/deps/include CURL_LDFLAGS='-L/deps/lib -lcurl -Wl,-rpath-link,/deps/lib' \
        git git-remote-http \
    && mkdir -p /opt/morca/bin /opt/morca/libexec/git/templates \
    && install -s git /opt/morca/libexec/git/git \
    && install -s git-remote-http /opt/morca/libexec/git/git-remote-https \
    && ln -s ../libexec/git/git /opt/morca/bin/git

# What the distroless base lacks, from the Debian it's built from:
# - a static busybox, for `sh`: MORCA_SECRET_FETCH runs as `sh
#   /etc/orca/secret-fetch` through `sh -c` (morca.control), and so do
#   morca's git calls (morca.config) and `morca aws`; morca-stack runs the
#   scheduler with cgroups through `/bin/sh -c 'mount -o remount,rw ... &&
#   exec setpriv ...'`, checks images with `test`, and probes the UI and
#   apps with `nc`; operators `docker exec scheduler sh`. Every applet is
#   linked where busybox puts it (/bin/sh, /usr/bin/env, ...), except
#   where a file below already is (setpriv, ldd).
# - util-linux's setpriv, at /usr/bin/setpriv: busybox's has no
#   --bounding-set, which the scheduler's cgroup start drops CAP_SYS_ADMIN
#   with. Call it by that path: busybox's sh runs its own applet for a
#   bare `setpriv` (Debian builds it standalone), whatever PATH says.
# - ldd (deploy/runtime/ldd; glibc's is bash), for the image tests.
# - the Debian libraries the binaries, git, setpriv and /opt/morca/lib link
#   that the base hasn't: libpsl5 for libcurl (see above) with what it
#   links, zlib for git, libcap-ng for setpriv. Whatever ldd resolves
#   outside /opt/morca and the base, so nothing is listed by hand.
FROM gcr.io/distroless/cc-debian12 AS base

FROM debian:bookworm-slim AS sys
RUN apt-get update && apt-get install -y --no-install-recommends busybox-static libpsl5 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=base / /base
COPY --from=build /out/lib /opt/morca/lib
COPY --from=build /out/bin /opt/morca/bin
COPY --from=build /out/libexec /opt/morca/libexec
COPY --from=git /opt/morca /opt/morca
COPY deploy/runtime/ldd /out/usr/bin/ldd
RUN t=$(cd /usr/lib && echo *-linux-gnu) && mkdir -p /out/bin /out/usr/lib/$t \
    && cp /bin/busybox /out/bin/busybox && cp "$(command -v setpriv)" /out/usr/bin/setpriv && chmod 755 /out/usr/bin/ldd \
    && for a in $(/bin/busybox --list-full); do case $a in */busybox | */setpriv | */ldd | linuxrc) continue ;; esac; \
            mkdir -p "/out/${a%/*}" && ln -s /bin/busybox "/out/$a" || exit 1; done \
    && for f in /opt/morca/bin/* /opt/morca/libexec/llvm-symbolizer /opt/morca/libexec/git/git* \
            /opt/morca/lib/*.so* /out/usr/bin/setpriv; do LD_LIBRARY_PATH=/opt/morca/lib ldd "$f" 2> /dev/null; done \
        | awk '$2 == "=>" && $3 ~ /^\// && $3 !~ /^\/opt\/morca\// {print $1, $3}' | sort -u \
        | while read -r n p; do [ -e "/base/lib/$t/$n" ] || [ -e "/base/usr/lib/$t/$n" ] \
            || cp -L "$p" "/out/usr/lib/$t/$n" || exit 1; done \
    && ls /out/usr/lib/$t && /bin/busybox | head -1 && /bin/busybox --list-full | tr '\n' ' '

FROM base
COPY --from=sys /out /
COPY --from=build /out/lib /opt/morca/lib
COPY --from=build /out/bin /opt/morca/bin
COPY --from=build /out/libexec /opt/morca/libexec
COPY --from=build /out/share /opt/morca/share
COPY --from=git /opt/morca /opt/morca
# libcurl (objectstore, git) and OpenSSL (flare) look for CA certificates
# under the build environment's prefix, compiled in when conda relocated
# them: /src/project/.pixi/envs/default/ssl, here and in a project's image
# alike. A fetch that hands flare $CONDA_PREFIX/ssl/cacert.pem finds the
# same bundle at /opt/morca/ssl. /opt/morca/pipelines is where a project's
# image puts its pipelines. Schedules read the base's TZif files
# (/usr/share/zoneinfo).
COPY --from=build /src/project/.pixi/envs/default/ssl /opt/morca/ssl
RUN mkdir -p /opt/morca/pipelines /src/project/.pixi/envs/default \
    && ln -s /opt/morca/ssl /src/project/.pixi/envs/default/ssl
ARG MORCA_VERSION=""
LABEL org.opencontainers.image.title="morca-runtime" org.opencontainers.image.version="${MORCA_VERSION}"
# The oldest deploy/hetzner tools (deploy/hetzner/VERSION) this morca works
# with: deploy.sh, promote.sh and up.sh read it from the registry and stop
# when they're older (#461). A project's image built FROM this one inherits
# it. Raise it, to the tools' new VERSION, when morca comes to need what
# only newer tools do (a morca-stack command, a setting); it is never above
# deploy/hetzner/VERSION (scripts/hetzner-version.sh). 0.31.0, morca
# 0.31.0's tarball, from before the tools' own versions (#461), still works
# (as does 0.32.0's).
LABEL dev.morca.hetzner-min="0.34.0"
# postgres.mojo and flare find what they dlopen under $CONDA_PREFIX/lib.
ENV CONDA_PREFIX=/opt/morca LD_LIBRARY_PATH=/opt/morca/lib PATH=/opt/morca/bin:/opt/morca/pipelines:/usr/bin:/bin \
    LLVM_SYMBOLIZER_PATH=/opt/morca/libexec/llvm-symbolizer GIT_EXEC_PATH=/opt/morca/libexec/git
ENTRYPOINT ["/opt/morca/bin/morca"]
