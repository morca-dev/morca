#!/bin/sh
# morca.toml (morca.config): `morca register` reads the project's file, in a git
# checkout of its own under build/:
#
# - the toy, named in it, is registered with [defaults] under its own table,
#   with the file's SHA-256 and commit; a flag overrides the file and is
#   recorded as an override; a key taken out of the file goes back to its
#   default (unlike a flag left out); the file's max_runs beats the code's;
# - daily, not named in it, keeps today's behaviour: a flag left out keeps
#   what was registered;
# - `morca config show` (text and --json) gives each value's source: code
#   default, morca.toml, flag, environment (MORCA_RUN_ENV);
# - a bad file is refused with its line, and nothing is registered;
# - the toy's `env` reaches its runs on the local runner (MORCA_TOY_FAIL fails
#   the month it names) and no other pipeline's;
# - on the ec2 runner (tests/fake_ec2.py) the env is exported on the run's
#   instance over the same variable from MORCA_RUN_ENV, and is part of the
#   warm pool's key: a run after a change of env launches a new instance, one
#   with the same env takes the pooled one;
# - `morca config check` checks a file with no database: its keys, that each
#   instance type can be sized (a warning for one with no price), and with
#   --secrets that each secret can be read, never printing a value;
# - the pipeline page shows the registration and its overrides (and its
#   JSON, `config`), and a run's settings link to it;
# - `morca config export` writes back a file that registers to the same thing;
# - `morca aws register` sends the file with its commit (tests/aws.sh has the
#   stand-ins; here only that the flags read back).
#
# Needs MORCA_DATABASE_URL (pixi run test-config starts a throwaway server),
# git, jq, python3 and curl.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
one_cluster_test
mkdir -p build
scripts/pipelines.sh toy
scripts/pipelines.sh daily
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca
root=$PWD
morca=$root/build/morca
log=$root/build/config.log
: > "$log"
fake=
ui=
stop() {
    [ -z "$fake" ] || kill "$fake" 2> /dev/null || true
    [ -z "$ui" ] || kill "$ui" 2> /dev/null || true
    fake=
    ui=
}
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    stop
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
# A failed run waits for its retry past the test.
export MORCA_RETRY_SECONDS=3600
proj=$root/build/config-project
rm -rf "$proj"
mkdir -p "$proj"
cd "$proj"
git init -q .
git config user.email test@example.com
git config user.name test
cat > morca.toml << 'EOF'
[defaults]
head_type = "t4g.medium"
placement = "default"

[pipelines.toy]
worker_type = "c7g.xlarge"
workers = "0..4"
worker_procs = 1
max_runs = 1
env = { MORCA_TOY_FAIL = "2024-02", CONFIG_ONLY = "x y" }

[stack]
hostname = "morca.example.com"
EOF
git add morca.toml
git commit -qm "morca.toml"
commit=$(git rev-parse HEAD)
if command -v sha256sum > /dev/null 2>&1; then
    sha=$(sha256sum morca.toml | cut -c1-64)
else
    sha=$(shasum -a 256 morca.toml | cut -c1-64)
fi

# Registered from ./morca.toml, found by itself.
"$morca" register "$root/build/toy" > reg.out 2>> "$log" || fail "register the toy"
grep -q "registered toy" reg.out || fail "register's output: $(cat reg.out)"
row() { q "SELECT concat_ws(' ', coalesce(placement, '-'), coalesce(head_type, '-'), coalesce(worker_type, '-'), coalesce(ec2_min_workers::text, '-'), coalesce(ec2_workers::text, '-'), coalesce(worker_procs::text, '-'), coalesce(max_runs::text, '-')) FROM orca.pipelines WHERE name = '$1'"; }
[ "$(row toy)" = "- t4g.medium c7g.xlarge 0 4 1 1" ] || fail "the toy's registration: $(row toy)"
[ "$(q "SELECT env->>'MORCA_TOY_FAIL' || '|' || (env->>'CONFIG_ONLY') FROM orca.pipelines WHERE name = 'toy'")" = "2024-02|x y" ] \
    || fail "the toy's env"
