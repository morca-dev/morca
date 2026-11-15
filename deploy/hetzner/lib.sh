# shellcheck shell=sh disable=SC2218
# (SC2218, "defined later", is wrong here: this file only defines functions,
# all called once it has been sourced.)
# Shared by the scripts in this directory (sourced, not run). POSIX sh.
#
# - the settings: $HETZNER_ENV, else hetzner.env next to the scripts
#   (hetzner.env.example lists every one), then this laptop's own, if it
#   has them: $HETZNER_LOCAL_ENV, else ~/.config/morca-hetzner/<NAME>.local.env;
#   a relative file name in either is read from that file's folder;
# - --dry-run: every hcloud and ssh command is printed, none is run, and
#   nothing is created, changed or read from the server;
# - nothing here prints a secret: files that hold one are only ever sent to
#   the server on ssh's standard input.

HERE=$(cd "$(dirname "$0")" && pwd)
# These scripts' own version (#461): deploy/hetzner/VERSION, which moves
# only when deploy/hetzner changes (scripts/hetzner-version.sh), and which
# package.sh copies into a release's tarball. Not morca's version: a morca
# release that changes nothing here ships the same tools again.
SCRIPTS_VERSION=
[ ! -r "$HERE/VERSION" ] || SCRIPTS_VERSION=$(cat "$HERE/VERSION")
DRY_RUN=0
YES=0
SKIP_TOOLS_CHECK=0

die() {
    echo "$(basename "$0"): $*" >&2
    exit 1
}

# The settings that name a file: a relative one is read from the folder of
# the settings file that sets it (resolve_paths).
PATH_SETTINGS="SECRETS_FILE S3_CREDENTIALS_FILE TUNNEL_TOKEN_FILE GITHUB_TOKEN_FILE
NTFY_TOPIC_FILE NTFY_TOKEN_FILE GHCR_TOKEN_FILE EXTRA_ENV_FILE CONFIG_OVERLAY_FILE SSH_PUBLIC_KEY_FILE SSH_PRIVATE_KEY_FILE"

# resolve_paths DIR: each PATH_SETTINGS that is set and relative becomes
# DIR/<it>. Run after each settings file, so a shared hetzner.env (in a
# secrets repository, say) can name its files wherever it is cloned.
resolve_paths() {
    for v in $PATH_SETTINGS; do
        eval "val=\${$v:-}"
        case $val in
            "" | /*) ;;
            *) eval "$v=\$1/\$val" ;;
        esac
    done
}

# absolute FILE: FILE, from the current folder if it's relative.
absolute() {
    case $1 in
        /*) echo "$1" ;;
        *) echo "$(pwd)/$1" ;;
    esac
}

load_env() {
    HETZNER_ENV=${HETZNER_ENV:-$HERE/hetzner.env}
    [ -f "$HETZNER_ENV" ] || die "no $HETZNER_ENV (copy hetzner.env.example and fill it in, or set HETZNER_ENV)"
    HETZNER_ENV=$(absolute "$HETZNER_ENV")
    # shellcheck disable=SC1090
    . "$HETZNER_ENV"
    resolve_paths "$(dirname "$HETZNER_ENV")"
    # Still orca: the stack's servers, Volume and firewall are named after it.
    NAME=${NAME:-orca}
    # This laptop's settings (ADMIN_IP, SSH_PUBLIC_KEY_FILE...), read after
    # the shared file, so they win. Optional, unless HETZNER_LOCAL_ENV names it.
    LOCAL_ENV=${HETZNER_LOCAL_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/morca-hetzner/$NAME.local.env}
    old_local=${XDG_CONFIG_HOME:-$HOME/.config}/orca-hetzner/$NAME.local.env
    [ -n "${HETZNER_LOCAL_ENV:-}" ] || [ -f "$LOCAL_ENV" ] || [ ! -f "$old_local" ] \
        || die "$old_local is from before the rename to morca (#384): move it to $LOCAL_ENV"
    if [ -f "$LOCAL_ENV" ]; then
        LOCAL_ENV=$(absolute "$LOCAL_ENV")
        shared_name=$NAME
        # shellcheck disable=SC1090
        . "$LOCAL_ENV"
        [ "${NAME:-}" = "$shared_name" ] || die "$LOCAL_ENV sets NAME: the stack's name belongs in $HETZNER_ENV"
        resolve_paths "$(dirname "$LOCAL_ENV")"
    elif [ -n "${HETZNER_LOCAL_ENV:-}" ]; then
        die "no $HETZNER_LOCAL_ENV (HETZNER_LOCAL_ENV)"
    else
        LOCAL_ENV=
    fi
    # The settings were ORCA_* before the rename to morca (#384), and morca
    # reads only MORCA_*: refuse an old key rather than drop it.
    for f in "$HETZNER_ENV" ${LOCAL_ENV:+"$LOCAL_ENV"} ${EXTRA_ENV_FILE:+"$EXTRA_ENV_FILE"}; do
        [ -f "$f" ] || continue
        old=$(sed -n 's/^[[:space:]]*\(export[[:space:]]*\)\{0,1\}\(ORCA_[A-Za-z0-9_]*\)=.*/\2/p' "$f" | tr '\n' ' ')
        [ -z "$old" ] || die "$f sets ${old% }: since the rename to morca (#384) these are MORCA_*"
    done
    LOCATION=${LOCATION:-fsn1}
    SERVER_TYPE_SMALL=${SERVER_TYPE_SMALL:-cax21}
    SERVER_TYPE_BIG=${SERVER_TYPE_BIG:-cax41}
    SERVER_IMAGE=${SERVER_IMAGE:-ubuntu-24.04}
    VOLUME_SIZE_GB=${VOLUME_SIZE_GB:-50}
    MORCA_IMAGE=${MORCA_IMAGE:-ghcr.io/morca-dev/census}
    CLOUDFLARED_IMAGE=${CLOUDFLARED_IMAGE:-cloudflare/cloudflared:2026.10.7}
    APPS=${APPS:-console:8080}
    BACKUP_KEEP=${BACKUP_KEEP:-14}
    # Overlapping schedulers (docs/overlap.md): on unless OVERLAP=0.
    OVERLAP=${OVERLAP:-1}
    SERVER=$NAME
    # The settings file may name the hcloud context (the Hetzner project) the
    # stack is in; otherwise hcloud's active one.
    [ -z "${HCLOUD_CONTEXT:-}" ] || export HCLOUD_CONTEXT
    # Which stack, as there may be more than one (docs/hetzner.md, A dev stack).
    echo "$(basename "$0"): stack $NAME${HCLOUD_CONTEXT:+ (hcloud context $HCLOUD_CONTEXT)}, settings $HETZNER_ENV${LOCAL_ENV:+ and $LOCAL_ENV}${SCRIPTS_VERSION:+, scripts $SCRIPTS_VERSION}" >&2
}

