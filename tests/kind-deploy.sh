#!/bin/sh
# deploy/k8s/deploy.sh on a kind cluster (#562), with a project's image at
# three tags: morca:dev with the toy and longpoll (tests/outdated_pipeline.mojo,
# which hands over once it's outdated), and a morca.toml giving longpoll a
# concurrency key, as the census's mojo_live has.
#
# - without HANDOVER_WAIT_SECONDS the first deploy stops before deploying,
#   naming the key; with it, it deploys 1.0.0: the scheduler gets
#   MORCA_OVERLAP, MORCA_DRAIN_SECONDS and MORCA_HANDOVER_WAIT_SECONDS,
#   the pipelines are registered from the image's morca.toml with the key,
#   and the check passes;
# - with a longpoll run going and a second waiting on its key, --dry-run of
#   1.1.0 prints the plan and changes nothing (Deployments, ConfigMaps,
#   pods, jobs, the pipelines and the runs as they were);
# - 1.1.0 is deployed over them: its before step confirmed, nothing paused,
#   a backup Job first, the old scheduler instance ended and the new one
#   leading, the going run hands over (it sees it's outdated and ends) and
#   the waiting one starts on the new code; its after step ran;
# - 1.2.0, whose image drops the toy's binary, fails the check and is
#   rolled back to 1.1.0 (paused and waited for, then unpaused), which is
#   deployed and checked again.
#
# KEEP_CLUSTER=1 leaves a cluster this made; KIND_CLUSTER names one to use.
# Needs docker, kind and kubectl.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
cluster=${KIND_CLUSTER:-morca-deploy}
export KUBECONFIG="$PWD/build/kind-$cluster.yaml"
made=
cleanup() {
    if [ -n "$made" ] && [ "${KEEP_CLUSTER:-0}" != 1 ]; then
        kind delete cluster --name "$cluster"
    fi
}
trap cleanup EXIT
log=build/kind-deploy.log
fail() {
    echo "FAIL: $*"
    tail -n 60 "$log" 2> /dev/null || true
    kubectl -n morca get pods -o wide || true
    kubectl -n morca-runs get pods,jobs -o wide || true
    kubectl -n morca logs deploy/morca-scheduler -c scheduler --tail=40 || true
    exit 1
}
q() { kubectl -n morca exec statefulset/postgres -- psql -U orca -d orca -Atc "$1"; }
morca_cli() { kubectl -n morca exec deploy/morca-scheduler -c scheduler -- morca "$@"; }
until_true() {
    i=0
    until [ "$(q "$1" 2> /dev/null)" = t ]; do
        i=$((i + 1)); [ "$i" -lt "$2" ] || fail "waited for: $1"; sleep 1
    done
}
has() { grep -q -- "$1" "$log" || fail "no '$1' in the deploy's output"; }
rec() { kubectl -n morca get configmap morca-deployed -o "jsonpath={.data.$1}"; }
deploy() { sh deploy/k8s/deploy.sh "$@" > "$log" 2>&1; }

# The image: deploy/Dockerfile with longpoll beside the toy, from a copy of
# the tree whose examples/ has it.
ctx=build/kind-deploy-ctx
rm -rf "$ctx"
mkdir -p "$ctx/examples"
cp -R src bin pixi.toml pixi.lock "$ctx/"
cp examples/toy.mojo "$ctx/examples/"
cp tests/outdated_pipeline.mojo "$ctx/examples/longpoll.mojo"
docker build -f deploy/Dockerfile --build-arg PIPELINES="examples/toy.mojo examples/longpoll.mojo" -t morca:dev "$ctx"
docker build -f deploy/k8s/minio.Dockerfile -t morca-minio:dev deploy/k8s

# The project at 1.0.0, 1.1.0 (other code, upgrade steps) and 1.2.0 (no toy).
p=build/kind-deploy-proj
rm -rf "$p"
mkdir -p "$p/1.0.0" "$p/1.1.0" "$p/1.2.0"
cat > "$p/1.0.0/morca.toml" << 'EOF'
[pipelines.longpoll]
concurrency = { key = "live", limit = 1 }
env = { OUTDATED_OUT = "/dev/null", OUTDATED_HANDOVER = "2024-01 2024-02", OUTDATED_STOP = "/tmp/never" }

