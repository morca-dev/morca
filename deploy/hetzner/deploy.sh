#!/bin/sh
# deploy.sh [--dry-run] [--force] [--all] [--no-backup] [--timeout SECONDS] [--yes] [--confirmed ID,...] [--skip-tools-check] <morca-tag> [<app>=<tag> ...]
# deploy.sh [--dry-run] [--force] [--no-backup] [--timeout SECONDS] [--yes] --rollback
#
# Code changes: pulls the images at the tags and starts again the containers
# whose image or settings changed (the scheduler, ui, sampler, apps and
# tunnel; the others keep running), as `morca aws app` and `morca aws up` did
# on AWS. The morca tag also becomes the default for the apps; an
# <app>=<tag> argument gives one app another. Postgres is not restarted.
# --all starts every container again, changed or not.
#
# Before anything changes on the server it checks hetzner.env: DRAIN_SECONDS
# is required (#390), a whole number of seconds above 0, how long an old
# scheduler may keep draining its runs after an overlapping deploy before it
# is stopped (docs/hetzner.md#the-drain-limit). Without it, or with 0 or a
# negative value, the deploy stops there, saying to set it.
#
# Then it brings the server's settings in line with hetzner.env, as up.sh
# writes them (sync_settings in lib.sh): settings.env, the secret files,
# the stack settings (OVERLAP, DRAIN_SECONDS, BACKUP_KEEP...) and the apps; not the tags, which are this script's.
# It prints what changed, settings.env's keys by name (added, removed,
# changed), never a value; a stack setting old -> new. A container whose
# env file this changes is then replaced ("replace settings: ..." in the
# plan), the scheduler's included, which quiesces as below. --rollback
# does it too: it rolls the tags back, not the settings, which are
# hetzner.env's (to undo a setting, change it there).
#
# It first asks the server what the apply would replace (morca-stack plan,
# one line per container) and goes on from that:
#
# - The scheduler is replaced (a new morca tag, or its settings changed):
#   restarting it kills running runs, so it quiesces first: pauses every
#   pipeline that isn't paused, waits for the running runs to end (up to
#   --timeout, default 3600 s), deploys, registers the pipelines from the
#   new image (morca-stack register) and unpauses the pipelines it paused.
#   Pipelines that were already paused (by hand or by the watchdog) stay
#   paused. On a timeout, a failed deploy or a failed registration the
#   pipelines stay paused, and the message says how to undo it. --force
#   skips the pause and kills the running runs. Only this path waits for
#   runs: it's taken when the schedulers can't overlap (OVERLAP=0 in
#   hetzner.env, a migration that raises the floor past the old binary, an
#   old scheduler without overlap, a rollback), and then the old
#   scheduler's restart would kill them (docs/overlap.md).
# - The scheduler is replaced and the stack overlaps schedulers (the
#   default; OVERLAP=0 in hetzner.env turns it off, docs/overlap.md), and
#   morca-stack can-overlap says the new image's scheduler may start beside
#   the old one (no migration of it raises the floor past the old binary):
#   nothing is paused and runs go on. The apply starts the new scheduler beside the old one and waits
#   until it leads; it registers the pipelines from the new image, asks the
#   old scheduler to drain (morca-stack drain-old) and returns: it doesn't
#   wait for the old scheduler's runs. They see that they're outdated
#   (morca.outdated()) and end when their code decides, or are killed once
#   DRAIN_SECONDS have passed (and queued again by the new scheduler); the
#   old scheduler then exits and is removed. Another deploy
#   meanwhile overlaps again, each old scheduler draining under its own
#   name (docs/overlap.md). A rollback, --force and a dry run don't overlap.
# - The scheduler keeps running (an app's tag only, say the census
#   console's): nothing is paused and runs go on; it backs up and applies,
#   and nothing needs registering (the pipelines are in the scheduler's
#   image, which didn't change).
# - Nothing is replaced: no backup, and the apply keeps every container.
#
# The UI and the apps are replaced without downtime (morca-stack starts the
# new one beside the old and waits until it's healthy). One that never is
# fails the deploy after the rest is applied, the old one still serving: a
# scheduler it replaced is registered first, the pipelines it paused are
# unpaused (the scheduler is deployed: nothing waits on the UI), and it
# exits non-zero naming what wasn't replaced; morca-stack apply on the
# server tries those again. The pipelines stay paused only when the
# scheduler itself, the registration or the backup failed.
#
# The quiesce waits only for the runs the scheduler's own processes hold: a
# run on a remote worker (placement worker:<pool>) goes on through the
# scheduler's restart, and is listed as left running on the workers.
#
# Before it applies anything that replaces a container it backs the
# database up (morca-stack backup-now, to s3://BUCKET/backups/pg/<time>.dump,
# with <time>.paused beside it: the pipelines paused by hand and the ones
# this deploy paused, so a restore of the dump unpauses only the latter) and
# stops if that fails, unless --no-backup. The server keeps the tags it ran
# before (morca-stack tags --previous); --rollback applies those again, the
# same way (docs/hetzner.md#rolling-back).
#
# When the morca tag changes (not for a rollback), the release's upgrade steps
# (docs/hetzner.md#a-releases-upgrade-steps, the new image's upgrade.toml):
# the "before" ones are listed first, before anything changes, and each must
# be done (a command run, an instruction confirmed: asked for, or named in
# --confirmed id,...; with --yes an unconfirmed instruction stops the deploy);
# the "after" ones run once the pipelines are registered, before they're
# unpaused (commands asked about, or run with --yes; instructions printed),
# and a failed one fails the deploy at the end, the rest deployed. A command
# several of the versions ask for runs once, for all their ids (#343).
#
# Before anything else, it checks that these scripts are new enough for
# the image (check_tools in lib.sh, #461): the image's dev.morca.hetzner-min
# label, read from the registry, names the oldest morca-hetzner that knows
# what its morca asks of the server, and an older one stops here, naming
# that version and where to get it. An image without the label has no
# minimum. Not for --rollback, whose tags these scripts deployed before;
# --skip-tools-check skips it.
#
# It ends with morca-stack check (docs/hetzner.md#the-check-after-each-deploy):
# the containers, one scheduler, the pipelines' binaries, and a canary run
# for each of hetzner.env's CANARY; when the check fails the deploy fails,
# with nothing undone.
set -eu
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

