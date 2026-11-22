#!/bin/sh
# Pipeline versions (morca.source): the toy built from two commits and once
# without a source. Each registration and each run records the version it
# is, the pipeline page lists all three with their runs, and each run's page
# links its own commit. Needs MORCA_DATABASE_URL (pixi run test-versions
# starts a throwaway server), curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build
repo=https://github.com/morca-dev/morca
c1=1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a
c2=2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b
# The toy at two commits: links to scripts/pipelines.sh's binary that run
# it with each one's source, as -D would give it (tests/test_source.mojo
# checks the defines themselves).
scripts/pipelines.sh --as toy-c1 toy MORCA_SOURCE=$repo.git MORCA_COMMIT=$c1
scripts/pipelines.sh --as toy-c2 toy MORCA_SOURCE=git@github.com:morca-dev/morca.git MORCA_COMMIT=$c2 MORCA_DIRTY=1
scripts/pipelines.sh toy
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca

log=build/versions.log
: > "$log"
q() { psql "$MORCA_DATABASE_URL" -Atc "$1"; }
pid=
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    [ -z "$pid" ] || kill "$pid" 2> /dev/null || true
    exit 1
}

./build/toy-c1 describe | jq -e ".source == {\"repo\": \"$repo.git\", \"commit\": \"$c1\", \"dirty\": false}" > /dev/null \
    || fail "describe's source: $(./build/toy-c1 describe | jq -c .source)"
./build/toy describe | jq -e '.source == {"repo": "", "commit": "", "dirty": false}' > /dev/null \
    || fail "describe without a source"
# Built without the defines, a binary reads them from its environment (an
# image's ENV); a define (here the link's) still wins, and a commit that
# isn't hex is dropped.
MORCA_SOURCE=$repo MORCA_COMMIT=$c2 ./build/toy describe \
    | jq -e ".source == {\"repo\": \"$repo\", \"commit\": \"$c2\", \"dirty\": false}" > /dev/null \
    || fail "describe's source from the environment: $(MORCA_SOURCE=$repo MORCA_COMMIT=$c2 ./build/toy describe | jq -c .source)"
MORCA_SOURCE=elsewhere MORCA_COMMIT=$c2 ./build/toy-c1 describe | jq -e ".source.commit == \"$c1\" and .source.repo == \"$repo.git\"" > /dev/null \
    || fail "the environment overrode the defines"
MORCA_COMMIT=not-a-sha ./build/toy describe | jq -e '.source.commit == ""' > /dev/null \
    || fail "a commit that isn't hex from the environment"
[ "$(./build/toy-c1 describe | jq -r .registry_hash)" = "$(./build/toy describe | jq -r .registry_hash)" ] \
    || fail "the source changed the registry hash"

./build/morca locate ./build/toy-c1 --root . >> "$log" 2>&1 || fail "locate c1"
./build/morca register --image morca:c1 ./build/toy-c1 >> "$log" 2>&1 || fail "register c1"
MORCA_IMAGE=morca:c1 ./build/toy-c1 run --partitions 2024-01 >> "$log" 2>&1 || fail "run c1"
./build/morca register ./build/toy-c2 >> "$log" 2>&1 || fail "register c2"
MORCA_IMAGE=morca:c1 ./build/toy-c2 run --partitions 2024-02 >> "$log" 2>&1 || fail "run c2"
./build/toy run --partitions 2024-03 >> "$log" 2>&1 || fail "run without a source"
r1=$(q "SELECT min(id) FROM orca.runs")
r3=$(q "SELECT max(id) FROM orca.runs")
r2=$(q "SELECT id FROM orca.runs WHERE id > $r1 AND id < $r3")

[ "$(q "SELECT count(*) FROM orca.pipeline_versions")" -eq 3 ] \
    || fail "versions: $(q "SELECT commit_sha, dirty, image FROM orca.pipeline_versions")"
# A run by hand records its version but leaves the registered one (#59).
[ "$(q "SELECT v.commit_sha FROM orca.pipelines p JOIN orca.pipeline_versions v ON v.id = p.version")" = $c2 ] \
    || fail "the pipeline's version isn't the last registered binary's"
