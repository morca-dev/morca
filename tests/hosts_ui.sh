#!/bin/sh
# A self-hosted host's Drain, Undrain and Remove on Ops > Pools, and
# `morca --remote ... host` (#220), over tests/pool/fillwk.mojo placed
# worker:t and a [pools.t] with no provider; the hosts are worker tokens
# whose claims are sent with curl:
#
# - each live host's row and page has Drain and Remove; a host never heard
#   from is "not seen", a revoked one has no buttons; its image is shown
#   beside the server's (MORCA_WORKER_IMAGE);
# - with login on, a visitor sees "Log in to ..." in their place, and a POST
#   without a session is refused (and changes nothing), as is one from
#   another site;
# - logged in: Drain, then Undrain (each one orca.audit row, `host drain`
#   and `host undrain`, `id=<id>`, source ui, the user); Remove of a host
#   with a run running is refused with a page that confirms it, and done
#   with force=1 (`host remove`, `id=<id> running=1`);
# - `morca --remote <url> host list|drain|undrain|remove [--force]` does the
#   same through /api/hosts/<id>/..., audited from cli; without a login it
#   is refused.
#
# Needs MORCA_DATABASE_URL (pixi run test-hosts-ui starts a throwaway
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
log=build/hosts-ui.log
: > "$log"
proj=$PWD/build/hosts-ui-project
rm -rf "$proj" build/hosts-ui-*.txt
mkdir -p "$proj"
export MORCA_STALE_SECONDS=120
export MORCA_WORKER_IMAGE=ghcr.io/x/morca:2
unset MORCA_IMAGE
home=build/hosts-ui-home
rm -rf "$home"
export MORCA_CREDENTIALS="$home/morca/credentials"
ui=
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    [ -z "$ui" ] || kill "$ui" 2> /dev/null || true
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
is() { [ "$(q "$1")" = "$2" ]; }
. "$PWD/tests/port.sh"
free_port port
base="http://127.0.0.1:$port"
cat > "$proj/morca.toml" << EOF
[pools.t]
max_runs = 2

[pipelines.fillwk]
placement = "worker:t"
EOF
./build/morca register --config "$proj/morca.toml" ./build/fillwk >> "$log" 2>&1 || fail "register"
MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
ui=$!
i=0
until curl -fs "$base/" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
done
tok=$(./build/morca worker-token create --pool t --label busy 2>> "$log") || fail "worker-token create"
tok2=$(./build/morca worker-token create --pool t --label idle 2>> "$log") || fail "worker-token create"
./build/morca worker-token create --pool t --label never > /dev/null 2>> "$log" || fail "worker-token create"
a=$(q "SELECT id FROM orca.workers WHERE label = 'busy'")
b=$(q "SELECT id FROM orca.workers WHERE label = 'idle'")
c=$(q "SELECT id FROM orca.workers WHERE label = 'never'")
# claim TOKEN NAME IMAGE [RUNNING [GPUS]]: one claim, as a worker sends it.
claim() {
    curl -fsS -H "Authorization: Bearer $1" \
        -d "{\"pool\": \"t\", \"slots\": 4, \"name\": \"$2\", \"image\": \"$3\", \"running\": \"${4:-}\", \"gpus\": ${5:-0}}" \
        "$base/api/worker/claim"
}
run=$(q "INSERT INTO orca.runs (pipeline, registry_hash, partitions, trigger, status) SELECT name, registry_hash, '2024-01', 'ui', 'queued' FROM orca.pipelines WHERE name = 'fillwk' RETURNING id" | head -1)
got=$(claim "$tok" busybox "") || fail "the busy host's claim"
[ "$(echo "$got" | jq -r .run.run)" = "$run" ] || fail "the busy host got: $got"
# Its next claim says it runs it, as a worker's does, and that its host has
# 2 GPUs (docs/groups.md).
claim "$tok" busybox "" "$run" 2 | jq -e '.run == null' > /dev/null || fail "the busy host's second claim"
claim "$tok2" idlebox "" > /dev/null || fail "the idle host's claim"
# The images they run (a claim's own must match a run's, which has none).
q "UPDATE orca.workers SET image = 'ghcr.io/x/morca:1' WHERE id = $a; UPDATE orca.workers SET image = 'ghcr.io/x/morca:2' WHERE id = $b" > /dev/null
is "SELECT count(*) FROM orca.runs WHERE status = 'running' AND worker = $a" 1 || fail "run $run isn't running on host $a"

# post PATH BODY [curl args]: the status, as the UI's own form sends it.
post() {
    p=$1; d=$2; shift 2
    curl -s -o build/hosts-ui-body.txt -w '%{http_code}' -H "Origin: $base" -d "$d" "$@" "$base$p"
}
body() { cat build/hosts-ui-body.txt; }
html() { curl -fsS "$base$1"; }

# --- The buttons, the state and the images ---
page=$(html '/ops/pools?kind=self-hosted')
for id in "$a" "$b"; do
    echo "$page" | grep -qF "action=\"/ops/pools/self-hosted/$id/drain\"" || fail "host $id has no Drain"
    echo "$page" | grep -qF "action=\"/ops/pools/self-hosted/$id/remove\" data-confirm=\"Remove host " \
        || fail "host $id's Remove doesn't ask"
