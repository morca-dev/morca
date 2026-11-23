#!/bin/sh
# Login to morca ui's actions (morca.auth), over HTTP only, as tests/actions.sh
# is. With no user and no MORCA_UI_LOGIN, actions are open, as before. Once a
# user exists:
#
# - an action without a session gets 401 (JSON) or the login page (HTML),
#   and changes nothing; pages still read without one;
# - a wrong password gets 401 and no cookie; the right one a session cookie
#   that's HttpOnly and SameSite=Strict, and a `next` off the site is
#   ignored;
# - with the cookie the action is done and recorded as the user's, which the
#   run's page shows;
# - logging out, an expired session, a removed user and a changed password
#   all end the session; a login posted from another site is refused;
# - behind a TLS proxy (MORCA_UI_TRUST_PROXY=1, X-Forwarded-Proto) or with
#   MORCA_UI_SECURE_COOKIES=1, an https Origin is the UI's own;
# - 5 failed logins for a name in 15 minutes get 429, the right password
#   included, until the window passes;
# - /healthz answers 200 "ok" without a login, login required or not;
# - a crawler that names itself gets 403, but /robots.txt and /healthz.
#
# Needs MORCA_DATABASE_URL (pixi run test-ui-login starts a throwaway server),
# curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build
scripts/pipelines.sh toy
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca
log=build/ui-login.log
: > "$log"
ui=
fail() {
    echo "FAIL: $*"
    tail -20 "$log"
    [ -z "$ui" ] || kill "$ui" 2> /dev/null || true
    exit 1
}
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
./build/morca register ./build/toy >> "$log" 2>&1 || fail "register"
free_port port
base="http://127.0.0.1:$port"
MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
ui=$!
i=0
until curl -fs "$base/" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
done
jar=build/ui-login-cookies.txt
rm -f "$jar"
# post PATH BODY [curl args]: the status, as the UI's own form would send it.
post() {
    p=$1; b=$2; shift 2
    curl -s -o build/ui-login-body.txt -w '%{http_code}' -H "Origin: $base" -d "$b" "$@" "$base$p"
}
runs() { q "SELECT count(*) FROM orca.runs"; }

# No user: open, as before.
[ "$(post /pipelines/toy/runs partitions=2024-01)" = 303 ] || fail "an action with no users"
[ "$(runs)" -eq 1 ] || fail "the open action made no run"

# A user: actions need a session.
printf 'correct horse battery\n' | ./build/morca user add alice >> "$log" 2>&1 || fail "user add"
[ "$(./build/morca user list)" = alice ] || fail "user list"
[ "$(q "SELECT password_hash LIKE '\$2a\$12\$%' FROM orca.users")" = t ] || fail "not a bcrypt hash"
[ "$(post /pipelines/toy/runs partitions=2024-02 -H 'Accept: application/json')" = 401 ] || fail "JSON without a session"
[ "$(post /pipelines/toy/runs partitions=2024-02 -H "Referer: $base/pipelines/toy")" = 303 ] || fail "HTML without a session"
loc=$(curl -s -o /dev/null -w '%{redirect_url}' -H "Origin: $base" -H "Referer: $base/pipelines/toy" -d partitions=2024-02 "$base/pipelines/toy/runs")
[ "$loc" = "$base/login?next=%2Fpipelines%2Ftoy" ] || fail "sent to $loc"
[ "$(runs)" -eq 1 ] || fail "an action without a session made a run"
curl -fs "$base/runs" > /dev/null || fail "reading needs no session"
curl -fs "$base/" | grep -q 'href="/login">Log in' || fail "no way to log in"
# Logged out, each inline action is a link to log in that comes back here,
# and its POST still needs a session.
page=$(curl -fs "$base/pipelines/toy")
echo "$page" | grep -q '<body class="anon">' || fail "the logged-out page isn't anon"
echo "$page" | grep -qF '<a class="act__login" href="/login?next=%2Fpipelines%2Ftoy" title="morca pause toy">Log in to pause</a>' \
    || fail "no Log in to pause"
page=$(curl -fs "$base/runs?status=queued")
echo "$page" | grep -qF 'href="/login?next=%2Fruns%3Fstatus%3Dqueued"' || fail "the login link doesn't come back to /runs"
echo "$page" | grep -qF '>Log in to cancel</a>' || fail "no Log in to cancel"
queued_run=$(q "SELECT max(id) FROM orca.runs")
[ "$(post "/runs/$queued_run/cancel" '' -H 'Accept: application/json')" = 401 ] || fail "the inline cancel without a session"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/runs/$queued_run/cancel")
[ "$code" = 403 ] || fail "the inline cancel without an Origin answered $code"
[ "$(q "SELECT cancel_requested OR status = 'cancelled' FROM orca.runs WHERE id = $queued_run")" = f ] \
    || fail "a cancel without a session or Origin changed the run"

