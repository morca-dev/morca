"""Runs as JSON: a run (`json_run`), a list's page with its cursors, a
code version, and a run's machines with their metrics.
"""

from morca._internal.ui.cluster import cluster_json
from morca._internal.json import quote
from morca._internal.metrics import InstanceMetrics, peaks_json
from morca._internal.source import commit_url
from morca._internal.usage import usage_json
from morca._internal.views.runs import (
    InstanceRow,
    RunRow,
    RunView,
    RunsPage,
    VersionRow,
    cluster_log_name,
)


def json_version(mut out: String, v: VersionRow):
    var url = commit_url(v.source, v.commit)
    out.write(
        '{"id": ',
        v.id,
        ', "registry_hash": ',
        quote(v.registry_hash),
        ', "source": ',
        quote(v.source),
        ', "commit": ',
        quote(v.commit),
        ', "commit_url": ',
        quote(url) if url else String("null"),
        ', "dirty": ',
        "true" if v.dirty else "false",
        ', "image": ',
        quote(v.image),
        ', "first_seen": ',
        quote(v.first_seen),
        ', "last_seen": ',
        quote(v.last_seen),
        ', "runs": ',
        v.runs,
        ', "locations": ',
        v.locations if v.locations else String("null"),
        "}",
    )


def json_instances(
    mut out: String,
    run: Int,
    xs: List[InstanceRow],
    metrics: List[InstanceMetrics],
):
    """The run's instances, each with its samples' peaks (`morca._internal.metrics`),
    then those with samples and no instance row: a local run's machine and
    a Kubernetes run's pods."""
    out.write("[")
    var matched = List[String]()
    for k in range(len(xs)):
        ref i = xs[k]
        var name = String(i.role, "-", i.id)
        var peaks = String("null")
        for m in metrics:
            if m.name == name:
                peaks = peaks_json(m)
                matched.append(name)
        out.write(
            ", " if k else "",
            '{"id": ',
            quote(i.id),
            ', "start": ',
            i.start,
            ', "role": ',
            quote(i.role),
            ', "type": ',
            quote(i.instance_type),
            ', "market": ',
            quote(i.market),
            ', "launched": ',
            quote(i.launched),
            ', "ended": ',
            quote(i.ended) if i.ended else String("null"),
            ', "why": ',
            quote(i.why) if i.why else String("null"),
            ', "procs": ',
            i.procs,
            ', "log": ',
            quote(String("/runs/", run, "/cluster/", cluster_log_name(i))),
            ', "peaks": ',
            peaks,
            "}",
        )
    var n = len(xs)
    for m in metrics:
        if m.name in matched:
            continue
        out.write(
            ", " if n else "",
            '{"id": ',
            quote(m.name),
            ', "start": null, "role": ',
            quote(_role_of(m.name)),
            ', "type": null, "market": null, "launched": null, "ended":',
            ' null, "why": null, "log": null, "peaks": ',
            peaks_json(m),
            "}",
        )
        n += 1
    out.write("]")


def _role_of(name: String) -> String:
    """A sampled instance's role, from its file's name: `local`, an ec2
    `<role>-<id>`, or a pod's `morca-<run>-<start>-<role>[-<i>]`."""
    if name == "local":
        return "local"
    if name.startswith("head-") or name.endswith("-head"):
        return "head"
    if name.startswith("worker-") or "-worker-" in name:
        return "worker"
    return "driver"


def json_run(mut out: String, r: RunRow):
    out.write(
        '{"id": ',
        r.id,
        ', "pipeline": ',
        quote(r.pipeline),
        ', "partitions": ',
        quote(r.partitions),
        ', "trigger": ',
        quote(r.trigger),
        ', "status": ',
        quote(r.status),
        ', "starts": ',
        r.starts,
        ', "created": ',
        quote(r.created),
        ', "started": ',
        quote(r.started),
        ', "ended": ',
        quote(r.ended),
        ', "cancel_requested": ',
        "true" if r.cancel_requested else "false",
        ', "stalled": ',
        "true" if r.stalled else "false",
        ', "error": ',
        quote(r.error),
        ', "waiting_until": ',
        quote(r.waiting_until) if r.waiting_until else String("null"),
        ', "placement": ',
        quote(r.placement) if r.placement else String("null"),
        ', "held": ',
        quote(r.held) if r.held and r.status == "queued" else String("null"),
        ', "waits_on": ',
        String(r.waits_on) if r.waits_on > 0 and r.held else String("null"),
        ', "usage": ',
        usage_json(r.usage),
        ', "code_version": ',
        quote(r.code_version) if r.code_version else String("null"),
        ', "desired_code_version": ',
        quote(r.desired_code_version) if r.desired_code_version else String(
            "null"
        ),
        ', "outdated": ',
        quote(r.outdated) if r.outdated else String("null"),
        ", ",
        r.resources.json(),
        ", ",
        r.resources.limit_json(),
        "}",
    )


def json_runs(mut out: String, runs: List[RunRow]):
    out.write("[")
    for i in range(len(runs)):
        if i:
            out.write(", ")
        json_run(out, runs[i])
    out.write("]")


