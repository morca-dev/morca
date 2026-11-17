#!/bin/sh
# The `morca` command against `morca ui` over HTTP, as a logged-in user
# (morca.remote, morca.tokens), over examples/toy.mojo:
#
# - reads (`status`) need no login; actions do, and `morca login` with a
#   wrong password stores nothing; with the right one it stores a token,
#   mode 600 in a directory of mode 700, which the database keeps only as
#   its SHA-256 and the UI's log never shows;
# - backfill (and its preview), pause, unpause, cancel, start, resume and
#   rerun go through the UI: the runs and the pipeline change as the local
#   commands change them, with the same output, and each is a row of
#   orca.audit with the user and source `cli`;
# - an unknown, malformed, expired or revoked token gets 401 and changes
#   nothing, a cookie alongside it included; a token's POST from another
#   site's page is refused; a login for a token has to be JSON;
# - `morca logout` revokes the token, as `morca user revoke` and a new
#   password do; 5 failed logins for a name get 429, as on /login;
# - plain http to anywhere but this machine is refused before connecting.
#
# Needs MORCA_DATABASE_URL (pixi run test-remote starts a throwaway server),
# curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build
scripts/pipelines.sh toy
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca
log=build/remote.log
: > "$log"
ui=
fail() {
    echo "FAIL: $*"
    tail -20 "$log"
    [ -z "$ui" ] || kill "$ui" 2> /dev/null || true
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
mode() { stat -c %a "$1" 2> /dev/null || stat -f %Lp "$1"; }
./build/morca register ./build/toy >> "$log" 2>&1 || fail "register"
free_port port
base="http://127.0.0.1:$port"
MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
ui=$!
i=0
until curl -fs "$base/" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
done
home=build/remote-home
rm -rf "$home"
export MORCA_CREDENTIALS="$home/morca/credentials"
# r ARGS: morca against the UI, its stdout and stderr in build/remote-out.txt.
r() { ./build/morca --remote "$base" "$@" > build/remote-out.txt 2>&1; }
out() { cat build/remote-out.txt; }
printf 'correct horse battery\n' | ./build/morca user add alice >> "$log" 2>&1 || fail "user add"

# Reads need no login; actions do.
r status || fail "status without a login: $(out)"
out | grep -q '^toy  active  running 0  queued 0  last -  next ' || fail "status: $(out)"
! r pause toy || fail "an action without a login"
out | grep -q "not logged in to $base" || fail "no login: $(out)"
[ "$(q "SELECT paused FROM orca.pipelines")" = f ] || fail "paused without a login"

# Logging in.
printf 'wrong password\n' | ./build/morca login "$base" --user alice > build/remote-out.txt 2>&1 \
    && fail "a wrong password logged in"
out | grep -q 'Wrong name or password' || fail "a wrong password: $(out)"
[ ! -e "$MORCA_CREDENTIALS" ] || fail "credentials for a wrong password"
printf 'correct horse battery\n' | ./build/morca login "$base" --user alice --label laptop \
    > build/remote-out.txt 2>&1 || fail "login: $(out)"
out | grep -q "^logged in to $base as alice until 20" || fail "login said: $(out)"
[ "$(mode "$MORCA_CREDENTIALS")" = 600 ] || fail "credentials mode $(mode "$MORCA_CREDENTIALS")"
[ "$(mode "$home/morca")" = 700 ] || fail "credentials' directory mode $(mode "$home/morca")"
token=$(grep -v '^#' "$MORCA_CREDENTIALS" | cut -f4)
case "$token" in orca_*) ;; *) fail "not a token: $token" ;; esac
[ "${#token}" -eq 69 ] || fail "a token of ${#token} characters"
[ "$(q "SELECT count(*) FROM orca.api_tokens WHERE token_hash = '$token'")" -eq 0 ] \
    || fail "the token is kept as it is"
[ "$(q "SELECT label || ' ' || username FROM orca.api_tokens
        WHERE token_hash = encode(digest('$token', 'sha256'), 'hex')")" = "laptop alice" ] \
    || fail "the token isn't kept as its SHA-256"
[ "$(q "SELECT expires > now() + interval '29 days' AND expires < now() + interval '31 days'
        FROM orca.api_tokens")" = t ] || fail "the token doesn't last 30 days"
[ "$(q "SELECT source || ' ' || action FROM orca.audit WHERE username = 'alice' ORDER BY id")" \
    = "$(printf 'cli login-failed\ncli /api/login')" ] \
    || fail "the login's audit: $(q "SELECT * FROM orca.audit")"