done
echo "$page" | grep -qF 'title="morca host drain '"$a"'"' || fail "Drain's title isn't the command"
echo "$page" | grep -qF 'It has 1 run running' || fail "the busy host's Remove doesn't say it runs"
echo "$page" | grep -qF '<td class="mono">ghcr.io/x/morca:1 <span class="muted" title="the server'"'"'s image: ghcr.io/x/morca:2">· server 2</span></td>' \
    || fail "the busy host's image beside the server's: $(echo "$page" | grep -o '<td class="mono">ghcr[^<]*<span[^<]*</span>' | head -2)"
echo "$page" | grep -qF "· the server's</span>" || fail "the idle host's image isn't marked as the server's"
gpage=$(html '/ops/pools?kind=self-hosted&gone=1')
echo "$gpage" | grep -qF "action=\"/ops/pools/self-hosted/$c/remove\"" || fail "the host never seen has no Remove"
echo "$gpage" | grep -qF '<span class="muted">not seen</span>' || fail "the host never seen isn't 'not seen'"
html "/ops/pools/self-hosted/$a" > build/hosts-ui-page.txt
grep -qF "action=\"/ops/pools/self-hosted/$a/drain\"" build/hosts-ui-page.txt || fail "the machine page has no Drain"
grep -qF '2, 0 granted</dd>' build/hosts-ui-page.txt || fail "the machine page doesn't show its host's GPUs"
if html "/ops/pools/self-hosted/$b" | grep -qF ' granted</dd>'; then fail "a host without GPUs shows some"; fi
html "/ops/pools/live?kind=self-hosted" | grep -qF "action=\"/ops/pools/self-hosted/$a/remove\"" || fail "the fragment has no Remove"
echo "ok   a live host's row and page have Drain and Remove; its state, images and GPUs"

# --- Login on: hidden from visitors, refused without a session ---
printf 'correct horse battery\n' | ./build/morca user add alice >> "$log" 2>&1 || fail "user add"
html '/ops/pools?kind=self-hosted' | grep -qF '<body class="anon">' || fail "the page isn't anon to a visitor"
html '/ops/pools/live?kind=self-hosted' | grep -qF 'href="/login?next=%2Fops%2Fpools%3Fkind%3Dself-hosted"' \
    || fail "the fragment's log-in links don't come back to the page"
[ "$(post "/ops/pools/self-hosted/$a/drain" '' -H 'Accept: application/json')" = 401 ] || fail "a drain without a session: $(body)"
[ "$(post "/api/hosts/$a/drain" '')" = 401 ] || fail "an API drain without a login: $(body)"
[ "$(post "/ops/pools/self-hosted/$a/remove" 'force=1')" = 303 ] || fail "a browser's remove without a session"
is "SELECT count(*) FROM orca.workers WHERE draining IS NOT NULL OR revoked IS NOT NULL" 0 || fail "changed without a session"
jar=build/hosts-ui-cookies.txt
rm -f "$jar"
[ "$(post /login 'name=alice&password=correct+horse+battery' -c "$jar")" = 303 ] || fail "login: $(body)"
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" -H 'Origin: http://evil.example' -d '' "$base/ops/pools/self-hosted/$a/drain")
[ "$code" = 403 ] || fail "a drain from another site answered $code"
is "SELECT count(*) FROM orca.workers WHERE draining IS NOT NULL" 0 || fail "drained from another site"
echo "ok   with login on, visitors see no buttons and are refused"

# --- Drain and undrain, audited as the user's ---
[ "$(post "/ops/pools/self-hosted/$a/drain" '' -b "$jar")" = 303 ] || fail "drain: $(body)"
is "SELECT count(*) FROM orca.workers WHERE id = $a AND draining IS NOT NULL" 1 || fail "not drained"
is "SELECT username || ' ' || source || ' ' || detail FROM orca.audit WHERE action = 'host drain'" "alice ui id=$a" \
    || fail "the drain's audit: $(q "SELECT username, action, detail, source FROM orca.audit")"
is "SELECT count(*) FROM orca.audit WHERE action LIKE '%/drain'" 0 || fail "the drain was audited by its path too"
page=$(curl -fsS -b "$jar" "$base/ops/pools/self-hosted/$a")
echo "$page" | grep -qF "action=\"/ops/pools/self-hosted/$a/undrain\"" || fail "a draining host has no Undrain"
echo "$page" | grep -qF "status--draining" || fail "its page doesn't say draining"
[ "$(post "/ops/pools/self-hosted/$a/drain" '' -b "$jar")" = 409 ] || fail "a second drain wasn't refused"
body | grep -qF "already" || fail "the second drain's refusal: $(body)"
[ "$(post "/ops/pools/self-hosted/$a/undrain" '' -b "$jar")" = 303 ] || fail "undrain: $(body)"
is "SELECT count(*) FROM orca.workers WHERE id = $a AND draining IS NULL" 1 || fail "not undrained"
is "SELECT username || ' ' || source || ' ' || detail FROM orca.audit WHERE action = 'host undrain'" "alice ui id=$a" \
    || fail "the undrain's audit"
