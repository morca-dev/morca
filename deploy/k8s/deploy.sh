#!/bin/sh
# deploy.sh [--dry-run] [--yes] [--force] [--no-backup] [--no-rollback] [--timeout SECONDS] [--confirmed ID,...] <tag>
# deploy.sh [--dry-run] [--yes] [--no-backup] --rollback
#
# Deploys the project's image at <tag> on Kubernetes (K8S.md#deploying), as
# deploy/hetzner/deploy.sh does on Hetzner (docs/hetzner.md#deploying-code):
# the scheduler, morca ui and the project's apps on the new image, the
# pipelines registered from its morca.toml, its upgrade steps done, backed
# up before and checked after, and rolled back to the tag before when the
# check fails. It needs kubectl, with the cluster as its current context.
#
# The settings are kube.env's (KUBE_ENV, default deploy/k8s/kube.env;
# kube.env.example says what each is): MORCA_IMAGE, the image's repository,
# and DRAIN_SECONDS are required; OVERLAP (1 unless 0),
# HANDOVER_WAIT_SECONDS (required once the image's morca.toml declares a
# concurrency key), MANIFESTS, EXTRA_ENV, CANARY, CANARY_TIMEOUT,
# HEALTH_TIMEOUT and PULL_SECRET aren't. The scheduler gets them from the
# ConfigMap morca-settings: MORCA_OVERLAP, MORCA_DRAIN_SECONDS and
# MORCA_HANDOVER_WAIT_SECONDS, and EXTRA_ENV's KEY=VALUE pairs.
#
# In order:
#
# 1. Checks the settings, before anything changes: DRAIN_SECONDS a whole
#    number of seconds above 0, HANDOVER_WAIT_SECONDS too when set, and set
#    when the new image's morca.toml declares a concurrency key (its
#    `morca config check`).
# 2. The release's upgrade steps (the new image's upgrade.toml, `morca
#    upgrade`), when the tag changes and not for a rollback: the "before"
#    ones, each done before anything changes (a command run in the
#    scheduler, an instruction confirmed: asked for, or named in
#    --confirmed id,...; with --yes an unconfirmed instruction stops it).
# 3. The plan: the scheduler is replaced when its image or its settings
#    change. Then, as on Hetzner, it overlaps or quiesces. On Kubernetes a
#    run is a Job, not the scheduler's process, so replacing the scheduler
#    (a Recreate: the old pod is stopped, then the new one starts) doesn't
#    stop it. The schedulers overlap (OVERLAP, on by default) when the new
#    image's `morca scheduler can-overlap` says yes: nothing is paused,
#    and the old image's runs go on, see that they're outdated once the new
#    code is registered (morca.outdated()) and end when their code decides,
#    a run waiting on their concurrency key starting on the new code once
#    they have (up to HANDOVER_WAIT_SECONDS). Otherwise (OVERLAP=0, a
#    migration that raises the floor past the old binary, no scheduler
#    leading with overlap on, a rollback) it pauses every pipeline that
#    isn't paused and waits for the running runs (up to --timeout, default
#    3600 s), and unpauses those it paused at the end. --force doesn't
#    pause, and the old image's runs go on over the new schema.
# 4. Backs up the database before anything is replaced: the CronJob
#    morca-backup (postgres-backup.yaml) as a Job of its own, waited for;
#    when that fails nothing is deployed (--no-backup deploys without one).
#    Not on a first deploy, which has nothing to back up.
# 5. Applies MANIFESTS (default morca.yaml, runs.yaml, postgres-backup.yaml
#    and ui.yaml, here), with their image morca:dev as MORCA_IMAGE:<tag>,
#    the ConfigMap morca-settings, and the apps, which the new image's
#    `morca config apps --kube` prints from its morca.toml; then waits for
#    the scheduler, the UI and the apps to roll out (HEALTH_TIMEOUT, 300).
# 6. When the scheduler was replaced, waits until the new one leads (`morca
#    scheduler wait-lead`) and registers the pipelines from the new image's
#    morca.toml (`morca register`, in it).
# 7. The "after" upgrade steps: each command asked about (run with --yes),
#    each instruction printed. A failed one fails the deploy at the end.
# 8. Unpauses the pipelines it paused, and records the tag deployed and the
#    one before it (the ConfigMap morca-deployed).
# 9. The check: Postgres answers; the scheduler, the UI and the apps rolled
#    out on the new image; one scheduler instance leads (with overlap on);
#    the pipelines registered, each one's binary in the scheduler's image;
#    and a run each of CANARY's PIPELINE=KEY, which must succeed within
#    CANARY_TIMEOUT (1800) seconds.
#
# When the rollout, the registration or the check fails, it rolls back to
# the tag deployed before (deploy.sh --rollback: no overlap, no upgrade
# steps), unless --no-rollback or there is none, and fails. --rollback does
# that by hand: the tag before, applied again the same way; a rollback
# again goes forward. --dry-run prints the plan and the commands that
# would change something, and changes nothing: it reads the cluster, but
# runs no pod of the new image, so it shows the longest way (no overlap)
# and lists no upgrade steps.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
NS=morca

