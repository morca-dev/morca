"""The actions: each a `POST` of a form (or of JSON, from `morca --remote`)
that changes something, through `morca._internal.actions`.

| `POST` | |
|---|---|
| `/pipelines/<name>/runs` | start a run over `partitions` |
| `/pipelines/<name>/backfill` | a run per partition in `partitions` that has none; `rerun=1` for done ones too |
| `/pipelines/<name>/cancel` | cancel its queued, deferred and running runs, and failed ones due a retry, over `partitions` (`@all` or empty: all) |
| `/pipelines/<name>/pause`, `/unpause` | stop the scheduler starting its runs, or let it again |
| `/watchdog/<rule>/snooze` | silence a watchdog rule for `duration` (`2h`, `30m`, `1d`; `off` ends it) |
| `/watchdog/<trip>/ack`, `/watchdog/all/ack` | acknowledge a watchdog trip, or all of them |
| `/runs/<id>/resume` | queue a failed, cancelled or stalled run again; `allow_new_code=1` confirms new code |
| `/runs/<id>/rerun` | a new run from `step` on, the steps before it copied |
| `/runs/<id>/cancel` | cancel a run, before its next attempt if it's running |
| `/runs/bulk` | `do=cancel`, `resume` (or its old name `retry`) or `backfill` the runs picked from a list: each `pick=<id>`, or with `all=1` every run its filters (`view`, `pipeline`, `status`, ...) match, if there are still `expect` of them |
| `/datasets/<name>/rebuild` | rebuild every pipeline downstream over `partitions` |

Each answers `303 See Other` to the page of what it made (a script gets
that page's JSON, with 200), or 409 saying why it wasn't done, with a way
to confirm when it asks for one. `morca._internal.web.server` checks the session and
audits each one done as its user's.
"""

from morca._internal.actions import (
    Bulk,
    Outcome,
    backfill_picked,
    cancel_runs_picked,
    resume_failed,
    backfill_runs,
    cancel_run,
    cancel_runs,
    pause_pipeline,
    rebuild_downstream,
    rerun_from,
    resume_run,
    start_run,
)
from morca._internal.api.pipelines import json_strings
from morca._internal.auth import audit
from morca._internal.html import Html, query_values, url_encode
from morca._internal.json import quote
from morca._internal.state import State
from morca._internal.ui.datasets import dataset_href
from morca._internal.ui.layout import page_html
from morca._internal.ui.errors import bad_request
from morca._internal.views.runs import (
    BULK_MAX,
    count_runs,
    int_or_zero,
    run_ids,
    runs_query,
)
from morca._internal.watchdog import acknowledge, snooze as snooze_rule
from morca._internal.web.page import Page
from morca._internal.web.router import Call


def _acted(
    o: Outcome,
    back: String,
    var json: String,
    location: String,
    again: String = "",
    again_fields: List[Tuple[String, String]] = [],
    again_label: String = "",
) -> Page:
    """The answer to an action: to `location` if it was done, or a 409
    saying why not, with a way back to `back`, and to confirm if it asks:
    posting `again_fields` to `again` with `again_label` on the button, or,
    without `again`, resuming the run at `back` onto new code."""
    if not o.refused:
        return Page(303, json^, String(), location=location)
    var h = Html()
    h.raw("<h1>Not done</h1><p>")
    h.text(o.refused)
    h.raw("</p>")
    if o.confirm and again:
        h.raw('<form class="action" method="post" action="')
        h.text(again)
        h.raw('">')
        for f in again_fields:
            h.raw('<input type="hidden" name="')
            h.text(f[0])
            h.raw('" value="')
            h.text(f[1])
            h.raw('">')
        h.raw('<button type="submit">')
        h.text(again_label)
        h.raw("</button></form>")
    elif o.confirm:
        h.raw('<form class="action" method="post" action="')
        h.text(back, "/resume")
        h.raw(
            '"><input type="hidden" name="allow_new_code" value="1">',
            '<button type="submit">Resume with the new code</button></form>',
        )
    h.raw('<p><a href="')
    h.text(back)
    h.raw('">Back</a></p>')
    return Page(
        409,
        String(
            '{"error": ',
            quote(o.refused),
            ', "confirm": ',
            "true" if o.confirm else "false",
            "}",
        ),
        page_html("Not done", "", h),
    )


