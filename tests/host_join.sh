#!/bin/sh
# `morca host join` (#220, morca.host_join): a machine sets itself up as a
# worker of pool t, against morca ui, every file under a --root in build/
# (or only printed, --dry-run): nothing is installed or started on this
# machine, no systemctl, launchctl or docker is run.
#
# - a pool's volumes are checked and recorded;
# - a token file others can read, or a token of another pool, is refused;
# - systemd: the unit, its own env file (mode 600) and the record, with the
#   token only in the token file, and the join audited; the unit's
#   ExecStart, run as it is, is a worker that runs the pool's runs, with
#   the --set variables of its env file;
# - launchd: the plist has the same command line;
# - --container: the script's docker run (dry run), on the image the
#   record names (the server's), with the token file, the env files and the
#   pool's volumes mounted, and the service that runs the script
#   (tests/host_follow.sh runs it);
# - with MORCA_REMOTE set, host join still runs here (never sent to the UI);
# - --uninstall removes what was installed.
#
# Needs MORCA_DATABASE_URL (pixi run test-host-join starts a throwaway
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
log=build/host-join.log
: > "$log"
t=$PWD/build/host-join
rm -rf "$t"
mkdir -p "$t"
export MORCA_STALE_SECONDS=5 MORCA_START_SECONDS=10 MORCA_SAMPLE_SECONDS=0
unset MORCA_IMAGE
export MORCA_LOGS="$t/logs"
hold="$t/hold"
pids=
cleanup() {
    for p in $pids; do kill "$p" 2> /dev/null || true; done
    rm -f "$hold"
}
trap cleanup EXIT
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
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
mode() { ls -ln "$1" | cut -c1-10; }
. "$PWD/tests/port.sh"
free_port port
base="http://127.0.0.1:$port"
# join ARGS...: morca host join on this machine, with no database.
join() { env -u MORCA_DATABASE_URL ./build/morca host join "$@"; }

# --- A pool's volumes are checked and recorded ---
printf '[pools.t]\nvolumes = ["census-work:/work", "/a b:/x"]\n' > "$t/bad.toml"
if ./build/morca config check "$t/bad.toml" > "$t/bad.out" 2>&1; then fail "a volume with a space was taken"; fi
grep -q "volumes: not a path a volume can have" "$t/bad.out" || fail "the refusal: $(cat "$t/bad.out")"
cat > "$t/morca.toml" << 'EOF'
[pools.t]
max_runs = 2
volumes = ["census-work:/work", "/srv/secrets:/etc/orca/secrets:ro"]

[pipelines.fillwk]
placement = "worker:t"
max_runs = 4
EOF
./build/morca register --config "$t/morca.toml" ./build/fillwk >> "$log" 2>&1 || fail "register"
is "SELECT volumes->>1 FROM orca.pool_settings WHERE name = 't'" "/srv/secrets:/etc/orca/secrets:ro" \
    || fail "the volumes: $(q "SELECT volumes FROM orca.pool_settings")"
echo "ok   a pool's volumes are checked and recorded"

MORCA_WORKER_IMAGE=ghcr.io/morca-dev/census:9.9.9 MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
pids="$pids $!"
until_ 10 "morca ui didn't start" curl -fs "$base/" -o /dev/null
./build/morca worker-token create --pool t --label lab > "$t/token" 2>> "$log" || fail "worker-token create"
tok=$(cat "$t/token")
./build/morca worker-token create --pool other > "$t/other-token" 2>> "$log" || fail "worker-token create"
chmod 600 "$t/other-token"

# --- Refusals: a token file others can read, another pool's token ---
chmod 644 "$t/token"
if join "$base" --pool t --token-file "$t/token" --root "$t/r0" > "$t/out" 2>&1; then fail "a readable token file was taken"; fi
grep -q "is readable by others" "$t/out" || fail "the refusal: $(cat "$t/out")"
chmod 600 "$t/token"
if join "$base" --pool t --token-file "$t/other-token" --root "$t/r0" > "$t/out" 2>&1; then fail "another pool's token was taken"; fi
grep -q "the server refused the join: morca: this worker token is for pool other, not t" "$t/out" || fail "the refusal: $(cat "$t/out")"
[ ! -e "$t/r0" ] || fail "a refused join wrote files: $(find "$t/r0")"
echo "ok   a readable token file and another pool's token are refused, and nothing is written"

