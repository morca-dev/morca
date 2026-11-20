"""What the step cards show (`morca._internal.ui.step_cards`): each step's card,
with what its attempts in the pipeline's latest runs did, and on a run's
page each attempt's.
"""

import morca._internal.db.pipelines_view as pipelines_db
import morca._internal.db.run_view as run_db

from morca._internal.sample import fixed1
from morca._internal.state import State
from morca._internal.db.run_rows import Usage
from morca._internal.ui.step_cards import AttemptCard, StepCard, duration_text
from morca._internal.ui.terms import value_help
from morca._internal.usage import bytes_text, cpu_text
from morca._internal.views.code import CodeLinks
from morca._internal.db.pipelines_view import StepDef


comptime STEP_RUNS = 20
"""How many of a pipeline's latest runs a step's card summarizes."""


def step_cards_of(
    mut db: State,
    pipeline: String,
    defs: List[StepDef],
    links: CodeLinks,
    recent: Bool,
) raises -> List[StepCard]:
    """Each step's card (`morca._internal.ui.step_cards`); with `recent`, what its
    attempts in the pipeline's latest `STEP_RUNS` runs did: how many failed,
    the p50 and most its succeeded ones took, and its peak memory's."""
    var out = List[StepCard]()
    for d in defs:
        var at = links.step(d.name)
        out.append(
            StepCard(
                d.name,
                d.kind,
                String(value_help("kind", d.kind)),
                d.after,
                d.function,
                d.input,
                d.output,
                d.reads.copy(),
                d.writes.copy(),
                at.url,
                at.at,
                at.commit,
                0,
                0,
                0,
                "",
                "",
            )
        )
    if not recent:
        return out^
    for r in pipelines_db.step_stats(db.conn, pipeline, STEP_RUNS):
        var name = r.step
        for ref c in out:
            if c.name != name:
                continue
            c.recent_runs = r.runs
            c.recent_attempts = r.attempts
            c.recent_failed = r.failed
            var t50 = r.took_p50
            var tmax = r.took_max
            if tmax >= 0:
                c.took = String(
                    "p50 ", duration_text(t50), " · max ", duration_text(tmax)
                )
            var p50 = r.peak_p50
            var pmax = r.peak_max
            if pmax >= 0:
                c.peak = String(
                    "p50 ",
                    bytes_text(Int(p50)),
                    " · max ",
                    bytes_text(Int(pmax)),
                )
    return out^


def attempt_cards(mut db: State, run: Int) raises -> List[AttemptCard]:
    """What each of a run's attempts adds to its step's card."""
    var out = List[AttemptCard]()
    for r in run_db.attempt_card_records(db.conn, run):
        var u = Usage(r.peak, r.cpu, r.cpus)
        var id = r.id
        var status = r.status
        out.append(
            AttemptCard(
                id,
                r.step,
                r.partition,
                r.attempt,
                status,
                String(value_help("status", status)),
                r.started,
                r.ended,
                duration_text(r.took),
                bytes_text(u.peak_rss_bytes) if u.peak_rss_bytes >= 0 else "",
                cpu_text(u.cpu_seconds) if u.cpu_seconds >= 0 else "",
                fixed1(u.peak_cpus) if u.peak_cpus >= 0 else "",
                r.error,
                String("/runs/", run, "/attempts/", id),
            )
        )
    return out^