# need VAR...: each is set in the settings file.
need() {
    for v in "$@"; do
        eval "val=\${$v:-}"
        [ -n "$val" ] || die "$v isn't set in $HETZNER_ENV"
    done
}

# need_file VAR...: each names a readable file (a warning in a dry run).
need_file() {
    for v in "$@"; do
        eval "val=\${$v:-}"
        [ -n "$val" ] || die "$v isn't set in $HETZNER_ENV"
        if [ ! -r "$val" ]; then
            if [ "$DRY_RUN" = 1 ]; then
                echo "# warning: $v ($val) isn't a readable file" >&2
            else
                die "$v ($val) isn't a readable file"
            fi
        fi
    done
}

need_tool() {
    for t in "$@"; do
        command -v "$t" > /dev/null 2>&1 || [ "$DRY_RUN" = 1 ] || die "$t isn't installed"
    done
}

# run CMD ARGS...: runs it, or prints it in a dry run.
run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '+'
        for a in "$@"; do printf ' %s' "$a"; done
        printf '\n'
    else
        "$@"
    fi
}

hc() {
    run hcloud "$@"
}

# exists KIND NAME: whether hcloud has it (never, in a dry run: so the
# creation commands are printed).
exists() {
    [ "$DRY_RUN" = 0 ] && hcloud "$1" describe "$2" > /dev/null 2>&1
}

confirm() { # QUESTION: yes with --yes or a typed "yes"
    [ "$YES" = 1 ] && return 0
    [ "$DRY_RUN" = 0 ] || return 0
    printf '%s Type yes to go on: ' "$1" >&2
    read -r answer
    [ "$answer" = yes ] || die "not confirmed"
}

# same_ssh_key FILE: the name of the project's ssh key whose public key is
# FILE's, if it has one. Hetzner refuses a second key with the same public
# key, so a second stack in the project (NAME=orca-dev) uses the first's.
same_ssh_key() {
    fp=$(ssh-keygen -l -E md5 -f "$1" 2> /dev/null | awk '{print $2}')
    fp=${fp#MD5:}
    [ -n "$fp" ] || return 0
    hcloud ssh-key list -o json | jq -r --arg fp "$fp" '[.[] | select(.fingerprint == $fp) | .name][0] // empty'
}

server_ip() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "<server-ip>"
    else
        hcloud server ip "$SERVER"
    fi
}

