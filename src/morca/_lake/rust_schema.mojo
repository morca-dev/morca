"""Whether a Rust worker's output fits its table (docs/rust-workers.md, "The
schema"): the schema of the stream it returns, and the schema of each
Parquet file it writes. Both are read into a `SchemaTree` and checked by
one rule, which names the column that doesn't fit.

A stream's batches are aligned to the table before they're written
(iceberg's `align_batch`), so a column of a narrower type is cast, and its
field ids are optional. A file is committed as it is, and read later by
field id, so it's held to more: every column carries the table's field id,
and a type is the table's or one iceberg's reader promotes when it reads
(`int` to `long`, `float` to `double`, a decimal's precision).
"""

from iceberg.nested import arrow_type_of
from iceberg.schema import Schema
from iceberg.types import (
    TK_LIST,
    TK_PRIMITIVE,
    TK_STRUCT,
    NestedField,
    TypeStore,
    primitive_name,
)
from arrow_mlake.arrow import (
    AT_BINARY,
    AT_DECIMAL128,
    AT_FIXED_SIZE_BINARY,
    AT_FLOAT32,
    AT_FLOAT64,
    AT_INT8,
    AT_INT16,
    AT_INT32,
    AT_INT64,
    AT_LARGE_BINARY,
    AT_LARGE_LIST,
    AT_LARGE_UTF8,
    AT_LIST,
    AT_MAP,
    AT_STRUCT,
    AT_TIME64,
    AT_TIMESTAMP,
    AT_UTF8,
    ArrowType,
)
from arrow_mlake.carrow import ARROW_FLAG_NULLABLE, CArrowSchema
from arrow_mlake.carrow_import import parquet_field_id, parse_format
from parquet.schema import ParquetSchema


@fieldwise_init
struct SchemaField(Copyable, Movable):
    """One field of a schema being checked."""

    var name: String
    var type: ArrowType
    var nullable: Bool
    var field_id: Int
    """-1 when the field has none."""
    var children: List[Int]
    """Indices into the tree's `fields`."""


struct SchemaTree(Movable):
    """A schema as a tree of fields in an arena, and how strictly to hold it
    to a table's."""

    var fields: List[SchemaField]
    var roots: List[Int]
    var whose: String
    """How the errors name it: "the worker's schema", "the file"."""
    var strict: Bool
    """A file's: field ids required, types as iceberg reads them."""

    def __init__(out self, var whose: String, strict: Bool):
        self.fields = List[SchemaField]()
        self.roots = List[Int]()
        self.whose = whose^
        self.strict = strict


def _cstr(addr: Int) -> String:
    if addr == 0:
        return String()
    return String(
        unsafe_from_utf8_ptr=Pointer[UInt8, ImmUntrackedOrigin](
            unsafe_from_address=addr
        )
    )


def _read_c(mut tree: SchemaTree, addr: Int, path: String) raises -> Int:
    """Reads the `ArrowSchema` at `addr` and its children into `tree`."""
    var s = Pointer[CArrowSchema, MutUntrackedOrigin](unsafe_from_address=addr)
    var name = _cstr(s[].name)
    var at = String(path, ".", name) if path else name
    var fmt = _cstr(s[].format)
    var t: ArrowType
    try:
        t = parse_format(fmt)
    except e:
        raise Error("column ", at, " has a type morca can't read: ", e)
    var kids = List[Int]()
    for i in range(Int(s[].n_children)):
        var child = Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=s[].children + 8 * i
        )[]
        kids.append(_read_c(tree, child, at))
    tree.fields.append(
        SchemaField(
            name,
            t^,
            (s[].flags & ARROW_FLAG_NULLABLE) != 0,
            Int(parquet_field_id(s[].metadata)),
            kids^,
        )
    )
    return len(tree.fields) - 1


