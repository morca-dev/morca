"""Every path `morca ui` answers, and what answers it: the route table
`morca._internal.web.server` serves (`morca._internal.web.router` for how a path matches).

Each handler here only takes the request's parameters out of the `Call`
and hands them to the page (`morca._internal.ui`) or the action (`morca._internal.api.actions`)
that does the work. A page answers HTML, or its JSON to `Accept:
application/json` or `?format=json` (`/api/...` always JSON). The worker
API (`/api/worker/...`) has a table of its own, `morca._internal.api.worker`, and the
stylesheet is served before any route is looked up.

| Path | |
|---|---|
| `/` | pipelines, with their coverage (`morca._internal.coverage`: partitions or keys done of those it has, `coverage` in the JSON), schedules, next runs and last runs |
| `/pipelines/<name>` | `?tab=overview` (default), `runs` or `operate`, each its own page; a pipeline's steps, partitions, schedule, next runs and runs; a keyed one's keys, done, live and failed; its fill (`morca._internal.fill`): done of total, rate, ETA, today's estimated spend against its budget and why it's idle; its registration as `morca config show` prints it (`#config`, Overview); `?preview=1&partitions=` (`&rerun=1`): what Start runs would queue, queueing nothing; `?steps=graph` or `table`: the Steps tab shown without scripts |
| `/pipelines/<name>/progress` | the page's Progress card (runs going, fill, how far a sensor is behind what it follows (`morca._internal.follow`), next run, coverage), as an HTML fragment the page refreshes every 5 s; `?tab=` is the tab polling it, which its "Log in to ..." links come back to |
| `/api/pipelines/<name>` | the same as JSON, whatever is asked for |
| `/pipelines/<name>/calendar` | a daily or monthly pipeline's days (months) of `?month=2023-01` (`2023`) with their state, as JSON: done, failed, live, open, outside; the page shows it as coverage (`?cal=` a month or year, `?cov=month` or `year`: a daily one's tab, year by default, both from one read of the year in `morca._internal.ui.coverage`) and as the Start runs form's date picker |
| `/pipelines/<name>/keys/<key>` | one key of a keyed pipeline: its steps in every run it was in |
| `/runs` | runs, newest first, `?limit=` (or `?n=`; 50, at most 500) to a page; `?pipeline=`, `?status=` (one or more), `?trigger=`, `?from=`, `?to=`, `?since=`, `?key=` (a partition: a glob or a part), `?run=` (goes to that run), `?batch=` (the runs queued together in one backfill, fill pass or sensor pass); `?before=<id>`: the page older than that run, `?after=<id>`: the page newer than it (keyset, so pages stay put as runs arrive); the JSON's `next`, `prev` (and `next_url`, `prev_url`) are the cursors either side. A pipeline's Runs tab pages and filters the same, 20 to a page (`runs_page` in its JSON). Each status's count under the other filters is the JSON's `counts` |
| `/runs/table` | a runs list's page as the fragment it refreshes from: `?view=list` (`/runs`), `pipeline` (a pipeline's Runs tab) or `home` (recent runs, a row per batch), with the list's filters, `limit` and cursor; `X-Poll-Every` says when to ask again (5 s while a run on it is queued or running, 30 s on the newest page otherwise), and an older page with nothing going on answers 286 |
| `/home/pipelines` | the home page's table of pipelines, as the fragment it refreshes from (5 s while a run is queued or running, else 30 s) |
| `/runs/<id>` | a run's cards (Status, Partitions & trigger, Code, Resources, Settings), its steps (`?steps=table` (default), `timeline` or `graph`: the Steps tab shown without scripts), its machines, and the snapshots each step read and wrote |
| `/runs/<id>/attempts/<attempt>` | an attempt's log, with its error; its facts refresh from `/runs/<id>/attempts/<attempt>/facts` while it runs |
| `/code` | `?u=` a link to a file at a commit on GitHub: its lines and each coloured as HTML (`morca._internal.highlight`), as JSON, for the code shown on hover; the UI fetches the file, so a browser needn't reach GitHub. With `&at=` a line, only that `def`'s signature, coloured, and its docstring's first paragraph, for a step's card (`morca._internal.ui.step_cards`) |
| `/runs/<id>/timeline.json` | the run's Dista timeline, which its page draws (`morca._internal.ui.viz`) and Perfetto opens |
| `/api/gantt` | the pipelines in dataset order with their runs over `?window=1h`, `6h`, `24h` (default) or `7d`, and the runs each started: the home page's Timeline tab (`morca._internal.ui.viz`) |
| `/runs/<id>/driver.log` | the run's driver output, as the scheduler kept it |
| `/runs/<id>/metrics` | the run's machines: charts and peaks from its samples (`morca._internal.metrics`) |
| `/ops` | redirects to `/ops/alerts`; "Ops" in the nav has Alerts, Control, Pools and Watchdog under it |
| `/ops/alerts` | Alerts (`morca._internal.ui.alerts`): every alert sent (`orca.alerts`), newest first, 50 to a page (`?limit=`, at most 500; `?before=<id>`, `?after=<id>`), `?kind=` and `?state=open` or `resolved`; its kind, title and message, links, whether ntfy took it and whether it is still open; the newest page refreshes every 30 s from `/ops/alerts/live`; `/api/alerts` is the same as JSON |
| `/ops/control` | Control, the one machine running the scheduler, this UI, Postgres and local and control-placed runs (so not a pool on Pools): its own health: CPU, memory, the disk Postgres is on and network over `?range=24h`, `7d` or `14d`, and each container's memory (`morca._internal.system`), and the watchdog's banner, refreshed every 30 s from `/ops/control/live`; `/api/system` is the same as JSON; `/system` redirects here (301) |
| `/metrics` | Prometheus gauges: the control instance's CPU, memory, disk, network and containers' memory, runs running and queued, hosts, and errors in the last hour; open like the other pages (reads need no login) |
| `/ops/pools` | Pools, every machine runs are placed on (`morca._internal.ui.pools`, `morca._internal.views.pools`): a row per EC2 instance morca launched (live, and gone for an hour after it ended), per live Kubernetes run's pods (on the Kubernetes runner) and per worker token's machine (`orca.workers`), with its pool, kind, state, image, CPUs, memory, runs, last heartbeat, CPU and worker; `?pool=` (`ec2`, `kubernetes`, `worker:<pool>`) and `?kind=` (`ec2`, `k8s`, `self-hosted`) filter it; machines gone for over an hour are behind `?gone=1`; with EC2 in view, Fleet's cards (`morca._internal.fleet`) and its charts over `?range=24h` or `7d`; refreshed every 10 s from `/ops/pools/live`; `/api/pools` the same as JSON, every machine unless `?gone=0` |
| `/ops/pools/<kind>/<id>` | a machine: its facts, and an EC2 instance's samples over its run (the run page's Machines charts) or the runs a worker claimed |
| `/ops/fleet`, `/ops/workers` | moved to `/ops/pools?kind=ec2` (Fleet's `?range=` kept) and `?kind=self-hosted` (301), as are `/ops/fleet/hosts`, `/ops/workers/live`, `/fleet` and `/fleet/hosts` (to `/ops/pools/live` for the fragments); asked for JSON, they answer Fleet's and Workers' JSON as before, as `/api/fleet` (the summary, hosts and charts of `morca._internal.fleet`) and `/api/workers` (each worker token's pool, label, worker, image, last heartbeat, runs, CPUs and memory) do. A worker's own requests go to `/api/worker/...` with its token |
| `/watchdog`, `/api/watchdog` | the watchdog's rules with their last values, limits and snoozes, and the trips with a pipeline still paused (`morca._internal.watchdog`); also the red banner on `/`, `/ops/pools` and `/ops/control`; the page refreshes every 30 s from `/watchdog/live` |
| `/datasets` | datasets, with their writers, readers and latest snapshots, and the graph of pipelines and datasets |
| `/datasets/<name>` | a dataset's place in that graph, the steps that write and read it (linked to their code), what a rebuild of it runs, and its snapshots; `?preview=1&partitions=`: a rebuild's runs by level, queueing nothing |
| `/datasets/<name>?tab=data` | its Data tab (`morca._internal.ui.data`): the schema (columns, types, field ids, docs) and partition spec, the partitions (rows, files, bytes and the snapshot that last wrote each, from the manifests), a page of rows and a quick chart, read by the project's `morca_maintain data` within limits (`morca._internal.views.data`). `?snapshot=` a snapshot (else the current one); `?f=COL:OP:VALUE`, one or more (`OP` `eq`, `ne`, `lt`, `le`, `gt`, `ge` or `in`, its values split on `,`); `?c=` the columns, one or more; `?sort=COL` or `-COL`; `?cursor=` the page's `next`; `?n=` rows (100, `MORCA_DATA_PAGE_ROWS`, at most); `?x=`, `?y=` (up to 3), `?agg=avg` or `sum` and `?chart=line` or `bar`. A read that stops at a limit says why (`stopped`). Hidden from visitors not logged in (401) when morca.toml has `[datasets."<name>"] public = false` |
| `/datasets/<name>/data.json` | the Data tab's JSON, whatever is asked for: `schema`, `partition_spec`, `snapshots`, `partitions`, `rows` (`next`, and `next_url`), `chart`, `limits` and `csv_url` |
| `/datasets/<name>/data.csv` | the filtered (and sorted) rows as CSV, up to `MORCA_DATA_DOWNLOAD_ROWS` (100,000); `X-Morca-Rows` says how many, and `X-Morca-Stopped` why it stopped, when it did |
| `/datasets/<name>?before=<cursor>` | its snapshots 50 to a page, newest first; `?after=` for the newer page, the cursor `<attempt>.<snapshot>` (`snapshots_page` in the JSON) |
| `/datasets/<name>/snapshots/<id>` | a snapshot's lineage (`morca._internal.lineage`): its diagram, Upstream (`back` in the JSON: the snapshot, if a run wrote it, and the snapshots it was written from, with the run and step that wrote each and what that step read) and Downstream (`forward`: the snapshots written from it) |
| `/rebuilds/<id>` | a rebuild's pipelines by level, with their runs (`morca._internal.sensors`) |

The actions, each a `POST`, are `morca._internal.api.actions`'; `/login`, `/logout`,
`/api/login` and `/api/logout` are `morca._internal.web.auth`'s.
"""