# A resume records the version that resumed it.
q "UPDATE orca.runs SET status = 'failed', heartbeat = NULL WHERE id = $r3" > /dev/null
MORCA_IMAGE=morca:c1 ./build/toy-c1 resume "$r3" >> "$log" 2>&1 || fail "resume with c1"
[ "$(q "SELECT v.commit_sha FROM orca.runs r JOIN orca.pipeline_versions v ON v.id = r.version WHERE r.id = $r3")" = $c1 ] \
    || fail "the resumed run's version"
q "UPDATE orca.runs SET status = 'failed', heartbeat = NULL WHERE id = $r3" > /dev/null
./build/toy resume "$r3" >> "$log" 2>&1 || fail "resume without a source"

free_port port
base="http://127.0.0.1:$port"
MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
pid=$!
i=0
until curl -fs "$base/" > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
done
json() { curl -fsS -H 'Accept: application/json' "$base$1" || fail "GET $1 as JSON"; }
html() { curl -fsS "$base$1" || fail "GET $1"; }

json "/runs/$r1" | jq -e ".version.commit == \"$c1\" and .version.image == \"morca:c1\" and .version.commit_url == \"$repo/tree/$c1\" and (.version.dirty | not)" > /dev/null \
    || fail "run $r1's version: $(json "/runs/$r1" | jq -c .version)"
json "/runs/$r2" | jq -e ".version.commit_url == \"$repo/tree/$c2\" and .version.dirty" > /dev/null \
    || fail "run $r2's version: $(json "/runs/$r2" | jq -c .version)"
json "/runs/$r3" | jq -e '.version.commit == "" and .version.commit_url == null' > /dev/null \
    || fail "run $r3's version: $(json "/runs/$r3" | jq -c .version)"
html "/runs/$r1" | grep -qF "<a class=\"src\" href=\"$repo/tree/$c1\" target=\"_blank\" rel=\"noopener\" title=\"View source on GitHub at 1a1a1a1\"><svg class=\"src__icon\"" \
    || fail "run $r1's page links its commit"
html "/runs/$r2" | grep -q "plus uncommitted changes" || fail "run $r2's page says it was dirty"
html "/runs/$r3" | grep -q "not recorded" || fail "run $r3's page says it has no source"
# The steps' code, at the commit, for the version morca locate mapped.
line=$(grep -n '^def days(' examples/toy.mojo | cut -d: -f1)
# A code link: the icon, out of the screen reader's way, the file and line
# in monospace, and an arrow out, in a new tab; unlike morca's own links.
icon='<svg class="src__icon" viewBox="0 0 16 16" width="12" height="12" aria-hidden="true" focusable="false">'
code_link() { # url, commit
    printf '<a class="src" href="%s" target="_blank" rel="noopener" title="View source on GitHub at %.7s">%s' "$1" "$2" "$icon"
}
code_at() { printf '<span class="src__at">%s</span><span class="src__out" aria-hidden="true">↗</span></a>' "$1"; }
page=$(html "/runs/$r1")
echo "$page" | grep -qF "tabindex=\"0\">days</span> $(code_link "$repo/blob/$c1/examples/toy.mojo#L$line" $c1)" \
    || fail "run $r1's page links its steps' code"
# The step's card (morca.ui.step_cards) has its code at the run's commit too.
got=$(echo "$page" | sed -n 's/.*<script type="application\/json" class="step-cards">\([^<]*\)<\/script>.*/\1/p' | jq -r '.steps.days | [.src, .at, .commit] | join(" ")')
[ "$got" = "$repo/blob/$c1/examples/toy.mojo#L$line examples/toy.mojo:$line 1a1a1a1" ] || fail "days' card's code: $got"
echo "$page" | grep -qF "$(code_at "examples/toy.mojo:$line")" || fail "the code link doesn't show the file and line"
echo "$page" | grep -qF '<a class="src" href="/' && fail "an internal link took the code link's look"
echo "$page" | grep -o '<a class="src"[^>]*>' | grep -vq 'target="_blank" rel="noopener" title="View source' \
    && fail "a code link without its target or title"