auth="Authorization: Bearer $token"

# Backfill, with what it skips and its preview, as locally.
r backfill --preview toy 2024-01..2024-03 || fail "preview: $(out)"
[ "$(out)" = "This queues 3 runs: 2024-01 … 2024-03. No estimate yet: no run of it has succeeded." ] || fail "preview said: $(out)"
[ "$(./build/morca backfill --preview toy 2024-01..2024-03)" = "$(out)" ] || fail "the local preview differs"
[ "$(q "SELECT count(*) FROM orca.runs")" -eq 0 ] || fail "a preview queued runs"
r backfill toy 2024-01..2024-03 || fail "backfill: $(out)"
[ "$(out)" = "queued 3 runs" ] || fail "backfill said: $(out)"
[ "$(q "SELECT count(*) FROM orca.runs WHERE trigger = 'backfill' AND status = 'queued'")" -eq 3 ] \
    || fail "backfill's runs"
r backfill toy 2024-01..2024-04 || fail "backfill again: $(out)"
out | grep -q '^skipped 3 in live runs: 2024-01 (run ' || fail "no skipped line: $(out)"
[ "$(out | tail -1)" = "queued 1 runs" ] || fail "backfill again said: $(out)"
[ "$(q "SELECT username || ' ' || source || ' ' || detail FROM orca.audit
        WHERE action = '/pipelines/toy/backfill' ORDER BY id LIMIT 1")" = "alice cli partitions=2024-01..2024-03" ] \
    || fail "backfill's audit: $(q "SELECT * FROM orca.audit")"

# Pause and unpause; a refusal says why, as locally.
r pause toy || fail "pause: $(out)"
[ "$(out)" = "paused toy" ] || fail "pause said: $(out)"
[ "$(q "SELECT paused FROM orca.pipelines")" = t ] || fail "not paused"
! r pause toy || fail "paused twice"
[ "$(out)" = "morca: pipeline toy is paused already" ] || fail "pause again said: $(out)"
r status toy || fail "status toy: $(out)"
[ "$(./build/morca status toy)" = "$(out)" ] || fail "status differs: $(out)"
out | grep -q '^toy  paused  running 0  queued 4' || fail "status toy said: $(out)"
# A run's line ends with how long it ran; a queued one hasn't started.
out | grep -Eq '^  [0-9]+ queued backfill [^ ]+ -$' || fail "a queued run's duration: $(out)"
[ "$(./build/morca --remote "$base" status toy --json | jq -r .pipeline.paused)" = true ] || fail "status --json"
r unpause toy || fail "unpause: $(out)"
[ "$(out)" = "unpaused toy" ] || fail "unpause said: $(out)"

# Cancel in bulk and one run; resume, start and rerun.
r cancel toy 2024-01 || fail "cancel: $(out)"
[ "$(out)" = "cancelled 1 runs" ] || fail "cancel said: $(out)"
r cancel toy @all || fail "cancel @all: $(out)"
[ "$(out)" = "cancelled 3 runs" ] || fail "cancel @all said: $(out)"
[ "$(q "SELECT count(*) FROM orca.runs WHERE status <> 'cancelled'")" -eq 0 ] || fail "runs left uncancelled"
run=$(q "SELECT min(id) FROM orca.runs")
r resume "$run" || fail "resume: $(out)"
[ "$(out)" = "resumed run $run" ] || fail "resume said: $(out)"
[ "$(q "SELECT status FROM orca.runs WHERE id = $run")" = queued ] || fail "not resumed"
r cancel "$run" || fail "cancel a run: $(out)"
[ "$(out)" = "cancelled run $run" ] || fail "cancel a run said: $(out)"
! r cancel "$run" || fail "cancelled twice"
[ "$(out)" = "morca: run $run is cancelled already" ] || fail "cancel again said: $(out)"
r start toy 2024-05..2024-06 || fail "start: $(out)"
started=$(q "SELECT max(id) FROM orca.runs")
[ "$(out)" = "queued run $started" ] || fail "start said: $(out)"
[ "$(q "SELECT trigger || ' ' || partitions FROM orca.runs WHERE id = $started")" = "cli 2024-05,2024-06" ] \
    || fail "start's run"
# The runs filter tells morca start's runs from the site's.
[ "$(curl -fsS -H 'Accept: application/json' "$base/runs?trigger=cli" | jq -r '[.runs[].id] | join(",")')" = "$started" ] \
    || fail "?trigger=cli"
