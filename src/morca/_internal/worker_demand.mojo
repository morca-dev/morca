"""Demand per group on pools (docs/groups.md), the worker's side: the
worker that runs a run's dista head asks it for its status every
`MORCA_SCALE_REPORT_SECONDS` (5) and sends the answers with its next claim
(`morca._internal.run_demand` keeps and decides on them). The scheduler
can't always reach the head, and this worker can: it's at
`127.0.0.1:<port>` here.

The status is the pipeline's binary's `dista-status <head>` (dista's
sockets can't share morca's binary), run with the run's environment, which
holds its cluster token, and given `STATUS_SECONDS` at most. A failure (a
head not up yet, or gone) is skipped: the scheduler keeps what it decided
last.
"""

from std.os import getenv

from morca._internal.http_store import Body
from morca._internal.proc import capture

comptime STATUS_SECONDS = 3.0
"""The most a head's status may take before it's skipped."""


def report_seconds() -> Float64:
    """`MORCA_SCALE_REPORT_SECONDS` (5): how often the head's status is
    sent; 0 or less sends none."""
    try:
        return Float64(getenv("MORCA_SCALE_REPORT_SECONDS", "5"))
    except:
        return 5.0


def env_value(env: List[String], name: String) -> String:
    """`name`'s value in `env`'s `NAME=value`s; empty if it has none."""
    var prefix = String(name, "=")
    for e in env:
        if e.startswith(prefix):
            return String(e[byte = prefix.byte_length() :])
    return String()


def head_status(binary: String, env: List[String]) -> Optional[String]:
    """The status of the head a run's `env` names (`DISTA_HEAD`, with its
    `DISTA_TOKEN`), through its `binary`; None if it has none or doesn't
    answer."""
    var head = env_value(env, "DISTA_HEAD")
    if not head:
        return None
    try:
        var got = capture(
            [binary, "dista-status", head], STATUS_SECONDS, env=env
        )
        if got[0] != 0 or not got[1].startswith("{"):
            return None
        return got[1]
    except:
        return None


struct DemandReports(Movable):
    """When the heads' statuses were last asked for, and the answers to
    send with the next claim."""

    var every: Float64
    var last: Float64
    """When they were last asked for, in seconds (monotonic); 0 never."""
    var answers: List[Tuple[Int, Int, String]]
    """Run, start and status, not sent yet."""

    def __init__(out self):
        self.every = report_seconds()
        self.last = 0
        self.answers = List[Tuple[Int, Int, String]]()

    def due(mut self, now: Float64) -> Bool:
        """Whether to ask now; if so, from now on it isn't for `every`, and
        answers no claim took are dropped for the new ones."""
        if self.every <= 0 or (self.last > 0 and now - self.last < self.every):
            return False
        self.last = now
        self.answers.clear()
        return True

    def add(mut self, run: Int, start: Int, status: String):
        self.answers.append((run, start, status))

    def json(self) -> String:
        """The claim's `demand`: `[{"run": 7, "start": 1, "status": "..."}]`,
        the status as a string so a bad one can't spoil the claim."""
        var out = String("[")
        for i in range(len(self.answers)):
            ref a = self.answers[i]
            out.write(
                ", " if i else "",
                Body()
                .int("run", Int64(a[0]))
                .int("start", Int64(a[1]))
                .text("status", a[2])
                .finish(),
            )
        out.write("]")
        return out^

    def sent(mut self):
        """The answers went with a claim."""
        self.answers.clear()