KNOWN_HOSTS=${XDG_STATE_HOME:-$HOME/.local/state}/morca-hetzner/known_hosts

# remote ARGS...: ssh to the server as root; the arguments are the remote command.
remote() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "+ ssh root@$IP $*"
        return 0
    fi
    mkdir -p "$(dirname "$KNOWN_HOSTS")"
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" ${SSH_PRIVATE_KEY_FILE:+-i "$SSH_PRIVATE_KEY_FILE"} \
        "root@$IP" "$@"
}

# put MODE DEST SRC: SRC's content to DEST on the server, over stdin.
put() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "+ ssh root@$IP install -D -m $1 /dev/stdin $2 < $3"
    else
        remote "install -D -m $1 /dev/stdin $2" < "$3"
    fi
}

wait_for_ssh() {
    [ "$DRY_RUN" = 0 ] || return 0
    n=0
    until remote true > /dev/null 2>&1; do
        n=$((n + 1))
        [ "$n" -lt 60 ] || die "no ssh to $IP after 5 minutes"
        sleep 5
    done
}

parse_common() { # sets REST to the arguments not handled here
    REST=
    for a in "$@"; do
        case "$a" in
            --dry-run) DRY_RUN=1 ;;
            --yes | -y) YES=1 ;;
            --skip-tools-check) SKIP_TOOLS_CHECK=1 ;;
            *) REST="$REST $a" ;;
        esac
    done
}

# --- the tools' version against the image's minimum (#461) -------------------
# A morca image says which of these scripts it needs: its label
# dev.morca.hetzner-min, the oldest morca-hetzner version that knows what
# its morca asks of the server (deploy/runtime.Dockerfile sets it; a
# project's image built FROM morca-runtime inherits it). check_tools reads
# it from the registry, not the server, so it runs before anything there
# is touched, and before up.sh makes a server at all. An image without the
# label (from before it) has no minimum.
TOOLS_MIN_LABEL=dev.morca.hetzner-min
TOOLS_URL=https://github.com/morca-dev/morca/releases/latest/download/morca-hetzner.tar.gz

# version_lt A B: version A (1.2.3) is older than B.
version_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, "."); n = na > nb ? na : nb
        for (i = 1; i <= n; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
        exit 1 }'
}

# reg_curl PATH: GET https://R_HOST/v2/R_REPO/PATH into $R_DIR/body (headers
# in $R_DIR/headers), printing the HTTP status. The token goes in curl's
# config on standard input, not its arguments.
reg_curl() {
    {
        printf 'header = "Accept: %s"\n' "$R_ACCEPT"
        [ -z "$R_TOKEN" ] || printf 'header = "Authorization: Bearer %s"\n' "$R_TOKEN"
    } | curl -sS -L --max-time 60 -K - -D "$R_DIR/headers" -o "$R_DIR/body" -w '%{http_code}' \
        "https://$R_HOST/v2/$R_REPO/$1"
}

# ghcr_token: the ghcr-token secret's value (SECRETS_FILE's, or
# GHCR_TOKEN_FILE's), or nothing. Never printed but to curl's config.
ghcr_token() {
    if in_secrets ghcr-token && [ -n "$SECRETS_JSON" ]; then
        printf '%s' "$SECRETS_JSON" | jq -j '.["ghcr-token"]'
    elif [ -n "${GHCR_TOKEN_FILE:-}" ] && [ -r "$GHCR_TOKEN_FILE" ]; then
        if is_sops "$GHCR_TOKEN_FILE"; then sops -d "$GHCR_TOKEN_FILE"; else cat "$GHCR_TOKEN_FILE"; fi
    fi
}