def json_runs_page(mut j: String, p: RunsPage):
    """A runs page's place, after its `runs`: the size, cursor and counts,
    and the cursors of the pages either side (null where there's none):
    `next` is the `before` of the older page, `prev` the `after` of the
    newer one, and `next_url`, `prev_url` their paths."""
    var newer = p.newer_href()
    var older = p.older_href()
    var n = len(p.rows)
    j.write(
        '"n": ',
        p.q.size,
        ', "limit": ',
        p.q.size,
        ', "before": ',
        String(p.q.before) if p.q.before > 0 else String("null"),
        ', "after": ',
        String(p.q.after) if p.q.after > 0 else String("null"),
        ', "total": ',
        p.total,
        ', "newer": ',
        p.newer,
        ', "older": ',
        p.older,
        ', "next_before": ',
        String(p.rows[n - 1].id) if older else String("null"),
        ', "next": ',
        String(p.rows[n - 1].id) if older else String("null"),
        ', "prev": ',
        String(p.rows[0].id) if newer and n > 0 else String("null"),
        ', "next_url": ',
        quote(older) if older else String("null"),
        ', "prev_url": ',
        quote(newer) if newer else String("null"),
    )


def runs_filters_json(mut j: String, p: RunsPage):
    """`"filters": {...}, "counts": {...}`: what the list is filtered by,
    and each status's runs under its other filters."""
    j.write(
        '"filters": {"pipeline": ',
        quote(p.q.pipeline),
        ', "status": ',
        quote(p.q.status),
        ', "statuses": [',
    )
    var ss = p.q.statuses()
    for i in range(len(ss)):
        j.write(", " if i else "", quote(ss[i]))
    j.write(
        '], "trigger": ',
        quote(p.q.trigger),
        ', "since": ',
        quote(p.q.since) if p.q.since else String("null"),
        ', "from": ',
        quote(p.q.start) if p.q.start else String("null"),
        ', "to": ',
        quote(p.q.end) if p.q.end else String("null"),
        ', "run": ',
        String(p.q.run) if p.q.run > 0 else String("null"),
        ', "key": ',
        quote(p.q.key) if p.q.key else String("null"),
        ', "batch": ',
        String(p.q.batch) if p.q.batch > 0 else String("null"),
        '}, "counts": {',
    )
    for i in range(len(p.counts)):
        j.write(", " if i else "", quote(p.counts[i][0]), ": ", p.counts[i][1])
    j.write("}")


def run_json(v: RunView) -> String:
    """`/runs/<id>` (and `/api/...`) as JSON: the run, its code, its
    machines, what started it, its steps and the tables they touched."""
    ref r = v.run
    var cpu = v.cpu_millis
    var j = String('{"run": ')
    json_run(j, r)
    j.write(
        ', "registry_hash": ',
        quote(v.registry_hash),
        ', "current_code": ',
        "true" if v.current_code else "false",
        ', "rebuild": ',
        String(v.rebuild) if v.rebuild else String("null"),
        ', "batch": ',
        String(v.batch) if v.batch else String("null"),
        ', "batch_runs": ',
        String(v.batch_runs) if v.batch else String("null"),
        ', "cpu_millis": ',
        String(cpu) if cpu else String("null"),
        ', "cpu_seconds": ',
        String(cpu * v.seconds // 1000) if cpu else String("null"),
        ', "version": ',
    )
    if v.version:
        json_version(j, v.version.value())
    else:
        j.write("null")
    j.write(', "instances": ')
    json_instances(j, r.id, v.instances, v.metrics)
    j.write(', "cluster": ', cluster_json(v.cluster))
    j.write(', "sensed": [')
    for i in range(len(v.sensed)):
        j.write(", " if i else "", quote(String(v.sensed[i])))
    j.write('], "steps": [')
    for i in range(len(v.steps)):
        ref s = v.steps[i]
        if i:
            j.write(", ")
        j.write(
            '{"step": ',
            quote(s.step),
            ', "partition": ',
            quote(s.partition),
            ', "status": ',
            quote(s.status),
            ', "attempts": ',
            s.attempts,
            ', "error": ',
            quote(s.error),
            ', "log": ',
            quote(s.log),
            ', "started": ',
            quote(s.started),
            ', "ended": ',
            quote(s.ended),
            ', "attempt_id": ',
            s.attempt_id,
            ', "from_run": ',
            s.from_run,
            ', "usage": ',
            usage_json(s.usage),
            ', "memory_limit_mb": ',
            String(s.limit_mb) if s.limit_mb > 0 else String("null"),
            ', "grant_memory_mb": ',
            String(s.grant_mb) if s.grant_mb > 0 else String("null"),
            "}",
        )
    j.write('], "tables": [')
    for i in range(len(v.touches)):
        ref t = v.touches[i]
        if i:
            j.write(", ")
        j.write(
            '{"step": ',
            quote(t.step),
            ', "partition": ',
            quote(t.partition),
            ', "kind": ',
            quote(t.kind),
            ', "table": ',
            quote(t.table),
            ', "snapshot": ',
            quote(t.snapshot),
            ', "dataset": ',
            quote(t.dataset) if t.dataset else String("null"),
            "}",
        )
    j.write("]}")
    return j^
