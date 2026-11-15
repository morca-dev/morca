#!/bin/sh
# A dataset's Data tab (#435, morca._internal.ui.data) over lake.obs, which
# tests/dataview/obs.mojo writes: 150 rows a month, partitioned by month
# and city, for 2024-01 and 2024-02. morca ui reads it through
# morca_maintain data (morca._internal.dataread):
#
# - the schema (field ids, types, docs) and the partition spec;
# - the partitions, from the manifests: rows, files, bytes, last snapshot;
# - a page of 100 rows, then the next by its cursor, and the last;
# - filters (eq, gt, in) that prune files, a column pick and a sort, and an
#   earlier snapshot;
# - the chart's data, averaged by x, and its SVG as a line and as bars;
# - the layout (#499): the commit bar (a picker, newest first and selected,
#   ?snapshot= in the URL, arrows to the commit before and after, the row
#   count), then Data | Schema with the table first and each column's type
#   under its header, then the partitions and the chart;
# - the CSV download, capped (MORCA_DATA_DOWNLOAD_ROWS), with why it stopped;
# - a page's row cap, a filter on a column that isn't one (400), and the
#   time and memory limits, each saying why the read stopped;
# - over lake.small and lake.wide, which tests/dataview/many.mojo writes a
#   commit a day to (many snapshots, manifests and small files): a later
#   page skips the files before it by their counts and reads the rest
#   together, with the same rows as a read from the start; the manifests
#   and the partitions are kept in MORCA_DATA_CACHE, so the next read
#   fetches none; and a Data link marks the page as loading once clicked;
# - the cache's own tests (tests/test_datacache.mojo); a kept file cut
#   short, or one that doesn't parse, is fetched again; and below the
#   free space to keep (MORCA_DATA_CACHE_MIN_FREE_MB) nothing is kept;
# - a pipeline's Data tab: the first rows of each dataset it writes, through
#   the same reader, linked to the dataset's Data tab;
# - a download that can't be written (no directory; a full disk, as
#   /dev/full is on Linux) is an error, not a crash;
# - [datasets."lake.obs"] public = false hides the data from visitors not
#   logged in once login is on (401), not from those logged in, and not the
#   dataset's overview; config check accepts the table and refuses a bad one.
#
# Needs MORCA_DATABASE_URL (pixi run -e data test-dataview starts a
# throwaway server), curl and jq.
set -eu
cd "$(dirname "$0")/.."
. "$PWD/tests/port.sh"
mkdir -p build/dataview
pids=
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC tests/dataview/obs.mojo -o build/dv-obs &
pids="$pids $!"
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC tests/dataview/many.mojo -o build/dv-many &
pids="$pids $!"
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC tests/test_datacache.mojo -o build/test-datacache &
pids="$pids $!"
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/morca_maintain.mojo -o build/morca_maintain &
pids="$pids $!"
# shellcheck disable=SC2086
scripts/mojo-build.sh -I src $DEP_INC bin/scheduler.mojo -o build/morca &
for pid in $pids $!; do wait "$pid"; done
log=build/dataview.log
: > "$log"
export MORCA_WAREHOUSE=$PWD/build/dataview-wh MORCA_MAINTAIN=$PWD/build/morca_maintain
export MORCA_DATA_CACHE=$PWD/build/dataview-cache
rm -rf "$MORCA_WAREHOUSE" "$MORCA_DATA_CACHE"
ui=
fail() {
    echo "FAIL: $*"
    tail -30 "$log"
    [ -z "$ui" ] || kill "$ui" 2> /dev/null || true
    exit 1
}
psql "$MORCA_DATABASE_URL" -qc "DELETE FROM orca.users" > /dev/null 2>&1 || true

