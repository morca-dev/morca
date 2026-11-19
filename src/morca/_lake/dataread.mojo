"""The UI's data view of a dataset, read with iceberg (#435): what
`morca_maintain data <dataset>` prints, as JSON, for
`morca._internal.views.data`.

The `morca` binary doesn't link iceberg, so the UI runs this in the
project's `morca_maintain` (as `morca expire` does), a short-lived process
it kills past its time limit. It runs inside liblake (`lake_data`, #471),
so `morca_maintain` compiles no iceberg either. What it reads:

- **the table**: its schema (columns, types, field ids and docs), its
  partition spec and its snapshots, newest first, from the metadata alone;
- **partitions**: one row per partition of the snapshot, with its rows,
  files, bytes and the snapshot that last added a file to it, from the
  manifests alone;
- **rows**: a page of rows at the snapshot, with `--where` filters (on any
  top-level column, partition source columns included, so iceberg prunes
  partitions and files), a column pick and a sort, from `--offset`;
- **a chart**: the filtered rows' `--chart-y` columns, averaged (or summed)
  by `--chart-x`;
- **a download**: the filtered rows as CSV, to `--csv <path>`.

Each read stops at its cap, its time limit or its memory limit, and says
which in `stopped`; what it read up to then is still shown. A sort holds
every row it reads, so the memory limit is what bounds it.

    morca_maintain data <dataset> [--snapshot ID] [--where COL:OP:VALUE]...
        [--columns A,B] [--sort COL|-COL] [--offset N] [--limit N]
        [--chart-x COL --chart-y A,B [--chart-agg avg|sum]]
        [--csv PATH] [--max-rows N] [--seconds S] [--memory-mb M]
        [--no-partitions] [--no-rows]

`OP` is `eq`, `ne`, `lt`, `le`, `gt`, `ge` or `in` (values split on `,`).
"""

from std.time import perf_counter_ns

from iceberg.catalog.filesystem import Table
from iceberg.json import json_quote
from iceberg.manifest import (
    CONTENT_DATA,
    MANIFEST_CONTENT_DATA,
    STATUS_DELETED,
    Manifest,
    ManifestCache,
    ManifestFile,
    read_manifest_bytes_cached,
    read_manifest_io_cached,
    read_manifest_list_bytes_cached,
)
from iceberg.metadata import Snapshot
from iceberg.types import TK_LIST, TK_MAP, TK_PRIMITIVE, TK_STRUCT, TypeStore

from morca._lake.datacache import DataCache
from morca._lake.dataask import DataAsk, columns_of, iso_ms, parse_ask
from morca._lake.datarows import chart_json, csv_json, rows_json
from morca._lake.impl import load_dataset

comptime SNAPSHOTS_SHOWN = 100
comptime PARTITIONS_SHOWN = 1000
comptime MANIFEST_BYTES = 256 << 20
"""How many bytes of manifests a read holds, to plan with more than once."""


def table_json(t: Table, snapshot: Int64, mut out: String) raises:
    """The schema, the partition spec and the snapshots, as fields of the
    object `out` is writing (no braces)."""
    ref m = t.metadata
    var scan = t.scan()
    if snapshot >= 0:
        scan = scan.use_snapshot(snapshot)
    var schema = scan.current_schema()
    out.write(
        '"snapshot": ',
        String(scan.snapshot().snapshot_id) if scan.has_any_snapshot() else (
            String("null")
        ),
        ', "current": ',
        String(m.current_snapshot_id) if m.has_current_snapshot else String(
            "null"
        ),
        ', "schema": {"schema_id": ',
        schema.schema_id,
        ', "columns": [',
    )
    var cols = columns_of(schema)
    var top = schema.columns()
    for i in range(len(cols)):
        ref c = cols[i]
        out.write(
            ", " if i else "",
            '{"id": ',
            c.id,
            ', "name": ',
            json_quote(c.name),
            ', "type": ',
            json_quote(c.type),
            ', "required": ',
            "true" if c.required else "false",
            ', "doc": ',
            json_quote(c.doc) if c.doc else String("null"),
        )
        _fields_json(schema.store, top[i].type, out)
        out.write("}")
    var spec = m.spec()
    out.write(
        ']}, "partition_spec": {"spec_id": ', spec.spec_id, ', "fields": ['
    )
    for i in range(len(spec.fields)):
        ref f = spec.fields[i]
        out.write(
            ", " if i else "",
            '{"field_id": ',
            f.field_id,
            ', "name": ',
            json_quote(f.name),
            ', "source_id": ',
            f.source_id,
            ', "source": ',
            json_quote(m.schema().name_of(f.source_id)),
            ', "transform": ',
            json_quote(String(f.transform)),
            "}",
        )
    out.write(']}, "snapshots": [')
    var n = 0
    var k = len(m.snapshots) - 1
    while k >= 0 and n < SNAPSHOTS_SHOWN:
        ref s = m.snapshots[k]
        out.write(
            ", " if n else "",
            '{"snapshot": ',
            s.snapshot_id,
            ', "at": ',
            json_quote(iso_ms(s.timestamp_ms)),
            ', "operation": ',
            json_quote(s.operation()),
            ', "added_records": ',
            s.summary_int("added-records", 0),
            ', "total_records": ',
            s.summary_int("total-records", -1),
            ', "run": ',
            json_quote(s.summary.get("orca.run", "")),
            ', "partitions": ',
            json_quote(s.summary.get("orca.partitions", "")),
            "}",
        )
        n += 1
        k -= 1
    out.write("], ", '"snapshots_total": ', len(m.snapshots))