die() {
    echo "deploy.sh: $*" >&2
    exit 1
}
log() { echo "deploy.sh $(date -u +%H:%M:%S): $*"; }

DRY_RUN=0
YES=0
force=
backup=1
autoroll=1
rollback=0
timeout=3600
confirmed=,
tag=
usage="usage: deploy.sh [--dry-run] [--yes] [--force] [--no-backup] [--no-rollback] [--timeout SECONDS] [--confirmed ID,...] <tag> | --rollback"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --yes | -y) YES=1 ;;
        --force) force=--force ;;
        --no-backup) backup=0 ;;
        --no-rollback) autoroll=0 ;;
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
        -*) die "unknown flag $1; $usage" ;;
        *)
            [ -z "$tag" ] || die "one tag; $usage"
            tag=$1
            ;;
    esac
    shift
done
case $timeout in "" | *[!0-9]*) die "--timeout needs a number of seconds, not '$timeout'" ;; esac
if [ "$rollback" = 1 ]; then
    [ -z "$tag" ] || die "--rollback takes no tag: it applies the one deployed before"
else
    [ -n "$tag" ] || die "$usage"
fi

# --- settings ------------------------------------------------------------------

KUBE_ENV=${KUBE_ENV:-$HERE/kube.env}
case $KUBE_ENV in */*) ;; *) KUBE_ENV=./$KUBE_ENV ;; esac
if [ -f "$KUBE_ENV" ]; then
    # shellcheck disable=SC1090
    . "$KUBE_ENV"
elif [ "$KUBE_ENV" != "$HERE/kube.env" ]; then
    die "no $KUBE_ENV (KUBE_ENV)"
fi
OVERLAP=${OVERLAP:-1}
MANIFESTS=${MANIFESTS:-"$HERE/morca.yaml $HERE/runs.yaml $HERE/postgres-backup.yaml $HERE/ui.yaml"}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-300}
CANARY_TIMEOUT=${CANARY_TIMEOUT:-1800}
command -v kubectl > /dev/null || die "needs kubectl"

safe() { # VALUE WHAT: letters, digits and ._:/@=- only
    case "$1" in
        "" | *[!A-Za-z0-9._:/@=-]*) die "$2: refusing '$1' (letters, digits and ._:/@=- only)" ;;
    esac
}
[ -n "${MORCA_IMAGE:-}" ] || die "MORCA_IMAGE isn't set ($KUBE_ENV): the project's image, without its tag (ghcr.io/morca-dev/census, say); nothing was changed"
safe "$MORCA_IMAGE" MORCA_IMAGE
[ -z "$tag" ] || safe "$tag" "the tag"
d_how="set DRAIN_SECONDS in $KUBE_ENV to how long, in seconds, an old scheduler may keep draining its runs after a deploy before it kills them (e.g. DRAIN_SECONDS=604800, a week; docs/hetzner.md#the-drain-limit); nothing was changed"
case ${DRAIN_SECONDS:-} in
    "") die "DRAIN_SECONDS isn't set: $d_how" ;;
    *[!0-9]*) die "DRAIN_SECONDS=$DRAIN_SECONDS isn't a whole number of seconds above 0: $d_how" ;;
esac
[ "$DRAIN_SECONDS" -gt 0 ] || die "DRAIN_SECONDS=$DRAIN_SECONDS isn't a whole number of seconds above 0: $d_how"
case ${HANDOVER_WAIT_SECONDS:-} in
    "") ;;
    *[!0-9]*) die "HANDOVER_WAIT_SECONDS=$HANDOVER_WAIT_SECONDS isn't a whole number of seconds above 0 ($KUBE_ENV); nothing was changed" ;;
    *) [ "$HANDOVER_WAIT_SECONDS" -gt 0 ] || die "HANDOVER_WAIT_SECONDS=$HANDOVER_WAIT_SECONDS isn't a whole number of seconds above 0 ($KUBE_ENV); nothing was changed" ;;
esac
for kv in ${EXTRA_ENV:-}; do
    case $kv in [A-Z_]*=*) ;; *) die "EXTRA_ENV: '$kv' isn't KEY=VALUE" ;; esac
done
for c in ${CANARY:-}; do
    case $c in ?*=?*) ;; *) die "CANARY: '$c' isn't PIPELINE=KEY" ;; esac
done
for f in $MANIFESTS; do [ -f "$f" ] || die "MANIFESTS: no $f"; done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/morca-kube.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- the cluster ------------------------------------------------------------------

k() { kubectl -n "$NS" "$@"; }

# change ARGS...: kubectl ARGS, a change; in a dry run printed instead.
change() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "+ kubectl -n $NS $*"
    else
        k "$@"
    fi
}

# rec KEY: the ConfigMap morca-deployed's KEY (tag, previous, paused), or empty.
rec() { k get configmap morca-deployed -o "jsonpath={.data.$1}" 2> /dev/null || true; }
# rec_set KEY VALUE
rec_set() {
    if ! k get configmap morca-deployed > /dev/null 2>&1; then
        if [ "$DRY_RUN" = 1 ]; then change create configmap morca-deployed; else change create configmap morca-deployed > /dev/null; fi
    fi
    if [ "$DRY_RUN" = 1 ]; then
        change patch configmap morca-deployed --type merge -p "{\"data\":{\"$1\":\"$2\"}}"
    else
        change patch configmap morca-deployed --type merge -p "{\"data\":{\"$1\":\"$2\"}}" > /dev/null
    fi
}

# image_of DEPLOYMENT CONTAINER: the image it's set to run, or empty.
image_of() {
    k get deployment "$1" -o "jsonpath={.spec.template.spec.containers[?(@.name==\"$2\")].image}" 2> /dev/null || true
}

# json_str VALUE: VALUE as a JSON string.
json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

pod_n=0
# in_pod IMAGE COMMAND...: COMMAND in a pod of its own of IMAGE in $NS,
# with the stack's settings and database (as the scheduler has them), waited
# for; prints its output (standard error on lines of its own after it) and
# returns its exit code. `$(MORCA_DATABASE_URL)` in COMMAND is the URL.
# In a dry run, prints what it would run and returns 3.
in_pod() {
    ip_image=$1
    shift
    if [ "$DRY_RUN" = 1 ]; then
        echo "+ a pod of $ip_image: $*" >&2
        return 3
    fi
    pod_n=$((pod_n + 1))
    ip_name=morca-deploy-$(date -u +%H%M%S)-$$-$pod_n
    ip_args=
    for a in sh -c '"$@" 2> /w/err; c=$?; sed "s/^/morca-deploy-stderr: /" /w/err; exit $c' sh "$@"; do
        ip_args="$ip_args${ip_args:+, }$(json_str "$a")"
    done
    {
        cat << EOF
apiVersion: v1
kind: Pod
metadata:
  name: $ip_name
  namespace: $NS
  labels: {morca.deploy: "1"}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
EOF
        [ -z "${PULL_SECRET:-}" ] || echo "  imagePullSecrets: [{name: $PULL_SECRET}]"
        cat << EOF
  volumes: [{name: w, emptyDir: {}}]
  containers:
    - name: c
      image: $ip_image
      imagePullPolicy: IfNotPresent
      command: [$ip_args]
      envFrom:
        - configMapRef: {name: morca-settings, optional: true}
        - configMapRef: {name: morca-lake, optional: true}
      env:
        - name: MORCA_DATABASE_URL
          valueFrom: {secretKeyRef: {name: morca-db, key: url, optional: true}}
        - {name: MORCA_IMAGE, value: "$ip_image"}
      volumeMounts: [{name: w, mountPath: /w}]
      resources:
        requests: {cpu: 50m, memory: 64Mi}
EOF
    } > "$tmp/pod.yaml"
    k apply -f "$tmp/pod.yaml" > /dev/null || return 1
    ip_t=0
    while :; do
        ip_phase=$(k get pod "$ip_name" -o 'jsonpath={.status.phase}' 2> /dev/null) || ip_phase=
        case $ip_phase in Succeeded | Failed) break ;; esac
        if [ "$ip_t" -ge "$HEALTH_TIMEOUT" ]; then
            ip_why=$(k get pod "$ip_name" -o 'jsonpath={.status.containerStatuses[0].state.waiting.reason}' 2> /dev/null) || ip_why=
            k delete pod "$ip_name" --wait=false > /dev/null 2>&1 || true
            echo "a pod of $ip_image didn't finish in ${HEALTH_TIMEOUT}s (${ip_why:-$ip_phase})" >&2
            return 1
        fi
        sleep 1
        ip_t=$((ip_t + 1))
    done
    ip_code=$(k get pod "$ip_name" -o 'jsonpath={.status.containerStatuses[0].state.terminated.exitCode}')
    k logs "$ip_name" > "$tmp/pod.out" 2>&1 || true
    k delete pod "$ip_name" --wait=false > /dev/null 2>&1 || true
    grep -v '^morca-deploy-stderr: ' "$tmp/pod.out" || true
    sed -n 's/^morca-deploy-stderr: //p' "$tmp/pod.out" >&2
    return "${ip_code:-1}"
}

# sched ARGS...: the running scheduler's morca ARGS.
sched() { k exec deploy/morca-scheduler -c scheduler -- morca "$@"; }

# psql_q SQL: Postgres's answer, through the StatefulSet postgres's psql, or
# for a database of your own a pod of postgres:17-bookworm with morca-db's URL.
psql_q() {
    if k get statefulset postgres > /dev/null 2>&1; then
        k exec statefulset/postgres -c postgres -- psql -U orca -d orca -Atc "$1"
    else
        in_pod postgres:17-bookworm psql '$(MORCA_DATABASE_URL)' -Atc "$1"
    fi
}

# The running runs: every run but those on remote workers, which talk to
# the UI and go on through anything this does.
HERE_RUNS="status = 'running' AND coalesce(placement, '') NOT LIKE 'worker:%'"
running_runs() { psql_q "SELECT count(*) FROM orca.runs WHERE $HERE_RUNS" 2> /dev/null || echo 0; }

# --- what is deployed, and what to ---------------------------------------------

was=
if kubectl get namespace "$NS" > /dev/null 2>&1; then
    was=$(rec tag)
fi
cur=$(image_of morca-scheduler scheduler)
if [ "$rollback" = 1 ]; then
    tag=$(rec previous)
    [ -n "$tag" ] || die "nothing to roll back to: no earlier deploy is recorded (the ConfigMap morca-deployed)"
fi
IMG=$MORCA_IMAGE:$tag
log "previous tag ${was:-none}, new tag $tag ($IMG)"

# The settings the scheduler gets, and their hash, which its pod template
# carries: a change replaces it.
{
    if [ "$OVERLAP" = 0 ]; then echo MORCA_OVERLAP=off; else echo MORCA_OVERLAP=on; fi
    echo "MORCA_DRAIN_SECONDS=$DRAIN_SECONDS"
    [ -z "${HANDOVER_WAIT_SECONDS:-}" ] || echo "MORCA_HANDOVER_WAIT_SECONDS=$HANDOVER_WAIT_SECONDS"
    for kv in ${EXTRA_ENV:-}; do echo "$kv"; done
} > "$tmp/settings.env"
hash=$(cksum < "$tmp/settings.env" | awk '{print $1}')
cur_hash=$(k get deployment morca-scheduler -o 'jsonpath={.spec.template.metadata.annotations.morca\.dev/settings}' 2> /dev/null || true)

# Pods of the new image need the namespace (a first deploy has none).
if [ "$DRY_RUN" = 0 ] && ! kubectl get namespace "$NS" > /dev/null 2>&1; then
    kubectl create namespace "$NS" > /dev/null
    # Its service account, which a pod needs, comes a moment later.
    n=0
    until k get serviceaccount default > /dev/null 2>&1; do
        n=$((n + 1))
        [ "$n" -lt 30 ] || die "the namespace $NS has no service account default after 30s"
        sleep 1
    done
fi

# A concurrency key needs the handover wait limit (#397), before anything
# changes. An image whose morca can't say (its config check fails) needs
# nothing here: its scheduler says so.
if [ -z "${HANDOVER_WAIT_SECONDS:-}" ]; then
    if out=$(in_pod "$IMG" morca config check 2> /dev/null); then
        keys=$(echo "$out" | sed -n 's/^morca: concurrency keys: \(.*\); the scheduler needs.*/\1/p')
        [ -z "$keys" ] || die "$IMG's morca.toml declares concurrency keys ($keys), and HANDOVER_WAIT_SECONDS isn't set: set it in $KUBE_ENV, how long, in seconds, a run waiting on a key may wait for a run of an older version to end before it fails, and deploy again (docs/hetzner.md#the-handover-wait-limit); nothing was deployed"
    fi
