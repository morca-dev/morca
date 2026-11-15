#!/bin/sh
# deploy/hetzner's deploys and rollbacks, against a fake server: ssh,
# hcloud and docker are tests/hetzner's fakes, and morca-stack runs here in
# its trial mode (MORCA_STACK_TEST=1) on directories of its own.
#
# - each apply that changes a tag keeps the tags before it (morca-stack tags
#   --previous, MORCA_PREV_TAG), including on a stack applied before it kept
#   them; applying the same tags again keeps the earlier ones;
# - deploy.sh backs up before it applies, says the previous and the new tag
#   and where the backup is, and stops before applying (unpausing what it
#   paused) when the backup fails, unless --no-backup;
# - deploy.sh --rollback (morca-stack rollback) applies the tags before
#   again, an app that followed the morca tag following it again, registers
#   the pipelines, and refuses with runs running unless --force; a second
#   rollback goes forward again;
# - a deploy registers the pipelines after the apply and before it unpauses,
#   and leaves them paused when that fails;
# - a backup's failed delete of an old dump only warns, and a failed upload
#   is tried three times;
# - each backup writes <time>.paused beside the dump: the pipelines paused
#   by hand (manual1) and the ones the deploy paused (toy); list-backups
#   says which dumps have one, and a restore unpauses only the ones the
#   deploy paused (a dump without one leaves them all paused);
# - apply starts again only the containers whose spec (image, env file,
#   flags, CGROUPS) changed, and says why; it refuses over running runs
#   only when the scheduler would be replaced; --only and --all; plan
#   changes nothing; Postgres is started once and never again;
# - run cgroups are on by default (#239): CGROUPS=0 drops the scheduler's
#   cgroup flags, a host without cgroup v2 or its memory controller runs it
#   without them, saying so, a failed remount doesn't stop the scheduler,
#   and with them on, apply warns for each pipeline whose peak is over its
#   memory_gb's maximum or what the host can grant;
# - deploy.sh (and --rollback) first brings the server's settings in line
#   with hetzner.env: a key added there reaches settings.env, one emptied is
#   removed, a secret file is rewritten (mode 600), a stack setting set,
#   each named and never its value; the plan then replaces the containers
#   whose env file changed and quiesces for the scheduler; the tags stay;
#   a dry run writes nothing;
# - deploy.sh pauses, waits and registers only when the plan replaces the
#   scheduler: a console-only deploy backs up and replaces the console and
#   nothing else, a deploy of what runs does nothing; an app-only rollback
#   goes on over running runs and registers nothing;
# - the UI and the apps are replaced without downtime: the new one starts as
#   NAME-next, is probed until healthy (the UI's /healthz, its worker
#   listener if MORCA_WORKER_ADDR is set, an app's check path), only then
#   gets the alias NAME and is probed again, and only then is the old one
#   stopped, removed and the new one renamed; a new one that isn't healthy (or exits) is removed and the
#   old one kept, apply goes on with the others and exits non-zero, and an
#   apply again replaces only it; deploy.sh still registers a scheduler it
#   replaced when the UI's replacement fails, then unpauses what it paused
#   and fails naming the UI (a rollback too); a scheduler that fails to
#   start leaves the pipelines paused;
# - quiesce, apply's refusal and status count only the runs the scheduler
#   holds: runs on remote workers aren't waited for, and are listed as left
#   running on the workers (quiesce --workers, rescale.sh's, waits for them);
# - with OVERLAP=1 and can-overlap saying yes, a deploy that replaces the
#   scheduler pauses nothing: the new scheduler starts beside the old one,
#   the old one is set not to restart and renamed scheduler-old-<time>, the
#   new one leads and registers, then the old one is asked to drain and the
#   deploy returns without waiting for its runs (#397): check and status
#   say it's draining N run(s), as information (status giving each
#   instance's image, morca.env's MORCA_IMAGE, #270), and a reaper removes it
#   once it exits. A second deploy while one drains overlaps again, its old
#   scheduler under a name of its own beside the first; drain-old
#   --timeout waits and stops one after it; can-overlap says no with
#   OVERLAP off, and the deploy that turns OVERLAP on pauses and waits as
#   before; an old scheduler or scheduler-next that isn't running (a
#   scheduler-old from before #397 too) is removed by the next apply,
#   saying so, and a deploy overlaps over it;
# - a stack's overlay (CONFIG_OVERLAY_FILE, #332) is sent beside
#   settings.env, which names it, checked by the image's morca before
#   anything changes (an image whose morca doesn't read overlays refused),
#   mounted in the scheduler only, whose replacement a change to it causes,
#   and removed when hetzner.env drops it;
# - an app's env file is what its [apps.NAME] in its image's morca.toml
#   asks for (#331): its env, the lake with lake = true, each secret from
#   secrets/orca/<id> (SECRETS_FILE may have any such key; never printed),
#   its port, check and memory; one missing secret, or APPS giving another
#   port, stops the deploy at the plan; an app not declared, or an image
#   without `morca config apps`, gets the fixed env of before;
# - package.sh's release tarball unpacks to morca-hetzner-<version>/ with
#   every script, server/ and the example settings, and its up.sh and
#   deploy.sh run from there (hetzner.env next to them), printing the
#   version and sending the tarball's own server files;
# - a shared hetzner.env (a secrets repository's) names its files relative
#   to its folder, and a laptop's <NAME>.local.env (or HETZNER_LOCAL_ENV)
#   is read after it, its relative names from its own folder; the first
#   line names both; a missing HETZNER_LOCAL_ENV, or one that sets NAME,
#   is refused;
# - upgrade steps: a command several versions ask for runs once, for all
#   their ids, and a failure fails them all (#343);
# - morca-stack check: ok on a healthy stack, and FAIL naming what's wrong (a
#   stopped container, an unhealthy UI, a scheduler-next left (a draining
#   old scheduler is information, and an exited one apply removes), a pipeline
#   whose binary isn't in the image (a retired one left out), none registered, a canary run that
#   failed or didn't end in time); checked keeps the result, kind and tags;
#   deploy.sh ends with it (hetzner.env's CANARY as --canary) and fails
#   when it fails;
# - promote.sh deploys the tags the dev stack checked, with the flags
#   given, and refuses when its last check failed, was of other tags, or
#   when --from is the target's own settings.
set -eu
cd "$(dirname "$0")/.."
FAKE=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/morca-hetzner.XXXXXX")" && pwd)
export FAKE
trap 'rm -rf "$FAKE"' EXIT INT TERM
export PATH="$PWD/tests/hetzner:$PATH"
export MORCA_STACK_TEST=1 MORCA_STACK_REGISTER_TRIES=1 MORCA_CONF="$FAKE/conf" MORCA_DATA="$FAKE/data" MORCA_STATE="$FAKE/state"
mkdir -p "$MORCA_CONF"
# The host: cgroup v2 with the memory controller, and 8 GB.
export MORCA_HOST_CGROUP="$FAKE/cgroup" MORCA_MEMINFO="$FAKE/meminfo"
mkdir -p "$MORCA_HOST_CGROUP"
echo "cpuset cpu io memory hugetlb pids rdma misc" > "$MORCA_HOST_CGROUP/cgroup.controllers"
echo "MemTotal:        8192000 kB" > "$MORCA_MEMINFO"
# The server's settings as up.sh writes them from hetzner.env (deploy.sh
# brings them in line with it; no tunnel: an empty tunnel.env).
cat > "$MORCA_CONF/settings.env" << 'EOS'
AWS_REGION=fsn1
AWS_ENDPOINT_URL_S3=https://example.invalid
MORCA_WAREHOUSE=s3://bkt/warehouse
MORCA_PUBLIC_WAREHOUSE=s3://bkt/warehouse
MORCA_LOGS=s3://bkt/logs
MORCA_RUN_ENV=MORCA_PUBLIC_WAREHOUSE
EOS
printf 'AWS_ACCESS_KEY_ID=x\nAWS_SECRET_ACCESS_KEY=y\n' > "$FAKE/s3.env"
cp "$FAKE/s3.env" "$MORCA_CONF/s3.env"
: > "$FAKE/tunnel.env"
cat > "$FAKE/hetzner.env" << EOS
NAME=morca
BUCKET=bkt
S3_ENDPOINT=https://example.invalid
S3_REGION=fsn1
S3_CREDENTIALS_FILE=$FAKE/s3.env
TUNNEL_TOKEN_FILE=$FAKE/tunnel.env
MORCA_IMAGE=img
EXTRA_ENV_FILE=$FAKE/extra.env
SSH_PRIVATE_KEY_FILE=
DRAIN_SECONDS=86400
EOS
: > "$FAKE/extra.env"
export HETZNER_ENV="$FAKE/hetzner.env"
XDG_STATE_HOME="$FAKE/xdg"
# No laptop's own settings (~/.config/morca-hetzner/<NAME>.local.env) but the tests'.
XDG_CONFIG_HOME="$FAKE/config"
export XDG_STATE_HOME XDG_CONFIG_HOME

fail() {
    echo "FAIL: $*"
    [ ! -f "$FAKE/out" ] || tail -20 "$FAKE/out"
    exit 1
}
stack() { sh deploy/hetzner/server/morca-stack "$@"; }
deploy() { sh deploy/hetzner/deploy.sh "$@" > "$FAKE/out" 2>&1; }
has() { grep -q -- "$1" "$FAKE/out" || fail "no '$1' in the output"; }
# add_setting KEY=VALUE: a line of hetzner.env's EXTRA_ENV_FILE, and the
# server's settings.env as a deploy would write it (for morca-stack apply).
add_setting() {
    echo "$1" >> "$FAKE/extra.env"
    echo "$1" >> "$MORCA_CONF/settings.env"
}

# A stack that ran before tags were kept: its conf says what runs.
stack configure MORCA_IMAGE=img MORCA_TAG=aaa1111 BUCKET=bkt
stack app console 8080
# The drain limit is required (#390): apply starts nothing without it, and
# configure takes only a whole number of seconds above 0 for it (and 0 or
# 1 for OVERLAP).
stack apply > "$FAKE/out" 2>&1 && fail "apply without DRAIN_SECONDS"
has "DRAIN_SECONDS isn't set in $MORCA_CONF/stack.conf: set it in hetzner.env"
[ -z "$(ls "$FAKE/containers" 2> /dev/null)" ] || fail "apply without DRAIN_SECONDS started $(ls "$FAKE/containers")"
for bad in DRAIN_SECONDS=0 DRAIN_SECONDS=-5 DRAIN_SECONDS=1.5 OVERLAP=2 OVERLAP=yes; do
    stack configure "$bad" > "$FAKE/out" 2>&1 && fail "configure $bad"
    grep -q "^${bad%%=*}=" "$MORCA_CONF/stack.conf" && fail "configure $bad wrote it"
done
stack configure DRAIN_SECONDS=86400 > /dev/null
stack apply > /dev/null
rm "$MORCA_CONF/deployed"
[ "$(stack tags)" = aaa1111 ] || fail "tags from the conf: $(stack tags)"
[ -z "$(stack tags --previous)" ] || fail "a previous deploy before any"
stack rollback > "$FAKE/out" 2>&1 && fail "a rollback with nothing before"
has "nothing to roll back to"

# deploy.sh refuses a missing, zero or negative DRAIN_SECONDS (#390) before
# it changes anything on the server: no morca-stack sent, stack.conf as it
# was, a message naming the setting.
cp "$MORCA_CONF/stack.conf" "$FAKE/stack.conf.before"
for d in missing empty 0 -5 1h; do
    case $d in
        missing) sed '/^DRAIN_SECONDS=/d' "$FAKE/hetzner.env" > "$FAKE/drain.env" ;;
        empty) sed 's/^DRAIN_SECONDS=.*/DRAIN_SECONDS=/' "$FAKE/hetzner.env" > "$FAKE/drain.env" ;;
        *) sed "s/^DRAIN_SECONDS=.*/DRAIN_SECONDS=$d/" "$FAKE/hetzner.env" > "$FAKE/drain.env" ;;
    esac
    HETZNER_ENV="$FAKE/drain.env" sh deploy/hetzner/deploy.sh bbb2222 > "$FAKE/out" 2>&1 && fail "deployed with DRAIN_SECONDS $d"
    case $d in
        missing | empty) has "deploy.sh: DRAIN_SECONDS isn't set: set DRAIN_SECONDS in $FAKE/drain.env to how long" ;;
        *) has "deploy.sh: DRAIN_SECONDS=$d isn't a whole number of seconds above 0: set DRAIN_SECONDS in" ;;
    esac
    has "nothing was changed on the server"
    [ ! -e "$FAKE/morca-stack" ] || fail "DRAIN_SECONDS $d: deploy.sh sent morca-stack first"
    cmp -s "$MORCA_CONF/stack.conf" "$FAKE/stack.conf.before" || fail "DRAIN_SECONDS $d: stack.conf changed"
    [ "$(stack tags)" = aaa1111 ] || fail "DRAIN_SECONDS $d: deployed $(stack tags)"
done
rm "$FAKE/drain.env" "$FAKE/stack.conf.before"

# A deploy: backup first, then apply; the tags before are kept.
: > "$FAKE/docker.log"
echo manual1 > "$FAKE/paused"
deploy bbb2222 || fail "deploy.sh bbb2222"
has "previous tag aaa1111, new tag bbb2222; backup s3://bkt/backups/pg/2"
grep -q 'pg_dump' "$FAKE/docker.log" || fail "no pg_dump"
[ "$(grep -n 'pg_dump\|run -d --name scheduler' "$FAKE/docker.log" | head -1 | grep -c pg_dump)" = 1 ] \
    || fail "the backup wasn't before the apply"