conf=build/dataview/morca.toml
printf '[pipelines.obs]\n' > "$conf"
MORCA_CONFIG=$conf ./build/morca register ./build/dv-obs >> "$log" 2>&1 || fail "register"
./build/dv-obs run --partitions 2024-01 >> "$log" 2>&1 || fail "obs 2024-01"
./build/dv-obs run --partitions 2024-02 >> "$log" 2>&1 || fail "obs 2024-02"
meta=$(ls "$MORCA_WAREHOUSE"/lake/obs/metadata/*.metadata.json | sort | tail -1)
S1=$(jq -r '.snapshots[0]."snapshot-id"' "$meta")
S2=$(jq -r '."current-snapshot-id"' "$meta")

start_ui() { # [VAR=value...]: morca ui on a free port, as $base
    free_port port
    base="http://127.0.0.1:$port"
    env "$@" MORCA_UI_ADDR="127.0.0.1:$port" ./build/morca ui >> "$log" 2>&1 &
    ui=$!
    i=0
    until curl -fs "$base/" > /dev/null 2>&1; do
        i=$((i + 1)); [ "$i" -lt 100 ] || fail "morca ui didn't start"; sleep 0.1
    done
}
stop_ui() { kill "$ui"; wait "$ui" 2> /dev/null || true; ui=; }
json() { curl -fsS "$base/datasets/lake.obs/data.json?$1" || fail "GET data.json?$1"; }
code() { curl -s -o build/dataview/body -w '%{http_code}' "$@"; }

start_ui MORCA_DATA_DOWNLOAD_ROWS=120

# The schema and the partition spec.
j=$(json "")
[ "$(echo "$j" | jq -r '[.schema.columns[] | "\(.id):\(.name):\(.type)"] | join(",")')" \
    = "1:id:long,2:month:string,3:day:date,4:city:string,5:temp:double,6:n:int,7:note:string" ] \
    || fail "the schema: $(echo "$j" | jq -c .schema)"
[ "$(echo "$j" | jq -r '.schema.columns[0].doc')" = "The row number, month * 1000 + i" ] || fail "a column's doc"
[ "$(echo "$j" | jq -r '.schema.columns[6].required')" = false ] || fail "note is optional"
[ "$(echo "$j" | jq -r '[.partition_spec.fields[] | "\(.name):\(.source):\(.transform)"] | join(",")')" \
    = "month:month:identity,city:city:identity" ] || fail "the partition spec"
[ "$(echo "$j" | jq -r .snapshot)" = "$S2" ] || fail "not at the current snapshot"
[ "$(echo "$j" | jq '.snapshots | length')" -eq 2 ] || fail "the snapshots"
echo "ok   the schema, its field ids and docs, and the partition spec"

# The partitions, from the manifests.
[ "$(echo "$j" | jq -r '[.partitions[] | "\(.partition.month)/\(.partition.city):\(.rows):\(.files)"] | join(" ")')" \
    = "2024-02/Paris:50:1 2024-02/Oslo, NO:50:1 2024-02/Lima:50:1 2024-01/Paris:50:1 2024-01/Oslo, NO:50:1 2024-01/Lima:50:1" ] \
    || fail "the partitions: $(echo "$j" | jq -c .partitions)"
[ "$(echo "$j" | jq -r '[.partitions[] | select(.partition.month == "2024-01") | .last_snapshot] | unique | join(",")')" = "$S1" ] \
    || fail "2024-01's partitions weren't last written by $S1"
[ "$(echo "$j" | jq '[.partitions[] | select(.bytes > 0)] | length')" -eq 6 ] || fail "the partitions' sizes"
echo "ok   six partitions from the manifests, with rows, files, sizes and last snapshots"

# A page of 100, the next by its cursor, the last.
[ "$(echo "$j" | jq '.rows.rows | length')" -eq 100 ] || fail "the first page has $(echo "$j" | jq '.rows.rows | length') rows"
[ "$(echo "$j" | jq -r .rows.next)" = 100 ] || fail "the first page's next"
next=$(echo "$j" | jq -r .next_url)
case "$next" in /datasets/lake.obs/data.json\?*cursor=100*) ;; *) fail "next_url: $next" ;; esac
p2=$(curl -fsS "$base$next")
[ "$(echo "$p2" | jq '.rows.rows | length')" -eq 100 ] || fail "the second page"
[ "$(echo "$p2" | jq -r .rows.next)" = 200 ] || fail "the second page's next"
p3=$(json "cursor=200")
[ "$(echo "$p3" | jq '.rows.rows | length')" -eq 100 ] && [ "$(echo "$p3" | jq -r .rows.next)" = null ] || fail "the last page"
[ "$({ echo "$j"; echo "$p2"; echo "$p3"; } | jq -r '.rows.rows[][0]' | sort -u | wc -l | tr -d ' ')" -eq 300 ] \
    || fail "the three pages don't hold the 300 rows once each"
[ "$(json "n=1000" | jq .rows.limit)" -eq 100 ] || fail "a page past MORCA_DATA_PAGE_ROWS"
echo "ok   pages of 100 by cursor, 300 rows once each, n capped at 100"

# Filters, a pick of columns, a sort, a snapshot.
f=$(json "f=city:eq:Paris&f=temp:gt:5")
[ "$(echo "$f" | jq '.rows.rows | length')" -eq 50 ] || fail "Paris over 5: $(echo "$f" | jq '.rows.rows | length') rows"
[ "$(echo "$f" | jq '[.rows.rows[] | select(.[3] == "Paris" and .[4] > 5)] | length')" -eq 50 ] || fail "rows outside the filter"
[ "$(echo "$f" | jq .rows.files)" -eq 2 ] || fail "city = Paris planned $(echo "$f" | jq .rows.files) files, not 2"
[ "$(json "f=city:in:Lima,Paris&n=1" | jq .rows.files)" -eq 4 ] || fail "city in (Lima, Paris) didn't prune to 4 files"
s=$(json "c=id&c=temp&sort=-temp&n=5")
[ "$(echo "$s" | jq -r '[.rows.columns[].name] | join(",")')" = "id,temp" ] || fail "the column pick"
[ "$(echo "$s" | jq '[.rows.rows[][1] == 10] | all and length == 5')" = true ] || fail "sorted by temp, descending: $(echo "$s" | jq -c .rows.rows)"
[ "$(json "c=id&sort=id&n=2&cursor=150" | jq -r '[.rows.rows[][0]] | join(",")')" = "2000,2001" ] || fail "sorted by id, from 150"
o=$(json "snapshot=$S1&c=month")
[ "$(echo "$o" | jq '.partitions | length')" -eq 3 ] || fail "the first snapshot's partitions"
[ "$(echo "$o" | jq -r '[.rows.rows[][0]] | unique | join(",")')" = 2024-01 ] || fail "the first snapshot's rows"
[ "$(json "f=note:eq:x&c=note" | jq '.rows.rows | length')" -eq 0 ] || fail "a filter nothing matches"
echo "ok   filters prune files; a pick, a sort and an earlier snapshot"

# The chart: temp and n averaged by day.
c=$(json "x=day&y=temp&y=n")
[ "$(echo "$c" | jq '.chart.points | length')" -eq 10 ] || fail "the chart's points: $(echo "$c" | jq -c .chart)"
[ "$(echo "$c" | jq -r '.chart.points[0] | "\(.x) \(.y[0] == 3)"')" = "2024-01-01 true" ] || fail "the chart's first point: $(echo "$c" | jq -c '.chart.points[0]')"
[ "$(json "x=city&y=temp&agg=sum&f=month:eq:2024-01" | jq -r '[.chart.points[] | "\(.x)=\(.y[0] == 250)"] | join(" ")')" \
    = "Lima=true Oslo, NO=true Paris=true" ] || fail "temp summed by city"
[ "$(json "x=day&y=city" | jq -r .chart.error)" = "morca: city isn't a number, so it can't be charted" ] || fail "a y that isn't a number"
page=$(curl -fsS "$base/datasets/lake.obs?tab=data&x=day&y=temp")
echo "$page" | grep -q '<svg class="tl dc"' && echo "$page" | grep -q 'class="dc__line dc--0"' || fail "the line chart"
curl -fsS "$base/datasets/lake.obs?tab=data&x=city&y=temp&chart=bar" | grep -q 'class="dc__bar dc--0"' || fail "the bar chart"
echo "ok   the chart's data, a line and bars"

# The page: its tabs, cards, links and forms.
page=$(curl -fsS "$base/datasets/lake.obs?tab=data")
for card in schema partitions rows chart; do
    echo "$page" | grep -q "id=\"$card\"" || fail "no $card card"
done
echo "$page" | grep -qF 'href="/datasets/lake.obs?tab=data" aria-current="page">Data</a>' || fail "the Data tab"
echo "$page" | grep -qF 'href="/datasets/lake.obs?tab=data&amp;f=month%3Aeq%3A2024-01#rows"' || fail "a partition's link to its rows"
echo "$page" | grep -qF 'href="/datasets/lake.obs/data.csv?' || fail "no download link"
curl -fsS "$base/datasets/lake.obs" | grep -qF 'href="/datasets/lake.obs" aria-current="page">Overview</a>' || fail "the overview's tabs"
[ "$(curl -fsS "$base/datasets/lake.obs?tab=data&fc=city&fo=eq&fv=Lima&format=json" | jq '.rows.rows | length')" -eq 100 ] || fail "the form's filter"
echo "ok   the tab's cards, partition links, download link and filter form"

# The layout (#499): the commit bar, then Data | Schema with Data shown and
# the table first; partitions and the chart below.
page=$(curl -fsS "$base/datasets/lake.obs?tab=data")
at() { echo "$page" | grep -boF "$1" | head -1 | cut -d: -f1; }
bar=$(at '<div class="dbar" role="group" aria-label="Commit">')
tbl=$(at '<div class="scroll dtable"><table>')
[ -n "$bar" ] && [ -n "$tbl" ] && [ "$bar" -lt "$tbl" ] || fail "the commit bar isn't above the table"
for later in '<div id="schema" role="tabpanel"' 'id="partitions"' 'id="chart"'; do
    n=$(at "$later")
    [ -n "$n" ] && [ "$tbl" -lt "$n" ] || fail "the table isn't before $later"
done
echo "ok   the commit bar, then the table, then the schema, partitions and chart"

# The commit picker: newest first, the newest selected; each a link to the
# tab at it, which selects it; the arrows step one commit.
picked() { echo "$page" | grep -o 'snapshot=[0-9]*[^"]*" data-search="[^"]*" aria-current="true"' | sed 's/snapshot=\([0-9]*\).*/\1/'; }
[ "$(echo "$page" | grep -o 'class="dpick__item" href="[^"]*' | sed 's/.*snapshot=//' | tr '\n' ' ')" = "$S2 $S1 " ] \
    || fail "the picker isn't newest first: $(echo "$page" | grep -o 'class="dpick__item" href="[^"]*')"
[ "$(picked)" = "$S2" ] || fail "the newest isn't selected: $(picked)"
echo "$page" | grep -qF '<span class="dpick__latest">latest</span>' || fail "the newest isn't marked latest"
echo "$page" | grep -qF 'class="dpick__search" hidden' && echo "$page" | grep -qF '.dpick__search' || fail "no search box"
echo "$page" | grep -qF '<span class="dbar__rows"><strong>300</strong> rows</span>' || fail "the row count: $(echo "$page" | grep -o '<span class="dbar__rows">[^/]*')"
echo "$page" | grep -qF "<a class=\"dbar__step\" rel=\"prev\" href=\"/datasets/lake.obs?tab=data&amp;snapshot=$S1\" title=\"Older commit\"" \
    || fail "the newest's Older arrow"
echo "$page" | grep -qF '<span class="dbar__step" aria-disabled="true" title="Newer commit">' || fail "the newest has a Newer arrow"
echo "$page" | grep -q "<code title=\"$S2\">$(echo "$S2" | cut -c1-8)</code> <span class=\"dpick__msg\">append · run [^<]* · 2024-02 · +150</span>" \
    || fail "a commit's entry: $(echo "$page" | grep -o '<span class="dpick__msg">[^<]*' | head -1)"
page=$(curl -fsS "$base/datasets/lake.obs?tab=data&snapshot=$S1&c=month")
[ "$(picked)" = "$S1" ] || fail "?snapshot=$S1 doesn't select it: $(picked)"
echo "$page" | grep -qF '<span class="dbar__rows"><strong>150</strong> rows</span>' || fail "$S1's row count"
echo "$page" | grep -qF '<span class="dbar__step" aria-disabled="true" title="Older commit">' || fail "the oldest has an Older arrow"
echo "$page" | grep -qF "<a class=\"dbar__step\" rel=\"next\" href=\"/datasets/lake.obs?tab=data&amp;snapshot=$S2&amp;c=month\" title=\"Newer commit\"" \
    || fail "the oldest's Newer arrow, keeping the column pick"
echo "ok   the commit picker: newest first and selected, ?snapshot= selects one, the arrows step"

# Data | Schema: Data shown unless ?view=schema; types under the headers;
# the schema's nullability, field ids and spec on its tab.
page=$(curl -fsS "$base/datasets/lake.obs?tab=data")
echo "$page" | grep -qF 'data-tabs="morca.data.view" data-tabs-param="view" data-tabs-forget>' || fail "the Data/Schema tabs"
echo "$page" | grep -qF 'data-view="data" href="/datasets/lake.obs?tab=data" aria-selected="true" aria-controls="rows">Data</a>' || fail "Data isn't selected"
echo "$page" | grep -qF 'data-view="schema" href="/datasets/lake.obs?tab=data&amp;view=schema" aria-selected="false" aria-controls="schema">Schema</a>' || fail "the Schema tab"
echo "$page" | grep -qF '<div id="rows" role="tabpanel" class="dview__panel">' && echo "$page" | grep -qF '<div id="schema" role="tabpanel" class="dview__panel" hidden>' \
    || fail "the Data panel isn't the one shown"
echo "$page" | grep -qF '<th class="num" title="long">id<span class="dtype">long</span></th>' || fail "id's type under its header"
echo "$page" | grep -qF '<th title="date">day<span class="dtype">date</span></th>' || fail "day's type under its header"
echo "$page" | grep -qF '<th>Nullable</th>' && echo "$page" | grep -qF '<code title="note">note</code></td><td class="mono">string</td><td>yes</td>' \
    || fail "the schema's nullability"
echo "$page" | grep -qF '<code>month</code> (identity of <code>month</code>, field 1000)' || fail "the partition spec's field"
page=$(curl -fsS "$base/datasets/lake.obs?tab=data&view=schema")
echo "$page" | grep -qF 'aria-selected="true" aria-controls="schema">Schema</a>' && echo "$page" | grep -qF '<div id="rows" role="tabpanel" class="dview__panel" hidden>' \
    || fail "?view=schema doesn't open the Schema tab"
[ "$(echo "$j" | jq '[.schema.columns[] | has("fields")] | any')" = false ] || fail "a primitive column with fields"
echo "ok   Data and Schema tabs, Data first; column types under the headers"

# The way to the data from the pages people land on.
curl -fsS "$base/" | grep -qF '<div class="data-line">Data: <a class="data-link" href="/datasets/lake.obs?tab=data"' \
    || fail "the home page doesn't link obs to lake.obs's data"
curl -fsS "$base/home/pipelines" | grep -qF 'href="/datasets/lake.obs?tab=data"' || fail "the home page's refreshed table"
page=$(curl -fsS "$base/pipelines/obs")
echo "$page" | grep -qF '<p class="data-line pipeline__datasets">Writes <a href="/datasets/lake.obs">lake.obs</a> <a class="data-link" href="/datasets/lake.obs?tab=data"' \
    || fail "the pipeline page's Datasets line"
curl -fsS "$base/pipelines/obs?steps=table" | grep -qF '<td class="names"><a href="/datasets/lake.obs">lake.obs</a> <a class="data-link" href="/datasets/lake.obs?tab=data"' \
    || fail "the steps table's data link"
curl -fsS "$base/datasets" | grep -qF '<td><a class="data-link" href="/datasets/lake.obs?tab=data"' || fail "the datasets list's Data column"
run=$(psql "$MORCA_DATABASE_URL" -Atc "SELECT max(id) FROM orca.runs WHERE pipeline = 'obs'")
curl -fsS "$base/runs/$run" | grep -qF "href=\"/datasets/lake.obs?tab=data&amp;snapshot=$S2\"" || fail "the run page's link to the data it wrote"
echo "ok   home, the pipeline page, the steps, the datasets list and the run page link to the data"

# A pipeline's Data tab: what it writes, a few rows each.
page=$(curl -fsS "$base/pipelines/obs?tab=data")
echo "$page" | grep -qF 'href="/pipelines/obs?tab=data" aria-current="page">Data</a>' || fail "the pipeline's Data tab"
echo "$page" | grep -qF '<section class="card pdata" id="data-0"><h2><a href="/datasets/lake.obs">lake.obs</a></h2>' || fail "lake.obs's card"
echo "$page" | grep -qF "Snapshot $S2 · 300 rows · 6 files" || fail "lake.obs's snapshot line: $(echo "$page" | grep -o 'Snapshot [^<]*')"
echo "$page" | grep -qF '<a class="data-link" href="/datasets/lake.obs?tab=data">All its data</a>' || fail "the link to lake.obs's Data tab"
[ "$(echo "$page" | grep -o '<td class="num">' | wc -l | tr -d ' ')" -ge 20 ] || fail "lake.obs's rows on the pipeline's Data tab"
[ "$(echo "$page" | grep -o '<tr>' | wc -l | tr -d ' ')" -eq 21 ] || fail "not 20 rows and a header: $(echo "$page" | grep -o '<tr>' | wc -l)"
echo "ok   the pipeline's Data tab: lake.obs's snapshot and first 20 rows, linked to its Data tab"

# The download: capped, with why.
hdr=build/dataview/csv.hdr
curl -fsS -D "$hdr" -o build/dataview/obs.csv "$base/datasets/lake.obs/data.csv?f=month:eq:2024-01" || fail "the download"
[ "$(head -1 build/dataview/obs.csv)" = "id,month,day,city,temp,n,note" ] || fail "the CSV's header"
[ "$(wc -l < build/dataview/obs.csv | tr -d ' ')" -eq 121 ] || fail "the CSV has $(wc -l < build/dataview/obs.csv) lines, not 121"
grep -qx '1003,2024-01,2024-01-04,Lima,3.5,3,"say ""3"", ok"' build/dataview/obs.csv || fail "a quoted field: $(sed -n 3p build/dataview/obs.csv)"
grep -qx '1000,2024-01,2024-01-01,Lima,0.5,0,' build/dataview/obs.csv || fail "a null"
grep -qi '^x-morca-stopped: the download stops at 120 rows (MORCA_DATA_DOWNLOAD_ROWS)' "$hdr" || fail "why the download stopped: $(cat "$hdr")"
grep -qi '^content-type: text/csv' "$hdr" || fail "the CSV's type"
curl -fsS -D "$hdr" -o build/dataview/paris.csv "$base/datasets/lake.obs/data.csv?f=city:eq:Paris&f=temp:gt:5" || fail "a small download"
[ "$(wc -l < build/dataview/paris.csv | tr -d ' ')" -eq 51 ] && ! grep -qi '^x-morca-stopped' "$hdr" || fail "a download under the cap"
echo "ok   the download: CSV, quoted, capped at MORCA_DATA_DOWNLOAD_ROWS with why"

# Mistakes, and the limits.
[ "$(code "$base/datasets/lake.obs/data.json?f=nope:eq:1")" = 400 ] || fail "a filter on no column"
[ "$(jq -r .error build/dataview/body)" = "morca: the table has no column nope" ] || fail "its error: $(cat build/dataview/body)"
[ "$(code "$base/datasets/lake.obs/data.json?f=n:lt:abc")" = 400 ] || fail "a number that isn't"
[ "$(code "$base/datasets/lake.obs?tab=data&f=bad")" = 400 ] && grep -q 'id="rows"' build/dataview/body || fail "a bad filter's page"
[ "$(code "$base/datasets/lake.nope?tab=data")" = 404 ] || fail "no such dataset"
stop_ui
start_ui MORCA_DATA_MEMORY_MB=0.001
[ "$(json "sort=id" | jq -r .rows.stopped)" = "the scan stopped at its memory limit, 0.001 MB (MORCA_DATA_MEMORY_MB)" ] || fail "the memory limit: $(json sort=id | jq -c .rows.stopped)"
curl -fsS "$base/datasets/lake.obs?tab=data&sort=id" | grep -qF 'Stopped: the scan stopped at its memory limit' || fail "the page doesn't say why it stopped"
stop_ui
start_ui MORCA_DATA_SECONDS=0.000001
case "$(json "" | jq -r .rows.stopped)" in "the scan stopped at its time limit"*) ;; *) fail "the time limit: $(json "" | jq -c .rows)" ;; esac
stop_ui
echo "ok   bad filters are 400; the memory and time limits stop a read, saying why"

# A download that can't be written (#483): an error the UI answers 503
# with, not a crash. Every write to /dev/full fails with ENOSPC, as on a
# full disk.
for to in build/dataview/no-such-dir/obs.csv /dev/full; do
    [ "$to" != /dev/full ] || [ -w /dev/full ] || { echo "skip: no /dev/full here"; continue; }
    ./build/morca_maintain data lake.obs --csv "$to" --max-rows 10 > build/dataview/full.json \
        || fail "morca_maintain data --csv $to exited $?"
    jq -r .csv.error build/dataview/full.json | grep -qF "can't write the download to $to" \
        || fail "a download to $to: $(cat build/dataview/full.json)"
done
echo "ok   a download that can't be written, or to a full disk, is an error, not a crash"

# Many commits: pages by count, the cache, the loading mark.
./build/dv-many run --partitions 2024-01-01..2024-02-29 >> "$log" 2>&1 || fail "many"
md() { ./build/morca_maintain data "$@" || fail "morca_maintain data $*"; }
for ds in lake.small lake.wide; do
    all=$(md $ds --offset 0 --limit 100 --max-rows 1000)
    [ "$(echo "$all" | jq .rows.files)" -ge 60 ] || fail "$ds has $(echo "$all" | jq .rows.files) files"
    want=$(echo "$all" | jq -c '.rows.rows[37:58]')
    page=$(md $ds --offset 37 --limit 21 --max-rows 1000)
    [ "$(echo "$page" | jq -c .rows.rows)" = "$want" ] || fail "$ds rows 37-58: $(echo "$page" | jq -c .rows.rows), not $want"
    [ "$(echo "$page" | jq .rows.scanned)" -lt 37 ] || fail "$ds read $(echo "$page" | jq .rows.scanned) rows for a page at 37"
    [ "$(echo "$page" | jq .rows.next)" = 58 ] || fail "$ds page's next"
    [ "$(echo "$page" | jq .timings.manifests.requests)" -eq 0 ] || fail "$ds fetched manifests again: $(echo "$page" | jq -c .timings)"
    [ "$(echo "$page" | jq -c .partitions)" = "$(echo "$all" | jq -c .partitions)" ] || fail "$ds partitions from the cache"
    top=$(md $ds --sort -id --limit 1 --max-rows 100000 | jq '.rows.rows[0][0]')
    [ "$top" -eq "$(md $ds --limit 100000 --max-rows 100000 | jq '[.rows.rows[][0]] | max')" ] \
        || fail "$ds sorted by id, descending, starts at $top"
done
[ "$(ls "$MORCA_DATA_CACHE" | grep -c partitions-)" -ge 2 ] || fail "no partitions kept in $MORCA_DATA_CACHE"
env MORCA_DATA_CACHE=off ./build/morca_maintain data lake.small --limit 5 > build/dataview/nocache.json
[ "$(jq .timings.manifests.requests build/dataview/nocache.json)" -gt 0 ] || fail "MORCA_DATA_CACHE=off still read the cache"
start_ui
curl -fsS "$base/datasets/lake.obs?tab=data" | grep -qF 'document.body.classList.toggle("loading", on)' || fail "no loading mark on the Data tab"
curl -fsS "$base/static/morca.css" | grep -qF 'body.loading::after { content: "Loading data' || fail "no loading style"
stop_ui
old=$(md lake.wide --no-rows --no-partitions | jq -r '.snapshots[9].snapshot')
env MORCA_DATA_CACHE_MB=0.002 ./build/morca_maintain data lake.wide --snapshot "$old" --limit 5 > /dev/null
kept=$(find "$MORCA_DATA_CACHE" -type f -exec cat {} + | wc -c)
[ "$kept" -le 2048 ] || fail "the cache past MORCA_DATA_CACHE_MB: $kept bytes"
echo "ok   many files: later pages by count, manifests and partitions kept, the loading mark"

# The cache when it's broken or the disk is low (#483).
./build/test-datacache >> "$log" 2>&1 || fail "tests/test_datacache.mojo"
reqs() { jq .timings.manifests.requests; }
rows() { jq -c .rows.rows; }
want=$(md lake.small --limit 30 | rows)
[ "$(md lake.small --limit 30 | reqs)" -eq 0 ] || fail "lake.small isn't kept"
# Every kept file cut short: each is a miss, removed and fetched again.
for f in "$MORCA_DATA_CACHE"/*; do
    head -c 9 "$f" > "$f.cut" && mv "$f.cut" "$f"
done
got=$(md lake.small --limit 30)
[ "$(echo "$got" | rows)" = "$want" ] || fail "rows after the cache was cut short"
[ "$(echo "$got" | reqs)" -gt 0 ] || fail "files cut short were read from the cache"
[ "$(md lake.small --limit 30 | reqs)" -eq 0 ] || fail "files cut short weren't kept again"
# Whole files that don't parse: the manifest list, the manifests and the
# partitions, kept as garbage.
meta=$(ls "$MORCA_WAREHOUSE"/lake/small/metadata/*.metadata.json | sort | tail -1)
cur=$(jq -r '."current-snapshot-id"' "$meta")
./build/test-datacache plant "$MORCA_DATA_CACHE" "$(jq -r --arg c "$cur" '.snapshots[] | select((."snapshot-id" | tostring) == $c) | ."manifest-list"' "$meta")" garbage \
    || fail "plant a manifest list"
got=$(md lake.small --limit 30)
[ "$(echo "$got" | rows)" = "$want" ] && [ "$(echo "$got" | reqs)" -eq 1 ] || fail "a kept manifest list that doesn't parse: $(echo "$got" | jq -c .timings)"
for m in "$MORCA_WAREHOUSE"/lake/small/metadata/*-m*.avro; do
    ./build/test-datacache plant "$MORCA_DATA_CACHE" "$m" garbage || fail "plant $m"
done
uuid=$(jq -r '."table-uuid"' "$meta")
./build/test-datacache plant "$MORCA_DATA_CACHE" "partitions-$uuid-$cur.json" '"partitions": [{"bro' || fail "plant partitions"
got=$(md lake.small --limit 30)
[ "$(echo "$got" | rows)" = "$want" ] || fail "rows over manifests kept as garbage: $(echo "$got" | jq -c '.error // .timings')"
[ "$(echo "$got" | jq .partitions_total)" -eq 1 ] || fail "partitions kept as garbage"
[ "$(echo "$got" | reqs)" -gt 1 ] || fail "manifests kept as garbage weren't fetched again: $(echo "$got" | jq -c .timings)"
[ "$(md lake.small --limit 30 | reqs)" -eq 0 ] || fail "broken entries weren't kept again"
# More free space to keep than the disk has: nothing is written, and the
# cache empties itself.
got=$(env MORCA_DATA_CACHE_MIN_FREE_MB=1000000000 ./build/morca_maintain data lake.wide --limit 5) || fail "a read low on space"
[ "$(echo "$got" | jq '.rows.rows | length')" -eq 5 ] || fail "rows when low on space"
[ -z "$(ls "$MORCA_DATA_CACHE")" ] || fail "the cache didn't empty itself low on space: $(ls "$MORCA_DATA_CACHE" | head -3)"
[ "$(env MORCA_DATA_CACHE_MIN_FREE_MB=1000000000 ./build/morca_maintain data lake.small --limit 5 | reqs)" -gt 0 ] \
    || fail "a read low on space found something kept"
[ -z "$(ls "$MORCA_DATA_CACHE")" ] || fail "a read low on space kept what it read"
echo "ok   the cache: files cut short or that don't parse are fetched again; low on space it writes nothing and empties"

# public = false: hidden from visitors once login is on.
printf '[pipelines.obs]\n\n[datasets."lake.obs"]\npublic = false\n' > "$conf"
./build/morca config check "$conf" >> "$log" 2>&1 || fail "config check refused [datasets]"
printf '[datasets."lake.obs"]\nhidden = true\n' > build/dataview/bad.toml
./build/morca config check build/dataview/bad.toml > build/dataview/bad.out 2>&1 && fail "config check took a bad key"
grep -q 'has no key hidden' build/dataview/bad.out || fail "config check's message: $(cat build/dataview/bad.out)"
MORCA_CONFIG=$conf ./build/morca register ./build/dv-obs > build/dataview/reg.out 2>&1 || fail "register with [datasets]: $(cat build/dataview/reg.out)"
grep -qx 'dataset lake.obs (data not public)' build/dataview/reg.out || fail "register's line: $(cat build/dataview/reg.out)"
start_ui
[ "$(code "$base/datasets/lake.obs/data.json")" = 200 ] || fail "hidden with login off"
printf 'correct horse battery\n' | ./build/morca user add alice >> "$log" 2>&1 || fail "user add"
for path in "/datasets/lake.obs/data.json" "/datasets/lake.obs/data.csv" "/datasets/lake.obs?tab=data"; do
    [ "$(code "$base$path")" = 401 ] || fail "$path isn't hidden from a visitor"
done
grep -q 'Log in</a> to see it' build/dataview/body || fail "the hidden tab's login link"
for path in / /datasets /pipelines/obs; do
    page=$(curl -fsS "$base$path")
    echo "$page" | grep -qF '<body class="anon">' && echo "$page" | grep -qF 'data-link--private' \
        || fail "$path doesn't mark lake.obs's data link private for a visitor"
done
[ "$(code "$base/datasets/lake.obs")" = 200 ] || fail "the overview is hidden too"
[ "$(code "$base/pipelines/obs?tab=data")" = 200 ] && grep -qF 'Its data is shown to those logged in' build/dataview/body \
    && ! grep -q '<td class="num">' build/dataview/body || fail "the pipeline's Data tab shows hidden data to a visitor"
jar=build/dataview/cookies.txt
rm -f "$jar"
[ "$(code -c "$jar" -H "Origin: $base" -d 'name=alice&password=correct+horse+battery' "$base/login")" = 303 ] || fail "log in"
[ "$(code -b "$jar" "$base/datasets/lake.obs/data.json")" = 200 ] || fail "hidden from alice"
[ "$(code -b "$jar" "$base/pipelines/obs?tab=data")" = 200 ] && grep -q '<td class="num">' build/dataview/body \
    || fail "the pipeline's Data tab hides lake.obs from alice"
printf '[pipelines.obs]\n' > "$conf"
MORCA_CONFIG=$conf ./build/morca register ./build/dv-obs > build/dataview/reg.out 2>&1 || fail "register without [datasets]"
grep -qx 'dataset lake.obs settings removed: its data is public' build/dataview/reg.out || fail "register's line: $(cat build/dataview/reg.out)"
[ "$(code "$base/datasets/lake.obs/data.json")" = 200 ] || fail "still hidden once the file doesn't say so"
stop_ui
psql "$MORCA_DATABASE_URL" -qc "DELETE FROM orca.users" > /dev/null 2>&1 || true
echo "ok   public = false hides the data from visitors, not from alice; config check takes it"