# ── a pipeline's ─────────────────────────────────────────────────────────────


def _pipeline_href(call: Call) raises -> String:
    return String("/pipelines/", url_encode(call.param("name")))


def _operate_href(call: Call) raises -> String:
    """Where a refused start or cancel goes back to: its form's tab."""
    return String(_pipeline_href(call), "?tab=operate")


def _from_file(keys: String) -> Bool:
    return String(keys.strip()).startswith("@file:")


comptime _FROM_FILE = (
    "partitions from a file (@file:) are for the command line, which reads"
    " its own files; list the names, or use @all"
)


def start(mut db: State, call: Call) raises -> Page:
    """`POST /pipelines/<name>/runs`: one run over `partitions`, trigger
    `cli` from the `morca` command (`call.source`), else `ui`."""
    var keys = call.field("partitions")
    if _from_file(keys):
        return bad_request(_FROM_FILE)
    var o = start_run(
        db,
        call.param("name"),
        keys,
        "cli" if call.source == "cli" else "ui",
    )
    return _acted(
        o,
        _operate_href(call),
        String('{"run": ', o.run, "}"),
        String("/runs/", o.run),
    )


def backfill(mut db: State, call: Call) raises -> Page:
    """`POST /pipelines/<name>/backfill`: a run per partition that has
    none (`rerun=1`: done ones too)."""
    var name = call.param("name")
    var keys = call.field("partitions")
    if _from_file(keys):
        return bad_request(_FROM_FILE)
    var o = backfill_runs(
        db,
        name,
        keys,
        rerun=call.field("rerun") == "1",
        allow_append=call.field("allow_append") == "1",
    )
    var j = String('{"queued": ', o.queued, ', "skipped": ')
    json_strings(j, o.skipped)
    j.write("}")
    return _acted(
        o,
        _operate_href(call),
        j^,
        String("/runs?pipeline=", url_encode(name)),
        String(_pipeline_href(call), "/backfill"),
        [
            (String("partitions"), keys),
            (String("rerun"), String("1")),
            (String("allow_append"), String("1")),
        ],
        "Rerun them, appending again",
    )


def cancel_pipeline(mut db: State, call: Call) raises -> Page:
    """`POST /pipelines/<name>/cancel`: its live runs over `partitions`,
    all of them for `@all` or none given."""
    var name = call.param("name")
    var keys = call.field("partitions")
    var o = cancel_runs(db, name, keys if keys.strip() else "@all")
    return _acted(
        o,
        _operate_href(call),
        String('{"cancelled": ', o.queued, "}"),
        String("/runs?pipeline=", url_encode(name)),
    )


def _set_paused(mut db: State, call: Call, paused: Bool) raises -> Page:
    var o = pause_pipeline(db, call.param("name"), paused)
    var back = _pipeline_href(call)
    return _acted(
        o,
        back,
        String('{"paused": ', "true" if paused else "false", "}"),
        back,
    )


def pause(mut db: State, call: Call) raises -> Page:
    """`POST /pipelines/<name>/pause`: the scheduler starts none of its
    runs."""
    return _set_paused(db, call, True)


def unpause(mut db: State, call: Call) raises -> Page:
    """`POST /pipelines/<name>/unpause`."""
    return _set_paused(db, call, False)


# ── the watchdog's ───────────────────────────────────────────────────────────


def _acknowledge(mut db: State, call: Call, trip: Int) raises -> Page:
    var n = acknowledge(db, trip, call.user)
    return _acted(
        Outcome.done(0),
        String("/watchdog"),
        String('{"acknowledged": ', n, "}"),
        String("/watchdog"),
    )


