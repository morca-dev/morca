#!/bin/sh
# Two stacks from deploy/hetzner, one settings file each (docs/hetzner.md,
# A dev stack), against tests/hetzner's fakes:
#
# - up.sh and down.sh --all with NAME=morca-dev name only morca-dev's server,
#   firewall, Volume and ssh key, never the production stack's (morca), and
#   every script says which stack and settings file it acts on;
# - the settings file's HCLOUD_CONTEXT reaches hcloud;
# - same_ssh_key finds the other stack's key with the same public key
#   (Hetzner takes a public key once per project), and nothing for another;
# - up.sh writes the settings with lib.sh's sync_settings (deploy.sh's too),
#   then MORCA_TAG only if the server has none;
# - the settings file's CONFIG_OVERLAY_FILE, relative to it, is sent as the
#   stack's overlay (#332), and settings.env names it;
# - an MORCA_CONFIG in the settings (EXTRA_ENV_FILE's lines end up in
#   settings.env) is in the scheduler's env file, which `morca register`
#   runs with.
set -eu
cd "$(dirname "$0")/.."
FAKE=$(mktemp -d "${TMPDIR:-/tmp}/morca-hetzner.XXXXXX")
export FAKE
trap 'rm -rf "$FAKE"' EXIT INT TERM
export PATH="$PWD/tests/hetzner:$PATH"
XDG_STATE_HOME="$FAKE/xdg"
export XDG_STATE_HOME

fail() {
    echo "FAIL: $*"
    [ ! -f "$FAKE/out" ] || tail -20 "$FAKE/out"
    exit 1
}
has() { grep -q -- "$1" "$FAKE/out" || fail "no '$1' in the output"; }

cat > "$FAKE/dev.env" << EOS
NAME=morca-dev
HCLOUD_CONTEXT=morca-dev
BUCKET=morca-dev-bkt
S3_ENDPOINT=https://fsn1.example.invalid
S3_REGION=fsn1
DRAIN_SECONDS=86400
ADMIN_IP=203.0.113.7/32
SSH_PUBLIC_KEY_FILE=$FAKE/k.pub
S3_CREDENTIALS_FILE=$FAKE/s3.env
TUNNEL_TOKEN_FILE=$FAKE/tunnel.env
EXTRA_ENV_FILE=$FAKE/extra.env
CONFIG_OVERLAY_FILE=dev.overlay.toml
EOS
echo MORCA_CONFIG=/opt/morca/morca.dev.toml > "$FAKE/extra.env"
printf '[defaults]\nenabled = false\n' > "$FAKE/dev.overlay.toml"

# up.sh: every Hetzner resource is morca-dev's.
HETZNER_ENV="$FAKE/dev.env" sh deploy/hetzner/up.sh --dry-run > "$FAKE/out" 2>&1 || fail "up.sh --dry-run"
has "up.sh: stack morca-dev (hcloud context morca-dev), settings $FAKE/dev.env"
has "+ hcloud ssh-key create --name morca-dev "
has "+ hcloud firewall create --name morca-dev "
has "+ hcloud volume create --name morca-dev-data "
has "+ hcloud server create --name morca-dev .* --ssh-key morca-dev --firewall morca-dev --volume morca-dev-data "
grep '^+ hcloud' "$FAKE/out" | grep -E '(^| )morca( |$)|[ ]morca-data( |$)' && fail "up.sh names the production stack's resources"
# Its settings, as deploy.sh writes them too (lib.sh's sync_settings), then
# the tag only if the server has none.
has "+ ssh root@<server-ip> morca-stack sync --keys settings.env < "
has "+ ssh root@<server-ip> morca-stack sync tunnel.env < $FAKE/tunnel.env"
# The stack's overlay, named relative to its settings file (#332).
has "+ ssh root@<server-ip> morca-stack sync overlay/morca.overlay.toml < $FAKE/dev.overlay.toml"
has "+ ssh root@<server-ip> morca-stack configure MORCA_IMAGE=ghcr.io/morca-dev/census .*BUCKET=morca-dev-bkt BACKUP_KEEP=14 GHCR_USER= OVERLAP=1 DRAIN_SECONDS=86400 HANDOVER_WAIT_SECONDS= ZSWAP=$"
has "+ ssh root@<server-ip> morca-stack configure --keep-existing MORCA_TAG=latest"
has "# settings.env from $FAKE/dev.env: AWS_REGION .* MORCA_CONFIG_OVERLAY MORCA_CONFIG "
# down.sh --all: the same.
HETZNER_ENV="$FAKE/dev.env" sh deploy/hetzner/down.sh --dry-run --all > "$FAKE/out" 2>&1 || fail "down.sh --dry-run --all"
has "+ hcloud server delete morca-dev$"
has "+ hcloud volume delete morca-dev-data$"
has "+ hcloud firewall delete morca-dev$"
has "+ hcloud ssh-key delete morca-dev$"
grep '^+ hcloud' "$FAKE/out" | grep -E '(^| )morca( |$)|[ ]morca-data( |$)' && fail "down.sh names the production stack's resources"

