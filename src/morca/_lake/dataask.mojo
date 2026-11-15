"""What the UI's data view asks `morca_maintain data` for (#435,
`morca._lake.dataread`): the dataset, the snapshot, the filters, the
columns, the sort, the page, the chart and the limits; and the table's
columns, with the filters as iceberg's filter DSL, each value typed by its
column."""

from iceberg.json import json_quote
from iceberg.schema import Schema
from iceberg.types import (
    P_BOOLEAN,
    P_DATE,
    P_DECIMAL,
    P_DOUBLE,
    P_FLOAT,
    P_INT,
    P_LONG,
    P_TIME,
    P_TIMESTAMP,
    P_TIMESTAMP_NS,
    P_TIMESTAMPTZ,
    P_TIMESTAMPTZ_NS,
    TK_PRIMITIVE,
)
from iceberg.values import iso_text

comptime OPS = ["eq", "ne", "lt", "le", "gt", "ge", "in"]
comptime _DSL_OPS = ["=", "!=", "<", "<=", ">", ">="]
comptime NESTED: UInt8 = 254
"""A column's kind when it's a struct, list or map, not a primitive."""


@fieldwise_init
struct Where(Copyable, Movable):
    """One `--where COL:OP:VALUE`."""

    var column: String
    var op: String
    var value: String

    @staticmethod
    def parse(text: String) raises -> Where:
        var a = text.find(":")
        var b = text.find(":", a + 1) if a >= 0 else -1
        if a <= 0 or b < 0:
            raise Error(
                (
                    "morca: a filter is COLUMN:OP:VALUE (OP eq, ne, lt, le, gt,"
                    " ge or in), not "
                ),
                text,
            )
        var op = String(text[byte = a + 1 : b])
        var known = False
        for o in materialize[OPS]():
            known = known or o == op
        if not known:
            raise Error(
                "morca: a filter's OP is eq, ne, lt, le, gt, ge or in, not ",
                op,
            )
        return Where(String(text[byte=:a]), op^, String(text[byte = b + 1 :]))


struct DataAsk(Copyable, Movable):
    """What `morca_maintain data` was asked for."""

    var dataset: String
    var snapshot: Int64
    """-1 for the current snapshot."""
    var wheres: List[Where]
    var columns: List[String]
    """Empty for every top-level column."""
    var sort: String
    """A column, `-` before it for descending; empty for the scan's order."""
    var offset: Int
    var limit: Int
    var chart_x: String
    var chart_y: List[String]
    var chart_agg: String
    var csv: String
    """Where to write the rows as CSV; empty for none."""
    var max_rows: Int
    """The most rows a sort, chart or download reads."""
    var seconds: Float64
    var memory_mb: Float64
    var partitions: Bool
    var rows: Bool

    def __init__(out self, dataset: String):
        self.dataset = dataset
        self.snapshot = -1
        self.wheres = List[Where]()
        self.columns = List[String]()
        self.sort = String()
        self.offset = 0
        self.limit = 100
        self.chart_x = String()
        self.chart_y = List[String]()
        self.chart_agg = String("avg")
        self.csv = String()
        self.max_rows = 100_000
        self.seconds = 20.0
        self.memory_mb = 256.0
        self.partitions = True
        self.rows = True


def _split_names(text: String) -> List[String]:
    var out = List[String]()
    for p in text.split(","):
        var s = String(p.strip())
        if s:
            out.append(s^)
    return out^


def parse_ask(args: List[String]) raises -> DataAsk:
    """`args` after `data`: the dataset, then the flags (module doc)."""
    if len(args) == 0:
        raise Error("morca_maintain: expected `data <dataset>`")
    var a = DataAsk(args[0])
    var i = 1
    while i < len(args):
        var k = args[i]
        var flag = k in [
            "--no-partitions",
            "--no-rows",
        ]
        if flag:
            if k == "--no-partitions":
                a.partitions = False
            else:
                a.rows = False
            i += 1
            continue
        if i + 1 >= len(args):
            raise Error("morca_maintain: ", k, " needs a value")
        var v = args[i + 1]
        if k == "--snapshot":
            a.snapshot = Int64(Int(v))
        elif k == "--where":
            a.wheres.append(Where.parse(v))
        elif k == "--columns":
            a.columns = _split_names(v)
        elif k == "--sort":
            a.sort = v
        elif k == "--offset":
            a.offset = max(0, Int(v))
        elif k == "--limit":
            a.limit = max(0, Int(v))
        elif k == "--chart-x":
            a.chart_x = v
        elif k == "--chart-y":
            a.chart_y = _split_names(v)
        elif k == "--chart-agg":
            if v != "avg" and v != "sum":
                raise Error("morca: --chart-agg is avg or sum, not ", v)
            a.chart_agg = v
        elif k == "--csv":
            a.csv = v
        elif k == "--max-rows":
            a.max_rows = max(1, Int(v))
        elif k == "--seconds":
            a.seconds = Float64(v)
        elif k == "--memory-mb":
            a.memory_mb = Float64(v)
            if a.memory_mb <= 0:
                raise Error("morca: --memory-mb is over 0, not ", v)
        else:
            raise Error("morca_maintain: unknown argument: ", k)
        i += 2
    return a^