[pipelines.toy]
EOF
cat > "$p/1.0.0/Dockerfile" << 'EOF'
FROM morca:dev
COPY morca.toml /opt/morca/morca.toml
ENV MORCA_CONFIG=/opt/morca/morca.toml MORCA_PIPELINES_DIR=/opt/morca/pipelines \
    MORCA_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
cat > "$p/1.1.0/upgrade.toml" << 'EOF'
[[version]]
version = "1.1.0"

[[version.step]]
id = "1.1.0-note"
when = "before"
manual = "Nothing to do: the kind test confirms it."

[[version.step]]
id = "1.1.0-pause"
when = "after"
run = "morca pause toy"
EOF
cat > "$p/1.1.0/Dockerfile" << 'EOF'
FROM morca-proj:1.0.0
COPY upgrade.toml /opt/morca/upgrade.toml
ENV MORCA_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
sed '/^\[pipelines.toy\]/d' "$p/1.0.0/morca.toml" > "$p/1.2.0/morca.toml"
cat > "$p/1.2.0/Dockerfile" << 'EOF'
FROM morca-proj:1.1.0
COPY morca.toml /opt/morca/morca.toml
RUN rm /opt/morca/pipelines/toy
ENV MORCA_COMMIT=cccccccccccccccccccccccccccccccccccccccc
EOF
for t in 1.0.0 1.1.0 1.2.0; do docker build -q -t "morca-proj:$t" "$p/$t" > /dev/null; done

if ! kind get clusters 2> /dev/null | grep -qx "$cluster"; then
    kind create cluster --name "$cluster" --kubeconfig "$KUBECONFIG" --wait 120s
    made=1
else
    kind get kubeconfig --name "$cluster" > "$KUBECONFIG"
fi
kind load docker-image morca-minio:dev morca-proj:1.0.0 morca-proj:1.1.0 morca-proj:1.2.0 --name "$cluster"
kubectl delete namespace morca morca-runs --ignore-not-found --wait

# The settings: kind's Secrets first, small pods.
cat > build/kind-deploy.env << 'EOF'
MORCA_IMAGE=morca-proj
DRAIN_SECONDS=600
HANDOVER_WAIT_SECONDS=600
MANIFESTS="deploy/k8s/local-secrets.yaml deploy/k8s/morca.yaml deploy/k8s/runs.yaml deploy/k8s/postgres-backup.yaml deploy/k8s/ui.yaml"
EXTRA_ENV="MORCA_DRIVER_CPU=100m MORCA_HEAD_CPU=100m MORCA_WORKER_CPU=100m MORCA_POD_MEMORY=128Mi"
HEALTH_TIMEOUT=240
EOF
sed '/^HANDOVER_WAIT_SECONDS=/d' build/kind-deploy.env > build/kind-deploy-nokey.env
export KUBE_ENV=build/kind-deploy.env

# A first deploy, refused without the handover wait limit, then deployed.
KUBE_ENV=build/kind-deploy-nokey.env deploy --yes 1.0.0 && fail "deployed a concurrency key without HANDOVER_WAIT_SECONDS"
has "declares concurrency keys (.*longpoll.*), and HANDOVER_WAIT_SECONDS isn't set"
! kubectl -n morca get deployment morca-scheduler > /dev/null 2>&1 || fail "a scheduler was deployed without HANDOVER_WAIT_SECONDS"
deploy --yes 1.0.0 || fail "the first deploy"
has "a first deploy: nothing runs yet"
has "deploy.sh: check: all ok"
env=$(kubectl -n morca exec deploy/morca-scheduler -c scheduler -- env)
for v in MORCA_OVERLAP=on MORCA_DRAIN_SECONDS=600 MORCA_HANDOVER_WAIT_SECONDS=600 MORCA_IMAGE=morca-proj:1.0.0; do
    echo "$env" | grep -qxF "$v" || fail "the scheduler's env has no $v"
done
[ "$(q "SELECT string_agg(name || '=' || coalesce(concurrency_key, '-'), ' ' ORDER BY name) FROM orca.pipelines")" = "longpoll=live toy=-" ] \
    || fail "the pipelines: $(q "SELECT name, concurrency_key FROM orca.pipelines")"
[ "$(rec tag)" = 1.0.0 ] || fail "the recorded tag: $(rec tag)"
echo "ok   a first deploy needs HANDOVER_WAIT_SECONDS for a key; then 1.0.0 is deployed, registered from its morca.toml and checked"

