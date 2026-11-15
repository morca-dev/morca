"""Batches without iceberg: `BatchBuilder`, which `morca.tables` gives steps
in place of `iceberg.batch`, joining batches, and reading a column's
values. Re-exported by `morca.tables`."""

from std.memory import bitcast

from arrow_mlake import (
    AT_BINARY,
    AT_BOOL,
    AT_DATE32,
    AT_DECIMAL128,
    AT_FIXED_SIZE_BINARY,
    AT_FLOAT32,
    AT_FLOAT64,
    AT_INT16,
    AT_INT32,
    AT_INT64,
    AT_INT8,
    AT_LARGE_BINARY,
    AT_LARGE_LIST,
    AT_LARGE_UTF8,
    AT_LIST,
    AT_MAP,
    AT_STRUCT,
    AT_TIME32,
    AT_TIME64,
    AT_TIMESTAMP,
    AT_UTF8,
    ArrayArena,
    bit_get,
    bit_set,
)
from parquet import RecordBatch

from morca._lake.client import Exported, api
import morca._lake.calls as lake
from morca._lake.schema import Schema


# ── building batches ────────────────────────────────────────────────────────


def _width(type_id: Int) -> Int:
    if type_id == AT_INT8:
        return 1
    if type_id == AT_INT16:
        return 2
    if type_id == AT_INT32 or type_id == AT_DATE32 or type_id == AT_TIME32:
        return 4
    if type_id == AT_FLOAT32:
        return 4
    if type_id == AT_DECIMAL128:
        return 16
    return 8