echo "ok   Drain and Undrain, each one row of orca.audit as the user's, from ui"

# --- Remove: refused while it runs, then confirmed ---
[ "$(post "/ops/pools/self-hosted/$a/remove" '' -b "$jar")" = 409 ] || fail "a busy host's remove wasn't refused: $(body)"
body | grep -qF "has 1 runs running" || fail "the refusal: $(body)"
body | grep -qF "<form class=\"action\" method=\"post\" action=\"/ops/pools/self-hosted/$a/remove\"><input type=\"hidden\" name=\"force\" value=\"1\">" \
    || fail "the refusal doesn't confirm: $(body)"
is "SELECT count(*) FROM orca.workers WHERE id = $a AND revoked IS NULL" 1 || fail "the refused remove revoked it"
[ "$(post "/ops/pools/self-hosted/$a/remove" 'force=1' -b "$jar")" = 303 ] || fail "the confirmed remove: $(body)"
is "SELECT count(*) FROM orca.workers WHERE id = $a AND revoked IS NOT NULL" 1 || fail "not revoked"
is "SELECT username || ' ' || source || ' ' || detail FROM orca.audit WHERE action = 'host remove'" "alice ui id=$a running=1" \
    || fail "the remove's audit: $(q "SELECT username, action, detail, source FROM orca.audit")"
curl -fsS -b "$jar" "$base/ops/pools/self-hosted/$a" | grep -qF "/ops/pools/self-hosted/$a/drain" && fail "a removed host has buttons"
echo "ok   Remove is refused while the host runs, and done once confirmed"

# --- morca --remote ... host ---
r() { ./build/morca --remote "$base" host "$@" > build/hosts-ui-out.txt 2>&1; }
out() { cat build/hosts-ui-out.txt; }
r list --pool t || fail "remote host list: $(out)"
out | grep -q "^$b t idlebox live image=ghcr.io/x/morca:2 .* runs=0 " || fail "remote host list: $(out)"
out | grep -q "^$a t busybox revoked " || fail "remote host list, the removed one: $(out)"
out | grep -q "^$c t never not-seen " || fail "remote host list, the one never seen: $(out)"
! r drain "$b" || fail "a remote drain without a login"
out | grep -q "not logged in to $base" || fail "no login: $(out)"
printf 'correct horse battery\n' | ./build/morca login "$base" --user alice > build/hosts-ui-out.txt 2>&1 || fail "login: $(out)"
r drain "$b" || fail "remote drain: $(out)"
out | grep -q "^draining host $b - it finishes its 0 running runs and claims no more$" || fail "remote drain said: $(out)"
is "SELECT username || ' ' || source FROM orca.audit WHERE action = 'host drain' AND detail = 'id=$b'" "alice cli" \
    || fail "the remote drain's audit: $(q "SELECT username, action, detail, source FROM orca.audit")"
r list || fail "remote host list"
out | grep -q "^$b t idlebox draining " || fail "remote list after a drain: $(out)"
! r drain "$b" || fail "a second remote drain"
out | grep -q "^morca: host $b is no live worker token's, or is draining already$" || fail "the second drain: $(out)"
r undrain "$b" || fail "remote undrain: $(out)"
out | grep -q "^host $b claims runs again$" || fail "remote undrain said: $(out)"
# Busy again: a run running on it.
run2=$(q "INSERT INTO orca.runs (pipeline, registry_hash, partitions, trigger, status) SELECT name, registry_hash, '2024-02', 'ui', 'queued' FROM orca.pipelines WHERE name = 'fillwk' RETURNING id" | head -1)
q "UPDATE orca.runs SET status = 'cancelled' WHERE id = $run" > /dev/null
got=$(claim "$tok2" idlebox "") || fail "the idle host's second claim"
[ "$(echo "$got" | jq -r .run.run)" = "$run2" ] || fail "the idle host got: $got"
! r remove "$b" || fail "a remote remove of a busy host"
out | grep -q "^morca: host $b has 1 runs running: drain it first, or remove it anyway (morca host remove --force)" \
    || fail "the remote refusal: $(out)"
r remove "$b" --force || fail "remote remove --force: $(out)"
out | grep -q "^removed host $b - its token is revoked" || fail "remote remove said: $(out)"
is "SELECT username || ' ' || source || ' ' || detail FROM orca.audit WHERE action = 'host remove' AND detail LIKE 'id=$b %'" \
    "alice cli id=$b running=1" || fail "the remote remove's audit: $(q "SELECT username, action, detail, source FROM orca.audit")"
is "SELECT count(*) FROM orca.workers WHERE id = $b AND revoked IS NOT NULL" 1 || fail "the remote remove didn't revoke it"
echo "ok   morca --remote ... host list, drain, undrain and remove, audited from cli"
grep -q "$tok" "$log" && fail "a token is in the log"
kill "$ui" 2> /dev/null || true
echo "hosts-ui: ok"
