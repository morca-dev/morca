# The UI

`morca ui` serves pipelines, runs and datasets as web pages on
`127.0.0.1:8270` (`MORCA_UI_ADDR`). Every page is also JSON, to
`Accept: application/json` or `?format=json`. Reading needs no login; the
actions need one once a user exists (`morca user add <name>`). The full list
of paths is the docstring of `src/morca/_internal/web/routes.mojo`, and of the actions
`src/morca/_internal/api/actions.mojo`'s (DESIGN.md's "Web layer" maps the modules);
the site's [UI page](https://mlake.dev/s/orca/docs/ui) has the older pages.
This page is the parts that changed most recently.

```sh
MORCA_DATABASE_URL=postgresql:///morca ./build/morca ui
pixi run playground          # or the playground: example pipelines and runs, demo / demo-password
```

## Home: List and Timeline

`/` has two tabs, remembered in the browser. **List** (the default, no
JavaScript needed) is the pipelines, each name followed by its state at a
glance: its [coverage](#coverage-in-one-number), its running runs (of its
`max_runs`) and its queued ones, then its partitions, schedule, next run
and last run. On a phone the table scrolls sideways under the names.
**Timeline** draws each pipeline's runs over 1 h, 6 h, 24 h or 7 d, a row
per pipeline in dataset order, indented by depth, coloured by status, fill
runs thinner, with a line from a run to the sensor or keyed runs its
commits started. Its data is `GET /api/gantt?window=24h` (`1h`, `6h`,
`24h`, `7d`).

