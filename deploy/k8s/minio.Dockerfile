# MinIO for deploy/k8s/morca.yaml on a local cluster: conda-forge's
# minio-server (the last community release; MinIO publishes no images or
# binaries any more), with curl, which makes the bucket at start. Build it
# from the repository root and load it into the cluster:
#
#     docker build -f deploy/k8s/minio.Dockerfile -t morca-minio:dev deploy/k8s
#     kind load docker-image morca-minio:dev --name <cluster>
FROM ghcr.io/prefix-dev/pixi:0.78.0-bookworm AS build
RUN pixi global install minio-server==2025.10.15.17.29.55 \
    && cp -L "$(find /root/.pixi/envs -path '*/bin/minio' -type f | head -n 1)" /minio \
    && /minio --version

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /minio /usr/local/bin/minio
ENTRYPOINT ["minio"]
