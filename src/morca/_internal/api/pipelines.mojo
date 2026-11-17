"""A pipeline as JSON: its registration (`json_pipeline`), a keyed one's
counts and Start runs' preview.
"""

from morca._internal.api.runs import (
    json_runs,
    json_runs_page,
    json_version,
    runs_filters_json,
)
from morca._internal.calendar import calendar, calendar_json
from morca._internal.coverage import Coverage, coverage_json
from morca._internal.fill import status_json
from morca._internal.follow import follow_json
from morca._internal.json import quote
from morca._internal.state import State
from morca._internal.ui.errors import bad_request, not_found
from morca._internal.views.commands import backfill_cmd, run_cmd
from morca._internal.views.pipelines import (
    KeyCounts,
    PipelineAsk,
    PipelineView,
    pipeline_rows,
)
from morca._internal.db.pipelines_view import PipelineRow
from morca._internal.views.start import StartPreview, preview_line
from morca._internal.web.page import Page


def json_strings(mut out: String, names: List[String]):
    out.write("[")
    for i in range(len(names)):
        out.write(", " if i else "", quote(names[i]))
    out.write("]")


def json_pipeline(
    mut out: String, p: PipelineRow, cov: Optional[Coverage] = None
):
    """`p` as JSON, with its coverage (`morca._internal.coverage`; null for none).
    """
    out.write(
        '{"name": ',
        quote(p.name),
        ', "registry_hash": ',
        quote(p.registry_hash),
        ', "binary": ',
        quote(p.binary),
        ', "partitions": {"kind": ',
        quote(p.kind),
        ', "start": ',
        quote(p.start),
        '}, "coverage": ',
        coverage_json(cov),
        ', "schedule": ',
    )
    if p.cron:
        out.write(
            '{"cron": ',
            quote(p.cron),
            ', "tz": ',
            quote(p.tz),
            ', "fire": ',
            quote(p.fills),
            ', "fills": ',
            quote(p.fills),
            "}",
        )
    else:
        out.write("null")
    out.write(
        ', "max_runs": ',
        p.max_runs,
        ', "run_retries": ',
        p.run_retries,
        ', "running": ',
        p.running,
        ', "queued": ',
        p.queued,
        ', "paused": ',
        "true" if p.paused else "false",
        ', "placement": ',
        quote(p.placement if p.placement else String("default")),
        ', "request": ',
    )
    if p.cpus or p.memory_gb:
        out.write(
            '{"cpus": ',
            quote(p.cpus) if p.cpus else String("null"),
            ', "memory_gb": ',
            quote(p.memory_gb) if p.memory_gb else String("null"),
            "}",
        )
    else:
        out.write("null")
    out.write(
        ', "waiting": ',
        quote(p.waiting) if p.waiting else String("null"),
        ', "last_run": ',
    )
    if p.last_run:
        out.write(
            '{"id": ',
            p.last_run,
            ', "status": ',
            quote(p.last_status),
            ', "partitions": ',
            quote(p.last_partitions),
            "}",
        )
    else:
        out.write("null")
    out.write(', "next_fire": ')
    if p.next_fire:
        out.write(
            '{"at": ',
            quote(p.next_fire),
            ', "partition": ',
            quote(p.next_partition),
            "}",
        )
    else:
        out.write("null")
    out.write(', "sense_error": ')
    if p.sense_error:
        out.write(
            '{"at": ',
            quote(p.sense_error_at),
            ', "error": ',
            quote(p.sense_error),
            "}",
        )
    else:
        out.write("null")
    out.write("}")


def json_keys(mut out: String, k: KeyCounts):
    out.write(
        '{"dataset": ',
        quote(k.dataset),
        ', "snapshot": ',
        k.snapshot,
        ', "total": ',
        k.total,
        ', "done": ',
        k.done,
        ', "live": ',
        k.live,
        ', "failed": ',
    )
    json_strings(out, k.failed)
    out.write(
        ', "error": ',
        quote(k.error),
        ', "read_at": ',
        quote(k.read_at),
        ', "note": ',
        quote(k.note),
        "}",
    )


def _or_null(seconds: Int) -> String:
    return String(seconds) if seconds >= 0 else String("null")


def _seconds(x: Float64) -> String:
    return String(Float64(Int(x * 10.0 + 0.5)) / 10.0)