# Logging in.
[ "$(post /login 'name=alice&password=wrong+password&next=/runs' -c "$jar")" = 401 ] || fail "a wrong password"
! grep -q morca_session "$jar" 2> /dev/null || fail "a cookie for a wrong password"
[ "$(post /login 'name=nobody&password=correct+horse+battery' -c "$jar")" = 401 ] || fail "no such user"
hdrs=$(curl -s -D - -o /dev/null -H "Origin: $base" -c "$jar" \
    -d 'name=alice&password=correct+horse+battery&next=//evil.example/x' "$base/login")
# Header lines end in CRLF, which grep's `\r` doesn't match the same way on
# every platform, so the CRs go first.
hdrs=$(echo "$hdrs" | tr -d '\r')
echo "$hdrs" | grep -qix 'location: /' || fail "followed an off-site next: $hdrs"
echo "$hdrs" | grep -i '^set-cookie: morca_session=' | grep -i 'httponly' | grep -qi 'samesite=strict' \
    || fail "the cookie: $hdrs"
[ "$(post /pipelines/toy/runs partitions=2024-02 -b "$jar")" = 303 ] || fail "an action with a session"
run=$(q "SELECT max(id) FROM orca.runs")
[ "$(q "SELECT username || ' ' || action || ' ' || run FROM orca.audit WHERE action <> 'login-failed'")" \
    = "alice /pipelines/toy/runs $run" ] || fail "the audit: $(q "SELECT * FROM orca.audit")"
curl -fs -b "$jar" "$base/runs/$run" | grep -q '<td>alice</td>' || fail "the run's page doesn't say who"
curl -fs -b "$jar" "$base/" | grep -q 'class="top__user">alice' || fail "the header doesn't say who"
page=$(curl -fs -b "$jar" "$base/pipelines/toy")
echo "$page" | grep -q '<body>' || fail "the logged-in page is still anon"
echo "$page" | grep -qF 'action="/pipelines/toy/pause"><button type="submit" class="act__btn" title="morca pause toy">Pause</button>' \
    || fail "no Pause button logged in"
[ "$(post "/runs/$run/cancel" '' -b "$jar")" = 303 ] || fail "cancel with a session"
[ "$(q "SELECT count(*) FROM orca.audit WHERE run = $run")" -eq 2 ] || fail "the cancel's audit"

# Bulk actions from a runs list: logged out, the list's boxes and buttons
# are hidden behind a link to log in, and a POST is refused; logged in, each
# run acted on is audited as its own action's, beside the bulk one.
q "INSERT INTO orca.runs (pipeline, registry_hash, partitions, trigger, status)
   SELECT 'toy', registry_hash, '2024-0' || i, 'manual', 'queued' FROM orca.runs, generate_series(5, 7) i
   WHERE id = $run" > /dev/null
