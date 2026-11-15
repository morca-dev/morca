#!/bin/sh
# The runtime image (deploy/runtime.Dockerfile) and a project's image built
# FROM it (deploy/project.Dockerfile), as CI builds them
# (.github/workflows/runtime-image.yml):
#
#     sh tests/runtime-image.sh morca-runtime:ci                 # the runtime
#     sh tests/runtime-image.sh morca-runtime:ci --project [CPU] # and a project on it
#
# The runtime: morca, morca_maintain, git over HTTPS (libcurl and the CA
# bundle), llvm-symbolizer, every binary's libraries found, and what the
# Hetzner stacks run in it on busybox: sh, the scheduler's cgroup start
# (mount, setpriv), the health probe (nc) and a secret fetch. The
# project: a scratch project that adds this commit of morca-mojo, with
# examples/toy.mojo as its one pipeline and no bin/ of its own, built on the
# runtime; its toy has its source map and runs a partition, and its `morca`
# is the runtime's. Needs docker, and pixi for the project's lock.
set -eu
cd "$(dirname "$0")/.."
img=$1
fail() { echo "FAIL: $*"; exit 1; }
run() { docker run --rm "$@"; }

# Without arguments, each prints its usage (and exits non-zero).
run "$img" 2>&1 | grep -q "morca locate" || fail "morca's usage"
# The morca-mojo package's morca (#455), of this checkout's version.
want=$(sed -n '/^\[package\]/,/^\[/s/^version = "\(.*\)"$/\1/p' pixi.toml)
[ "$(run "$img" version)" = "morca $want" ] || fail "morca version: $(run "$img" version 2>&1), not $want"
run --entrypoint morca_maintain "$img" 2>&1 | grep -q "expected .expire <dataset>" || fail "morca_maintain's usage"
run --entrypoint /opt/morca/libexec/llvm-symbolizer "$img" --version | grep -q LLVM || fail "llvm-symbolizer"
run --entrypoint git "$img" ls-remote https://github.com/morca-dev/morca HEAD | grep -q HEAD \
    || fail "git over HTTPS"