[ "$(q "SELECT config->>'hash' FROM orca.pipelines WHERE name = 'toy'")" = "$sha" ] || fail "the file's hash"
[ "$(q "SELECT (config->>'commit') || ' ' || (config->>'dirty') FROM orca.pipelines WHERE name = 'toy'")" = "$commit false" ] \
    || fail "the file's commit"
echo "ok   a pipeline in morca.toml is registered from it, with its hash and commit"

# A flag beats the file, recorded as an override.
"$morca" register --worker-type c7g.2xlarge "$root/build/toy" >> "$log" 2>&1 || fail "register with a flag"
[ "$(row toy)" = "- t4g.medium c7g.2xlarge 0 4 1 1" ] || fail "the flag didn't win: $(row toy)"
[ "$(q "SELECT config->'overrides'->>'worker_type' FROM orca.pipelines WHERE name = 'toy'")" = c7g.2xlarge ] \
    || fail "the override wasn't recorded"
# Without it, the file's value is back: a flag is a one-off.
"$morca" register "$root/build/toy" >> "$log" 2>&1 || fail "register again"
[ "$(row toy)" = "- t4g.medium c7g.xlarge 0 4 1 1" ] || fail "the file's value didn't come back: $(row toy)"
[ "$(q "SELECT config->'overrides' FROM orca.pipelines WHERE name = 'toy'")" = "{}" ] || fail "a stale override"
echo "ok   a flag overrides the file, recorded, for that registration only"

# A key taken out of the file goes back to its default; the file changed
# since its commit says so.
sed -i.bak '/^worker_procs/d; /^max_runs/d; /^head_type/d' morca.toml
"$morca" register "$root/build/toy" >> "$log" 2>&1 || fail "register after the edit"
[ "$(row toy)" = "- - c7g.xlarge 0 4 - -" ] || fail "keys taken out: $(row toy)"
[ "$(q "SELECT config->>'dirty' FROM orca.pipelines WHERE name = 'toy'")" = true ] || fail "the edit isn't marked"
[ "$(q "SELECT max_runs FROM orca.pipelines WHERE name = 'toy'")" = "" ] || fail "max_runs stayed"
cp morca.toml.bak morca.toml
git checkout -q morca.toml
"$morca" register "$root/build/toy" >> "$log" 2>&1 || fail "register from the commit"
echo "ok   a key taken out of the file goes back to its default"

# daily isn't in the file: today's behaviour, a flag left out keeping its
# value, and a note saying so.
"$morca" register --worker-type c7g.large --workers 3 "$root/build/daily" >> "$log" 2> warn.out || fail "register daily"
grep -q "daily isn't in morca.toml" warn.out || fail "no note for daily: $(cat warn.out)"
"$morca" register "$root/build/daily" >> "$log" 2>&1 || fail "register daily again"
[ "$(row daily)" = "- - c7g.large - 3 - -" ] || fail "daily lost its flags: $(row daily)"
[ "$(q "SELECT config ? 'file' FROM orca.pipelines WHERE name = 'daily'")" = f ] || fail "daily recorded a file"
[ "$(q "SELECT count(*) FROM orca.pipelines WHERE name = 'daily' AND env IS NULL")" = 1 ] || fail "daily got an env"
# --no-config: the toy as a pipeline without the file, flags left out
# keeping what was registered.
"$morca" register --no-config "$root/build/toy" >> "$log" 2>&1 || fail "register --no-config"
[ "$(row toy)" = "- t4g.medium c7g.xlarge 0 4 1 1" ] || fail "--no-config changed the toy: $(row toy)"
"$morca" register "$root/build/toy" >> "$log" 2>&1 || fail "register the toy from the file again"
echo "ok   a pipeline not in the file keeps today's behaviour"

# morca config show: each value's source.
export CONFIG_FALLBACK=fb MORCA_RUN_ENV=CONFIG_FALLBACK,MORCA_TOY_FAIL MORCA_TOY_FAIL=2024-01
"$morca" config show toy > show.out 2>> "$log" || fail "config show"
cat show.out >> "$log"
grep -q "^toy  registered from morca.toml @ $(echo "$commit" | cut -c1-12), sha256 $(echo "$sha" | cut -c1-12)" show.out \
    || fail "show's header: $(head -2 show.out)"