from morca._internal.api import actions
from morca._internal.api.ops import (
    fleet_api,
    fleet_json,
    gantt_api,
    system_api,
    watchdog_api,
    workers_api,
)
from morca._internal.api.pipelines import calendar_page, pipeline_json
from morca._internal.api.runs import run_json
from morca._internal.state import State
from morca._internal.ui.alerts import alerts, alerts_api, alerts_live
from morca._internal.ui.attempt import attempt, attempt_facts, attempt_log
from morca._internal.ui.code import code_page
from morca._internal.ui.data import data_csv, data_json, data_page
from morca._internal.ui.datasets import (
    dataset_page,
    datasets_page,
    rebuild_page,
    snapshot_page,
)
from morca._internal.ui.home import home, home_pipelines
from morca._internal.ui.errors import not_found
from morca._internal.ui.ops import (
    control_live,
    metrics_page,
    moved,
    ops_home,
    system_page,
    to_pools,
    watchdog_live,
    watchdog_page,
)
from morca._internal.ui.pools import (
    PoolsAsk,
    machine_page,
    pools_api,
    pools_ask,
    pools_live,
    pools_page,
)
from morca._internal.ui.pipeline import (
    key_page,
    pipeline_html,
    pipeline_progress,
    pipeline_progress_here,
)
from morca._internal.ui.run import (
    cluster_log,
    driver_log,
    run_html,
    run_live,
    run_metrics,
    run_steps,
    timeline,
)
from morca._internal.ui.runs import (
    jumped,
    runs,
    runs_fragment_query,
    runs_table,
)
from morca._internal.views.pipelines import PipelineAsk, pipeline_view
from morca._internal.views.runs import run_view, runs_query
from morca._internal.web.auth import (
    API_LOGIN,
    API_LOGOUT,
    LOGIN,
    LOGOUT,
    api_login,
    api_logout,
    login,
    login_form,
    logout,
)
from morca._internal.web.page import Page
from morca._internal.web.router import Call, Route, action, auth, page