@fieldwise_init
struct Column(Copyable, Movable):
    var id: Int
    var name: String
    var type: String
    var kind: UInt8
    """The primitive kind (`iceberg.types.P_*`), or `NESTED`."""
    var required: Bool
    var doc: String


def columns_of(schema: Schema) -> List[Column]:
    """The schema's top-level columns."""
    var out = List[Column]()
    for f in schema.columns():
        ref n = schema.store.nodes[f.type]
        out.append(
            Column(
                f.id,
                f.name.copy(),
                schema.store.type_name(f.type),
                n.prim if n.kind == TK_PRIMITIVE else NESTED,
                f.required,
                f.doc.copy() if f.has_doc else String(),
            )
        )
    return out^


def find_column(cols: List[Column], name: String) -> Int:
    for i in range(len(cols)):
        if cols[i].name == name:
            return i
    return -1


def is_numeric(kind: UInt8) -> Bool:
    return (
        kind == P_INT
        or kind == P_LONG
        or kind == P_FLOAT
        or kind == P_DOUBLE
        or kind == P_DECIMAL
    )


def is_time(kind: UInt8) -> Bool:
    return (
        kind == P_DATE
        or kind == P_TIME
        or kind == P_TIMESTAMP
        or kind == P_TIMESTAMPTZ
        or kind == P_TIMESTAMP_NS
        or kind == P_TIMESTAMPTZ_NS
    )


def _literal(c: Column, value: String) raises -> String:
    """`value`, typed in the filter DSL as column `c` reads it."""
    var v = String(value.strip())
    if is_numeric(c.kind) and c.kind != P_DECIMAL:
        try:
            _ = Float64(v)
        except:
            raise Error("morca: ", c.name, " is a number, and ", v, " isn't")
        return v^
    if c.kind == P_BOOLEAN:
        if v != "true" and v != "false":
            raise Error("morca: ", c.name, " is true or false, not ", v)
        return v^
    if c.kind == NESTED:
        raise Error(
            "morca: ", c.name, " is a ", c.type, ": it can't be compared"
        )
    return json_quote(v)


def filter_dsl(cols: List[Column], wheres: List[Where]) raises -> String:
    """The filters as iceberg's filter DSL, each literal typed by its
    column; `["true"]` for none."""
    if len(wheres) == 0:
        return String('["true"]')
    var parts = List[String]()
    for w in wheres:
        var k = find_column(cols, w.column)
        if k < 0:
            raise Error("morca: the table has no column ", w.column)
        ref c = cols[k]
        if w.op == "in":
            var vals = String()
            for v in w.value.split(","):
                vals.write("," if vals else "", _literal(c, String(v)))
            parts.append(
                String('["in", ', json_quote(c.name), ", [", vals, "]]")
            )
        else:
            var at = 0
            for i in range(len(materialize[OPS]())):
                if materialize[OPS]()[i] == w.op:
                    at = i
            parts.append(
                String(
                    '["',
                    materialize[_DSL_OPS]()[at],
                    '", ',
                    json_quote(c.name),
                    ", ",
                    _literal(c, w.value),
                    "]",
                )
            )
    if len(parts) == 1:
        return parts[0]
    var out = String('["and"')
    for p in parts:
        out.write(", ", p)
    out.write("]")
    return out^


def iso_ms(ms: Int64) -> String:
    return iso_text(P_TIMESTAMPTZ, ms * 1000).replace("+00:00", "Z")