struct BatchBuilder(Movable):
    """A batch of a schema's columns, built a value at a time: what steps use
    in place of `iceberg.batch`'s `ColumnBuilder` and `batch_of`.

    ```mojo
    var b = BatchBuilder(schema)       # or (t.metadata.schema())
    var id = b.col("id")
    var tags = b.col("tags")           # a list<string>
    var tag = b.col("tags.element")
    for r in rows:
        b.add_int(id, r.id)
        for t in r.tags:
            b.add_str(tag, t)
        b.end_list(tags)
    var batches = [b^.build()]
    ```

    Columns are the schema's, at the Arrow types iceberg writes them with
    (the library makes the empty batch). A column is found by its dotted
    name: `a.b` for a struct's field, `x.element` for a list's elements,
    `m.key` and `m.value` for a map's. Each top-level column gets one value
    per row: `add_*` or `add_null` for a value, `end_list` once a list's
    elements are added, `end_struct` once a struct's fields are.
    """

    var arena: ArrayArena
    var roots: List[Int]
    var names: Dict[String, Int]

    def __init__(out self, schema: Schema) raises:
        var b = lake.empty_batch(api(), schema.to_json())
        self.arena = b.arena.copy()  # its own memory: it grows
        self.roots = b.roots.copy()
        self.names = Dict[String, Int]()
        for r in self.roots:
            self._index(r, self.arena.nodes[r].name.copy())

    def _index(mut self, node: Int, full: String):
        self.names[full] = node
        var kids = self.arena.nodes[node].children.copy()
        for c in kids:
            if self.arena.nodes[node].type.id == AT_MAP:
                # A map's one child is its entries struct: key and value.
                for kv in self.arena.nodes[c].children.copy():
                    self._index(
                        kv, String(full, ".", self.arena.nodes[kv].name)
                    )
            else:
                self._index(c, String(full, ".", self.arena.nodes[c].name))

    def col(self, name: String) raises -> Int:
        """The column (or nested field) named `name`."""
        var got = self.names.get(name, -1)
        if got < 0:
            raise Error("morca: the batch has no column ", name)
        return got

    def _valid(mut self, c: Int, ok: Bool):
        ref a = self.arena.nodes[c]
        bit_set(a.validity, a.length, ok)
        if not ok:
            a.null_count += 1
        a.length += 1

    def add_int(mut self, c: Int, v: Int64) raises:
        """An integer, date (days), time or timestamp (in the column's
        unit) value."""
        ref a = self.arena.nodes[c]
        var w = _width(a.type.id)
        var u = UInt64(v)
        for k in range(w if w <= 8 else 8):
            a.values.append(UInt8((u >> UInt64(8 * k)) & 0xFF))
        self._valid(c, True)

    def add_float(mut self, c: Int, v: Float64) raises:
        ref a = self.arena.nodes[c]
        if a.type.id == AT_FLOAT32:
            var bits = UInt64(bitcast[DType.uint32](Float32(v)))
            for k in range(4):
                a.values.append(UInt8((bits >> UInt64(8 * k)) & 0xFF))
        else:
            var bits = bitcast[DType.uint64](v)
            for k in range(8):
                a.values.append(UInt8((bits >> UInt64(8 * k)) & 0xFF))
        self._valid(c, True)

    def add_bool(mut self, c: Int, v: Bool):
        ref a = self.arena.nodes[c]
        bit_set(a.values, a.length, v)
        self._valid(c, True)

    def add_bytes(mut self, c: Int, v: Span[UInt8, _]) raises:
        """A string, binary or fixed-size value's bytes."""
        ref a = self.arena.nodes[c]
        var t = a.type.id
        a.values.extend(v)
        if t == AT_UTF8 or t == AT_BINARY:
            if len(a.offsets) == 0:
                a.offsets.append(0)
            a.offsets.append(Int32(len(a.values)))
        elif t == AT_LARGE_UTF8 or t == AT_LARGE_BINARY:
            if len(a.large_offsets) == 0:
                a.large_offsets.append(0)
            a.large_offsets.append(Int64(len(a.values)))
        elif t != AT_FIXED_SIZE_BINARY and t != AT_DECIMAL128:
            raise Error("morca: column ", a.name, " doesn't take bytes")
        self._valid(c, True)

    def add_str(mut self, c: Int, v: String) raises:
        self.add_bytes(c, v.as_bytes())

    def end_list(mut self, c: Int) raises:
        """Ends the list value whose elements were added since the last."""
        ref a = self.arena.nodes[c]
        var e = a.children[0]
        var n = self.arena.nodes[e].length
        if a.type.id == AT_LARGE_LIST:
            if len(a.large_offsets) == 0:
                a.large_offsets.append(0)
            a.large_offsets.append(Int64(n))
        else:
            if len(a.offsets) == 0:
                a.offsets.append(0)
            a.offsets.append(Int32(n))
        self._valid(c, True)

    def end_struct(mut self, c: Int):
        """Ends a struct value whose fields were each given one."""
        self._valid(c, True)

    def add_null(mut self, c: Int) raises:
        """A null: a struct's fields get one too, a list or map no elements."""
        ref a = self.arena.nodes[c]
        var t = a.type.id
        if t == AT_STRUCT:
            for k in a.children.copy():
                self.add_null(k)
        elif t == AT_LIST or t == AT_MAP:
            if len(a.offsets) == 0:
                a.offsets.append(0)
            a.offsets.append(a.offsets[len(a.offsets) - 1])
        elif t == AT_LARGE_LIST:
            if len(a.large_offsets) == 0:
                a.large_offsets.append(0)
            a.large_offsets.append(a.large_offsets[len(a.large_offsets) - 1])
        elif t == AT_UTF8 or t == AT_BINARY:
            if len(a.offsets) == 0:
                a.offsets.append(0)
            a.offsets.append(Int32(len(a.values)))
        elif t == AT_LARGE_UTF8 or t == AT_LARGE_BINARY:
            if len(a.large_offsets) == 0:
                a.large_offsets.append(0)
            a.large_offsets.append(Int64(len(a.values)))
        elif t == AT_BOOL:
            bit_set(a.values, a.length, False)
        elif t == AT_FIXED_SIZE_BINARY:
            for _ in range(a.type.byte_width):
                a.values.append(0)
        else:
            for _ in range(_width(t)):
                a.values.append(0)
        self._valid(c, False)

    def rows(self) -> Int:
        if len(self.roots) == 0:
            return 0
        return self.arena.nodes[self.roots[0]].length

    def batch(self) raises -> RecordBatch:
        """The batch so far, copied; the builder goes on."""
        var b = RecordBatch()
        b.arena = self.arena.copy()
        b.roots = self.roots.copy()
        b.num_rows = self.rows()
        _check_rows(b)
        return b^

    def build(deinit self) raises -> RecordBatch:
        """The batch; every top-level column must have the same rows."""
        var n = 0
        if len(self.roots) > 0:
            n = self.arena.nodes[self.roots[0]].length
        for r in self.roots:
            if self.arena.nodes[r].length != n:
                raise Error(
                    "morca: column ",
                    self.arena.nodes[r].name,
                    " has ",
                    self.arena.nodes[r].length,
                    " rows and the first ",
                    n,
                )
        var b = RecordBatch()
        b.arena = self.arena^
        b.roots = self.roots^
        b.num_rows = n
        return b^