force=
timeout=3600
backup=1
dump=
rollback=0
all=
confirmed=,
parse_common "$@"
# shellcheck disable=SC2086
set -- $REST
args=
apps=
tag=
while [ $# -gt 0 ]; do
    case "$1" in
        --force) force=--force ;;
        --no-backup) backup=0 ;;
        --all) all=--all ;;
        --rollback) rollback=1 ;;
        --confirmed)
            [ $# -ge 2 ] || die "--confirmed needs step ids (a,b)"
            confirmed=",$2,"
            shift
            ;;
        --timeout)
            [ $# -ge 2 ] || die "--timeout needs a number of seconds"
            timeout=$2
            shift
            ;;
        -*) die "unknown flag $1" ;;
        *=*)
            args="$args --app $1"
            apps="$apps, ${1%%=*} ${1#*=}"
            ;;
        *)
            [ -z "$tag" ] || die "one morca tag, then app=tag arguments"
            tag=$1
            ;;
    esac
    shift
done
usage="usage: deploy.sh [--dry-run] [--force] [--all] [--no-backup] [--timeout SECONDS] [--confirmed ID,...] [--skip-tools-check] <morca-tag> [<app>=<tag> ...] | --rollback"
if [ "$rollback" = 1 ]; then
    [ -z "$tag" ] && [ -z "$args" ] || die "--rollback takes no tags: it applies the ones deployed before"
    [ -z "$all" ] || die "--rollback replaces what differs from the tags before; --all isn't for it"
else
    [ -n "$tag" ] || die "$usage"
fi

load_env
need_settings
need_tool hcloud ssh
[ "$rollback" = 1 ] || check_tools "$tag"
IP=$(server_ip)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/morca-hetzner.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
log() { echo "deploy.sh $(date -u +%H:%M:%S): $*"; }

# remote_out PLACEHOLDER ARGS...: the remote command's output, or in a dry run
# the command printed (to stderr) and the placeholder.
remote_out() {
    p=$1
    shift
    if [ "$DRY_RUN" = 1 ]; then
        echo "+ ssh root@$IP $*" >&2
        echo "$p"
    else
        remote "$@"
    fi
}

# The server's morca-stack from this checkout, so quiesce and resume match it.
put 755 /usr/local/sbin/morca-stack "$HERE/server/morca-stack"
# The backup timer runs it too. A server set up before the rename to morca
# (#384) has orca-stack, which reads ORCA_* keys morca-stack renames: remove it.
put 644 /etc/systemd/system/orca-backup.service "$HERE/server/orca-backup.service"
remote "systemctl daemon-reload && rm -f /usr/local/sbin/orca-stack"

