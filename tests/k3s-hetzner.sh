#!/bin/sh
# morca on a real two-node k3s cluster on Hetzner (#559): two CAX (ARM)
# servers made for the test and deleted at its end, the project's image from
# ghcr, and a bucket of its own on Hetzner Object Storage for the warehouse
# and the logs. Not run by CI: it costs money (a few cents) and needs the
# stack's hcloud context and Object Storage keys. Ask before each run.
#
# Node a is the k3s server, with Postgres, the scheduler and morca ui, and
# a run's dista head (MORCA_KUBE_HEAD_NODE_SELECTOR); it's tainted
# PreferNoSchedule, so run pods go to node b while it's there. Node b is
# tainted NoSchedule, which only the drivers and workers tolerate
# (MORCA_KUBE_DRIVER_TOLERATIONS, MORCA_KUBE_WORKER_TOLERATIONS), so nothing
# else lands on it. Checks:
#
# - a census pipeline (gharchive, one day) runs across both nodes, its head
#   on a and its driver and workers on b, pulled from ghcr (with the pull
#   secret MORCA_KUBE_PULL_SECRET when GHCR_TOKEN is set), and succeeds;
#   its logs and tables are in the bucket and nothing of it is left;
# - a second run, of a few days, with node b powered off mid-run (hcloud server
#   poweroff), is started again (start 2) once its heartbeat goes stale,
#   on node a, workers included, and succeeds;
# - the first start's pods, stuck Terminating on the lost node, are swept
#   (fails until #575: morca doesn't force-delete them yet).
#
# Everything it made (servers, firewall, SSH key, bucket) is deleted on every
# exit, failed or not, and it prints what the servers cost. A run that was
# killed too hard to clean up is cleaned up by `tests/k3s-hetzner.sh
# --cleanup`, which deletes whatever any run of it left (by the label
# morca-k3s-test and the bucket prefix morca-k3s-test-).
#
# Settings, from the environment (docs/hetzner.md#a-k3s-test):
#   HCLOUD_CONTEXT     the hcloud context (project) to make the servers in
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#                      that project's Object Storage keys
#   LOCATION           nbg1; S3_ENDPOINT and S3_REGION follow it
#   SERVER_TYPE        cax21 (4 vCPU, 8 GB); SERVER_IMAGE ubuntu-24.04
#   MORCA_IMAGE        ghcr.io/morca-dev/census:1.17.0
#   PIPELINE           gharchive; DAY1 the partition of its first run (morca
#                      start) and DAYS2 the KEYS (6) days of its second, a
#                      backfill, which the scheduler retries, unlike a start
#                      (a day takes about 20 s, so LOSE_AFTER, 20 s, is mid-run);
#                      WORKERS (2) its dista workers (gharchive's code asks for 8)
#   GHCR_USER, GHCR_TOKEN  a pull secret for ghcr, optional for a public image
#   K3S_VERSION        a k3s release (v1.34.2+k3s1); the stable channel if unset
#   ADMIN_IP           the IPv4 address SSH and the API are open to (this host's)
#   KEEP=1             leaves everything up (and paid for) for a look; then
#                      --cleanup deletes it
#
# Needs hcloud, kubectl, the AWS CLI, jq, ssh, ssh-keygen, openssl and curl.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
LABEL=morca-k3s-test
: "${LOCATION:=nbg1}"
: "${S3_ENDPOINT:=https://$LOCATION.your-objectstorage.com}"
: "${S3_REGION:=$LOCATION}"
: "${SERVER_TYPE:=cax21}"
: "${SERVER_IMAGE:=ubuntu-24.04}"
: "${MORCA_IMAGE:=ghcr.io/morca-dev/census:1.17.0}"
: "${PIPELINE:=gharchive}"
: "${DAY1:=2026-11-01}"
: "${DAYS2:=2026-11-02..2026-11-07}"
: "${KEYS:=6}"
: "${WORKERS:=2}"
export AWS_EC2_METADATA_DISABLED=true
s3() { aws --endpoint-url "$S3_ENDPOINT" --region "$S3_REGION" "$@"; }
log() { echo "k3s-hetzner: $*"; }