def acknowledge_trip(mut db: State, call: Call) raises -> Page:
    """`POST /watchdog/<trip>/ack`."""
    return _acknowledge(db, call, call.int("trip"))


def acknowledge_all(mut db: State, call: Call) raises -> Page:
    """`POST /watchdog/all/ack`."""
    return _acknowledge(db, call, 0)


def snooze(mut db: State, call: Call) raises -> Page:
    """`POST /watchdog/<rule>/snooze`: silenced for `duration`."""
    try:
        var secs = snooze_rule(
            db, call.param("rule"), call.field("duration"), "ui"
        )
        return _acted(
            Outcome.done(0),
            String("/watchdog"),
            String('{"snoozed_seconds": ', secs, "}"),
            String("/watchdog"),
        )
    except e:
        return _acted(
            Outcome.no(String(e)),
            String("/watchdog"),
            String(),
            String("/watchdog"),
        )


# ── a dataset's ──────────────────────────────────────────────────────────────


def rebuild(mut db: State, call: Call) raises -> Page:
    """`POST /datasets/<name>/rebuild`: every pipeline downstream of it,
    over `partitions`."""
    var name = call.param("name")
    var o = rebuild_downstream(db, name, call.field("partitions"))
    return _acted(
        o,
        dataset_href(name),
        String('{"rebuild": ', o.run, "}"),
        String("/rebuilds/", o.run),
    )


# ── a run's ──────────────────────────────────────────────────────────────────


def _run_acted(o: Outcome, id: Int) -> Page:
    return _acted(
        o,
        String("/runs/", id),
        String('{"run": ', o.run, "}"),
        String("/runs/", o.run),
    )


def resume(mut db: State, call: Call) raises -> Page:
    """`POST /runs/<id>/resume`: queued again (`allow_new_code=1` onto new
    code)."""
    var id = call.int("id")
    return _run_acted(
        resume_run(db, id, call.field("allow_new_code") == "1"), id
    )


def rerun(mut db: State, call: Call) raises -> Page:
    """`POST /runs/<id>/rerun`: a new run from `step` on."""
    var id = call.int("id")
    var back = String("/runs/", id)
    var step = call.field("step")
    var o = rerun_from(db, id, step, call.field("allow_append") == "1")
    if o.refused and o.confirm:
        return _acted(
            o,
            back,
            String('{"run": 0}'),
            back,
            String(back, "/rerun"),
            [
                (String("step"), step),
                (String("allow_append"), String("1")),
            ],
            "Rerun it, appending again",
        )
    return _run_acted(o, id)


def cancel(mut db: State, call: Call) raises -> Page:
    """`POST /runs/<id>/cancel`: before its next attempt, if it's
    running."""
    var id = call.int("id")
    return _run_acted(cancel_run(db, id), id)


# ── runs picked from a list ──────────────────────────────────────────────────


def _ids_json(mut j: String, ids: List[Int]):
    j.write("[")
    for i in range(len(ids)):
        j.write(", " if i else "", ids[i])
    j.write("]")