# Every binary and library finds what it links.
missing=$(run --entrypoint sh "$img" -c \
    'for f in /opt/morca/bin/* /opt/morca/libexec/llvm-symbolizer /opt/morca/libexec/git/* /opt/morca/lib/*.so*; do
        [ -f "$f" ] && ldd "$f" 2>/dev/null | grep "not found" | sed "s|^|$f: |"; done; true')
[ -z "$missing" ] || fail "libraries not found: $missing"
run --entrypoint sh "$img" -c '[ -s /opt/morca/ssl/cacert.pem ] && [ -s /src/project/.pixi/envs/default/ssl/cacert.pem ] \
    && [ -s /opt/morca/share/pixi.lock ] && [ -d /opt/morca/pipelines ]' || fail "the CA bundles, pixi.lock or the layout"
# On distroless with busybox (#337): sh and the tools morca-stack and these
# tests run in the containers, util-linux's setpriv, and the base's time
# zones and CA certificates.
run --entrypoint test "$img" -x /opt/morca/bin/morca || fail "test -x, as morca-stack checks an image"
# The oldest deploy/hetzner tools it works with, which deploy.sh reads (#461).
[ -n "$(docker image inspect -f '{{index .Config.Labels "dev.morca.hetzner-min"}}' "$img")" ] \
    || fail "no dev.morca.hetzner-min label"
out=$(run --entrypoint sh "$img" -c 'for t in sh cat test timeout nc printf tr mount setpriv ldd grep sed awk cut sha256sum env; do
    command -v "$t" > /dev/null || echo "no $t"; done
    /usr/bin/setpriv --help 2>&1 | grep -q -e --bounding-set || echo "/usr/bin/setpriv has no --bounding-set"
    for f in /bin/sh /usr/bin/env; do [ -x "$f" ] || echo "no $f"; done
    for f in /usr/share/zoneinfo/Europe/Berlin /etc/ssl/certs/ca-certificates.crt; do [ -s "$f" ] || echo "no $f"; done' 2>&1) \
    || fail "busybox's tools: $out"
[ -z "$out" ] || fail "busybox's tools, setpriv, the time zones or the CA certificates: $out"
# The scheduler's start with cgroups (morca-stack's containers()): /sys/fs/cgroup
# remounted writable, CAP_SYS_ADMIN dropped, and a cgroup made under it.
out=$(run --cgroupns=private --cap-add SYS_ADMIN --security-opt apparmor=unconfined --entrypoint /bin/sh "$img" -c \
    'mount -o remount,rw /sys/fs/cgroup && exec /usr/bin/setpriv --bounding-set -sys_admin --inh-caps -sys_admin /bin/sh -c '"'"'
        mkdir /sys/fs/cgroup/probe && rmdir /sys/fs/cgroup/probe || exit 1
        b=$(sed -n "s/^CapBnd:[[:space:]]*//p" /proc/self/status)
        [ $((0x$b & 0x200000)) = 0 ] && echo dropped'"'"'' 2>&1) || fail "the scheduler's cgroup start: $out"
[ "$out" = dropped ] || fail "the scheduler's cgroup start kept CAP_SYS_ADMIN: $out"
# morca-stack's health probe (probe()), at a listener in the image.
code=$(run --entrypoint sh "$img" -c 'mkdir -p /tmp/www && echo ok > /tmp/www/index.html && busybox httpd -p 127.0.0.1:8270 -h /tmp/www && sleep 1
printf "GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" "$1" \
    | timeout 5 nc 127.0.0.1 "$0" | { read -r _ code _ && echo "$code" | tr -d "\r"; }' 8270 /index.html) || code=
[ "$code" = 200 ] || fail "morca-stack's health probe: '$code'"
# A secret through MORCA_SECRET_FETCH as the Hetzner stacks set it (sh
# /etc/orca/secret-fetch, run through sh -c), read by `config check --secrets`.
sec=$PWD/build/runtime-secrets
rm -rf "$sec"
mkdir -p "$sec/secrets/orca"
printf 'a token\n' > "$sec/secrets/orca/test-token"
for id in orca/test-token orca/missing; do
    printf '[defaults]\nplacement = "control"\n\n[pipelines.toy]\nsecrets = { TOKEN = "%s" }\n' "$id" \
        > "$sec/$(basename "$id").toml"
done
fetch() {
    run -v "$sec:/work:ro" -v "$PWD/deploy/hetzner/server/secret-fetch:/etc/orca/secret-fetch:ro" \
        -v "$sec/secrets:/etc/orca/secrets:ro" -e "MORCA_SECRET_FETCH=sh /etc/orca/secret-fetch" "$img" \
        config check "/work/$1.toml" --secrets
}
out=$(fetch test-token 2>&1) || fail "a secret through MORCA_SECRET_FETCH: $out"
out=$(fetch missing 2>&1) && fail "a missing secret read: $out"
echo "$out" | grep -q "can't read secret orca/missing" || fail "a missing secret's error: $out"
echo "ok   runtime image"

[ "${2:-}" = --project ] || exit 0
cpu=${3:-neoverse-n1}
# morca-mojo as `pixi shelf add` pins it: by revision, which must be on
# GitHub (CI's commit; MORCA_REV and MORCA_REPO say another).
rev=${MORCA_REV:-$(git rev-parse HEAD)}
repo=${MORCA_REPO:-https://github.com/morca-dev/morca}
ctx=$PWD/build/runtime-project
rm -rf "$ctx"
mkdir -p "$ctx/pipelines"
cp examples/toy.mojo "$ctx/pipelines/"
cat > "$ctx/pixi.toml" << EOF
[workspace]
name = "runtime-project"
channels = ["https://conda.modular.com/max-nightly", "conda-forge"]
platforms = ["linux-64", "linux-aarch64"]
preview = ["pixi-build"]

[dependencies]
mojo-compiler = "==1.2.0"
morca-mojo = { git = "$repo", rev = "$rev" }
EOF
pixi lock --manifest-path "$ctx/pixi.toml"
docker build -f deploy/project.Dockerfile --build-arg MORCA_RUNTIME="${img%:*}" --build-arg MORCA_VERSION="${img##*:}" \
    --build-arg MOJO_TARGET_CPU="$cpu" --build-arg MORCA_SOURCE=https://github.com/morca-dev/morca \
    --build-arg MORCA_COMMIT=0000000 -t runtime-project:ci "$ctx"
proj=runtime-project:ci
run --entrypoint sh "$proj" -c '[ -x /opt/morca/bin/morca_maintain ] && [ -x /opt/morca/bin/git ]' || fail "the project's layout"
run --entrypoint cat "$proj" /opt/morca/pipelines/toy.source.json | grep -q '"pipeline"' || fail "toy's source map"
run --entrypoint toy "$proj" describe | grep -q '"pipeline": "toy"' || fail "toy describe"
run --entrypoint toy "$proj" describe | grep -q "\"morca\": \"$want\"}\$" || fail "toy describe names no morca $want"
out=$(run --entrypoint toy "$proj" run --partitions 2024-01 2>&1) || fail "toy run: $out"
[ "$(docker image inspect -f '{{.Config.Entrypoint}}' "$proj")" = "[/opt/morca/bin/morca]" ] || fail "the entrypoint"
# The oldest deploy/hetzner tools it works with (#461), the runtime's label inherited.
min=$(sed -n 's/^LABEL dev\.morca\.hetzner-min="\(.*\)"$/\1/p' deploy/runtime.Dockerfile)
[ "$(docker image inspect -f '{{index .Config.Labels "dev.morca.hetzner-min"}}' "$proj")" = "$min" ] \
    || fail "the project's image has no dev.morca.hetzner-min $min"
# No upgrade.toml in the project, none in the image, and no steps (#472).
run --entrypoint sh "$proj" -c '[ ! -e /opt/morca/upgrade.toml ] && [ ! -e /opt/morca/CHANGELOG.md ]' \
    || fail "an upgrade.toml or CHANGELOG.md the project hasn't"
out=$(run "$proj" upgrade --from 0.0.1 --to 9.9.9 2>&1) || fail "morca upgrade without an upgrade.toml: $out"
[ -z "$out" ] || fail "upgrade steps without an upgrade.toml: $out"
# The runtime's morca, unchanged: the project has no bin/scheduler.mojo, and
# needs none (#455).
a=$(run --entrypoint sha256sum "$img" /opt/morca/bin/morca | cut -d' ' -f1)
b=$(run --entrypoint sha256sum "$proj" /opt/morca/bin/morca | cut -d' ' -f1)
[ "$a" = "$b" ] || fail "the project's morca isn't the runtime's"
echo "ok   project image on the runtime"