fi

# --- the release's upgrade steps (morca#323) -----------------------------------

from=${was:-none}
steps=0
[ "$rollback" = 0 ] && [ "$from" != "$tag" ] && steps=1

ask() {
    printf '%s [y/N] ' "$1" >&2
    read -r answer
    case "$answer" in y | Y | yes) return 0 ;; *) return 1 ;; esac
}

# upgrade_steps WHEN: the new image's steps for a deploy from $from, each
# command once (merge_steps); none for a tag that isn't a version, an image
# whose morca has no `morca upgrade` (exit 2), or a dry run.
upgrade_steps() {
    case "$tag" in v[0-9]*.* | [0-9]*.*) ;; *) return 0 ;; esac
    rc=0
    out_=$(in_pod "$IMG" morca upgrade --from "$from" --to "$tag" --when "$1") || rc=$?
    case $rc in
        0) ;;
        2 | 3) return 0 ;;
        *) echo "$out_" >&2; return 1 ;;
    esac
    printf '%s\n' "$out_" | grep '^step	' | merge_steps || true
}

# merge_steps: step lines with each run command (trimmed) once, where it
# last comes, its id the ids of all that asked for it (#343), as
# deploy/hetzner/deploy.sh merges them.
merge_steps() {
    awk -F '\t' -v OFS='\t' '
        { l[NR] = $0; k[NR] = $4; t = $5; gsub(/^ +| +$/, "", t); c[NR] = $3 OFS t
          if ($4 == "run") { last[c[NR]] = NR; if (c[NR] in ids) ids[c[NR]] = ids[c[NR]] "," $2; else ids[c[NR]] = $2 } }
        END { for (i = 1; i <= NR; i++) {
            if (k[i] != "run") print l[i]
            else if (last[c[i]] == i) { split(c[i], p, OFS); print "step", ids[c[i]], p[1], "run", p[2] }
        } }'
}