[ "$(stack tags)" = bbb2222 ] || fail "tags after the deploy: $(stack tags)"
[ "$(stack tags --previous)" = aaa1111 ] || fail "previous: $(stack tags --previous)"
grep -q '^MORCA_PREV_TAG=aaa1111$' "$MORCA_CONF/stack.conf" || fail "no MORCA_PREV_TAG"
grep -q 'unpause toy' "$FAKE/docker.log" || fail "the pipelines weren't unpaused"
grep -q 'unpause manual1' "$FAKE/docker.log" && fail "unpaused a pipeline paused by hand"
order=$(grep -o 'run -d --name scheduler\|exec scheduler morca register\|morca unpause toy' "$FAKE/docker.log" | tr '\n' ,)
[ "$order" = "run -d --name scheduler,exec scheduler morca register,morca unpause toy," ] \
    || fail "not apply, register, unpause: $order"
has "registering the pipelines from bbb2222"
# Its backup's paused state: manual1 by hand, toy by the deploy.
side=$(ls "$FAKE/bucket" | grep '\.paused$' | tail -n 1)
[ -n "$side" ] || fail "no .paused beside the dump: $(ls "$FAKE/bucket")"
[ -f "$FAKE/bucket/${side%.paused}.dump" ] || fail "$side has no dump"
grep -qx 'paused_by_hand manual1' "$FAKE/bucket/$side" || fail "by hand: $(cat "$FAKE/bucket/$side")"
grep -qx 'paused_by_deploy toy' "$FAKE/bucket/$side" || fail "by the deploy: $(cat "$FAKE/bucket/$side")"
has "paused then (in ${side}): by hand: manual1; by a deploy: toy"
dump=${side%.paused}.dump
stack list-backups > "$FAKE/out"
has "$dump   paused state recorded"

# Restoring that dump (whose toy is paused, as quiesce left it) unpauses toy
# only.
printf 'manual1\ntoy\n' > "$FAKE/paused"
stack restore --force "backups/pg/$dump" > "$FAKE/out" 2>&1 || fail "restore"
has "unpaused toy (a deploy had paused it)"
has "paused by hand or the watchdog, so still paused: manual1"
[ "$(cat "$FAKE/paused")" = manual1 ] || fail "paused after the restore: $(cat "$FAKE/paused")"
# Without its .paused, all stay paused.
rm "$FAKE/bucket/$side"
printf 'manual1\ntoy\n' > "$FAKE/paused"
stack restore --force latest > "$FAKE/out" 2>&1 || fail "restore latest"
has "has no ${side}: every pipeline paused in it stays paused"
[ "$(sort "$FAKE/paused" | tr '\n' ' ')" = "manual1 toy " ] || fail "unpaused without a .paused"
stack list-backups > "$FAKE/out"
has "$dump   no paused state"
echo manual1 > "$FAKE/paused"

# A deploy whose registration fails stops with the pipelines paused.
touch "$FAKE/register-fails"
deploy bbb2222 && fail "a deploy whose register failed"
has "bbb2222 is deployed, but registering failed; the pipelines stay paused"
grep -qx toy "$FAKE/paused" || fail "toy unpaused after a failed register"
rm "$FAKE/register-fails"
stack register > /dev/null || fail "morca-stack register"
stack resume > /dev/null || fail "morca-stack resume"
[ "$(cat "$FAKE/paused")" = manual1 ] || fail "paused after resume: $(cat "$FAKE/paused")"

# The same tags again keep the ones before.
stack apply --tag bbb2222 > /dev/null
[ "$(stack tags --previous)" = aaa1111 ] || fail "a re-apply moved previous: $(stack tags --previous)"

# A failed backup stops the deploy and unpauses; --no-backup goes on.
: > "$FAKE/docker.log"
touch "$FAKE/backup-fails"
deploy ccc3333 && fail "deployed after a failed backup"
has "the backup failed, so nothing was deployed"
grep -q 'run -d --name scheduler' "$FAKE/docker.log" && fail "applied after a failed backup"
grep -q 'unpause toy' "$FAKE/docker.log" || fail "left paused after a failed backup"
[ "$(stack tags)" = bbb2222 ] || fail "tags after a failed backup: $(stack tags)"
deploy --no-backup ccc3333 console=ddd4444 || fail "deploy.sh --no-backup"
has "no-backup: not backing up; previous tag bbb2222, new tag morca ccc3333, console ddd4444"
rm "$FAKE/backup-fails"
[ "$(stack tags)" = "morca ccc3333, console ddd4444" ] || fail "tags: $(stack tags)"

# A backup whose delete of an old dump fails still succeeds, and says so
# (#425); an upload that fails once is tried again.
cp "$MORCA_CONF/stack.conf" "$FAKE/stack.conf.before"
echo BACKUP_KEEP=1 >> "$MORCA_CONF/stack.conf"
sleep 1 # a stamp of its own
touch "$FAKE/bucket/20200101T000000Z.dump" "$FAKE/s3-rm-fails"
echo 1 > "$FAKE/s3-cp-fails"
stack backup-now > "$FAKE/out" 2>&1 || fail "a failed prune failed the backup: $(cat "$FAKE/out")"
has "warning: couldn't remove old dump 20200101T000000Z.dump: delete failed: .*THROUGHPUT_FAILURE"
has "the next backup tries again"
has "(try 1 of 3); trying again"
has "morca-stack: backed up to s3://bkt/backups/pg/"
[ -f "$FAKE/bucket/20200101T000000Z.dump" ] || fail "the old dump went"
# The next prune deletes it; an upload that keeps failing fails the backup.
rm "$FAKE/s3-rm-fails"
sleep 1
stack backup-now > "$FAKE/out" 2>&1 || fail "backup-now"
[ -f "$FAKE/bucket/20200101T000000Z.dump" ] && fail "the next prune kept the old dump"
[ "$(ls "$FAKE/bucket" | grep -c '\.dump$')" = 1 ] || fail "BACKUP_KEEP=1 kept $(ls "$FAKE/bucket")"
echo 3 > "$FAKE/s3-cp-fails"
sleep 1
stack backup-now > "$FAKE/out" 2>&1 && fail "a backup whose upload failed three times"
has "couldn't upload 2.*\.dump"
rm "$FAKE/s3-cp-fails"
mv "$FAKE/stack.conf.before" "$MORCA_CONF/stack.conf"

# Rolling back: refused with runs running, then the tags before, registered.
echo 2 > "$FAKE/running"
stack rollback > "$FAKE/out" 2>&1 && fail "rolled back over running runs"
has "2 run(s) running"
[ "$(stack tags)" = "morca ccc3333, console ddd4444" ] || fail "a refused rollback changed the tags"
echo 0 > "$FAKE/running"
: > "$FAKE/docker.log"
deploy --rollback || fail "deploy.sh --rollback"
has "previous tag morca ccc3333, console ddd4444, new tag bbb2222; backup s3://bkt/backups/pg/"
has "morca-stack: registered toy"
[ "$(stack tags)" = bbb2222 ] || fail "tags after the rollback: $(stack tags)"
grep -q '^console 8080 - /$' "$MORCA_CONF/apps" || fail "the console doesn't follow the morca tag: $(cat "$MORCA_CONF/apps")"
grep -q 'exec scheduler morca register' "$FAKE/docker.log" || fail "not registered"
[ "$(grep -n 'exec scheduler morca register\|unpause toy' "$FAKE/docker.log" | head -1 | grep -c register)" = 1 ] \
    || fail "unpaused before registering"

# Again goes forward; --force over running runs.
echo 1 > "$FAKE/running"
stack rollback --force > "$FAKE/out" 2>&1 || fail "morca-stack rollback --force"
[ "$(stack tags)" = "morca ccc3333, console ddd4444" ] || fail "tags after rolling forward: $(stack tags)"
echo 0 > "$FAKE/running"

# A failed registration fails the rollback, which says so.
touch "$FAKE/register-fails"
deploy --rollback && fail "a rollback whose register failed"
has "the rollback failed; the pipelines stay paused"
rm "$FAKE/register-fails"

# A dry run runs nothing on the server.
: > "$FAKE/docker.log"
sh deploy/hetzner/deploy.sh --dry-run --rollback > "$FAKE/out" 2>&1 || fail "a dry run"
has "+ ssh root@<server-ip> morca-stack rollback"
has "+ ssh root@<server-ip> morca-stack sync --keys settings.env"
[ ! -s "$FAKE/docker.log" ] || fail "a dry run ran docker"

# Only what changed starts again: each container has its spec as a label,
# and an apply that changes nothing replaces nothing.
stack resume > /dev/null
stack apply --tag eee5555 --app console=- > /dev/null || fail "apply eee5555"
grep -q '^orca.stack.spec=' "$FAKE/containers/scheduler/labels" || fail "no spec label"
: > "$FAKE/docker.log"
stack apply > "$FAKE/out" 2>&1 || fail "an apply of what runs"
for c in scheduler ui sampler console; do has "$c: unchanged"; done
grep -q 'run -d\|rm -f\|stop ' "$FAKE/docker.log" && fail "an unchanged apply started or stopped a container"

# Runs running: an apply that keeps the scheduler goes on; one that would
# replace it is refused and changes nothing.
echo 2 > "$FAKE/running"
: > "$FAKE/docker.log"
stack apply --app console=fff6666 > "$FAKE/out" 2>&1 || fail "a console-only apply with runs running"
has "console: replaced (image eee5555 -> fff6666)"
has "scheduler: unchanged"
grep -q 'run -d --name \(scheduler\|ui\|sampler\)' "$FAKE/docker.log" && fail "a console-only apply replaced more"
stack apply --tag ggg7777 > "$FAKE/out" 2>&1 && fail "replaced the scheduler over running runs"
has "2 run(s) running; restarting the scheduler (image eee5555 -> ggg7777) kills them"
[ "$(stack tags)" = "morca eee5555, console fff6666" ] || fail "a refused apply changed the tags: $(stack tags)"
grep -q '^MORCA_TAG=eee5555$' "$MORCA_CONF/stack.conf" || fail "a refused apply changed MORCA_TAG"
echo 0 > "$FAKE/running"

# plan says what apply would do, and changes nothing.
: > "$FAKE/docker.log"
stack plan --tag ggg7777 > "$FAKE/out" 2>&1 || fail "morca-stack plan"
has "^scheduler replace image eee5555 -> ggg7777$"
has "^console keep unchanged$"
grep -q 'run -d\|rm -f' "$FAKE/docker.log" && fail "plan started or removed a container"
[ "$(stack tags)" = "morca eee5555, console fff6666" ] || fail "plan changed the tags"

# A census-only deploy: no pause, a backup, the console replaced and
# nothing else, nothing registered.
: > "$FAKE/docker.log"
deploy eee5555 console=hhh8888 || fail "a console-only deploy"
has "  console replace image fff6666 -> hhh8888"
has "the scheduler keeps running: not pausing anything"
grep -q 'morca pause' "$FAKE/docker.log" && fail "a console-only deploy paused the pipelines"
grep -q pg_dump "$FAKE/docker.log" || fail "a console-only deploy didn't back up"
[ "$(grep -n 'pg_dump\|run -d --name console' "$FAKE/docker.log" | head -1 | grep -c pg_dump)" = 1 ] \
    || fail "the backup wasn't before the console's start"
grep -q 'run -d --name console' "$FAKE/docker.log" || fail "the console wasn't replaced"
grep -q 'run -d --name \(scheduler\|ui\|sampler\)' "$FAKE/docker.log" && fail "a console-only deploy replaced more"
grep -q 'morca register' "$FAKE/docker.log" && fail "a console-only deploy registered"
has "the scheduler wasn't replaced: the pipelines stay registered as they are"
[ "$(stack tags)" = "morca eee5555, console hhh8888" ] || fail "tags after a console deploy: $(stack tags)"

# A deploy of what runs: nothing replaced, no backup, no pause.
: > "$FAKE/docker.log"
deploy eee5555 console=hhh8888 || fail "a deploy of what runs"
has "nothing to replace: not backing up"
grep -q 'pg_dump\|run -d\|morca pause' "$FAKE/docker.log" && fail "a deploy of what runs did something"

