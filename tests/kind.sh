#!/bin/sh
# morca on a kind cluster (deploy/), each run on a cluster of its own
# (morca.kube). Builds the image, loads it, applies the manifests, and with
# the scheduler's clock fixed just after a fire:
#
# - the toy, registered from the image, is fired, runs as a driver Job and
#   succeeds, morca ui shows it and the driver log the scheduler kept, its
#   driver pod's samples are kept apart from that log, and nothing
#   labelled with it is left;
# - fanout's runs get a head and 3 workers each, and the tasks of a run
#   reach all 3; every pod's samples are kept;
# - fanout, registered with a secret (MORCA_SECRET_FETCH stands in for
#   Secrets Manager), gets it from a Secret of the run's own: the Job and
#   Pods hold only its name, its step sees the value (its length is
#   logged), its driver and tasks print it, yet no pod log, no log under
#   MORCA_LOGS (the driver log the scheduler keeps, the attempts') and not
#   the scheduler's own holds it, and the Secret is gone with the run;
# - a fanout driver pod deleted mid-run is resumed on a new cluster (start
#   2) and succeeds, and the first cluster is gone;
# - with MORCA_VCPU_BUDGET room for one fanout cluster, a toy run queued
#   beside two fanout runs never runs at the same time as either;
# - a pod and a Secret a killed scheduler left behind are deleted when it
#   starts again.
#
# KEEP_CLUSTER=1 leaves a cluster this made; KIND_CLUSTER names one to use.
# Needs docker, kind, kubectl, curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build
cluster=${KIND_CLUSTER:-morca}
export KUBECONFIG="$PWD/build/kind-$cluster.yaml"
fwd=
made=
cleanup() {
    [ -z "$fwd" ] || kill "$fwd" 2> /dev/null || true
    if [ -n "$made" ] && [ "${KEEP_CLUSTER:-0}" != 1 ]; then
        kind delete cluster --name "$cluster"
    fi
}
trap cleanup EXIT
fail() {
    echo "FAIL: $*"
    kubectl -n morca get pods -o wide || true
    kubectl -n morca-runs get pods,jobs,services,secrets -o wide || true
    kubectl -n morca logs deploy/morca-scheduler -c scheduler --tail=40 || true
    exit 1
}
q() { kubectl -n morca exec statefulset/postgres -- psql -U orca -d orca -Atc "$1"; }
runs() { kubectl -n morca-runs get pods,jobs,services,secrets -l "$1" -o name 2> /dev/null; }
morca_cli() { kubectl -n morca exec deploy/morca-scheduler -c scheduler -- "$@"; }
# Until the SQL says t, for up to $2 seconds.
until_true() {
    i=0
    until [ "$(q "$1")" = t ]; do
        i=$((i + 1)); [ "$i" -lt "$2" ] || fail "waited for: $1"; sleep 1
    done
}
gone() {
    i=0
    while [ -n "$(runs "$1")" ]; do
        i=$((i + 1)); [ "$i" -lt 90 ] || fail "still there: $(runs "$1" | tr '\n' ' ')"; sleep 1
    done
}

docker build -f deploy/Dockerfile -t morca:dev .
if ! kind get clusters 2> /dev/null | grep -qx "$cluster"; then
    kind create cluster --name "$cluster" --kubeconfig "$KUBECONFIG" --wait 120s
    made=1
else
    kind get kubeconfig --name "$cluster" > "$KUBECONFIG"
fi
kind load docker-image morca:dev --name "$cluster"

kubectl delete namespace morca morca-runs --ignore-not-found --wait
kubectl apply -f deploy/k8s/morca.yaml -f deploy/k8s/runs.yaml
kubectl -n morca rollout status statefulset/postgres --timeout=180s || fail "postgres"
# The clock just after the toy's fire for January (03:00 UTC on 2 February);
# small pods, room for one fanout cluster (100m driver and head, 3 × 100m
# workers) and no more; a run whose heartbeat stops is restarted soon. A
# secret's value is printf's, from its ID, and fanout prints and logs the
# one it's given.
value=kind-s3cr3t-orca/kind-token
kubectl -n morca set env deployment/morca-scheduler -c scheduler \
    MORCA_NOW=2024-02-02T03:00Z MORCA_STALE_SECONDS=10 \
    MORCA_DRIVER_CPU=100m MORCA_HEAD_CPU=100m MORCA_WORKER_CPU=100m MORCA_POD_MEMORY=128Mi \
    MORCA_VCPU_BUDGET=550m MORCA_FANOUT_SHOW_HOST=1 MORCA_FANOUT_SLEEP=1 \
    MORCA_SECRET_FETCH="printf kind-s3cr3t-%s" MORCA_FANOUT_SECRET=GITHUB_TOKEN \
    MORCA_RUN_ENV=MORCA_FANOUT_SHOW_HOST,MORCA_FANOUT_SLEEP,MORCA_FANOUT_SECRET