confirmed_all() {
    for i_ in $(echo "$1" | tr , ' '); do
        case "$confirmed" in *",$i_,"*) ;; *) return 1 ;; esac
    done
}

# step_run COMMAND...: an upgrade step's morca command, in the running
# scheduler, or with none (a first deploy) in a pod of the new image.
step_run() {
    [ "${1:-}" = morca ] || { echo "deploy.sh: upgrade steps run morca commands only" >&2; return 1; }
    for a in "$@"; do
        case "$a" in "" | *[!A-Za-z0-9._:/@=,+-]*) echo "deploy.sh: refusing the argument '$a'" >&2; return 1 ;; esac
    done
    shift
    if [ -n "$(image_of morca-scheduler scheduler)" ]; then
        sched "$@" < /dev/null
    else
        in_pod "$IMG" morca "$@"
    fi
}

tab=$(printf '\t')
if [ "$steps" = 1 ]; then
    before=$(upgrade_steps before) || die "reading $tag's upgrade steps failed; nothing was deployed"
    if [ -n "$before" ]; then
        log "before deploying $tag:"
        echo "$before" | while IFS="$tab" read -r _ id _ kind text; do
            echo "  [$id] $text"
        done
        while IFS="$tab" read -r _ id _ kind text; do
            if confirmed_all "$id"; then log "[$id] confirmed (--confirmed)"; continue; fi
            if [ "$kind" = run ]; then
                if [ "$YES" = 1 ] || ask "run '$text' now?" < /dev/tty; then
                    # shellcheck disable=SC2086
                    step_run $text || die "[$id] '$text' failed; nothing was deployed"
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