b1=$(q "SELECT max(id) - 2 FROM orca.runs"); b2=$((b1 + 1)); b3=$((b1 + 2))
page=$(curl -fs "$base/runs?status=queued")
echo "$page" | grep -qF '<form id="bulk-runs" class="bulk act__need"' || fail "no bulk form for act__need to hide"
echo "$page" | grep -qF '<td class="pick act__need"><input type="checkbox" name="pick" form="bulk-runs"'     || fail "the boxes aren't hidden logged out"
echo "$page" | grep -qF '<p class="act__login bulk__login"><a href="/login?next=%2Fruns%3Fstatus%3Dqueued">Log in</a>'     || fail "no Log in for the bulk actions"
[ "$(post /runs/bulk "do=cancel&pick=$b1&pick=$b2" -H 'Accept: application/json')" = 401 ] || fail "a bulk cancel without a session"
[ "$(post /runs/bulk "do=cancel&all=1&expect=3&status=queued" -H 'Accept: application/json')" = 401 ]     || fail "a bulk cancel of all without a session"
[ "$(q "SELECT count(*) FROM orca.runs WHERE id >= $b1 AND status = 'queued'")" -eq 3 ] || fail "a refused bulk cancel changed runs"
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" -H 'Origin: http://evil.example' -d "do=cancel&pick=$b1" "$base/runs/bulk")
[ "$code" = 403 ] || fail "a bulk cancel from another site answered $code"
[ "$(post /runs/bulk "do=cancel&view=list&status=queued&pick=$b1&pick=$b2&pick=$run" -b "$jar")" = 303 ] || fail "a bulk cancel with a session"
[ "$(q "SELECT string_agg(status, ',' ORDER BY id) FROM orca.runs WHERE id >= $b1")" = cancelled,cancelled,queued ]     || fail "the bulk cancel: $(q "SELECT id, status FROM orca.runs WHERE id >= $b1")"
[ "$(q "SELECT string_agg(action || ' ' || coalesce(run::text, '-') || ' ' || detail, '|' ORDER BY id)
        FROM orca.audit WHERE username = 'alice' AND (action LIKE '/runs/%' AND (run >= $b1 OR run IS NULL))")" \
    = "/runs/$b1/cancel $b1 bulk|/runs/$b2/cancel $b2 bulk|/runs/bulk - do=cancel&view=list&status=queued&pick=$b1&pick=$b2&pick=$run" ] \
    || fail "the bulk cancel's audit: $(q "SELECT action, run, detail FROM orca.audit WHERE username = 'alice'")"

# Ending sessions.
[ "$(post /login 'name=alice&password=correct+horse+battery' -c "$jar")" = 303 ] || fail "log in again"
[ "$(post /logout '' -b "$jar" -c "$jar")" = 303 ] || fail "log out"
[ "$(post /pipelines/toy/runs partitions=2024-03 -b "$jar" -H 'Accept: application/json')" = 401 ] || fail "after logout"
[ "$(post /login 'name=alice&password=correct+horse+battery' -c "$jar")" = 303 ] || fail "log in"
q "UPDATE orca.sessions SET expires = now() - interval '1 second'" > /dev/null
[ "$(post /pipelines/toy/runs partitions=2024-03 -b "$jar" -H 'Accept: application/json')" = 401 ] || fail "an expired session"
[ "$(post /login 'name=alice&password=correct+horse+battery' -c "$jar")" = 303 ] || fail "log in"
printf 'a new long password\n' | ./build/morca user add alice >> "$log" 2>&1
[ "$(post /pipelines/toy/runs partitions=2024-03 -b "$jar" -H 'Accept: application/json')" = 401 ] || fail "after a new password"
[ "$(post /login 'name=alice&password=a+new+long+password' -c "$jar")" = 303 ] || fail "the new password"
./build/morca user remove alice >> "$log" 2>&1
[ "$(q "SELECT count(*) FROM orca.sessions")" -eq 0 ] || fail "sessions of a removed user"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Origin: http://evil.example" \
    -d 'name=alice&password=x' "$base/login")
[ "$code" = 403 ] || fail "a login from another site answered $code"
printf 'short\n' | ./build/morca user add bob > /dev/null 2>&1 && fail "a short password was taken"

# Guessing: 5 failures for a name, then 429 even with the right password.
printf 'correct horse battery\n' | ./build/morca user add carol >> "$log" 2>&1
for _ in 1 2 3 4 5; do
    [ "$(post /login 'name=carol&password=wrong+guess+here')" = 401 ] || fail "a wrong guess"
done
[ "$(post /login 'name=carol&password=correct+horse+battery')" = 429 ] || fail "a sixth try wasn't refused"
[ "$(q "SELECT count(*) FROM orca.audit WHERE action = 'login-failed' AND username = 'carol'")" -eq 5 ] \
    || fail "the failures weren't recorded"
q "UPDATE orca.audit SET at = now() - interval '16 minutes' WHERE action = 'login-failed'" > /dev/null
[ "$(post /login 'name=carol&password=correct+horse+battery')" = 303 ] || fail "after the window"

# MORCA_UI_LOGIN=required: no user yet, and still no action.
kill "$ui"
MORCA_UI_LOGIN=required MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
ui=$!
i=0
until curl -fs "$base/" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start again"; sleep 0.1
done
[ "$(post /pipelines/toy/runs partitions=2024-03 -H 'Accept: application/json')" = 401 ] \
    || fail "MORCA_UI_LOGIN=required with no users"