def concat_batches(batches: List[RecordBatch]) raises -> RecordBatch:
    """Batches with the same columns as one batch, as iceberg's `concat_tree`
    joins them column by column: e.g. to write a partition's rows as one file
    (`write_files` writes a file per batch)."""
    if len(batches) == 0:
        return RecordBatch()
    if len(batches) == 1:
        return batches[0].copy()
    return lake.concat(api(), Exported(batches))


def _check_rows(b: RecordBatch) raises:
    for r in b.roots:
        if b.arena.nodes[r].length != b.num_rows:
            raise Error(
                "morca: column ",
                b.arena.nodes[r].name,
                " has ",
                b.arena.nodes[r].length,
                " rows and the first ",
                b.num_rows,
            )


# ── reading batches ─────────────────────────────────────────────────────────


def column_of(b: RecordBatch, name: String) raises -> Int:
    """The arena index of `b`'s top-level column `name`."""
    for r in b.roots:
        if b.arena.nodes[r].name == name:
            return r
    raise Error("morca: the batch has no column ", name)


def strings_of(b: RecordBatch, name: String) raises -> List[Optional[String]]:
    """The values of `b`'s string column `name`, None for a null."""
    ref a = b.arena.nodes[column_of(b, name)]
    if a.type.id != AT_UTF8 and a.type.id != AT_LARGE_UTF8:
        raise Error("morca: column ", name, " isn't a string column")
    var out = List[Optional[String]]()
    var large = a.type.id == AT_LARGE_UTF8
    for i in range(a.length):
        if not bit_get(Span(a.validity), i):
            out.append(None)
            continue
        var lo = Int(a.large_offsets[i]) if large else Int(a.offsets[i])
        var hi = Int(a.large_offsets[i + 1]) if large else Int(a.offsets[i + 1])
        out.append(String(unsafe_from_utf8=Span(a.values)[lo:hi]))
    return out^


def ints_of(b: RecordBatch, name: String) raises -> List[Optional[Int64]]:
    """The values of `b`'s integer (or date, time, timestamp) column `name`,
    None for a null."""
    ref a = b.arena.nodes[column_of(b, name)]
    var w = _width(a.type.id)
    if a.type.id == AT_FLOAT32 or a.type.id == AT_FLOAT64 or w > 8:
        raise Error("morca: column ", name, " isn't an integer column")
    var out = List[Optional[Int64]]()
    for i in range(a.length):
        if not bit_get(Span(a.validity), i):
            out.append(None)
            continue
        var u: UInt64 = 0
        for k in range(w):
            u |= UInt64(a.values[i * w + k]) << UInt64(8 * k)
        if w < 8 and ((u >> UInt64(8 * w - 1)) & 1) == 1:
            u |= ~UInt64(0) << UInt64(8 * w)  # sign-extend
        out.append(Int64(u))
    return out^
