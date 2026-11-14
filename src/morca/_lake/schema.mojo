"""Iceberg schemas and partition specs as `morca.tables` passes them to
liblake: their JSON, which the library parses. A schema's fields are the
library's reading of it (`Schema.fields`)."""

from morca._lake.abi import Dec, Slots
from morca._lake.client import api, take_bytes, take_error


# ── schemas and specs ───────────────────────────────────────────────────────


@fieldwise_init
struct SchemaField(Copyable, Movable, Writable):
    """A field of a schema, nested ones included, as iceberg's
    `AccessorField` shows it."""

    var id: Int
    var name: String
    """Dotted for a nested field: `a.b`, `tags.element`, `m.key`."""
    var type: String
    """Its Iceberg type as JSON: `"long"` for a primitive (quoted), an
    object for a struct, list or map."""
    var required: Bool
    var parent_id: Int
    """The id of the field it's nested in, or -1 for a top-level column."""


struct Schema(Copyable, Movable, Writable):
    """An Iceberg schema, as its JSON (the spec's Appendix C). The library
    parses it; a schema that doesn't parse fails the call it's given to."""

    var json: String

    def __init__(out self, var json: String):
        self.json = json^

    @staticmethod
    def parse(text: String) -> Schema:
        return Schema(text.copy())

    def to_json(self) -> String:
        return self.json.copy()

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.json)

    def fields(self) raises -> List[SchemaField]:
        """Every field, nested ones after the field they're in; raises if the
        schema doesn't parse."""
        var a = api()
        var got = Slots()
        var err = Slots()
        var rc = a.schema_fields(
            Int(self.json.unsafe_ptr()), self.json.byte_length(), got.addr, err.addr
        )
        if rc != 0:
            raise take_error(a, err)
        var b = take_bytes(a, got)
        var d = Dec(Int(b.unsafe_ptr()), len(b))
        var out = List[SchemaField]()
        for _ in range(Int(d.int())):
            var id = Int(d.int())
            var name = d.str()
            var type = d.str()
            var required = d.bool()
            out.append(SchemaField(id, name^, type^, required, Int(d.int())))
        _ = b^
        return out^

    def columns(self) raises -> List[SchemaField]:
        """The top-level fields only."""
        var out = List[SchemaField]()
        for f in self.fields():
            if f.parent_id < 0:
                out.append(f.copy())
        return out^

    def find_field(self, id: Int) raises -> SchemaField:
        """The field with id `id`, at any depth; raises if there's none."""
        for f in self.fields():
            if f.id == id:
                return f.copy()
        raise Error("morca: no field with id ", id)

    def has_field(self, id: Int) -> Bool:
        """Whether a field has id `id` (False too if the schema doesn't
        parse)."""
        try:
            for f in self.fields():
                if f.id == id:
                    return True
        except:
            pass
        return False

    def find_by_name(self, name: String) raises -> SchemaField:
        """The field named `name` (dotted for a nested one); raises if
        there's none, as iceberg's does."""
        for f in self.fields():
            if f.name == name:
                return f.copy()
        raise Error("morca: no field named '", name, "'")

    def has_field_named(self, name: String) -> Bool:
        try:
            for f in self.fields():
                if f.name == name:
                    return True
        except:
            pass
        return False


@fieldwise_init
struct PartitionField(Copyable, Movable):
    """One field of a partition spec: the source column's id, the partition
    field's own id (1000 and up), its name and transform (`identity`,
    `day`, `bucket[16]`, ...)."""

    var source_id: Int
    var field_id: Int
    var name: String
    var transform: String

    @staticmethod
    def single(
        source_id: Int, field_id: Int, var name: String, var transform: String
    ) -> Self:
        """As iceberg's `PartitionField.single` is called."""
        return Self(source_id, field_id, name^, transform^)


def parse_transform(s: String) -> String:
    """A transform, as iceberg's `parse_transform` is called; the library
    parses it."""
    return s.copy()


struct PartitionSpec(Copyable, Movable):
    """An Iceberg partition spec, as its JSON."""

    var json: String

    def __init__(out self, var json: String):
        self.json = json^

    def __init__(out self, spec_id: Int, fields: List[PartitionField]):
        var j = String('{"spec-id":', spec_id, ',"fields":[')
        for k in range(len(fields)):
            ref f = fields[k]
            j.write(
                "," if k > 0 else "",
                '{"source-id":',
                f.source_id,
                ',"field-id":',
                f.field_id,
                ',"name":"',
                f.name,
                '","transform":"',
                f.transform,
                '"}',
            )
        j.write("]}")
        self.json = j^

    @staticmethod
    def unpartitioned(spec_id: Int = 0) -> Self:
        return Self(spec_id, List[PartitionField]())

    @staticmethod
    def parse(text: String) -> Self:
        return Self(text.copy())

    def to_json(self) -> String:
        return self.json.copy()