# --- the plan ------------------------------------------------------------------

scheduler=1
first=0
if [ -z "$cur" ]; then
    first=1
    plan="scheduler new $IMG"
elif [ "$cur" != "$IMG" ]; then
    plan="scheduler replace image $cur -> $IMG"
elif [ "$cur_hash" != "$hash" ]; then
    plan="scheduler replace settings: morca-settings changed"
else
    scheduler=0
    plan="scheduler keep unchanged"
fi
ui=$(image_of morca-ui ui)
if [ "$ui" = "$IMG" ]; then
    plan="$plan
ui keep unchanged"
else
    plan="$plan
ui replace image ${ui:-none} -> $IMG"
fi
plan="$plan
apps from $IMG's morca.toml (morca config apps --kube)"
log "the plan:"
echo "$plan" | sed 's/^/  /'
replaces=0
! echo "$plan" | grep -Eq '^[^ ]* (replace|new)' || replaces=1

quiesced=0
overlap=0
if [ "$scheduler" = 1 ] && [ "$first" = 0 ] && [ "$rollback" = 0 ] && [ -z "$force" ] && [ "$DRY_RUN" = 0 ]; then
    if [ "$OVERLAP" = 0 ]; then
        log "not overlapping the schedulers: OVERLAP=0 in $KUBE_ENV"
    elif why=$(in_pod "$IMG" morca scheduler can-overlap 2>&1); then
        overlap=1
    else
        log "not overlapping the schedulers: $(echo "$why" | tail -n 1 | sed 's/^no: //')"
    fi
fi
if [ "$scheduler" = 0 ]; then
    log "the scheduler keeps running: not pausing anything, runs go on"
elif [ "$first" = 1 ]; then
    log "a first deploy: nothing runs yet"
elif [ "$overlap" = 1 ]; then
    log "the new scheduler takes over from the old one, whose runs go on and hand over: not pausing anything"
elif [ -n "$force" ]; then
    log "--force: not pausing; the old image's runs go on"
