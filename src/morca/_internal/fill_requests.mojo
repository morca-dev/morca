"""Fill requests (#465): `morca backfill --as-fill` records keys for the
scheduler to run as fill runs, rather than queueing a run for each:

    morca backfill --rerun --as-fill mojo_repos 2023-01-01..2026-11-13

The scheduler's fill pass (`morca._internal.fill.fill_status`) takes the
request's keys before the fill's range, within the same limits: up to
`keys_per_run` keys a run, in `fill_order`, at most `fill_max_runs` fill
runs going, inside `fill_window` and `fill_budget_per_day`, only while none
of the pipeline's other runs are queued, and after the pipelines of higher
priority. It does so whether `fills` is `all` or not. A request's runs are
fill runs (trigger `fill`) with `orca.runs.fill_request` set.

A pipeline has one open request at most (`orca.fill_requests`, ended
NULL): a second request adds the keys it hasn't to it, and one that
differs in `--rerun` is refused. The request is in the database, so it
survives the scheduler's restarts and an overlapping deploy: only the
leading scheduler runs the fill pass, under the pipeline's row lock.

**What a request takes.** A key is taken once a run of the request was
queued for it, so the request runs each key once. A key in another live
run waits for it to end. Without `--rerun`, a key done in a run of any
code of the pipeline (`morca._internal.db.fill.done_any_code`) is
skipped. A key whose run failed past its retries, or was cancelled, is
left to a person, as a fill's is. The request ends once every key is done,
failed or skipped, with nothing going; `morca backfill --cancel` ends it
early and cancels its runs.
"""

from postgres import Transaction

import morca._internal.db.fill_requests as requests_db
from morca._internal.json import quote


struct RequestProgress(Copyable, Movable):
    """Where a pipeline's open fill request is."""

    var id: Int64
    var spec: String
    var rerun: Bool
    var created: String
    var requested_by: String
    var total: Int
    var done: Int
    """Keys whose run of the request succeeded."""
    var skipped: Int
    """Without `--rerun`, keys done before their turn came."""
    var running: Int
    """Keys in a run of the request that is queued or running."""
    var waiting: Int
    """Keys not yet taken that another live run has."""
    var failed: Int
    """Keys whose run failed past its retries, or was cancelled."""
    var retrying: Int
    """Keys whose run failed and waits for a retry."""
    var todo: List[String]
    """The keys no run of the request has taken yet, ascending: those
    waiting left out."""
    var next: String
    """The keys of its next run, comma-separated (`fill_status` sets it),
    or empty."""

    def __init__(out self):
        self.id = 0
        self.spec = String()
        self.rerun = True
        self.created = String()
        self.requested_by = String()
        self.total = 0
        self.done = 0
        self.skipped = 0
        self.running = 0
        self.waiting = 0
        self.failed = 0
        self.retrying = 0
        self.todo = List[String]()
        self.next = String()

    def left(self) -> Int:
        """Keys still to take: those waiting for another run too."""
        return len(self.todo) + self.waiting

    def finished(self) -> Bool:
        """Every key ran, failed for good or was skipped, nothing going."""
        return self.left() == 0 and self.running == 0 and self.retrying == 0

    def text(self) -> String:
        """`fill request 3 (2023-01..2026-10, rerun): 12 of 46 done, 1
        running, 33 left`."""
        var out = String(
            "fill request ",
            self.id,
            " (",
            self.spec,
            ", rerun" if self.rerun else "",
            "): ",
            self.done,
            " of ",
            self.total,
            " done",
        )
        if self.skipped:
            out.write(", ", self.skipped, " already done")
        if self.running:
            out.write(", ", self.running, " running")
        if self.retrying:
            out.write(", ", self.retrying, " retrying")
        if self.failed:
            out.write(", ", self.failed, " failed")
        out.write(", ", self.left(), " left")
        if self.waiting:
            out.write(" (", self.waiting, " in other live runs)")
        if self.next:
            out.write("; next: ", self.next)
        return out^


def request_progress(
    mut tx: Transaction,
    pipeline: String,
    run_retries: Int,
    live: Dict[String, Int],
    done: Dict[String, Bool],
) raises -> Optional[RequestProgress]:
    """`pipeline`'s open fill request and where it is, None if it has
    none; `live` is the keys in its live runs, `done` those done in a run
    of any of its code."""
    var row = requests_db.open_request(tx, pipeline)
    if not row:
        return None
    ref r = row.value()
    var s = RequestProgress()
    s.id = r.id
    s.spec = r.spec
    s.rerun = r.rerun
    s.created = r.created
    s.requested_by = r.requested_by
    var taken = Dict[String, Int]()
    var states = requests_db.request_keys(tx, r.id, run_retries)
    for i in range(len(states)):
        taken[states[i].key] = i
    for k in r.keys.split(","):
        var key = String(k)
        if not key:
            continue
        s.total += 1
        var at = taken.get(key)
        if at:
            ref st = states[at.value()]
            if st.done:
                s.done += 1
            elif st.live:
                s.running += 1
            elif st.gone:
                s.failed += 1
            elif st.again:
                s.retrying += 1
            else:
                s.failed += 1
        elif not s.rerun and key in done:
            s.skipped += 1
        elif key in live:
            s.waiting += 1
        else:
            s.todo.append(key^)
    return s^


def end_finished(
    mut tx: Transaction, request: Optional[RequestProgress]
) raises:
    """Ends `request` once it has `finished`, so the pipeline's fill pass
    no longer looks at it and a new request opens a new one."""
    if request and request.value().finished():
        requests_db.end_request(tx, request.value().id)
        print(
            "fill request", request.value().id, "ended:", request.value().text()
        )


def request_json(s: RequestProgress) -> String:
    """The request as `/api/pipelines/<name>`'s `fill.request` gives it."""
    var out = String('{"id": ', s.id, ', "spec": ', quote(s.spec))
    out.write(
        ', "rerun": ',
        "true" if s.rerun else "false",
        ', "created": ',
        quote(s.created),
        ', "requested_by": ',
        quote(s.requested_by),
        ', "total": ',
        s.total,
        ', "done": ',
        s.done,
        ', "skipped": ',
        s.skipped,
        ', "running": ',
        s.running,
        ', "retrying": ',
        s.retrying,
        ', "failed": ',
        s.failed,
        ', "waiting": ',
        s.waiting,
        ', "left": ',
        s.left(),
        ', "next": ',
        quote(s.next) if s.next else String("null"),
        "}",
    )
    return out^