grep -Eq "^  head_type +t4g.medium +morca.toml \[defaults\]$" show.out || fail "show's head_type"
grep -Eq "^  worker_type +c7g.xlarge +morca.toml \[pipelines.toy\]$" show.out || fail "show's worker_type"
grep -Eq "^  env.MORCA_TOY_FAIL +2024-02 +morca.toml \[pipelines.toy\]$" show.out || fail "show's env"
grep -Eq "^  env.CONFIG_FALLBACK +fb +environment MORCA_RUN_ENV$" show.out || fail "show's MORCA_RUN_ENV"
grep -q "env.MORCA_TOY_FAIL *2024-01" show.out && fail "MORCA_RUN_ENV shown over the pipeline's env"
"$morca" config show daily > show.out 2>> "$log" || fail "config show daily"
grep -Eq "^  max_runs +1 +code default the pipeline's max_runs$" show.out || fail "daily's max_runs: $(cat show.out)"
grep -Eq "^  worker_type +c7g.large +flag --worker-type$" show.out || fail "daily's worker_type"
MORCA_EC2_HEAD_TYPE=m7g.large "$morca" config show daily > show.out 2>> "$log" || fail "config show with MORCA_EC2_HEAD_TYPE"
grep -Eq "^  head_type +m7g.large +environment MORCA_EC2_HEAD_TYPE$" show.out || fail "daily's head_type from the environment"
"$morca" register --max-runs 3 "$root/build/toy" >> "$log" 2>&1 || fail "register --max-runs"
json=$("$morca" config show toy --json) || fail "config show --json"
[ "$(echo "$json" | jq -r '.settings[] | select(.key == "max_runs") | .value + " " + .source + " " + .detail')" = "3 flag --max-runs" ] \
    || fail "show --json's max_runs: $json"
[ "$(echo "$json" | jq -r '.overrides.max_runs + " " + .commit + " " + (.dirty | tostring)')" = "3 $commit false" ] \
    || fail "show --json's overrides: $json"
[ "$(echo "$json" | jq -r '.settings[] | select(.key == "workers") | .source + " " + .detail')" = "morca.toml [pipelines.toy]; unused: the pipeline has no tasks" ] \
    || fail "show --json's workers"
[ "$("$morca" config show --json | jq -r '[.pipelines[].pipeline] | join(",")')" = "daily,toy" ] || fail "show --json of all"
unset CONFIG_FALLBACK MORCA_RUN_ENV MORCA_TOY_FAIL
"$morca" register "$root/build/toy" >> "$log" 2>&1 || fail "register without --max-runs"
echo "ok   config show gives each value's source"

# A bad file is refused, saying where, and nothing changes.
before=$(q "SELECT config->>'hash' FROM orca.pipelines WHERE name = 'toy'")
printf '[pipelines.toy]\nworkrs = 4\n' > bad.toml
if "$morca" register --config bad.toml "$root/build/toy" > bad.out 2>&1; then fail "registered from a bad file"; fi
grep -q "bad.toml:2: \[pipelines.toy\] has no key workrs" bad.out || fail "the bad file's message: $(cat bad.out)"
printf '[pipelines.toy]\nworkers = "4..2"\n' > bad.toml
if "$morca" register --config bad.toml "$root/build/toy" > bad.out 2>&1; then fail "registered workers 4..2"; fi
grep -q "bad.toml:2: \[pipelines.toy\] workers: not a count or a range MIN..MAX: 4..2" bad.out || fail "the range's message: $(cat bad.out)"
[ "$(q "SELECT config->>'hash' FROM orca.pipelines WHERE name = 'toy'")" = "$before" ] || fail "the bad file changed the registration"
echo "ok   a bad file is refused with its line"