def _field_json(
    store: TypeStore,
    id: Int,
    name: String,
    type: Int,
    required: Bool,
    doc: String,
    mut out: String,
):
    out.write(
        '{"id": ',
        id,
        ', "name": ',
        json_quote(name),
        ', "type": ',
        json_quote(store.type_name(type)),
        ', "required": ',
        "true" if required else "false",
        ', "doc": ',
        json_quote(doc) if doc else String("null"),
    )
    _fields_json(store, type, out)
    out.write("}")


def _fields_json(store: TypeStore, type: Int, mut out: String):
    """A nested type's own fields, as `, "fields": [...]` (a struct's, a
    list's element, a map's key and value), each with its own; nothing for
    a primitive."""
    ref n = store.nodes[type]
    if n.kind == TK_PRIMITIVE:
        return
    out.write(', "fields": [')
    if n.kind == TK_STRUCT:
        for i in range(len(n.fields)):
            ref f = n.fields[i]
            if i:
                out.write(", ")
            _field_json(
                store,
                f.id,
                f.name,
                f.type,
                f.required,
                f.doc if f.has_doc else String(),
                out,
            )
    elif n.kind == TK_LIST:
        _field_json(
            store,
            n.element_id,
            "element",
            n.element,
            n.element_required,
            String(),
            out,
        )
    elif n.kind == TK_MAP:
        _field_json(store, n.key_id, "key", n.key, True, String(), out)
        out.write(", ")
        _field_json(
            store, n.value_id, "value", n.value, n.value_required, String(), out
        )
    out.write("]")


# ── partitions, from the manifests ───────────────────────────────────────────


struct _Part(Copyable, Movable):
    var key: String
    """The partition's values as a JSON object."""
    var rows: Int64
    var files: Int
    var bytes: Int64
    var last: Int64
    var last_ms: Int64

    def __init__(out self, key: String):
        self.key = key
        self.rows = 0
        self.files = 0
        self.bytes = 0
        self.last = -1
        self.last_ms = -1


def warm_manifests(
    t: Table, snap: Snapshot, mut cache: ManifestCache, mut disk: DataCache
) raises -> List[ManifestFile]:
    """The snapshot's manifest list, with the bytes of every manifest it
    names in `cache`, for `partitions_json` and the rows' plan to share:
    from `disk` where it has them, the rest fetched at once and kept there.
    A manifest's bytes never change, so they're kept by its location."""
    var mfs = List[ManifestFile]()
    var got = disk.get(snap.manifest_list)
    var parsed = False
    if got:
        # A kept list that doesn't parse is a miss: removed, fetched again.
        try:
            mfs = read_manifest_list_bytes_cached(got.value().copy(), cache)
            cache.keep_file(snap.manifest_list, Span(got.value()))
            parsed = True
        except:
            disk.drop(snap.manifest_list)
    if not parsed:
        var lst = t.io.read_all(snap.manifest_list)
        disk.put(snap.manifest_list, Span(lst))
        cache.keep_file(snap.manifest_list, Span(lst))
        mfs = read_manifest_list_bytes_cached(lst^, cache)
    var missing = List[String]()
    for mf in mfs:
        if cache.has_file(mf.manifest_path):
            continue
        var d = disk.get(mf.manifest_path)
        if d:
            cache.keep_file(mf.manifest_path, Span(d.value()))
        else:
            missing.append(mf.manifest_path)
    var fetched = t.io.read_all_many(missing)
    for i in range(len(missing)):
        disk.put(missing[i], Span(fetched[i]))
        cache.keep_file(missing[i], Span(fetched[i]))
    return mfs^


