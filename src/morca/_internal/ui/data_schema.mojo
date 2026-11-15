"""The Schema tab of a dataset's Data tab (#499): every column at the
commit shown, nested fields under the column they're in, each with its
field id, type, whether it may be null and its doc; then the schema's id
and how the table is partitioned."""

from json import Value

from morca._internal.html import Html


def _field_row(mut h: Html, f: Value, path: String, depth: Int) raises:
    var name = f.at("/name").string_value()
    var full = String(path, ".", name) if path else name
    h.raw("<tr>")
    h.num(f.at("/id").int_value())
    h.raw('<td class="dschema__name"')
    if depth:
        h.raw(' style="padding-left: ', Float64(depth) * 1.25 + 0.75, 'rem"')
    h.raw('><code title="')
    h.text(full)
    h.raw('">')
    h.text(name)
    h.raw("</code></td>")
    h.mono(f.at("/type").string_value())
    h.cell("no" if f.at("/required").bool_value() else "yes")
    var doc = f.at("/doc")
    h.cell(doc.string_value() if doc.is_string() else String())
    h.raw("</tr>")
    var kids = f.try_at("/fields")
    if kids:
        for k in kids.value().array_items():
            _field_row(h, k, full, depth + 1)


def schema_panel(mut h: Html, v: Value) raises:
    """The tab's content (the module doc), from the read's `schema` and
    `partition_spec`."""
    h.raw(
        '<div class="scroll"><table class="dschema"><thead><tr>',
        '<th class="num">Field id</th><th>Column</th><th>Type</th>',
        "<th>Nullable</th><th>Doc</th></tr></thead><tbody>",
    )
    for c in v.at("/schema/columns").array_items():
        _field_row(h, c, String(), 0)
    h.raw('</tbody></table></div><p class="card__sub">Schema ')
    h.text(v.at("/schema/schema_id").int_value())
    h.raw(". ")
    var fields = v.at("/partition_spec/fields").array_items()
    if len(fields) == 0:
        h.raw("Not partitioned.")
    else:
        h.raw("Partitioned by ")
        for i in range(len(fields)):
            ref f = fields[i]
            h.raw(", " if i else "", "<code>")
            h.text(f.at("/name").string_value())
            h.raw("</code> (")
            h.text(f.at("/transform").string_value(), " of ")
            h.raw("<code>")
            h.text(f.at("/source").string_value())
            h.raw("</code>, field ")
            h.text(f.at("/field_id").int_value())
            h.raw(")")
        h.raw(", spec ")
        h.text(v.at("/partition_spec/spec_id").int_value())
        h.raw(".")
    h.raw("</p>")
