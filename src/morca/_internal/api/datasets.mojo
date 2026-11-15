"""Rebuilds and lineage as JSON."""

from morca._internal.json import quote
from morca._internal.db.lineage import Made
from morca._internal.db.rebuilds import Rebuild


def json_rebuild(mut out: String, r: Rebuild):
    out.write(
        '{"id": ',
        r.id,
        ', "dataset": ',
        quote(r.dataset),
        ', "partitions": ',
        quote(r.partitions),
        ', "status": ',
        quote(r.status),
        ', "created": ',
        quote(r.created),
        ', "ended": ',
        quote(r.ended),
        ', "plan": [',
    )
    for i in range(len(r.plan)):
        ref p = r.plan[i]
        out.write(
            ", " if i else "",
            '{"pipeline": ',
            quote(p.pipeline),
            ', "level": ',
            p.level,
            ', "partitions": ',
            quote(p.partitions),
            ', "run": ',
            String(p.run) if p.run else String("null"),
            ', "status": ',
            quote(p.status),
            "}",
        )
    out.write("]}")


def json_made(mut out: String, ms: List[Made]):
    out.write("[")
    for i in range(len(ms)):
        ref m = ms[i]
        out.write(
            ", " if i else "",
            '{"dataset": ',
            quote(m.at.dataset),
            ', "snapshot": ',
            m.at.snapshot,
            ', "depth": ',
            m.depth,
            ', "pipeline": ',
            quote(m.pipeline),
            ', "run": ',
            m.run,
            ', "step": ',
            quote(m.step),
            ', "partition": ',
            quote(m.partition),
            ', "attempt": ',
            m.attempt,
            ', "code": ',
            quote(m.code),
            ', "ended": ',
            quote(m.ended),
            ', "inputs": [',
        )
        for k in range(len(m.inputs)):
            out.write(
                ", " if k else "",
                '{"dataset": ',
                quote(m.inputs[k].dataset),
                ', "snapshot": ',
                m.inputs[k].snapshot,
                "}",
            )
        out.write("]}")
    out.write("]")
