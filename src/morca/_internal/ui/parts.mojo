"""Pieces several pages draw: durations, times and partitions in a
table's cells, a runs table with each row's actions, links to code, and a
run's grant and usage as facts.
"""

from morca._internal.actions import cancel_kill_seconds
from morca._internal.html import Html, url_encode
from morca._internal.resources import gb_text
from morca._internal.sample import fixed1
from morca._internal.source import commit_url, web_url
from morca._internal.db.run_rows import Usage
from morca._internal.ui.layout import act_button, fact_item
from morca._internal.usage import bytes_text, cpu_text, usage_text
from morca._internal.views.code import CodeLinks, CodeRef, RunCode
from morca._internal.views.commands import cancel_cli, resume_cli, shell_quote
from morca._internal.views.runs import RunResources, RunRow
from morca._internal.db.run_view import VersionRow


def dataset_links(mut h: Html, names: List[String]):
    for i in range(len(names)):
        if i:
            h.raw(", ")
        h.link(String("/datasets/", url_encode(names[i])), names[i])


def data_href(name: String, snapshot: String = "") -> String:
    """A dataset's Data tab (`morca._internal.ui.data`), at `snapshot` if
    given."""
    var href = String("/datasets/", url_encode(name), "?tab=data")
    if snapshot:
        href.write("&snapshot=", url_encode(snapshot))
    return href^


def data_link(
    mut h: Html,
    name: String,
    private: List[String],
    snapshot: String = "",
    label: String = "data",
):
    """A link to a dataset's data, `label` its text; hidden from visitors
    not logged in (`body.anon`) when the dataset isn't public."""
    h.raw('<a class="data-link')
    if name in private:
        h.raw(" data-link--private")
    h.raw('" href="')
    h.text(data_href(name, snapshot))
    h.raw('" title="')
    h.text(name, "'s data")
    if snapshot:
        h.text(" at snapshot ", snapshot)
    h.raw('">')
    h.text(label)
    h.raw("</a>")


def datasets_with_data(mut h: Html, names: List[String], private: List[String]):
    """Each dataset linked to its page, then to its data."""
    for i in range(len(names)):
        if i:
            h.raw(", ")
        h.link(String("/datasets/", url_encode(names[i])), names[i])
        h.raw(" ")
        data_link(h, names[i], private)


def data_line(mut h: Html, names: List[String], private: List[String]):
    """`Data: a · b`, each name a link straight to that dataset's data:
    under a pipeline's name, the way to what it writes."""
    if len(names) == 0:
        return
    var all_private = True
    for n in names:
        all_private = all_private and n in private
    h.raw(
        '<div class="data-line',
        " data-link--private" if all_private else "",
        '">Data: ',
    )
    for i in range(len(names)):
        if i:
            h.raw('<span class="data-line__sep"> · </span>')
        data_link(h, names[i], private, label=names[i])
    h.raw("</div>")