# The server's settings as hetzner.env says, before the plan (which then
# replaces what they change).
log "the server's settings from $HETZNER_ENV (names only, never values):"
if sync_settings "$tmp" > "$tmp/synced" 2>&1; then synced=1; else synced=0; fi
if [ -s "$tmp/synced" ]; then sed 's/^/  /' "$tmp/synced"; else echo "  unchanged"; fi
[ "$synced" = 1 ] || die "setting the server's settings failed (above); nothing was deployed"
was=$(remote_out "<deployed>" morca-stack tags)
was=${was:-unknown}
if [ "$rollback" = 1 ]; then
    to=$(remote_out "<deployed before>" morca-stack tags --previous)
    [ -n "$to" ] || die "nothing to roll back to: the server has no earlier deploy recorded (one is kept from this deploy.sh on)"
else
    to=$tag
    [ -z "$apps" ] || to="morca $tag$apps"
fi
log "previous tag $was, new tag $to"

# The release's upgrade steps (morca#323): those of every version after the
# morca tag deployed before up to the new one, from the new image's
# upgrade.toml (morca-stack upgrade-steps). Not for a rollback, nor when the
# morca tag stays.
from=${was#morca }
from=${from#orca }
from=${from%%,*}
steps=0
[ "$rollback" = 0 ] && [ "$from" != "$tag" ] && steps=1

# ask QUESTION: yes for a typed y or yes.
ask() {
    printf '%s [y/N] ' "$1" >&2
    read -r answer
    case "$answer" in y | Y | yes) return 0 ;; *) return 1 ;; esac
}

# upgrade_steps WHEN: the steps' lines, an empty list in a dry run (which
# prints the command), each command once (merge_steps).
upgrade_steps() {
    out_=$(remote_out "" morca-stack upgrade-steps --tag "$tag" --from "$from" --when "$1") || return 1
    [ -z "$out_" ] || printf '%s\n' "$out_" | merge_steps
}

# merge_steps: step lines with each run command (trimmed) once, where it
# last comes, its id the ids of all that asked for it, comma-separated
# (#343). The new image's morca upgrade does this already; an older one's
# doesn't.
merge_steps() {
    awk -F '\t' -v OFS='\t' '
        { l[NR] = $0; k[NR] = $4; t = $5; gsub(/^ +| +$/, "", t); c[NR] = $3 OFS t
          # Not ids[x] = (x in ids) ? ...: mawk makes ids[x] before the test.
          if ($4 == "run") { last[c[NR]] = NR; if (c[NR] in ids) ids[c[NR]] = ids[c[NR]] "," $2; else ids[c[NR]] = $2 } }
        END { for (i = 1; i <= NR; i++) {
            if (k[i] != "run") print l[i]
            else if (last[c[i]] == i) { split(c[i], p, OFS); print "step", ids[c[i]], p[1], "run", p[2] }
        } }'
}

# confirmed_all IDS: every one of IDS (a,b) is in --confirmed.
confirmed_all() {
    for i_ in $(echo "$1" | tr , ' '); do
        case "$confirmed" in *",$i_,"*) ;; *) return 1 ;; esac
    done
}

tab=$(printf '\t')
if [ "$steps" = 1 ]; then
    before=$(upgrade_steps before) || die "reading $tag's upgrade steps failed; nothing was deployed"
    if [ -n "$before" ]; then
        log "before deploying $tag:"
        echo "$before" | while IFS="$tab" read -r _ id _ kind text; do
            echo "  [$id] $text"
        done
        # Each one done, or confirmed, before anything changes.
        while IFS="$tab" read -r _ id _ kind text; do
            if confirmed_all "$id"; then log "[$id] confirmed (--confirmed)"; continue; fi
            if [ "$kind" = run ]; then
                if [ "$YES" = 1 ] || ask "run '$text' now?" < /dev/tty; then
                    # shellcheck disable=SC2086
                    remote morca-stack upgrade-run $text < /dev/null || die "[$id] '$text' failed; nothing was deployed"
                    log "ran '$text' for $(echo "$id" | sed 's/,/, /g')"
                else
                    die "[$id] not run; nothing was deployed (run it, then deploy with --confirmed $id)"
                fi
            elif [ "$YES" = 1 ]; then
                die "[$id] needs doing before this deploy: $text. Do it, then deploy with --confirmed $id; nothing was deployed"
            else
                ask "[$id] done?" < /dev/tty || die "[$id] not done; nothing was deployed (do it, then deploy again, or with --confirmed $id)"
            fi
        done << EOF
$before
EOF
    fi