else
    log "the scheduler is replaced without overlapping: pausing the pipelines and waiting for running runs (up to ${timeout}s)"
    paused=$(rec paused)
    for p in $(psql_q "SELECT name FROM orca.pipelines WHERE NOT paused ORDER BY name" 2> /dev/null); do
        if [ "$DRY_RUN" = 1 ]; then
            echo "+ kubectl -n $NS exec deploy/morca-scheduler -c scheduler -- morca pause $p"
            continue
        fi
        sched pause "$p" > /dev/null || die "pausing $p failed; not deployed (deploy.sh unpauses what it paused once a deploy goes through)"
        paused="$paused $p"
        rec_set paused "$(echo $paused)"
        echo "deploy.sh: paused $p"
    done
    quiesced=1
    t=0
    while [ "$DRY_RUN" = 0 ] && [ "$(running_runs)" -gt 0 ]; do
        if [ $((t % 60)) -eq 0 ]; then
            echo "deploy.sh: waiting for $(running_runs) running run(s):"
            psql_q "SELECT '  run ' || id || ' ' || pipeline || ' ' || partitions || ', running ' || date_trunc('second', now() - started) FROM orca.runs WHERE $HERE_RUNS ORDER BY id" 2> /dev/null || true
        fi
        [ "$t" -lt "$timeout" ] || die "$(running_runs) run(s) still running after ${timeout}s; not deployed, and the pipelines it paused stay paused (morca unpause <pipeline>, or deploy again)"
        sleep 10
        t=$((t + 10))
    done
fi
if [ "$quiesced" = 1 ]; then
    left="the pipelines it paused stay paused ($(rec paused)); fix it and deploy again, which unpauses them"
else
    left="nothing was paused"
fi

# --- the backup ----------------------------------------------------------------

dump=
if [ "$replaces" = 0 ]; then
    log "nothing to replace: not backing up"
elif [ "$backup" = 0 ]; then
    log "--no-backup: not backing up"
elif [ "$first" = 1 ] || ! k get cronjob morca-backup > /dev/null 2>&1; then
    log "nothing deployed before (no CronJob morca-backup): not backing up"
else
    job=morca-backup-deploy-$(date -u +%Y%m%dt%H%M%Sz)
    log "backing up the database (Job $job, from the CronJob morca-backup)"
    if [ "$DRY_RUN" = 1 ]; then
        change create job "$job" --from=cronjob/morca-backup
    else
        k create job "$job" --from=cronjob/morca-backup > /dev/null || die "making the backup Job failed, so nothing was deployed; $left"
    fi
    t=0
    while [ "$DRY_RUN" = 0 ]; do
        [ "$(k get job "$job" -o 'jsonpath={.status.succeeded}' 2> /dev/null)" != 1 ] || break
        if [ -n "$(k get job "$job" -o 'jsonpath={.status.failed}' 2> /dev/null)" ] || [ "$t" -ge 600 ]; then
            k logs "job/$job" --all-containers 2>&1 | tail -n 5 >&2 || true
            die "the backup failed (kubectl -n $NS logs job/$job --all-containers), so nothing was deployed (--no-backup deploys without one); $left"
        fi
        sleep 2
        t=$((t + 2))
    done
    if [ "$DRY_RUN" = 0 ]; then
        dump=$(k logs "job/$job" -c report 2> /dev/null | sed -n 's/^morca-backup: backed up to //p' | tail -n 1)
        k delete job "$job" --wait=false > /dev/null 2>&1 || true
    fi
    log "previous tag ${was:-none}, new tag $tag; backup ${dump:-(in the dry run, none)}"
fi

# --- the apply -----------------------------------------------------------------

# rollback_now WHY: rolls back to the tag before (when there's one and
# --no-rollback isn't given), then fails saying WHY and how that went.
rollback_now() {
    if [ "$rollback" = 1 ] || [ "$autoroll" = 0 ] || [ -z "$was" ] || [ "$was" = "$tag" ] || [ "$DRY_RUN" = 1 ]; then
        die "$1; not rolled back${dump:+ (backup before it: $dump)}: deploy.sh --rollback goes back"
    fi
    log "$1: rolling back to $was"
    if KUBE_ENV=$KUBE_ENV sh "$0" --rollback --yes --no-backup; then
        die "$1, so it rolled back to $was, which is deployed and checked${dump:+ (backup before it: $dump)}"
    fi
    die "$1, and rolling back to $was failed too (above)${dump:+; backup before it: $dump}"
}

log "deploying $tag"
k create configmap morca-settings --from-env-file="$tmp/settings.env" --dry-run=client -o yaml > "$tmp/settings.yaml"
for f in $MANIFESTS; do
    cat "$f"
    printf '\n---\n'
done | sed -e "s|morca:dev|$IMG|g" -e "s|morca.dev/settings: none|morca.dev/settings: \"$hash\"|" > "$tmp/stack.yaml"
if [ "$DRY_RUN" = 1 ]; then
    echo "+ kubectl apply -f - (the ConfigMap morca-settings: $(sed 's/=.*//' "$tmp/settings.env" | tr '\n' ' '))"
    echo "+ kubectl apply -f - ($(echo $MANIFESTS), with $IMG)"
else
    # The settings first, so the new scheduler starts with them.
    kubectl apply -f "$tmp/settings.yaml" > /dev/null || die "applying morca-settings failed; $left"
    kubectl apply -f "$tmp/stack.yaml" > "$tmp/applied" 2>&1 || { cat "$tmp/applied" >&2; die "applying the manifests failed; $left"; }
    sed 's/^/  /' "$tmp/applied"