# reg_token: a pull token from the realm the last 401's WWW-Authenticate
# names, as GHCR_USER on ghcr.io (with ghcr-token) or anonymously.
reg_token() {
    h=$(tr -d '\r' < "$R_DIR/headers" | sed -n 's/^[Ww][Ww][Ww]-[Aa][Uu][Tt][Hh][Ee][Nn][Tt][Ii][Cc][Aa][Tt][Ee]: *[Bb]earer *//p' | tail -n 1)
    realm=$(echo "$h" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
    service=$(echo "$h" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
    [ -n "$realm" ] || {
        R_ERR="$R_HOST asks for a login it doesn't say how to get"
        return 1
    }
    tok_=
    [ "$R_HOST" != ghcr.io ] || [ -z "${GHCR_USER:-}" ] || tok_=$(ghcr_token) || tok_=
    R_TOKEN=$({
        [ -z "$tok_" ] || printf 'user = "%s:%s"\n' "$GHCR_USER" "$tok_"
    } | curl -fsS --max-time 60 -K - "$realm?service=$service&scope=repository:$R_REPO:pull" \
        | jq -r '.token // .access_token // empty') || R_TOKEN=
    tok_=
    [ -n "$R_TOKEN" ] || {
        R_ERR="no pull token from $realm${GHCR_USER:+ as $GHCR_USER}"
        return 1
    }
}

# reg_get PATH: reg_curl, logging in once on a 401; fails with R_ERR set
# unless the answer is a 200.
reg_get() {
    code=$(reg_curl "$1") || {
        R_ERR="couldn't reach $R_HOST"
        return 1
    }
    if [ "$code" = 401 ] && [ -z "$R_TOKEN" ]; then
        reg_token || return 1
        code=$(reg_curl "$1") || {
            R_ERR="couldn't reach $R_HOST"
            return 1
        }
    fi
    case $code in
        200) ;;
        401 | 403) R_ERR="$R_HOST refused $R_REPO (HTTP $code: a private image needs GHCR_USER and ghcr-token)" && return 1 ;;
        404) R_ERR="no $R_REPO:$R_TAG on $R_HOST (HTTP 404)" && return 1 ;;
        *) R_ERR="$R_HOST answered HTTP $code for $1" && return 1 ;;
    esac
}

