# The image morca runs from on Kubernetes: the `morca` binary (scheduler and
# UI) and pipeline binaries, built with pixi, on a slim Debian with only the
# libraries they load. Build it from the repository root:
#
#     docker build -f deploy/Dockerfile -t morca:dev .
#
# PIPELINES are the Mojo files to build into /opt/morca/pipelines/, each
# named after its file. MORCA_SOURCE and MORCA_COMMIT say what they were built
# from, which each run records and morca ui links (morca.source). They're set
# in the image's environment, not compiled in, so a new commit changes no
# program:
#
#     docker build --build-arg MORCA_SOURCE=$(git remote get-url origin) \
#         --build-arg MORCA_COMMIT=$(git rev-parse HEAD) ...
#
# dista and k8s compile from source at DISTA_REV and K8S_REV, the revisions
# CI checks out, cloned next to morca as pixi.toml expects.
#
# As in deploy/project.Dockerfile, the binaries have line tables (-g1),
# compressed, and the image has llvm-symbolizer, so a crash's stack dump
# names its frames.
# pixi's -bookworm image, not its default (Ubuntu): the build stage then
# installs from Debian's mirrors, the same release as the runtime stage.
FROM ghcr.io/prefix-dev/pixi:0.78.0-bookworm AS build
ARG DISTA_REV=ef13c67d448704f4c15cd22572538d404963bbca
ARG K8S_REV=1e688c57adbf891dae5c22d5a822cd3a2f681326
ARG PIPELINES="examples/toy.mojo examples/fanout.mojo"
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone -q https://github.com/morca-dev/dista /src/dista.mojo \
    && git -C /src/dista.mojo checkout -q ${DISTA_REV} \
    && git clone -q https://github.com/magmalake/k8s.mojo /src/k8s.mojo \
    && git -C /src/k8s.mojo checkout -q ${K8S_REV}
WORKDIR /src/morca
COPY pixi.toml pixi.lock ./
RUN pixi install --locked -e default
COPY src src
COPY bin bin
COPY examples examples
RUN mkdir -p /out/bin /out/pipelines \
    && pixi run -e default sh -c 'mojo build -g1 -I src $DEP_INC bin/scheduler.mojo -o /out/bin/morca \
        && for p in '"${PIPELINES}"'; do n=$(basename "$p" .mojo); \
            mojo build -g1 -I src $DEP_INC \
                "$p" -o "/out/pipelines/$n" || exit 1; done \
        && /out/bin/morca locate /out/pipelines/* --root .'
# The line tables compressed, which llvm-symbolizer reads as they are.
RUN for b in /out/bin/* /out/pipelines/*; do [ -x "$b" ] || continue; \
        objcopy --compress-debug-sections=zlib "$b" || exit 1; done
# What the binaries link, and what they dlopen from $CONDA_PREFIX/lib at run
# time (libpq for postgres.mojo, flare's shims for morca ui, objectstore's
# for dista) with what those link: only libraries from the pixi
# environment, as the system's are in the runtime image already. And
# llvm-symbolizer, which Mojo's runtime runs to name a crash's frames.
RUN env=/src/morca/.pixi/envs/default && mkdir -p /out/lib /out/libexec \
    && cp -L $env/bin/llvm-symbolizer /out/libexec/ \
    && loaded=$(ls $env/lib/libpq.so* $env/lib/libflare_*.so $env/lib/libobjectstoremojo.so 2>/dev/null) \
    && ldd /out/bin/morca /out/pipelines/* /out/libexec/* $loaded | awk -v e="$env" '$3 ~ "^"e {print $3}' \
        | sort -u | xargs -r cp -L -t /out/lib \
    && cp -L -t /out/lib $loaded

FROM debian:bookworm-slim
# tzdata: schedules read the system's TZif files.
RUN apt-get update && apt-get install -y --no-install-recommends tzdata ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/lib /opt/morca/lib
COPY --from=build /out/bin /opt/morca/bin
COPY --from=build /out/pipelines /opt/morca/pipelines
COPY --from=build /out/libexec /opt/morca/libexec
ARG MORCA_SOURCE=""
ARG MORCA_COMMIT=""
ENV MORCA_SOURCE=${MORCA_SOURCE} MORCA_COMMIT=${MORCA_COMMIT}
# postgres.mojo and flare find what they dlopen under $CONDA_PREFIX/lib.
ENV CONDA_PREFIX=/opt/morca LD_LIBRARY_PATH=/opt/morca/lib PATH=/opt/morca/bin:/opt/morca/pipelines:/usr/bin:/bin \
    LLVM_SYMBOLIZER_PATH=/opt/morca/libexec/llvm-symbolizer
ENTRYPOINT ["/opt/morca/bin/morca"]