def routes() -> List[Route]:
    """The table, first match first."""
    return [
        # Home, and the runs.
        page("/", _home),
        page("/home/pipelines", _home_pipelines),
        page("/runs", _runs),
        page("/runs/table", _runs_table),
        page("/runs/{id:int}", _run, "run"),
        page("/runs/{id:int}/live", _run_live, "run"),
        page("/runs/{id:int}/steps", _run_steps, "run"),
        page("/runs/{id:int}/metrics", _run_metrics, "run"),
        page("/runs/{id:int}/timeline.json", _timeline, "run"),
        page("/runs/{id:int}/driver.log", _driver_log, "run"),
        page("/runs/{id:int}/cluster/{name}", _cluster_log, "run"),
        page("/runs/{id:int}/attempts/{attempt:int}", _attempt, "attempt"),
        page(
            "/runs/{id:int}/attempts/{attempt:int}/log", _attempt_log, "attempt"
        ),
        page(
            "/runs/{id:int}/attempts/{attempt:int}/facts",
            _attempt_facts,
            "attempt",
        ),
        page("/code", _code),
        # Pipelines; /api/pipelines/... is the same as JSON.
        page("/pipelines/{name}", _pipeline),
        page("/pipelines/{name}/progress", _progress),
        page("/pipelines/{name}/calendar", _calendar),
        page("/pipelines/{name}/keys/{key}", _key),
        page("/api/pipelines/{name}", _pipeline),
        page("/api/pipelines/{name}/progress", _progress),
        page("/api/pipelines/{name}/calendar", _calendar),
        page("/api/pipelines/{name}/keys/{key}", _key),
        # Datasets and their lineage.
        page("/datasets", _datasets),
        page("/datasets/{name}", _dataset),
        page("/datasets/{name}/data.json", _data_json),
        page("/datasets/{name}/data.csv", _data_csv),
        page("/datasets/{name}/snapshots/{id:int}", _snapshot, "snapshot"),
        page("/rebuilds/{id:int}", _rebuild, "rebuild"),
        # Ops: Alerts, Control, Pools, the watchdog; Fleet and Workers moved
        # to Pools, their JSON paths kept.
        page("/ops", _ops),
        page("/ops/alerts", _alerts),
        page("/ops/alerts/live", _alerts_live),
        page("/api/alerts", _alerts_api),
        page("/system", _moved),
        page("/fleet", _fleet),
        page("/fleet/hosts", _fleet),
        page("/ops/control", _control),
        page("/ops/control/live", _control_live),
        page("/api/system", _system_api),
        page("/metrics", _metrics),
        page("/ops/pools", _pools),
        page("/ops/pools/live", _pools_live),
        page("/ops/pools/{kind}/{id}", _machine),
        page("/api/pools", _pools_api),
        page("/ops/fleet", _fleet),
        page("/ops/fleet/hosts", _fleet),
        page("/api/fleet", _fleet_api),
        page("/ops/workers", _workers),
        page("/ops/workers/live", _workers),
        page("/api/workers", _workers_api),
        page("/watchdog", _watchdog),
        page("/watchdog/live", _watchdog_live),
        page("/api/watchdog", _watchdog_api),
        page("/api/gantt", _gantt),
        # Logging in and out (morca.web.auth).
        page(LOGIN, login_form),
        auth(LOGIN, login),
        auth(LOGOUT, logout),
        auth(API_LOGIN, api_login),
        auth(API_LOGOUT, api_logout),
        # The actions (morca.api.actions).
        action("/pipelines/{name}/runs", actions.start),
        action("/pipelines/{name}/backfill", actions.backfill),
        action("/pipelines/{name}/cancel", actions.cancel_pipeline),
        action("/pipelines/{name}/pause", actions.pause),
        action("/pipelines/{name}/unpause", actions.unpause),
        action("/watchdog/all/ack", actions.acknowledge_all),
        action("/watchdog/{trip:int}/ack", actions.acknowledge_trip, "trip"),
        action("/watchdog/{rule}/snooze", actions.snooze),
        action("/datasets/{name}/rebuild", actions.rebuild),
        action("/runs/bulk", actions.bulk),
        action("/runs/{id:int}/resume", actions.resume, "run"),
        action("/runs/{id:int}/rerun", actions.rerun, "run"),
        action("/runs/{id:int}/cancel", actions.cancel, "run"),
    ]


