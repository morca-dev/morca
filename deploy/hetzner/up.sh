#!/bin/sh
# up.sh [--dry-run] [--restore <backups/pg/<time>.dump|latest>] [--force] [--yes] [--skip-tools-check]
#
# Makes the morca stack on Hetzner Cloud, or brings what exists back to what
# hetzner.env says; running it again is how drift is fixed. Per step, what
# exists is left alone:
#
#   ssh key, firewall (ssh from ADMIN_IP only), Volume (delete-protected),
#   server (cloud-init: Docker and the Volume mount), then over ssh:
#   morca-stack, the settings and secrets (lib.sh's sync_settings, which
#   deploy.sh runs too), the backup timer, and `morca-stack
#   apply` (postgres, scheduler, ui, apps, sampler, cloudflared).
#
# --restore restores Postgres from Object Storage before the scheduler
# starts (a new server on an empty Volume). --force lets the final apply
# restart the scheduler although runs are running (it kills them).
# --dry-run prints every hcloud and ssh command and runs none.
#
# First, before any Hetzner resource or the server is touched, it checks
# that these scripts are new enough for the image the stack runs (lib.sh's
# check_tools, #461): the tag the server has deployed, or for a new server
# MORCA_TAG; with neither (a dry run asks the server nothing) it says so
# and goes on, deploy.sh checking the tag it deploys. --skip-tools-check
# skips it.
set -eu
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

restore=
force=
parse_common "$@"
# shellcheck disable=SC2086
set -- $REST
while [ $# -gt 0 ]; do
    case "$1" in
        --restore)
            [ $# -ge 2 ] || die "--restore needs a key or latest"
            restore=$2
            shift
            ;;
        --force) force=--force ;;
        *) die "unknown argument $1" ;;
    esac
    shift
done

load_env
need NAME LOCATION ADMIN_IP
need_file SSH_PUBLIC_KEY_FILE
need_settings
need_tool hcloud ssh jq

# --- these scripts against the image's minimum (check_tools) ----------------
# The tag the server runs (read only: morca-stack tags), else MORCA_TAG.
up_tag=
if exists server "$SERVER"; then
    IP=$(server_ip)
    up_tag=$(remote morca-stack tags 2> /dev/null < /dev/null) || up_tag=
    up_tag=${up_tag#morca }
    up_tag=${up_tag#orca }
    up_tag=${up_tag%%,*}
fi
up_tag=${up_tag:-${MORCA_TAG:-}}
if [ -n "$up_tag" ]; then
    check_tools "$up_tag"
else
    echo "up.sh: no tag deployed or in MORCA_TAG: not checking which morca-hetzner the image needs (deploy.sh checks its tag)" >&2
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/morca-hetzner.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- ssh key (another stack's, if it has the same public key) ---------------
ssh_key=$NAME
if exists ssh-key "$NAME"; then
    echo "ssh key $NAME exists"
elif [ "$DRY_RUN" = 0 ] && other=$(same_ssh_key "$SSH_PUBLIC_KEY_FILE") && [ -n "$other" ]; then
    echo "ssh key $other has the same public key; using it (Hetzner takes a public key once per project)"
    ssh_key=$other
else
    hc ssh-key create --name "$NAME" --public-key-from-file "$SSH_PUBLIC_KEY_FILE"
fi

# --- firewall: ssh from ADMIN_IP, nothing else -----------------------------
# (Outbound is open; the tunnel and Object Storage are outbound connections.)
cat > "$tmp/rules.json" << EOS
[{"direction": "in", "protocol": "tcp", "port": "22", "source_ips": ["$ADMIN_IP"], "description": "ssh from the admin"}]
EOS
if exists firewall "$NAME"; then
    echo "firewall $NAME exists; setting its rules"
    hc firewall replace-rules "$NAME" --rules-file "$tmp/rules.json"
else
    hc firewall create --name "$NAME" --rules-file "$tmp/rules.json"
fi

# --- Volume: Postgres's data, formatted once, protected from deletion ------
if exists volume "$NAME-data"; then
    echo "volume $NAME-data exists"
else
    hc volume create --name "$NAME-data" --size "$VOLUME_SIZE_GB" --location "$LOCATION" --format ext4
    hc volume enable-protection "$NAME-data" delete
fi
if [ "$DRY_RUN" = 1 ]; then
    volume_id="<volume-id>"
else
    volume_id=$(hcloud volume describe "$NAME-data" -o json | jq -r .id)
fi

# --- server ----------------------------------------------------------------
if exists server "$SERVER"; then
    echo "server $SERVER exists"
else
    sed -e "s|@@HOSTNAME@@|$NAME|" -e "s|@@VOLUME_ID@@|$volume_id|" "$HERE/cloud-init.yaml" > "$tmp/cloud-init.yaml"
    hc server create --name "$SERVER" --type "$SERVER_TYPE_SMALL" --image "$SERVER_IMAGE" \
        --location "$LOCATION" --ssh-key "$ssh_key" --firewall "$NAME" --volume "$NAME-data" \
        --user-data-from-file "$tmp/cloud-init.yaml" --label orca=true
fi
if [ "$DRY_RUN" = 0 ]; then
    applied=$(hcloud firewall describe "$NAME" -o json | jq -r --arg s "$SERVER" '[.applied_to[]? | select(.type == "server") | .server.id] | length')
    if [ "$applied" = 0 ]; then
        hc firewall apply-to-resource "$NAME" --type server --server "$SERVER"
    fi
else
    echo "+ (if the firewall isn't applied to the server:) hcloud firewall apply-to-resource $NAME --type server --server $SERVER"
fi

IP=$(server_ip)
echo "server $SERVER at $IP"
wait_for_ssh
remote cloud-init status --wait
remote mountpoint -q /mnt/orca-data

# --- settings and secrets (stdin only), stack settings, apps -----------------
# morca-stack first: it writes them (sync_settings in lib.sh, which
# deploy.sh runs too, so a setting changed in hetzner.env later applies on
# the next deploy).
put 755 /usr/local/sbin/morca-stack "$HERE/server/morca-stack"
put 755 /etc/orca/secret-fetch "$HERE/server/secret-fetch"
put 644 /etc/systemd/system/orca-backup.service "$HERE/server/orca-backup.service"
put 644 /etc/systemd/system/orca-backup.timer "$HERE/server/orca-backup.timer"
sync_settings "$tmp" || die "setting the server's settings from $HETZNER_ENV failed"
# The tag is only set by the first up (deploy.sh moves it).
remote morca-stack configure --keep-existing MORCA_TAG="${MORCA_TAG:-latest}"
remote systemctl daemon-reload
remote systemctl enable --now orca-backup.timer

# --- restore, then start everything ------------------------------------------
if [ -n "$restore" ]; then
    remote morca-stack apply --db-only
    remote morca-stack restore "$restore"
fi
remote morca-stack apply ${force:+"$force"}
# The smoke check, as deploy.sh ends with; a new stack fails its
# registration part until the pipelines are registered (below).
# shellcheck disable=SC2046
remote morca-stack check $(check_args) || echo "up: the check failed (above); on a new stack, register the pipelines and run ssh root@$IP morca-stack check" >&2

cat << EOS

up: done. Next (once per new database):
  - Cloudflare: the tunnel's public hostnames point at http://ui:8270 and the apps.
  - ssh root@$IP, then: docker exec -it scheduler morca user add <name>
  - register the pipelines: see docs/hetzner.md
EOS