curl -fsS "$base/static/morca.css" | grep -q '^a.src {' || fail "the stylesheet has no code link style"
att=$(json "/runs/$r1" | jq -r '.steps[0].attempt_id')
html "/runs/$r1/attempts/$att" | grep -qF "<dt>Code</dt><dd>$(code_link "$repo/blob/$c1/examples/toy.mojo#L$line" $c1)" \
    || fail "the attempt's page doesn't link its step's code"
json "/runs/$r1" | jq -e '.version.locations["toy::measure"] | startswith("examples/toy.mojo#L")' > /dev/null \
    || fail "run $r1's locations"

# Newest first: the bare binary, then c2 (registered without --image, so
# with the image the pipeline has), then c1.
got=$(json /pipelines/toy | jq -c '[.versions[] | [.commit[0:1], .image, .runs]]')
[ "$got" = '[["","",1],["2","morca:c1",1],["1","morca:c1",1]]' ] || fail "the pipeline's versions: $got"
html '/pipelines/toy?tab=runs' | grep -q "<h2>Versions" || fail "the pipeline page's versions"

# A dataset's page links the steps that write and read it to their lines:
# the writer at the commit of the run that committed the snapshot (c1), the
# reader, which no run has read with, at the one registered now (c2).
for c in 1 2; do
    eval "sha=\$c$c"
    src=$repo.git
    [ "$c" = 2 ] && src=git@github.com:morca-dev/morca.git
    scripts/pipelines.sh --as "ds-first-c$c" ds-first "MORCA_SOURCE=$src" "MORCA_COMMIT=$sha"
    ./build/morca locate "./build/ds-first-c$c" --root . >> "$log" 2>&1 || fail "locate first c$c"
done
./build/morca register ./build/ds-first-c1 >> "$log" 2>&1 || fail "register first c1"
./build/ds-first-c1 run --partitions 2024-01 >> "$log" 2>&1 || fail "run first c1"
q "INSERT INTO orca.commits (attempt, table_name, snapshot_id, dataset) SELECT a.id, 'a', 7, 'lake.a' FROM orca.attempts a JOIN orca.steps s ON s.id = a.step JOIN orca.runs r ON r.id = s.run WHERE r.pipeline = 'first'" > /dev/null
./build/morca register ./build/ds-first-c2 >> "$log" 2>&1 || fail "register first c2"
fline=$(grep -n '^def step(' tests/datasets/first.mojo | cut -d: -f1)
# The pipeline page's Code card: each function by its name, where it is in
# the title, at the commit registered now (c2).
page=$(html /pipelines/first)
echo "$page" | grep -qF "<a class=\"src\" href=\"$repo/blob/$c2/tests/datasets/first.mojo#L$fline\" target=\"_blank\" rel=\"noopener\" title=\"View source on GitHub at 2b2b2b2: tests/datasets/first.mojo:$fline\">$icon" \
    || fail "the Code card doesn't link the step's line"
echo "$page" | grep -qF '<span class="src__at">step</span>' || fail "the Code card's link isn't the step's name"
page=$(html /datasets/lake.a)
echo "$page" | grep -qF "<dt>Written by</dt><dd><a href=\"/pipelines/first\">first</a> <span class=\"steps-of\">step step $(code_link "$repo/blob/$c1/tests/datasets/first.mojo#L$fline" $c1)" \
    || fail "the dataset's page doesn't link its writer's code at the run's commit: $(echo "$page" | grep -o '<dt>Written by.*</dl>')"
echo "$page" | grep -qF "$(code_at "tests/datasets/first.mojo:$fline")" || fail "the writer's code link doesn't show its file and line"
echo "$page" | grep -qF "<td>step $(code_link "$repo/blob/$c1/tests/datasets/first.mojo#L$fline" $c1)" \
    || fail "the snapshot doesn't link its step's code"
html /datasets/lake.c | grep -qF "<dt>Read by</dt><dd><a href=\"/pipelines/first\">first</a> <span class=\"steps-of\">step step $(code_link "$repo/blob/$c2/tests/datasets/first.mojo#L$fline" $c2)" \
    || fail "the dataset's page doesn't link its reader's code at the registered commit"
