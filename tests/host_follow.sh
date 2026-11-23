#!/bin/sh
# A hand-joined host following the server's worker image (#220,
# morca._internal.host_follow): `morca host join --container --root` writes
# the container's script, which runs here with a fake `docker` on PATH (it
# logs each call and runs `morca worker` in place of the container, its
# mounts mapped to the host's paths). Nothing is installed or started, no
# real docker, systemctl or launchctl is run. A deploy is morca ui started
# again with another MORCA_WORKER_IMAGE.
#
# - the claim answer carries the server's image, and an older worker's
#   claim (no host fields) is answered as before;
# - a deploy: the host drains (its running run isn't stopped, the queued
#   one waits), then exits 4; the script pulls the new image, writes it to
#   the record and starts it, and it claims again; `morca host list` shows
#   draining, then current;
# - a pull that fails (no login): the old image again, claiming runs,
#   `upgrade=failed`, never draining in a loop; `morca host upgrade`
#   (audited) tries again, and it moves;
# - a new image that exits at once (a morca that doesn't know
#   --host-image): back on the old one, claiming runs;
# - a service (--host-service) says needs-upgrade and keeps running runs;
#   `morca host upgrade` refuses it;
# - an older server (no MORCA_WORKER_IMAGE): the host doesn't drain;
# - its token revoked (morca host remove): the worker exits 3 and the
#   script stops.
#
# Needs MORCA_DATABASE_URL (pixi run test-host-follow starts a throwaway
# server), curl and jq.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
scripts/pipelines.sh fillwk &
b1=$!
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca &
b2=$!
wait "$b1"
wait "$b2"
log=build/host-follow.log
: > "$log"
t=$PWD/build/host-follow
rm -rf "$t"
mkdir -p "$t/bin" "$t/fake"
export MORCA_STALE_SECONDS=5 MORCA_START_SECONDS=10 MORCA_SAMPLE_SECONDS=0
unset MORCA_IMAGE
export MORCA_LOGS="$t/logs"
hold="$t/hold"
ui=
pids=
cleanup() {
    for p in $ui $pids; do kill "$p" 2> /dev/null || true; done
    rm -f "$hold"
}
trap cleanup EXIT
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    [ -f "$t/script.out" ] && { echo "== script"; tail -40 "$t/script.out"; }
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
until_() {
    s=$1; what=$2; shift 2
    i=0
    until "$@"; do
        i=$((i + 1)); [ "$i" -lt $((s * 10)) ] || fail "$what"; sleep 0.1
    done
}
is() { [ "$(q "$1")" = "$2" ]; }
has() { grep -q "$1" "$2"; }
. "$PWD/tests/port.sh"
free_port port
base="http://127.0.0.1:$port"
img=reg.example/census
# ui IMAGE: morca ui (again: a deploy), its MORCA_WORKER_IMAGE IMAGE (none
# if empty).
start_ui() {
    if [ -n "$ui" ]; then kill "$ui"; wait "$ui" 2> /dev/null || true; fi
    if [ -n "$1" ]; then
        MORCA_WORKER_IMAGE=$1 MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
    else
        env -u MORCA_WORKER_IMAGE MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
    fi
    ui=$!
    until_ 10 "morca ui didn't start" curl -fs "$base/" -o /dev/null
}
queue() {
    q "INSERT INTO orca.runs (pipeline, registry_hash, partitions, trigger, status) SELECT name, registry_hash, '$1', 'ui', 'queued' FROM orca.pipelines WHERE name = 'fillwk' RETURNING id" | head -1
}
status() { q "SELECT status FROM orca.runs WHERE id = $1"; }
list() { ./build/morca host list --pool t 2>> "$log"; }

# The fake docker: `run` is the worker, here, with the container's mounts
# mapped back to the host's paths; a pull of an image in fake/pull-fails
# fails as an unauthorized one does; an image in fake/start-fails exits 2.
cat > "$t/bin/docker" << 'EOF'
#!/bin/sh
echo "$*" >> "$FAKE/calls"
case $1 in
rm) exit 0 ;;
pull)
    if grep -qxF "$2" "$FAKE/pull-fails" 2> /dev/null; then
        echo "Error response from daemon: unauthorized: authentication required" >&2
        exit 1
    fi
    exit 0 ;;
