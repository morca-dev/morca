"""Ops' Pools (`/ops/pools`): a row per machine of every pool runs are
placed on (`morca._internal.views.pools`), filtered by pool and kind with plain links,
refreshed every 10 s from `/ops/pools/live`; a machine's own page
(`/ops/pools/<kind>/<id>`); and `/api/pools`. With EC2 in view the page
keeps Fleet's summary cards and charts (`morca._internal.fleet`).

Pools replaced Fleet and Workers: `/ops/fleet` and `/ops/workers` redirect
here (`?kind=ec2`, `?kind=self-hosted`), and answer their old JSON to a
script that asks for JSON, as `/api/fleet` and `/api/workers` still do.
"""

from std.os import getenv

from morca._internal.ui.pool_status import (
    scaled_pools,
    scaled_pools_html,
    scaled_pools_json,
)
from morca._internal.fleet import (
    charts_html,
    fleet_charts,
    fleet_summary,
    sparkline,
    summary_html,
)
from morca._internal.html import Html, url_encode
from morca._internal.json import quote
from morca._internal.metrics import metrics_html, parse_samples
from morca._internal.logs import read_location
from morca._internal.sample import machine_name, metrics_location
from morca._internal.state import State
from morca._internal.ui.layout import card_open, fact_item, page_html
from morca._internal.ui.errors import not_found
from morca._internal.ui.terms import header_help, value_help
from morca._internal.views.pools import (
    EC2,
    K8S,
    SELF_HOSTED,
    Machine,
    PoolCount,
    WorkerRun,
    filtered,
    kind_of,
    machine,
    machines,
    old_gone,
    pool_counts,
    run_pipeline,
    worker_runs,
)
from morca._internal.views.runs import step_spans
from morca._internal.watchdog import active_trips, banner_html
from morca._internal.web.page import Page


comptime POOLS_EVERY = 10
"""Seconds between refreshes of the machines, as Fleet's hosts and the
Workers table were."""


@fieldwise_init
struct PoolsAsk(Copyable, Movable):
    """What the page was asked for: `?pool=`, `?kind=`, `?range=`, and
    `?gone=1`."""

    var pool: String
    var kind: String
    var range: String
    var gone: Bool
    """Whether machines gone for more than an hour are listed."""

    def query(self, with_range: Bool = True) -> String:
        """The query that asks for it again (`?` included; empty for none)."""
        var q = String()
        if self.pool:
            q.write("?pool=", url_encode(self.pool))
        if self.kind:
            q.write("&" if q else "?", "kind=", self.kind)
        if self.gone:
            q.write("&" if q else "?", "gone=1")
        if with_range and self.range != "24h":
            q.write("&" if q else "?", "range=", self.range)
        return q^

    def ec2(self) -> Bool:
        """Whether EC2 instances are in view: Fleet's cards and charts."""
        return (not self.kind or self.kind == EC2) and (
            not self.pool or self.pool == EC2
        )


def pools_ask(
    pool: String, kind: String, range: String, gone: Bool
) -> PoolsAsk:
    return PoolsAsk(
        pool,
        kind_of(kind),
        String("7d") if range == "7d" else String("24h"),
        gone,
    )