# morca config check: a file alone, with no database, for a project's CI.
check() { env -u MORCA_DATABASE_URL "$morca" config check "$@"; }
[ "$(check 2>&1)" = "morca.toml: ok, 1 pipeline" ] || fail "config check of morca.toml: $(check 2>&1)"
printf '[pipelines.toy]\nworkrs = 4\n' > bad.toml
if check bad.toml > bad.out 2>&1; then fail "config check passed a bad key"; fi
grep -q "bad.toml:2: \[pipelines.toy\] has no key workrs" bad.out || fail "config check's message: $(cat bad.out)"
printf '[defaults]\nhead_type = "m7g.large"\n[pipelines.toy]\nworker_type = "c7g.huge"\n' > bad.toml
if check bad.toml > bad.out 2>&1; then fail "config check passed c7g.huge"; fi
grep -q "bad.toml:4: \[pipelines.toy\] worker_type: the vCPUs of c7g.huge" bad.out || fail "the instance type's message: $(cat bad.out)"
grep -q "warning: bad.toml:2: \[defaults\] head_type: m7g.large isn't in morca's price table" bad.out || fail "no price warning: $(cat bad.out)"
printf '[pipelines.toy]\nsecrets = { A = "orca/github-token" }\n[pipelines.daily]\nsecrets = { B = "orca/missing" }\n' > sec.toml
check sec.toml > sec.out 2>&1 || fail "config check without --secrets reads none: $(cat sec.out)"
if MORCA_SECRET_FETCH=$root/tests/fake_secret.sh check sec.toml --secrets > sec.out 2>&1; then fail "a missing secret passed"; fi
grep -q "sec.toml:4: \[pipelines.daily\] secrets: B: can't read secret orca/missing" sec.out || fail "the missing secret's message: $(cat sec.out)"
grep -q "s3cr3t" sec.out && fail "config check printed a secret's value"
printf '[pipelines.toy]\nsecrets = { A = "orca/github-token" }\n' > sec.toml
[ "$(MORCA_SECRET_FETCH=$root/tests/fake_secret.sh check sec.toml --secrets 2>&1)" = "sec.toml: ok, 1 pipeline, 1 secret(s) readable" ] \
    || fail "config check --secrets: $(MORCA_SECRET_FETCH=$root/tests/fake_secret.sh check sec.toml --secrets 2>&1)"
echo "ok   config check checks a file, its instance types and secrets, with no database"
# A stack's overlay (#332), laid on morca.toml: by --overlay or
# MORCA_CONFIG_OVERLAY, for check, show --file and register.
printf '[pipelines.toy]\nworker_type = "c7g.2xlarge"\n' > ov.toml
[ "$(check --overlay ov.toml 2>&1)" = "morca.toml with ov.toml: ok, 1 pipeline" ] || fail "config check --overlay: $(check --overlay ov.toml 2>&1)"
[ "$(MORCA_CONFIG_OVERLAY=ov.toml check 2>&1)" = "morca.toml with ov.toml: ok, 1 pipeline" ] || fail "config check with MORCA_CONFIG_OVERLAY"
env -u MORCA_DATABASE_URL "$morca" config show --file --overlay ov.toml > shown.out 2>&1 || fail "config show --file: $(cat shown.out)"
grep -qx 'worker_type = "c7g.2xlarge"  # overlay ov.toml:2' shown.out || fail "show --file's overlaid value: $(cat shown.out)"
grep -qx 'head_type = "t4g.medium"' shown.out || fail "show --file's own value: $(cat shown.out)"
printf '[pipelines.toyy]\nmax_runs = 2\n' > bad-ov.toml
if check --overlay bad-ov.toml > bad.out 2>&1; then fail "an overlay with a pipeline the file hasn't passed"; fi
grep -q "bad-ov.toml:1: \[pipelines.toyy\] isn't a pipeline of morca.toml" bad.out || fail "the overlay's message: $(cat bad.out)"
MORCA_CONFIG_OVERLAY=ov.toml "$morca" register "$root/build/toy" > reg.out 2>&1 || fail "register with the overlay: $(cat reg.out)"
grep -q "registering with morca.toml (sha256 .*) and the overlay ov.toml" reg.out || fail "register's line: $(cat reg.out)"
[ "$(row toy)" = "- t4g.medium c7g.2xlarge 0 4 1 1" ] || fail "the toy with the overlay: $(row toy)"
[ "$(q "SELECT config->>'overlay' FROM orca.pipelines WHERE name = 'toy'")" = ov.toml ] || fail "the overlay isn't recorded"
"$morca" register "$root/build/toy" >> "$log" 2>&1 || fail "register without the overlay"
[ "$(row toy)" = "- t4g.medium c7g.xlarge 0 4 1 1" ] || fail "the toy without the overlay: $(row toy)"
# enabled = false: register with no binaries skips it.
printf '[pipelines.toy]\nenabled = false\n' > off.toml
if MORCA_PIPELINES_DIR=$root/build "$morca" register --overlay off.toml > reg.out 2>&1; then fail "registered a pipeline not enabled"; fi
grep -q "skipping toy (enabled = false)" reg.out || fail "register's skip: $(cat reg.out)"
grep -q "names no \[pipelines.<name>\] to register" reg.out || fail "register with none enabled: $(cat reg.out)"
[ "$(check --overlay off.toml 2>&1)" = "morca.toml with off.toml: ok, 1 pipeline (1 not enabled)" ] || fail "config check of one not enabled"
echo "ok   a stack's overlay is laid on morca.toml for check, show --file and register; enabled = false skips"
# morca config apps (#331): none in this file; an app's facts, a line each,
# the overlay laid on them; no database.
apps() { env -u MORCA_DATABASE_URL "$morca" config apps "$@"; }
[ -z "$(apps 2>&1)" ] || fail "config apps of a file with none: $(apps 2>&1)"
printf '[apps.console]\nport = 8080\nsecrets = { POSTHOG_KEY = "orca/posthog-key" }\n' > apps.toml
printf '[apps.console]\nenv = { A = "1" }\n' > apps-ov.toml
apps apps.toml --overlay apps-ov.toml > apps.out 2>&1 || fail "config apps: $(cat apps.out)"
[ "$(cat apps.out)" = "$(printf 'console port 8080\nconsole check /\nconsole lake false\nconsole memory_mb 0\nconsole env A=1\nconsole secret POSTHOG_KEY orca/posthog-key')" ] \
    || fail "config apps' lines: $(cat apps.out)"
