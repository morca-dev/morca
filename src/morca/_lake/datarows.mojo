"""The rows of the UI's data view (#435, `morca._lake.dataread`): a
page of the filtered rows, in a sort's order; the chart of them; and the
download, as CSV. Each read stops at its cap, its time limit or its memory
limit, and says which in `stopped`; a sort holds every row it reads, so the
memory limit is what bounds it."""

from std.time import perf_counter_ns

from arrow_mlake.arrow import (
    AT_LARGE_LIST,
    AT_LIST,
    AT_MAP,
    AT_STRUCT,
    ArrayArena,
    bit_get,
)
from iceberg.catalog.filesystem import Table
from iceberg.json import json_quote
from iceberg.read import ScanOptions
from iceberg.manifest import ManifestCache
from iceberg.scan import TRUE_RESIDUAL, FileScanTask, TableScan
from iceberg.types import P_DOUBLE, P_FLOAT
from iceberg.values import iso_text
from parquet import RecordBatch
from parquet.display import scalar_json

from morca._lake.datacache import write_file
from morca._lake.dataask import (
    NESTED,
    Column,
    DataAsk,
    columns_of,
    filter_dsl,
    find_column,
    is_numeric,
    is_time,
)

comptime CHART_POINTS = 2000
"""Distinct x values a chart keeps; past it the chart stops."""


# ── rows ─────────────────────────────────────────────────────────────────────


def _valid(arena: ArrayArena, node: Int, i: Int) -> Bool:
    ref a = arena.nodes[node]
    if a.null_count == 0 or len(a.validity) == 0:
        return True
    return bit_get(Span(a.validity), i)


def _nested_json(arena: ArrayArena, node: Int, i: Int) raises -> String:
    """A struct, list or map value as JSON; its nulls checked against the
    validity each array has, or hasn't."""
    if not _valid(arena, node, i):
        return String("null")
    ref a = arena.nodes[node]
    var id = a.type.id
    if id == AT_LIST or id == AT_LARGE_LIST:
        var lo = Int(a.offsets[i]) if id == AT_LIST else Int(a.large_offsets[i])
        var hi = Int(a.offsets[i + 1]) if id == AT_LIST else Int(
            a.large_offsets[i + 1]
        )
        var out = String("[")
        for k in range(lo, hi):
            out.write(
                "," if k > lo else "", _nested_json(arena, a.children[0], k)
            )
        out.write("]")
        return out^
    if id == AT_MAP:
        var lo = Int(a.offsets[i])
        var hi = Int(a.offsets[i + 1])
        ref entries = arena.nodes[a.children[0]]
        var out = String("[")
        for k in range(lo, hi):
            out.write(
                "," if k > lo else "",
                "[",
                _nested_json(arena, entries.children[0], k),
                ",",
                _nested_json(arena, entries.children[1], k),
                "]",
            )
        out.write("]")
        return out^
    if id == AT_STRUCT:
        var out = String("{")
        for k in range(len(a.children)):
            var c = a.children[k]
            out.write(
                "," if k else "",
                json_quote(arena.nodes[c].name),
                ":",
                _nested_json(arena, c, i),
            )
        out.write("}")
        return out^
    return scalar_json(a, i)


def cell_json(b: RecordBatch, c: Int, i: Int, kind: UInt8) raises -> String:
    """Row `i` of column `c` as a JSON value: dates and times as ISO text,
    a nested value as JSON."""
    var node = b.roots[c]
    if not _valid(b.arena, node, i):
        return String("null")
    if kind == NESTED:
        return _nested_json(b.arena, node, i)
    var s = scalar_json(b.column(c), i)
    if is_time(kind):
        return json_quote(iso_text(kind, Int64(Int(s))))
    if (kind == P_DOUBLE or kind == P_FLOAT) and ("n" in s or "i" in s):
        # NaN and the infinities, which JSON has no number for.
        return json_quote(s)
    return s^