def took_text(seconds: Int) -> String:
    """A duration as `42s`, `3m 07s` or `2h 05m`; empty for a negative one."""
    if seconds < 0:
        return String()
    if seconds < 60:
        return String(seconds, "s")
    if seconds < 3600:
        return String(seconds // 60, "m ", _two(seconds % 60), "s")
    return String(seconds // 3600, "h ", _two(seconds % 3600 // 60), "m")


def took_long(seconds: Int) -> String:
    """A duration as `42 s`, `3 min 21 s` or `2 h 5 min`."""
    if seconds < 60:
        return String(seconds, " s")
    if seconds < 3600:
        return String(seconds // 60, " min ", seconds % 60, " s")
    return String(seconds // 3600, " h ", seconds % 3600 // 60, " min")


def _two(n: Int) -> String:
    return String("0", n) if n < 10 else String(n)


def when_cell(mut h: Html, utc: String):
    """A `YYYY-MM-DDTHH:MM:SSZ` time as a table cell that the page's script
    shows as how long ago it was, the full local time on hover."""
    h.raw('<td class="mono"><time class="rel" datetime="')
    h.text(utc)
    h.raw('">')
    h.text(utc)
    h.raw("</time></td>")


comptime _SHOWN_PARTITIONS = 2
"""How many of a run's partitions its row in a table of runs names before
saying how many more there are."""


comptime _KEY_CHARS = 24
"""The most of one partition key a runs table shows; a longer key (a
keyed pipeline's `owner/repository`, say) ends in an ellipsis, whole in
the tooltip."""


def _key_text(key: StringSpan) -> String:
    """`key`, cut to `_KEY_CHARS` with an ellipsis if longer."""
    if key.count_codepoints() <= _KEY_CHARS:
        return String(key)
    var out = String()
    var k = 0
    for cp in key.codepoint_slices():
        if k == _KEY_CHARS - 1:
            break
        out.write(cp)
        k += 1
    out.write("…")
    return out^


def _partitions_cell(mut h: Html, partitions: String):
    """A run's partitions as a table cell: the first few, each cut to
    `_KEY_CHARS`, then `+N more`, with the whole list in the tooltip."""
    var parts = partitions.split(",")
    h.raw('<td class="mono parts" title="')
    h.text(partitions)
    h.raw('">')
    var shown = (
        len(parts) if len(parts) <= _SHOWN_PARTITIONS + 1 else _SHOWN_PARTITIONS
    )
    for i in range(shown):
        if i > 0:
            h.raw(", ")
        h.text(_key_text(parts[i]))
    if shown < len(parts):
        h.raw(
            ' <span class="muted">+',
            len(parts) - _SHOWN_PARTITIONS,
            " more</span>",
        )
    h.raw("</td>")


comptime _LISTED_PARTITIONS = 12
"""How many partitions a run's page lists in full; a longer list shows its
first and last and the count, the whole list folded under them."""


def partitions_fact(mut h: Html, partitions: String):
    """A run's partitions on its page: all of them if few, else
    `first … last (N partitions)` with the whole list in a fold."""
    var parts = partitions.split(",")
    if len(parts) <= _LISTED_PARTITIONS:
        h.text(partitions)
        return
    h.raw('<span class="mono">')
    h.text(parts[0])
    h.raw(" … ")
    h.text(parts[len(parts) - 1])
    h.raw('</span> <span class="muted">(', len(parts), " partitions)</span>")
    h.raw('<details class="all-parts"><summary>all ', len(parts), "</summary>")
    h.raw('<div class="mono">')
    for i in range(len(parts)):
        if i > 0:
            h.raw(", ")
        h.text(parts[i])
    h.raw("</div></details>")


def code_link(mut h: Html, at: CodeRef):
    """A link to a line of code: every one morca shows is drawn by this,
    so they all look alike and unlike morca's own links."""
    h.code(at.url, at.at, at.commit)


def step_cell(mut h: Html, name: String, links: CodeLinks, attempt: Int = -1):
    """A step's name, then a link to its function where the code is known.
    With `attempt` (0 for none yet), the name shows the step's card
    (`morca._internal.ui.step_cards`), and that attempt's on a run's page."""
    var at = links.step(name)
    h.raw("<td>")
    if attempt >= 0:
        h.raw('<span class="step-ref" data-step="')
        h.text(name)
        if attempt > 0:
            h.raw('" data-attempt="', String(attempt))
        h.raw('" tabindex="0">')
        h.text(name)
        h.raw("</span>")
    else:
        h.text(name)
    if at:
        h.raw(" ")
        code_link(h, at)
    h.raw("</td>")


def source_html(mut h: Html, v: VersionRow):
    """The commit, linked to its tree where the host is known."""
    if not v.commit:
        h.raw('<span class="muted">not recorded (built without')
        h.raw(
            " <code>-D MORCA_COMMIT</code> or <code>MORCA_COMMIT</code>)</span>"
        )
        return
    var url = commit_url(v.source, v.commit)
    var short = String(v.commit[byte = : min(12, v.commit.byte_length())])
    if url:
        h.code(url, short, v.commit)
    else:
        h.raw("<code>")
        h.text(short)
        h.raw("</code>")
    if v.dirty:
        h.raw(' <span class="muted">plus uncommitted changes</span>')
    if v.source:
        h.raw(' <span class="muted">of ')
        var web = web_url(v.source)
        if web:
            h.code(web, v.source, "")
        else:
            h.text(v.source)
        h.raw("</span>")


def pause_button(mut h: Html, name: String, paused: Bool):
    """Resume a paused pipeline, or pause an active one."""
    var base = String("/pipelines/", url_encode(name))
    if paused:
        act_button(
            h,
            String(base, "/unpause"),
            "Resume",
            "resume",
            String("morca unpause ", shell_quote(name)),
        )
    else:
        act_button(
            h,
            String(base, "/pause"),
            "Pause",
            "pause",
            String("morca pause ", shell_quote(name)),
        )


def cancel_tell(r: RunRow) -> String:
    """What cancelling `r` does, as its Cancel's dialog says it
    (`morca._internal.actions.cancel_run`)."""
    if r.status == "running":
        return String(
            "It stops before its next step; the step running now has ",
            Int(cancel_kill_seconds()),
            " s to finish before it's stopped. Steps that finished are kept.",
        )
    if r.status == "failed":
        return "It won't be retried; the steps that succeeded are kept."
    if r.status == "deferred":
        return "It won't be started again when its wait ends."
    return "It leaves the queue and won't start."


def row_actions(mut h: Html, r: RunRow):
    """A runs table row's Cancel (queued or running) or Resume (failed)."""
    if (r.status == "queued" or r.status == "running") and not (
        r.cancel_requested
    ):
        act_button(
            h,
            String("/runs/", r.id, "/cancel"),
            "Cancel",
            "cancel",
            cancel_cli(r),
            danger=True,
            ask=String("Cancel run ", r.id, "?"),
            tell=cancel_tell(r),
            yes="Cancel run",
            no="Keep it",
        )
    elif r.status == "failed" or r.stalled:
        act_button(
            h,
            String("/runs/", r.id, "/resume"),
            "Resume",
            "resume",
            resume_cli(r),
        )


comptime TRIES = (
    "Times the run's process was started: 1 is normal; more means retries,"
    " a lost instance or a resume."
)
"""What a runs table's Tries column counts (`orca.runs.starts`)."""


def runs_table_html(
    mut h: Html,
    runs: List[RunRow],
    show_pipeline: Bool,
    pick: Bool = False,
    code: Dict[Int, RunCode] = Dict[Int, RunCode](),
):
    """A table of runs; with `pick`, a checkbox before each, for the list's
    bulk actions (`form="bulk-runs"`, `morca._internal.ui.runs.runs_bulk_html`), and
    one in the header that ticks the page's (with JavaScript). With a run's
    `code`, its pipeline's name shows the pipeline's declaration on hover
    (`data-src`, the page's `_PEEK`) and a failed run names the step that
    failed, linked to its function, at the commit the run ran."""
    if len(runs) == 0:
        h.raw('<p class="empty">No runs.</p>')
        return
    runs_table_head(h, show_pipeline, pick)
    for r in runs:
        run_row_html(h, r, show_pipeline, pick, code.get(r.id))
    h.raw("</tbody></table></div>")


def runs_table_head(mut h: Html, show_pipeline: Bool, pick: Bool = False):
    """A table of runs' opening and header row (`runs_table_html`)."""
    h.raw('<div class="scroll"><table><thead><tr>')
    if pick:
        h.raw(
            '<th class="pick act__need"><input type="checkbox"',
            ' class="pick__all" form="bulk-runs" aria-label="Tick every run on',
            ' this page"></th>',
        )
    h.raw("<th>Run</th>")
    if show_pipeline:
        h.raw("<th>Pipeline</th>")
    h.raw(
        '<th>Created</th><th class="num">Took</th>',
        "<th>Partitions</th><th>Trigger</th><th>Status</th>",
        '<th class="num"><abbr title="',
        TRIES,
        '" aria-label="Tries: ',
        TRIES,
        '">Tries</abbr></th><th class="num"><abbr title="',
        _PEAK,
        '" aria-label="Peak memory: ',
        _PEAK,
        '">Peak</abbr></th></tr></thead><tbody>',
    )


def run_row_html(
    mut h: Html,
    r: RunRow,
    show_pipeline: Bool,
    pick: Bool = False,
    rc: Optional[RunCode] = None,
):
    """A run's row in a table of runs (`runs_table_html`)."""
    h.raw("<tr>")
    if pick:
        h.raw(
            '<td class="pick act__need"><input type="checkbox" name="pick"',
            ' form="bulk-runs" value="',
            r.id,
            '" aria-label="Tick run ',
            r.id,
            '"></td>',
        )
    h.raw("<td>")
    h.chip(String("/runs/", r.id), String(r.id))
    h.raw("</td>")
    if show_pipeline:
        h.raw('<td><a href="')
        h.text(String("/pipelines/", url_encode(r.pipeline)))
        h.raw('"')
        if rc and rc.value().pipeline:
            h.raw(' data-src="')
            h.text(rc.value().pipeline.url)
            h.raw('"')
        h.raw(">")
        h.text(r.pipeline)
        h.raw("</a></td>")
    when_cell(h, r.created)
    h.num(took_text(r.seconds))
    _partitions_cell(h, r.partitions)
    h.raw("<td>")
    h.term("trigger", r.trigger)
    h.raw("</td>")
    h.raw("<td>")
    h.status(r.status)
    if r.waiting_until:
        h.raw(' <span class="muted">until ')
        h.text(r.waiting_until)
        h.raw("</span>")
    if r.waits_on > 0 and r.held:
        # The run holding the concurrency key it waits on (#397).
        h.raw(' <span class="muted" title="')
        h.text(r.held)
        h.raw('">for run</span> ')
        h.chip(String("/runs/", r.waits_on), String(r.waits_on))
    if rc and rc.value().failed and r.status == "failed":
        h.raw(' <span class="muted">in</span> ')
        if rc.value().step:
            named_code_link(h, rc.value().failed, rc.value().step)
        else:
            h.raw('<span class="mono">')
            h.text(rc.value().failed)
            h.raw("</span>")
    row_actions(h, r)
    h.raw("</td>")
    # Empty for 0 and 1, so a run that took more draws the eye.
    if r.starts > 1:
        h.num(r.starts)
    else:
        h.raw('<td class="num"></td>')
    usage_cell(h, r.usage)
    h.raw("</tr>")


comptime _PEAK = (
    "The most memory the run's processes held at once, and in its title"
    " the CPU they used; empty where it wasn't measured."
)


def mb_text(mb: Int) -> String:
    """`512 MB`, `1.5 GB`."""
    return String(gb_text(mb), " GB") if mb >= 1024 else String(mb, " MB")


def usage_cell(
    mut h: Html,
    u: Usage,
    limit_mb: Int = 0,
    grant_mb: Int = 0,
    swap_bytes: Int = -1,
):
    """A `<td>` of a peak in memory, with the CPU in its title, and after
    it the attempt's memory limit (`morca._internal.cgroup`) when it had one,
    and what of it went to swap (`morca._internal.offload`) when any did."""
    if u.peak_rss_bytes < 0 and limit_mb <= 0:
        h.raw('<td class="num"></td>')
        return
    var title = usage_text(u) if u.peak_rss_bytes >= 0 else String()
    if limit_mb > 0:
        title.write("; " if title else "", "memory limit ", mb_text(limit_mb))
        if grant_mb > 0:
            title.write(", granted ", mb_text(grant_mb))
    if swap_bytes > 0:
        title.write("; up to ", bytes_text(swap_bytes), " in swap")
    h.raw('<td class="num" title="')
    h.text(title)
    h.raw('">')
    if u.peak_rss_bytes >= 0:
        h.text(bytes_text(u.peak_rss_bytes))
    if limit_mb > 0:
        h.raw('<span class="muted"> / ')
        h.text(mb_text(limit_mb))
        h.raw("</span>")
    if swap_bytes > 0:
        h.raw('<span class="muted"> + ')
        h.text(bytes_text(swap_bytes), " swap")
        h.raw("</span>")
    h.raw("</td>")


comptime PEAK_HELP = (
    "The most memory its processes held at once: the run's process and"
    " what it started (dista's local workers too), sampled every second by"
    " the scheduler or worker that started it, and at the end the largest"
    " single process. Not measured on EC2 or Kubernetes."
)


comptime CPU_HELP = (
    "The CPU time its processes used, user and system, and the most cores"
    " they kept busy over one sample's second. macOS gives only the time, and"
    " only for a process that made one attempt."
)


comptime _GRANT_HELP = (
    "What its pipeline asks for (cpus and memory_gb in morca.toml; for auto,"
    " what its runs suggest), and what"
    " its latest start was given of its host's CPUs and memory, fixed for"
    " that start, in MORCA_GRANT_CPUS and MORCA_GRANT_MEMORY_MB. Compare it"
    " with the peak below."
)


def request_text(cpus: String, memory_gb: String) -> String:
    """`1..16 CPUs, 2..24 GB`; `auto` as `CPUs auto`, `memory auto..24 GB`."""
    var text = String()
    if cpus.startswith("auto"):
        text.write("CPUs ", cpus)
    elif cpus:
        text.write(cpus, " CPU" if cpus == "1" else " CPUs")
    if memory_gb:
        if text:
            text.write(", ")
        if memory_gb == "auto":
            text.write("memory auto")
        elif memory_gb.startswith("auto"):
            text.write("memory ", memory_gb, " GB")
        else:
            text.write(memory_gb, " GB")
    return text^


comptime LIMIT_HELP = (
    "Its latest start's cgroup (morca.cgroup): past the limit (memory.high,"
    " its grant, request or MORCA_RUN_MEMORY_MB) the kernel slows its"
    " processes and reclaims their memory; past the kill line (memory.max,"
    " MORCA_RUN_MEMORY_MARGIN above) it kills them, and the retry asks for"
    " more. None where morca can't make cgroups."
)


def limit_facts(mut h: Html, limit_mb: Int, max_mb: Int, grant_mb: Int = 0):
    """A Memory limit fact (`morca._internal.cgroup`), when there was one."""
    if limit_mb <= 0:
        return
    fact_item(h, "Memory limit", "memory-limit", LIMIT_HELP, "runners")
    h.text(mb_text(limit_mb))
    if max_mb > 0:
        h.text(", killed past ", mb_text(max_mb))
    if grant_mb > 0:
        h.text(" (granted ", mb_text(grant_mb), ")")
    h.raw("</dd>")


comptime OFFLOAD_HELP = (
    "With MORCA_RUN_SWAP_PCT over 0, a run's cgroup may keep that percent of"
    " its limit in swap (memory.swap.max): past its limit its coldest pages"
    " go there, to zswap's compressed memory first where the host has it on,"
    " and it slows down rather than being held at its limit. The most of its"
    " memory in swap at once, and of that in zswap; a learned request counts"
    " it on top of the peak."
)


def offload_facts(mut h: Html, swap_bytes: Int, zswapped_bytes: Int):
    """An Offloaded fact (`morca._internal.offload`), when it was measured."""
    if swap_bytes < 0:
        return
    fact_item(h, "Offloaded", "offloaded", OFFLOAD_HELP, "runners")
    if swap_bytes == 0:
        h.raw('<span class="muted">nothing: it fit in its limit</span>')
    else:
        h.text(bytes_text(swap_bytes), " in swap at most")
        if zswapped_bytes >= 0:
            h.text(" (", bytes_text(zswapped_bytes), " of it in zswap)")
    h.raw("</dd>")


def grant_facts(mut h: Html, r: RunResources):
    """A run's Requested and Granted facts (`morca._internal.resources`), when its
    pipeline asked for any, and its memory limit (`morca._internal.cgroup`) when it
    had one."""
    if not r.any():
        if r.source:
            # `auto` with nothing learned: no request, as without one.
            fact_item(h, "Requested", "request", _GRANT_HELP, "runners")
            h.raw('<span class="muted">')
            h.text("none: ", r.source_text())
            h.raw("</span></dd>")
        limit_facts(h, r.limit_mb, r.max_mb)
        return
    fact_item(h, "Requested", "request", _GRANT_HELP, "runners")
    h.text(request_text(r.cpus, r.memory_gb))
    if r.source == "learned":
        h.raw(' <span class="muted">')
        h.text("· ", r.source_text())
        h.raw("</span>")
    h.raw("</dd>")
    fact_item(h, "Granted", "grant", _GRANT_HELP, "runners")
    var g = String()
    if r.grant.cpus > 0:
        g.write(r.grant.cpus, " CPU" if r.grant.cpus == 1 else " CPUs")
    if r.grant.memory_mb > 0:
        g.write(", " if g else "", gb_text(r.grant.memory_mb), " GB")
    if g:
        h.text(g)
    else:
        h.raw('<span class="muted">not yet: it hasn\'t started</span>')
    h.raw("</dd>")
    limit_facts(h, r.limit_mb, r.max_mb)


def usage_facts(mut h: Html, u: Usage, live: Bool):
    """A run's or an attempt's Peak memory and CPU used facts (`morca._internal.usage`).
    """
    var none = String(
        "recorded when its process ends" if live else "not measured"
    )
    fact_item(h, "Peak memory", "peak", PEAK_HELP, "runners")
    if u.peak_rss_bytes >= 0:
        h.text(bytes_text(u.peak_rss_bytes))
    else:
        h.raw('<span class="muted">', none, "</span>")
    h.raw("</dd>")
    fact_item(h, "CPU used", "cpu-used", CPU_HELP, "runners")
    if u.cpu_seconds >= 0:
        h.text(cpu_text(u.cpu_seconds))
        if u.peak_cpus >= 0:
            h.text(", up to ", fixed1(u.peak_cpus), " cores at once")
    else:
        h.raw('<span class="muted">', none, "</span>")
    h.raw("</dd>")


def named_code_link(mut h: Html, name: String, at: CodeRef):
    """A link to a function's code labelled with its name; where it is
    (`file.mojo:26`) is in its title, and in the source shown on hover."""
    h.code_named(at.url, name, at.at, at.commit)