fi

# What the apply would replace. A dry run doesn't ask, and shows the
# longest way: the scheduler replaced.
if [ "$rollback" = 1 ]; then
    plan=$(remote_out "scheduler replace (a dry run assumes it)" morca-stack plan --rollback) \
        || die "morca-stack plan --rollback failed; nothing was deployed"
else
    # shellcheck disable=SC2086
    plan=$(remote_out "scheduler replace (a dry run assumes it)" morca-stack plan --tag "$tag" $args $all) \
        || die "morca-stack plan failed; nothing was deployed"
fi
log "the plan:"
echo "$plan" | sed 's/^/  /'
replaces=0
scheduler=0
! echo "$plan" | grep -q '^[^ ]* replace' || replaces=1
! echo "$plan" | grep -q '^scheduler replace' || scheduler=1

quiesced=0
overlap=0
if [ "$scheduler" = 1 ] && [ "$rollback" = 0 ] && [ -z "$force" ] && [ "$DRY_RUN" = 0 ]; then
    if why=$(remote morca-stack can-overlap --tag "$tag"); then
        overlap=1
    else
        log "not overlapping the schedulers: ${why#no: }"
    fi
fi
if [ "$scheduler" = 0 ]; then
    log "the scheduler keeps running: not pausing anything, runs go on"
elif [ "$overlap" = 1 ]; then
    log "the new scheduler starts beside the old one, which drains its runs: not pausing anything"
elif [ -n "$force" ]; then
    log "--force: not pausing; the scheduler is replaced, so running runs are killed"
else
    log "the scheduler is replaced: pausing the pipelines and waiting for running runs (up to ${timeout}s)"
    remote morca-stack quiesce --timeout "$timeout" \
        || die "not deployed; the pipelines it paused stay paused (ssh root@$IP morca-stack resume)"
    quiesced=1
fi
# What a failure leaves paused.
if [ "$quiesced" = 1 ]; then
    left="the pipelines stay paused (fix it and rerun, or ssh root@$IP morca-stack resume)"
else
    left="nothing was paused"
fi

# unhealthy_of OUTPUT: the containers apply's (or rollback's) closing
# "morca-stack: not replaced: NAME..." line names, the ones whose new
# container wasn't healthy, the old ones still serving; empty if none.
unhealthy_of() {
    echo "$1" | sed -n 's/^morca-stack: not replaced: *\(.*\), whose new container.*/\1/p' | tail -n 1
}

# finish_failed OUTPUT WHAT: the end of a failed apply or rollback, after the
# registration. Only a UI or an app not replaced: what this deploy paused
# runs again (the scheduler is deployed and registered), and it fails
# naming them. Anything else (the scheduler too): stays as it is.
finish_failed() {
    bad=$(unhealthy_of "$1")
    case " $bad " in
        "  " | *" scheduler "*) die "$2; $left" ;;
    esac
    if [ "$quiesced" = 1 ]; then
        log "only $bad wasn't replaced and the scheduler is deployed: unpausing the pipelines it paused"
        remote morca-stack resume \
            || die "not replaced: $bad; and unpausing failed, so some pipelines stay paused (ssh root@$IP morca-stack resume)"
    fi
    remote morca-stack status || true
    die "not replaced: $bad, whose new container wasn't healthy (above): the old one keeps serving, and the rest of $to is deployed${dump:+ (backup before it: $dump)}$([ "$quiesced" = 0 ] || echo ', the pipelines it paused running again'). Fix it, then ssh root@$IP morca-stack apply, which replaces only those"
}

if [ "$replaces" = 0 ]; then
    log "nothing to replace: not backing up"
elif [ "$backup" = 1 ]; then
    log "backing up the database"
    if ! out=$(remote_out "morca-stack: backed up to s3://<bucket>/backups/pg/<time>.dump" morca-stack backup-now 2>&1); then
        echo "$out" >&2
        [ "$quiesced" = 0 ] || remote morca-stack resume || true
        die "the backup failed, so nothing was deployed (--no-backup deploys without one)"
    fi
    dump=$(echo "$out" | sed -n 's/^morca-stack: backed up to //p')
    log "previous tag $was, new tag $to; backup ${dump:-$out}"
    echo "$out" | grep '^morca-stack: paused then' || true
else
    log "--no-backup: not backing up; previous tag $was, new tag $to"
fi

