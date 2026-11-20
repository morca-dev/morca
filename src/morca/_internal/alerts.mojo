"""What the scheduler raises alerts about (`morca._internal.notify`, #184), each decided
where the data is and sent through `morca._internal.notify.alert`:

| Kind | Subject | Priority | When |
|---|---|---|---|
| `watchdog` | the rule | high | a rule tripped (sent from `morca._internal.watchdog.trip`); resolved, low, when no unacknowledged trip of it has a pipeline still paused |
| `run-failed` | run and start | default | a run failed with no retry left (`failed_runs`), once per run |
| `fill-stalled` | the pipeline | high | `fill`: no fill run finished in `MORCA_NOTIFY_FILL_STALL_HOURS` (2) while the pipeline is unpaused, inside its window and not done; resolved when one finishes |
| `disk` | the mount | high | `disk`: the control host's fullest disk is over `MORCA_NOTIFY_DISK_PERCENT` (85); resolved when it isn't |
| `worker-lost` | worker and last seen | default | `lost_workers`: a worker that last said it was running runs, quiet for `MORCA_NOTIFY_WORKER_SECONDS` (300), once per loss |
| `backup-failed` | `nightly` | high | `morca notify --kind backup-failed ...`, from morca-stack's backup |

The text is plain and short: names, numbers and the first line of an error,
never a secret.
"""

from std.os import getenv

import morca._internal.db.notify as notify_db

from morca._internal.fill import FillStatus
from morca._internal.notify import (
    alert,
    configured,
    firing_subjects,
    resolve,
    ui_link,
)
from morca._internal.state import State
from morca._internal.system import system_now
from morca._internal.watchdog import active_trips


def _first_line(text: String, limit: Int = 200) -> String:
    var line = String(text.strip())
    var nl = line.find("\n").or_else(-1)
    if nl >= 0:
        var first = String(line[byte=:nl])
        line = first^
    if line.byte_length() > limit:
        var cut = String(line[byte=:limit], "...")
        line = cut^
    return line^


def _hours(name: String, default: Float64) -> Float64:
    var v = getenv(name)
    if not v:
        return default
    try:
        return Float64(v)
    except:
        return default


