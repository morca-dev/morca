#!/bin/sh
# promote.sh --from <dev settings> [--dry-run] [--yes] [deploy.sh's flags]
#
# Deploys to this stack (HETZNER_ENV's, production) the tags the dev stack
# (the settings file --from names) runs and checked: no rebuild, so what was
# tested is what ships (#250). It asks the dev stack's server for its last
# check (morca-stack checked) and refuses unless that check passed on the
# tags it runs now, then runs deploy.sh with those tags ("T", or "T
# console=U" when an app runs another) and the other flags given
# (--force, --all, --no-backup, --timeout S, --yes, --skip-tools-check).
# deploy.sh checks that these scripts are new enough for dev's image before
# it touches this stack's server (check_tools in lib.sh, #461).
#
# The dev stack's own per-laptop file (<its NAME>.local.env) is read as
# usual; HETZNER_LOCAL_ENV, if set, applies to both stacks.
# --dry-run asks the dev stack nothing and deploys "<dev's tags>".
set -eu
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

abs_path() { # FILE: FILE, from the current folder if it's relative
    case $1 in /*) echo "$1" ;; *) echo "$(pwd)/$1" ;; esac
}

from=
parse_common "$@"
# shellcheck disable=SC2086
set -- $REST
pass=
while [ $# -gt 0 ]; do
    case "$1" in
        --from)
            [ $# -ge 2 ] || die "--from needs the dev stack's settings file"
            from=$2
            shift
            ;;
        --timeout)
            [ $# -ge 2 ] || die "--timeout needs a number of seconds"
            pass="$pass --timeout $2"
            shift
            ;;
        --rollback) die "promote deploys dev's tags; to roll back, deploy.sh --rollback" ;;
        -*) pass="$pass $1" ;;
        *) die "promote takes no tags: it deploys the ones the dev stack checked" ;;
    esac
    shift
done
[ -n "$from" ] || die "usage: promote.sh --from <dev settings> [--dry-run] [--yes] [deploy.sh's flags]"
[ -f "$from" ] || die "no $from (--from)"
from=$(abs_path "$from")
target=$(abs_path "${HETZNER_ENV:-$HERE/hetzner.env}")
[ "$from" != "$target" ] || die "--from is this stack's own settings ($target): promote goes from dev to another stack"

# The dev stack's last check, in a subshell: its settings stay there.
if [ "$DRY_RUN" = 1 ]; then
    checked="ok <time> canary <dev's tags>"
else
    checked=$(
        HETZNER_ENV=$from
        load_env
        need_tool hcloud ssh
        IP=$(server_ip)
        now=$(remote morca-stack tags) || die "couldn't ask the dev stack ($NAME) what it runs"
        c=$(remote morca-stack checked) || die "the dev stack ($NAME) has no check: deploy there first (deploy.sh ends with morca-stack check)"
        set -- $c
        [ "$1" = ok ] || die "the dev stack's last check failed ($c): fix it there first"
        shift 3
        [ "$*" = "$now" ] || die "the dev stack runs $now, but its last check was of $*: deploy.sh or ssh root@$IP morca-stack check there first"
        echo "$c"
    ) || exit 1
fi
set -- $checked
when=$2
kind=$3
shift 3
tags="$*"
echo "promote.sh: dev checked $tags at $when ($kind)" >&2
[ "$kind" = canary ] || echo "promote.sh: warning: dev's check ran no canary (CANARY in its settings)" >&2

# "T" or "morca T, console U, ..." -> deploy.sh's arguments.
if [ "$DRY_RUN" = 1 ]; then
    dargs="<dev-tag>"
else
    case $tags in
        # "orca T, ..." from a dev stack still on orca-hetzner 0.24.x.
        "morca "* | "orca "*)
            dargs=$(echo "$tags" | sed 's/^m\{0,1\}orca //; s/, \([^ ,]*\) \([^ ,]*\)/ \1=\2/g')
            ;;
        *) dargs=$tags ;;
    esac
fi
[ "$DRY_RUN" = 0 ] || pass="$pass --dry-run"
[ "$YES" = 0 ] || pass="$pass --yes"
[ "$SKIP_TOOLS_CHECK" = 0 ] || pass="$pass --skip-tools-check"
echo "promote.sh: deploy.sh$pass $dargs (settings $target)" >&2
# shellcheck disable=SC2086
exec sh "$HERE/deploy.sh" $pass $dargs