def stream_tree(stream_schema: Int) raises -> SchemaTree:
    """The schema of a worker's stream, an `ArrowSchema` address."""
    var tree = SchemaTree("the worker's schema", False)
    var s = Pointer[CArrowSchema, MutUntrackedOrigin](
        unsafe_from_address=stream_schema
    )
    var fmt = _cstr(s[].format)
    if parse_format(fmt).id != AT_STRUCT:
        raise Error("the stream's schema isn't a struct of columns")
    for i in range(Int(s[].n_children)):
        var child = Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=s[].children + 8 * i
        )[]
        tree.roots.append(_read_c(tree, child, ""))
    return tree^


def file_tree(ps: ParquetSchema) -> SchemaTree:
    """The schema of a Parquet file, as parquet.mojo reads it to Arrow."""
    var tree = SchemaTree("the file", True)
    for f in ps.fields:
        tree.fields.append(
            SchemaField(
                f.name,
                f.type.copy(),
                f.nullable,
                Int(f.field_id),
                f.children.copy(),
            )
        )
    tree.roots = ps.roots.copy()
    return tree^


def check_schema(stream_schema: Int, table: Schema) raises:
    """Raises, naming the column, unless the stream's schema (an
    `ArrowSchema` address) fits `table` by the rule in
    docs/rust-workers.md."""
    var tree = stream_tree(stream_schema)
    check_tree(tree, table)


def check_tree(tree: SchemaTree, table: Schema) raises:
    """Raises, naming the column, unless `tree` fits `table`."""
    _fields_fit(tree, table.store, table.columns(), tree.roots, "")


def _fields_fit(
    tree: SchemaTree,
    store: TypeStore,
    want: List[NestedField],
    kids: List[Int],
    path: String,
) raises:
    for f in want:
        var at = String(path, ".", f.name) if path else f.name
        var found = -1
        for k in kids:
            if tree.fields[k].name == f.name:
                found = k
                break
        if found < 0:
            raise Error(
                "column ", at, " is in the table but not in ", tree.whose
            )
        ref g = tree.fields[found]
        if g.field_id < 0 and tree.strict:
            raise Error(
                "column ",
                at,
                " has no field id in ",
                tree.whose,
                ", and the table's is ",
                f.id,
                " (morca_worker::schema::to_arrow gives each field its id)",
            )
        if g.field_id >= 0 and g.field_id != f.id:
            raise Error(
                "column ",
                at,
                " has field id ",
                g.field_id,
                ", and the table's is ",
                f.id,
            )
        _nullable_fits(tree, f.required, g.nullable, at)
        _fits(tree, store, f.type, found, at)
    for k in kids:
        ref g = tree.fields[k]
        var known = False
        for f in want:
            if f.name == g.name:
                known = True
                break
        if not known:
            var at = String(path, ".", g.name) if path else g.name
            raise Error(
                "column ", at, " is in ", tree.whose, " but not in the table"
            )


def _nullable_fits(
    tree: SchemaTree, required: Bool, nullable: Bool, at: String
) raises:
    if required and nullable:
        raise Error(
            "column ",
            at,
            " is required in the table but nullable in ",
            tree.whose,
        )