run) shift ;;
*) echo "fake docker: $1?" >&2; exit 1 ;;
esac
maps=
while [ $# -gt 0 ]; do
    case $1 in
    --rm) shift ;;
    --name | --network) shift 2 ;;
    --env-file) set -a; . "$2"; set +a; shift 2 ;;
    -v) maps="$maps $2"; shift 2 ;;
    *) break ;;
    esac
done
image=$1
shift
if grep -qxF "$image" "$FAKE/start-fails" 2> /dev/null; then
    echo "morca worker: unknown argument: --host-image" >&2
    exit 2
fi
n=$#
i=0
while [ "$i" -lt "$n" ]; do
    a=$1
    shift
    for m in $maps; do
        src=${m%%:*}
        rest=${m#*:}
        dst=${rest%%:*}
        [ "$a" = "$dst" ] && a=$src
    done
    set -- "$@" "$a"
    i=$((i + 1))
done
exec "$FAKE_MORCA" "$@" --poll-seconds 0.3
EOF
chmod 755 "$t/bin/docker"
export FAKE="$t/fake" FAKE_MORCA="$PWD/build/morca"

cat > "$t/morca.toml" << 'EOF'
[pools.t]

[pipelines.fillwk]
placement = "worker:t"
max_runs = 4
EOF
./build/morca register --config "$t/morca.toml" ./build/fillwk >> "$log" 2>&1 || fail "register"
start_ui "$img:1"
./build/morca worker-token create --pool t --label lab > "$t/token" 2>> "$log" || fail "worker-token create"
chmod 600 "$t/token"
id=$(q "SELECT id FROM orca.workers WHERE label = 'lab'")

# --- The claim carries the server's image; an older worker is answered ---
probe=$(./build/morca worker-token create --pool t --label probe 2>> "$log") || fail "worker-token create"
got=$(curl -fsS -H "Authorization: Bearer $probe" -d '{"pool": "t", "slots": 0, "name": "probe", "image": "", "running": ""}' \
    "$base/api/worker/claim") || fail "an older worker's claim"
echo "$got" | jq -e --arg i "$img:1" '.run == null and .worker_image == $i and (has("upgrade") | not)' > /dev/null \
    || fail "the claim's answer: $got"
is "SELECT count(*) FROM orca.workers WHERE label = 'probe' AND host_image IS NULL AND host_upgrade IS NULL" 1 \
    || fail "an older worker's host fields: $(q "SELECT host_image, host_upgrade FROM orca.workers")"
echo "ok   the claim carries the server's worker image; an older worker's claim is answered as before"

# --- Joined as a container, its script run with the fake docker ---
r=$t/root
env -u MORCA_DATABASE_URL ./build/morca host join "$base" --pool t --token-file "$t/token" --container --service systemd \
    --root "$r" --name lab > "$t/join.out" 2>&1 || fail "join: $(cat "$t/join.out")"
script=$r/etc/morca/worker-t-container.sh
rec=$r/etc/morca/host-t.json
unit=$r/etc/systemd/system/morca-worker-t.service
stage=$r/var/lib/morca/t/stage
for f in "$script" "$rec" "$unit"; do [ -f "$f" ] || fail "no $f: $(cat "$t/join.out")"; done
has "^ExecStart=/bin/sh $script$" "$unit" || fail "the unit: $(cat "$unit")"
jq -e --arg i "$img:1" --arg u "$unit" '.image == $i and .supervisor == "systemd" and .unit_file == $u' "$rec" > /dev/null \
    || fail "the record: $(cat "$rec")"
sh -n "$script" || fail "the script isn't sh"
touch "$hold"
r1=$(queue 2024-01)
env -u MORCA_DATABASE_URL PATH="$t/bin:$PATH" FILLWK_HOLD="$hold" sh "$script" > "$t/script.out" 2>&1 &
sp=$!
pids="$pids $sp"
until_ 20 "the container's worker didn't start run $r1: $(tail -5 "$t/script.out")" \
    is "SELECT count(*) FROM orca.runs WHERE id = $r1 AND status = 'running' AND heartbeat IS NOT NULL" 1
has "run --rm --name morca-worker-t .* $img:1 worker --pool t .* --host-image $img:1$" "$FAKE/calls" \
    || fail "the docker run: $(cat "$FAKE/calls")"
until_ 10 "host list: $(list)" sh -c "./build/morca host list --pool t | grep -q '^$id t lab live image=$img:1 server_image=$img:1 upgrade=current '"
echo "ok   joined as a container: its script runs the record's image, which follows the server's"

# --- A deploy: it drains, its run going on, then moves ---
r2=$(queue 2024-02)
start_ui "$img:2"
until_ 15 "it didn't drain: $(list)" sh -c "./build/morca host list --pool t | grep -q 'image=$img:1 server_image=$img:2 upgrade=draining '"
has "the server's worker image is $img:2 and this host runs $img:1 - draining" "$t/script.out" || fail "it didn't say it drains"
sleep 2
[ "$(status "$r1")" = running ] || fail "the drain stopped run $r1: $(status "$r1")"
[ "$(status "$r2")" = queued ] || fail "a draining host took run $r2: $(status "$r2")"
grep -q "pull" "$FAKE/calls" && fail "it pulled before it was idle"
rm -f "$hold"
until_ 30 "run $r1 didn't succeed: $(status "$r1")" is "SELECT status FROM orca.runs WHERE id = $r1" succeeded
until_ 30 "it didn't move to $img:2: $(tail -5 "$t/script.out")" has "^pull $img:2$" "$FAKE/calls"
until_ 30 "run $r2 didn't succeed on $img:2: $(status "$r2")" is "SELECT status FROM orca.runs WHERE id = $r2" succeeded
jq -e --arg i "$img:2" '.image == $i' "$rec" > /dev/null || fail "the record wasn't moved: $(cat "$rec")"
[ "$(ls -ln "$rec" | cut -c1-10)" = "-rw-------" ] || fail "the record's mode: $(ls -ln "$rec")"
jq -e '.supervisor == "systemd" and .pool == "t"' "$rec" > /dev/null || fail "the record lost its fields: $(cat "$rec")"
has "run --rm --name morca-worker-t .* $img:2 worker .* --host-image $img:2$" "$FAKE/calls" || fail "not started on $img:2"
has "exiting 4 for its container to be started on $img:2" "$t/script.out" || fail "the worker didn't say it exits 4"
has "the host moved to $img:2" "$t/script.out" || fail "the new worker didn't say it moved"
[ ! -e "$stage/.host-upgrade" ] || fail "the marker is still there"
until_ 10 "host list: $(list)" sh -c "./build/morca host list --pool t | grep -q 'image=$img:2 server_image=$img:2 upgrade=current '"
echo "ok   a deploy: it drains (its run goes on, nothing new), then its container is started on the new image"

# --- A pull that fails: the old image again, claiming ---
echo "$img:3" > "$FAKE/pull-fails"
start_ui "$img:3"
until_ 30 "the failed pull: $(tail -5 "$t/script.out")" has "can't pull $img:3 (Error response from daemon: unauthorized: authentication required): starting $img:2 again" "$t/script.out"
until_ 15 "host list: $(list)" sh -c "./build/morca host list --pool t | grep -q 'image=$img:2 server_image=$img:3 upgrade=failed '"
has "the host couldn't move to $img:3 (can't pull $img:3 (Error response from daemon: unauthorized: authentication required)): it claims runs on $img:2" "$t/script.out" \
    || fail "the worker didn't say why it stays"
r3=$(queue 2024-03)
until_ 30 "run $r3 didn't succeed on the old image: $(status "$r3")" is "SELECT status FROM orca.runs WHERE id = $r3" succeeded
jq -e --arg i "$img:2" '.image == $i' "$rec" > /dev/null || fail "the record moved: $(cat "$rec")"
sleep 2
[ "$(grep -c "^pull $img:3$" "$FAKE/calls")" = 1 ] || fail "it tried to pull again by itself: $(cat "$FAKE/calls")"
echo "ok   a pull that fails: it says why, runs the old image and claims runs, and doesn't try again by itself"

# morca host upgrade: tries again, now it can pull.
rm -f "$FAKE/pull-fails"
./build/morca host upgrade "$id" > "$t/upgrade.out" 2>&1 || fail "host upgrade: $(cat "$t/upgrade.out")"
is "SELECT count(*) FROM orca.audit WHERE action = 'host upgrade' AND detail = 'id=$id image=$img:2'" 1 \
    || fail "the audit: $(q "SELECT username, action, detail FROM orca.audit WHERE action LIKE 'host%'")"
until_ 30 "it didn't move to $img:3: $(tail -5 "$t/script.out")" sh -c "jq -e '.image == \"$img:3\"' '$rec' > /dev/null"
has "asked to upgrade (morca host upgrade): trying $img:3 again" "$t/script.out" || fail "it didn't say it was asked"
until_ 10 "host list: $(list)" sh -c "./build/morca host list --pool t | grep -q 'image=$img:3 server_image=$img:3 upgrade=current '"
is "SELECT count(*) FROM orca.workers WHERE id = $id AND upgrade IS NULL" 1 || fail "the ask wasn't cleared"
echo "ok   morca host upgrade (audited) tries a failed image again, and it moves"

# --- A new image that exits at once: back on the old one ---
echo "$img:4" > "$FAKE/start-fails"
start_ui "$img:4"
until_ 30 "it didn't roll back: $(tail -5 "$t/script.out")" has "$img:4 exited 2 within 60 s of starting: starting $img:3 again" "$t/script.out"
until_ 15 "host list: $(list)" sh -c "./build/morca host list --pool t | grep -q 'image=$img:3 server_image=$img:4 upgrade=failed '"
jq -e --arg i "$img:3" '.image == $i' "$rec" > /dev/null || fail "the record wasn't put back: $(cat "$rec")"
r4=$(queue 2024-04)
until_ 30 "run $r4 didn't succeed on the old image: $(status "$r4")" is "SELECT status FROM orca.runs WHERE id = $r4" succeeded
echo "ok   a new image that won't start: back on the old one, claiming runs"

# --- A service reports, and keeps working ---
./build/morca worker-token create --pool t --label svc > "$t/svc-token" 2>> "$log" || fail "worker-token create"
svc=$(q "SELECT id FROM orca.workers WHERE label = 'svc'")
env -u MORCA_DATABASE_URL ./build/morca worker --pool t --remote "$base" --token-file "$t/svc-token" --name svc \
    --dir "$t/svc-stage" --poll-seconds 0.3 --host-service systemd > "$t/svc.out" 2>&1 &
sw=$!
pids="$pids $sw"
until_ 15 "the service's report: $(list)" sh -c "./build/morca host list --pool t | grep -q '^$svc t svc live image=- server_image=$img:4 upgrade=needs-upgrade '"
has "as a systemd service, which can't change its binary itself: it keeps working" "$t/svc.out" || fail "the service didn't say: $(cat "$t/svc.out")"
if ./build/morca host upgrade "$svc" > "$t/svc-upgrade.out" 2>&1; then fail "a service was asked to upgrade"; fi
has "can't upgrade itself: it runs as a service" "$t/svc-upgrade.out" || fail "the refusal: $(cat "$t/svc-upgrade.out")"
r5=$(queue 2024-05)
until_ 30 "run $r5 didn't succeed: $(status "$r5")" is "SELECT status FROM orca.runs WHERE id = $r5" succeeded
kill "$sw" 2> /dev/null || true
echo "ok   a service says needs-upgrade, keeps running runs, and host upgrade refuses it"

# --- An older server says no image: the host doesn't drain ---
start_ui ""
r6=$(queue 2024-06)
until_ 30 "run $r6 didn't succeed: $(status "$r6")" is "SELECT status FROM orca.runs WHERE id = $r6" succeeded
until_ 10 "host list: $(list)" sh -c "./build/morca host list --pool t | grep -q '^$id t lab live image=$img:3 server_image=- upgrade=- '"
jq -e --arg i "$img:3" '.image == $i' "$rec" > /dev/null || fail "the record moved: $(cat "$rec")"
echo "ok   a server with no worker image: the host stays as it is and claims runs"

# --- Its token revoked: the worker exits 3, and the script stops ---
./build/morca host remove "$id" >> "$log" 2>&1 || fail "host remove"
until_ 20 "the script didn't stop: $(tail -5 "$t/script.out")" sh -c "! kill -0 $sp 2> /dev/null"
wait "$sp" && fail "the script exited 0" || code=$?
[ "$code" = 3 ] || fail "the script exited $code, not 3"
has "the worker's token was refused (morca host remove): stopping" "$t/script.out" || fail "the script didn't say why"
echo "ok   a revoked token: the worker exits 3, and its script stops with it"
echo "host follow: ok"