[ "$(check apps.toml 2>&1)" = "apps.toml: ok, 0 pipelines, 1 app" ] || fail "config check of an app: $(check apps.toml 2>&1)"
(cd "$root/build" && [ -z "$(env -u MORCA_DATABASE_URL -u MORCA_CONFIG "$morca" config apps 2>&1)" ]) || fail "config apps without a file"
# --kube (#565): a Deployment and a Service per app, for kubectl apply.
apps apps.toml --kube --image img:1 > apps.yaml 2>&1 || fail "config apps --kube: $(cat apps.yaml)"
[ "$(grep -c '^kind: ' apps.yaml)" = 2 ] && grep -q 'secretKeyRef: {name: "morca-app-console", key: "POSTHOG_KEY"}' apps.yaml \
    || fail "config apps --kube: $(cat apps.yaml)"
if apps apps.toml --kube > apps.yaml 2>&1; then fail "config apps --kube without --image"; fi
echo "ok   config apps prints each app's facts, with no database"

# The env reaches the toy's runs on the local runner: 2024-02 fails as asked,
# 2024-01 doesn't; daily's runs don't get it.
export MORCA_LOGS=$root/build/config-logs
rm -rf "$MORCA_LOGS"
"$morca" backfill toy 2024-01..2024-02 >> "$log" 2>&1 || fail "backfill the toy"
i=0
until [ "$(q "SELECT count(*) FROM orca.runs WHERE pipeline = 'toy' AND status IN ('succeeded', 'failed')")" -eq 2 ]; do
    "$morca" tick >> "$log" 2>&1 || fail "tick"
    i=$((i + 1)); [ "$i" -lt 300 ] || fail "the toy's runs didn't end"; sleep 0.2
done
[ "$(q "SELECT status FROM orca.runs WHERE pipeline = 'toy' AND partitions = '2024-01'")" = succeeded ] || fail "2024-01"
[ "$(q "SELECT status FROM orca.runs WHERE pipeline = 'toy' AND partitions = '2024-02'")" = failed ] || fail "2024-02 didn't fail"
[ "$(q "SELECT count(*) FROM orca.attempts WHERE error LIKE '%failing 2024-02 as asked%'")" -ge 1 ] || fail "2024-02 failed otherwise"
echo "ok   a pipeline's env reaches its own runs on the local runner"