fi
# What's deployed now, and before it: a rollback goes to the one before,
# and a rollback again forward.
if [ "$was" != "$tag" ]; then
    rec_set previous "$was"
    rec_set tag "$tag"
fi
# The apps, as the new image's morca.toml declares them.
apps=
bytes=$(kubectl get nodes -o 'jsonpath={range .items[*].status.images[*]}{.sizeBytes} {.names}{"\n"}{end}' 2> /dev/null \
    | grep -F -e "\"$IMG\"" -e "\"docker.io/library/$IMG\"" | awk '{print $1}' | head -n 1) || bytes=
if in_pod "$IMG" morca config apps --kube --image "$IMG" ${bytes:+--image-bytes "$bytes"} ${PULL_SECRET:+--pull-secret "$PULL_SECRET"} > "$tmp/apps.yaml"; then
    if [ -s "$tmp/apps.yaml" ]; then
        kubectl apply -f "$tmp/apps.yaml" -o name > "$tmp/apps.applied" 2>&1 || { cat "$tmp/apps.applied" >&2; rollback_now "applying the apps failed"; }
        sed 's/^/  applied /' "$tmp/apps.applied"
        apps=$(sed -n 's|^deployment.apps/||p' "$tmp/apps.applied")
    fi
elif [ "$DRY_RUN" = 1 ]; then
    echo "+ kubectl apply -f - (the apps: morca config apps --kube --image $IMG)"
else
    rollback_now "$IMG's morca config apps --kube failed (above)"
fi

if [ "$DRY_RUN" = 0 ]; then
    # Postgres (and MinIO) first: the scheduler waits on them.
    for st in $(k get statefulset -o name 2> /dev/null); do
        k rollout status "$st" --timeout="${HEALTH_TIMEOUT}s" > /dev/null 2>&1 \
            || rollback_now "$st didn't roll out within ${HEALTH_TIMEOUT}s (kubectl -n $NS describe $st)"
    done
    for d in morca-scheduler morca-ui $apps; do
        k rollout status "deployment/$d" --timeout="${HEALTH_TIMEOUT}s" > /dev/null 2>&1 \
            || rollback_now "deployment/$d didn't roll out within ${HEALTH_TIMEOUT}s (kubectl -n $NS describe deployment/$d)"
        log "deployment/$d rolled out"
    done
fi

# The pipelines are in the scheduler's image: registered again when it was
# replaced, once the new scheduler leads, so no old one starts new code.
if [ "$scheduler" = 1 ]; then
    log "registering the pipelines from $tag"
    if [ "$DRY_RUN" = 1 ]; then
        [ "$OVERLAP" = 0 ] || echo "+ kubectl -n $NS exec deploy/morca-scheduler -c scheduler -- morca scheduler wait-lead --timeout $HEALTH_TIMEOUT"
        echo "+ kubectl -n $NS exec deploy/morca-scheduler -c scheduler -- morca register"
    else
        if [ "$OVERLAP" != 0 ]; then
            sched scheduler wait-lead --timeout "$HEALTH_TIMEOUT" > /dev/null \
                || rollback_now "the new scheduler doesn't lead after ${HEALTH_TIMEOUT}s (kubectl -n $NS logs deploy/morca-scheduler)"
        fi
        n=0
        until out=$(sched register 2>&1); do
            n=$((n + 1))
            [ "$n" -lt 15 ] || { echo "$out" >&2; rollback_now "$tag is deployed, but registering failed"; }
            sleep 2
        done
        echo "$out" | sed 's/^/  /'
    fi
else
    log "the scheduler wasn't replaced: the pipelines stay registered as they are"
fi

# --- the after steps, the record, the check ------------------------------------

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
                if step_run $text; then
                    log "ran '$text' for $(echo "$id" | sed 's/,/, /g')"
                else
                    step_failed="$step_failed $(echo "$id" | tr , ' ')"
                fi
            else
                echo "  [$id] not run; run it later: kubectl -n $NS exec deploy/morca-scheduler -c scheduler -- $text"
            fi
        done << EOF
$after
EOF
    fi
fi

paused=$(rec paused)
if [ -n "$paused" ]; then
    log "unpausing the pipelines it paused: $paused"
    for p in $paused; do
        if [ "$DRY_RUN" = 1 ]; then
            echo "+ kubectl -n $NS exec deploy/morca-scheduler -c scheduler -- morca unpause $p"
            continue
        fi
        n=0
        until sched unpause "$p" > /dev/null 2>&1; do
            n=$((n + 1))
            [ "$n" -lt 30 ] || die "couldn't unpause $p; still paused: $paused"
            sleep 2
        done
        echo "deploy.sh: unpaused $p"
    done
    rec_set paused ""