def _manifest(
    t: Table, mf: ManifestFile, mut cache: ManifestCache
) raises -> Manifest:
    if cache.has_file(mf.manifest_path):
        return read_manifest_bytes_cached(
            cache.file(mf.manifest_path), mf, cache
        )
    return read_manifest_io_cached(t.io, mf.manifest_path, mf, cache)


def partitions_json(
    t: Table,
    snapshot: Int64,
    mut cache: ManifestCache,
    mut disk: DataCache,
    mut out: String,
) raises:
    """`"partitions": [...]` of the snapshot: a row per partition, newest
    partition values first, from its data manifests; kept in `disk` by the
    table and the snapshot, which never change."""
    var scan = t.scan()
    if snapshot >= 0:
        scan = scan.use_snapshot(snapshot)
    if not scan.has_any_snapshot():
        out.write('"partitions": [], "partitions_total": 0')
        return
    var snap = scan.snapshot()
    var key = String(
        "partitions-", t.metadata.table_uuid, "-", snap.snapshot_id, ".json"
    )
    var kept = disk.get_text(key)
    if kept:
        if _partitions_shape(kept.value()):
            out.write(kept.value())
            return
        disk.drop(key)
    var mfs: List[ManifestFile]
    if snap.manifest_list:
        mfs = warm_manifests(t, snap, cache, disk)
    else:
        mfs = List[ManifestFile]()
    var text = _partitions(t, mfs, cache)
    if t.metadata.table_uuid and snap.manifest_list:
        disk.put_text(key, text)
    out.write(text)


def _partitions_shape(text: String) -> Bool:
    """Whether kept partitions look as `_partitions` writes them."""
    if not text.startswith('"partitions": [') or (
        '], "partitions_total": ' not in text
    ):
        return False
    try:
        _ = Int(text[byte = text.rfind(" ").or_else(-1) + 1 :])
        return True
    except:
        return False


def _partitions(
    t: Table, mfs: List[ManifestFile], mut cache: ManifestCache
) raises -> String:
    ref m = t.metadata
    var out = String('"partitions": [')
    var parts = List[_Part]()
    var index = Dict[String, Int]()
    for mf in mfs:
        if mf.content != MANIFEST_CONTENT_DATA:
            continue
        var man = _manifest(t, mf, cache)
        ref spec = man.partition_spec
        for e in man.entries:
            if e.status == STATUS_DELETED:
                continue
            ref df = e.data_file
            if df.content != CONTENT_DATA:
                continue
            var key = String("{")
            for k in range(min(len(spec.fields), len(df.partition))):
                key.write(
                    ", " if k else "",
                    json_quote(spec.fields[k].name),
                    ": ",
                    df.partition[k].to_json(),
                )
            key.write("}")
            var at = index.get(key, -1)
            if at < 0:
                at = len(parts)
                index[key] = at
                parts.append(_Part(key))
            ref p = parts[at]
            p.rows += df.record_count
            p.files += 1
            p.bytes += df.file_size_in_bytes
            var sid = (
                e.snapshot_id if e.has_snapshot_id else mf.added_snapshot_id
            )
            var i = m.snapshot_index(sid)
            var ms = m.snapshots[i].timestamp_ms if i >= 0 else Int64(-1)
            if ms > p.last_ms or p.last < 0:
                p.last = sid
                p.last_ms = ms
    # Newest values first: the keys compare as text, which orders dates,
    # and numbers of a width, as the values do.
    var order = List[Int]()
    for i in range(len(parts)):
        order.append(i)
    _sort_text_desc(order, parts)
    for n in range(min(len(order), PARTITIONS_SHOWN)):
        ref p = parts[order[n]]
        out.write(
            ", " if n else "",
            '{"partition": ',
            p.key,
            ', "rows": ',
            p.rows,
            ', "files": ',
            p.files,
            ', "bytes": ',
            p.bytes,
            ', "last_snapshot": ',
            p.last,
            ', "last_at": ',
            json_quote(iso_ms(p.last_ms)) if p.last_ms >= 0 else String("null"),
            "}",
        )
    out.write('], "partitions_total": ', len(parts))
    return out^


