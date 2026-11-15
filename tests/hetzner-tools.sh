#!/bin/sh
# deploy/hetzner's check of its own version against the image's minimum
# (#461; check_tools in lib.sh), against tests/hetzner's fakes (curl is a
# registry whose images' dev.morca.hetzner-min label is $FAKE/tools-min/<tag>):
#
# - version_lt orders versions by number (0.9.0 < 0.10.0), equal isn't older;
# - deploy.sh of an image that needs newer tools stops before touching the
#   server (no ssh, no morca-stack sent; a dry run too), naming the version
#   it needs, the scripts' own and the download URL;
# - an image that needs these tools or older ones, or names no minimum (no
#   label: from before it), goes on;
# - a private image's registry is logged in to as GHCR_USER with ghcr-token
#   (never on the command line); without them, or with the registry down or
#   the tag missing, a deploy stops, saying why, and a dry run only warns;
#   --skip-tools-check goes on without asking the registry;
# - --rollback doesn't check (these scripts deployed those tags before);
# - up.sh checks MORCA_TAG before any hcloud command, and with no tag says
#   it doesn't check; promote.sh passes --skip-tools-check to deploy.sh.
set -eu
cd "$(dirname "$0")/.."
FAKE=$(mktemp -d "${TMPDIR:-/tmp}/morca-hetzner.XXXXXX")
export FAKE
trap 'rm -rf "$FAKE"' EXIT INT TERM
export PATH="$PWD/tests/hetzner:$PATH"
XDG_STATE_HOME="$FAKE/xdg"
XDG_CONFIG_HOME="$FAKE/config"
export XDG_STATE_HOME XDG_CONFIG_HOME
mkdir -p "$FAKE/tools-min"
v=$(cat deploy/hetzner/VERSION)

fail() {
    echo "FAIL: $*"
    [ ! -f "$FAKE/out" ] || tail -20 "$FAKE/out"
    exit 1
}
has() { grep -q -- "$1" "$FAKE/out" || fail "no '$1' in the output"; }
hasnt() { ! grep -q -- "$1" "$FAKE/out" || fail "'$1' in the output"; }
deploy() { sh deploy/hetzner/deploy.sh "$@" > "$FAKE/out" 2>&1; }
# untouched: deploy.sh sent the server nothing (the fake ssh writes
# $FAKE/morca-stack when morca-stack is installed) and ran no docker.
untouched() {
    [ ! -e "$FAKE/morca-stack" ] || fail "$1: morca-stack was sent to the server"
    [ ! -s "$FAKE/docker.log" ] || fail "$1: docker ran: $(cat "$FAKE/docker.log")"
}

printf 'AWS_ACCESS_KEY_ID=x\nAWS_SECRET_ACCESS_KEY=y\n' > "$FAKE/s3.env"
: > "$FAKE/tunnel.env"
echo ghcr-secret > "$FAKE/ghcr-token"
cat > "$FAKE/hetzner.env" << EOS
NAME=morca
BUCKET=bkt
S3_ENDPOINT=https://example.invalid
S3_REGION=fsn1
S3_CREDENTIALS_FILE=$FAKE/s3.env
TUNNEL_TOKEN_FILE=$FAKE/tunnel.env
MORCA_IMAGE=ghcr.io/example/census
DRAIN_SECONDS=86400
ADMIN_IP=203.0.113.7/32
SSH_PUBLIC_KEY_FILE=$FAKE/k.pub
EOS
: > "$FAKE/k.pub"
export HETZNER_ENV="$FAKE/hetzner.env"

# Version order.
. deploy/hetzner/lib.sh
version_lt 0.31.0 0.32.0 || fail "0.31.0 < 0.32.0"
version_lt 0.9.0 0.10.0 || fail "0.9.0 < 0.10.0"
version_lt 0.31.0 0.31.1 || fail "0.31.0 < 0.31.1"
version_lt 0.31 0.31.1 || fail "0.31 < 0.31.1"
! version_lt 0.31.0 0.31.0 || fail "0.31.0 < 0.31.0"
! version_lt 1.0.0 0.99.9 || fail "1.0.0 < 0.99.9"

# An image that needs newer tools: refused, in a dry run too, before the server.
echo 99.0.0 > "$FAKE/tools-min/new1111"
deploy new1111 && fail "deployed an image that needs morca-hetzner 99.0.0"
has "deploy.sh: ghcr.io/example/census:new1111 needs morca-hetzner >= 99.0.0, and these scripts are $v"
has "curl -fsSL https://github.com/morca-dev/morca/releases/latest/download/morca-hetzner.tar.gz | tar -xz"
has "nothing was changed on the server"
untouched "too old"
grep -q "^curl https://ghcr.io/v2/example/census/manifests/new1111$" "$FAKE/curl.log" || fail "the registry wasn't asked: $(cat "$FAKE/curl.log")"
# The server's platform's manifest: cax (the default) is arm64.
grep -q "manifests/sha256:m-new1111-arm64$" "$FAKE/curl.log" || fail "not the arm64 manifest: $(cat "$FAKE/curl.log")"
deploy --dry-run new1111 && fail "a dry run of an image that needs newer tools"
has "needs morca-hetzner >= 99.0.0"
hasnt "+ ssh"
untouched "too old, dry run"