for c in hcloud kubectl aws jq ssh ssh-keygen openssl curl; do
    command -v "$c" > /dev/null || { echo "FAIL: k3s-hetzner.sh needs $c"; exit 1; }
done
[ -n "${HCLOUD_CONTEXT:-}" ] || [ -n "${HCLOUD_TOKEN:-}" ] || { echo "FAIL: set HCLOUD_CONTEXT (or HCLOUD_TOKEN)"; exit 1; }
export HCLOUD_CONTEXT="${HCLOUD_CONTEXT:-}"
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] \
    || { echo "FAIL: set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY to the project's Object Storage keys"; exit 1; }

# Deletes what runs labelled $1 (a run's id, or every run's with "") left:
# servers, firewalls, SSH keys, and the buckets named after them. Keeps
# going past errors; says loudly what's still there.
delete_all() {
    sel=$LABEL${1:+=$1}
    prefix=${1:-$LABEL-}
    ids=$(hcloud server list -l "$sel" -o noheader -o columns=id 2> /dev/null || true)
    [ -z "$ids" ] || hcloud server delete $ids || true
    for fw in $(hcloud firewall list -l "$sel" -o noheader -o columns=id 2> /dev/null || true); do
        i=0
        until hcloud firewall delete "$fw" > /dev/null 2>&1; do
            i=$((i + 1)); [ "$i" -lt 30 ] || { log "can't delete firewall $fw"; break; }; sleep 2
        done
    done
    for k in $(hcloud ssh-key list -l "$sel" -o noheader -o columns=id 2> /dev/null || true); do
        hcloud ssh-key delete "$k" || true
    done
    for b in $(s3 s3api list-buckets --query 'Buckets[].Name' --output text 2> /dev/null | tr '\t' '\n' \
        | grep "^$prefix" || true); do
        s3 s3 rm --recursive --only-show-errors "s3://$b" || true
        s3 s3api delete-bucket --bucket "$b" || log "can't delete bucket $b"
    done
    left=$(hcloud server list -l "$sel" -o noheader -o columns=id,name 2> /dev/null || echo "(can't list servers)")
    left="$left$(hcloud firewall list -l "$sel" -o noheader -o columns=id,name 2> /dev/null)"
    left="$left$(s3 s3api list-buckets --query 'Buckets[].Name' --output text 2> /dev/null | tr '\t' '\n' \
        | grep "^$prefix" || true)"
    if [ -n "$left" ]; then
        echo "!!! k3s-hetzner: NOT ALL DELETED, still there (and paid for):"
        echo "$left"
        echo "!!! delete them with: HCLOUD_CONTEXT=$HCLOUD_CONTEXT tests/k3s-hetzner.sh --cleanup"
        return 1
    fi
    log "deleted everything labelled $sel"
}

if [ "${1:-}" = --cleanup ]; then
    delete_all ""
    exit
fi