# --- systemd, under a root ---
r=$t/systemd
printf 'AWS_SECRET_ACCESS_KEY=not-a-real-key\n' > "$t/bucket.env"
chmod 600 "$t/bucket.env"
join "$base" --pool t --token-file "$t/token" --service systemd --root "$r" --name lab \
    --env-file "$t/bucket.env" --set "FILLWK_HOLD=$hold" > "$t/systemd.out" 2>&1 || fail "join systemd: $(cat "$t/systemd.out")"
unit=$r/etc/systemd/system/morca-worker-t.service
envf=$r/etc/morca/worker-t.env
rec=$r/etc/morca/host-t.json
for f in "$unit" "$envf" "$rec"; do [ -f "$f" ] || fail "no $f: $(cat "$t/systemd.out")"; done
[ "$(mode "$envf")" = "-rw-------" ] || fail "the env file's mode: $(mode "$envf")"
[ "$(mode "$rec")" = "-rw-------" ] || fail "the record's mode: $(mode "$rec")"
[ "$(mode "$unit")" = "-rw-r--r--" ] || fail "the unit's mode: $(mode "$unit")"
grep -q "^Restart=always$" "$unit" && grep -q "^RestartPreventExitStatus=3$" "$unit" || fail "the unit: $(cat "$unit")"
grep -q "^ExecStart=$PWD/build/morca worker --pool t --remote $base --token-file $t/token --name lab --dir $r/var/lib/morca/t/stage --env-file $envf --env-file $t/bucket.env --host-service systemd$" "$unit" \
    || fail "the unit's ExecStart: $(grep ExecStart "$unit")"
grep -q "^MORCA_REMOTE=$base$" "$envf" && grep -q "^FILLWK_HOLD=$hold$" "$envf" || fail "the env file: $(cat "$envf")"
jq -e --arg u "$unit" '.service == "systemd" and .pool == "t" and .service_file == $u and .name == "lab"' "$rec" > /dev/null \
    || fail "the record: $(cat "$rec")"
grep -q "nothing started" "$t/systemd.out" || fail "it didn't say it started nothing: $(cat "$t/systemd.out")"
grep -rq "$tok" "$r" "$t/systemd.out" && fail "the token is in a file it wrote, or its output"
grep -rq "not-a-real-key" "$r" "$t/systemd.out" && fail "the bucket's key was copied"
is "SELECT count(*) FROM orca.audit WHERE action = '/api/worker/join' AND username = 'worker:lab' AND detail = 'name=lab pool=t'" 1 \
    || fail "the join's audit: $(q "SELECT username, action, detail FROM orca.audit")"
echo "ok   systemd: the unit, a private env file and the record, no secret in them, the join audited"

# The unit's ExecStart, as systemd would run it: a worker of the pool.
touch "$hold"
cmd=$(sed -n 's/^ExecStart=//p' "$unit")
run1=$(q "INSERT INTO orca.runs (pipeline, registry_hash, partitions, trigger, status) SELECT name, registry_hash, '2024-01', 'ui', 'queued' FROM orca.pipelines WHERE name = 'fillwk' RETURNING id" | head -1)
# shellcheck disable=SC2086
env -u MORCA_DATABASE_URL -u MORCA_REMOTE $cmd > "$t/worker.out" 2>&1 &
w=$!
pids="$pids $w"
until_ 20 "the unit's worker didn't start run $run1: $(q "SELECT id, status FROM orca.runs") $(tail -5 "$t/worker.out")" \
    is "SELECT count(*) FROM orca.runs WHERE id = $run1 AND status = 'running' AND heartbeat IS NOT NULL" 1
sleep 1
is "SELECT status FROM orca.runs WHERE id = $run1" running || fail "the run didn't hold: FILLWK_HOLD from the env file didn't reach it"
rm -f "$hold"
until_ 30 "run $run1 didn't succeed: $(q "SELECT status, error FROM orca.runs WHERE id = $run1")" \
    is "SELECT status FROM orca.runs WHERE id = $run1" succeeded
grep -q "up to 2 runs at once (the pool's max_runs)" "$t/worker.out" || fail "the worker: $(cat "$t/worker.out")"
kill "$w"
echo "ok   the unit's ExecStart runs the pool's runs, with its env file's variables"

# --- launchd, under a root: the same worker ---
r2=$t/launchd
join "$base" --pool t --token-file "$t/token" --service launchd --root "$r2" --name lab > "$t/launchd.out" 2>&1 \
    || fail "join launchd: $(cat "$t/launchd.out")"