curl -fsS -H 'Accept: application/json' "$base/runs?trigger=ui" | jq -e --argjson s "$started" '[.runs[].id] | index($s) == null' > /dev/null \
    || fail "?trigger=ui has morca start's run"
# Without --remote, morca start's run is cli too.
local_start=$(./build/morca start toy 2024-07 2>&1) || fail "a local start: $local_start"
[ "$(q "SELECT trigger FROM orca.runs WHERE id = (SELECT max(id) FROM orca.runs)")" = cli ] || fail "a local start's trigger"
q "UPDATE orca.runs SET status = 'cancelled', ended = now() WHERE id = (SELECT max(id) FROM orca.runs)" > /dev/null
r rerun "$run" days || fail "rerun: $(out)"
rerun=$(q "SELECT max(id) FROM orca.runs")
[ "$(out)" = "queued run $rerun rerunning run $run from step days" ] || fail "rerun said: $(out)"
[ "$(q "SELECT trigger FROM orca.runs WHERE id = $rerun")" = rerun ] || fail "rerun's run"
! r rerun "$run" nosuch || fail "a rerun from no step"
[ "$(out)" = "morca: pipeline toy has no step nosuch" ] || fail "rerun refused: $(out)"
[ "$(q "SELECT count(*) FROM orca.audit WHERE source = 'cli' AND username = 'alice'
        AND action LIKE '/%' AND action <> '/api/login'")" -eq 10 ] \
    || fail "the actions' audit: $(q "SELECT action, source FROM orca.audit ORDER BY id")"
[ "$(q "SELECT count(*) FROM orca.audit WHERE run = $run AND source = 'cli'")" -eq 2 ] \
    || fail "the run's audit"
curl -fs "$base/runs/$run" | grep -q '<td>alice</td><td>/runs/[0-9]*/resume</td><td>cli</td>' \
    || fail "the run's page doesn't say the resume came from the cli"
# Not a dataset: refused as locally.
! r rebuild nosuch 2024-01 || fail "a rebuild of nothing"
remote_said=$(out)
! ./build/morca rebuild nosuch 2024-01 > build/remote-out.txt 2>&1 || fail "a local rebuild of nothing"
[ "$remote_said" = "$(out)" ] || fail "rebuild refusals differ: $remote_said / $(out)"
grep -q "$token" "$log" && fail "the token is in the UI's log"

# Tokens that are no use: 401 and nothing done, a cookie alongside or not.
# p STATUS HEADER...: a JSON pause, as morca sends it.
p() {
    want=$1; shift
    code=$(curl -s -o build/remote-body.txt -w '%{http_code}' -H 'Content-Type: application/json' \
        -d '{}' "$@" "$base/pipelines/toy/pause")
    [ "$code" = "$want" ] || fail "a pause with $* answered $code: $(cat build/remote-body.txt)"
}
jar=build/remote-cookies.txt
curl -s -o /dev/null -c "$jar" -H "Origin: $base" -d 'name=alice&password=correct+horse+battery' "$base/login"
p 401 -H "Authorization: Bearer orca_$(printf '%064d' 0)"
grep -q 'expired or revoked' build/remote-body.txt || fail "a refused token's answer"
p 401 -H "Authorization: Bearer not-a-token"
p 401 -H "Authorization: Basic YWxpY2U6eA=="
p 401 -H "Authorization: Bearer orca_$(printf '%064d' 0)" -b "$jar"
p 403 -H "$auth" -H "Origin: http://evil.example"
p 403 -b "$jar"
[ "$(q "SELECT paused FROM orca.pipelines")" = f ] || fail "a refused token paused"
# No preflight is ever allowed, so another site's page can't send a token
# or a JSON login.
hdrs=$(curl -s -D - -o /dev/null -X OPTIONS -H 'Origin: http://evil.example' \
    -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: authorization' \
    "$base/pipelines/toy/pause" | tr -d '\r')
echo "$hdrs" | head -1 | grep -q ' 405' || fail "a preflight answered: $hdrs"
! echo "$hdrs" | grep -qi '^access-control-allow' || fail "a preflight was allowed: $hdrs"
# A login for a token that isn't JSON is a form, which needs the UI's own
# Origin like any other, and then is refused for not being JSON.
code=$(curl -s -o /dev/null -w '%{http_code}' -d 'name=alice&password=correct+horse+battery' "$base/api/login")
[ "$code" = 403 ] || fail "a form login for a token answered $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Origin: $base" -d 'name=alice&password=correct+horse+battery' \
    "$base/api/login")