# deploy.sh brings the server's settings in line with hetzner.env before
# it plans: a key added there (POSTHOG_KEY) reaches settings.env, by name
# only in the output, the containers whose env file it changes are
# replaced, and the scheduler's replacement quiesces.
mode() { ls -l "$1" | cut -c1-10; }
echo POSTHOG_KEY=phc_notavalue42 >> "$FAKE/hetzner.env"
: > "$FAKE/docker.log"
deploy eee5555 console=hhh8888 || fail "a deploy that adds POSTHOG_KEY"
has "  morca-stack: settings.env: added MORCA_POSTHOG_KEY$"
grep -q phc_notavalue42 "$FAKE/out" && fail "a setting's value was printed"
grep -qx 'MORCA_POSTHOG_KEY=phc_notavalue42' "$MORCA_CONF/settings.env" || fail "no MORCA_POSTHOG_KEY in settings.env"
[ "$(mode "$MORCA_CONF/settings.env")" = -rw------- ] || fail "settings.env is $(mode "$MORCA_CONF/settings.env")"
grep -qx 'POSTHOG_KEY=phc_notavalue42' "$MORCA_CONF/app-console.env" || fail "no POSTHOG_KEY in app-console.env"
has "  scheduler replace settings: its env file changed"
has "  ui replace settings: its env file changed"
has "  console replace settings: its env file changed"
has "  sampler keep unchanged"
has "the scheduler is replaced: pausing the pipelines"
grep -q 'exec scheduler morca pause' "$FAKE/docker.log" || fail "a settings change to the scheduler didn't quiesce"
grep -q 'exec scheduler morca register' "$FAKE/docker.log" || fail "not registered after a settings change"
grep -q 'unpause toy' "$FAKE/docker.log" || fail "not unpaused after a settings change"
[ "$(stack tags)" = "morca eee5555, console hhh8888" ] || fail "a settings change moved the tags: $(stack tags)"
# Nothing differs: nothing changes, nothing is replaced.
deploy eee5555 console=hhh8888 || fail "a deploy with the settings in line"
has "names only, never values):"
has "^  unchanged$"
has "nothing to replace: not backing up"
# The stack's overlay (#332): CONFIG_OVERLAY_FILE (relative to hetzner.env)
# is sent as overlay/morca.overlay.toml, settings.env names it, the image's
# morca checks it before anything changes, and the scheduler gets it
# mounted and is replaced, so it registers with it.
mkdir -p "$FAKE/dev"
printf '[pipelines.toy]\nfills = "since_registration"\n' > "$FAKE/dev/morca.overlay.toml"
echo CONFIG_OVERLAY_FILE=dev/morca.overlay.toml >> "$FAKE/hetzner.env"
: > "$FAKE/docker.log"
deploy eee5555 console=hhh8888 || fail "a deploy that adds the overlay"
has "  morca-stack: overlay/morca.overlay.toml: new"
has "  morca-stack: settings.env: added MORCA_CONFIG_OVERLAY"
has "morca-stack: the overlay: /opt/morca/morca.toml with /etc/orca/overlay/morca.overlay.toml: ok"
cmp -s "$FAKE/dev/morca.overlay.toml" "$MORCA_CONF/overlay/morca.overlay.toml" || fail "the overlay on the server differs"
grep -qx 'MORCA_CONFIG_OVERLAY=/etc/orca/overlay/morca.overlay.toml' "$MORCA_CONF/morca.env" || fail "no MORCA_CONFIG_OVERLAY in morca.env"
grep -q "^config-check run --rm --env-file $MORCA_CONF/settings.env -v $MORCA_CONF/overlay:/etc/orca/overlay:ro img:eee5555 config check" "$FAKE/docker.log" \
    || fail "the overlay wasn't checked in the image"
grep -q "run -d --name scheduler .*-v $MORCA_CONF/overlay:/etc/orca/overlay:ro" "$FAKE/docker.log" || fail "the scheduler hasn't the overlay"
grep -q "run -d --name ui-next .*/etc/orca/overlay" "$FAKE/docker.log" && fail "the UI has the overlay"
grep -q 'exec scheduler morca register' "$FAKE/docker.log" || fail "not registered with the overlay"
# Only the overlay changes: the scheduler is replaced, and registers.
printf '[pipelines.toy]\nfills = "all"\n' > "$FAKE/dev/morca.overlay.toml"
: > "$FAKE/docker.log"
deploy eee5555 console=hhh8888 || fail "a deploy that changes the overlay"
has "  morca-stack: overlay/morca.overlay.toml: changed"
has "  scheduler replace settings: its env file or the overlay changed"
has "  ui keep unchanged"
has "  console keep unchanged"
grep -q 'exec scheduler morca register' "$FAKE/docker.log" || fail "not registered after the overlay changed"
deploy eee5555 console=hhh8888 || fail "a deploy with the overlay in line"
has "nothing to replace: not backing up"
# One the image's morca refuses, or an image whose morca doesn't read
# overlays: the deploy stops at the plan, before anything is paused.
touch "$FAKE/overlay-bad"
printf '[pipelines.toyy]\nfills = "all"\n' > "$FAKE/dev/morca.overlay.toml"
: > "$FAKE/docker.log"
deploy eee5555 console=hhh8888 && fail "deployed with an overlay that doesn't check"
has "morca.toml with the stack's overlay doesn't check: .*isn't a pipeline of"
grep -q 'morca pause\|run -d' "$FAKE/docker.log" && fail "a refused overlay paused or started something"
rm "$FAKE/overlay-bad"
printf '[pipelines.toy]\nfills = "all"\n' > "$FAKE/dev/morca.overlay.toml"
touch "$FAKE/no-overlays"
deploy eee5555 console=hhh8888 && fail "deployed an image whose morca doesn't read overlays"
has "img:eee5555's morca doesn't read overlays"
rm "$FAKE/no-overlays"
# Taken out of hetzner.env: removed from the server, and the scheduler
# replaced without it.
sed -i.bak '/^CONFIG_OVERLAY_FILE=/d' "$FAKE/hetzner.env"
: > "$FAKE/docker.log"
deploy eee5555 console=hhh8888 || fail "a deploy that removes the overlay"
has "  morca-stack: overlay/morca.overlay.toml: removed"
has "  morca-stack: settings.env: removed MORCA_CONFIG_OVERLAY"
[ ! -f "$MORCA_CONF/overlay/morca.overlay.toml" ] || fail "the overlay is still on the server"
grep -q "run -d --name scheduler .*/etc/orca/overlay" "$FAKE/docker.log" && fail "the scheduler still has the overlay"
grep -q 'config-check' "$FAKE/docker.log" && fail "checked an overlay there is none of"
deploy eee5555 console=hhh8888 || fail "a deploy with no overlay"
has "nothing to replace: not backing up"
echo "ok   a stack's overlay is sent, checked in the image, mounted in the scheduler and removed"
# A dry run shows the sync and the keys, and writes nothing.
sed -i.bak '/^POSTHOG_KEY=/d' "$FAKE/hetzner.env"
printf 'POSTHOG_KEY=\nFIXED_COST=8/month\nBACKUP_KEEP=7\nS3_REGION=nbg1\n' >> "$FAKE/hetzner.env"
printf 'AWS_ACCESS_KEY_ID=x2\nAWS_SECRET_ACCESS_KEY=notasecret99\n' > "$FAKE/s3.env"
before=$(cat "$MORCA_CONF/settings.env" "$MORCA_CONF/s3.env" "$MORCA_CONF/stack.conf" | cksum)
: > "$FAKE/docker.log"
sh deploy/hetzner/deploy.sh --dry-run eee5555 > "$FAKE/out" 2>&1 || fail "a dry run with settings changed"
has "+ ssh root@<server-ip> morca-stack sync --keys settings.env < "
has "+ ssh root@<server-ip> morca-stack sync s3.env < $FAKE/s3.env"
has "+ ssh root@<server-ip> morca-stack configure MORCA_IMAGE=img .*BACKUP_KEEP=7 GHCR_USER= OVERLAP=1 DRAIN_SECONDS=86400$"
has "# settings.env from $FAKE/hetzner.env: AWS_REGION .*MORCA_FIXED_COST"
grep -q 'MORCA_POSTHOG_KEY\|notasecret99\|nbg1 ' "$FAKE/out" && fail "the dry run: $(grep 'POSTHOG\|notasecret99' "$FAKE/out")"
[ "$(cat "$MORCA_CONF/settings.env" "$MORCA_CONF/s3.env" "$MORCA_CONF/stack.conf" | cksum)" = "$before" ] \
    || fail "a dry run changed the server's settings"
[ ! -s "$FAKE/docker.log" ] || fail "a dry run ran docker"
# A key emptied in hetzner.env is removed; a changed one and a stack
# setting are named; a secret file only said to have changed.
deploy eee5555 console=hhh8888 || fail "a deploy that removes POSTHOG_KEY"
has "  morca-stack: settings.env: added MORCA_FIXED_COST; removed MORCA_POSTHOG_KEY; changed AWS_REGION$"
has "  morca-stack: s3.env: changed$"
has "  morca-stack: BACKUP_KEEP 14 -> 7$"
grep -q 'notasecret99\|8/month\|phc_' "$FAKE/out" && fail "a value was printed"
grep -q MORCA_POSTHOG_KEY "$MORCA_CONF/settings.env" && fail "MORCA_POSTHOG_KEY wasn't removed"
grep -q POSTHOG_KEY "$MORCA_CONF/app-console.env" && fail "POSTHOG_KEY is still in app-console.env"
grep -qx 'AWS_REGION=nbg1' "$MORCA_CONF/settings.env" || fail "AWS_REGION wasn't changed"
grep -qx 'AWS_SECRET_ACCESS_KEY=notasecret99' "$MORCA_CONF/s3.env" || fail "s3.env wasn't written"
[ "$(mode "$MORCA_CONF/s3.env")" = -rw------- ] || fail "s3.env is $(mode "$MORCA_CONF/s3.env")"
grep -qx 'BACKUP_KEEP=7' "$MORCA_CONF/stack.conf" || fail "BACKUP_KEEP wasn't configured"
grep -qx 'MORCA_TAG=eee5555' "$MORCA_CONF/stack.conf" || fail "the sync touched MORCA_TAG"
has "  scheduler replace settings: its env file changed"
has "  console replace settings: its env file changed"
stack resume > /dev/null
# A SOPS-encrypted secret file (tests/hetzner/sops: "decrypts" by dropping
# ENC: from each line): sent decrypted, said to need sops in a dry run.
printf 'ENC:AWS_ACCESS_KEY_ID=x3\nENC:AWS_SECRET_ACCESS_KEY=sopssecret77\n' > "$FAKE/s3.sops.env"
sed -i.bak "s|^S3_CREDENTIALS_FILE=.*|S3_CREDENTIALS_FILE=$FAKE/s3.sops.env|" "$FAKE/hetzner.env"
sh deploy/hetzner/deploy.sh --dry-run eee5555 > "$FAKE/out" 2>&1 || fail "a dry run with a SOPS file"
has "+ sops -d $FAKE/s3.sops.env | ssh root@<server-ip> morca-stack sync s3.env$"
deploy eee5555 console=hhh8888 || fail "a deploy with a SOPS file"
has "  morca-stack: s3.env: changed$"
grep -q 'sopssecret77' "$FAKE/out" && fail "a SOPS value was printed"
grep -qx 'AWS_SECRET_ACCESS_KEY=sopssecret77' "$MORCA_CONF/s3.env" || fail "s3.env wasn't decrypted: $(sed 's/=.*//' "$MORCA_CONF/s3.env")"
printf 'garbage\n' > "$FAKE/s3.sops.env"
deploy eee5555 console=hhh8888 && fail "a deploy with a SOPS file that doesn't decrypt"
has "sops couldn't decrypt $FAKE/s3.sops.env"
grep -qx 'AWS_SECRET_ACCESS_KEY=sopssecret77' "$MORCA_CONF/s3.env" || fail "a failed decrypt changed s3.env"
sed -i.bak "s|^S3_CREDENTIALS_FILE=.*|S3_CREDENTIALS_FILE=$FAKE/s3.env|" "$FAKE/hetzner.env"
deploy eee5555 console=hhh8888 || fail "a deploy back on the plain s3.env"
stack resume > /dev/null

# SECRETS_FILE: every secret in one SOPS file (here JSON lines behind ENC:),
# decrypted once per deploy (tests/hetzner/sops counts its calls), each value
# sent as a *.sops file is: one trailing newline. No value is printed.
secrets_file() { # JSON: SECRETS_FILE's content
    printf '%s\n' "$1" | sed 's/^/ENC:/' > "$FAKE/secrets.sops.yaml"
}
all_secrets='{"s3.env": "AWS_ACCESS_KEY_ID=x4\nAWS_SECRET_ACCESS_KEY=onefile55\n",
 "tunnel.env": "TUNNEL_TOKEN=tunnel66",
 "secrets/orca/github-token": "ghp_gh77\n\n",
 "secrets/orca/ntfy-topic": "topic88",
 "secrets/orca/ntfy-token": "tk_ntfy99",
 "ghcr-token": "ghcr11",
 "secrets/orca/hcloud-token": "hc_pool12",
 "secrets/orca/posthog-key": "phc_app13"}'
secrets_file "$all_secrets"
sed -i.bak '/^S3_CREDENTIALS_FILE=/d; /^TUNNEL_TOKEN_FILE=/d' "$FAKE/hetzner.env"
echo "SECRETS_FILE=$FAKE/secrets.sops.yaml" >> "$FAKE/hetzner.env"
secret_files() { cat "$MORCA_CONF/settings.env" "$MORCA_CONF/s3.env" "$MORCA_CONF/tunnel.env" 2> /dev/null | cksum; }
values='onefile55\|tunnel66\|ghp_gh77\|topic88\|tk_ntfy99\|ghcr11\|hc_pool12\|phc_app13'
: > "$FAKE/sops.calls"
before=$(secret_files)
sh deploy/hetzner/deploy.sh --dry-run eee5555 > "$FAKE/out" 2>&1 || fail "a dry run with SECRETS_FILE"
has "# a dry run doesn't decrypt $FAKE/secrets.sops.yaml: it assumes it has s3.env tunnel.env secrets/orca/github-token secrets/orca/ntfy-topic secrets/orca/ntfy-token ghcr-token secrets/orca/hcloud-token$"
has "^  + sops -d $FAKE/secrets.sops.yaml (once)$"
for n in s3.env tunnel.env secrets/orca/github-token secrets/orca/ntfy-topic secrets/orca/ntfy-token ghcr-token secrets/orca/hcloud-token; do
    has "^  | ssh root@<server-ip> morca-stack sync $n$"
done
has "# settings.env from .*MORCA_NOTIFY_SECRET MORCA_NOTIFY_TOKEN_SECRET"
[ ! -s "$FAKE/sops.calls" ] || fail "a dry run ran sops: $(cat "$FAKE/sops.calls")"
[ "$(secret_files)" = "$before" ] || fail "a dry run with SECRETS_FILE changed the server's files"
deploy eee5555 console=hhh8888 || fail "a deploy with SECRETS_FILE"
[ "$(cat "$FAKE/sops.calls")" = "-d --output-type json $FAKE/secrets.sops.yaml" ] \
    || fail "not one decrypt per deploy: $(cat "$FAKE/sops.calls")"