plist=$r2/Library/LaunchDaemons/dev.morca.worker.t.plist
[ -f "$plist" ] || fail "no plist: $(cat "$t/launchd.out")"
grep -q "<string>dev.morca.worker.t</string>" "$plist" && grep -q "<key>KeepAlive</key>" "$plist" \
    && grep -q "<string>$t/token</string>" "$plist" && grep -q "<string>$r2/var/log/morca-worker-t.log</string>" "$plist" \
    || fail "the plist: $(cat "$plist")"
if command -v plutil > /dev/null 2>&1; then plutil -lint "$plist" >> "$log" 2>&1 || fail "plutil: $(plutil -lint "$plist")"; fi
grep -q "$tok" "$plist" && fail "the token is in the plist"
echo "ok   launchd: the plist has the same command line, its log under the root"

# --- --container, a dry run: the server's image, the mounts ---
join "$base" --pool t --token-file "$t/token" --container --root "$t/c" --name lab --env-file "$t/bucket.env" --dry-run \
    > "$t/container.out" 2>&1 || fail "join --container: $(cat "$t/container.out")"
[ ! -e "$t/c" ] || fail "a dry run wrote files"
grep -q "^    'docker' 'run' '--rm' '--name' 'morca-worker-t' '--env-file' '$t/c/etc/morca/worker-t.env' '--env-file' '$t/bucket.env' '-v' '$t/token:/etc/morca/token:ro' '-v' '$t/c/var/lib/morca/t/stage:/var/lib/morca/stage' '-v' 'census-work:/work' '-v' '/srv/secrets:/etc/orca/secrets:ro' \"\$image\" 'worker' '--pool' 't' '--remote' '$base' '--token-file' '/etc/morca/token' '--name' 'lab' '--dir' '/var/lib/morca/stage' '--host-image' \"\$image\"$" "$t/container.out" \
    || fail "the container's docker run: $(grep docker "$t/container.out")"
grep -q '"image": "ghcr.io/morca-dev/census:9.9.9"' "$t/container.out" || fail "the record's image: $(grep image "$t/container.out")"
grep -q "worker-t-container.sh (mode 700)" "$t/container.out" || fail "the script's mode: $(grep '^==' "$t/container.out")"
grep -q "^ExecStart=/bin/sh $t/c/etc/morca/worker-t-container.sh$\|<string>$t/c/etc/morca/worker-t-container.sh</string>" "$t/container.out" \
    || fail "the script's service: $(cat "$t/container.out")"
grep -q "$tok" "$t/container.out" && fail "the token is in the dry run's output"
join "$base" --pool t --token-file "$t/token" --container --image my/img:1 --root "$t/c" --dry-run > "$t/container2.out" 2>&1 \
    || fail "join --container --image"
grep -q '"image": "my/img:1"' "$t/container2.out" || fail "--image wasn't used"
grep -q "would run" "$t/container2.out" && fail "a dry run under a root would run something"
# Without --root, a dry run only says what it would run.
join "$base" --pool t --token-file "$t/token" --service systemd --dry-run > "$t/dry.out" 2>&1 || fail "dry run"
grep -q "^would run: systemctl enable morca-worker-t$" "$t/dry.out" || fail "the dry run: $(cat "$t/dry.out")"
echo "ok   --container: a script, run by a service, that runs the server's image with the token, env files and the pool's volumes"

# With MORCA_REMOTE set (as `morca --remote` commands use it), host join
# still runs here, and takes the UI from it.
MORCA_REMOTE="$base" join --pool t --token-file "$t/token" --service systemd --dry-run > "$t/remote.out" 2>&1 \
    || fail "host join with MORCA_REMOTE set: $(cat "$t/remote.out")"
grep -q "^ExecStart=.* worker --pool t --remote $base " "$t/remote.out" || fail "with MORCA_REMOTE: $(cat "$t/remote.out")"
echo "ok   with MORCA_REMOTE set, host join --dry-run runs on this machine"

# --- --uninstall ---
join --uninstall --pool t --root "$r" > "$t/un.out" 2>&1 || fail "uninstall: $(cat "$t/un.out")"
for f in "$unit" "$envf" "$rec"; do [ ! -e "$f" ] || fail "$f is still there"; done
if join --uninstall --pool t --root "$r" > "$t/un2.out" 2>&1; then fail "a second uninstall found something"; fi
grep -q "no morca host join of pool t here" "$t/un2.out" || fail "the refusal: $(cat "$t/un2.out")"
join --uninstall --pool t --root "$r2" >> "$log" 2>&1 || fail "uninstall launchd"
[ ! -e "$plist" ] || fail "the plist is still there"
echo "ok   --uninstall removes what was installed"
echo "host join: ok"