[ "$code" = 400 ] || fail "a same-site form login for a token answered $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H 'Origin: http://evil.example' \
    -d '{"name": "alice", "password": "correct horse battery"}' "$base/api/login")
[ "$code" = 403 ] || fail "a token login from another site answered $code"
q "UPDATE orca.api_tokens SET expires = now() - interval '1 second'" > /dev/null
! r pause toy || fail "an expired token paused"
out | grep -q 'the token has expired or been revoked; morca login' || fail "expired said: $(out)"
p 401 -H "$auth"

# Revoked by an admin, by a new password, and by logging out.
login() { printf '%s\n' "${2:-correct horse battery}" | ./build/morca login "$base" --user "$1" > build/remote-out.txt 2>&1; }
login alice || fail "login again: $(out)"
./build/morca user tokens alice > build/remote-out.txt
[ "$(wc -l < build/remote-out.txt)" -eq 1 ] || fail "expired tokens weren't removed: $(out)"
id=$(cut -d' ' -f1 build/remote-out.txt)
out | grep -q "^$id $(hostname | cut -c1-64) created 20.* used never expires 20" || fail "user tokens: $(out)"
r pause toy || fail "pause after a new login: $(out)"
./build/morca user tokens alice | grep -q ' used 20' || fail "last used wasn't recorded"
[ "$(./build/morca user revoke alice "$id")" = "revoked 1 token of alice" ] || fail "user revoke"
! r unpause toy || fail "a revoked token unpaused"
out | grep -q 'expired or been revoked' || fail "revoked said: $(out)"
login alice || fail "login after revoke"
printf 'a new long password\n' | ./build/morca user add alice >> "$log" 2>&1
[ "$(q "SELECT count(*) FROM orca.api_tokens")" -eq 0 ] || fail "a new password kept the tokens"
login alice 'a new long password' || fail "login with the new password: $(out)"
MORCA_REMOTE="$base" ./build/morca logout > build/remote-out.txt 2>&1 || fail "logout: $(out)"
[ "$(out)" = "logged out of $base" ] || fail "logout said: $(out)"
[ "$(q "SELECT count(*) FROM orca.api_tokens")" -eq 0 ] || fail "logout didn't revoke"
[ "$(q "SELECT action FROM orca.audit ORDER BY id DESC LIMIT 1")" = /api/logout ] || fail "logout's audit"
! grep -q "$base" "$MORCA_CREDENTIALS" || fail "logout kept the token"
! r unpause toy || fail "an action after logout"
login alice 'a new long password' || fail "login for --days: $(out)"
./build/morca user revoke alice @all > /dev/null
./build/morca logout "$base" > build/remote-out.txt 2>&1 || fail "logout of a revoked token: $(out)"
out | grep -q 'already expired or been revoked' || fail "logout of a revoked token said: $(out)"
printf 'a new long password\n' | ./build/morca login "$base" --user alice --days 2 > /dev/null 2>&1 \
    || fail "login --days"
[ "$(q "SELECT expires < now() + interval '2 days 1 minute' FROM orca.api_tokens")" = t ] || fail "--days 2"
# MORCA_REMOTE picks the UI, with no database at all.
env -u MORCA_DATABASE_URL MORCA_REMOTE="$base" ./build/morca unpause toy > build/remote-out.txt 2>&1 \
    || fail "MORCA_REMOTE: $(out)"
[ "$(out)" = "unpaused toy" ] || fail "MORCA_REMOTE said: $(out)"

# Guessing: as /login, 5 failures for a name, then 429.
printf 'correct horse battery\n' | ./build/morca user add carol >> "$log" 2>&1
for _ in 1 2 3 4 5; do
    ! login carol 'wrong guess here' || fail "a wrong guess logged in"
done
! login carol || fail "a sixth try wasn't refused"
out | grep -q 'Too many failed logins' || fail "the sixth try said: $(out)"
[ "$(q "SELECT count(*) FROM orca.audit WHERE action = 'login-failed' AND username = 'carol' AND source = 'cli'")" -eq 5 ] \
    || fail "the failures weren't recorded"

# The credentials file, and where a token may go.
chmod 644 "$MORCA_CREDENTIALS"
! r pause toy || fail "credentials others can read were used"
out | grep -q 'can be read by others' || fail "an open credentials file: $(out)"
chmod 600 "$MORCA_CREDENTIALS"
! printf 'x\n' | ./build/morca login http://morca.example.com --user alice > build/remote-out.txt 2>&1 \
    || fail "a login over plain http"
out | grep -q 'plain http' || fail "plain http said: $(out)"
kill "$ui"
echo "ok   remote"