def _ago(s: Int) -> String:
    if s < 0:
        return "never"
    if s < 120:
        return String(s, " s ago")
    if s < 7200:
        return String(s // 60, " min ago")
    if s < 172800:
        return String(s // 3600, " h ago")
    return String(s // 86400, " days ago")


def _span(s: Int) -> String:
    """A duration as Fleet writes an uptime: `3h 05m`, `12m`, `40s`."""
    if s < 0:
        return "-"
    if s < 60:
        return String(s, "s")
    if s < 3600:
        return String(s // 60, "m")
    if s < 86400:
        var m = (s % 3600) // 60
        return String(s // 3600, "h ", "0" if m < 10 else "", m, "m")
    return String(s // 86400, "d ", (s % 86400) // 3600, "h")


def _memory(mb: Int) -> String:
    if mb <= 0:
        return "-"
    if mb >= 1024:
        var tenths = (mb * 10 + 512) // 1024
        if tenths % 10 == 0:
            return String(tenths // 10, " GiB")
        return String(tenths // 10, ".", tenths % 10, " GiB")
    return String(mb, " MiB")


def machine_href(m: Machine) -> String:
    return String("/ops/pools/", m.kind, "/", url_encode(m.id))


def _state_html(mut h: Html, m: Machine):
    """The state as a badge, with what it means on hover, and what the
    machine is doing beside it when that says more."""
    h.raw("<span")
    var tip = value_help("machine", m.state)
    if tip:
        h.raw(' data-tip="', tip, '" tabindex="0"')
    h.raw(' class="status status--', m.state, '">', m.state, "</span>")
    if m.detail and m.detail != m.state:
        h.raw(' <span class="muted">')
        h.text(m.detail)
        h.raw("</span>")


def _runs_html(mut h: Html, runs: List[Int]):
    var first = True
    for r in runs:
        if r > 0:
            if not first:
                h.raw(" ")
            h.chip(String("/runs/", r), String(r))
            first = False
    if first:
        h.raw('<span class="muted">none</span>')


def _process_html(mut h: Html, m: Machine):
    if m.kind == SELF_HOSTED:
        h.raw("<code>morca worker</code> ")
        h.raw('<span class="muted" title="expires ')
        h.text(m.expires)
        h.raw('">token ')
        h.text(m.token, " · ", m.label)
        h.raw("</span>")
    elif m.kind == EC2:
        h.term("role", m.process)
        h.raw(' <span class="muted">')
        h.text(m.instance_type, " Spot" if m.market == "spot" else String(""))
        h.raw("</span>")
    else:
        h.text(m.process)


def _th(mut h: Html, label: StaticString, num: Bool = False):
    h.raw('<th data-help="pools"', ' class="num"' if num else "", ">")
    h.raw(label, "</th>")


def _gone_link(mut h: Html, ask: PoolsAsk, show: Bool, text: String):
    h.raw('<a href="/ops/pools')
    h.text(PoolsAsk(ask.pool, ask.kind, ask.range, show).query())
    h.raw('">', text, "</a>")


def _gone_html(mut h: Html, ask: PoolsAsk, gone: Tuple[Int, Int], none: Bool):
    """Under the table: the machines it leaves out, and the link that lists
    them; with them listed, the link back. With `none` (nothing is
    running), it is the table's empty state."""
    var n = gone[0]
    if n == 0:
        if none:
            h.raw('<p class="card__none">No machines in this view.</p>')
        return
    var many = String(n, " gone machines" if n > 1 else " gone machine")
    var seen = String("last seen ", _ago(gone[1])) if gone[1] >= 0 else String(
        "never seen"
    )
    if ask.gone:
        h.raw('<p class="muted">', many, ", ", seen, " · ")
        _gone_link(h, ask, False, String("hide gone"))
    elif none:
        h.raw('<p class="card__none">No machines running')
        if ask.pool:
            h.raw(" in ")
            h.text(ask.pool)
        h.raw(". ", n, " ran here before (", seen, "): ")
        _gone_link(h, ask, True, String("show them"))
        h.raw(".")
    else:
        h.raw('<p class="muted">', many, ", ", seen, " · ")
        _gone_link(h, ask, True, String("show all"))
    h.raw("</p>")


def machines_html(
    mut h: Html, ms: List[Machine], ask: PoolsAsk, gone: Tuple[Int, Int]
):
    """The table of machines, a row each, and the gone ones it leaves out
    (`gone`: how many, and when the freshest was last seen)."""
    if len(ms) == 0:
        _gone_html(h, ask, gone, True)
        return
    h.raw('<div class="scroll"><table class="hosts pools"><thead><tr>')
    _th(h, "Machine")
    _th(h, "Pool")
    _th(h, "Kind")
    _th(h, "State")
    _th(h, "Image")
    _th(h, "CPUs", True)
    _th(h, "Memory", True)
    _th(h, "Runs")
    _th(h, "Last heartbeat")
    _th(h, "CPU", True)
    _th(h, "Worker")
    h.raw("</tr></thead><tbody>")
    for m in ms:
        h.raw('<tr class="pools__', m.state, '"><td><a href="')
        h.text(machine_href(m))
        h.raw('"><code>')
        h.text(m.name)
        h.raw("</code></a></td>")
        h.raw("<td>")
        h.link(String("/ops/pools?pool=", url_encode(m.pool)), m.pool)
        h.raw("</td><td>")
        h.term("machine_kind", m.kind)
        h.raw("</td><td>")
        _state_html(h, m)
        h.raw("</td>")
        h.mono(m.image if m.image else String("-"))
        h.num(String(m.cpus) if m.cpus > 0 else String("-"))
        h.num(_memory(m.memory_mb))
        h.raw("<td>")
        _runs_html(h, m.runs)
        h.raw("</td>")
        if m.seen_ago < 0 and m.kind == EC2:
            h.raw('<td class="muted">no samples yet</td>')
        else:
            h.cell(_ago(m.seen_ago))
        if m.cpu >= 0:
            h.raw('<td class="num">')
            h.text(Int(m.cpu + 0.5), "% ")
            h.raw(
                sparkline(
                    m.spark_x, m.spark_y, 100.0, "CPU over the last 10 minutes"
                )
            )
            h.raw("</td>")
        else:
            h.raw('<td class="num muted">-</td>')
        h.raw("<td>")
        _process_html(h, m)
        h.raw("</td></tr>")
    h.raw("</tbody></table></div>")
    _gone_html(h, ask, gone, False)


def _filters_html(mut h: Html, ask: PoolsAsk, counts: List[PoolCount]):
    """The kind as tabs, then the pools as links: plain links, so they
    need no script."""
    h.raw('<nav class="ptabs" aria-label="Kinds of machine">')
    for k in [
        ("", "All"),
        (EC2, "EC2"),
        (K8S, "Kubernetes"),
        (SELF_HOSTED, "Self-hosted"),
    ]:
        var n = 0
        for c in counts:
            if not k[0] or c.kind == k[0]:
                n += c.machines
        h.raw('<a class="ptabs__tab" href="/ops/pools')
        h.text(PoolsAsk(String(), String(k[0]), ask.range, ask.gone).query())
        h.raw('"', ' aria-current="page"' if ask.kind == k[0] else "", ">")
        h.raw(k[1], ' <span class="muted">', n, "</span></a>")
    h.raw("</nav>")
    h.raw('<p class="range pools__pools">Pool: ')
    var shown = List[String]()
    if not ask.pool:
        h.raw("<strong>all</strong>")
    else:
        h.raw('<a href="/ops/pools')
        h.text(PoolsAsk(String(), ask.kind, ask.range, ask.gone).query())
        h.raw('">all</a>')
    for c in counts:
        if ask.kind and c.kind != ask.kind:
            continue
        shown.append(c.pool)
        h.raw(" ")
        if c.pool == ask.pool:
            h.raw("<strong>")
            h.text(c.pool)
            h.raw("</strong>")
        else:
            h.raw('<a href="/ops/pools')
            h.text(PoolsAsk(c.pool, ask.kind, ask.range, ask.gone).query())
            h.raw('">')
            h.text(c.pool)
            h.raw("</a>")
        h.raw(' <span class="muted">', c.live, "/", c.machines, "</span>")
    if ask.pool and ask.pool not in shown:
        h.raw(" <strong>")
        h.text(ask.pool)
        h.raw('</strong> <span class="muted">0</span>')
    h.raw("</p>")


def _live_html(mut h: Html, mut db: State, ask: PoolsAsk) raises:
    """What the page refreshes: Fleet's cards with EC2 in view, the
    filters (their counts move too) and the machines."""
    var all = machines(db)
    if ask.ec2():
        summary_html(h, fleet_summary(db), False)
    _filters_html(h, ask, pool_counts(all))
    scaled_pools_html(h, scaled_pools(db))
    card_open(
        h,
        "machines",
        "Machines",
        (
            "A row per machine of each pool runs are placed on: the EC2"
            " instances morca launches, a Kubernetes run's pods, and the"
            " machines running morca worker for a worker:&lt;pool&gt; pool,"
            " the worker in the row's last column. Refreshed every 10 s."
        ),
        "pools",
        facts=False,
    )
    var inview = filtered(all, ask.pool, ask.kind)
    machines_html(
        h, filtered(all, ask.pool, ask.kind, ask.gone), ask, old_gone(inview)
    )
    h.raw("</section>")


def _machine_json(m: Machine) -> String:
    var runs = String("[")
    for i in range(len(m.runs)):
        runs.write(", " if i else "", m.runs[i])
    runs.write("]")
    return String(
        '{"pool": ',
        quote(m.pool),
        ', "kind": ',
        quote(m.kind),
        ', "id": ',
        quote(m.id),
        ', "name": ',
        quote(m.name),
        ', "state": ',
        quote(m.state),
        ', "detail": ',
        quote(m.detail),
        ', "image": ',
        quote(m.image),
        ', "cpus": ',
        m.cpus,
        ', "memory_mb": ',
        m.memory_mb,
        ', "runs": ',
        runs,
        ', "seen_seconds_ago": ',
        m.seen_ago,
        ', "process": ',
        quote(m.process),
        ', "instance_type": ',
        quote(m.instance_type),
        ', "market": ',
        quote(m.market),
        ', "uptime_seconds": ',
        m.uptime,
        ', "cpu_pct": ',
        String(m.cpu) if m.cpu >= 0 else String("null"),
        ', "mem_pct": ',
        String(m.mem_pct) if m.mem_pct >= 0 else String("null"),
        ', "token": ',
        String(m.token) if m.token else String("null"),
        ', "label": ',
        quote(m.label),
        ', "expires": ',
        quote(m.expires),
        ', "ended": ',
        quote(m.ended),
        ', "url": ',
        quote(machine_href(m)),
        "}",
    )


def pools_json(ask: PoolsAsk, all: List[Machine]) -> String:
    var out = String(
        '{"filters": {"pool": ',
        quote(ask.pool),
        ', "kind": ',
        quote(ask.kind),
        '}, "pools": [',
    )
    var counts = pool_counts(all)
    for i in range(len(counts)):
        ref c = counts[i]
        out.write(
            ", " if i else "",
            '{"pool": ',
            quote(c.pool),
            ', "kind": ',
            quote(c.kind),
            ', "machines": ',
            c.machines,
            ', "live": ',
            c.live,
            "}",
        )
    out.write('], "machines": [')
    var ms = filtered(all, ask.pool, ask.kind, ask.gone)
    for i in range(len(ms)):
        out.write(", " if i else "", _machine_json(ms[i]))
    out.write("]}")
    return out^


def pools_page(mut db: State, ask: PoolsAsk) raises -> Page:
    """`/ops/pools` (and `/api/pools`): every machine of every pool."""
    var h = Html()
    h.raw("<h1>Pools</h1>")
    h.raw(
        '<p class="muted">Every machine runs are placed on, by pool:',
        " <code>ec2</code>, the instances morca launches for runs;",
        " <code>kubernetes</code>, a run's pods on the Kubernetes runner;",
        " and <code>worker:&lt;pool&gt;</code>, the machines of your own",
        " running <code>morca worker</code>. The one machine that runs the",
        ' scheduler, this UI and Postgres is <a href="/ops/control">',
        'Control</a>; <a href="/watchdog">Watchdog</a> lists the rules that',
        " pause pipelines.</p>",
    )
    var trips = active_trips(db)
    banner_html(h, trips)
    if ask.ec2() and getenv("MORCA_RUNNER") == "local":
        h.raw(
            '<p class="alert">This scheduler\'s runner is',
            " <code>local</code>: it runs every run on its own machine and",
            " launches no instances, so there are none to list and no",
            ' per-instance cost. The machine is <a href="/ops/control">',
            "Control</a>; its price is the server's fixed price.</p>",
        )
    h.raw('<div data-poll="/ops/pools/live')
    h.text(ask.query(with_range=False))
    h.raw('" data-poll-every="', POOLS_EVERY, '">')
    _live_html(h, db, ask)
    h.raw("</div>")
    if ask.ec2():
        charts_html(
            h,
            fleet_charts(db, 168 if ask.range == "7d" else 24),
            ask.range,
            String(
                "/ops/pools",
                PoolsAsk(ask.pool, ask.kind, "24h", ask.gone).query(),
            ),
        )
    return Page(
        200,
        _with_scaled(
            db,
            pools_json(
                PoolsAsk(ask.pool, ask.kind, ask.range, True), machines(db)
            ),
        ),
        page_html("Pools", "/ops/pools", h),
    )


def pools_live(mut db: State, ask: PoolsAsk) raises -> Page:
    """`/ops/pools/live`: the page's live part, as the fragment it
    refreshes from; it never ends."""
    var h = Html()
    _live_html(h, db, ask)
    return Page(200, String(), h^.finish(), "text/html; charset=utf-8")


def pools_api(mut db: State, ask: PoolsAsk) raises -> Page:
    """`/api/pools`: the page's machines as JSON, filtered as asked; `?gone=0`
    leaves out those gone for more than an hour."""
    var j = _with_scaled(db, pools_json(ask, machines(db)))
    return Page(200, j.copy(), j^, "application/json")


def _with_scaled(mut db: State, var j: String) raises -> String:
    """`j` (pools_json's object) with the autoscaled pools added."""
    var head = String(j[byte = : j.byte_length() - 1])
    return String(
        head, ', "autoscaled": ', scaled_pools_json(scaled_pools(db)), "}"
    )


def _fact(mut h: Html, key: StaticString, id: StaticString):
    """A fact named as its column is, with the column's help."""
    fact_item(h, key, id, header_help(key, "pools"))


def machine_page(mut db: State, kind: String, id: String) raises -> Page:
    """`/ops/pools/<kind>/<id>`: a machine's facts, and its charts: an EC2
    instance's samples (as its run's Machines card draws them), a worker's
    runs."""
    var found = machine(db, kind, id)
    if not found:
        return not_found(String("no ", kind, " machine ", id))
    var m = found.take()
    var h = Html()
    h.raw('<p class="crumb"><a href="/ops/pools">Pools</a> · <a href="')
    h.text("/ops/pools?pool=", url_encode(m.pool))
    h.raw('">')
    h.text(m.pool)
    h.raw("</a></p><h1>")
    h.text(m.name)
    h.raw(" ")
    _state_html(h, m)
    h.raw("</h1>")
    card_open(
        h,
        "machine",
        "Machine",
        (
            "What morca knows of this machine: its pool and kind, its size,"
            " the runs on it now and when it was last heard from."
        ),
        "pools",
    )
    h.raw('<dl class="facts">')
    _fact(h, "Pool", "m-pool")
    h.text(m.pool)
    h.raw("</dd>")
    _fact(h, "Kind", "m-kind")
    h.term("machine_kind", m.kind)
    h.raw("</dd>")
    _fact(h, "Image", "m-image")
    h.raw("<code>")
    h.text(m.image if m.image else String("-"))
    h.raw("</code></dd>")
    _fact(h, "CPUs", "m-cpus")
    h.text(String(m.cpus) if m.cpus > 0 else String("-"))
    h.raw("</dd>")
    _fact(h, "Memory", "m-memory")
    h.text(_memory(m.memory_mb))
    h.raw("</dd>")
    _fact(h, "Runs", "m-runs")
    _runs_html(h, m.runs)
    h.raw("</dd>")
    _fact(h, "Last heartbeat", "m-seen")
    h.text(_ago(m.seen_ago))
    h.raw("</dd>")
    _fact(h, "Worker", "m-worker")
    _process_html(h, m)
    h.raw("</dd>")
    if m.uptime >= 0:
        _fact(h, "Uptime", "m-uptime")
        h.text(_span(m.uptime))
        h.raw("</dd>")
    if m.cpu >= 0:
        _fact(h, "CPU", "m-cpu")
        h.text(Int(m.cpu + 0.5), "% ")
        h.raw(
            sparkline(
                m.spark_x, m.spark_y, 100.0, "CPU over the last 10 minutes"
            )
        )
        h.raw("</dd>")
    if m.kind == SELF_HOSTED:
        _fact(h, "Expires", "m-expires")
        h.text(m.expires)
        h.raw("</dd>")
    if m.ended:
        _fact(h, "Ended", "m-ended")
        h.text(m.ended)
        h.raw("</dd>")
    h.raw("</dl></section>")
    var runs_json = String("[]")
    if m.kind == EC2:
        _ec2_charts(h, db, m)
    elif m.kind == SELF_HOSTED:
        runs_json = _worker_runs_html(h, db, m)
    else:
        h.raw(
            '<p class="muted">The Kubernetes runner records no pods or',
            " nodes of its own, so this is the run's: its page has its",
            " Machines card, from the samples its pods took.</p>",
        )
    return Page(
        200,
        String('{"machine": ', _machine_json(m), ', "runs": ', runs_json, "}"),
        page_html(m.name, "/ops/pools", h),
    )


def _ec2_charts(mut h: Html, mut db: State, m: Machine) raises:
    """Its samples over its run, as the run page's Machines card draws
    them, from the file its sampler uploaded."""
    var run = m.runs[0] if len(m.runs) > 0 else 0
    card_open(
        h,
        "metrics",
        "Samples",
        (
            "The whole machine every few seconds while its run ran: CPU,"
            " memory, fullest disk, disk io and network, with the run's"
            " steps lined up under them, from the file its sampler uploaded"
            " to the run's metrics folder."
        ),
        "metrics",
        facts=False,
    )
    var loc = metrics_location(
        run_pipeline(db, run), run, String(m.process, "-", m.id)
    )
    var text = String()
    if loc:
        try:
            text = String(from_utf8_lossy=Span(read_location(loc)))
        except:
            pass
    var got = parse_samples(String(m.process, "-", m.id), text)
    if len(got.samples) == 0:
        h.raw(
            '<p class="card__none">No samples yet: the instance uploads them',
            " every MORCA_CLUSTER_LOG_SECONDS once its sampler starts.</p>",
        )
    else:
        metrics_html(h, [got^], step_spans(db, run), m.live())
    h.raw("</section>")


def _worker_runs_html(mut h: Html, mut db: State, m: Machine) raises -> String:
    """The runs the worker claimed, newest first; their JSON."""
    var rs = worker_runs(db, m.token)
    card_open(
        h,
        "runs",
        "Runs",
        (
            "The runs this worker claimed, newest first. Each run's"
            " Resources card has what its processes used, and its Machines"
            " card this machine's samples while it ran."
        ),
        "workers",
        facts=False,
    )
    var j = String("[")
    if len(rs) == 0:
        h.raw('<p class="card__none">It hasn\'t claimed a run.</p>')
    else:
        h.raw(
            '<div class="scroll"><table><thead><tr><th>Run</th>',
            "<th>Pipeline</th><th>Status</th><th>Partitions</th>",
            "<th>Started</th><th>Ended</th></tr></thead><tbody>",
        )
        for i in range(len(rs)):
            ref r = rs[i]
            h.raw("<tr><td>")
            h.chip(String("/runs/", r.id), String(r.id))
            h.raw("</td><td>")
            h.link(String("/pipelines/", url_encode(r.pipeline)), r.pipeline)
            h.raw("</td><td>")
            h.status(r.status)
            h.raw("</td>")
            h.mono(r.partitions)
            h.mono(r.started)
            h.mono(r.ended)
            h.raw("</tr>")
            j.write(
                ", " if i else "",
                '{"id": ',
                r.id,
                ', "pipeline": ',
                quote(r.pipeline),
                ', "status": ',
                quote(r.status),
                "}",
            )
        h.raw("</tbody></table></div>")
    j.write("]")
    h.raw("</section>")
    _worker_charts(h, db, m, rs)
    return j^


def _worker_charts(
    mut h: Html, mut db: State, m: Machine, rs: List[WorkerRun]
) raises:
    """The machine's samples over its latest run, as that run's Machines
    card draws them: the worker starts the sampler beside each run, which
    writes `metrics/worker-<name>.jsonl` in the run's folder."""
    card_open(
        h,
        "metrics",
        "Samples",
        (
            "This machine every few seconds while the worker's latest run"
            " ran: CPU, memory, fullest disk, disk io and network, with the"
            " run's steps lined up under them, from the file the sampler the"
            " worker started beside it wrote to the run's metrics folder."
        ),
        "metrics",
        facts=False,
    )
    if len(rs) == 0:
        h.raw('<p class="card__none">No run yet, so no samples.</p>')
        h.raw("</section>")
        return
    ref r = rs[0]
    var instance = machine_name(m.name)
    var loc = metrics_location(r.pipeline, r.id, instance)
    var text = String()
    if loc:
        try:
            text = String(from_utf8_lossy=Span(read_location(loc)))
        except:
            pass
    var got = parse_samples(instance, text)
    h.raw("<p>Run ")
    h.chip(String("/runs/", r.id), String(r.id))
    h.raw("</p>")
    if len(got.samples) == 0:
        h.raw(
            '<p class="card__none">No samples for it: the worker needs',
            " MORCA_LOGS, and MORCA_SAMPLE_SECONDS above 0.</p>",
        )
    else:
        metrics_html(h, [got^], step_spans(db, r.id), r.status == "running")
    h.raw("</section>")