def _bytes(b: RecordBatch) -> Int:
    var n = 0
    for a in b.arena.nodes:
        n += (
            len(a.values)
            + len(a.validity)
            + 4 * len(a.offsets)
            + 8 * len(a.large_offsets)
        )
    return n


@fieldwise_init
struct _Key(Copyable, Movable):
    var null: Bool
    var num: Float64
    var text: String


def _key_of(cell: String, kind: UInt8) -> _Key:
    if cell == "null":
        return _Key(True, 0, String())
    if is_numeric(kind):
        try:
            var s = cell.strip('"')
            return _Key(False, Float64(s), String())
        except:
            pass
    return _Key(False, 0, cell)


def _before(a: _Key, b: _Key, numeric: Bool, desc: Bool) -> Bool:
    """Whether `a` sorts strictly before `b`; nulls last either way."""
    if a.null or b.null:
        return not a.null and b.null
    if numeric:
        return a.num > b.num if desc else a.num < b.num
    return a.text > b.text if desc else a.text < b.text


def _merge_sort(
    mut order: List[Int], keys: List[_Key], numeric: Bool, desc: Bool
):
    """A stable sort of `order` by `keys`."""
    var n = len(order)
    var tmp = List[Int](length=n, fill=0)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                if _before(keys[order[j]], keys[order[i]], numeric, desc):
                    tmp[k] = order[j]
                    j += 1
                else:
                    tmp[k] = order[i]
                    i += 1
                k += 1
            while i < mid:
                tmp[k] = order[i]
                i += 1
                k += 1
            while j < hi:
                tmp[k] = order[j]
                j += 1
                k += 1
            lo += 2 * width
        for x in range(n):
            order[x] = tmp[x]
        width *= 2


struct _Clock:
    var t0: Int
    var limit: Float64

    def __init__(out self, limit: Float64):
        self.t0 = Int(perf_counter_ns())
        self.limit = limit

    def seconds(self) -> Float64:
        return Float64(Int(perf_counter_ns()) - self.t0) / 1e9

    def over(self) -> Bool:
        return self.limit > 0 and self.seconds() > self.limit


def _time_stop(seconds: Float64) -> String:
    return String(
        "the scan stopped at its time limit, ",
        String(Int(seconds)) if seconds >= 1 else String(seconds),
        " s (MORCA_DATA_SECONDS)",
    )


def _memory_stop(mb: Float64) -> String:
    return String(
        "the scan stopped at its memory limit, ",
        String(Int(mb)) if mb >= 1 else String(mb),
        " MB (MORCA_DATA_MEMORY_MB)",
    )


def _scan_of(t: Table, a: DataAsk, cols: List[Column]) raises -> TableScan:
    var scan = t.scan()
    if a.snapshot >= 0:
        scan = scan.use_snapshot(a.snapshot)
    return scan.filter(filter_dsl(cols, a.wheres))


comptime GROUP_FILES = 16
"""Data files read together, at most: their footers in one round of
requests and their chunks in the next, instead of a round each."""
comptime GROUP_BYTES = 8 << 20
"""Their size together, at most; a file bigger than this is read alone,
stopping at the rows wanted."""


def _countable(t: FileScanTask) -> Bool:
    """Whether the file's `record_count` is the rows the scan gets from it
    (iceberg's own test for a count from the metadata)."""
    return (
        len(t.delete_files) == 0
        and t.residual == TRUE_RESIDUAL
        and t.start == 0
        and t.length == t.data_file.file_size_in_bytes
        and t.data_file.record_count > 0
    )