# The pipeline page shows the registration as config show does, with the
# flags over the file; the run page's settings link to it.
"$morca" register --max-runs 3 "$root/build/toy" >> "$log" 2>&1 || fail "register --max-runs for the page"
free_port uport
MORCA_UI_ADDR="127.0.0.1:$uport" "$morca" ui >> "$log" 2>&1 &
ui=$!
i=0
until curl -fs "http://127.0.0.1:$uport/" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
done
page=$(curl -fsS "http://127.0.0.1:$uport/pipelines/toy")
api=$(curl -fsS "http://127.0.0.1:$uport/api/pipelines/toy")
run=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'toy'")
runpage=$(curl -fsS "http://127.0.0.1:$uport/runs/$run")
kill "$ui"
wait "$ui" 2> /dev/null || true
ui=
echo "$page" | grep -q '<h2 id="config">Configuration</h2>' || fail "no Configuration on the pipeline page"
echo "$page" | grep -q "Registered from <code>morca.toml</code> @ <code>$(echo "$commit" | cut -c1-12)</code>" || fail "the page's registered-from"
echo "$page" | grep -q '<code>--max-runs 3</code>' || fail "the page doesn't show the override"
echo "$page" | grep -q '<td><code>head_type</code><span class="help">.*</span></span></td><td><code>t4g.medium</code></td><td><span class="term" data-tip="[^"]*" tabindex="0">morca.toml</span> \[defaults\]</td>' || fail "the page's head_type row"
# Each key has its help, a value from a fixed set its meaning, and the
# registration keeps each file value's line and the file's path in its
# checkout, for a link to the line.
echo "$page" | grep -q '<td><code>placement</code><span class="help">' || fail "placement has no help"
echo "$page" | grep -q '<th data-help="config">From<span class="help">' || fail "the From column has no help"
echo "$page" | grep -q '<td><code><span class="term" data-tip="On the scheduler' || fail "the placement value has no meaning"
[ "$(q "SELECT (config->'sources'->'head_type'->>'line') || ' ' || (config->>'repo_path') FROM orca.pipelines WHERE name = 'toy'")" = "2 morca.toml" ] \
    || fail "the registration's line and path: $(q "SELECT config FROM orca.pipelines WHERE name = 'toy'")"
[ "$(echo "$api" | jq -r '.config.overrides.max_runs + " " + .config.commit')" = "3 $commit" ] || fail "the page's JSON config: $(echo "$api" | jq .config)"
echo "$runpage" | grep -q 'href="/pipelines/toy#config"' || fail "the run's settings don't link the registration"
"$morca" register "$root/build/toy" >> "$log" 2>&1 || fail "register the toy back"
echo "ok   the pipeline page shows its registration; a run's settings link to it"

# config export: back to a file that registers the same.
"$morca" config export --out exported.toml >> "$log" 2>&1 || fail "config export"
cat exported.toml >> "$log"
if "$morca" config export --out exported.toml > /dev/null 2>&1; then fail "export replaced a file without --force"; fi
"$morca" config export --out - | grep -q '^\[pipelines.daily\]$' || fail "export to stdout"
grep -q '^workers = "0..4"$' exported.toml || fail "export's workers"
# Postgres keeps an object's keys shortest first.
grep -q '^env = { CONFIG_ONLY = "x y", MORCA_TOY_FAIL = "2024-02" }$' exported.toml || fail "export's env"
toy_before=$(row toy)
daily_before=$(row daily)
"$morca" register --config exported.toml "$root/build/toy" "$root/build/daily" >> "$log" 2>&1 || fail "register from the export"
[ "$(row toy)" = "$toy_before" ] && [ "$(row daily)" = "$daily_before" ] \
    || fail "the export registered otherwise: $(row toy) / $(row daily)"
echo "ok   config export writes a file that registers the same"

# morca aws register sends the file and its commit to the control instance's
# morca register, which reads it back.
b64=$(base64 < morca.toml | tr -d '\n')
"$morca" register --config-b64 "$b64" --config-commit "$commit" --config-name morca.toml "$root/build/toy" >> "$log" 2>&1 \
    || fail "register --config-b64"
[ "$(q "SELECT (config->>'hash') || ' ' || (config->>'commit') FROM orca.pipelines WHERE name = 'toy'")" = "$sha $commit" ] \
    || fail "--config-b64's hash and commit"