# HCLOUD_CONTEXT reaches hcloud (deploy.sh's server ip, a real call).
printf 'NAME=morca\nHCLOUD_CONTEXT=prod-ctx\n' > "$FAKE/prod.env"
: > "$FAKE/hcloud.log"
HETZNER_ENV="$FAKE/prod.env" sh deploy/hetzner/backup.sh > "$FAKE/out" 2>&1 || true
grep -q '^prod-ctx: hcloud server ip morca$' "$FAKE/hcloud.log" || fail "hcloud didn't get HCLOUD_CONTEXT: $(cat "$FAKE/hcloud.log")"

# same_ssh_key: the key of another stack with the same public key.
ssh-keygen -q -t ed25519 -N '' -C test -f "$FAKE/k"
ssh-keygen -q -t ed25519 -N '' -C test -f "$FAKE/other"
fp=$(ssh-keygen -l -E md5 -f "$FAKE/k.pub" | awk '{print $2}')
fp=${fp#MD5:}
printf '[{"id": 1, "name": "laptop", "fingerprint": "00:11"}, {"id": 2, "name": "morca", "fingerprint": "%s"}]\n' "$fp" > "$FAKE/ssh-keys.json"
lib() { sh -c '. deploy/hetzner/lib.sh; same_ssh_key "$1"' sh "$1"; }
[ "$(lib "$FAKE/k.pub")" = morca ] || fail "same_ssh_key: '$(lib "$FAKE/k.pub")', not morca"
[ -z "$(lib "$FAKE/other.pub")" ] || fail "same_ssh_key found a key for another public key"
[ -z "$(lib "$FAKE/missing.pub")" ] || fail "same_ssh_key found a key for no file"

# MORCA_CONFIG from the settings is in the scheduler's env file.
export MORCA_STACK_TEST=1 MORCA_CONF="$FAKE/conf" MORCA_DATA="$FAKE/data" MORCA_STATE="$FAKE/state"
mkdir -p "$MORCA_CONF"
{
    printf 'AWS_REGION=fsn1\nAWS_ENDPOINT_URL_S3=https://example.invalid\n'
    cat "$FAKE/extra.env"
} > "$MORCA_CONF/settings.env"
printf 'AWS_ACCESS_KEY_ID=x\nAWS_SECRET_ACCESS_KEY=y\n' > "$MORCA_CONF/s3.env"
stack() { sh deploy/hetzner/server/morca-stack "$@"; }
stack configure MORCA_IMAGE=img MORCA_TAG=aaa1111 BUCKET=morca-dev-bkt DRAIN_SECONDS=86400 > /dev/null
stack apply > "$FAKE/out" 2>&1 || fail "morca-stack apply"
grep -qx 'MORCA_CONFIG=/opt/morca/morca.dev.toml' "$MORCA_CONF/morca.env" || fail "no MORCA_CONFIG in morca.env"
grep -q "run -d --name scheduler .*--env-file $MORCA_CONF/morca.env" "$FAKE/docker.log" || fail "the scheduler doesn't get morca.env"

echo "ok   hetzner-stacks"