# ── home and runs ────────────────────────────────────────────────────────────


def _home(mut db: State, call: Call) raises -> Page:
    return home(db)


def _home_pipelines(mut db: State, call: Call) raises -> Page:
    var p = home_pipelines(db)
    p.here = "/"
    return p^


def _runs(mut db: State, call: Call) raises -> Page:
    return runs(db, runs_query(call.url, "list"), call.url)


def _runs_table(mut db: State, call: Call) raises -> Page:
    var p = runs_table(db, call.url)
    # Its login links go back to the list's page, not the fragment.
    p.here = runs_fragment_query(call.url).here()
    return p^


def _run(mut db: State, call: Call) raises -> Page:
    var id = call.int("id")
    var v = run_view(db, id)
    if not v:
        return not_found(String("no run ", id))
    return Page(
        200, run_json(v.value()), run_html(db, v.value(), call.query("steps"))
    )


def _run_live(mut db: State, call: Call) raises -> Page:
    return run_live(db, call.int("id"))


def _run_steps(mut db: State, call: Call) raises -> Page:
    return run_steps(db, call.int("id"))


def _run_metrics(mut db: State, call: Call) raises -> Page:
    return run_metrics(db, call.int("id"))


def _timeline(mut db: State, call: Call) raises -> Page:
    return timeline(db, call.int("id"))