struct _TaskReader(Movable):
    """The planned files' batches in the scan's order, up to `want` rows
    from its start, files that are all before `skip` passed over by their
    counts. Small files are read together (`GROUP_FILES`, `GROUP_BYTES`),
    since a table of many small appends would otherwise cost two rounds of
    requests a file; a big one alone, with the rows still wanted as its
    limit, so the reader stops inside it."""

    var scan: TableScan
    var tasks: List[FileScanTask]
    var next_task: Int
    var want: Int
    var skip: Int
    var at: Int
    """Rows of the scan before the next batch: those skipped by count and
    those handed out."""
    var skipped: Int
    var pending: List[RecordBatch]
    """The group's batches not handed out yet, reversed."""

    def __init__(
        out self,
        scan: TableScan,
        var tasks: List[FileScanTask],
        want: Int,
        skip: Int = 0,
    ):
        self.scan = scan.copy()
        self.tasks = tasks^
        self.next_task = 0
        self.want = want
        self.skip = skip
        self.at = 0
        self.skipped = 0
        self.pending = List[RecordBatch]()

    def _fill(mut self) raises -> Bool:
        while self.next_task < len(self.tasks) and self.at < self.want:
            ref first = self.tasks[self.next_task]
            if (
                _countable(first)
                and self.at + Int(first.data_file.record_count) <= self.skip
            ):
                var n = Int(first.data_file.record_count)
                self.at += n
                self.skipped += n
                self.next_task += 1
                continue
            var lo = self.next_task
            var hi = lo + 1
            var bytes = Int(first.data_file.file_size_in_bytes)
            var known = Int(first.data_file.record_count) if _countable(
                first
            ) else 0
            while (
                hi < len(self.tasks)
                and hi - lo < GROUP_FILES
                and self.at + known < self.want
            ):
                ref t = self.tasks[hi]
                var b = Int(t.data_file.file_size_in_bytes)
                if bytes + b > GROUP_BYTES:
                    break
                bytes += b
                if _countable(t):
                    known += Int(t.data_file.record_count)
                hi += 1
            var group = List[FileScanTask]()
            for k in range(lo, hi):
                group.append(self.tasks[k].copy())
            var o = ScanOptions()
            o.num_workers = 1
            o.files_at_once = hi - lo
            if hi - lo == 1:
                o.limit = self.want - self.at
            var got = self.scan.to_batches_for_tasks(group^, o)
            self.next_task = hi
            var n = len(got)
            for _ in range(n):
                self.pending.append(got.pop())
            if n > 0:
                return True
        return False

    def next_batch(mut self) raises -> Optional[RecordBatch]:
        if len(self.pending) == 0 and not self._fill():
            return None
        var b = self.pending.pop()
        self.at += b.num_rows
        return Optional[RecordBatch](b^)


def _batch_columns(
    b: RecordBatch, names: List[String], cols: List[Column]
) raises -> List[Tuple[Int, UInt8]]:
    """Each name's column in `b`, with its kind."""
    var out = List[Tuple[Int, UInt8]]()
    for n in names:
        var at = -1
        for i in range(b.num_columns()):
            if b.name(i) == n:
                at = i
        if at < 0:
            raise Error("morca: the scan didn't return column ", n)
        out.append((at, cols[find_column(cols, n)].kind))
    return out^


struct _Rows(Movable):
    """The page `_read_rows` read: its columns, and the cells of its rows
    in order, each a JSON value."""

    var columns: List[Column]
    var cells: List[List[String]]
    var order: List[Int]
    var lo: Int
    var hi: Int
    var more: Bool
    var files: Int
    var scanned: Int
    var stopped: String
    var filter: String
    var seconds: Float64
    var plan_seconds: Float64

    def __init__(out self):
        self.columns = List[Column]()
        self.cells = List[List[String]]()
        self.order = List[Int]()
        self.lo = 0
        self.hi = 0
        self.more = False
        self.files = 0
        self.scanned = 0
        self.stopped = String()
        self.filter = String()
        self.seconds = 0
        self.plan_seconds = 0