grep -q "$values" "$FAKE/out" && fail "a SECRETS_FILE value was printed"
has "  morca-stack: s3.env: changed$"
has "  morca-stack: secrets/orca/ntfy-topic: new$"
has "  morca-stack: ghcr-token: new$"
has "  morca-stack: secrets/orca/hcloud-token: new$"
# An app's secret (#331): any secrets/orca/<id> key, sent the same way.
has "  morca-stack: secrets/orca/posthog-key: new$"
# Worker pools (morca #267): the Hetzner token's id, the stack's firewall and
# key, and the registry login's id, in settings.env; the worker image in
# morca.env; ghcr-token among the secrets for morca.
grep -qx "MORCA_HCLOUD_TOKEN_SECRET=orca/hcloud-token" "$MORCA_CONF/settings.env" || fail "no MORCA_HCLOUD_TOKEN_SECRET"
grep -q "^MORCA_HCLOUD_FIREWALL=." "$MORCA_CONF/settings.env" || fail "no MORCA_HCLOUD_FIREWALL"
grep -q "^MORCA_HCLOUD_SSH_KEYS=." "$MORCA_CONF/settings.env" || fail "no MORCA_HCLOUD_SSH_KEYS"
same() { # NAME CONTENT
    printf '%s\n' "$2" | cmp -s - "$MORCA_CONF/$1" || fail "/etc/orca/$1 isn't SECRETS_FILE's value"
    [ "$(mode "$MORCA_CONF/$1")" = -rw------- ] || fail "$1 is $(mode "$MORCA_CONF/$1")"
}
same s3.env "$(printf 'AWS_ACCESS_KEY_ID=x4\nAWS_SECRET_ACCESS_KEY=onefile55')"
same tunnel.env TUNNEL_TOKEN=tunnel66
same secrets/orca/github-token ghp_gh77
same secrets/orca/ntfy-topic topic88
same secrets/orca/ntfy-token tk_ntfy99
same ghcr-token ghcr11
same secrets/orca/posthog-key phc_app13
grep -qx 'MORCA_NOTIFY_SECRET=orca/ntfy-topic' "$MORCA_CONF/settings.env" || fail "no MORCA_NOTIFY_SECRET from SECRETS_FILE"
grep -qx 'MORCA_NOTIFY_TOKEN_SECRET=orca/ntfy-token' "$MORCA_CONF/settings.env" || fail "no MORCA_NOTIFY_TOKEN_SECRET from SECRETS_FILE"
stack resume > /dev/null
# Again: unchanged, still one decrypt.
: > "$FAKE/sops.calls"
deploy eee5555 console=hhh8888 || fail "a deploy with SECRETS_FILE in line"
has "^  unchanged$"
[ "$(wc -l < "$FAKE/sops.calls")" -eq 1 ] || fail "$(wc -l < "$FAKE/sops.calls") decrypts in a deploy"
# What's refused, before anything is changed on the server.
refused() { # WHY MESSAGE
    before=$(secret_files)
    deploy eee5555 console=hhh8888 && fail "a deploy with $1"
    has "$2"
    grep -q "$values" "$FAKE/out" && fail "a value was printed ($1)"
    grep -q 'morca-stack' "$FAKE/out" && fail "the server was changed ($1)"
    [ "$(secret_files)" = "$before" ] || fail "$1 changed the server's files"
}
secrets_file '{"s3.env": "AWS_SECRET_ACCESS_KEY=onefile55", "../s3.env": "x", "notes.txt": "x", "/etc/passwd": "x", "ghcr-token": 11, "secrets/orca/a b": "x", "secrets/orca/x/../../s3.env": "x"}'
refused "bad keys" '"\.\./s3\.env": a name has no leading / and no \.\.'
has '"notes.txt" is not one of: s3.env tunnel.env'
has '"/etc/passwd": a name has no leading / and no \.\.'
has '"ghcr-token": the value is a number, not a string'
has '"secrets/orca/a b" is not one of: .*, or secrets/orca/<id>'
has '"secrets/orca/x/\.\./\.\./s3\.env": a name has no leading / and no \.\.'
secrets_file "$all_secrets"
echo "S3_CREDENTIALS_FILE=$FAKE/s3.env" >> "$FAKE/hetzner.env"
refused "SECRETS_FILE and S3_CREDENTIALS_FILE" "S3_CREDENTIALS_FILE and SECRETS_FILE both give s3.env: set only one"
sed -i.bak '/^S3_CREDENTIALS_FILE=/d' "$FAKE/hetzner.env"
secrets_file '{"s3.env": "a=b", "tunnel.env": ""}'
echo GHCR_USER=me >> "$FAKE/hetzner.env"
refused "GHCR_USER and no ghcr-token" "GHCR_USER needs GHCR_TOKEN_FILE or a ghcr-token key in SECRETS_FILE"
sed -i.bak '/^GHCR_USER=/d' "$FAKE/hetzner.env"
printf 'garbage\n' > "$FAKE/secrets.sops.yaml"
refused "a SECRETS_FILE that doesn't decrypt" "sops couldn't decrypt $FAKE/secrets.sops.yaml; nothing was changed on the server"
# Back on the plain files.
sed -i.bak '/^SECRETS_FILE=/d' "$FAKE/hetzner.env"
printf 'S3_CREDENTIALS_FILE=%s\nTUNNEL_TOKEN_FILE=%s\n' "$FAKE/s3.env" "$FAKE/tunnel.env" >> "$FAKE/hetzner.env"
rm -f "$MORCA_CONF/secrets/orca/ntfy-topic" "$MORCA_CONF/secrets/orca/ntfy-token"
deploy eee5555 console=hhh8888 || fail "a deploy back on the plain files"
grep -q MORCA_NOTIFY "$MORCA_CONF/settings.env" && fail "MORCA_NOTIFY_SECRET without SECRETS_FILE"
stack resume > /dev/null

# An app declared in morca.toml (#331): its env file is what [apps.console]
# asks for (`morca config apps` in its image): its env, the lake, its secret
# from secrets/orca/<id> (never printed), and its port, check and memory.
cat > "$FAKE/apps-decl" << 'EOS'
console port 8080
console check /healthz
console lake true
console memory_mb 1024
console env CONSOLE_SEMANTIC=1
console env GREETING=hello world
console secret POSTHOG_KEY orca/posthog-key
other port 9090
EOS
appenv=$MORCA_CONF/app-console.env
: > "$FAKE/docker.log"
deploy eee5555 console=hhh8888 || fail "a deploy with the console declared"
grep -q "^config-apps run --rm --env-file $MORCA_CONF/settings.env img:hhh8888 config apps" "$FAKE/docker.log" || fail "the console's image wasn't asked for its apps"
grep -qx 'CONSOLE_SEMANTIC=1' "$appenv" && grep -qx 'GREETING=hello world' "$appenv" || fail "the console's env: $(sed 's/=.*//' "$appenv" | tr '\n' ' ')"
grep -qx 'POSTHOG_KEY=phc_app13' "$appenv" || fail "the console hasn't its secret"
grep -qx 'MORCA_WAREHOUSE=s3://bkt/warehouse' "$appenv" && grep -q '^AWS_SECRET_ACCESS_KEY=' "$appenv" || fail "lake = true didn't give the lake"
grep -q 'MORCA_DATABASE_URL' "$appenv" && fail "the console has morca's database"
[ "$(mode "$appenv")" = -rw------- ] || fail "app-console.env is $(mode "$appenv")"
[ ! -f "$MORCA_CONF/app.env" ] || fail "the old app.env is left"
grep -q phc_app13 "$FAKE/out" && fail "the app's secret was printed"
has "  console replace "
grep -q "run -d --name console-next .*--env-file $MORCA_CONF/app-console.env -e PORT=8080 --memory 1024m --entrypoint /opt/morca/bin/console img:hhh8888" "$FAKE/docker.log" \
    || fail "the console's run: $(grep 'name console' "$FAKE/docker.log")"
grep -q "probe console-next 8080 /healthz" "$FAKE/docker.log" || fail "the console wasn't probed on its declared check"
grep -q "isn't declared" "$FAKE/out" && fail "a declared app was said not to be"
deploy eee5555 console=hhh8888 || fail "a deploy with the console in line"
has "nothing to replace: not backing up"
# An image whose morca has no `config apps`: the fixed env of before.
touch "$FAKE/no-config-apps"
deploy eee5555 console=hhh8888 || fail "a deploy of an image without config apps"
has "app console isn't declared in img:hhh8888's morca.toml"
grep -q 'POSTHOG_KEY\|CONSOLE_SEMANTIC' "$appenv" && fail "the fixed env has the declared app's"
grep -qx 'MORCA_WAREHOUSE=s3://bkt/warehouse' "$appenv" || fail "the fixed env hasn't the lake"
rm "$FAKE/no-config-apps"
# A secret it names that the server hasn't: refused at the plan, before
# anything is paused.
mv "$MORCA_CONF/secrets/orca/posthog-key" "$FAKE/posthog-key"
: > "$FAKE/docker.log"
deploy eee5555 console=hhh8888 && fail "deployed an app without its secret"
has "app console needs the secret orca/posthog-key, and $MORCA_CONF/secrets/orca/posthog-key is missing"
grep -q 'morca pause\|run -d' "$FAKE/docker.log" && fail "a missing app secret paused or started something"
mv "$FAKE/posthog-key" "$MORCA_CONF/secrets/orca/posthog-key"
# APPS names the app; a port there that isn't morca.toml's is refused, and
# APPS=console leaves the port to morca.toml.
echo "APPS=console:8081" >> "$FAKE/hetzner.env"
deploy eee5555 console=hhh8888 && fail "deployed with APPS's port against morca.toml's"
has "app console: hetzner.env's APPS says port 8081, img:hhh8888's morca.toml port 8080"
sed -i.bak 's/^APPS=console:8081$/APPS=console/' "$FAKE/hetzner.env"
deploy eee5555 console=hhh8888 || fail "a deploy with APPS=console"
has "app console: port 8081 -> morca.toml's"
grep -q '^console - ' "$MORCA_CONF/apps" || fail "the apps file: $(cat "$MORCA_CONF/apps")"
# Back to an app the image doesn't declare, its port from APPS.
rm "$FAKE/apps-decl"
sed -i.bak '/^APPS=/d' "$FAKE/hetzner.env"
deploy eee5555 console=hhh8888 || fail "a deploy back on the undeclared console"
grep -q '^console 8080 ' "$MORCA_CONF/apps" || fail "the apps file after: $(cat "$MORCA_CONF/apps")"
stack resume > /dev/null
echo "ok   an app's env, secrets, port, check and memory come from its [apps.NAME]; one not declared gets the fixed env"

# A setting only morca.env has: the scheduler and the UI; CGROUPS: the
# scheduler only; a tag pushed again: what runs it.
add_setting MORCA_TEST_SETTING=1
stack apply > "$FAKE/out" 2>&1 || fail "apply after a setting"
has "scheduler: replaced (settings: its env file changed)"
has "ui: replaced (settings: its env file changed)"
has "console: unchanged"
has "sampler: unchanged"
# Run cgroups are on by default (#239): the scheduler already has them.
grep 'run -d --name scheduler ' "$FAKE/docker.all" | tail -n 1 | grep -q -- '--cgroupns=private --cap-add SYS_ADMIN' \
    || fail "the scheduler has no cgroup flags by default"
stack configure CGROUPS=0
stack apply > "$FAKE/out" 2>&1 || fail "apply with CGROUPS=0"
has "scheduler: replaced (options: its flags, mounts or CGROUPS changed)"
has "ui: unchanged"
grep 'run -d --name scheduler ' "$FAKE/docker.all" | tail -n 1 | grep -q -- '--cgroupns' && fail "CGROUPS=0 kept the cgroup flags"
grep -q 'run cgroups' "$FAKE/out" && fail "CGROUPS=0 said why there are no cgroups"
stack configure CGROUPS=1
stack apply > "$FAKE/out" 2>&1 || fail "apply with CGROUPS=1"
has "scheduler: replaced (options: its flags, mounts or CGROUPS changed)"
grep 'run -d --name scheduler ' "$FAKE/docker.all" | tail -n 1 | grep -q -- 'remount,rw /sys/fs/cgroup || echo' \
    || fail "a failed remount stops the scheduler"
stack configure CGROUPS=2 > "$FAKE/out" 2>&1 && fail "configured CGROUPS=2"
has "CGROUPS is 1 (the default) or 0, not 2"
# A host without cgroup v2 (or its memory controller): the scheduler runs
# without, saying why, in the plan and the apply.
mv "$MORCA_HOST_CGROUP/cgroup.controllers" "$FAKE/controllers"
stack plan > "$FAKE/out" 2>&1 || fail "plan on a cgroup v1 host"
has "morca-stack: run cgroups off: this host has no cgroup v2 at $MORCA_HOST_CGROUP"
has "scheduler replace options: its flags, mounts or CGROUPS changed"
stack apply > "$FAKE/out" 2>&1 || fail "apply on a cgroup v1 host"
has "morca-stack: run cgroups off: this host has no cgroup v2"
grep 'run -d --name scheduler ' "$FAKE/docker.all" | tail -n 1 | grep -q -- '--cgroupns' && fail "cgroup flags on a cgroup v1 host"
echo "cpu io pids" > "$MORCA_HOST_CGROUP/cgroup.controllers"
stack plan > "$FAKE/out" 2>&1 || fail "plan without a memory controller"
has "run cgroups off: this host's cgroup v2 has no memory controller"
has "scheduler keep unchanged"
mv "$FAKE/controllers" "$MORCA_HOST_CGROUP/cgroup.controllers"
# The pre-flight: a warning for each pipeline whose peak is over its
# memory_gb's maximum, or what the host can grant (8000 - 1536 MB).
printf 'big|9000|20|2..8\nfits|3000|20|2..4\nwild|7000|5|\nlearned|7000|20|auto\ncapped|5000|20|auto..4\n' > "$FAKE/peaks"
stack apply > "$FAKE/out" 2>&1 || fail "apply with peaks over their limits"
has "scheduler: replaced (options: its flags, mounts or CGROUPS changed)"
has "warning: big peaks at 9000 MB (95th percentile of its last 20 runs), over memory_gb's maximum, 8 GB"
has "warning: wild peaks at 7000 MB (95th percentile of its last 5 runs), over what the host can grant, 6464 MB"
has "warning: learned peaks at 7000 MB"
has "warning: capped peaks at 5000 MB (95th percentile of its last 20 runs), over memory_gb's maximum, 4 GB"
grep -q 'warning: fits' "$FAKE/out" && fail "warned for a pipeline that fits"
stack configure CGROUPS=0
stack apply > "$FAKE/out" 2>&1 || fail "apply with CGROUPS=0 and peaks"
grep -q 'warning:' "$FAKE/out" && fail "warned about peaks with CGROUPS=0"
stack configure CGROUPS=1
stack apply > /dev/null 2>&1 || fail "apply with CGROUPS=1 again"
rm "$FAKE/peaks"
echo sha256:0123456789abcdef0123 > "$FAKE/images/img_eee5555"
stack apply > "$FAKE/out" 2>&1 || fail "apply after a push"
has "scheduler: replaced (image eee5555 pushed again ("
has "sampler: replaced (image eee5555 pushed again ("
has "console: unchanged"