def _driver_log(mut db: State, call: Call) raises -> Page:
    return driver_log(db, call.int("id"))


def _cluster_log(mut db: State, call: Call) raises -> Page:
    return cluster_log(db, call.int("id"), call.param("name"))


def _attempt(mut db: State, call: Call) raises -> Page:
    return attempt(db, call.int("id"), call.int("attempt"))


def _attempt_log(mut db: State, call: Call) raises -> Page:
    return attempt_log(db, call.int("id"), call.int("attempt"))


def _attempt_facts(mut db: State, call: Call) raises -> Page:
    return attempt_facts(db, call.int("id"), call.int("attempt"))


def _code(mut db: State, call: Call) raises -> Page:
    return code_page(call.query("u"), call.query("at"))


# ── pipelines ────────────────────────────────────────────────────────────────


def _pipeline(mut db: State, call: Call) raises -> Page:
    var ask = PipelineAsk(
        name=call.param("name"),
        partitions=call.query("partitions"),
        rerun=call.query("rerun") == "1",
        preview=call.query("preview") == "1",
        cal=call.query("cal"),
        allow_append=call.query("allow_append") == "1",
        steps=call.query("steps"),
        tab=call.query("tab"),
        cov=call.query("cov"),
        url=call.url,
    )
    var v = pipeline_view(db, ask)
    if not v:
        return not_found(String("no pipeline ", ask.name))
    if ask.shown_tab() == "runs" and jumped(v.value().runs):
        return Page(
            303,
            pipeline_json(v.value(), ask),
            String(),
            location=String("/runs/", v.value().runs.q.run),
        )
    return Page(
        200,
        pipeline_json(v.value(), ask),
        pipeline_html(db, v.value(), ask, call.user),
    )


def _progress(mut db: State, call: Call) raises -> Page:
    var p = pipeline_progress(db, call.param("name"))
    # Its login links go back to the pipeline's page, not the fragment (#314).
    p.here = pipeline_progress_here(call.param("name"), call.query("tab"))
    return p^