fi

check_bad=0
check_ok() { echo "deploy.sh: check: ok    $*"; }
check_fail() {
    echo "deploy.sh: check: FAIL  $*"
    check_bad=$((check_bad + 1))
}

# canary_run PIPELINE KEY: a run of PIPELINE over KEY, ok if it succeeds
# within CANARY_TIMEOUT seconds.
canary_run() {
    c_out=$(sched start "$1" "$2" 2>&1) || {
        check_fail "canary $1 $2: morca start: $(echo "$c_out" | tail -n 1)"
        return 0
    }
    c_run=$(echo "$c_out" | sed -n 's/^queued run \([0-9][0-9]*\)$/\1/p' | tail -n 1)
    [ -n "$c_run" ] || {
        check_fail "canary $1 $2: morca start said: $(echo "$c_out" | tail -n 1)"
        return 0
    }
    c_t=0
    while :; do
        c_st=$(psql_q "SELECT status FROM orca.runs WHERE id = $c_run" 2> /dev/null) || c_st=
        case $c_st in
            succeeded)
                check_ok "canary $1 $2: run $c_run succeeded"
                return 0
                ;;
            failed | cancelled)
                check_fail "canary $1 $2: run $c_run $c_st (morca status $c_run)"
                return 0
                ;;
        esac
        [ "$c_t" -lt "$CANARY_TIMEOUT" ] || {
            check_fail "canary $1 $2: run $c_run still ${c_st:-unknown} after ${c_t}s (paused? morca status $c_run)"
            return 0
        }
        sleep 5
        c_t=$((c_t + 5))
    done
}

if [ "$DRY_RUN" = 1 ]; then
    log "the check (not in a dry run): Postgres, the Deployments on $IMG, one scheduler leading, the pipelines' binaries${CANARY:+, the canary runs $CANARY}"
    log "dry run: nothing was changed"
    exit 0
fi
log "checking the stack${CANARY:+ (canary runs: $CANARY)}"
if [ "$(psql_q 'SELECT 1' 2> /dev/null)" = 1 ]; then
    check_ok "postgres: answers"
else
    check_fail "postgres: doesn't answer"
fi
for d in morca-scheduler morca-ui $apps; do
    c=scheduler
    [ "$d" != morca-ui ] || c=ui
    if ! k rollout status "deployment/$d" --timeout=30s > /dev/null 2>&1; then
        check_fail "$d: not rolled out (kubectl -n $NS describe deployment/$d)"
    elif [ "$d" = morca-scheduler ] || [ "$d" = morca-ui ]; then
        img=$(image_of "$d" "$c")
        if [ "$img" = "$IMG" ]; then check_ok "$d: $img"; else check_fail "$d: runs $img, not $IMG"; fi
    else
        check_ok "$d: rolled out"
    fi
done
if [ "$OVERLAP" != 0 ]; then
    leaders=$(sched scheduler status 2> /dev/null | grep -c ' leading ' || true)
    if [ "$leaders" = 1 ]; then
        check_ok "scheduler instances: one leads"
    else
        check_fail "scheduler instances: ${leaders:-0} lead (morca scheduler status)"
    fi
fi
regs=$(psql_q "SELECT name || ' ' || coalesce(binary_path, '-') || ' ' || paused FROM orca.pipelines p WHERE to_jsonb(p)->>'retired' IS NULL ORDER BY name" 2> /dev/null) || regs=
n=0
missing=
paused=
for line in $(echo "$regs" | tr ' ' '|'); do
    pname=${line%%|*}
    rest=${line#*|}
    pbin=${rest%%|*}
    n=$((n + 1))
    [ "${rest#*|}" != t ] || paused="$paused $pname"
    if [ "$pbin" = - ]; then
        missing="$missing $pname (no binary)"
    elif ! k exec deploy/morca-scheduler -c scheduler -- test -x "$pbin" > /dev/null 2>&1; then
        missing="$missing $pname ($pbin)"
    fi
done
if [ "$n" = 0 ]; then
    check_fail "pipelines: none registered"
elif [ -n "$missing" ]; then
    check_fail "pipelines: not in the scheduler's image:$missing (morca retire <pipeline> for one it no longer has)"
else
    check_ok "pipelines: $n registered, each binary in the image; paused:${paused:- none}"
fi
for c in ${CANARY:-}; do
    canary_run "${c%%=*}" "${c#*=}"
done
[ "$check_bad" = 0 ] || rollback_now "$tag is deployed, but the check failed ($check_bad above)"
echo "deploy.sh: check: all ok"
[ -z "$step_failed" ] || die "$tag is deployed and checked, but upgrade steps failed:$step_failed (above); run them by hand: kubectl -n $NS exec deploy/morca-scheduler -c scheduler -- <the command>"
log "done: $tag${dump:+ (backup before it: $dump)}"