# On the ec2 runner: the env on the instance, over MORCA_RUN_ENV's, and in
# the pool's key.
dir=$root/build/fake-ec2-config
rm -rf "$dir"
mkdir -p "$dir"
free_port port
export MORCA_RUNNER=ec2 MORCA_EC2_MODE=direct MORCA_EC2_ENDPOINT="http://127.0.0.1:$port"
export AWS_REGION=us-east-2 AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test MORCA_EC2_AMI=ami-test
export MORCA_STALE_SECONDS=10 MORCA_START_SECONDS=60 MORCA_EC2_POOL_SECONDS=60
export MORCA_RUN_ENV=MORCA_TOY_FAIL,CONFIG_FALLBACK MORCA_TOY_FAIL=2024-03 CONFIG_FALLBACK=fb
python3 "$root/tests/fake_ec2.py" "$port" "$dir" >> "$log" 2>&1 &
fake=$!
i=0
until curl -s -o /dev/null "$MORCA_EC2_ENDPOINT/"; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "the stand-in EC2 didn't start"; sleep 0.1
done
"$morca" cancel toy @all >> "$log" 2>&1 || fail "cancel the failed run"
"$morca" register --image morca:test "$root/build/toy" >> "$log" 2>&1 || fail "register the toy for ec2"
ec2_run() {  # backfills the toy's $1 and waits for its run to end; prints its id
    "$morca" backfill toy "$1" >> "$log" 2>&1 || fail "backfill $1"
    r=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'toy'")
    i=0
    until [ "$(q "SELECT status IN ('succeeded', 'failed') FROM orca.runs WHERE id = $r")" = t ]; do
        "$morca" tick >> "$log" 2>&1 || fail "tick"
        i=$((i + 1)); [ "$i" -lt 600 ] || fail "run $r of $1 didn't end"; sleep 0.2
    done
    echo "$r"
}
r1=$(ec2_run 2024-03)
# MORCA_RUN_ENV says to fail 2024-03; the pipeline's own MORCA_TOY_FAIL wins.
[ "$(q "SELECT status FROM orca.runs WHERE id = $r1")" = succeeded ] || fail "MORCA_RUN_ENV's MORCA_TOY_FAIL won on ec2"
script=$(grep -l "^# morca run $r1 start" "$dir"/*.sh | head -1)
grep -q "^export MORCA_TOY_FAIL='2024-02'$" "$script" || fail "the instance's env: $(grep export "$script")"
grep -q "^export CONFIG_ONLY='x y'$" "$script" || fail "the instance's CONFIG_ONLY"
grep -q "^export CONFIG_FALLBACK='fb'$" "$script" || fail "MORCA_RUN_ENV's fallback"
[ "$(grep -c "^export MORCA_TOY_FAIL=" "$script")" -eq 1 ] || fail "MORCA_TOY_FAIL exported twice"
# The same env again: the pooled instance.
until_idle() {
    i=0
    until [ "$(q "SELECT count(*) FROM orca.instances WHERE run = $1 AND idle IS NOT NULL")" -ge 1 ]; do
        "$morca" tick >> "$log" 2>&1 || fail "tick"
        i=$((i + 1)); [ "$i" -lt 300 ] || fail "run $1's head didn't go idle"; sleep 0.2
    done
}
until_idle "$r1"
r2=$(ec2_run 2024-04)
[ "$(q "SELECT bool_and(pooled) FROM orca.instances WHERE run = $r2")" = t ] || fail "the same env didn't take the pooled head"
until_idle "$r2"
# A new env: a new instance, of another key.
sed -i.bak 's/CONFIG_ONLY = "x y"/CONFIG_ONLY = "z"/' morca.toml
"$morca" register --image morca:test "$root/build/toy" >> "$log" 2>&1 || fail "register the new env"
r3=$(ec2_run 2024-05)
[ "$(q "SELECT bool_or(pooled) FROM orca.instances WHERE run = $r3")" = f ] || fail "a new env reused a pooled instance"
[ "$(q "SELECT count(DISTINCT pool_key) FROM orca.instances WHERE run IN ($r1, $r3)")" -eq 2 ] || fail "the env isn't in the pool's key"
[ "$(q "SELECT spec->'env'->>'CONFIG_ONLY' FROM orca.runs WHERE id = $r3")" = z ] || fail "the run's spec lacks the env"
echo "ok   on ec2 the env is on the instance, over MORCA_RUN_ENV's, and in the pool's key"
stop

# No paths: every table of the file, from pipelines/ next to it or
# MORCA_PIPELINES_DIR; outside a git checkout, MORCA_COMMIT and MORCA_SOURCE are
# the commit, and git says nothing.
np=$(mktemp -d)
mkdir "$np/pipelines" "$np/elsewhere"
cp "$root/build/toy" "$np/pipelines/toy"
cp "$root/build/daily" "$np/pipelines/daily"
cat > "$np/morca.toml" << 'EOF'
[defaults]
max_runs = 1

[pipelines.toy]

[pipelines.daily]
EOF
cd "$np"
MORCA_COMMIT=0123456789abcdef0123456789abcdef01234567 MORCA_SOURCE=https://github.com/example/census \
    "$morca" register --config morca.toml > reg.out 2> reg.err || fail "register with no paths: $(cat reg.err)"
grep -q "registered toy" reg.out && grep -q "registered daily" reg.out || fail "no paths registered: $(cat reg.out)"
! grep -q "fatal" reg.err || fail "git's stderr leaked: $(cat reg.err)"
[ "$(q "SELECT (config->>'commit') || ' ' || (config->>'source') FROM orca.pipelines WHERE name = 'toy'")" = "0123456789abcdef0123456789abcdef01234567 https://github.com/example/census" ] \
    || fail "MORCA_COMMIT and MORCA_SOURCE weren't recorded"
# Without them, no commit, and still no noise.
"$morca" register --config morca.toml > reg.out 2> reg.err || fail "register without MORCA_COMMIT"
! grep -q "fatal" reg.err || fail "git's stderr leaked: $(cat reg.err)"
[ "$(q "SELECT config->>'commit' FROM orca.pipelines WHERE name = 'toy'")" = "" ] || fail "a commit from nowhere"
# Bare, as on the server (docker exec scheduler morca register): the file
# from MORCA_CONFIG, else ./morca.toml.
"$morca" register > reg.out 2> reg.err || fail "bare register: $(cat reg.out reg.err)"
grep -q "registered toy" reg.out && grep -q "registered daily" reg.out || fail "bare register: $(cat reg.out)"
(cd / && MORCA_CONFIG=$np/morca.toml "$morca" register > "$np/reg.out" 2>&1) || fail "bare register, MORCA_CONFIG: $(cat reg.out)"
grep -q "registered toy" reg.out || fail "bare register, MORCA_CONFIG: $(cat reg.out)"
# MORCA_PIPELINES_DIR beats pipelines/ next to the file.
mv pipelines elsewhere/p
MORCA_PIPELINES_DIR=$np/elsewhere/p "$morca" register --config morca.toml > reg.out 2>&1 || fail "MORCA_PIPELINES_DIR: $(cat reg.out)"
# Neither: refused, saying so.
if "$morca" register --config morca.toml > reg.out 2>&1; then fail "registered with no pipelines directory"; fi
grep -q "MORCA_PIPELINES_DIR" reg.out || fail "the refusal doesn't say how: $(cat reg.out)"
# A missing binary: an error naming it, and nothing registered.
mv elsewhere/p pipelines
cat > bad.toml << 'EOF'
[pipelines.toy]
max_runs = 3

[pipelines.ghost]
EOF
if "$morca" register --config bad.toml > reg.out 2>&1; then fail "registered with a binary missing"; fi
grep -q "ghost" reg.out || fail "the error doesn't name ghost: $(cat reg.out)"
[ "$(q "SELECT max_runs FROM orca.pipelines WHERE name = 'toy'")" = 1 ] || fail "something was registered"
# Paths given explicitly still work.
"$morca" register --config morca.toml pipelines/toy > reg.out 2>&1 || fail "explicit path: $(cat reg.out)"
grep -q "registered toy" reg.out || fail "explicit path not registered"
echo "ok   register with no paths registers the file's pipelines; the commit from MORCA_COMMIT outside git"
cd "$root"
rm -rf "$np"
echo "ok   config"