# image_min IMAGE TAG: the image's dev.morca.hetzner-min label, or nothing
# when it has none; on failure, why, and non-zero. For a multi-platform
# image, the server's platform's (cax: arm64, otherwise amd64).
image_min() {
    R_TAG=$2
    R_TOKEN=
    R_ERR=
    first=${1%%/*}
    case $1 in
        */*)
            case $first in
                *.* | *:* | localhost) R_HOST=$first R_REPO=${1#*/} ;;
                *) R_HOST=docker.io R_REPO=$1 ;;
            esac
            ;;
        *) R_HOST=docker.io R_REPO=$1 ;;
    esac
    if [ "$R_HOST" = docker.io ]; then
        R_HOST=registry-1.docker.io
        case $R_REPO in */*) ;; *) R_REPO=library/$R_REPO ;; esac
    fi
    case $SERVER_TYPE_SMALL in cax*) arch=arm64 ;; *) arch=amd64 ;; esac
    R_DIR=$(mktemp -d "${TMPDIR:-/tmp}/morca-hetzner-registry.XXXXXX")
    R_ACCEPT="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
    # Not image_min_; st=$?: under set -e that exits a $(...) at once.
    if image_min_ "$arch"; then st=0; else st=1; fi
    [ "$st" = 0 ] || echo "$R_ERR"
    rm -rf "$R_DIR"
    R_TOKEN=
    return "$st"
}

image_min_() {
    reg_get "manifests/$R_TAG" || return 1
    if jq -e '.manifests' "$R_DIR/body" > /dev/null 2>&1; then
        d_=$(jq -r --arg a "$1" '[.manifests[] | select(.platform.os == "linux")]
            | (map(select(.platform.architecture == $a)) + .)[0].digest // empty' "$R_DIR/body")
        [ -n "$d_" ] || {
            R_ERR="$R_REPO:$R_TAG has no linux image"
            return 1
        }
        reg_get "manifests/$d_" || return 1
    fi
    d_=$(jq -r '.config.digest // empty' "$R_DIR/body" 2> /dev/null)
    [ -n "$d_" ] || {
        R_ERR="$R_REPO:$R_TAG's manifest names no config"
        return 1
    }
    reg_get "blobs/$d_" || return 1
    jq -r --arg l "$TOOLS_MIN_LABEL" '.config.Labels[$l] // empty' "$R_DIR/body" 2> /dev/null || {
        R_ERR="$R_REPO:$R_TAG's config isn't JSON"
        return 1
    }
}

# check_tools TAG: these scripts are at least the version MORCA_IMAGE:TAG
# needs, or it stops, naming that version and where to get it. Run before
# anything on the server is touched. A dry run only warns when the
# registry can't be read (it doesn't decrypt the ghcr-token);
# --skip-tools-check skips it.
check_tools() {
    img_=$MORCA_IMAGE:$1
    me_=$(basename "$0")
    if [ "$SKIP_TOOLS_CHECK" = 1 ]; then
        echo "$me_: --skip-tools-check: not checking which morca-hetzner $img_ needs" >&2
        return 0
    fi
    if [ -z "$SCRIPTS_VERSION" ]; then
        echo "$me_: warning: no VERSION beside these scripts, so not checking which morca-hetzner $img_ needs" >&2
        return 0
    fi
    case $1 in
        *"<"*)
            echo "# a dry run doesn't know the tag ($1): not checking which morca-hetzner it needs" >&2
            return 0
            ;;
    esac
    need_tool curl jq
    if ! min_=$(image_min "$MORCA_IMAGE" "$1"); then
        if [ "$DRY_RUN" = 1 ]; then
            echo "# warning: couldn't read which morca-hetzner $img_ needs: $min_" >&2
            return 0
        fi
        die "couldn't read which morca-hetzner $img_ needs from its registry: $min_; nothing was changed on the server (--skip-tools-check goes on without the check)"
    fi
    if [ -z "$min_" ]; then
        echo "$me_: $img_ names no minimum morca-hetzner (no $TOOLS_MIN_LABEL label: an image from before it): going on with $SCRIPTS_VERSION" >&2
    elif version_lt "$SCRIPTS_VERSION" "$min_"; then
        die "$img_ needs morca-hetzner >= $min_, and these scripts are $SCRIPTS_VERSION: get the newest with curl -fsSL $TOOLS_URL | tar -xz, and run them from morca-hetzner-<version>/; nothing was changed on the server"
    else
        echo "$me_: $img_ needs morca-hetzner >= $min_: these are $SCRIPTS_VERSION" >&2
    fi
}

# check_args: morca-stack check's arguments from hetzner.env: a --canary for
# each of CANARY's PIPELINE=KEY, and CANARY_TIMEOUT's --timeout.
check_args() {
    for c in ${CANARY:-}; do
        case $c in ?*=?*) ;; *) die "CANARY: '$c' isn't PIPELINE=KEY" ;; esac
        printf ' --canary %s' "$c"
    done
    [ -z "${CANARY_TIMEOUT:-}" ] || printf ' --timeout %s' "$CANARY_TIMEOUT"
}

# --- the server's settings, from hetzner.env (up.sh and deploy.sh) ---------

# need_settings: what settings.env, the secret files and the stack settings
# are made from is set. With SECRETS_FILE, decrypts it (load_secrets), so a
# decrypt failure stops before anything is changed on the server.
need_settings() {
    need_drain_limit
    case $OVERLAP in 0 | 1) ;; *) die "OVERLAP is 1 (overlapping schedulers, the default) or 0, not '$OVERLAP' ($HETZNER_ENV); nothing was changed on the server" ;; esac
    need BUCKET S3_ENDPOINT S3_REGION
    [ -z "${EXTRA_ENV_FILE:-}" ] || need_file EXTRA_ENV_FILE
    [ -z "${CONFIG_OVERLAY_FILE:-}" ] || need_file CONFIG_OVERLAY_FILE
    load_secrets
    for name in $SECRET_NAMES; do
        v=$(secret_var "$name")
        eval "val=\${$v:-}"
        if in_secrets "$name"; then
            [ -z "$val" ] || die "$v and SECRETS_FILE both give $name: set only one (remove $v, or the key $name from $SECRETS_FILE)"
        elif [ -n "$val" ]; then
            need_file "$v"
        else
            case $name in
                s3.env | tunnel.env) die "$v isn't set in $HETZNER_ENV${SECRETS_FILE:+, and SECRETS_FILE has no $name}" ;;
            esac
        fi
    done
    [ -z "${GHCR_USER:-}" ] || has_secret ghcr-token \
        || die "GHCR_USER needs GHCR_TOKEN_FILE or a ghcr-token key in SECRETS_FILE"
    for v in S3_CREDENTIALS_FILE TUNNEL_TOKEN_FILE GITHUB_TOKEN_FILE NTFY_TOPIC_FILE NTFY_TOKEN_FILE GHCR_TOKEN_FILE CONFIG_OVERLAY_FILE; do
        eval "val=\${$v:-}"
        if is_sops "$val"; then
            need_tool sops
            break
        fi
    done
}

# need_drain_limit: DRAIN_SECONDS, required (#390), is a whole number of
# seconds above 0: how long an old scheduler may keep draining its runs
# after a deploy before it is stopped (docs/hetzner.md#the-drain-limit).
# Checked before anything is changed on the server.
need_drain_limit() {
    d_how="set DRAIN_SECONDS in $HETZNER_ENV to how long, in seconds, an old scheduler may keep draining its runs after a deploy before it is stopped and its runs queued again (e.g. DRAIN_SECONDS=604800, a week; docs/hetzner.md#the-drain-limit); nothing was changed on the server"
    case ${DRAIN_SECONDS:-} in
        "") die "DRAIN_SECONDS isn't set: $d_how" ;;
        *[!0-9]*) die "DRAIN_SECONDS=$DRAIN_SECONDS isn't a whole number of seconds above 0: $d_how" ;;
    esac
    [ "$DRAIN_SECONDS" -gt 0 ] || die "DRAIN_SECONDS=$DRAIN_SECONDS isn't a whole number of seconds above 0: $d_how"
}

# --- SECRETS_FILE: every secret in one SOPS file, one `sops -d` ----------------
# Its top-level keys are these, the files' names under /etc/orca, and each
# value is the file's content (a string). It may have more secrets/orca/<id>
# keys, the secrets the apps' [apps.<name>] secrets name (#331), sent the same way. One decrypt per run: a Secure
# Enclave age key (age-plugin-se) asks for Touch ID once, not per file.
SECRET_NAMES="s3.env tunnel.env secrets/orca/github-token secrets/orca/ntfy-topic secrets/orca/ntfy-token ghcr-token secrets/orca/hcloud-token"
SECRETS_JSON=
SECRETS_KEYS=
SECRETS_LOADED=0

# secret_var NAME: the per-secret *_FILE setting for NAME.
secret_var() {
    case $1 in
        s3.env) echo S3_CREDENTIALS_FILE ;;
        tunnel.env) echo TUNNEL_TOKEN_FILE ;;
        secrets/orca/github-token) echo GITHUB_TOKEN_FILE ;;
        secrets/orca/ntfy-topic) echo NTFY_TOPIC_FILE ;;
        secrets/orca/ntfy-token) echo NTFY_TOKEN_FILE ;;
        ghcr-token) echo GHCR_TOKEN_FILE ;;
        secrets/orca/hcloud-token) echo HCLOUD_POOL_TOKEN_FILE ;;
    esac
}

# in_secrets NAME: SECRETS_FILE has the key NAME.
in_secrets() {
    case " $SECRETS_KEYS " in *" $1 "*) return 0 ;; esac
    return 1
}

# has_secret NAME: the secret NAME is given, by SECRETS_FILE or its *_FILE.
has_secret() {
    in_secrets "$1" && return 0
    eval "val=\${$(secret_var "$1"):-}"
    [ -n "$val" ]
}

clear_secrets() {
    SECRETS_JSON=
}

# load_secrets: decrypts SECRETS_FILE, if set, once, into SECRETS_JSON (a
# shell variable, never a file) and checks its keys. A dry run doesn't
# decrypt: it assumes the file has every secret no *_FILE setting gives.
load_secrets() {
    [ -n "${SECRETS_FILE:-}" ] && [ "$SECRETS_LOADED" = 0 ] || return 0
    need_file SECRETS_FILE
    need_tool sops jq
    SECRETS_LOADED=1
    if [ "$DRY_RUN" = 1 ]; then
        for name in $SECRET_NAMES; do
            eval "val=\${$(secret_var "$name"):-}"
            [ -n "$val" ] || SECRETS_KEYS="$SECRETS_KEYS $name"
        done
        echo "# a dry run doesn't decrypt $SECRETS_FILE: it assumes it has${SECRETS_KEYS:- nothing}" >&2
        return 0
    fi
    SECRETS_JSON=$(sops -d --output-type json "$SECRETS_FILE") || {
        SECRETS_JSON=
        die "sops couldn't decrypt $SECRETS_FILE; nothing was changed on the server"
    }
    # Key names aren't secret; a value never leaves jq here.
    bad=$(printf '%s' "$SECRETS_JSON" | jq -r --arg known "$SECRET_NAMES" '
        if type != "object" then "it is not a mapping of file names to their contents"
        else ($known | split(" ")) as $k | to_entries[]
            | if (.key | startswith("/") or contains("..")) then "\(.key | @json): a name has no leading / and no .."
              elif (.key | IN($k[]) | not) and (.key | test("^secrets/orca/[A-Za-z0-9_+=.@-]+(/[A-Za-z0-9_+=.@-]+)*$") | not)
                then "\(.key | @json) is not one of: \($known), or secrets/orca/<id>"
              elif (.value | type) != "string" then "\(.key | @json): the value is a \(.value | type), not a string (quote it, or use |)"
              else empty end
        end') || {
        SECRETS_JSON=
        die "$SECRETS_FILE didn't decrypt to JSON"
    }
    if [ -n "$bad" ]; then
        clear_secrets
        die "$SECRETS_FILE: $bad"
    fi
    SECRETS_KEYS=$(printf '%s' "$SECRETS_JSON" | jq -r 'keys_unsorted[]' | tr '\n' ' ')
}

# sync_secret NAME: SECRETS_FILE's value of NAME becomes /etc/orca/NAME, as
# sync_file sends a *.sops file: without trailing newlines, then one.
sync_secret() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "| ssh root@$IP morca-stack sync $1"
        return 0
    fi
    plain=$(printf '%s' "$SECRETS_JSON" | jq -j --arg k "$1" '.[$k]') || {
        plain=
        return 1
    }
    printf '%s\n' "$plain" | remote morca-stack sync "$1"
    st=$?
    plain=
    return "$st"
}

# is_sops FILE: FILE is encrypted with SOPS (named *.sops or *.sops.<ext>,
# e.g. s3.sops.env), so sync_file sends what `sops -d` makes of it.
is_sops() {
    case "$1" in */*.sops | */*.sops.* | *.sops | *.sops.*) return 0 ;; esac
    return 1
}

# write_settings FILE: /etc/orca/settings.env as hetzner.env says. No
# secret is in it: those are files of their own, and only their ids are here.
# A setting hetzner.env leaves empty isn't written.
write_settings() {
    {
        echo "AWS_REGION=$S3_REGION"
        echo "AWS_ENDPOINT_URL_S3=$S3_ENDPOINT"
        echo "MORCA_WAREHOUSE=s3://$BUCKET/warehouse"
        echo "MORCA_PUBLIC_WAREHOUSE=s3://$BUCKET/warehouse"
        echo "MORCA_LOGS=s3://$BUCKET/logs"
        echo "MORCA_RUN_ENV=MORCA_PUBLIC_WAREHOUSE"
        # Alerts (ntfy): the topic and token are secret files, only their ids are here.
        if has_secret secrets/orca/ntfy-topic; then
            echo "MORCA_NOTIFY_SECRET=orca/ntfy-topic"
            [ -z "${NTFY_URL:-}" ] || echo "MORCA_NOTIFY_URL=$NTFY_URL"
            ! has_secret secrets/orca/ntfy-token || echo "MORCA_NOTIFY_TOKEN_SECRET=orca/ntfy-token"
        fi
        # Where links point, and where pool machines reach the UI.
        [ -z "${UI_URL:-}" ] || echo "MORCA_UI_URL=$UI_URL"
        # Worker pools morca grows itself ([pools.<name>], morca #267): the
        # Hetzner token is a secret file, only its id is here; the machines
        # get the stack's firewall and SSH key unless POOL_FIREWALL and
        # POOL_SSH_KEYS say otherwise. The registry login lets a booting
        # machine pull the image (morca-stack copies ghcr-token among the
        # secrets for it).
        if has_secret secrets/orca/hcloud-token; then
            echo "MORCA_HCLOUD_TOKEN_SECRET=orca/hcloud-token"
            echo "MORCA_HCLOUD_FIREWALL=${POOL_FIREWALL:-$NAME}"
            echo "MORCA_HCLOUD_SSH_KEYS=${POOL_SSH_KEYS:-$NAME}"
        fi
        if [ -n "${GHCR_USER:-}" ] && has_secret ghcr-token; then
            echo "MORCA_REGISTRY_USER=$GHCR_USER"
            echo "MORCA_REGISTRY_TOKEN_SECRET=orca/ghcr-token"
        fi
        [ -z "${FIXED_COST:-}" ] || echo "MORCA_FIXED_COST=$FIXED_COST"
        [ -z "${POSTHOG_KEY:-}" ] || echo "MORCA_POSTHOG_KEY=$POSTHOG_KEY"
        # Where the UI's analytics go: a proxy such as /ph; PostHog's own without.
        [ -z "${POSTHOG_HOST:-}" ] || echo "MORCA_POSTHOG_HOST=$POSTHOG_HOST"
        # The stack's overlay on morca.toml (#332): sync_settings sends the
        # file, and the scheduler has it here (morca-stack's OVERLAY).
        [ -z "${CONFIG_OVERLAY_FILE:-}" ] || echo "MORCA_CONFIG_OVERLAY=/etc/orca/overlay/morca.overlay.toml"
        if [ -n "${EXTRA_ENV_FILE:-}" ] && [ -r "$EXTRA_ENV_FILE" ]; then cat "$EXTRA_ENV_FILE"; fi
    } > "$1"
}

# sync_file [--keys] NAME SRC: SRC becomes /etc/orca/NAME (mode 600) if it
# differs, over ssh's standard input (morca-stack sync, which prints what
# changed: with --keys the keys, never a value). A SOPS file (is_sops) is
# decrypted into a variable and piped, never written to a file here.
sync_file() {
    k=
    if [ "$1" = --keys ]; then
        k=--keys
        shift
    fi
    if [ "$DRY_RUN" = 1 ] && is_sops "$2"; then
        echo "+ sops -d $2 | ssh root@$IP morca-stack sync ${k:+$k }$1"
    elif [ "$DRY_RUN" = 1 ]; then
        echo "+ ssh root@$IP morca-stack sync ${k:+$k }$1 < $2"
    elif is_sops "$2"; then
        plain=$(sops -d "$2") || {
            plain=
            echo "sops couldn't decrypt $2" >&2
            return 1
        }
        printf '%s\n' "$plain" | remote morca-stack sync ${k:+"$k"} "$1"
        st=$?
        plain=
        return "$st"
    else
        remote morca-stack sync ${k:+"$k"} "$1" < "$2"
    fi
}

# sync_settings DIR: brings the server's settings in line with hetzner.env,
# as up.sh made them: settings.env, the secret files, the overlay, the stack settings
# (morca-stack configure; not MORCA_TAG, which deploy.sh moves) and the apps.
# Each prints what it changes, keys and file names only (a stack setting
# old -> new: none is a secret). DIR is a local temporary directory. The
# server's morca-stack must be this checkout's (it has sync). Returns
# non-zero at the first step that fails. SECRETS_JSON is cleared after it.
sync_settings() {
    sync_settings_ "$@"
    st=$?
    clear_secrets
    return "$st"
}

sync_settings_() {
    load_secrets
    write_settings "$1/settings.env" || return 1
    if [ "$DRY_RUN" = 1 ]; then
        echo "# settings.env from $HETZNER_ENV: $(sed -n 's/=.*//p' "$1/settings.env" | tr '\n' ' ')"
    fi
    sync_file --keys settings.env "$1/settings.env" || return 1
    [ "$DRY_RUN" = 0 ] || [ -z "$SECRETS_KEYS" ] || echo "+ sops -d $SECRETS_FILE (once)"
    for name in $SECRET_NAMES; do
        if in_secrets "$name"; then
            sync_secret "$name" || return 1
            continue
        fi
        v=$(secret_var "$name")
        eval "val=\${$v:-}"
        [ -n "$val" ] || continue
        # A ghcr-token file is only sent with GHCR_USER, as before.
        [ "$name" != ghcr-token ] || [ -n "${GHCR_USER:-}" ] || continue
        sync_file "$name" "$val" || return 1
    done
    # The apps' secrets: SECRETS_FILE's other secrets/orca/<id> keys.
    for name in $SECRETS_KEYS; do
        case " $SECRET_NAMES " in *" $name "*) continue ;; esac
        sync_secret "$name" || return 1
    done
    # The overlay, or none: one taken out of hetzner.env is removed.
    if [ -n "${CONFIG_OVERLAY_FILE:-}" ]; then
        sync_file overlay/morca.overlay.toml "$CONFIG_OVERLAY_FILE" || return 1
    else
        remote morca-stack sync --remove overlay/morca.overlay.toml || return 1
    fi
    # GHCR_USER= (none in hetzner.env) removes it from stack.conf.
    remote morca-stack configure MORCA_IMAGE="$MORCA_IMAGE" CLOUDFLARED_IMAGE="$CLOUDFLARED_IMAGE" \
        BUCKET="$BUCKET" BACKUP_KEEP="$BACKUP_KEEP" GHCR_USER="${GHCR_USER:-}" \
        OVERLAP="$OVERLAP" DRAIN_SECONDS="$DRAIN_SECONDS" || return 1
    # APPS=console names an app; console:8080 also gives its port, for an
    # app whose morca.toml has no [apps.console] port.
    for app in $APPS; do
        case $app in
            *:*) remote morca-stack app "${app%%:*}" "${app#*:}" || return 1 ;;
            *) remote morca-stack app "$app" || return 1 ;;
        esac
    done
}