def _fits(
    tree: SchemaTree, store: TypeStore, ti: Int, gi: Int, at: String
) raises:
    ref t = store.nodes[ti]
    ref g = tree.fields[gi]
    if t.kind == TK_PRIMITIVE:
        var want = arrow_type_of(store, ti)
        var ok = file_prim_fits(want, g.type) if tree.strict else prim_fits(
            want, g.type
        )
        if not ok:
            raise Error(
                "column ",
                at,
                " is ",
                g.type,
                " in ",
                tree.whose,
                ", which doesn't fit the table's ",
                primitive_name(t.prim),
            )
        return
    if t.kind == TK_STRUCT:
        if g.type.id != AT_STRUCT:
            raise Error(
                "column ",
                at,
                " is ",
                g.type,
                " in ",
                tree.whose,
                ", not a struct",
            )
        _fields_fit(tree, store, t.fields, g.children, at)
        return
    if t.kind == TK_LIST:
        if (g.type.id != AT_LIST and g.type.id != AT_LARGE_LIST) or len(
            g.children
        ) != 1:
            raise Error(
                "column ",
                at,
                " is ",
                g.type,
                " in ",
                tree.whose,
                ", not a list",
            )
        var p = String(at, ".element")
        _nullable_fits(
            tree, t.element_required, tree.fields[g.children[0]].nullable, p
        )
        _fits(tree, store, t.element, g.children[0], p)
        return
    if g.type.id != AT_MAP or len(g.children) != 1:
        raise Error(
            "column ", at, " is ", g.type, " in ", tree.whose, ", not a map"
        )
    ref kv = tree.fields[g.children[0]]
    if len(kv.children) != 2:
        raise Error(
            "column ", at, " is a map whose entries aren't key and value"
        )
    var k = kv.children[0]
    var v = kv.children[1]
    _nullable_fits(tree, True, tree.fields[k].nullable, String(at, ".key"))
    _fits(tree, store, t.key, k, String(at, ".key"))
    _nullable_fits(
        tree, t.value_required, tree.fields[v].nullable, String(at, ".value")
    )
    _fits(tree, store, t.value, v, String(at, ".value"))


def prim_fits(want: ArrowType, got: ArrowType) -> Bool:
    """Whether a primitive column of type `got` can be written to one the
    table stores as `want`: the same type, or one Iceberg widens to it."""
    var w = want.id
    var g = got.id
    if w == AT_INT32:
        return g == AT_INT8 or g == AT_INT16 or g == AT_INT32
    if w == AT_INT64:
        return g == AT_INT8 or g == AT_INT16 or g == AT_INT32 or g == AT_INT64
    if w == AT_FLOAT64:
        return g == AT_FLOAT32 or g == AT_FLOAT64
    if w == AT_UTF8:
        return g == AT_UTF8 or g == AT_LARGE_UTF8
    if w == AT_BINARY:
        return g == AT_BINARY or g == AT_LARGE_BINARY
    if w == AT_DECIMAL128:
        return (
            g == AT_DECIMAL128
            and got.scale == want.scale
            and got.precision <= want.precision
        )
    if w == AT_TIMESTAMP:
        return g == AT_TIMESTAMP and (got.tz.byte_length() > 0) == (
            want.tz.byte_length() > 0
        )
    if w == AT_TIME64:
        return g == AT_TIME64
    if w == AT_FIXED_SIZE_BINARY:
        return g == AT_FIXED_SIZE_BINARY and got.byte_width == want.byte_width
    return g == w


def file_prim_fits(want: ArrowType, got: ArrowType) -> Bool:
    """Whether a primitive column a Parquet file stores as `got` reads as the
    table's `want`: the same type (a timestamp or time in the same unit),
    or one iceberg's reader promotes: `int` to `long`, `float` to
    `double`, a decimal of the same scale and no more precision."""
    var w = want.id
    var g = got.id
    if w == AT_INT64:
        return g == AT_INT32 or g == AT_INT64
    if w == AT_FLOAT64:
        return g == AT_FLOAT32 or g == AT_FLOAT64
    if w == AT_DECIMAL128:
        return (
            g == AT_DECIMAL128
            and got.scale == want.scale
            and got.precision <= want.precision
        )
    if w == AT_TIMESTAMP:
        return (
            g == AT_TIMESTAMP
            and got.unit == want.unit
            and (got.tz.byte_length() > 0) == (want.tz.byte_length() > 0)
        )
    if w == AT_TIME64:
        return g == AT_TIME64 and got.unit == want.unit
    if w == AT_FIXED_SIZE_BINARY:
        return g == AT_FIXED_SIZE_BINARY and got.byte_width == want.byte_width
    return g == w