def _calendar(mut db: State, call: Call) raises -> Page:
    return calendar_page(db, call.param("name"), call.query("month"))


def _key(mut db: State, call: Call) raises -> Page:
    return key_page(db, call.param("name"), call.param("key"))


# ── datasets ─────────────────────────────────────────────────────────────────


def _datasets(mut db: State, call: Call) raises -> Page:
    return datasets_page(db)


def _dataset(mut db: State, call: Call) raises -> Page:
    if call.query("tab") == "data":
        return data_page(db, call.param("name"), call.url, call.user)
    return dataset_page(
        db,
        call.param("name"),
        call.query("partitions"),
        call.query("preview") == "1",
        call.url,
    )


def _data_json(mut db: State, call: Call) raises -> Page:
    return data_json(db, call.param("name"), call.url, call.user)


def _data_csv(mut db: State, call: Call) raises -> Page:
    return data_csv(db, call.param("name"), call.url, call.user)


def _snapshot(mut db: State, call: Call) raises -> Page:
    return snapshot_page(db, call.param("name"), Int64(call.int("id")))


def _rebuild(mut db: State, call: Call) raises -> Page:
    return rebuild_page(db, call.int("id"))


# ── ops ──────────────────────────────────────────────────────────────────────


def _ops(mut db: State, call: Call) raises -> Page:
    return ops_home()


def _alerts(mut db: State, call: Call) raises -> Page:
    return alerts(db, call.url)


def _alerts_live(mut db: State, call: Call) raises -> Page:
    return alerts_live(db, call.url)


def _alerts_api(mut db: State, call: Call) raises -> Page:
    return alerts_api(db, call.url)


def _moved(mut db: State, call: Call) raises -> Page:
    return moved(call.url, call.path)


def _control(mut db: State, call: Call) raises -> Page:
    return system_page(db, call.query("range"))


def _control_live(mut db: State, call: Call) raises -> Page:
    return control_live(db, call.query("range"))


def _system_api(mut db: State, call: Call) raises -> Page:
    return system_api(db, call.query("range"))


def _metrics(mut db: State, call: Call) raises -> Page:
    return metrics_page(db)


def _ask(call: Call, gone: Bool) -> PoolsAsk:
    return pools_ask(
        call.query("pool"), call.query("kind"), call.query("range"), gone
    )


def _pools(mut db: State, call: Call) raises -> Page:
    return pools_page(db, _ask(call, call.query("gone") == "1"))


def _pools_live(mut db: State, call: Call) raises -> Page:
    return pools_live(db, _ask(call, call.query("gone") == "1"))


def _pools_api(mut db: State, call: Call) raises -> Page:
    return pools_api(db, _ask(call, call.query("gone") != "0"))


def _machine(mut db: State, call: Call) raises -> Page:
    return machine_page(db, call.param("kind"), call.param("id"))


def _fleet(mut db: State, call: Call) raises -> Page:
    """Fleet's old paths: to Pools, or Fleet's JSON as it was."""
    return to_pools(
        call.path,
        call.query("range"),
        fleet_json(
            db, call.query("sort"), call.query("dir"), call.query("range")
        ),
    )


def _fleet_api(mut db: State, call: Call) raises -> Page:
    return fleet_api(db, call.query("range"))


def _workers(mut db: State, call: Call) raises -> Page:
    """Workers' old paths: to Pools, or Workers' JSON as it was."""
    return to_pools(call.path, "", workers_api(db).json.copy())


def _workers_api(mut db: State, call: Call) raises -> Page:
    return workers_api(db)


def _watchdog(mut db: State, call: Call) raises -> Page:
    return watchdog_page(db)


def _watchdog_live(mut db: State, call: Call) raises -> Page:
    return watchdog_live(db)


def _watchdog_api(mut db: State, call: Call) raises -> Page:
    return watchdog_api(db)


def _gantt(mut db: State, call: Call) raises -> Page:
    return gantt_api(db, call.query("window"))