if [ "$rollback" = 1 ]; then
    log "rolling back to $to"
    # A UI or app that isn't healthy fails it after the registration.
    failed=0
    rolled=$(remote morca-stack rollback ${force:+"$force"} 2>&1) || failed=1
    echo "$rolled"
    [ "$failed" = 0 ] || finish_failed "$rolled" "the rollback failed"
else
    log "deploying $tag"
    # A new UI or app that isn't healthy fails the apply after the others
    # are applied: a scheduler it replaced is registered all the same, and
    # then finish_failed unpauses.
    failed=0
    # shellcheck disable=SC2086
    ov=
    [ "$overlap" = 0 ] || ov=--overlap
    # shellcheck disable=SC2086
    applied=$(remote morca-stack apply --tag "$tag" $args $all ${force:+"$force"} $ov 2>&1) || failed=1
    echo "$applied"
    if [ "$failed" = 1 ] && ! echo "$applied" | grep -q '^scheduler: replaced'; then
        finish_failed "$applied" "the deploy failed"
    fi
    # The pipelines are in the scheduler's image: registered again when it
    # was replaced.
    if echo "$applied" | grep -q '^scheduler: replaced' || { [ "$DRY_RUN" = 1 ] && [ "$scheduler" = 1 ]; }; then
        log "registering the pipelines from $tag"
        if [ "$quiesced" = 0 ]; then
            remote morca-stack register \
                || die "$tag is deployed, but registering failed (fix it, then ssh root@$IP morca-stack register)"
        else
            remote morca-stack register \
                || die "$tag is deployed, but registering failed; the pipelines stay paused (fix it, then ssh root@$IP morca-stack register and morca-stack resume; or ./deploy.sh --rollback)"
        fi
    else
        log "the scheduler wasn't replaced: the pipelines stay registered as they are"
    fi
    # The old scheduler drains in the background, for as long as its runs
    # take: not waited for (#397).
    if [ "$overlap" = 1 ] && echo "$applied" | grep -q '^scheduler: replaced'; then
        log "the old scheduler drains its runs in the background; not waiting for them"
        remote morca-stack drain-old \
            || die "$tag is deployed and registered, but asking the old scheduler to drain failed (ssh root@$IP morca-stack drain-old)"
    fi
    [ "$failed" = 0 ] || finish_failed "$applied" "the deploy failed"
fi
# The release's after steps, the pipelines registered and still paused (if
# this deploy paused them): a command is asked about (run with --yes), an
# instruction printed. A failed one is said at the end, after the rest.
step_failed=
if [ "$steps" = 1 ]; then
    after=$(upgrade_steps after) || { log "reading $tag's after steps failed: see morca upgrade in the image"; step_failed="(reading them)"; }
    if [ -n "$after" ]; then
        log "after deploying $tag:"
        while IFS="$tab" read -r _ id _ kind text; do
            if [ "$kind" = manual ]; then
                echo "  [$id] to do: $text"
                [ "$YES" = 1 ] || [ "$DRY_RUN" = 1 ] || {
                    printf '  press Enter once noted ' >&2
                    read -r _ < /dev/tty || true
                }
                continue
            fi
            if [ "$DRY_RUN" = 1 ]; then
                echo "  [$id] would run: $text"
            elif [ "$YES" = 1 ] || ask "[$id] run '$text' now?" < /dev/tty; then
                log "[$id] $text"
                # shellcheck disable=SC2086
                if remote morca-stack upgrade-run $text < /dev/null; then
                    log "ran '$text' for $(echo "$id" | sed 's/,/, /g')"
                else
                    step_failed="$step_failed $(echo "$id" | tr , ' ')"
                fi
            else
                echo "  [$id] not run; run it later: ssh root@$IP docker exec scheduler $text"
            fi
        done << EOF
$after
EOF
    fi
fi
if [ "$quiesced" = 1 ]; then
    log "unpausing the pipelines it paused"
    remote morca-stack resume
fi
remote morca-stack status
# The smoke check (morca-stack check): containers, one scheduler, the
# pipelines' binaries, and hetzner.env's CANARY runs. Nothing is undone when
# it fails: it says what's wrong, and --rollback is a command away.
log "checking the stack${CANARY:+ (canary runs: $CANARY)}"
# shellcheck disable=SC2046
remote morca-stack check $(check_args) \
    || die "$to is deployed, but the check failed (above)${dump:+; backup before it: $dump}; ./deploy.sh --rollback goes back"
[ -z "$step_failed" ] || die "$to is deployed and checked, but upgrade steps failed:$step_failed (above); run them by hand: ssh root@$IP docker exec scheduler <the command>"
log "done: $to${dump:+ (backup before it: $dump)}"