id=$LABEL-$(date -u +%Y%m%d%H%M%S)
dir=build/$id
mkdir -p "$dir"
chmod 700 "$dir"
export KUBECONFIG="$PWD/$dir/kubeconfig"
bucket=$id
a=$id-a
b=$id-b
t0=
t1=
results=
check() { results="$results$1 $2
"; echo "$1 $2"; }

hourly() {
    hcloud server-type describe "$SERVER_TYPE" -o json \
        | jq -r --arg l "$LOCATION" '.prices[] | select(.location == $l) | .price_hourly.gross'
}
# The primary IPv4's hourly price, from the API's pricing (hcloud has no
# command for it), with the context's token; empty without one.
ipv4_hourly() {
    tok=${HCLOUD_TOKEN:-$(awk -v c="$HCLOUD_CONTEXT" '/^\[\[contexts\]\]/ {n = ""} /^ *name *=/ {gsub(/[" ]/, "", $0); split($0, p, "="); n = p[2]} /^ *token *=/ && n == c {gsub(/[" ]/, "", $0); split($0, p, "="); print p[2]; exit}' "${HCLOUD_CONFIG:-$HOME/.config/hcloud/cli.toml}" 2> /dev/null)}
    [ -n "$tok" ] || return 0
    curl -fsS -H "Authorization: Bearer $tok" https://api.hetzner.cloud/v1/pricing 2> /dev/null \
        | jq -r --arg l "$LOCATION" '[.pricing.primary_ips[] | select(.type == "ipv4") | .prices[] | select(.location == $l) | .price_hourly.gross][0] // empty' || true
}
cost() {
    [ -n "$t0" ] || return 0
    secs=$(( ${t1:-$(date -u +%s)} - t0 ))
    h=$(hourly)
    ip=$(ipv4_hourly)
    awk -v s="$secs" -v h="$h" -v ip="${ip:-0}" -v t="$SERVER_TYPE" -v noip="${ip:+x}" 'BEGIN {
        hours = s / 3600; billed = int((s + 3599) / 3600)
        printf "k3s-hetzner: cost: 2 x %s for %d min at %.4f/h", t, s / 60, h
        if (noip != "") printf ", with their IPv4 at %.4f/h", ip
        printf ": %.4f (billed by started hours: %d h, %.4f), in the project currency\n", 2 * hours * (h + ip), billed, 2 * billed * (h + ip)
    }'
}

teardown() {
    rc=$?
    set +e
    trap - EXIT INT TERM HUP
    if [ "${KEEP:-0}" = 1 ]; then
        log "KEEP=1: $a and $b, firewall, SSH key and bucket $bucket are still up, and paid for"
        log "KUBECONFIG=$KUBECONFIG; delete them with: HCLOUD_CONTEXT=$HCLOUD_CONTEXT tests/k3s-hetzner.sh --cleanup"
        cost
        exit "$rc"
    fi
    log "tearing down $id"
    delete_all "$id" || rc=1
    [ -z "$t0" ] || t1=$(date -u +%s)
    hcloud server list -o columns=id,name,type,status,labels
    cost
    rm -f "$dir/id_ed25519"
    if [ -n "$results" ]; then
        echo "k3s-hetzner: the checks:"
        printf %s "$results"
    fi
    exit "$rc"
}
trap teardown EXIT
trap 'exit 130' INT TERM HUP

fail() {
    echo "FAIL: $*"
    kubectl get nodes -o wide 2> /dev/null || true
    kubectl -n morca get pods -o wide 2> /dev/null || true
    kubectl -n morca-runs get pods,jobs -o wide 2> /dev/null || true
    kubectl -n morca logs deploy/morca-scheduler -c scheduler --tail=60 2> /dev/null || true
    check FAIL "$*"
    exit 1
}