kubectl -n morca rollout status deployment/morca-scheduler --timeout=180s || fail "the scheduler"
morca_cli env MORCA_NOW=2024-02-01T00:00Z morca register --image morca:dev /opt/morca/pipelines/toy \
    || fail "register the toy"

free_port port
kubectl -n morca port-forward svc/morca-ui "$port:8270" > build/kind-forward.log 2>&1 &
fwd=$!
base="http://127.0.0.1:$port"
json() { curl -fsS -H 'Accept: application/json' "$base$1"; }
i=0
until [ "$(json '/runs?pipeline=toy' 2> /dev/null | jq -r '[.runs[] | select(.status == "succeeded")] | length')" = 1 ]; do
    i=$((i + 1)); [ "$i" -lt 180 ] || fail "no succeeded toy run on the UI"; sleep 1
done
toy=$(json '/runs?pipeline=toy' | jq -r '.runs[0].id')
[ "$(json "/runs/$toy" | jq -r '.run | "\(.trigger) \(.partitions)"')" = "schedule 2024-01" ] \
    || fail "run $toy: $(json "/runs/$toy")"
[ "$(json "/runs/$toy" | jq .cpu_millis)" = 100 ] || fail "the toy's CPU: $(json "/runs/$toy" | jq .cpu_millis)"
gone "orca.run=$toy"
curl -fsS "$base/runs/$toy/driver.log" | grep -qx "run succeeded" || fail "the toy's driver log"
# Its driver pod's samples (morca.sample), kept beside the driver log and
# out of it.
morca_cli sh -c "cat /var/orca/logs/toy/$toy/metrics/morca-$toy-1-*.jsonl" > build/kind-toy-metrics.jsonl \
    || fail "the toy's metrics"
python3 tests/metrics_ok.py build/kind-toy-metrics.jsonl > /dev/null || fail "the toy's metrics"
! curl -fsS "$base/runs/$toy/driver.log" | grep -q "^orca-sample" || fail "samples in the toy's driver log"
echo "ok   the toy ran as a driver Job, its driver log and metrics were kept, and nothing of it is left"

# Two fanout runs, one at a time, and a toy run beside them.
morca_cli morca register --image morca:dev --secret GITHUB_TOKEN=orca/kind-token /opt/morca/pipelines/fanout > /dev/null \
    || fail "register fanout"
morca_cli morca backfill fanout 2024-01..2024-02 > /dev/null || fail "backfill fanout"
morca_cli morca backfill toy 2024-03 > /dev/null || fail "backfill the toy"
f1=$(q "SELECT min(id) FROM orca.runs WHERE pipeline = 'fanout'")
f2=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'fanout'")

# The first: its tasks on all 3 workers, read from the workers' logs while
# they're up.
until_true "SELECT status = 'running' AND heartbeat IS NOT NULL FROM orca.runs WHERE id = $f1" 180
[ "$(runs "orca.run=$f1,orca.role=worker" | grep -c '^pod/')" -eq 3 ] || fail "3 workers for run $f1"
[ "$(runs "orca.run=$f1,orca.role=head" | wc -l | tr -d ' ')" -eq 2 ] || fail "a head pod and service for run $f1"
# Its secret: in its own Secret, and only there.
[ "$(kubectl -n morca-runs get secret "morca-$f1-1-secrets" -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d)" = "$value" ] \
    || fail "run $f1's Secret"
! kubectl -n morca-runs get jobs,pods -l "orca.run=$f1" -o json | grep -qF "$value" \
    || fail "run $f1's Job or Pods hold its secret's value"
hosts=
i=0
: > build/kind-pods.log
while [ "$(q "SELECT status FROM orca.runs WHERE id = $f1")" = running ]; do
    kubectl -n morca-runs logs -l "orca.run=$f1" --prefix --tail=-1 --max-log-requests=10 \
        >> build/kind-pods.log 2> /dev/null || true
    hosts=$( (echo "$hosts"; kubectl -n morca-runs logs -l "orca.run=$f1,orca.role=worker" --prefix --tail=-1 2> /dev/null \
        | sed -n 's|^\[pod/\([^/]*\)/.*trips on .*|\1|p') | sort -u | grep . || true)
    i=$((i + 1)); [ "$i" -lt 300 ] || fail "run $f1 didn't end"; sleep 1
done
[ "$(q "SELECT status FROM orca.runs WHERE id = $f1")" = succeeded ] || fail "run $f1"
[ "$(echo "$hosts" | wc -l | tr -d ' ')" -eq 3 ] || fail "run $f1's tasks reached $(echo "$hosts" | tr '\n' ' ')"