def _duration(seconds: Int) -> String:
    if seconds < 90:
        return String(seconds, " s")
    if seconds < 5400:
        return String(seconds // 60, " min")
    if seconds < 172800:
        return String(seconds // 3600, " h")
    return String(seconds // 86400, " days")


# ---------------------------------------------------------------------------
# The watchdog
# ---------------------------------------------------------------------------


def watchdog_recovered(mut db: State) raises:
    """Resolves the watchdog alerts whose trips were acknowledged or whose
    pipelines were unpaused."""
    var firing = firing_subjects(db, "watchdog")
    if len(firing) == 0:
        return
    var active = active_trips(db)
    for rule in firing:
        var live = False
        for t in active:
            if t.rule == rule:
                live = True
        if not live:
            resolve(
                db,
                "watchdog",
                rule,
                String("morca watchdog: ", rule, " resolved"),
                "Acknowledged, or its pipelines are unpaused.",
                ui_link("/ops/control"),
            )


# ---------------------------------------------------------------------------
# Runs
# ---------------------------------------------------------------------------


def failed_runs(
    mut db: State, pipeline: String, run_retries: Int, retried_sql: String
) raises -> Int:
    """Alerts for `pipeline`'s runs that failed in the last hour with no retry
    left: past `run_retries` starts, or of a trigger the scheduler doesn't
    retry (`retried_sql`), or not started for their code. Once per run and
    start. Returns how many were raised."""
    if not configured():
        return 0
    var n = 0
    for r in notify_db.failed_unretried(
        db.conn, pipeline, run_retries, retried_sql
    ):
        var id = r.id
        var subject = String(id, "/", r.starts)
        if _known(db, "run-failed", subject):
            continue
        var keys = r.partitions
        if keys.byte_length() > 80:
            var cut = String(keys[byte=:80], "...")
            keys = cut^
        var why = _first_line(r.error)
        if alert(
            db,
            "run-failed",
            subject,
            "default",
            "x",
            String("morca: ", pipeline, " run ", id, " failed"),
            String(
                pipeline,
                " ",
                keys,
                "\n",
                why if why else String("failed; see the run"),
            ),
            ui_link(String("/runs/", id)),
            pipelines=pipeline,
            run=Int(id),
        ):
            n += 1
    return n


def _known(mut db: State, kind: String, subject: String) raises -> Bool:
    return notify_db.is_known(db.conn, kind, subject)


# ---------------------------------------------------------------------------
# Fills
# ---------------------------------------------------------------------------


def fill(
    mut db: State,
    pipeline: String,
    s: FillStatus,
    paused: Bool,
    in_window: Bool,
) raises:
    """Raises 'fill stalled' when no fill run of `pipeline` finished in
    `MORCA_NOTIFY_FILL_STALL_HOURS` (2) although it is unpaused, inside its
    window and not done; resolves it once one finishes."""
    if not configured() or not s.on:
        return
    var limit = Int(_hours("MORCA_NOTIFY_FILL_STALL_HOURS", 2.0) * 3600.0)
    # Since the last fill run that succeeded; else the first fill run, else
    # when the pipeline was first registered.
    var got = notify_db.fill_success_age(db.conn, pipeline)
    if not got:
        return
    var ago = got.value()[0]
    var ever = got.value()[1]
    var unfinished = s.done < s.total and (
        s.left + s.retrying + s.live + s.running > 0
    )
    if not unfinished or ago < limit:
        resolve(
            db,
            "fill-stalled",
            pipeline,
            String("morca: fill of ", pipeline, " is moving again"),
            String(s.done, " of ", s.total, " partitions done."),
            ui_link(String("/pipelines/", pipeline)),
        )
        return
    if paused or not in_window:
        return
    _ = alert(
        db,
        "fill-stalled",
        pipeline,
        "high",
        "warning,hourglass",
        String("morca: fill of ", pipeline, " stalled"),
        String(
            s.done,
            " of ",
            s.total,
            " partitions done; ",
            String("last success ", _duration(ago), " ago") if ever else (
                String("no fill run has succeeded in ", _duration(ago))
            ),
            ".",
            String("\n", s.idle) if s.idle else String(),
        ),
        ui_link(String("/pipelines/", pipeline)),
        pipelines=pipeline,
    )


# ---------------------------------------------------------------------------
# The control host
# ---------------------------------------------------------------------------


def disk(mut db: State) raises:
    """Raises 'disk' when the control host's fullest disk, from the /system
    sampler, is over `MORCA_NOTIFY_DISK_PERCENT` (85); resolves it when not."""
    if not configured():
        return
    var now = system_now(db)
    if not now or now.value().stale():
        return
    ref n = now.value()
    var limit = _hours("MORCA_NOTIFY_DISK_PERCENT", 85.0)
    if n.disk_pct > limit:
        var gb = n.disk_total // 1000000000
        _ = alert(
            db,
            "disk",
            n.disk_path,
            "high",
            "warning,floppy_disk",
            "morca: control disk filling",
            String(
                n.disk_path,
                " is ",
                Int(n.disk_pct + 0.5),
                "% full (",
                n.disk_used // 1000000000,
                " of ",
                gb,
                " GB), over ",
                Int(limit + 0.5),
                "%.",
            ),
            ui_link("/ops/control"),
        )
        return
    for mount in firing_subjects(db, "disk"):
        resolve(
            db,
            "disk",
            mount,
            "morca: control disk is fine again",
            String(mount, " is ", Int(n.disk_pct + 0.5), "% full."),
            ui_link("/ops/control"),
        )


# ---------------------------------------------------------------------------
# Workers
# ---------------------------------------------------------------------------


def lost_workers(mut db: State) raises -> Int:
    """Alerts for the workers (`orca.workers`) that last said they were
    running runs and haven't been heard from for `MORCA_NOTIFY_WORKER_SECONDS`
    (300), once per loss. Their runs are requeued when their heartbeats go
    stale (`morca._internal.scheduler`). Returns how many were raised."""
    if not configured():
        return 0
    var quiet = _hours("MORCA_NOTIFY_WORKER_SECONDS", 300.0)
    var n = 0
    for r in notify_db.quiet_workers(db.conn, quiet):
        var subject = String(r.id, "/", r.seen)
        if _known(db, "worker-lost", subject):
            continue
        var runs = r.running
        var count = len(runs.split(","))
        var host = r.name
        if alert(
            db,
            "worker-lost",
            subject,
            "default",
            "warning",
            String("morca: worker ", r.label, " lost"),
            String(
                "Pool ",
                r.pool,
                ", worker ",
                r.label,
                String(" (", host, ")") if host else String(),
                " has been quiet for ",
                _duration(r.ago),
                " while holding ",
                count,
                " run" if count == 1 else " runs",
                " (",
                runs,
                "); they are requeued when their heartbeats go stale.",
            ),
            ui_link(String("/ops/pools/self-hosted/", r.id)),
        ):
            n += 1
    return n