def _sort_text_desc(mut order: List[Int], parts: List[_Part]):
    """Insertion sort of `order` by the parts' keys, descending; a table's
    partitions are few enough (`PARTITIONS_SHOWN` shown)."""
    for i in range(1, len(order)):
        var v = order[i]
        var j = i - 1
        while j >= 0 and _num_aware_less(parts[order[j]].key, parts[v].key):
            order[j + 1] = order[j]
            j -= 1
        order[j + 1] = v


def _num_aware_less(a: String, b: String) -> Bool:
    """`a` before `b` as text, but a shorter run of digits is the smaller
    number (`{"lead": 6}` before `{"lead": 24}`)."""
    var x = a.as_bytes()
    var y = b.as_bytes()
    var i = 0
    var j = 0
    while i < len(x) and j < len(y):
        var dx = _digits(x, i)
        var dy = _digits(y, j)
        if dx > 0 and dy > 0:
            if dx != dy:
                return dx < dy
            for k in range(dx):
                if x[i + k] != y[j + k]:
                    return x[i + k] < y[j + k]
            i += dx
            j += dy
            continue
        if x[i] != y[j]:
            return x[i] < y[j]
        i += 1
        j += 1
    return len(x) - i < len(y) - j


def _digits(b: Span[Byte, _], at: Int) -> Int:
    var n = 0
    while at + n < len(b) and b[at + n] >= 48 and b[at + n] <= 57:
        n += 1
    return n


# ── the command ──────────────────────────────────────────────────────────────


struct _Phases(Movable):
    """How long each part of a read took, and the requests it made: the
    JSON's `timings`."""

    var t: Int
    var requests: Int
    var json: String

    def __init__(out self):
        self.t = Int(perf_counter_ns())
        self.requests = 0
        self.json = String()

    def mark(mut self, name: StaticString, t: Table):
        var now = Int(perf_counter_ns())
        var n = t.io.counts().requests()
        self.json.write(
            ", " if self.json else "",
            '"',
            name,
            '": {"seconds": ',
            Float64(now - self.t) / 1e9,
            ', "requests": ',
            n - self.requests,
            "}",
        )
        self.t = now
        self.requests = n


def data_json(a: DataAsk) raises -> String:
    """What `morca_maintain data` prints for `a`. A read that fails on what
    the disk cache gave it, not on a mistake in what was asked (a `morca:`
    error), is read again without it, and what it used is removed."""
    var disk = DataCache.from_env()
    try:
        return _data_json(a, disk)
    except e:
        if len(disk.used) == 0 or String(e).startswith("morca:"):
            raise e^
        for k in disk.used:
            disk.drop(k)
        disk.used = List[String]()
        disk.reading = False
        return _data_json(a, disk)


def _data_json(a: DataAsk, mut disk: DataCache) raises -> String:
    var ph = _Phases()
    var t = load_dataset(a.dataset)
    ph.mark("load", t)
    # One cache of manifests for the partitions, the rows and the chart,
    # which all plan the same snapshot; and the one on disk, across reads.
    var cache = ManifestCache()
    cache.max_file_bytes = MANIFEST_BYTES
    var out = String('{"dataset": ', json_quote(a.dataset), ", ")
    var scan = t.scan()
    if a.snapshot >= 0:
        scan = scan.use_snapshot(a.snapshot)
    if scan.has_any_snapshot() and scan.snapshot().manifest_list:
        _ = warm_manifests(t, scan.snapshot(), cache, disk)
    ph.mark("manifests", t)
    if a.csv:
        csv_json(t, a, cache, out)
        out.write("}")
        disk.prune()
        return out^
    table_json(t, a.snapshot, out)
    ph.mark("table", t)
    if a.partitions:
        out.write(", ")
        partitions_json(t, a.snapshot, cache, disk, out)
        ph.mark("partitions", t)
    if a.rows:
        out.write(", ")
        rows_json(t, a, cache, out)
        ph.mark("rows", t)
    if a.chart_x:
        out.write(", ")
        try:
            chart_json(t, a, cache, out)
        except e:
            out.write('"chart": {"error": ', json_quote(String(e)), "}")
        ph.mark("chart", t)
    out.write(', "timings": {', ph.json, "}}")
    disk.prune()
    return out^


def data_text(args: List[String]) raises -> String:
    """What `morca_maintain data ...` prints: the JSON, or on a mistake in
    what was asked for (a column the table hasn't, a value of the wrong
    type) `{"error": ...}`, and exit 0, since the UI shows it. Raises only
    on arguments it can't parse. Runs inside liblake (`lake_data`)."""
    var a = parse_ask(args)
    try:
        return data_json(a)
    except e:
        var msg = String(e)
        return String('{"error": ', json_quote(msg), "}")