# --all and --only.
stack apply --all > "$FAKE/out" 2>&1 || fail "apply --all"
for c in scheduler ui sampler console; do has "$c: replaced (--all)"; done
: > "$FAKE/docker.log"
stack apply --only console --app console=iii9999 > "$FAKE/out" 2>&1 || fail "apply --only console"
has "console: replaced (image hhh8888 -> iii9999)"
has "scheduler: left as it is (--only console)"
grep -q 'run -d --name \(scheduler\|ui\|sampler\)' "$FAKE/docker.log" && fail "--only console replaced more"
stack apply --only ui --tag jjj0000 > "$FAKE/out" 2>&1 && fail "--only with a new --tag"
has "would leave the other containers on the old one"
stack apply --only ui --app console=jjj0000 > "$FAKE/out" 2>&1 && fail "--only ui with --app console"
[ "$(stack tags)" = "morca eee5555, console iii9999" ] || fail "tags after --only: $(stack tags)"

# Rolling back an app only goes on over running runs and registers nothing.
echo 1 > "$FAKE/running"
: > "$FAKE/docker.log"
deploy --rollback || fail "an app-only deploy.sh --rollback"
has "  console replace image iii9999 -> hhh8888"
has "the scheduler keeps running: not pausing anything"
has "console: replaced (image iii9999 -> hhh8888)"
has "the scheduler kept running, so the pipelines stay registered as they are"
grep -q 'morca register\|morca pause\|run -d --name scheduler' "$FAKE/docker.log" && fail "an app-only rollback touched the scheduler"
[ "$(stack tags)" = "morca eee5555, console hhh8888" ] || fail "tags after an app-only rollback: $(stack tags)"
echo 0 > "$FAKE/running"

# Without downtime: the UI's and the apps' new container starts beside the
# old one, as NAME-next; once it's healthy it gets the alias NAME (a
# reconnect) and is checked again, and only then is the old one stopped.
: > "$FAKE/docker.log"
deploy kkk1111 || fail "deploy.sh kkk1111"
has "ui: replaced (image eee5555 -> kkk1111), without downtime"
has "scheduler: replaced (image eee5555 -> kkk1111)"
has "console: unchanged"
order=$(grep -oE 'run -d --name ui-next|probe ui-next|network disconnect orca ui-next|network connect --alias ui orca ui-next|stop -t 10 ui$|rm -f ui$|rename ui-next ui$' "$FAKE/docker.log" | tr '\n' ,)
[ "$order" = "run -d --name ui-next,probe ui-next,network disconnect orca ui-next,network connect --alias ui orca ui-next,probe ui-next,stop -t 10 ui,rm -f ui,rename ui-next ui," ] \
    || fail "the UI's replacement order: $order"
grep -q 'run -d --name ui-next.*--network-alias' "$FAKE/docker.log" && fail "ui-next had the alias ui before it was healthy"
grep -q '^probe ui-next 8270 /healthz$' "$FAKE/docker.log" || fail "the UI's probe isn't /healthz on 8270"
grep -q 'stop -t 10 scheduler\|run -d --name scheduler-next' "$FAKE/docker.log" && fail "the scheduler was replaced side by side"
[ ! -d "$FAKE/containers/ui-next" ] || fail "ui-next is left"
[ "$(cat "$FAKE/containers/ui/image")" = img:kkk1111 ] || fail "ui runs $(cat "$FAKE/containers/ui/image")"
grep -qw ui "$FAKE/containers/ui/aliases" || fail "the new ui has no alias ui"
# An app, by its check path.
stack app console 8080 /ready
stack app console 8080
grep -q '^console 8080 [^ ]* /ready$' "$MORCA_CONF/apps" || fail "app without a CHECK reset it: $(cat "$MORCA_CONF/apps")"
: > "$FAKE/docker.log"
stack apply --app console=lll2222 > "$FAKE/out" 2>&1 || fail "the console's apply"
has "console: replaced (image hhh8888 -> lll2222), without downtime"
grep -q '^probe console-next 8080 /ready$' "$FAKE/docker.log" || fail "the console's probe isn't /ready on 8080"
[ "$(grep -n 'exec console-next sh\|stop -t 10 console$' "$FAKE/docker.log" | head -1 | grep -c exec)" = 1 ] \
    || fail "the old console was stopped before the new one was healthy"

# A new console that answers 503 (warming up, for good): removed, the old
# one keeps serving, the others are applied, and apply fails saying why.
mkdir -p "$FAKE/health" "$FAKE/exits"
echo 503 > "$FAKE/health/console"
add_setting MORCA_TEST_SETTING=2
: > "$FAKE/docker.log"
stack apply --app console=mmm3333 --health-timeout 0 > "$FAKE/out" 2>&1 && fail "an apply whose console wasn't healthy"
has "console: not replaced: the new container answered 503 on :8080/ready (wants 200) after 0s; the old one keeps serving"
has "fake log of console-next"
has "not replaced: console, whose new container wasn't healthy"
has "ui: replaced (settings: its env file changed), without downtime"
[ ! -d "$FAKE/containers/console-next" ] || fail "console-next is left"
[ "$(cat "$FAKE/containers/console/image")" = img:lll2222 ] || fail "the old console was replaced: $(cat "$FAKE/containers/console/image")"
[ "$(cat "$FAKE/containers/console/status")" = running ] || fail "the old console was stopped"
grep -q 'stop -t 10 console$' "$FAKE/docker.log" && fail "the old console was stopped"
# Healthy again: an apply again replaces only the console.
rm "$FAKE/health/console"
stack apply > "$FAKE/out" 2>&1 || fail "an apply again"
has "console: replaced (image lll2222 -> mmm3333), without downtime"
for c in scheduler ui sampler; do has "$c: unchanged"; done
# One that exits at once fails without waiting out the timeout.
touch "$FAKE/exits/console"
stack apply --app console=nnn4444 > "$FAKE/out" 2>&1 && fail "an apply whose console exited"
has "console: not replaced: the new container stopped (exited, exit code 1)"
[ "$(cat "$FAKE/containers/console/image")" = img:mmm3333 ] || fail "the console was replaced by one that exited"
rm "$FAKE/exits/console"
stack apply --app console=mmm3333 > /dev/null 2>&1 || fail "back to mmm3333"

# The worker API's listener (MORCA_WORKER_ADDR) moves with the UI and is
# probed too.
add_setting MORCA_WORKER_ADDR=0.0.0.0:8271
: > "$FAKE/docker.log"
stack apply > "$FAKE/out" 2>&1 || fail "apply with MORCA_WORKER_ADDR"
grep -q '^probe ui-next 8271 /$' "$FAKE/docker.log" || fail "the worker listener wasn't probed"
has "ui: replaced (settings: its env file changed), without downtime"

# deploy.sh: a UI that isn't healthy after the scheduler was replaced: the
# pipelines are registered from the new image, then unpaused (the
# scheduler is deployed), the status shown, and it fails naming the UI and
# how to retry.
echo 503 > "$FAKE/health/ui"
stack configure HEALTH_TIMEOUT=0
: > "$FAKE/docker.log"
deploy ooo5555 && fail "a deploy whose UI wasn't healthy"
rm "$FAKE/health/ui"
stack configure HEALTH_TIMEOUT=300
has "registering the pipelines from ooo5555"
grep -q 'exec scheduler morca register' "$FAKE/docker.log" || fail "a replaced scheduler wasn't registered"
has "unpausing the pipelines it paused"
grep -qx toy "$FAKE/paused" && fail "toy left paused after only the UI failed"
grep -qx manual1 "$FAKE/paused" || fail "unpaused manual1, paused by hand"
order=$(grep -o 'exec scheduler morca register\|morca unpause toy' "$FAKE/docker.log" | tr '\n' ,)
[ "$order" = "exec scheduler morca register,morca unpause toy," ] || fail "not register, then unpause: $order"
has "running runs: "
has "not replaced: ui, whose new container wasn't healthy (above): the old one keeps serving"
has "ssh root@192.0.2.1 morca-stack apply"
grep -q 'stay paused' "$FAKE/out" && fail "said the pipelines stay paused"
[ "$(cat "$FAKE/containers/ui/image")" = img:kkk1111 ] || fail "the old UI wasn't kept: $(cat "$FAKE/containers/ui/image")"
[ "$(cat "$FAKE/containers/scheduler/image")" = img:ooo5555 ] || fail "the scheduler wasn't replaced"
stack apply > "$FAKE/out" 2>&1 || fail "the UI's retry"
has "ui: replaced (image kkk1111 -> ooo5555), without downtime"
has "scheduler: unchanged"
[ ! -f "$MORCA_STATE/paused-by-quiesce" ] || fail "quiesce's list is left"

# The same through a rollback: registered, unpaused, failing on the UI.
echo 503 > "$FAKE/health/ui"
stack configure HEALTH_TIMEOUT=0
deploy --rollback && fail "a rollback whose UI wasn't healthy"
rm "$FAKE/health/ui"
stack configure HEALTH_TIMEOUT=300
has "morca-stack: registered toy"
has "not replaced: ui, whose new container wasn't healthy"
grep -qx toy "$FAKE/paused" && fail "toy left paused after only the UI failed a rollback"
stack apply > /dev/null 2>&1 || fail "the UI's retry after the rollback"
deploy ooo5555 console=mmm3333 > /dev/null 2>&1 || fail "back to ooo5555"

# A scheduler that fails to start stops the deploy with the pipelines
# paused, as a failed registration does; the UI isn't let off either.
mkdir -p "$FAKE/run-fails"
touch "$FAKE/run-fails/scheduler"
: > "$FAKE/docker.log"
deploy ooo6666 && fail "a deploy whose scheduler didn't start"
rm "$FAKE/run-fails/scheduler"
has "the deploy failed; the pipelines stay paused"
grep -q 'morca register' "$FAKE/docker.log" && fail "registered a scheduler that didn't start"
grep -q 'unpause' "$FAKE/docker.log" && fail "unpaused after the scheduler failed"
grep -qx toy "$FAKE/paused" || fail "toy unpaused after the scheduler failed"
stack apply > /dev/null 2>&1 || fail "the scheduler's retry"
stack resume > /dev/null

# The quiesce waits only for the scheduler's own runs: runs on remote
# workers go on through its restart, and are listed as left running there.
# (--timeout 0: a wait for them would fail the deploy.)
echo 2 > "$FAKE/worker-running"
: > "$FAKE/docker.log"
deploy --timeout 0 ooo7777 || fail "a deploy with runs only on workers"
has "pausing the pipelines"
has "2 run(s) left running on workers"
has "  run 91 mojo_history 2026-11-07 on bgent"
has "morca-stack: quiet; paused: toy"
grep -q 'unpause toy' "$FAKE/docker.log" || fail "not unpaused after a deploy over worker runs"
has "running runs: 0 here, 2 on remote workers"
# Runs of its own are waited for, and the worker runs listed beside them.
echo 1 > "$FAKE/running"
deploy --timeout 0 ooo8888 && fail "a deploy over a run of the scheduler's own"
has "waiting for 1 running run(s)"
has "2 run(s) left running on workers"
has "1 run(s) still running after 0s"
echo 0 > "$FAKE/running"
stack resume > /dev/null
# apply's refusal doesn't count them either.
stack apply --tag ooo8888 > "$FAKE/out" 2>&1 || fail "apply refused over runs on workers"
has "scheduler: replaced (image ooo7777 -> ooo8888)"
# rescale.sh's quiesce --workers (the UI goes down too) waits for them.
stack quiesce --workers --timeout 0 > "$FAKE/out" 2>&1 && fail "quiesce --workers over runs on workers"
has "and for 2 on remote workers (--workers)"
has "  run 92 mojo_history"
has "2 run(s) still running after 0s"
grep -q -- 'morca-stack quiesce --workers' deploy/hetzner/rescale.sh || fail "rescale.sh doesn't wait for the workers' runs"
stack resume > /dev/null
rm "$FAKE/worker-running"

# An image before morca 0.18 has no /healthz: its UI's 404 there counts as up.
echo 404 > "$FAKE/health/ui"
stack configure HEALTH_TIMEOUT=0
stack apply --tag ppp6666 > "$FAKE/out" 2>&1 || { cat "$FAKE/out"; fail "a UI answering 404 on /healthz wasn't taken as up"; }
rm "$FAKE/health/ui"
stack configure HEALTH_TIMEOUT=300
[ "$(cat "$FAKE/containers/ui/image")" = img:ppp6666 ] || fail "the older UI wasn't swapped in: $(cat "$FAKE/containers/ui/image")"