# The SSH key, the firewall (SSH and the API from here, everything between
# the nodes) and the bucket, each labelled with the run.
admin=${ADMIN_IP:-$(curl -fsS -4 https://ifconfig.me)}
ssh-keygen -q -t ed25519 -N "" -C "$id" -f "$dir/id_ed25519"
hcloud ssh-key create --name "$id" --public-key-from-file "$dir/id_ed25519.pub" --label "$LABEL=$id" > /dev/null
hcloud firewall create --name "$id" --label "$LABEL=$id" > /dev/null
for p in 22 6443; do
    hcloud firewall add-rule "$id" --direction in --protocol tcp --port "$p" --source-ips "$admin/32" > /dev/null
done
s3 s3api create-bucket --bucket "$bucket" > /dev/null || fail "create the bucket $bucket"
log "made SSH key, firewall and bucket $id"

# The servers, at once. Their cost runs from here.
t0=$(date -u +%s)
for n in "$a" "$b"; do
    hcloud server create --name "$n" --type "$SERVER_TYPE" --image "$SERVER_IMAGE" --location "$LOCATION" \
        --ssh-key "$id" --firewall "$id" --label "$LABEL=$id" > "$dir/$n.create.log" 2>&1 &
done
wait || true
ipa=$(hcloud server ip "$a") || fail "create $a: $(cat "$dir/$a.create.log")"
ipb=$(hcloud server ip "$b") || fail "create $b: $(cat "$dir/$b.create.log")"
for ip in "$ipa" "$ipb"; do
    for proto in tcp udp; do
        hcloud firewall add-rule "$id" --direction in --protocol "$proto" --port 1-65535 --source-ips "$ip/32" > /dev/null
    done
done
log "servers $a ($ipa) and $b ($ipb), $SERVER_TYPE in $LOCATION"

sshn() {
    h=$1; shift
    ssh -i "$dir/id_ed25519" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$dir/known_hosts" -o LogLevel=ERROR "root@$h" "$@"
}
for ip in "$ipa" "$ipb"; do
    i=0
    until sshn "$ip" true 2> /dev/null; do
        i=$((i + 1)); [ "$i" -lt 60 ] || fail "no SSH to $ip"; sleep 3
    done
    sshn "$ip" cloud-init status --wait > /dev/null 2>&1 || true
done

# k3s: the server on a, the agent on b. Nodes are taken for NotReady after
# 20 s, and their pods evicted 30 s later, rather than 40 s and 5 min, so a
# lost node shows in minutes.
ver=${K3S_VERSION:+INSTALL_K3S_VERSION=$K3S_VERSION}
sshn "$ipa" "curl -sfL https://get.k3s.io | $ver sh -s - server --tls-san $ipa --node-external-ip $ipa \
    --disable traefik --disable servicelb --write-kubeconfig-mode 600 \
    --node-label morca.dev/node=core --node-taint morca.dev/core=true:PreferNoSchedule \
    --kube-controller-manager-arg node-monitor-grace-period=20s \
    --kube-apiserver-arg default-not-ready-toleration-seconds=30 \
    --kube-apiserver-arg default-unreachable-toleration-seconds=30" > "$dir/k3s-a.log" 2>&1 \
    || fail "k3s on $a: $(tail -n 20 "$dir/k3s-a.log")"
sshn "$ipa" cat /var/lib/rancher/k3s/server/node-token | sshn "$ipb" "K3S_TOKEN=\$(cat) && export K3S_TOKEN \
    && curl -sfL https://get.k3s.io | K3S_URL=https://$ipa:6443 $ver sh -s - agent --node-external-ip $ipb \
    --node-label morca.dev/node=runs --node-taint morca.dev/runs=true:NoSchedule" > "$dir/k3s-b.log" 2>&1 \
    || fail "k3s on $b: $(tail -n 20 "$dir/k3s-b.log")"
sshn "$ipa" cat /etc/rancher/k3s/k3s.yaml | sed "s|https://127.0.0.1:6443|https://$ipa:6443|" > "$KUBECONFIG"
chmod 600 "$KUBECONFIG"
i=0
until [ "$(kubectl get nodes --no-headers 2> /dev/null | grep -c ' Ready ')" = 2 ]; do
    i=$((i + 1)); [ "$i" -lt 90 ] || fail "two Ready nodes"; sleep 2
done
log "k3s $(kubectl version -o json | jq -r .serverVersion.gitVersion) on $a and $b"

# The Secrets: the database's (a password of its own), the bucket's keys
# and the ghcr pull secret, in both namespaces, from files that go at once.
pw=$(openssl rand -hex 16)
kubectl create namespace morca > /dev/null
kubectl create namespace morca-runs > /dev/null
url=postgresql://orca:$pw@postgres.morca.svc:5432/orca
(umask 077
    printf 'password=%s\nurl=%s\n' "$pw" "$url" > "$dir/db.env"
    printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" > "$dir/s3.env")
for ns in morca morca-runs; do
    kubectl -n "$ns" create secret generic morca-db --from-env-file="$dir/db.env" > /dev/null
    kubectl -n "$ns" create secret generic morca-s3 --from-env-file="$dir/s3.env" > /dev/null
done
rm -f "$dir/db.env" "$dir/s3.env"
pull=
if [ -n "${GHCR_TOKEN:-}" ]; then
    pull=ghcr
    (umask 077
        auth=$(printf '%s:%s' "${GHCR_USER:-morca}" "$GHCR_TOKEN" | base64 | tr -d '\n')
        printf '{"auths": {"ghcr.io": {"auth": "%s"}}}\n' "$auth" > "$dir/ghcr.json")
    for ns in morca morca-runs; do
        kubectl -n "$ns" create secret generic ghcr --type=kubernetes.io/dockerconfigjson \
            --from-file=.dockerconfigjson="$dir/ghcr.json" > /dev/null
    done
    rm -f "$dir/ghcr.json"
fi

# The manifests, as kustomize lays them out: deploy/k8s's morca.yaml,
# runs.yaml and ui.yaml with the project's image, no MinIO, the bucket, the
# dev config (morca.dev.toml: no fills) and the placement above.
k=$dir/kustomize
mkdir -p "$k"
cp deploy/k8s/morca.yaml deploy/k8s/runs.yaml deploy/k8s/ui.yaml "$k/"
img_name=${MORCA_IMAGE%:*}
img_tag=${MORCA_IMAGE##*:}
pull_spec=
[ -z "$pull" ] || pull_spec="
            imagePullSecrets: [{name: $pull}]"
cat > "$k/kustomization.yaml" << EOF
resources: [morca.yaml, runs.yaml, ui.yaml]
images:
  - {name: morca, newName: $img_name, newTag: "$img_tag"}
patches:
  - patch: |-
      \$patch: delete
      apiVersion: apps/v1
      kind: StatefulSet
      metadata: {name: minio, namespace: morca}
  - patch: |-
      \$patch: delete
      apiVersion: v1
      kind: Service
      metadata: {name: minio, namespace: morca}
  - patch: |-
      apiVersion: v1
      kind: ConfigMap
      metadata: {name: morca-lake, namespace: morca}
      data:
        MORCA_WAREHOUSE: "s3://$bucket/warehouse"
        AWS_ENDPOINT_URL_S3: "$S3_ENDPOINT"
        AWS_REGION: "$S3_REGION"
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata: {name: morca-ui, namespace: morca}
      spec:
        template:
          spec:$pull_spec
            containers:
              - name: ui
                env:
                  - {name: MORCA_LOGS, value: "s3://$bucket/logs"}
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata: {name: morca-scheduler, namespace: morca}
      spec:
        template:
          spec:$pull_spec
            containers:
              - name: scheduler
                env:
                  - {name: MORCA_LOGS, value: "s3://$bucket/logs"}
                  - {name: MORCA_WAREHOUSE, value: "s3://$bucket/warehouse"}
                  - {name: AWS_ENDPOINT_URL_S3, value: "$S3_ENDPOINT"}
                  - {name: AWS_REGION, value: "$S3_REGION"}
                  - {name: MORCA_IMAGE, value: "$MORCA_IMAGE"}
                  - {name: MORCA_CONFIG, value: /opt/morca/morca.dev.toml}
                  - {name: MORCA_KUBE_PULL_SECRET, value: "$pull"}
                  - {name: MORCA_KUBE_HEAD_NODE_SELECTOR, value: morca.dev/node=core}
                  - {name: MORCA_KUBE_DRIVER_TOLERATIONS, value: morca.dev/runs}
                  - {name: MORCA_KUBE_WORKER_TOLERATIONS, value: morca.dev/runs}
EOF
kubectl apply -k "$k" > "$dir/apply.log" 2>&1 || fail "apply the manifests: $(cat "$dir/apply.log")"
kubectl -n morca rollout status statefulset/postgres --timeout=300s > /dev/null || fail "postgres"
kubectl -n morca rollout status deployment/morca-scheduler --timeout=600s > /dev/null || fail "the scheduler"
kubectl -n morca rollout status deployment/morca-ui --timeout=300s > /dev/null || fail "morca ui"
log "morca is up on $MORCA_IMAGE"

q() { kubectl -n morca exec statefulset/postgres -- psql -U orca -d orca -Atc "$1"; }
morca_cli() { kubectl -n morca exec deploy/morca-scheduler -c scheduler -- morca "$@"; }
until_true() {
    i=0
    until [ "$(q "$1" 2> /dev/null)" = t ]; do
        i=$((i + 1)); [ "$i" -lt "$2" ] || fail "waited ${2}s for: $1"; sleep 1
    done
}
# role node, for each pod of run $1 at start $2.
placed() {
    kubectl -n morca-runs get pods -l "orca.run=$1,orca.start=$2" \
        -o jsonpath='{range .items[*]}{.metadata.labels.orca\.role} {.spec.nodeName}{"\n"}{end}' | sort
}
# Waits for run $1's start $2 to have its driver, head and workers Running.
all_running() {
    i=0
    until [ -n "$(kubectl -n morca-runs get pods -l "orca.run=$1,orca.start=$2,orca.role=worker" -o name 2> /dev/null)" ] \
        && [ -z "$(kubectl -n morca-runs get pods -l "orca.run=$1,orca.start=$2" --no-headers 2> /dev/null | grep -v ' Running ')" ]; do
        i=$((i + 1)); [ "$i" -lt "$3" ] || fail "run $1's start $2 pods: $(kubectl -n morca-runs get pods -l "orca.run=$1" -o wide)"; sleep 2
    done
}
left() { kubectl -n morca-runs get pods,jobs,services,secrets -l "$1" -o name 2> /dev/null; }
# Starts a run of $PIPELINE over $1, its id in $r.
start() {
    out=$(morca_cli start "$PIPELINE" "$1" 2>&1) || fail "morca start $PIPELINE $1: $out"
    r=$(echo "$out" | sed -n 's/^queued run //p')
    [ -n "$r" ] || fail "morca start $PIPELINE $1 said: $out"
}

# Registered with an overlay (morca-toml.md#a-stacks-overlay): its workers,
# and its keys per run, which a backfill's run takes.
printf '[pipelines.%s]\nworkers = %s\nkeys_per_run = %s\n' "$PIPELINE" "$WORKERS" "$KEYS" \
    | kubectl -n morca exec -i deploy/morca-scheduler -c scheduler -- sh -c 'cat > /tmp/k3s.overlay.toml' \
    || fail "write the overlay"
morca_cli register --image "$MORCA_IMAGE" --overlay /tmp/k3s.overlay.toml "/opt/morca/pipelines/$PIPELINE" \
    > "$dir/register.log" 2>&1 || fail "register $PIPELINE: $(cat "$dir/register.log")"

# 1. A run across both nodes.
start "$DAY1"
r1=$r
log "run $r1: $PIPELINE $DAY1"
until_true "SELECT status = 'running' AND heartbeat IS NOT NULL FROM orca.runs WHERE id = $r1" 900
all_running "$r1" 1 300
p=$(placed "$r1" 1)
echo "$p" | sed 's/^/  /'
echo "$p" | grep -q "^head $a$" || fail "run $r1's head isn't on $a: $p"
[ -z "$(echo "$p" | grep -E '^(driver|worker) ' | grep -v " $b$")" ] || fail "run $r1's driver and workers aren't all on $b: $p"
until_true "SELECT status IN ('succeeded', 'failed', 'cancelled') FROM orca.runs WHERE id = $r1" 1800
[ "$(q "SELECT status FROM orca.runs WHERE id = $r1")" = succeeded ] \
    || fail "run $r1: $(q "SELECT status, error FROM orca.runs WHERE id = $r1")"
i=0
while [ -n "$(left "orca.run=$r1")" ]; do
    i=$((i + 1)); [ "$i" -lt 120 ] || fail "run $r1 left: $(left "orca.run=$r1" | tr '\n' ' ')"; sleep 1
done
s3 s3 ls --recursive "s3://$bucket/logs/$PIPELINE/$r1/" > "$dir/logs-$r1.txt" || fail "run $r1's logs in the bucket"
for f in driver.log head.log worker-0.log; do
    grep -q "/$r1/$f\$" "$dir/logs-$r1.txt" || fail "no $f for run $r1 in the bucket: $(cat "$dir/logs-$r1.txt")"
done
[ -n "$(s3 s3 ls --recursive "s3://$bucket/warehouse/" | grep 'metadata.json$')" ] || fail "no table in s3://$bucket/warehouse"
check ok "a $PIPELINE run went across both nodes (head on $a, driver and workers on $b) and succeeded, its logs and tables in the bucket"

# 2. Node b lost mid-run: powered off once the run has been working a while.
out=$(morca_cli backfill "$PIPELINE" "$DAYS2" 2>&1) || fail "morca backfill $PIPELINE $DAYS2: $out"
r2=$(q "SELECT max(id) FROM orca.runs WHERE trigger = 'backfill'")
[ "$(q "SELECT count(*) FROM orca.runs WHERE trigger = 'backfill'")" = 1 ] || fail "morca backfill $PIPELINE $DAYS2 queued more than one run: $out"
log "run $r2: $PIPELINE $DAYS2"
until_true "SELECT status = 'running' AND heartbeat IS NOT NULL FROM orca.runs WHERE id = $r2" 900
all_running "$r2" 1 300
sleep "${LOSE_AFTER:-20}"
[ "$(q "SELECT status FROM orca.runs WHERE id = $r2")" = running ] || fail "run $r2 ended before $b could be lost"
placed "$r2" 1 | grep -E '^(driver|worker) ' | grep -q " $b$" || fail "run $r2 has nothing on $b: $(placed "$r2" 1)"
lost=$(date -u +%s)
hcloud server poweroff "$b" > /dev/null || fail "power off $b"
log "powered off $b"
until_true "SELECT starts >= 2 OR status <> 'running' FROM orca.runs WHERE id = $r2" 600
[ "$(q "SELECT starts FROM orca.runs WHERE id = $r2")" -ge 2 ] \
    || fail "run $r2 wasn't started again: $(q "SELECT status, error FROM orca.runs WHERE id = $r2")"
log "run $r2 started again $(( $(date -u +%s) - lost ))s after $b went"
all_running "$r2" 2 600
p=$(placed "$r2" 2)
echo "$p" | sed 's/^/  /'
echo "$p" | grep -q '^worker ' || fail "run $r2's second start has no workers"
[ -z "$(echo "$p" | grep -v " $a$")" ] || fail "run $r2's second start isn't all on $a: $p"
until_true "SELECT status IN ('succeeded', 'failed', 'cancelled') FROM orca.runs WHERE id = $r2" 1800
[ "$(q "SELECT status FROM orca.runs WHERE id = $r2")" = succeeded ] \
    || fail "run $r2: $(q "SELECT status, starts, error FROM orca.runs WHERE id = $r2")"
check ok "run $r2, its driver and workers lost with $b, started again on $a, workers included, and succeeded"

# 3. Its first start's pods, which the lost node can't confirm deleting.
i=0
while [ -n "$(left "orca.run=$r2")" ]; do
    i=$((i + 1))
    if [ "$i" -ge "${SWEEP_WAIT:-300}" ]; then
        kubectl -n morca-runs get pods -l "orca.run=$r2" -o wide || true
        fail "run $r2's pods on the lost node weren't swept in ${SWEEP_WAIT:-300}s: $(kubectl -n morca-runs get pods -l "orca.run=$r2" -o jsonpath='{range .items[*]}{.metadata.name} deleting since {.metadata.deletionTimestamp} on {.spec.nodeName}; {end}')"
    fi
    sleep 1
done
check ok "run $r2's pods on the lost node were swept, Terminating ones included"
log "all ok"