def _read_rows(t: Table, a: DataAsk, mut cache: ManifestCache) raises -> _Rows:
    """The page of rows at `a.offset`, `a.limit` long, of the filtered rows
    in the sort's order (the scan's without one)."""
    var full = t.scan()
    if a.snapshot >= 0:
        full = full.use_snapshot(a.snapshot)
    var cols = columns_of(full.current_schema())
    var shown = a.columns.copy()
    if len(shown) == 0:
        for c in cols:
            shown.append(c.name)
    var r = _Rows()
    for n in shown:
        var k = find_column(cols, n)
        if k < 0:
            raise Error("morca: the table has no column ", n)
        r.columns.append(cols[k].copy())
    var desc = a.sort.startswith("-")
    var sort_col = String(a.sort[byte=1:]) if desc else a.sort.copy()
    var read = shown.copy()
    if sort_col:
        if find_column(cols, sort_col) < 0:
            raise Error("morca: the table has no column ", sort_col)
        if sort_col not in read:
            read.append(sort_col)
    r.filter = filter_dsl(cols, a.wheres)
    var scan = _scan_of(t, a, cols).select(read.copy())
    var clock = _Clock(a.seconds)
    var tasks = scan.plan_files_with(cache)
    r.files = len(tasks)
    r.plan_seconds = clock.seconds()
    var cap = Int(a.memory_mb * 1024 * 1024)
    var held = 0
    var keys = List[_Key]()
    var sort_kind = cols[
        find_column(cols, sort_col)
    ].kind if sort_col else UInt8(0)
    var sort_at = shown.index(sort_col) if sort_col in shown else -1
    # Without a sort, the rows past the page are never read; with one,
    # every filtered row is, up to max_rows.
    var want = a.offset + a.limit + 1 if not sort_col else a.max_rows + 1
    var reader = _TaskReader(
        scan, tasks^, want, skip=a.offset if not sort_col else 0
    )
    var done = False
    while not done:
        if clock.over():
            r.stopped = _time_stop(a.seconds)
            break
        var got = reader.next_batch()
        guard case .Some(b) = got else:
            break
        if _bytes(b) + held > cap:
            r.stopped = _memory_stop(a.memory_mb)
            break
        var at = _batch_columns(b, read, cols)
        for i in range(b.num_rows):
            var n = reader.skipped + r.scanned
            r.scanned += 1
            if not sort_col:
                if n < a.offset:
                    continue
                if n >= a.offset + a.limit:
                    r.more = True
                    done = True
                    break
            elif n >= a.max_rows:
                r.stopped = String(
                    "sorted the first ",
                    a.max_rows,
                    " filtered rows only (MORCA_DATA_SORT_ROWS)",
                )
                done = True
                break
            var row = List[String]()
            for k in range(len(shown)):
                var c = cell_json(b, at[k][0], i, at[k][1])
                held += c.byte_length() + 24
                row.append(c^)
            if sort_col:
                var s = row[sort_at].copy() if sort_at >= 0 else cell_json(
                    b, at[len(at) - 1][0], i, sort_kind
                )
                held += s.byte_length() + 32
                keys.append(_key_of(s, sort_kind))
            r.cells.append(row^)
        if not done and held > cap:
            r.stopped = _memory_stop(a.memory_mb)
            break
    for i in range(len(r.cells)):
        r.order.append(i)
    r.lo = 0
    r.hi = len(r.cells)
    if sort_col:
        _merge_sort(r.order, keys, is_numeric(sort_kind), desc)
        r.lo = min(a.offset, len(r.order))
        r.hi = min(a.offset + a.limit, len(r.order))
        r.more = len(r.order) > r.hi
    r.seconds = clock.seconds()
    return r^


def rows_json(
    t: Table, a: DataAsk, mut cache: ManifestCache, mut out: String
) raises:
    """`"rows": {...}`: `_read_rows`' page."""
    var r = _read_rows(t, a, cache)
    out.write('"rows": {"columns": [')
    for k in range(len(r.columns)):
        ref c = r.columns[k]
        out.write(
            ", " if k else "",
            '{"name": ',
            json_quote(c.name),
            ', "type": ',
            json_quote(c.type),
            "}",
        )
    out.write('], "rows": [')
    for n in range(r.lo, r.hi):
        out.write(", " if n > r.lo else "", "[")
        ref row = r.cells[r.order[n]]
        for k in range(len(row)):
            out.write(", " if k else "", row[k])
        out.write("]")
    out.write(
        '], "offset": ',
        a.offset,
        ', "limit": ',
        a.limit,
        ', "next": ',
        String(a.offset + a.limit) if r.more else String("null"),
        ', "sort": ',
        json_quote(a.sort),
        ', "filter": ',
        r.filter,
        ', "files": ',
        r.files,
        ', "scanned": ',
        r.scanned,
        ', "stopped": ',
        json_quote(r.stopped) if r.stopped else String("null"),
        ', "seconds": ',
        r.seconds,
        ', "plan_seconds": ',
        r.plan_seconds,
        "}",
    )