# Overlapping schedulers (docs/overlap.md), on by default (#390): hetzner.env
# has no OVERLAP, so the deploys set OVERLAP=1, and morca.env has
# MORCA_OVERLAP=on and the drain limit, hetzner.env's DRAIN_SECONDS.
grep -qx OVERLAP=1 "$MORCA_CONF/stack.conf" || fail "no OVERLAP=1 in stack.conf: $(cat "$MORCA_CONF/stack.conf")"
grep -qx DRAIN_SECONDS=86400 "$MORCA_CONF/stack.conf" || fail "no DRAIN_SECONDS in stack.conf: $(cat "$MORCA_CONF/stack.conf")"
grep -qx MORCA_OVERLAP=on "$MORCA_CONF/morca.env" || fail "no MORCA_OVERLAP=on in morca.env by default"
grep -qx MORCA_DRAIN_SECONDS=86400 "$MORCA_CONF/morca.env" || fail "no MORCA_DRAIN_SECONDS in morca.env"
# A stack.conf without OVERLAP (a server set up before #390) overlaps too:
# can-overlap asks the new image.
grep -v '^OVERLAP=' "$MORCA_CONF/stack.conf" > "$FAKE/conf.new" && mv "$FAKE/conf.new" "$MORCA_CONF/stack.conf"
stack can-overlap > "$FAKE/out" 2>&1 && fail "can-overlap without a leading instance"
has "no: no live scheduler instance leads"
# OVERLAP=0 in hetzner.env opts out: the deploy sets it, morca.env loses
# MORCA_OVERLAP, can-overlap says no without asking the image (which would
# say yes), and the deploy pauses and waits.
echo OVERLAP=0 >> "$FAKE/hetzner.env"
echo yes > "$FAKE/can-overlap"
: > "$FAKE/docker.log"
deploy ppp6666 || fail "the deploy that turns OVERLAP off"
has "OVERLAP (unset) -> 0"
has "not overlapping the schedulers: OVERLAP=0 in stack.conf"
has "pausing the pipelines"
grep -q 'run -d --name scheduler-next' "$FAKE/docker.log" && fail "overlapped with OVERLAP=0"
grep -q MORCA_OVERLAP "$MORCA_CONF/morca.env" && fail "MORCA_OVERLAP with OVERLAP=0"
grep -qx MORCA_DRAIN_SECONDS=86400 "$MORCA_CONF/morca.env" || fail "no MORCA_DRAIN_SECONDS with OVERLAP=0"
rm "$FAKE/can-overlap"
# Taking it out turns it on again, which changes the scheduler's env file:
# that deploy can't overlap (the running one has it off), so it pauses and
# waits as before.
sed -i.bak '/^OVERLAP=/d' "$FAKE/hetzner.env"
: > "$FAKE/docker.log"
deploy ppp6666 || fail "the deploy that turns OVERLAP on"
has "OVERLAP 0 -> 1"
grep -q '^MORCA_OVERLAP=on$' "$MORCA_CONF/morca.env" || fail "no MORCA_OVERLAP=on in morca.env"
has "not overlapping the schedulers: no live scheduler instance leads"
has "pausing the pipelines"
grep -q 'run -d --name scheduler-next' "$FAKE/docker.log" && fail "overlapped when can-overlap said no"
# can-overlap yes: the new scheduler beside the old one, nothing paused, the
# old one told not to restart, renamed scheduler-old-<time> and asked to
# drain; registered from the new one, after it leads. One that has exited
# by then (the fake's drain) is removed at once.
echo yes > "$FAKE/can-overlap"
echo 4 > "$FAKE/running"
echo 7 > "$FAKE/instances"
: > "$FAKE/docker.log"
deploy qqq7777 || fail "an overlapping deploy"
has "the new scheduler starts beside the old one, which drains its runs: not pausing anything"
old_re='scheduler-old-[0-9]\{8\}T[0-9]\{6\}Z'
grep -q "^scheduler: replaced (image ppp6666 -> qqq7777), overlapping: $old_re drains its runs$" "$FAKE/out" \
    || fail "no line naming the old scheduler"
grep -q "asked scheduler instance 7 ($old_re) to drain" "$FAKE/out" || fail "the old scheduler wasn't asked to drain"
has "the old scheduler drains its runs in the background; not waiting for them"
grep -q "$old_re drained and removed" "$FAKE/out" || fail "the exited old scheduler wasn't removed"
grep -q 'exec scheduler morca pause' "$FAKE/docker.log" && fail "an overlapping deploy paused a pipeline"
order=$(grep -oE 'run -d --name scheduler-next|update --restart no scheduler$|rename scheduler scheduler-old-[0-9TZ]*|rename scheduler-next scheduler|morca scheduler wait-lead|exec scheduler morca register|morca scheduler drain 7|rm -f scheduler-old-[0-9TZ]*' "$FAKE/docker.log" | sed 's/-[0-9]\{8\}T[0-9]\{6\}Z/-T/' | tr '\n' ,)
[ "$order" = "run -d --name scheduler-next,update --restart no scheduler,rename scheduler scheduler-old-T,rename scheduler-next scheduler,morca scheduler wait-lead,exec scheduler morca register,morca scheduler drain 7,rm -f scheduler-old-T," ] \
    || fail "the overlap's order: $order"
grep -q 'stop .*scheduler' "$FAKE/docker.log" && fail "the old scheduler was stopped"
[ "$(cat "$FAKE/containers/scheduler/image")" = img:qqq7777 ] || fail "scheduler runs $(cat "$FAKE/containers/scheduler/image")"
ls "$FAKE/containers" | grep -q '^scheduler-old' && fail "an old scheduler is left: $(ls "$FAKE/containers")"
# Its runs go on (#397): the deploy doesn't wait for them, and the old
# scheduler drains in the background, check saying so without failing.
touch "$FAKE/old-stays"
echo 2 > "$FAKE/old-running"
export MORCA_STACK_REAP_SECONDS=1
deploy rrr8888 || fail "an overlapping deploy whose old scheduler's runs go on"
first=$(ls "$FAKE/containers" | grep '^scheduler-old-' || true)
[ -n "$first" ] || fail "no old scheduler draining: $(ls "$FAKE/containers")"
has "$first drains 2 run(s) in the background (outdated: morca.outdated() is true for them); it's removed once its last run ends"
has "check: info  $first: draining 2 run(s) (outdated)"
has "check: all ok"
has "done: rrr8888"
grep -q "stop .*$first" "$FAKE/docker.all" && fail "the old scheduler was stopped"
[ "$(cat "$FAKE/containers/$first/image")" = img:qqq7777 ] || fail "$first runs $(cat "$FAKE/containers/$first/image")"
[ -f "$MORCA_STATE/reap-$first.pid" ] || fail "no reaper for $first"
stack status > "$FAKE/out" 2>&1 || fail "status beside a draining old scheduler"
has "^$first: draining 2 run(s) (outdated)$"
# Each scheduler instance says its image: morca.env's MORCA_IMAGE (#270).
grep -qx MORCA_IMAGE=img:rrr8888 "$MORCA_CONF/morca.env" || fail "no MORCA_IMAGE in morca.env"
has "leading image=img:rrr8888 "
# A second deploy while it drains overlaps again: the scheduler it replaces
# drains under a name of its own, beside the first, which keeps its own.
sleep 1
deploy sss9999 || fail "a deploy while an old scheduler drains"
has "the new scheduler starts beside the old one, which drains its runs"
second=$(ls "$FAKE/containers" | grep '^scheduler-old-' | grep -vx "$first" || true)
[ -n "$second" ] || fail "no second old scheduler: $(ls "$FAKE/containers")"
[ "$(ls "$FAKE/containers" | grep -c '^scheduler-old-')" = 2 ] || fail "old schedulers: $(ls "$FAKE/containers")"
[ "$(cat "$FAKE/containers/$first/image")" = img:qqq7777 ] || fail "$first was replaced: $(cat "$FAKE/containers/$first/image")"
[ "$(cat "$FAKE/containers/$second/image")" = img:rrr8888 ] || fail "$second runs $(cat "$FAKE/containers/$second/image")"
[ "$(cat "$FAKE/containers/scheduler/image")" = img:sss9999 ] || fail "scheduler runs $(cat "$FAKE/containers/scheduler/image")"
has "check: info  $first: draining 2 run(s) (outdated)"
has "check: info  $second: draining 2 run(s) (outdated)"
has "check: all ok"
# Each one's reaper removes it once its last run has ended and it exits.
# Wait for the reaper itself to end (its pid file goes last), not only for
# the container to go: it logs the removal just after it (#453).
echo exited > "$FAKE/containers/$first/status"
i=0
while [ -d "$FAKE/containers/$first" ] || [ -f "$MORCA_STATE/reap-$first.pid" ]; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "$first wasn't removed once it exited"; sleep 0.1
done
[ -d "$FAKE/containers/$second" ] || fail "$second was removed while it drained"
grep -q "$first drained and removed" "$MORCA_STATE/reap-$first.log" || fail "the reaper's log: $(cat "$MORCA_STATE/reap-$first.log")"
echo exited > "$FAKE/containers/$second/status"
i=0
while [ -d "$FAKE/containers/$second" ] || [ -f "$MORCA_STATE/reap-$second.pid" ]; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "$second wasn't removed once it exited"; sleep 0.1
done
# drain-old --timeout waits, and stops one still running after it.
deploy ttt0000 || fail "an overlapping deploy"
: > "$FAKE/docker.log"
stack drain-old --timeout 0 > "$FAKE/out" 2>&1 || fail "drain-old --timeout 0"
grep -q "$old_re still runs after 0s: stopping it" "$FAKE/out" || fail "drain-old --timeout didn't stop it"
grep -q "stop -t 30 $old_re" "$FAKE/docker.log" || fail "the old scheduler wasn't stopped"
ls "$FAKE/containers" | grep -q '^scheduler-old' && fail "an old scheduler is left: $(ls "$FAKE/containers")"
# The drain limit drives drain-old and the reaper (#390): one still running
# DRAIN_SECONDS (and MORCA_STACK_DRAIN_GRACE) after it was asked to drain is
# stopped, its runs queued again by the new scheduler. (The limit is set to
# 1 only around them, so the schedulers' env file stays as it was.)
stack apply --tag ttt0001 --overlap > /dev/null 2>&1 || fail "an overlapping apply"
stack configure DRAIN_SECONDS=1 > /dev/null
: > "$FAKE/docker.log"
MORCA_STACK_DRAIN_GRACE=0 stack drain-old --wait > "$FAKE/out" 2>&1 || fail "drain-old --wait"
grep -q "$old_re still runs after 1s: stopping it" "$FAKE/out" || fail "drain-old --wait didn't stop it at the drain limit"
ls "$FAKE/containers" | grep -q '^scheduler-old' && fail "an old scheduler is left: $(ls "$FAKE/containers")"
stack configure DRAIN_SECONDS=86400 > /dev/null
stack apply --tag ttt0002 --overlap > /dev/null 2>&1 || fail "an overlapping apply"
reaped=$(ls "$FAKE/containers" | grep '^scheduler-old-')
stack configure DRAIN_SECONDS=1 > /dev/null
MORCA_STACK_DRAIN_GRACE=0 MORCA_STACK_REAP_SECONDS=1 stack reap-old "$reaped" > "$FAKE/out" 2>&1 || fail "reap-old"
has "waiting for $reaped to drain (the drain limit: 1s)"
has "$reaped still runs past the drain limit (1s): stopping it; the new scheduler queues its runs again"
has "$reaped drained and removed"
[ ! -d "$FAKE/containers/$reaped" ] || fail "the reaper left $reaped"
stack configure DRAIN_SECONDS=86400 > /dev/null
rm "$FAKE/old-stays" "$FAKE/old-running"
# One from before #397 (scheduler-old), still draining: the next deploy
# overlaps beside it, apply leaves it, and drain-old counts it.
mkdir "$FAKE/containers/scheduler-old"
echo running > "$FAKE/containers/scheduler-old/status"
echo img:f3516e2 > "$FAKE/containers/scheduler-old/image"
echo h-scheduler-old > "$FAKE/containers/scheduler-old/hostname"
stack can-overlap > "$FAKE/out" 2>&1 || fail "can-overlap beside a draining scheduler-old"
stack apply > "$FAKE/out" 2>&1 || fail "an apply beside a running scheduler-old"
grep -q 'removed scheduler-old' "$FAKE/out" && fail "apply removed a running scheduler-old"
[ -d "$FAKE/containers/scheduler-old" ] || fail "apply removed a running scheduler-old"
# One that has exited (drain-old didn't follow), and a scheduler-next that
# never ran: the apply removes both first, naming their images and when
# they exited, and the deploy overlaps.
echo exited > "$FAKE/containers/scheduler-old/status"
echo 2026-01-01T00:00:00.123456789Z > "$FAKE/containers/scheduler-old/finished"
mkdir "$FAKE/containers/scheduler-next"
echo created > "$FAKE/containers/scheduler-next/status"
echo img:f3516e2 > "$FAKE/containers/scheduler-next/image"
stack can-overlap > "$FAKE/out" 2>&1 || fail "can-overlap with an exited scheduler-old"
: > "$FAKE/docker.log"
deploy uuu1212 || fail "an overlapping deploy over an exited scheduler-old"
grep -q 'removed scheduler-old, left by a deploy before (img:f3516e2, exited, exited [0-9]*d [0-9]*h ago)$' "$FAKE/out" \
    || fail "no line naming the exited scheduler-old"