def json_start_preview(
    mut out: String,
    p: PipelineRow,
    v: StartPreview,
    keys: String,
    rerun: Bool,
):
    out.write(
        '{"partitions": ',
        quote(keys),
        ', "rerun": ',
        "true" if rerun else "false",
        ', "refused": ',
        quote(v.refused) if v.refused else String("null"),
        ', "runs": ',
        v.runs,
        ', "keys": ',
    )
    json_strings(out, v.keys)
    out.write(', "done": ')
    json_strings(out, v.done)
    out.write(', "live": ')
    json_strings(out, v.live)
    out.write(
        ', "one_run": ',
        len(v.keys) + len(v.done) + len(v.live),
        ', "summary": ',
        quote(preview_line(p, v)) if not v.refused else String("null"),
        ', "estimate": {"per_key_seconds": ',
        _seconds(v.pace.per_key) if v.pace.known() else String("null"),
        ', "sample_runs": ',
        v.pace.runs,
        ', "backfill_seconds": ',
        _or_null(v.pace.backfill(len(v.keys), v.runs, p.max_runs)),
        ', "one_run_seconds": ',
        _or_null(v.pace.one_run(len(v.keys) + len(v.done) + len(v.live))),
        "}",
        ', "commands": {"backfill": ',
        quote(backfill_cmd(p.name, keys, rerun)),
        ', "run": ',
        quote(run_cmd(p.binary, keys)),
        "}}",
    )


def calendar_page(mut db: State, name: String, month: String) raises -> Page:
    """`/pipelines/<name>/calendar?month=2023-01`: each day (or, for a
    monthly pipeline, each month of the year) with its state, as JSON alone."""
    var ps = pipeline_rows(db, name)
    if len(ps) == 0:
        return not_found(String("no pipeline ", name))
    try:
        var c = calendar(db, name, ps[0].kind, ps[0].start, month)
        var j = calendar_json(c)
        return Page(200, j.copy(), j^, "application/json")
    except e:
        return bad_request(String(e))


def pipeline_json(v: PipelineView, ask: PipelineAsk) -> String:
    """`/pipelines/<name>` (and `/api/pipelines/<name>`) as JSON: the
    registration with its coverage, its fill, steps, next fires, code
    versions, config, a page of its runs, what its runs used, a keyed one's
    counts, the snapshots its sensor couldn't run, and Start runs' preview
    if asked for."""
    ref p = v.pipeline
    var j = String('{"pipeline": ')
    json_pipeline(j, p, v.coverage)
    j.write(', "fill": ', status_json(v.fill.value()) if v.fill else "null")
    j.write(
        ', "follow": ',
        follow_json(v.following.value()) if v.following else "null",
    )
    j.write(', "steps": [')
    for i in range(len(v.steps)):
        ref s = v.steps[i]
        if i:
            j.write(", ")
        j.write(
            '{"name": ',
            quote(s.name),
            ', "kind": ',
            quote(s.kind),
            ', "after": ',
            quote(s.after) if s.after else String("null"),
            ', "reads": ',
        )
        json_strings(j, s.reads)
        j.write(', "writes": ')
        json_strings(j, s.writes)
        j.write("}")
    j.write('], "fires": [')
    for i in range(len(v.fires)):
        ref f = v.fires[i]
        if i:
            j.write(", ")
        j.write(
            '{"at": ',
            quote(f.at),
            ', "local": ',
            quote(f.local),
            ', "partition": ',
            quote(f.partition),
            "}",
        )
    j.write('], "versions": [')
    for i in range(len(v.versions)):
        if i:
            j.write(", ")
        json_version(j, v.versions[i])
    j.write('], "config": ')
    j.write(v.configs[0].json() if len(v.configs) > 0 else String("null"))
    j.write(', "runs": ')
    json_runs(j, v.runs.rows)
    j.write(', "runs_page": {')
    json_runs_page(j, v.runs)
    j.write(", ")
    runs_filters_json(j, v.runs)
    j.write('}, "usage": ', v.usage.json(), ', "learned": ')
    j.write(v.learned.value().json() if v.learned else String("null"))
    if v.keys:
        j.write(', "keys": ')
        json_keys(j, v.keys.value())
    j.write(', "not_run": [')
    for i in range(len(v.not_run)):
        ref u = v.not_run[i]
        j.write(
            ", " if i else "",
            '{"dataset": ',
            quote(u.snapshot.dataset),
            ', "snapshot": ',
            u.snapshot.snapshot,
            ', "at": ',
            quote(u.at),
            ', "error": ',
            quote(u.error),
            "}",
        )
    j.write("]")
    if v.start:
        j.write(', "preview": ')
        json_start_preview(j, p, v.start.value(), ask.partitions, ask.rerun)
    j.write("}")
    return j^