json /datasets/lake.a | jq -e '.writers == ["first"] and .snapshots[0].snapshot == 7' > /dev/null \
    || fail "the dataset's JSON changed: $(json /datasets/lake.a | jq -c .)"
# Hover cards on the lists (the page's _PEEK): a runs table's pipeline
# shows its declaration at the commit the run ran, a failed run names the
# step that failed with its function's link; the home page's pipelines
# (list and timeline) theirs at the code registered now. Nothing is
# fetched until a hover; every card opens with its docstring's lead.
pl=$(json "/runs/$r1" | jq -r '.version.locations.pipeline')
[ -n "$pl" ] && [ "$pl" != null ] || fail "run $r1 has no pipeline location"
html /runs | grep -qF "<td><a href=\"/pipelines/toy\" data-src=\"$repo/blob/$c1/$pl\">toy</a></td>" \
    || fail "the runs list's pipeline doesn't show run $r1's code"
html /runs | grep -qF '<td><a href="/pipelines/toy">toy</a></td>' || fail "a run without locations has a code hover"
mline=$(grep -n '^def measure(' examples/toy.mojo | cut -d: -f1)
q "UPDATE orca.runs SET status = 'failed' WHERE id = $r1" > /dev/null
q "UPDATE orca.steps SET status = 'failed' WHERE run = $r1 AND step = 'measure'" > /dev/null
for path in /runs "/pipelines/toy?tab=runs" "/runs/table?view=pipeline&pipeline=toy" "/runs/table?view=home"; do
    html "$path" | grep -qF "status--failed\">failed</span> <span class=\"muted\">in</span> <a class=\"src\" href=\"$repo/blob/$c1/examples/toy.mojo#L$mline\"" \
        || fail "$path doesn't name run $r1's failed step with its code"
done
q "UPDATE orca.steps SET status = 'succeeded' WHERE run = $r1 AND step = 'measure'" > /dev/null
q "UPDATE orca.runs SET status = 'succeeded' WHERE id = $r1" > /dev/null
dline=$(grep -n '^comptime P = Pipeline\[' tests/datasets/first.mojo | cut -d: -f1)
for path in / /home/pipelines; do
    html "$path" | grep -qF "<tr><td><a href=\"/pipelines/first\" data-src=\"$repo/blob/$c2/tests/datasets/first.mojo#L$dline\">first</a>" \
        || fail "$path's pipeline doesn't show its registered code"
done
[ "$(json /api/gantt | jq -r '.rows[] | select(.pipeline == "first") | .src')" = "$repo/blob/$c2/tests/datasets/first.mojo#L$dline" ] \
    || fail "the timeline's row has no code: $(json /api/gantt | jq -c '.rows')"
page=$(html /runs)
echo "$page" | grep -qF 't.closest("a.src, a[data-src]")' || fail "the peek doesn't take data-src links"
echo "$page" | grep -qF 'document.addEventListener("morca:swap", () => { if (cur && !cur.isConnected) hide(0); });' \
    || fail "the peek doesn't follow a refresh"
echo "$page" | grep -qF 'function morcaLead(doc)' || fail "the cards have no lead sentence"
echo "$page" | grep -qF 'const doc = own || (isDef ? null : moduleDoc(src.lines));' || fail "a pipeline's card doesn't fall back to its module's docstring"
# A run in another image than the one registered is another version row,
# which morca locate's map wasn't put on: it has the map of the same code
# at the same commit, on the run's page and, now the newest, on the
# pipeline's (#583).
MORCA_IMAGE=morca:other ./build/toy-c1 run --partitions 2024-04 >> "$log" 2>&1 || fail "run c1 in another image"
r4=$(q "SELECT max(id) FROM orca.runs WHERE pipeline = 'toy'")
[ "$(q "SELECT v.image, v.locations IS NULL FROM orca.runs r JOIN orca.pipeline_versions v ON v.id = r.version WHERE r.id = $r4")" = "morca:other|t" ] \
    || fail "run $r4's version row isn't a new one without locations"
json "/runs/$r4" | jq -e '.version.image == "morca:other" and (.version.locations["toy::measure"] | startswith("examples/toy.mojo#L"))' > /dev/null \
    || fail "run $r4, in another image, has no locations: $(json "/runs/$r4" | jq -c .version)"
