"""The Cluster card on a run's page (#268): the workers its dista cluster
spread over (`morca._internal.views.cluster`)."""

from morca._internal.html import Html
from morca._internal.json import quote
from morca._internal.ui.layout import card_open
from morca._internal.db.run_view import ClusterRow

comptime _HELP = (
    "This run's dista cluster spread over several workers of its pool"
    " (workers = N on a pipeline placed worker:<pool>). The head is the"
    " worker that started the run, with its dista head at the address shown;"
    " each member is a worker that joined it, running dista workers against"
    " that head with what its own machine granted. A member ends with its"
    " run, or when its process does."
)


def cluster_html(mut h: Html, rows: List[ClusterRow]):
    """The Cluster card; nothing for a run on one machine."""
    if len(rows) == 0:
        return
    card_open(h, "cluster", "Cluster", _HELP, "workers", facts=False)
    h.raw(
        '<div class="scroll"><table><thead><tr><th>Role</th><th>Worker</th>',
        "<th>Start</th><th>Address</th><th>Grant</th><th>Joined</th>",
        "<th>Ended</th><th>Why</th></tr></thead><tbody>",
    )
    for r in rows:
        h.raw("<tr><td>")
        h.text(r.role)
        h.raw("</td><td><code>")
        h.text(r.worker if r.worker else String("-"))
        h.raw("</code></td><td>")
        h.text(String(r.start))
        h.raw("</td><td><code>")
        h.text(r.address if r.address else String("-"))
        h.raw("</code></td><td>")
        if r.grant_cpus or r.grant_memory_mb:
            h.text(String(r.grant_cpus, " CPUs, ", r.grant_memory_mb, " MB"))
        else:
            h.text("-")
        h.raw("</td><td>")
        h.text(r.joined)
        h.raw("</td><td>")
        h.text(r.ended if r.ended else String("-"))
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
            ', "address": ',
            quote(r.address) if r.address else String("null"),
            ', "grant": {"cpus": ',
            String(r.grant_cpus) if r.grant_cpus else String("null"),
            ', "memory_mb": ',
            String(r.grant_memory_mb) if r.grant_memory_mb else String("null"),
            '}, "joined": ',
            quote(r.joined),
            ', "ended": ',
            quote(r.ended) if r.ended else String("null"),
            ', "why": ',
            quote(r.why) if r.why else String("null"),
            "}",
        )
    out.write("]")
    return out^