# ── the chart ────────────────────────────────────────────────────────────────


def chart_json(
    t: Table, a: DataAsk, mut cache: ManifestCache, mut out: String
) raises:
    """`"chart": {...}`: each `chart_y` column averaged (or summed) over
    the filtered rows by `chart_x`, in x's order."""
    var full = t.scan()
    if a.snapshot >= 0:
        full = full.use_snapshot(a.snapshot)
    var cols = columns_of(full.current_schema())
    var xk = find_column(cols, a.chart_x)
    if xk < 0:
        raise Error("morca: the table has no column ", a.chart_x)
    if len(a.chart_y) == 0 or len(a.chart_y) > 3:
        raise Error("morca: a chart has 1 to 3 y columns")
    for y in a.chart_y:
        var k = find_column(cols, y)
        if k < 0:
            raise Error("morca: the table has no column ", y)
        if not is_numeric(cols[k].kind):
            raise Error("morca: ", y, " isn't a number, so it can't be charted")
    var read: List[String] = [a.chart_x]
    for y in a.chart_y:
        if y not in read:
            read.append(y)
    var scan = _scan_of(t, a, cols).select(read.copy())
    var reader = _TaskReader(scan, scan.plan_files_with(cache), a.max_rows)
    var clock = _Clock(a.seconds)
    var xs = List[String]()
    var index = Dict[String, Int]()
    var sums = List[List[Float64]]()
    var counts = List[List[Int]]()
    var stopped = String()
    var scanned = 0
    var xkind = cols[xk].kind
    while True:
        if clock.over():
            stopped = _time_stop(a.seconds)
            break
        var got = reader.next_batch()
        guard case .Some(b) = got else:
            break
        var at = _batch_columns(b, read, cols)
        for i in range(b.num_rows):
            if scanned >= a.max_rows:
                break
            scanned += 1
            var x = cell_json(b, at[0][0], i, xkind)
            var p = index.get(x, -1)
            if p < 0:
                if len(xs) >= CHART_POINTS:
                    stopped = String(
                        "the chart stopped at ", CHART_POINTS, " x values"
                    )
                    break
                p = len(xs)
                index[x] = p
                xs.append(x)
                sums.append(List[Float64](length=len(a.chart_y), fill=0))
                counts.append(List[Int](length=len(a.chart_y), fill=0))
            for k in range(len(a.chart_y)):
                var ci = at[read.index(a.chart_y[k])][0]
                var v = cell_json(b, ci, i, P_DOUBLE)
                if v == "null":
                    continue
                try:
                    var f = Float64(v.strip('"'))
                    if f == f and f - f == 0:  # neither NaN nor infinite
                        sums[p][k] += f
                        counts[p][k] += 1
                except:
                    pass
        if stopped or scanned >= a.max_rows:
            break
    if not stopped and scanned >= a.max_rows:
        stopped = String(
            "the chart read the first ",
            a.max_rows,
            " filtered rows only (MORCA_DATA_CHART_ROWS)",
        )
    var keys = List[_Key]()
    var order = List[Int]()
    for i in range(len(xs)):
        keys.append(_key_of(xs[i], xkind))
        order.append(i)
    _merge_sort(order, keys, is_numeric(xkind), False)
    out.write(
        '"chart": {"x": ',
        json_quote(a.chart_x),
        ', "x_type": ',
        json_quote(cols[xk].type),
        ', "numeric_x": ',
        "true" if is_numeric(xkind) else "false",
        ', "agg": ',
        json_quote(a.chart_agg),
        ', "y": [',
    )
    for k in range(len(a.chart_y)):
        out.write(", " if k else "", json_quote(a.chart_y[k]))
    out.write('], "points": [')
    for n in range(len(order)):
        var p = order[n]
        out.write(", " if n else "", '{"x": ', xs[p], ', "y": [')
        for k in range(len(a.chart_y)):
            var c = counts[p][k]
            var v = sums[p][k] / Float64(c) if a.chart_agg == "avg" and c else (
                sums[p][k]
            )
            out.write(", " if k else "", String(v) if c else String("null"))
        out.write("]}")
    out.write(
        '], "scanned": ',
        scanned,
        ', "stopped": ',
        json_quote(stopped) if stopped else String("null"),
        "}",
    )