# A longpoll run going, and a second waiting on its key.
run1=$(morca_cli start longpoll 2024-01 | sed -n 's/^queued run //p')
[ -n "$run1" ] || fail "morca start longpoll 2024-01"
until_true "SELECT status = 'running' FROM orca.runs WHERE id = $run1" 180
run2=$(morca_cli start longpoll 2024-02 | sed -n 's/^queued run //p')
until_true "SELECT waits_on = $run1 FROM orca.runs WHERE id = $run2" 60

# A dry run of 1.1.0 changes nothing.
snap() {
    kubectl -n morca get deployments,statefulsets,cronjobs -o 'jsonpath={range .items[*]}{.metadata.name}={.metadata.generation} {end}'
    kubectl -n morca get configmaps -o 'jsonpath={range .items[*]}{.metadata.name}={.metadata.resourceVersion} {end}'
    kubectl get pods,jobs -n morca -o name
    kubectl get pods,jobs -n morca-runs -o name
    q "SELECT name, paused, version FROM orca.pipelines ORDER BY name"
    q "SELECT id, status, version FROM orca.runs ORDER BY id"
}
before=$(snap)
deploy --dry-run --yes 1.1.0 || fail "the dry run"
after=$(snap)
[ "$before" = "$after" ] || fail "the dry run changed something: $(printf '%s\n' "$before" > build/kind-deploy-before; printf '%s\n' "$after" | diff build/kind-deploy-before - || true)"
has "scheduler replace image morca-proj:1.0.0 -> morca-proj:1.1.0"
has "+ kubectl -n morca create job morca-backup-deploy-"
has "dry run: nothing was changed"
echo "ok   --dry-run prints the plan and changes nothing"

# 1.1.0 over the going run: it hands over, the waiting one starts on 1.1.0.
deploy --yes --confirmed 1.1.0-note 1.1.0 || fail "the deploy of 1.1.0"
has "\[1.1.0-note\] confirmed"
has "the new scheduler takes over from the old one"
has "backup s3://morca/backups/pg/.*\.dump"
has "ran 'morca pause toy' for 1.1.0-pause"
has "deploy.sh: check: all ok"
! grep -q "deploy.sh: paused" "$log" || fail "the overlapping deploy paused pipelines"
until_true "SELECT status = 'succeeded' FROM orca.runs WHERE id = $run1" 120
until_true "SELECT status IN ('running', 'succeeded') FROM orca.runs WHERE id = $run2" 120
[ "$(q "SELECT a.version <> b.version AND b.started >= a.ended FROM orca.runs a, orca.runs b WHERE a.id = $run1 AND b.id = $run2")" = t ] \
    || fail "run $run2 didn't start on new code after run $run1 handed over: $(q "SELECT id, version, started, ended FROM orca.runs ORDER BY id")"
[ "$(q "SELECT count(*) || ' ' || max(image) FROM orca.schedulers WHERE ended IS NULL")" = "1 morca-proj:1.1.0" ] \
    || fail "the scheduler instances: $(morca_cli scheduler status)"
[ "$(q "SELECT paused FROM orca.pipelines WHERE name = 'toy'")" = t ] || fail "the after step didn't pause the toy"
[ "$(rec tag) $(rec previous)" = "1.1.0 1.0.0" ] || fail "the recorded tags: $(rec tag) $(rec previous)"
echo "ok   1.1.0 over a going run: backed up, not paused, the run hands over and the one waiting on its key starts on 1.1.0"

# 1.2.0 fails the check (no toy binary): rolled back to 1.1.0.
deploy --yes 1.2.0 && fail "1.2.0 passed its check"
has "check: FAIL  pipelines: not in the scheduler's image: toy"
has "rolling back to 1.1.0"
has "so it rolled back to 1.1.0, which is deployed and checked"
[ "$(kubectl -n morca get deployment morca-scheduler -o 'jsonpath={.spec.template.spec.containers[0].image}')" = morca-proj:1.1.0 ] \
    || fail "the scheduler isn't on 1.1.0 again"
[ "$(rec tag) $(rec previous)" = "1.1.0 1.2.0" ] || fail "the recorded tags: $(rec tag) $(rec previous)"
[ "$(q "SELECT paused FROM orca.pipelines WHERE name = 'longpoll'")" = f ] || fail "the rollback left longpoll paused"
echo "ok   1.2.0 fails its check and is rolled back to 1.1.0, deployed and checked"