def bulk(mut db: State, call: Call) raises -> Page:
    """`POST /runs/bulk`: `do` (`cancel`, `resume` or `backfill`; `retry` is
    `resume`'s old name) to the runs
    picked from a list (`morca._internal.ui.runs`), each a `pick` field, or with
    `all=1` all those the list's filters match (the form's `view`,
    `pipeline`, `status`, `trigger`, `from`, `to`, `since`, `key`, `run`),
    if there are still the `expect` the page said; otherwise it asks again
    with the number there are now. At most `BULK_MAX`. Answers 303 to the
    list, which says what was done; each run acted on is audited as its own
    action's (`/runs/<id>/cancel`, `/runs/<id>/resume`), and each backfill
    as its pipeline's."""
    var form = String("?", call.form)
    var q = runs_query(form, call.field("view"), call.field("pipeline"))
    q.before = 0
    q.after = 0
    if q.view == "home":
        q.view = "list"
    var back = q.href()
    var what = call.field("do")
    if what == "retry":
        what = "resume"  # its name before #378, still taken
    if what != "cancel" and what != "resume" and what != "backfill":
        return bad_request("do is cancel, resume or backfill")
    var ids = List[Int]()
    if call.field("all") == "1":
        var n = count_runs(db, q)
        if n > BULK_MAX:
            return _acted(
                Outcome.no(
                    String(
                        n,
                        " runs match these filters, more than the ",
                        BULK_MAX,
                        " one action does; narrow them",
                    )
                ),
                back,
                String(),
                back,
            )
        if n != int_or_zero(call.field("expect")):
            var again = List[Tuple[String, String]]()
            for f in q.fields():
                again.append(f.copy())
            again.append((String("do"), what))
            again.append((String("all"), String("1")))
            again.append((String("expect"), String(n)))
            if call.field("allow_append") == "1":
                again.append((String("allow_append"), String("1")))
            return _acted(
                Outcome.no(
                    String(
                        n,
                        " runs match these filters now, not the ",
                        int_or_zero(call.field("expect")),
                        " the page said",
                    ),
                    confirm=True,
                ),
                back,
                String(),
                back,
                String("/runs/bulk"),
                again,
                String(_verb(what), " all ", n),
            )
        ids = run_ids(db, q, BULK_MAX)
    else:
        for v in query_values(form, "pick"):
            var id = int_or_zero(v)
            if id > 0 and id not in ids:
                ids.append(id)
        if len(ids) > BULK_MAX:
            return bad_request(String("at most ", BULK_MAX, " runs at once"))
    if len(ids) == 0:
        return _acted(
            Outcome.no("no runs were picked: tick some, or all that match"),
            back,
            String(),
            back,
        )
    var b: Bulk
    if what == "cancel":
        b = cancel_runs_picked(db, ids)
    elif what == "resume":
        b = resume_failed(db, ids)
    else:
        b = backfill_picked(db, ids, call.field("allow_append") == "1")
        if b.confirm:
            var again = List[Tuple[String, String]]()
            for f in q.fields():
                again.append(f.copy())
            again.append((String("do"), what))
            for id in ids:
                again.append((String("pick"), String(id)))
            again.append((String("allow_append"), String("1")))
            return _acted(
                Outcome.no(b.confirm, confirm=True),
                back,
                String(),
                back,
                String("/runs/bulk"),
                again,
                "Backfill them, appending again",
            )
    if call.user:
        var action = String("/resume") if what == "resume" else String(
            "/cancel"
        )
        if what != "backfill":
            for id in b.done:
                audit(
                    db,
                    call.user,
                    String("/runs/", id, action),
                    id,
                    "bulk",
                    call.source,
                )
        for p in b.pipelines:
            audit(
                db,
                call.user,
                String("/pipelines/", url_encode(p[0]), "/backfill"),
                0,
                String("partitions=", url_encode(p[1]), "&rerun=1&bulk=1"),
                call.source,
            )
    var j = String('{"do": ', quote(what), ', "done": ')
    _ids_json(j, b.done)
    j.write(', "skipped": ')
    _ids_json(j, b.skipped)
    j.write(', "refused": [')
    for i in range(len(b.refused)):
        j.write(
            ", " if i else "",
            '{"run": ',
            String(b.refused[i][0]) if b.refused[i][0] else String("null"),
            ', "why": ',
            quote(b.refused[i][1]),
            "}",
        )
    j.write('], "queued": ', b.queued, "}")
    var to = String(
        back,
        "&" if "?" in back else "?",
        "did=",
        what,
        "&done=",
        len(b.done),
        "&skipped=",
        len(b.skipped),
        "&refused=",
        len(b.refused),
    )
    if what == "backfill":
        to.write("&queued=", b.queued)
    return Page(303, j^, String(), location=to)


def _verb(what: String) -> String:
    """A bulk action's button, before "all <n>"."""
    if what == "cancel":
        return String("Cancel")
    if what == "resume":
        return String("Resume the failed of")
    return String("Backfill again")