# ── the download ─────────────────────────────────────────────────────────────


def _csv_field(cell: String) -> String:
    """A JSON cell as a CSV field: text unquoted from JSON and quoted for
    CSV when it needs it; null empty."""
    if cell == "null":
        return String()
    var text = cell
    if cell.startswith('"') and cell.endswith('"'):
        text = _unjson(cell)
    if "," in text or '"' in text or "\n" in text or "\r" in text:
        return String('"', text.replace('"', '""'), '"')
    return text^


def _unjson(s: String) -> String:
    """A JSON string literal's text (the escapes `json_quote` writes)."""
    var b = s.as_bytes()
    var out = List[Byte]()
    var i = 1
    while i < len(b) - 1:
        var c = b[i]
        if c == 92 and i + 1 < len(b) - 1:
            var e = b[i + 1]
            if e == 110:  # n
                out.append(10)
            elif e == 116:  # t
                out.append(9)
            elif e == 114:  # r
                out.append(13)
            elif e == 117 and i + 5 < len(b):  # u
                var v = 0
                for k in range(4):
                    var h = Int(b[i + 2 + k])
                    v = v * 16 + (
                        h - 48 if h <= 57 else (h - 87 if h >= 97 else h - 55)
                    )
                if v < 0x80:
                    out.append(Byte(v))
                i += 6
                continue
            else:
                out.append(e)
            i += 2
            continue
        out.append(c)
        i += 1
    return String(from_utf8_lossy=Span(out))


def csv_json(
    t: Table, a: DataAsk, mut cache: ManifestCache, mut out: String
) raises:
    """Writes the filtered rows (sorted, if asked) to `a.csv` as CSV, up to
    `a.max_rows`; `"csv": {...}` says how many and why it stopped."""
    var page = a.copy()
    page.offset = 0
    page.limit = a.max_rows
    var r = _read_rows(t, page, cache)
    # Written whole with write_file, not Mojo's file write, which aborts
    # the process on a full disk (#483): that's a "csv" error instead.
    var text = String()
    for k in range(len(r.columns)):
        text.write("," if k else "", _csv_field(json_quote(r.columns[k].name)))
    text.write("\n")
    var n = 0
    for i in range(r.lo, r.hi):
        ref row = r.cells[r.order[i]]
        for k in range(len(row)):
            text.write("," if k else "", _csv_field(row[k]))
        text.write("\n")
        n += 1
    if not write_file(a.csv, text.as_bytes()):
        out.write(
            '"csv": {"path": ',
            json_quote(a.csv),
            ', "error": ',
            json_quote(
                String(
                    "morca_maintain: can't write the download to ",
                    a.csv,
                    ": its disk is full or can't be written",
                )
            ),
            "}",
        )
        return
    var stopped = r.stopped.copy()
    if not stopped and r.more:
        stopped = String(
            "the download stops at ",
            a.max_rows,
            " rows (MORCA_DATA_DOWNLOAD_ROWS)",
        )
    out.write(
        '"csv": {"path": ',
        json_quote(a.csv),
        ', "rows": ',
        n,
        ', "stopped": ',
        json_quote(stopped) if stopped else String("null"),
        "}",
    )