# The second, which starts as the first ends: its driver deleted mid-run.
until_true "SELECT status = 'running' AND heartbeat IS NOT NULL FROM orca.runs WHERE id = $f2" 180
sleep 3
[ "$(q "SELECT status FROM orca.runs WHERE id = $f2")" = running ] || fail "run $f2 ended before its driver could be deleted"
kubectl -n morca-runs delete pod -l "orca.run=$f2,orca.role=driver" --wait=false > /dev/null
gone "orca.run=$f1"
# A metrics file per pod: the driver's, the head's and the 3 workers'.
pods=$(morca_cli sh -c "ls /var/orca/logs/fanout/$f1/metrics" | while read -r f; do
    case "$f" in (*-head.jsonl) echo head ;; (*-worker-*.jsonl) echo worker ;; (*) echo driver ;; esac
done | sort | tr '\n' ' ')
[ "$pods" = "driver head worker worker worker " ] || fail "run $f1's metrics: $pods"
for f in $(morca_cli sh -c "cd /var/orca/logs/fanout/$f1/metrics && ls"); do
    morca_cli cat "/var/orca/logs/fanout/$f1/metrics/$f" > "build/kind-$f"
    case "$f" in (*-head.jsonl | *-worker-*) rss=--rss ;; (*) rss= ;; esac
    python3 tests/metrics_ok.py $rss "build/kind-$f" > /dev/null || fail "run $f1's $f"
done
echo "ok   fanout's run had its own head and 3 workers, and its tasks reached all 3, each with metrics"
# Its secret reached its step, driver and tasks, masked in every log.
morca_cli grep -rq "secret \*\*\* of length ${#value}" "/var/orca/logs/fanout/$f1" \
    || fail "run $f1's step didn't see its secret"
grep -q "worker-.*secret \*\*\*$" build/kind-pods.log || fail "run $f1's workers' logs: no masked secret"
curl -fsS "$base/runs/$f1/driver.log" | grep -q "^secret \*\*\*$" || fail "run $f1's driver log: no masked secret"
! grep -qF "$value" build/kind-pods.log || fail "run $f1's pod logs hold its secret's value"
! morca_cli grep -rqF "$value" /var/orca/logs || fail "a log under MORCA_LOGS holds the secret's value"
! kubectl -n morca logs deploy/morca-scheduler -c scheduler | grep -qF "$value" \
    || fail "the scheduler's log holds the secret's value"
echo "ok   fanout's run got its secret from a Secret of its own, no log holds it, and the Secret went with the run"
until_true "SELECT status = 'succeeded' FROM orca.runs WHERE id = $f2" 300
[ "$(q "SELECT starts FROM orca.runs WHERE id = $f2")" -eq 2 ] || fail "run $f2 started $(q "SELECT starts FROM orca.runs WHERE id = $f2") times"
gone "orca.run=$f2"
echo "ok   a run whose driver was deleted resumed on a new cluster and succeeded"

# The budget: the toy run never beside a fanout run.
until_true "SELECT status = 'succeeded' FROM orca.runs WHERE pipeline = 'toy' AND partitions = '2024-03'" 180
[ "$(q "SELECT count(*) FROM orca.runs t JOIN orca.runs f ON f.pipeline = 'fanout' WHERE t.pipeline = 'toy' AND t.partitions = '2024-03' AND t.started < f.ended AND f.started < t.ended")" -eq 0 ] \
    || fail "the toy ran beside a fanout run over the budget"
echo "ok   the budget kept the toy waiting"

# What a killed scheduler left behind.
kill "$fwd"; fwd=
kubectl -n morca scale deployment/morca-scheduler --replicas=0
kubectl -n morca rollout status deployment/morca-scheduler --timeout=60s
# With requests, which the namespace's ResourceQuota insists on.
kubectl apply -f - > /dev/null << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: morca-999-1-worker-0
  namespace: morca-runs
  labels: {orca.run: "999", orca.start: "1", orca.role: worker}
spec:
  restartPolicy: Never
  containers:
    - name: main
      image: morca:dev
      imagePullPolicy: IfNotPresent
      command: [sleep, "600"]
      resources: {requests: {cpu: 10m, memory: 16Mi}}
---
apiVersion: v1
kind: Secret
metadata:
  name: morca-999-1-secrets
  namespace: morca-runs
  labels: {orca.run: "999", orca.start: "1", orca.role: secrets}
stringData: {GITHUB_TOKEN: left-behind}
EOF
kubectl -n morca scale deployment/morca-scheduler --replicas=1
kubectl -n morca rollout status deployment/morca-scheduler --timeout=180s || fail "the scheduler again"
gone "orca.run=999"
[ -z "$(runs orca.run)" ] || fail "left over: $(runs orca.run | tr '\n' ' ')"
echo "ok   kind"