Under the tabs, **Recent runs** has a row per batch: the runs one
`morca backfill`, fill pass or sensor pass queued together share a batch
(`orca.runs.batch`, migration 56, its first run's id). A batch's row says
how many runs it has and how many are running, queued, succeeded, failed
and cancelled, over a bar of those that have ended, and links to
`/runs?batch=<id>`; a run with no batch is its own row, as on `/runs`.
Batches with a run running, or one that failed in the last day, come
first, then those with runs queued, then the rest by when they last
ended. The JSON's `recent` has the rows (`runs` stays the newest 10 runs),
and a run's page says which batch it's part of.

## Lists of runs, in pages

`/runs`, a pipeline's Runs tab and a dataset's snapshots come a page at a
time, newest first, with **« Newest**, **← Newer** and **Older →** under
the table (the left and right arrow keys follow Newer and Older). Pages
are keyed by run id, not counted from the top, so a page stays the same
while new runs arrive and each one is a single index range, however far
back it is:

| Parameter | |
|---|---|
| `?limit=` | runs to a page: 50 on `/runs`, 20 on a pipeline's tab, at most 500 (`?n=` still works) |
| `?before=<id>` | the page of runs older than that one |
| `?after=<id>` | the page of runs just newer than it (the newest page once fewer than a page are left) |

The filters ([below](#filtering-runs)) and the page size are kept in every
link. `/runs` says where the page is, `1–50 of 1,234`, from
an indexed count (`runs_pipeline_id`, migration 37, for a pipeline's runs).
The JSON keeps its fields (`runs`, `n`, `before`, `total`, `newer`,
`next_before`) and adds `limit`, `after`, `older`, and the cursors either
side: `next` (the `before` of the older page) and `prev` (the `after` of
the newer one), null at the ends, with `next_url` and `prev_url`. With no
parameters it's the same first page as before. A pipeline's page has the
same as `runs_page` in its JSON (`/api/pipelines/<name>?before=...`).

### Filtering runs

Over the table is a filter bar, a plain `GET` form, so it works without
JavaScript (with it, a dropdown, a status box or a date filters as soon as
it changes; text fields filter on Enter). `/runs` and a pipeline's Runs tab
take the same parameters, and so do their JSON
(`/api/pipelines/<name>?status=failed`); each is kept in every link, the
pager's `1–50 of N` counts what matches, and the newest page keeps
refreshing with them applied (its `/runs/table` fragment carries them).

| Parameter | |
|---|---|
| `?status=` | runs with any of the statuses: `?status=failed&status=queued`, or `failed,queued`. The box lists every status with its runs under the other filters, which the JSON has as `counts` |
| `?trigger=` | `schedule`, `sensor`, `backfill`, `fill`, `manual`, `ui`, `rerun`, `rebuild` |
| `?pipeline=` | on `/runs` |
| `?from=`, `?to=` | created on or after, and by the end of, a day (`2024-06-01`) or at a time (`2024-06-01T09:30`), UTC; one that isn't a time is left out |
| `?since=` | created in the last `1h`, `24h`, `7d` (any `<n>h` or `<n>d`), or `today` since midnight UTC: the quick picks beside the dates |
| `?key=` | a partition: a glob matched against each of a run's partitions (`2023-08-*`, `?` for one character), or else any part of them (`modular/` for a keyed pipeline's repositories) |
| `?run=` | one run: the page goes to it (`/runs/<id>`), the JSON is the list of it |
| `?batch=` | the runs queued together in that batch: a backfill, a fill pass or a sensor pass (`runs_batch`, migration 56) |

The JSON's `filters` has each (`status` as it was, comma-joined, and
`statuses` as a list; null for those not set), and `counts` each status's
runs; a pipeline's JSON has both in its `runs_page`. A filter by date is
one range of `runs_created` (migration 38), a status one of
`runs_pipeline_status`; a partition glob reads every run of what the
other filters leave, which on 200,000 runs is 80 ms without a pipeline
and a few with one.

### Acting on many runs

Logged in (or with login off), each row has a checkbox and the bar over
the table acts on the runs ticked: **Cancel** (queued, deferred and
running ones, as each row's Cancel does; the others are left), **Retry
failed** (failed and stalled ones queued again, as each row's Retry does,
except one whose code has changed, which is resumed from its own page)
and **Backfill again** (what `morca backfill --rerun` does, over the
partitions of the runs ticked, a backfill per pipeline; one whose steps
append asks first, for all of them). The header's box ticks the page's
runs; ticks survive the table refreshing. **or all N that match** acts on
every run the filters match, its number on the box: the action checks
there are still that many, and if not says how many there are now, with a
button to do it to those. One action does at most 2,000 runs. Logged out,
the boxes and buttons give way to a link to log in.

It's a `POST /runs/bulk` with `do` (`cancel`, `retry`, `backfill`), each
run ticked as `pick=<id>`, or `all=1&expect=<n>` and the list's filters
(`view`, `pipeline`, `status`, ...). It answers `303` back to the list,
which says what it did ("Cancelled 12 runs, 3 already finished"), or to
JSON its `done`, `skipped` and `refused` runs and how many a backfill
`queued`. Each run acted on is a row of `orca.audit` as its own action's
(`/runs/<id>/cancel`, `/runs/<id>/resume`, with detail `bulk`), each
pipeline backfilled as `/pipelines/<name>/backfill`, beside the row of
`/runs/bulk` itself.

`<pipeline> status --status failed,queued` lists a store's runs by status
on the command line, in Postgres, a SQLite file or memory alike.

A dataset's snapshots are 50 to a page the same way, by the attempt that
first committed each snapshot: `?before=<attempt>.<snapshot>`, `?after=`,
and `snapshots_page` in the JSON. `<pipeline> status --before <run>`
pages a store's runs on the command line, in Postgres, a SQLite file or
memory alike.

## Live pages

A page with something going on refreshes that part by itself, from a
fragment, only while the tab is visible. A refresh keeps open
`<details>`, scrolled tables, the chosen tab, a field being typed in and
the row at the top of the window, even when new rows arrive above it.

| Page | What refreshes | How often |
|---|---|---|
| `/` | the pipelines table (`/home/pipelines`) and Recent runs | 5 s while a run is queued or running, else 30 s |
| `/runs`, a pipeline's Runs tab | the table and its pager (`/runs/table`) | 5 s while a run on the page is queued or running; the newest page every 30 s otherwise, so new runs appear at its top; an older page stops once nothing on it is going on |
| a pipeline's page, every tab | the Progress card | 5 s |
| `/runs/<id>` | its facts, steps, DAG and machines (`/runs/<id>/live`) | 5 s, until the run ends |
| `/runs/<id>/attempts/<a>` | its facts (`.../facts`) and its log (`.../log`) | 5 s and 2 s, until the attempt ends |
| Ops: Alerts | the table of alerts and its pager (`/ops/alerts/live`, with the page's filters) | 30 s on the newest page; an older page doesn't refresh |
| Ops: Control | its charts, containers and alerts (`/ops/control/live`) | 30 s |
| Ops: Pools | its machines, filters and, with EC2 in view, Fleet's cards (`/ops/pools/live`, with the page's filters) | 10 s |
| `/watchdog` | the rules and trips (`/watchdog/live`) | 30 s |

A fragment answers 286 once it has nothing more to show, and the page
stops asking; a list's fragment sends `X-Poll-Every` with the seconds to
the next ask.

## A pipeline's page

Four tabs, each its own page, so links and the back button work:

| Tab | Link | What it has |
|---|---|---|
| Overview | `/pipelines/<name>` | the cards below, Steps, keys, snapshots not run, Next runs |
| Runs | `?tab=runs` | its runs and versions |
| Operate | `?tab=operate` | Coverage (the calendar of done, failed and open days), Start runs, Stop runs |
| Data | `?tab=data` | Each dataset it writes: its current snapshot and first 20 rows, read as the dataset's Data tab reads them, and a link to that tab |

The name, Pause and the Progress card are on every tab. Links to
`#coverage`, `#start` or `#stop` open Operate.

The header is four cards, side by side on a wide screen:

- **Progress**: runs going, the [fill](morca-toml.md#fills) (done of total,
  rate, ETA, today's spend against its budget, why it's idle), a failing
  sensor, the next run, and the pipeline's
  [coverage](#coverage-in-one-number) (`1141 / 1407 days done (81%)`),
  linking to the year calendar, or to Keys for a keyed pipeline. It
  refreshes itself every 5 s.
- **Config**: partitions, schedule, run retries,
  [placement](placement.md), binary.
- **Code**: the pipeline, its steps and dista tasks, each linked to its
  line on GitHub, and the code hash.
- **Resources**: what its last 20 measured runs used, the median (p50)
  and the most of each run's peak memory, CPU time and peak cores: what
  to ask for in a request (#171). It's `usage` in the page's JSON. See
  [What a run uses](#what-a-run-uses). A pipeline with a request
  (`cpus`, `memory_gb` in [morca.toml](morca-toml.md#requests-and-grants))
  has it here too, as **Requested**, and `request` in the JSON.
  **Learned** is the request its runs suggest
  ([Learned requests](morca-toml.md#learned-requests)), `learned` in the
  JSON: `learned from 20 runs: 3.25 GB, 2 CPUs`, **applied** when its
  `cpus` or `memory_gb` is `auto` and it learns, else **not applied**.

A sensor that runs when another pipeline's dataset gets a snapshot (the
census's mojo_repos and mojo_activity follow gharchive) has **Following**
on its Progress card: the pipelines and datasets it follows, how many of
their days (months) in its range it has done, and the rest broken down
into running or queued, failed and not queued yet, the first few of each
linking to their month on Coverage (`toy (up.days): 3 of 9 days done; 6
behind: 3 running or queued, 1 failed and 2 not queued yet`). What they
have is every partition morca knows of: those of each snapshot another
pipeline's succeeded attempt committed (`orca.commits`) and those of the
runs the sensor's own sensed snapshots started (`orca.sensed`), mapped to
its kind. The page's JSON (and `/api/pipelines/<name>`) has it as
`follow`: `datasets`, `upstream`, `unit`, `available`, `done`, `behind`,
and `live`, `failed` and `waiting`, each a `count` and its `first` eight
keys; null for a pipeline that isn't a dated sensor. It's one query for
the keys and the calendar's three for their states.

While its oldest queued run waits on its host, the Progress card says why
under **Waiting**, and the JSON has it as `waiting` (null otherwise): for
room (`waiting: needs 2 GB, 1.3 GB free of grants`), or for the host's
[memory pressure](morca-toml.md#memory-pressure) to ease (`waiting: memory
pressure 23% (limit 10%)`, `... on worker <name>` for a worker's pool).

### Coverage in one number

Each pipeline has one coverage number, the same on the home page's
**Coverage** column, its Progress card, and in the JSON (`coverage` on
each pipeline of `/` and on `/api/pipelines/<name>`'s `pipeline`, as
`{"done": 1141, "total": 1407, "pct": 81.0, "unit": "day"}`, `pct`
rounded down to a tenth; the page shows it rounded down to a whole
percent, so 100% means all of them). `src/morca/_internal/coverage.mojo` defines it:

- **Hourly, daily, weekly or monthly**: partitions done of those in the range so
  far, from the first partition through the last one that has ended on the
  schedule's clock (UTC without a schedule): the last hour for an hourly
  pipeline, yesterday for a daily one, last week (ISO, Monday to Sunday) for
  a weekly one, last month for a monthly one. An hourly pipeline's Coverage
  card shows a day of hours (`?cal=YYYY-MM-DD`), a weekly one's the 52 or 53
  weeks of an ISO year (`?cal=YYYY`). That's the range a fill works
  through; today's day, still going, is in neither number, nor is one
  that ended less than the pipeline's
  [`fill_lag`](morca-toml.md#the-lag) ago.
- **Keyed**: keys done of the keys morca knows, those `<binary> keys` last
  printed (`orca.keys`, which the sensor and the pipeline's page keep
  fresh; the home page never runs the binary).
- **Done** is what the calendar, a backfill and the Fill line count as
  done: every mapped step succeeded for the key in a run of any of the
  pipeline's code with its current data version, the same steps'
  `version=` (with no mapped step, such a run over the key succeeded).
  New code that keeps every `version=` leaves keys done. A step skipped
  because one before it failed isn't done, and neither are failed,
  queued, running or never-run keys, nor a key done only before a
  `version=` was raised.
- **None** (`null`, "—"): a pipeline without a first partition, one whose
  first hasn't ended yet, and a keyed one whose keys haven't been read.

It costs one query a pipeline, the calendar's and backfill's own: which
of the range's keys are done, each looked up by the `steps_partition`
index, so it grows with the range rather than with the runs. For 1,492
days over 30,000 runs and 60,000 steps that's 7 ms (10 ms for a pipeline
without a mapped step, whose half of the query now reads its runs' keys
once instead of once a key, 1.2 s before), and the home page's table
answers in 9 ms. The table asks it for every pipeline each time it
refreshes (every 5 s while a run is going); there's no cache, so the UI
stays stateless.

### Coverage

Operate's **Coverage** card is a dated pipeline's partitions on a
calendar, each coloured by its state: done, failed, running or queued, not
run, or outside the pipeline's range (before its start, or after today).
Hover a day for its date and state.

A daily pipeline's card has two tabs, **Month** and **Year**, remembered
in the browser like the Steps tabs; Year is the default. Year is twelve
small months (Monday to Sunday, like Month), each named with how many of
its days in the range are done (`28/31 done, 1 failed`) and linking to
that month; `‹ 2026 ›` moves a year within the range. Under it, a strip
has every month of the range (the last ten years at most), darker the
more of its days are done, each linking to its year. The tabs and arrows
are links (`?cal=2026` or `?cal=2026-03`, `&cov=year` or `month`), so all
of it works without scripts. A monthly pipeline's card is a year of
months, a keyed pipeline has none.

For a sensor (`morca._internal.sensors`), days the datasets it follows have but no run
of it has done, failed on or is running are **behind**, in amber, with a
line under the legend saying what that means.

The card reads one year for both tabs: which days are done (of the year
and the strip's range together), the live runs, and each day's last run,
three queries whatever the view.

Each fact's name has a "?" that explains it, with a link to the docs.
Steps shows a Graph and a Table tab (`?steps=graph|table`). Hovering any
link to code on GitHub shows that function, up to 24 lines (not for a
private repository).

## A run's page

`/runs/<id>` refreshes itself while the run is queued or running, and
stops once it has ended. The crumb links the pipeline's previous and next
run (the left and right arrow keys follow them). The header is five
cards, side by side on a wide screen and stacked on a phone, each fact's
name with a "?" that explains it:

| Card | Anchor | What it has |
|---|---|---|
| Status | `#status` | duration, created, started, ended, tries, why it waits, is held or failed; Resume, Rerun from and Cancel |
| Partitions & trigger | `#trigger` | its partitions, and what started it: the rebuild, or the snapshots a sensor saw |
| Code | `#code` | the pipeline, its steps and dista tasks on one line, each a name linked to its line (hover for the source), the commit and image, the driver log, and the code hash |
| Resources | `#resources` | what it requested and was granted, the run's own Peak memory and CPU used (see [What a run uses](#what-a-run-uses)), and on Kubernetes what its pods asked for |
| Settings | `#settings` | where it was placed and ran (a [remote worker](workers.md) by name), max runs, the EC2 settings, its environment, and its secrets by name only |

**Steps** (`#steps`) is one card with three tabs, remembered in the
browser: **Table** (the default: each step and partition, status,
attempts, times, peak memory and CPU, log, error), **Timeline** (the
attempts on the clock, a row per step) and **Graph** (the DAG in the
run's colours). `?steps=table|timeline|graph` links work without scripts.

**Machines** (`#machines`) is the machines' samples, when the runner
recorded them, and its subtitle says whose:

| Runner | Machines shows |
|---|---|
| local | `local`: the whole machine the scheduler runs on. Other runs, the scheduler and anything else on it count too; when other local or control-placed runs overlapped this one, the card says how many shared it |
| control placement | `control`: the whole control host, with Postgres, the scheduler and the UI on it; shared the same way |
| EC2 | `head-<id>` and `worker-<id>`: each of the run's own instances, a whole machine |
| Kubernetes | each pod's samples: CPU, memory and disk io are the node's, which other pods share; network is the pod's own |
| remote worker | `worker-<name>`: the whole machine the worker runs on, sampled by the `<binary> sample` it starts beside each run (since 0.15.0, [workers](workers.md)); other runs it claimed at the same time count too |

So Machines is never the run's own use; Resources is. Below it come
Instances (`#instances`, EC2), the Dista timeline (`#timeline`), Actions
(`#audit`, who did what from the UI or `morca`) and **Snapshots**
(`#tables`): the table snapshots each step read and wrote, linked to
their lineage.

## A dataset's data

`/datasets/<name>` has two tabs: **Overview** (its place in the graph,
the steps that write and read it, a rebuild, its snapshots) and **Data**
(`?tab=data`), which shows the table itself, so an app's output tables
need no UI of their own:

- **Schema**: each column's field id, name, type, whether it's required
  and its doc string, then the partition spec.
- **Partitions**: one row per partition with its rows, data files, size
  and the snapshot that last added a file to it, read from the manifests
  without reading any data. A value of an identity partition links to its
  rows.
- **Rows**: 100 to a page, paged by `?cursor=`. Filters (`=`, `≠`, `<`,
  `≤`, `>`, `≥`, `in`) on any column; on a partition's source column they
  prune partitions and files before anything is read. A column picker, a
  sort, and a snapshot picked from the list (the current one by default).
- **Chart**: an x column and up to three numeric y columns, averaged or
  summed for each x, drawn as a line or as bars.
- **Download CSV**: the filtered (and sorted) rows, up to 100,000.

The way there is on the pages people land on first: under each
pipeline's name on the home page, `Data:` and the datasets it writes; on a
pipeline's page, a line of what it writes and reads, and the Steps
table's Reads and Writes; a Data column on `/datasets`; and on a run's
Snapshots card, each snapshot it wrote or read, at that snapshot. A
dataset with `public = false` has its links hidden from visitors.

The same is JSON at `/datasets/<name>/data.json`, and the download is
`/datasets/<name>/data.csv`; routes.mojo lists the parameters.

The `morca` binary doesn't link iceberg, so the UI reads the table by
running the project's `morca_maintain data` (beside `morca` in the image,
or `MORCA_MAINTAIN`), at a lower CPU priority, and kills it 5 s past its
time limit. The UI needs the warehouse settings the scheduler has
(`MORCA_WAREHOUSE` and the `AWS_*` ones). A read stops at its limits and
the page says which one stopped it:

| Variable | Default | |
|---|---|---|
| `MORCA_DATA_PAGE_ROWS` | 100 | rows on a page, at most |
| `MORCA_DATA_DOWNLOAD_ROWS` | 100000 | rows in a download |
| `MORCA_DATA_SORT_ROWS` | 100000 | filtered rows a sort reads |
| `MORCA_DATA_CHART_ROWS` | 100000 | filtered rows a chart reads |
| `MORCA_DATA_SECONDS` | 20 | how long a read may take |
| `MORCA_DATA_MEMORY_MB` | 256 | what a read may hold |

Without a sort only the page's rows are read, and a later page skips the
files before it by their row counts; a sort holds every filtered row it
reads, so the memory limit is what bounds it. Small files are read 16 at a
time. There is no SQL.

A snapshot never changes, so a read keeps the manifests it fetched, and
the partitions it worked out, on local disk for the next one; a table of
many small commits then doesn't fetch its manifests again for every page.
`timings` in the JSON says how long each part of the read took and the
requests it made.

| Variable | Default | |
|---|---|---|
| `MORCA_DATA_CACHE` | `$TMPDIR/morca-data-cache` | where; `off` for no cache |
| `MORCA_DATA_CACHE_MB` | 256 | what it keeps; the least recently used goes first |
| `MORCA_DATA_CACHE_MIN_FREE_MB` | 1 GB or 5% of the disk, the larger | the free space it leaves: below it, it writes nothing and shrinks |

A kept file that was cut short or doesn't parse is removed and read from
object storage again.

A click on a Data link, or on one of the tab's forms, shows "Loading
data…" and a bar along the top until the page comes.

Like every other page, the Data tab needs no login. A dataset whose
`[datasets."<name>"]` table in morca.toml has `public = false`
([morca.toml](morca-toml.md#datasets)) shows its data only to those
logged in, once login is on; its Overview stays public.

## A snapshot's lineage

`/datasets/<name>/snapshots/<id>` draws the snapshot's lineage: each box
a snapshot, each arrow a step that read the snapshot it starts at and
wrote the one it points to, so data flows down. The legend under
the heading names the boxes: this snapshot (a thick border), one written
by a morca run (its pipeline and partition on the second line; hover for
the run and step), a source (dashed), written by something else, and
another input (dotted) of a step downstream, whose own lineage its page
has. A box nothing points to sits just above what read it. The diagram, like
`/datasets`' graph of pipelines and datasets, is drawn top to bottom, at
most two boxes to a row, so it fits a phone and grows downward.
Below it, **Upstream** is the snapshot and everything it was written
from, with the run and step that wrote each and what that step read
(`back` in the JSON), and **Downstream** is everything written from it
(`forward`), up to 20 steps away either way.

### What a run uses

The scheduler measures the runs it starts here (local and control-placed),
and `morca worker` the runs it starts: each tick (every second; a worker's
every poll) it reads the run's process tree in `/proc` (the run's process
and what it started, dista's local workers too), and when the process
ends `wait4` gives the largest single process and the CPU time of those
that ended between samples. Each attempt of that process gets its share,
by time: its **peak memory** (the most the tree held at once), its **CPU
used** (user and system seconds), and its **peak cores** (the most cores
kept busy over one sample's interval). They are `peak_rss_bytes`,
`cpu_seconds` and `peak_cpus` on `orca.attempts`.

The run's page has the run's Peak memory (its attempts' largest) and CPU
used (their sum, with the most cores at once), and the Steps table each
step's latest attempt's; an attempt's page has its own. Runs tables have
a Peak column. In the JSON, a run, each step and each attempt have
`usage`, with `null` for what wasn't measured. `morca status <pipeline>`
prints each run's, and `<binary> status <run>` each step's.

A run of a pipeline with a request also has **Requested** (what its
latest start asked for) and **Granted** (what it was given of its host, in
`MORCA_GRANT_CPUS` and `MORCA_GRANT_MEMORY_MB`), beside its peak: a peak
well under the grant means the request can come down, one at the grant
that it may need more. The run's JSON has `request` (`cpus`, `memory_gb`)
and `grant` (`cpus`, `memory_mb`), both null for a pipeline without one.
For an `auto` request ([Learned requests](morca-toml.md#learned-requests)),
**Requested** says `· learned from 20 runs`, and `request_source` in the
JSON is `{"source": "learned", "runs": 20, ...}` (`declared` or `default`
otherwise; null before morca kept it).
A queued run held for room or by memory pressure shows why under
**Held**, and `held` in the JSON. While the scheduler's host holds new runs
for its memory pressure, the home page and Runs say so at the top (and
their JSON has `memory_pressure`).

Where the scheduler (or worker) gives runs a cgroup of their own
([docs/hetzner.md](hetzner.md#a-cgroup-per-run), `morca._internal.cgroup`), the run's
page also has **Memory limit**: its latest start's `memory.high` (its grant,
request maximum or `MORCA_RUN_MEMORY_MB`) and the `memory.max` past which the
kernel kills it. The Steps table's Peak cell reads `312 MB / 1 GB`: the
latest attempt's peak against the limit it ran under (its grant in the
title), and an attempt's page has its own limit and grant. An attempt the
kernel killed for its memory fails `out of memory at <limit>: ...`, saying
what the retry asks for: 1.5 times as much, up to the request's maximum,
which the pipeline's later runs ask for too. In the JSON, a run has
`memory_limit` (`limit_mb`, `max_mb`, `current_bytes` while it runs), and each
step and attempt `memory_limit_mb` and `grant_memory_mb`; null without a
cgroup.

Not measured: runs on EC2 or Kubernetes (their machines' samples are under
Machines), runs no scheduler or worker started (`<binary> run`), and on
macOS, which has no `/proc`, the peak cores, and an attempt that shares
its process with others (a retry, a second step): there only a process
of one attempt gets `wait4`'s numbers.

A run with dista tasks has a **Timeline**: a track per process (driver or
head, then each worker), a lane per slot, spans coloured by function, input
waits as thin bars. Hover for a span's process, slot, duration and
arguments; wheel or drag to zoom, Reset zoom to go back. Perfetto and the
raw `timeline.json` stay linked.

## Help on every page

Each fact's name and each table's column header has a "?" that explains
it, on hover, keyboard focus or a tap. A value from a fixed set (a status
such as `deferred`, a step's kind `mapped`, a trigger, a placement, where
a setting came from) is dotted underlined instead, and says what it means
the same ways, so a table doesn't get a "?" in every cell. The texts are
in one place, `src/morca/_internal/ui/terms.mojo`: a header's by its label (or its
table's, for a word that means different things, as From does in the
Configuration and Actions tables), a value's by its kind and value, and a
setting's by its key. The UI adds a header's "?" to every `<th>` it has a
text for as it answers, so a new table gets them by using the same words.

The Configuration table (a pipeline's Overview) has each key's "?", and
its From column links to where the value is set, where morca knows it:

| From | Links to |
|---|---|
| morca.toml | the line at the commit the file was registered from, on the host of the pipeline's source (`config.sources.<key>.line` and `config.repo_path`, recorded by `morca register` from a git checkout; not for a file with uncommitted changes, one registered before morca kept lines, or one outside a checkout) |
| code default, from the pipeline (max_runs, workers) | the pipeline's `Pipeline[...]` line, from `morca locate` |
| code default, morca's own (placement, instance types, worker_procs, fills) | nothing: it's morca's, not the pipeline's |
| flag, environment | nothing: a flag of `morca register`, or the scheduler's environment, has no line |

## Code on hover

Hovering a link to a line on GitHub shows that function, coloured:
keywords, names a `def` or `struct` defines, strings (triple-quoted too),
comments, numbers and decorators, from the theme's colours. The UI fetches
the file (`/code?u=`, only a GitHub file at a commit, at most 1 MiB) and
colours it (`morca._internal.highlight`, a small tokenizer, no library), so the
browser needn't reach GitHub; a private repository's file it can't fetch
says so, and the link still opens it.

The same card shows on the lists: a runs table's pipeline (on Runs, a
pipeline's Runs tab and the home page's recent runs) shows the pipeline's
`Pipeline[...]` declaration at the commit that run ran, and a failed run
names the step that failed ("failed in measure"), linked to its function
at that commit. The home page's pipelines, in the List and the Timeline,
show theirs at the code registered now. The link keeps going where it did,
and its code is in a `data-src` attribute. A card shows on hover, on
keyboard focus, or on a first tap, and a second tap follows the link. A
list's live refresh doesn't break it. Nothing is fetched until a hover,
and then once per file per page.

Every card leads with a one-sentence summary: its docstring's first
sentence (up to the first ". " or blank line, at most 160 characters),
then the rest of the docstring in muted text, three lines at most, without
its indented examples, then the code without the docstring. A pipeline's
declaration with no docstring of its own uses its module's (the file's
opening docstring). So a docstring's first sentence should say what the
function or pipeline is for, on its own.

## Asking first

An action that's hard to undo asks first, in a dialog in the page's
colours: what will happen, and two buttons, the safe one focused. Enter
presses the focused button, Escape or a click outside is no, and the focus
goes back to the button that asked.

| Action | Asks |
|---|---|
| Cancel (a runs row, a run's header or Status card) | "Cancel run 4418?": a queued run leaves the queue and won't start; a running one stops before its next step, and the step running has `MORCA_CANCEL_KILL_SECONDS` to finish; a failed one isn't retried |
| Cancel on a runs list (bulk) | "Cancel 3 runs?" (or "all 120 runs that match"); nothing ticked, it doesn't ask |
| Cancel queued runs (a pipeline's Operate) | "Cancel the runs of toy over 2024-01..2024-03?" |
| Rerun (a succeeded run's header) | "Rerun every step of run 4418?", a new run over the same partitions |
| Rerun from here (an attempt's page) | "Rerun run 4418 from measure?", the steps before it copied |
| Rebuild downstream (a dataset's page) | "Rebuild what reads lake.a over 2024-01?" |

A form asks with `data-confirm` (on the form, or on one of its submit
buttons), `data-confirm-body`, `data-confirm-yes`, `data-confirm-no` and
`data-confirm-danger` (`ask_attrs` in `morca._internal.ui.layout`). It's one
`<dialog>` per page, and yes submits the form again with the same button,
so what's posted, the login cookie and the Origin check are as before.
Without scripts, or in a browser without `<dialog>`, the form posts
without asking. Previews (GET) never ask, and nothing in the UI uses the
browser's `confirm()`, `alert()` or `prompt()`.

## Step cards

Each step in the steps views (a pipeline's Steps card, Graph and Table,
and a run's Table, Timeline and Graph) shows a card on hover, keyboard
focus (each step is a tab stop) or a tap; Escape, a tap elsewhere or
scrolling the step out of sight closes it. On a box that links to its
code, as the graph's do, the first tap shows the card and the next opens
the code.

| Part | From |
|---|---|
| Its docstring's first sentence over the signature, coloured, and the rest of its first paragraph under it, with a link to the line | the source at the commit the run ran or the pipeline is registered with: `/code?u=<file>&at=<line>` answers only the `def`'s lines and docstring, fetched once per step per page. Until it answers (or for a private repository, or code `morca locate` didn't map) the card shows the signature `describe` records, `def measure(mut ctx: Ctx, input: Measured) raises -> Measured`, its argument names morca's |
| Kind (with what it means), `after=`, input and output types | the registration's `describe` |
| Reads and Writes, linked to the datasets' pages | the step's `reads=` and `writes=` |
| Pipeline page: its last runs' attempts, how many failed, the p50 and most its succeeded attempts took, and their peak memory's p50 and most | the attempts of the pipeline's latest 20 runs, with what each used where it was measured |
| Run page, on an attempt (a timeline bar, or a table row's latest): its partition, number and status (linked to its page), start, end, how long it took, peak memory, CPU and cores, and its error's first line | that attempt |

Everything but the docstring is in the page, one
`<script type="application/json" class="step-cards">` in the Steps card,
so a hover asks the server nothing; a run's live Steps card brings a new
one each time it refreshes. Without scripts the page is as it was, and
each bar and box keeps its title.

## Ops

"Ops" in the nav has four pages, each linking the others; `/ops` opens
Alerts, the first:

| Page | What it shows |
|---|---|
| Ops › Alerts (`/ops/alerts`, `/api/alerts`) | every [alert](alerts.md) sent to the phone, newest first, with its links and whether it is still open. See [Alerts](#alerts) |
| Ops › Control (`/ops/control`, `/api/system`) | the one machine running the scheduler, the UI, Postgres and local and control-placed runs: CPU, memory, disk, network and each container's memory over `?range=24h`, `7d` or `14d`; its **Memory pressure** (PSI `some` and `full` avg10, avg60 and avg300, the file read, and whether new runs wait for it: [morca.toml](morca-toml.md#memory-pressure)), `memory_pressure` in the JSON, null without a reading in the last minute; whether [alerts](alerts.md) are on and the last ones; the [watchdog](watchdog.md)'s banner; the local and control-placed runs going, each with its cgroup's memory against its limit, its kill line, its grant and its CPU priority, the cgroup's `cpu.weight` or the `nice` it started at ([hetzner.md](hetzner.md#a-cgroup-per-run); `runs` in the JSON, with `cpu_weight` and `nice`) |
| Ops › Pools (`/ops/pools`, `/api/pools`) | every machine runs are placed on, a row each, by pool: the EC2 instances morca launches, a Kubernetes run's pods, the machines running [`morca worker`](workers.md). See [Pools](#pools) |
| Ops › Watchdog (`/watchdog`, `/api/watchdog`) | the rules that pause pipelines, and their trips. See [the watchdog page](#the-watchdog-page) |

Each section's heading links to it, so a link can open at one chart:

- Control: `#cpu`, `#memory`, `#disk`, `#network`, `#containers`,
  `#runs`, `#container-memory`
- Pools: `#machines`, and with EC2 in view `#hours`, `#runs`, `#fleet-cpu`,
  `#fleet-network`

`/system` redirects to Control. Fleet and Workers are Pools now:
`/ops/fleet` and `/fleet` redirect to `/ops/pools?kind=ec2` (Fleet's
`?range=` kept), `/ops/workers` to `/ops/pools?kind=self-hosted`, and their
fragments to `/ops/pools/live` with the same filter. A script that asks
them for JSON (`Accept: application/json`, `?format=json`) gets Fleet's and
Workers' JSON as before, with no redirect; `/api/fleet` and `/api/workers`
are unchanged.

### Alerts

Ops › Alerts lists every alert morca has pushed to ntfy, or is about to,
newest first and 50 to a page, so what reached the phone can be found in
the UI too. Each row has:

| Column | |
|---|---|
| When | when it was raised (or resolved), as how long ago; the full time on hover |
| Kind | run failed, watchdog trip, fill stalled, disk, worker lost, memory pressure, backup failed, or a script's own kind; an all-clear says "resolved" after it. Its priority is on hover |
| Alert | its title and message, as they were sent |
| Links | what it is about: the run, the pipelines it paused or names, the watchdog's rule, the worker, or Control |
| Delivered | sent; waiting; failed, retrying (with the error ntfy's server or the network gave); or not sent, when a newer alert or its resolution replaced it before it went |
| State | for the alerts that end (a watchdog trip, a stalled fill, the disk, memory pressure, and a kind `morca notify --resolved` has ended): open, resolved with when, or raised again when the same alert was sent anew first |

Open alerts are tinted red, and a line above the table counts them and
links to `?state=open`. The filters are `?kind=` (each kind with its count)
and `?state=open` or `resolved`; `?before=<id>` and `?after=<id>` page it
(the arrow keys too), `?limit=` sets the size (at most 500). `/api/alerts`
is the same as JSON: `alerts` (each with its `links`, `delivery`, `error`,
`state` and `resolved`), `open`, `total`, `kinds`, and the cursors `next`
and `prev` with their URLs. `morca alerts [--kind K] [--open|--resolved]
[--limit N] [--json]` prints the newest 20, over the database or
`--remote`.

Alerts are kept for 90 days in `orca.alerts`, a row per alert raised and
per "resolved". One held back because the same alert went out within
`MORCA_NOTIFY_MIN_SECONDS` isn't sent, so it has no row; the
[watchdog](watchdog.md)'s trips are all on its page.

### Pools

Every placement target is a pool, and a machine is in one:

| Pool | Kind | A row is |
|---|---|---|
| `ec2` | `ec2` | an instance morca launched for a run, while it's up and for an hour after it ended |
| `kubernetes` | `k8s` | a live run's pods (`morca-<run>-<start>`), on the Kubernetes runner. The runner records no pods or nodes of its own, so the run is the machine |
| `worker:<pool>` | `self-hosted` | the machine a [worker token](workers.md#tokens)'s `morca worker` runs on |

The scheduler's own machine isn't a pool: it runs the local runner's runs
and control-placed ones, and it is Control.

Each row has the machine (linked to its page), its pool and kind, its
state (`live`, `draining` or `gone`, with what it's doing beside it:
`starting`, `running`, `idle (pooled)`, `ended`, `idle`, `revoked`,
`expired`, `not seen`), the image tag its runs need, its CPUs and memory,
the runs on it, its last heartbeat, its CPU now and over ten minutes (EC2
instances only, which are sampled), and the worker: a run's head or dista
worker on EC2, or `morca worker` with its token and label. Every column's
"?" says what it is.

The kind tabs (All, EC2, Kubernetes, Self-hosted) and the pool links
filter it with `?kind=` and `?pool=`, plain links that keep each other.
With EC2 in view the page also has Fleet's cards (hosts, cost, runs and
errors per hour) and charts over `?range=24h` or `7d`, and on the local
runner it says that no instances are launched and the Cost tile shows
`MORCA_FIXED_COST`.

A machine's page (`/ops/pools/<kind>/<id>`, from its row) has its facts
and, for an EC2 instance, its samples over its run, as the run page's
Machines card draws them; for a worker, the runs it claimed. A worker
samples only its runs' processes, so their Resources cards have what they
used.

## The watchdog page

`/watchdog` lists each rule with each of its thresholds, the last value and
whether it is past it, the snooze form, and the trips with what each
tripped on. See [watchdog.md](watchdog.md).

## Stopping

SIGTERM (what `docker stop` sends) or SIGINT (Ctrl-C) drains `morca ui`
instead of cutting it off: it closes its listening socket, so new
connections are refused, answers `/healthz` with 503 `draining` from then
on, so a health checker or proxy asking over a kept-alive connection stops
routing here, lets the requests already in flight finish, and
exits 0 once none has been for 200 ms. `MORCA_UI_DRAIN_SECONDS` (default 8,
under `docker stop`'s 10 s grace) bounds the wait; when it's up the server
stops and closes its kept-alive connections, and a request still running
half a second later is given up, with exit code 1. A second signal stops
it at once. The worker API on `MORCA_WORKER_ADDR`, if any, ends with the
process. `src/morca/_internal/web/drain.mojo` has the details.