html "/runs/$r4" | grep -qF "tabindex=\"0\">days</span> $(code_link "$repo/blob/$c1/examples/toy.mojo#L$line" $c1)" \
    || fail "run $r4's page, in another image, doesn't link its steps' code"
page=$(html /pipelines/toy)
echo "$page" | grep -qF "No links to the code" && fail "the pipeline's page has no links once a run started in another image"
echo "$page" | grep -qF "$(code_link "$repo/blob/$c1/examples/toy.mojo#L$line" $c1)" \
    || fail "the pipeline's page doesn't link days' code"
kill "$pid"

# The morca a pipeline was built with (#455): describe says it, `morca
# version` prints this one's, and register refuses another's unless
# MORCA_MIXED_VERSIONS=1, when it warns.
want=$(sed -n '/^\[package\]/,/^\[/s/^version = "\(.*\)"$/\1/p' pixi.toml)
[ "$(./build/morca version)" = "morca $want" ] || fail "morca version: $(./build/morca version 2>&1)"
./build/toy describe | jq -e ".morca == \"$want\"" > /dev/null || fail "describe's morca: $(./build/toy describe | jq -c .morca)"
./build/toy describe | sed -e 's/"pipeline": "toy"/"pipeline": "toy_old"/' -e 's/"morca": "[^"]*"}$/"morca": "0.0.1"}/' \
    > build/toy-old.json
printf '#!/bin/sh\ncat "%s"\n' "$PWD/build/toy-old.json" > build/toy-old
chmod +x build/toy-old
out=$(./build/morca register ./build/toy-old 2>&1) && fail "registered a pipeline of another morca: $out"
echo "$out" | grep -qF "toy-old was built with morca 0.0.1 and this morca is $want: build the pipelines with" \
    || fail "the refusal: $out"
[ "$(q "SELECT count(*) FROM orca.pipelines WHERE name = 'toy_old'")" = 0 ] || fail "the refused pipeline is registered"
out=$(MORCA_MIXED_VERSIONS=1 ./build/morca register ./build/toy-old 2>&1) || fail "MORCA_MIXED_VERSIONS=1 register: $out"
echo "$out" | grep -qF "morca: warning: $PWD/build/toy-old was built with morca 0.0.1" || fail "no warning: $out"
# The protocol version (#525): a binary not built with morca-mojo says
# `protocol` and no `morca`, in compact JSON (#524), and registers; one of
# a protocol this morca doesn't speak is refused, MORCA_MIXED_VERSIONS or not.
./build/toy describe | jq -e '.protocol == 1' > /dev/null || fail "describe's protocol: $(./build/toy describe | jq -c .protocol)"
./build/toy describe | jq -c '.pipeline = "toy_sdk" | del(.morca)' > build/toy-sdk.json
printf '#!/bin/sh\ncat "%s"\n' "$PWD/build/toy-sdk.json" > build/toy-sdk
chmod +x build/toy-sdk
out=$(./build/morca register ./build/toy-sdk 2>&1) || fail "register a protocol-only describe: $out"
echo "$out" | grep -qF warning && fail "a protocol-only describe warned: $out"
[ "$(q "SELECT count(*) FROM orca.pipelines WHERE name = 'toy_sdk'")" = 1 ] || fail "the protocol-only pipeline isn't registered"
jq -c '.pipeline = "toy_next" | .protocol = 2' build/toy-sdk.json > build/toy-next.json
printf '#!/bin/sh\ncat "%s"\n' "$PWD/build/toy-next.json" > build/toy-next
chmod +x build/toy-next
out=$(MORCA_MIXED_VERSIONS=1 ./build/morca register ./build/toy-next 2>&1) && fail "registered protocol 2: $out"
echo "$out" | grep -qF "toy-next speaks pipeline protocol 2 and this morca speaks 1" || fail "the protocol refusal: $out"
[ "$(q "SELECT count(*) FROM orca.pipelines WHERE name = 'toy_next'")" = 0 ] || fail "the protocol-2 pipeline is registered"
echo "ok   versions: a run links the commit it ran, the pipeline lists its versions, register checks the morca and the protocol"