has "removed scheduler-next, left by a deploy before (img:f3516e2, created, never ran)"
grep -q "^scheduler: replaced (image ttt0002 -> uuu1212), overlapping: $old_re drains its runs$" "$FAKE/out" \
    || fail "no overlap over the exited scheduler-old"
grep -q "$old_re drained and removed" "$FAKE/out" || fail "the old scheduler wasn't removed"
has "check: all ok"
ls "$FAKE/containers" | grep -q '^scheduler-old' && fail "an old scheduler is left: $(ls "$FAKE/containers")"
# A new scheduler that doesn't lead: apply fails, and deploy.sh says so.
touch "$FAKE/no-lead"
stack apply --tag vvv3434 --overlap > "$FAKE/out" 2>&1 && fail "an overlap whose new scheduler doesn't lead"
has "doesn't lead after"
rm "$FAKE/no-lead"
stack drain-old > /dev/null 2>&1 || fail "drain-old after the failed lead"
stack configure OVERLAP=0
rm "$FAKE/can-overlap" "$FAKE/instances"
echo 0 > "$FAKE/running"
stack apply > /dev/null 2>&1 || fail "back to OVERLAP=0"
stack resume > /dev/null

# Postgres: started once, by the first apply, and never stopped or removed.
[ "$(grep -c 'run -d --name postgres' "$FAKE/docker.all")" = 1 ] || fail "Postgres was started more than once"
grep -q '\(stop\|rm\).* postgres$' "$FAKE/docker.all" && fail "Postgres was stopped or removed"

# One hetzner.env for every laptop: in a secrets repository, its file names
# relative to its folder, and each laptop's ADMIN_IP and ssh key in
# <XDG_CONFIG_HOME>/morca-hetzner/<NAME>.local.env, read after it (its own
# relative names from its folder). The first line names both files.
shared=$FAKE/ops-secrets/prod
mkdir -p "$shared/creds" "$XDG_CONFIG_HOME/morca-hetzner/keys"
cp "$FAKE/s3.env" "$shared/creds/s3.env"
: > "$shared/tunnel.env"
: > "$XDG_CONFIG_HOME/morca-hetzner/keys/laptop.pub"
cat > "$shared/hetzner.env" << 'EOS'
NAME=morca
BUCKET=bkt
S3_ENDPOINT=https://example.invalid
S3_REGION=fsn1
DRAIN_SECONDS=86400
S3_CREDENTIALS_FILE=creds/s3.env
TUNNEL_TOKEN_FILE=./tunnel.env
MORCA_IMAGE=img
ADMIN_IP=192.0.2.1/32
SSH_PUBLIC_KEY_FILE=/nowhere/id.pub
EOS
local_env=$XDG_CONFIG_HOME/morca-hetzner/morca.local.env
printf 'ADMIN_IP=198.51.100.9/32\nSSH_PUBLIC_KEY_FILE=keys/laptop.pub\n' > "$local_env"
(cd "$FAKE" && HETZNER_ENV=ops-secrets/prod/hetzner.env sh "$OLDPWD/deploy/hetzner/up.sh" --dry-run) > "$FAKE/out" 2>&1 \
    || fail "up.sh --dry-run with a shared hetzner.env"
real=$(cd "$shared" && pwd) # HETZNER_ENV was relative: from the folder it was given in
has "up.sh: stack morca, settings $real/hetzner.env and $local_env"
has "morca-stack sync s3.env < $real/creds/s3.env"
has "morca-stack sync tunnel.env < $real/./tunnel.env"
has "public-key-from-file $XDG_CONFIG_HOME/morca-hetzner/keys/laptop.pub"
# Without the local file, the shared file's own settings.
rm "$local_env"
HETZNER_ENV=$shared/hetzner.env sh deploy/hetzner/deploy.sh --dry-run ttt0000 > "$FAKE/out" 2>&1 \
    || fail "deploy.sh --dry-run with no local file"
has "deploy.sh: stack morca, settings $shared/hetzner.env$"
# HETZNER_LOCAL_ENV names another; one that's missing, or that sets NAME, is refused.
echo "ADMIN_IP=198.51.100.10/32" > "$FAKE/other.local.env"
HETZNER_ENV=$shared/hetzner.env HETZNER_LOCAL_ENV=$FAKE/other.local.env sh deploy/hetzner/deploy.sh --dry-run ttt0000 > "$FAKE/out" 2>&1 \
    || fail "deploy.sh --dry-run with HETZNER_LOCAL_ENV"
has "settings $shared/hetzner.env and $FAKE/other.local.env"
HETZNER_ENV=$shared/hetzner.env HETZNER_LOCAL_ENV=$FAKE/none.env sh deploy/hetzner/deploy.sh --dry-run ttt0000 > "$FAKE/out" 2>&1 \
    && fail "a missing HETZNER_LOCAL_ENV"
has "no $FAKE/none.env (HETZNER_LOCAL_ENV)"
echo NAME=morca-dev >> "$FAKE/other.local.env"
HETZNER_ENV=$shared/hetzner.env HETZNER_LOCAL_ENV=$FAKE/other.local.env sh deploy/hetzner/deploy.sh --dry-run ttt0000 > "$FAKE/out" 2>&1 \
    && fail "a local file that sets NAME"
has "sets NAME: the stack's name belongs in $shared/hetzner.env"
# morca-stack check: the smoke check deploy.sh ends with.
export MORCA_STACK_CHECK_SECONDS=0
tags=$(stack tags)
stack check > "$FAKE/out" 2>&1 || fail "check on a healthy stack"
has "check: ok    postgres: ready"
has "check: ok    scheduler: img:"
has "check: ok    ui: img:.*, healthy"
has "check: ok    pipelines: 2 registered, each binary in the image; paused: manual1"
has "check: all ok"
stack checked | grep -q "^ok [0-9T:-]*Z plain $tags\$" || fail "checked: $(stack checked)"
check_fails() { # WHY: check fails, saying WHY, and checked says failed
    stack check "$@" > "$FAKE/out" 2>&1 && fail "check passed, though: $why_"
    has "$why_"
    has "check: 1 failed"
    stack checked | grep -q '^failed ' || fail "checked after a failed check: $(stack checked)"
}
echo exited > "$FAKE/containers/sampler/status"
why_="FAIL  sampler: exited"
check_fails
echo running > "$FAKE/containers/sampler/status"
mkdir -p "$FAKE/health"
echo 500 > "$FAKE/health/ui"
why_="FAIL  ui: answered 500 on :8270/healthz"
check_fails
rm "$FAKE/health/ui"
mkdir "$FAKE/containers/scheduler-next"
echo running > "$FAKE/containers/scheduler-next/status"
why_="FAIL  scheduler-next is still there"
check_fails
rm -r "$FAKE/containers/scheduler-next"
# An old scheduler still draining is information, not a failure.
mkdir "$FAKE/containers/scheduler-old"
echo running > "$FAKE/containers/scheduler-old/status"
echo h-scheduler-old > "$FAKE/containers/scheduler-old/hostname"
echo 1 > "$FAKE/old-running"
stack check > "$FAKE/out" 2>&1 || fail "check failed beside a draining scheduler-old"
has "check: info  scheduler-old: draining 1 run(s) (outdated)"
rm "$FAKE/old-running"
# One that has exited: apply removes it, saying how long ago it exited, and
# the check passes.
echo exited > "$FAKE/containers/scheduler-old/status"
echo img:f3516e2 > "$FAKE/containers/scheduler-old/image"
date -u +%Y-%m-%dT%H:%M:%S.000000000Z > "$FAKE/containers/scheduler-old/finished"
stack apply > "$FAKE/out" 2>&1 || fail "an apply over an exited scheduler-old"
grep -q 'removed scheduler-old, left by a deploy before (img:f3516e2, exited, exited [0-9]*s ago)$' "$FAKE/out" \
    || fail "no line naming the exited scheduler-old"