# /healthz needs no login (morca-stack's deploys wait for it), and says only ok.
[ "$(curl -s -o "$log.healthz" -w '%{http_code}' "$base/healthz")" = 200 ] || fail "/healthz with login required"
[ "$(cat "$log.healthz")" = ok ] || fail "/healthz said: $(cat "$log.healthz")"
[ "$(curl -s -o /dev/null -w '%{http_code}' -I "$base/healthz")" = 200 ] || fail "HEAD /healthz"
rm -f "$log.healthz"

# A crawler that names itself gets 403 on a page, but still /robots.txt
# (which turns it away) and /healthz (a monitor's name may hold "bot").
bot='Mozilla/5.0 (X11; Linux x86_64) Chrome/145.0.0.0 Safari/537.36 (compatible; meta-externalagent/1.1)'
[ "$(curl -s -o /dev/null -w '%{http_code}' -A "$bot" "$base/runs")" = 403 ] || fail "a crawler read /runs"
[ "$(curl -s -o /dev/null -w '%{http_code}' -A "$bot" "$base/login")" = 403 ] || fail "a crawler read /login"
[ "$(curl -s -o /dev/null -w '%{http_code}' -A "$bot" "$base/robots.txt")" = 200 ] || fail "a crawler's /robots.txt"
[ "$(curl -s -o /dev/null -w '%{http_code}' -A "$bot" "$base/healthz")" = 200 ] || fail "a crawler's /healthz"
kill "$ui"

# Behind a proxy that terminates TLS (MORCA_UI_TRUST_PROXY=1), the browser's
# Origin is https://, as X-Forwarded-Proto says; in any case of the host.
# Without the header, or with Origin http:// when it says https, the POST is
# refused.
restart() {
    kill "$ui"; wait "$ui" 2> /dev/null || true
    env "$@" MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
    ui=$!
    i=0
    until curl -fs "$base/" > /dev/null 2>&1; do
        i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't restart"; sleep 0.1
    done
}
MORCA_UI_TRUST_PROXY=1 MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
ui=$!
i=0
until curl -fs "$base/" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start behind a proxy"; sleep 0.1
done
https="https://127.0.0.1:$port"
# hpost ORIGIN PATH BODY [curl args]: the status of a POST as a browser on
# ORIGIN sends it.
hpost() {
    o=$1; p=$2; b=$3; shift 3
    curl -s -o build/ui-login-body.txt -w '%{http_code}' -H "Origin: $o" -d "$b" "$@" "$base$p"
}
login='name=carol&password=correct+horse+battery'
[ "$(hpost "$https" /login "$login" -H 'X-Forwarded-Proto: https' -c "$jar")" = 303 ] \
    || fail "a login through an https proxy: $(cat build/ui-login-body.txt)"
[ "$(hpost "$https" /pipelines/toy/runs partitions=2024-04 -H 'X-Forwarded-Proto: https' -b "$jar")" = 303 ] \
    || fail "an action through an https proxy"
[ "$(hpost "https://127.0.0.1:$port" /logout '' -H 'X-Forwarded-Proto: HTTPS' -H "Host: 127.0.0.1:$port")" = 303 ] \
    || fail "X-Forwarded-Proto in upper case"
[ "$(hpost "HTTPS://127.0.0.1:$port" /login "$login" -H 'X-Forwarded-Proto: https')" = 303 ] \
    || fail "an Origin in upper case"
[ "$(hpost "$base" /login "$login" -H 'X-Forwarded-Proto: https')" = 403 ] \
    || fail "an http Origin when the proxy says https"
[ "$(hpost "$https" /login "$login")" = 403 ] || fail "an https Origin with no X-Forwarded-Proto"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Referer: $https/pipelines/toy" -H 'X-Forwarded-Proto: https' \
    -d "$login" "$base/login")" = 303 ] || fail "an https Referer through the proxy"
[ "$(hpost "https://evil.example" /login "$login" -H 'X-Forwarded-Proto: https')" = 403 ] \
    || fail "another site through the proxy"
# Without a trusted proxy, X-Forwarded-Proto is ignored; secure cookies
# imply https.
restart
[ "$(hpost "$https" /login "$login" -H 'X-Forwarded-Proto: https')" = 403 ] \
    || fail "X-Forwarded-Proto believed without MORCA_UI_TRUST_PROXY"
restart MORCA_UI_SECURE_COOKIES=1
[ "$(hpost "$https" /login "$login")" = 303 ] || fail "an https Origin with secure cookies"
[ "$(hpost "$base" /login "$login")" = 403 ] || fail "an http Origin with secure cookies"
kill "$ui"
echo "ok   ui login"