# These tools, or older ones, and an image with no minimum: on to the server.
for min in "$v" 0.1.0 none; do
    if [ "$min" = none ]; then rm -f "$FAKE/tools-min/ok2222"; else echo "$min" > "$FAKE/tools-min/ok2222"; fi
    deploy --dry-run ok2222 || fail "a dry run with minimum $min"
    if [ "$min" = none ]; then
        has "ghcr.io/example/census:ok2222 names no minimum morca-hetzner (no dev.morca.hetzner-min label"
    else
        has "ghcr.io/example/census:ok2222 needs morca-hetzner >= $min: these are $v"
    fi
    has "+ ssh root@<server-ip> install -D -m 755 /dev/stdin /usr/local/sbin/morca-stack"
done
untouched "dry runs"

# A private image: a pull token as GHCR_USER, with ghcr-token on curl's
# standard input, never its arguments.
touch "$FAKE/registry-private"
echo 99.0.0 > "$FAKE/tools-min/new1111"
: > "$FAKE/curl.log"
deploy new1111 && fail "deployed a private image that needs newer tools, anonymously"
has "ghcr.io refused example/census (HTTP 401"
grep -q "fake-auth.invalid/token.*scope=repository:example/census:pull$" "$FAKE/curl.log" || fail "no anonymous token asked for"
{
    cat "$FAKE/hetzner.env"
    echo GHCR_USER=someone
    echo "GHCR_TOKEN_FILE=$FAKE/ghcr-token"
} > "$FAKE/private.env"
: > "$FAKE/curl.log"
(HETZNER_ENV="$FAKE/private.env" && deploy new1111) && fail "deployed a private image that needs newer tools"
has "needs morca-hetzner >= 99.0.0"
grep -q "fake-auth.invalid/token.*(as user)$" "$FAKE/curl.log" || fail "the token wasn't asked for as GHCR_USER: $(cat "$FAKE/curl.log")"
! grep -q ghcr-secret "$FAKE/curl.log" "$FAKE/out" || fail "the ghcr token was printed or passed as an argument"
untouched "private"
rm "$FAKE/registry-private"

# The registry down, or the tag not there: a deploy stops, a dry run warns,
# --skip-tools-check goes on without asking.
touch "$FAKE/registry-down"
deploy ok2222 && fail "deployed with the registry down"
has "couldn't read which morca-hetzner ghcr.io/example/census:ok2222 needs from its registry: couldn't reach ghcr.io"
has "(--skip-tools-check goes on without the check)"
untouched "registry down"
deploy --dry-run ok2222 || fail "a dry run with the registry down"
has "# warning: couldn't read which morca-hetzner ghcr.io/example/census:ok2222 needs"
: > "$FAKE/curl.log"
deploy --dry-run --skip-tools-check new1111 || fail "--skip-tools-check"
has "deploy.sh: --skip-tools-check: not checking which morca-hetzner ghcr.io/example/census:new1111 needs"
[ ! -s "$FAKE/curl.log" ] || fail "--skip-tools-check asked the registry"
rm "$FAKE/registry-down"
echo gone3333 > "$FAKE/registry-missing"
deploy gone3333 && fail "deployed a tag the registry hasn't"
has "no example/census:gone3333 on ghcr.io (HTTP 404)"
untouched "missing tag"

# A rollback doesn't ask the registry.
: > "$FAKE/curl.log"
deploy --dry-run --rollback || fail "deploy.sh --dry-run --rollback"
[ ! -s "$FAKE/curl.log" ] || fail "a rollback asked the registry: $(cat "$FAKE/curl.log")"

# up.sh: MORCA_TAG checked before any hcloud command; none, not checked.
echo MORCA_TAG=new1111 >> "$FAKE/hetzner.env"
sh deploy/hetzner/up.sh --dry-run > "$FAKE/out" 2>&1 && fail "up.sh with an image that needs newer tools"
has "up.sh: ghcr.io/example/census:new1111 needs morca-hetzner >= 99.0.0"
hasnt "+ hcloud"
sed -i.bak '/^MORCA_TAG=/d' "$FAKE/hetzner.env"
sh deploy/hetzner/up.sh --dry-run > "$FAKE/out" 2>&1 || fail "up.sh --dry-run without a tag"
has "up.sh: no tag deployed or in MORCA_TAG: not checking"
has "+ hcloud server create"

# promote.sh hands --skip-tools-check to deploy.sh.
cp "$FAKE/hetzner.env" "$FAKE/dev.env"
sh deploy/hetzner/promote.sh --from "$FAKE/dev.env" --dry-run --skip-tools-check > "$FAKE/out" 2>&1 || fail "promote --dry-run"
has "promote.sh: deploy.sh --dry-run --skip-tools-check <dev-tag>"
has "deploy.sh: --skip-tools-check"
echo "ok   hetzner-tools"
