"""The Cluster card on a run's page (#268): the workers its dista cluster
spread over (`morca._internal.views.cluster`)."""

from morca._internal.html import Html
from morca._internal.json import quote
from morca._internal.resources import gpus_text
from morca._internal.ui.layout import card_open
from morca._internal.db.run_view import ClusterRow
from morca._internal.member_wants import Kind
from morca._internal.views.cluster import ClusterWants

comptime _HELP = (
    "This run's dista cluster spread over several workers of its pool"
    " (workers = N on a pipeline placed worker:<pool>). The head is the"
    " worker that started the run, with its dista head at the address shown;"
    " each member is a worker that joined it, running dista workers against"
    " that head with what its own machine granted. A member of a worker"
    " group runs only that group's tasks, and its grant may hold GPUs. A"
    " member ends with its run, or when its process does. Wanted is how many"
    " members of each kind the run wants now: its MIN until its head reports"
    " demand (its MAX if the head's worker doesn't report any), then what"
    " morca decided from it, within the range (workers ="
    ' "MIN..MAX"). A kind with more live members than it wants gets no new'
    " ones."
)


def range_text(k: Kind) -> String:
    """A kind's range: `2`, or `0..4`."""
    if k.min_workers == k.max_workers:
        return String(k.max_workers)
    return String(k.min_workers, "..", k.max_workers)


def _wants_html(mut h: Html, w: ClusterWants):
    """The members of each kind the run wants and has."""
    if len(w.kinds) == 0:
        return
    h.raw('<p class="muted">')
    if w.demand_at:
        h.text(String("Demand from its head at ", w.demand_at, "."))
    else:
        h.text(
            "No demand from its head yet: each kind wants its MIN, or its MAX"
            " when the head's worker doesn't report demand."
        )
    h.raw("</p>")
    h.raw(
        '<div class="scroll"><table><thead><tr><th>Group</th><th>Range</th>',
        "<th>Live</th><th>Wanted</th></tr></thead><tbody>",
    )
    for k in w.kinds:
        h.raw("<tr><td>")
        if k.group:
            h.raw("<code>")
            h.text(k.group)
            h.raw("</code>")
        else:
            h.text("-")
        h.raw("</td><td>")
        h.text(range_text(k))
        h.raw("</td><td>")
        h.text(String(k.live))
        h.raw("</td><td>")
        h.text(String(k.wanted))
        if not k.decided and k.min_workers != k.max_workers:
            h.text(" (MIN)" if k.wanted == k.min_workers else " (MAX)")
        h.raw("</td></tr>")
    h.raw("</tbody></table></div>")


def grant_text(r: ClusterRow) -> String:
    """A row's grant: "2 CPUs, 4096 MB, 1 GPU", what it holds; "-" for
    nothing."""
    var parts = List[String]()
    if r.grant_cpus or r.grant_memory_mb:
        parts.append(String(r.grant_cpus, " CPUs, ", r.grant_memory_mb, " MB"))
    if r.grant_gpus:
        parts.append(gpus_text(r.grant_gpus))
    if len(parts) == 0:
        return "-"
    return ", ".join(parts)


def cluster_html(mut h: Html, rows: List[ClusterRow], wants: ClusterWants):
    """The Cluster card; nothing for a run on one machine."""
    if len(rows) == 0:
        return
    card_open(h, "cluster", "Cluster", _HELP, "workers", facts=False)
    _wants_html(h, wants)
    h.raw(
        '<div class="scroll"><table><thead><tr><th>Role</th><th>Worker</th>',
        "<th>Group</th><th>Start</th><th>Address</th><th>Grant</th>",
        "<th>Joined</th>",
        "<th>Ended</th><th>Why</th></tr></thead><tbody>",
    )
    for r in rows:
        h.raw("<tr><td>")
        h.text(r.role)
        h.raw("</td><td><code>")
        h.text(r.worker if r.worker else String("-"))
        h.raw("</code></td><td>")
        if r.group:
            h.raw("<code>")
            h.text(r.group)
            h.raw("</code>")
        else:
            h.text("-")
        h.raw("</td><td>")
        h.text(String(r.start))
        h.raw("</td><td><code>")
        h.text(r.address if r.address else String("-"))
        h.raw("</code></td><td>")
        h.text(grant_text(r))
        h.raw("</td><td>")
        h.text(r.joined)
        h.raw("</td><td>")
        if r.ended:
            h.text(r.ended)
        elif r.draining:
            h.text(String("draining since ", r.draining))
        else:
            h.text("-")
        h.raw("</td><td>")
        h.text(r.why)
        h.raw("</td></tr>")
    h.raw("</tbody></table></div></section>")


def cluster_json(rows: List[ClusterRow]) -> String:
    """The run's cluster as JSON: a list, empty for one machine."""
    var out = String("[")
    for i in range(len(rows)):
        ref r = rows[i]
        out.write(
            ", " if i else "",
            '{"role": ',
            quote(r.role),
            ', "start": ',
            r.start,
            ', "worker": ',
            quote(r.worker),
            ', "group": ',
            quote(r.group) if r.group else String("null"),
            ', "address": ',
            quote(r.address) if r.address else String("null"),
            ', "grant": {"cpus": ',
            String(r.grant_cpus) if r.grant_cpus else String("null"),
            ', "memory_mb": ',
            String(r.grant_memory_mb) if r.grant_memory_mb else String("null"),
            ', "gpus": ',
            String(r.grant_gpus) if r.grant_gpus else String("null"),
            '}, "joined": ',
            quote(r.joined),
            ', "draining": ',
            quote(r.draining) if r.draining else String("null"),
            ', "ended": ',
            quote(r.ended) if r.ended else String("null"),
            ', "why": ',
            quote(r.why) if r.why else String("null"),
            "}",
        )
    out.write("]")
    return out^


def cluster_wants_json(w: ClusterWants) -> String:
    """The members of each kind the run wants and has, as JSON: a list,
    empty for a run without a head. `group` is null for the workers with no
    group; `decided` says whether `wanted` came from its head's demand."""
    var out = String("[")
    for i in range(len(w.kinds)):
        ref k = w.kinds[i]
        out.write(
            ", " if i else "",
            '{"group": ',
            quote(k.group) if k.group else String("null"),
            ', "min": ',
            k.min_workers,
            ', "max": ',
            k.max_workers,
            ', "live": ',
            k.live,
            ', "wanted": ',
            k.wanted,
            ', "decided": ',
            "true" if k.decided else "false",
            ', "demand_at": ',
            quote(w.demand_at) if w.demand_at else String("null"),
            "}",
        )
    out.write("]")
    return out^