[ ! -d "$FAKE/containers/scheduler-old" ] || fail "apply left an exited scheduler-old"
stack check > "$FAKE/out" 2>&1 || fail "check after apply removed an exited scheduler-old"
echo /opt/morca/pipelines/toy > "$FAKE/no-binary"
why_="FAIL  pipelines: not in the scheduler's image: toy (/opt/morca/pipelines/toy)"
check_fails
# A retired pipeline (morca retire, #427) is left out.
echo toy > "$FAKE/retired"
stack check > "$FAKE/out" 2>&1 || { cat "$FAKE/out"; fail "check with the binary-less toy retired"; }
has "check: ok    pipelines: 1 registered"
rm "$FAKE/no-binary" "$FAKE/retired"
touch "$FAKE/unregistered"
why_="FAIL  pipelines: none registered"
check_fails
rm "$FAKE/unregistered"
# Canary runs: each started and waited for.
: > "$FAKE/canary.log"
stack check --canary toy=2024-01 --canary manual1=x > "$FAKE/out" 2>&1 || fail "check with canaries"
has "check: ok    canary toy 2024-01: run 701 succeeded"
has "check: ok    canary manual1 x: run 702 succeeded"
[ "$(cat "$FAKE/canary.log")" = "toy 2024-01
manual1 x" ] || fail "the canaries started: $(cat "$FAKE/canary.log")"
stack checked | grep -q "^ok .* canary $tags\$" || fail "checked after canaries: $(stack checked)"
mkdir -p "$FAKE/canary-status"
echo failed > "$FAKE/canary-status/toy"
why_="FAIL  canary toy 2024-01: run 703 failed"
check_fails --canary toy=2024-01
echo running > "$FAKE/canary-status/toy"
why_="FAIL  canary toy 2024-01: run 704 still running after 0s"
check_fails --canary toy=2024-01 --timeout 0
rm -r "$FAKE/canary-status"
stack check --canary toy > "$FAKE/out" 2>&1 && fail "a --canary without a key"
has "needs PIPELINE=KEY"
# deploy.sh ends with it, CANARY's runs as --canary; it fails when the check does.
echo 'CANARY="toy=2024-02 manual1=y"' >> "$FAKE/hetzner.env"
echo CANARY_TIMEOUT=60 >> "$FAKE/hetzner.env"
sh deploy/hetzner/deploy.sh --dry-run uuu1111 > "$FAKE/out" 2>&1 || fail "a dry run with CANARY"
has "+ ssh root@<server-ip> morca-stack check --canary toy=2024-02 --canary manual1=y --timeout 60"
deploy uuu1111 || fail "a deploy with canaries"
has "checking the stack (canary runs: toy=2024-02 manual1=y)"
has "check: ok    canary manual1 y"
has "check: all ok"
echo /opt/morca/pipelines/manual1 > "$FAKE/no-binary"
deploy --all uuu1111 && fail "a deploy whose check fails"
has "uuu1111 is deployed, but the check failed (above)"
rm "$FAKE/no-binary"
sed -i.bak '/^CANARY/d' "$FAKE/hetzner.env"
stack check --canary toy=2024-03 > /dev/null 2>&1 || fail "a check with a canary"

# promote.sh: the tags the dev stack checked go to production (the fake
# server is both stacks' here).
sed 's/^NAME=morca$/NAME=morca-dev/' "$FAKE/hetzner.env" > "$FAKE/dev.env"
promote() { sh deploy/hetzner/promote.sh "$@" > "$FAKE/out" 2>&1; }
promote --from "$FAKE/dev.env" --dry-run || fail "promote --dry-run"
has "deploy.sh --dry-run <dev-tag>"
promote --from "$FAKE/dev.env" --no-backup || fail "promote"
has "promote.sh: stack morca-dev"
has "promote.sh: dev checked morca uuu1111, console mmm3333 at .* (canary)"
has "promote.sh: deploy.sh --no-backup uuu1111 console=mmm3333 (settings $FAKE/hetzner.env)"
has "deploy.sh: stack morca, settings $FAKE/hetzner.env"
has "deploy.sh .*done: morca uuu1111, console mmm3333"
# An app on its own tag goes along as app=tag.
deploy uuu1111 console=vvv2222 || fail "a deploy of the console's own tag"
promote --from "$FAKE/dev.env" || fail "promote with an app's own tag"
has "deploy.sh uuu1111 console=vvv2222"
# Refused: a failed check, a check of other tags, the target's own settings.
echo /opt/morca/pipelines/toy > "$FAKE/no-binary"
stack check > /dev/null 2>&1 || true
rm "$FAKE/no-binary"
promote --from "$FAKE/dev.env" && fail "promote after a failed check"
has "the dev stack's last check failed"
stack check > /dev/null 2>&1 || fail "check again"
stack apply --tag www3333 > /dev/null 2>&1 || fail "an apply after the check"
promote --from "$FAKE/dev.env" && fail "promote of tags dev hasn't checked"
has "the dev stack runs morca www3333, console vvv2222, but its last check was of morca uuu1111, console vvv2222"
promote --from "$FAKE/hetzner.env" && fail "promote from the target itself"
has "promote goes from dev to another stack"
promote --from "$FAKE/dev.env" uuu1111 && fail "promote with a tag"
has "promote takes no tags"
stack register > /dev/null 2>&1
deploy uuu1111 > /dev/null 2>&1 || fail "back to uuu1111"
unset MORCA_STACK_CHECK_SECONDS

# Upgrade steps (morca#323): from the new image's upgrade.toml (morca upgrade).
# A before step that isn't confirmed stops a --yes deploy before anything
# changes; with --confirmed it goes on, and the after steps run (a command)
# or are printed (an instruction).
printf 'step\tb1\tbefore\tmanual\tAllow egress to example.org.\nstep\ta1\tafter\trun\tmorca backfill --rerun toy @all\nstep\ta2\tafter\tmanual\tCheck /live.\n' > "$FAKE/steps"
: > "$FAKE/docker.log"
deploy --yes 1.1.0 && fail "a deploy with an unconfirmed before step"
has "\[b1\] Allow egress to example.org."
has "\[b1\] needs doing before this deploy"
has "nothing was deployed"
grep -q "step exec" "$FAKE/docker.log" && fail "an after step ran though the deploy stopped"
deploy --yes --confirmed b1 1.1.0 || fail "deploy.sh --confirmed b1 1.1.0"
has "\[b1\] confirmed"
has "\[a2\] to do: Check /live."
grep -q "step exec scheduler morca backfill --rerun toy @all" "$FAKE/docker.log" || fail "the after step a1 didn't run"
grep -q "upgrade run --rm img:1.1.0 upgrade --from .* --to 1.1.0 --when before" "$FAKE/docker.log" \
    || fail "the before steps weren't read from the new image"
# The same morca tag again: no steps.
: > "$FAKE/docker.log"
deploy --yes --all 1.1.0 || fail "deploy.sh --all 1.1.0"
grep -q "^upgrade " "$FAKE/docker.log" && fail "steps read for the tag already deployed"
# From 1.1.0: the image is asked for the steps after it.
touch "$FAKE/step-fails"
deploy --yes --confirmed b1 1.2.0 && fail "a deploy whose after step failed"
has "upgrade steps failed: a1"
has "1.2.0 is deployed and checked"
grep -q "upgrade run --rm img:1.2.0 upgrade --from 1.1.0 --to 1.2.0 --when after" "$FAKE/docker.log" \
    || fail "the steps weren't asked for from 1.1.0"
rm "$FAKE/step-fails"
# A rollback runs none.
: > "$FAKE/docker.log"
deploy --yes --rollback || fail "deploy.sh --rollback"
grep -q "^upgrade \|^step " "$FAKE/docker.log" && fail "a rollback read or ran upgrade steps"
# An image whose morca has no `morca upgrade`: no steps.
touch "$FAKE/no-upgrade"
deploy --yes 1.3.0 || fail "deploy.sh 1.3.0 of an image without morca upgrade"
rm "$FAKE/no-upgrade"
# A command several versions ask for (the same after trimming) runs once,
# where it last comes, for all their ids; different ones each, in order; a
# before one confirmed only with all its ids (#343).
printf 'step\tr1\tafter\trun\tmorca backfill --rerun toy @all\nstep\tn1\tafter\trun\tmorca backfill toy 2026-11-01\nstep\tr2\tafter\trun\tmorca backfill --rerun toy @all \nstep\tb1\tbefore\trun\tmorca backfill toy 2026-11-02\nstep\tb2\tbefore\trun\tmorca backfill toy 2026-11-02\n' > "$FAKE/steps"
: > "$FAKE/docker.log"
deploy --yes --confirmed b1 1.3.1 || fail "deploy.sh 1.3.1 with shared steps"
[ "$(grep '^step ' "$FAKE/docker.log" | sed 's/.* backfill //')" = "toy 2026-11-02
toy 2026-11-01
--rerun toy @all" ] || fail "the steps didn't each run once, in order: $(grep '^step ' "$FAKE/docker.log")"
has "ran 'morca backfill toy 2026-11-02' for b1, b2"
has "ran 'morca backfill --rerun toy @all' for r1, r2"
# A failed shared step fails all its ids; a before one is confirmed by all of them.
touch "$FAKE/step-fails"
deploy --yes --confirmed b1,b2 1.3.2 && fail "a deploy whose shared step failed"
has "\[b1,b2\] confirmed"
has "upgrade steps failed: n1 r1 r2"
rm "$FAKE/step-fails" "$FAKE/steps"
# A dry run lists nothing and needs no confirmation.
deploy --dry-run 1.4.0 || fail "deploy.sh --dry-run 1.4.0"
has "morca-stack upgrade-steps --tag 1.4.0 --from <deployed> --when before"
has "morca-stack upgrade-steps --tag 1.4.0 --from <deployed> --when after"
# morca-stack upgrade-run refuses what isn't a morca command.
stack upgrade-run rm -rf / > "$FAKE/out" 2>&1 && fail "upgrade-run ran rm"
has "morca commands only"
stack upgrade-run morca backfill 'a;b' > "$FAKE/out" 2>&1 && fail "upgrade-run took a ;"
has "refusing the argument"

# The release tarball (deploy/hetzner/package.sh), run from where it's unpacked.
sh deploy/hetzner/package.sh 9.8.7 "$FAKE/pkg" > "$FAKE/out" 2>&1 || fail "package.sh"
cmp -s "$FAKE/pkg/morca-hetzner-9.8.7.tar.gz" "$FAKE/pkg/morca-hetzner.tar.gz" || fail "the two tarballs differ"
mkdir "$FAKE/unpacked"
(cd "$FAKE/unpacked" && gzip -dc "$FAKE/pkg/morca-hetzner.tar.gz" | tar -xf -) || fail "unpacking"
pkg=$FAKE/unpacked/morca-hetzner-9.8.7
for f in up.sh deploy.sh promote.sh down.sh rescale.sh backup.sh lib.sh cloud-init.yaml hetzner.env.example \
    README.md VERSION server/morca-stack server/secret-fetch server/orca-backup.service server/orca-backup.timer; do
    [ -f "$pkg/$f" ] || fail "no $f in the tarball"
done
[ "$(ls "$FAKE/unpacked")" = morca-hetzner-9.8.7 ] || fail "the tarball unpacks to $(ls "$FAKE/unpacked")"
[ "$(cat "$pkg/VERSION")" = 9.8.7 ] || fail "VERSION is $(cat "$pkg/VERSION")"
[ -x "$pkg/up.sh" ] && [ -x "$pkg/server/morca-stack" ] || fail "the scripts aren't executable"
{
    cat "$FAKE/hetzner.env"
    echo ADMIN_IP=203.0.113.7/32
    echo "SSH_PUBLIC_KEY_FILE=$FAKE/k.pub"
} > "$pkg/hetzner.env"
: > "$FAKE/k.pub"
(cd "$pkg" && unset HETZNER_ENV && ./up.sh --dry-run) > "$FAKE/out" 2>&1 || fail "the tarball's up.sh --dry-run"
has "up.sh: stack morca, settings $pkg/hetzner.env, scripts 9.8.7"
has "install -D -m 755 /dev/stdin /usr/local/sbin/morca-stack < $pkg/server/morca-stack"
has "install -D -m 644 /dev/stdin /etc/systemd/system/orca-backup.timer < $pkg/server/orca-backup.timer"
has "hcloud server create"
(cd "$pkg" && unset HETZNER_ENV && ./deploy.sh --dry-run ttt0000) > "$FAKE/out" 2>&1 || fail "the tarball's deploy.sh --dry-run"
has "deploy.sh: stack morca, settings $pkg/hetzner.env, scripts 9.8.7"
has "/usr/local/sbin/morca-stack < $pkg/server/morca-stack"
has "systemctl daemon-reload && rm -f /usr/local/sbin/orca-stack"

# The server's docker network is orca, as on the stacks made before the
# rename to morca (#384): every network command and --network names it
# (or host, for the containers that share the server's).
[ -s "$FAKE/networks" ] || fail "no docker network was named"
grep -qx orca "$FAKE/networks" || fail "no docker command named the orca network"
! grep -vxE 'orca|host' "$FAKE/networks" > /dev/null || fail "a docker network other than orca (or host): $(sort -u "$FAKE/networks" | tr '\n' ' ')"
# The secrets a worker pool's machine reads are under secrets/orca (login
# copies ghcr-token there while GHCR_USER is set).
[ ! -e "$MORCA_CONF/secrets/morca" ] || fail "a secrets/morca directory"

# A scheduler from before the rename has orca's command, not morca's: the
# first deploy's quiesce and resume use it.
echo /opt/morca/bin/morca >> "$FAKE/no-binary"
n=$(wc -l < "$FAKE/docker.log")
stack quiesce --timeout 5 > "$FAKE/out" 2>&1 || fail "quiesce of a pre-rename scheduler"
stack resume > "$FAKE/out" 2>&1 || fail "resume of a pre-rename scheduler"
tail -n +"$((n + 1))" "$FAKE/docker.log" > "$FAKE/old-sched.log"
grep -q 'exec scheduler orca pause' "$FAKE/old-sched.log" || fail "quiesce didn't use orca's command: $(cat "$FAKE/old-sched.log")"
grep -q 'exec scheduler orca unpause' "$FAKE/old-sched.log" || fail "resume didn't use orca's command"
! grep -q 'exec scheduler morca ' "$FAKE/old-sched.log" || fail "ran morca in a pre-rename scheduler"
grep -vx /opt/morca/bin/morca "$FAKE/no-binary" > "$FAKE/no-binary.new" || true
mv "$FAKE/no-binary.new" "$FAKE/no-binary"

# deploy.sh with an image from before the rename (#384): refused by the
# plan, before it pauses or stops anything.
echo "img:pre4444" > "$FAKE/pre-rename"
cp "$MORCA_CONF/stack.conf" "$FAKE/stack.conf.before"
n=$(wc -l < "$FAKE/docker.log")
deploy pre4444 && fail "deployed an image from before the rename"
has "img:pre4444 predates the morca rename (#384)"
! tail -n +"$((n + 1))" "$FAKE/docker.log" | grep -qE 'morca pause|stop|rm -f' || fail "the refused deploy paused or stopped something: $(tail -n +"$((n + 1))" "$FAKE/docker.log")"
cmp -s "$MORCA_CONF/stack.conf" "$FAKE/stack.conf.before" || fail "the refused deploy changed stack.conf"
rm -f "$FAKE/pre-rename"

# A server from before the rename to morca (#384): its stack.conf and
# settings.env with orca's ORCA_* keys, its tags as orca lines. Looking at it
# changes nothing; an image from before the rename is refused before
# anything changes; configure keeps orca's key names; the first apply of a
# morca image renames the keys once, keeps the files as they were, and the
# orca deploy before can't be rolled back to.
old="$FAKE/old-conf"
rm -rf "$old"
cp -Rp "$MORCA_CONF" "$old"
for f in stack.conf settings.env; do sed 's/^MORCA_/ORCA_/' "$MORCA_CONF/$f" > "$old/$f"; done
grep -v '^ORCA_TAG=' "$old/stack.conf" > "$old/stack.conf.new"
printf 'ORCA_TAG=old1111\nORCA_PREV_TAG=old0000\n' >> "$old/stack.conf.new"
mv "$old/stack.conf.new" "$old/stack.conf"
rm -f "$old/renamed" "$old"/*.orca
echo "orca old1111" > "$old/deployed"
echo "orca old0000" > "$old/deployed.prev"
os() { MORCA_CONF="$old" stack "$@"; }
snap() { rm -rf "$FAKE/old-snap"; cp -Rp "$old" "$FAKE/old-snap"; }
same() { diff -r "$FAKE/old-snap" "$old" > "$FAKE/old.diff" 2>&1 || fail "$1 changed the orca server: $(cat "$FAKE/old.diff")"; }
snap
os tags > "$FAKE/out" 2>&1 || fail "morca-stack tags on an orca server"
has "old1111"
same "tags"
os status > "$FAKE/out" 2>&1 || true
same "status"
echo "img:old2222" > "$FAKE/pre-rename"
os plan --tag old2222 > "$FAKE/out" 2>&1 && fail "planned an image from before the rename"
has "img:old2222 predates the morca rename (#384)"
same "a refused plan"
os apply --tag old2222 > "$FAKE/out" 2>&1 && fail "applied an image from before the rename"
has "img:old2222 predates the morca rename (#384): it has no /opt/morca/bin/morca; deploy it with orca-hetzner 0.24.x"
same "a refused apply"
os configure HEALTH_TIMEOUT=0 OVERLAP=1 MORCA_IMAGE=img2 > /dev/null || fail "configure on an orca server"
os can-overlap --tag new3333 > "$FAKE/out" 2>&1 && fail "overlapped the first deploy after the rename"
has "the first deploy after the orca -> morca rename"
grep -qx ORCA_IMAGE=img2 "$old/stack.conf" || fail "configure didn't keep orca's key name: $(cat "$old/stack.conf")"
! grep -q '^MORCA_' "$old/stack.conf" || fail "configure wrote a MORCA_ key before the migration"
os configure OVERLAP=0 MORCA_IMAGE=img > /dev/null || fail "configure on an orca server again"
[ ! -f "$old/renamed" ] && [ ! -f "$old/stack.conf.orca" ] || fail "configure migrated the server"
os apply --tag new3333 > "$FAKE/out" 2>&1 || fail "the first apply of a morca image on an orca server"
has "stack.conf: renamed its ORCA_\\* keys to MORCA_\\*"
has "applied img:new3333"
grep -qx MORCA_TAG=new3333 "$old/stack.conf" || fail "stack.conf: $(cat "$old/stack.conf")"
! grep -q PREV_TAG "$old/stack.conf" || fail "stack.conf kept a PREV_TAG"
! grep -q '^ORCA_' "$old/stack.conf" "$old/settings.env" || fail "ORCA_ keys left"
grep -qx ORCA_TAG=old1111 "$old/stack.conf.orca" || fail "no stack.conf.orca"
[ -f "$old/settings.env.orca" ] || fail "no settings.env.orca"
[ -f "$old/deployed.prev.orca" ] && [ ! -f "$old/deployed.prev" ] && [ ! -f "$old/renamed" ] || fail "deployed.prev wasn't set aside"
os rollback > "$FAKE/out" 2>&1 && fail "rolled back to an orca deploy"
has "the deploy before was orca's"
snap
os tags > "$FAKE/out" 2>&1 || fail "morca-stack tags after the migration"
has "new3333"
! grep -q renamed "$FAKE/out" || fail "renamed the keys twice"
same "tags after the migration"
rm -f "$FAKE/pre-rename"

echo "ok   hetzner"
