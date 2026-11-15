"""A run's machines on its page: each instance with its role, its
metrics' peaks and warnings (`morca._internal.metrics`), and the steps that ran on
it.
"""

import morca._internal.db.run_view as run_db

from morca._internal.control import CONTROL
from morca._internal.html import Html
from morca._internal.metrics import InstanceMetrics, metrics_html
from morca._internal.state import State
from morca._internal.timeline import workers_svg
from morca._internal.ui.layout import card_open
from morca._internal.views.runs import (
    RunRow,
    cluster_log_name,
    live_status,
    step_spans,
)
from morca._internal.db.run_view import InstanceRow


comptime _MACHINES_HELP = (
    "Samples of the whole machine, every few seconds while the run ran"
    " (MORCA_SAMPLE_SECONDS, 5 by default): its CPU, memory, fullest disk,"
    " disk io and network, by a sampler the runner starts beside the run's"
    " process. They count everything on that machine, not just this run."
    " What the run's own processes used is in Resources, above. The steps"
    " lane lines a busy stretch up with the step it came from. A run on a"
    " remote worker has none: the worker measures only its processes."
)


def _machines_of(
    mut db: State, r: RunRow, names: List[String]
) raises -> String:
    """What the Machines card is, for the runner that recorded its samples
    (each file's name): a heading's subtitle, and on the scheduler's own
    machine, how many other runs it shared it with."""
    var local = False
    var control = False
    var ec2 = False
    for n in names:
        if n == "local" or n == CONTROL:
            local = True
            control = control or n == CONTROL
        elif n.startswith("head-") or n.startswith("worker-"):
            ec2 = True
    if local:
        var host = String(
            "the control host, which also runs Postgres, the scheduler and the UI" if control else "the scheduler's machine (the local runner)"
        )
        # Runs on the same machine at the same time: the scheduler's own
        # (local and control-placed) that overlapped this one.
        var n = run_db.shared_runs(db.conn, r.id)
        var out = String(
            "The whole machine, while this run ran: ",
            host,
            ". Not this run's own use; that is in Resources.",
        )
        if n > 0:
            out.write(
                '</p><p class="card__warn">A shared machine: ',
                n,
                " other run" if n == 1 else " other runs",
                " ran on it at the same time, so these numbers are theirs",
                " too.",
            )
        return out^
    if ec2:
        return String(
            "This run's EC2 instances, its head and workers, each a whole"
            " machine of its own while the run ran. What its processes used"
            " is in Resources."
        )
    return String(
        "This run's Kubernetes pods. CPU, memory and disk io are the whole"
        " node's, which other pods share; network is the pod's own."
    )


def machines_html(
    mut h: Html, mut db: State, r: RunRow, metrics: List[InstanceMetrics]
) raises:
    """The Machines card (`morca._internal.metrics`), saying what its numbers are:
    nothing for a run without samples."""
    if len(metrics) == 0:
        return
    var names = List[String]()
    for m in metrics:
        names.append(m.name)
    card_open(h, "machines", "Machines", _MACHINES_HELP, "metrics", facts=False)
    h.raw('<p class="card__sub">', _machines_of(db, r, names), "</p>")
    metrics_html(h, metrics, step_spans(db, r.id), live_status(r.status))
    h.raw("</section>")


def instances_html(mut h: Html, run: Int, xs: List[InstanceRow]):
    var changes = List[Tuple[Float64, Int]]()
    var total = Float64(0)
    for i in xs:
        if i.role == "worker":
            changes.append((i.from_start, 1))
            changes.append((i.to_end, -1))
        total = max(total, i.to_end)
    # In time order, a start before an end at the same moment.
    for a in range(1, len(changes)):
        var b = a
        while b > 0 and (
            changes[b - 1][0] > changes[b][0]
            or (
                changes[b - 1][0] == changes[b][0]
                and changes[b - 1][1] < changes[b][1]
            )
        ):
            var t = changes[b - 1]
            changes[b - 1] = changes[b]
            changes[b] = t
            b -= 1
    card_open(
        h,
        "instances",
        "Instances",
        (
            "The EC2 instances started for this run: each one's role, type,"
            " when it was asked for, launched and ended, and why; the chart"
            " is how many workers were up over time."
        ),
        "scheduler",
        facts=False,
    )
    if len(changes) > 0:
        h.raw('<div class="scroll">', workers_svg(changes, total), "</div>")
    h.raw(
        '<div class="scroll"><table><thead><tr><th>Role</th><th>Instance</th>',
        "<th>Type</th><th>Start</th><th>Launched</th><th>Ended</th>",
        "<th>Why</th><th>Log</th></tr></thead><tbody>",
    )
    for i in xs:
        h.raw("<tr>")
        h.raw("<td>")
        h.term("role", i.role)
        h.raw("</td>")
        h.raw("<td><code>")
        h.text(i.id)
        h.raw("</code></td>")
        h.cell(
            i.instance_type,
            " Spot" if i.market == "spot" else String(""),
            String(" x", i.procs, " workers") if i.procs > 1 else String(""),
        )
        h.cell(i.start)
        h.cell(i.launched)
        if i.ended:
            h.cell(i.ended)
        else:
            h.raw(
                '<td><span class="status status--running">running</span></td>'
            )
        h.cell(i.why)
        h.raw("<td>")
        h.link(String("/runs/", run, "/cluster/", cluster_log_name(i)), "log")
        h.raw("</td></tr>")
    h.raw("</tbody></table></div></section>")
