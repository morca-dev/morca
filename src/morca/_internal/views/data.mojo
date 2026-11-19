"""A dataset's data as its Data tab reads it (#435): what the URL asks for
(`DataQuery`), the limits a public page keeps to (`DataLimits`), and the
read itself, which runs in the project's `morca_maintain data`
(`morca._lake.dataread`), since the `morca` binary doesn't link iceberg.

The read is a process of its own, started at a lower CPU priority and
killed a few seconds past the time limit it was given, so a scan that
won't stop can't hold the UI; the memory it used goes with it.

The limits, each from the UI's environment:

| Variable | Default | |
|---|---|---|
| `MORCA_DATA_PAGE_ROWS` | 100 | rows a page shows, at most |
| `MORCA_DATA_DOWNLOAD_ROWS` | 100000 | rows a download holds, at most |
| `MORCA_DATA_SORT_ROWS` | 100000 | filtered rows a sort reads, at most |
| `MORCA_DATA_CHART_ROWS` | 100000 | filtered rows a chart reads, at most |
| `MORCA_DATA_SECONDS` | 20 | how long a read may take |
| `MORCA_DATA_MEMORY_MB` | 256 | what a read may hold |

What a read keeps on disk for the next, by snapshot, is
`morca._lake.datacache`'s (`MORCA_DATA_CACHE`, `MORCA_DATA_CACHE_MB`).
"""

from std.os import getenv
from std.os.path import exists

from json import loads

from morca._internal.expiry import maintain_binary
from morca._internal.html import query_param, query_values, url_encode
from morca._internal.proc import capture

comptime OPS = ["eq", "ne", "lt", "le", "gt", "ge", "in"]
comptime DATA_NICE = 10
"""How much lower than the UI's the read's CPU priority is."""
comptime GRACE_SECONDS = 5.0
"""How long past its time limit a read is let run before it's killed: it
checks the limit between batches, and stops by itself."""


def _env_int(name: StringSlice, dflt: Int) -> Int:
    try:
        var v = getenv(String(name))
        return Int(v) if v else dflt
    except:
        return dflt


def _env_float(name: StringSlice, dflt: Float64) -> Float64:
    try:
        var v = getenv(String(name))
        return Float64(v) if v else dflt
    except:
        return dflt


@fieldwise_init
struct DataLimits(Copyable, Movable):
    """What a read of a dataset's data may do (the module doc)."""

    var page_rows: Int
    var download_rows: Int
    var sort_rows: Int
    var chart_rows: Int
    var seconds: Float64
    var memory_mb: Float64

    @staticmethod
    def from_env() -> DataLimits:
        return DataLimits(
            max(1, _env_int("MORCA_DATA_PAGE_ROWS", 100)),
            max(1, _env_int("MORCA_DATA_DOWNLOAD_ROWS", 100_000)),
            max(1, _env_int("MORCA_DATA_SORT_ROWS", 100_000)),
            max(1, _env_int("MORCA_DATA_CHART_ROWS", 100_000)),
            _env_float("MORCA_DATA_SECONDS", 20.0),
            _env_float("MORCA_DATA_MEMORY_MB", 256.0),
        )

    def json(self) -> String:
        return String(
            '{"page_rows": ',
            self.page_rows,
            ', "download_rows": ',
            self.download_rows,
            ', "sort_rows": ',
            self.sort_rows,
            ', "chart_rows": ',
            self.chart_rows,
            ', "seconds": ',
            self.seconds,
            ', "memory_mb": ',
            self.memory_mb,
            "}",
        )


struct DataQuery(Copyable, Movable):
    """What a Data tab's URL asks for: `?snapshot=`, `?f=COL:OP:VALUE` (one
    or more; a form's `fc`, `fo` and `fv` add one), `?c=` columns (one or
    more, or `cols=a,b`), `?sort=[-]COL`, `?cursor=` (the offset the last
    page's `next` gave), `?n=` rows, and the chart's `?x=`, `?y=` (up to
    three), `?agg=avg|sum` and `?chart=line|bar`."""

    var snapshot: String
    var filters: List[String]
    var columns: List[String]
    var sort: String
    var cursor: Int
    var n: Int
    var x: String
    var y: List[String]
    var agg: String
    var chart: String
    var problem: String
    """Why the URL can't be read as asked (a filter that isn't one), or
    empty."""

    def __init__(out self, url: String, limits: DataLimits):
        self.snapshot = query_param(url, "snapshot")
        self.filters = List[String]()
        self.problem = String()
        for f in query_values(url, "f"):
            if f:
                self.filters.append(f)
        var fc = query_param(url, "fc")
        var fv = query_param(url, "fv")
        if fc and fv:
            var op = query_param(url, "fo")
            self.filters.append(String(fc, ":", op if op else "eq", ":", fv))
        for f in self.filters:
            var why = filter_problem(f)
            if why and not self.problem:
                self.problem = why
        self.columns = List[String]()
        for c in query_values(url, "c"):
            if c and c not in self.columns:
                self.columns.append(c)
        for c in query_param(url, "cols").split(","):
            var s = String(c.strip())
            if s and s not in self.columns:
                self.columns.append(s^)
        self.sort = query_param(url, "sort")
        self.cursor = 0
        try:
            var c = query_param(url, "cursor")
            self.cursor = max(0, Int(c)) if c else 0
        except:
            self.problem = String(
                "the cursor is a row number, not ", query_param(url, "cursor")
            )
        self.n = limits.page_rows
        try:
            var n = query_param(url, "n")
            if n:
                self.n = min(max(1, Int(n)), limits.page_rows)
        except:
            pass
        self.x = query_param(url, "x")
        self.y = List[String]()
        for v in query_values(url, "y"):
            if v and v not in self.y and len(self.y) < 3:
                self.y.append(v)
        self.agg = query_param(url, "agg")
        if self.agg != "sum":
            self.agg = String("avg")
        self.chart = query_param(url, "chart")
        if self.chart != "bar":
            self.chart = String("line")
        if self.snapshot:
            try:
                _ = Int(self.snapshot)
            except:
                self.problem = String(
                    "a snapshot is a number, not ", self.snapshot
                )

    def charted(self) -> Bool:
        return Bool(self.x) and len(self.y) > 0

    def query(
        self,
        cursor: Int = 0,
        drop_filter: Int = -1,
        with_chart: Bool = True,
    ) -> String:
        """The URL's query (without `tab`) as `&k=v...`, at `cursor`;
        `drop_filter` leaves out that filter, for its remove link."""
        var q = String()
        if self.snapshot:
            q.write("&snapshot=", url_encode(self.snapshot))
        for i in range(len(self.filters)):
            if i != drop_filter:
                q.write("&f=", url_encode(self.filters[i]))
        for c in self.columns:
            q.write("&c=", url_encode(c))
        if self.sort:
            q.write("&sort=", url_encode(self.sort))
        if cursor > 0:
            q.write("&cursor=", cursor)
        if with_chart and self.charted():
            q.write("&x=", url_encode(self.x))
            for v in self.y:
                q.write("&y=", url_encode(v))
            if self.agg != "avg":
                q.write("&agg=", self.agg)
            if self.chart != "line":
                q.write("&chart=", self.chart)
        return q^


def filter_problem(f: String) -> String:
    """Why `f` isn't a `COLUMN:OP:VALUE` filter, or empty."""
    var a = f.find(":")
    var b = f.find(":", a + 1) if a >= 0 else -1
    if a <= 0 or b < 0:
        return String(
            (
                "a filter is COLUMN:OP:VALUE, OP one of eq, ne, lt, le, gt, ge"
                " and in: "
            ),
            f,
        )
    var op = String(f[byte = a + 1 : b])
    for o in materialize[OPS]():
        if o == op:
            return ""
    return String("a filter's OP is eq, ne, lt, le, gt, ge or in, not ", op)


def data_argv(
    binary: String,
    dataset: String,
    q: DataQuery,
    limits: DataLimits,
    csv: String = "",
    partitions: Bool = True,
) -> List[String]:
    """The `morca_maintain data` command line for `q`."""
    var a: List[String] = [binary, String("data"), dataset]
    if q.snapshot:
        a.append(String("--snapshot"))
        a.append(q.snapshot)
    for f in q.filters:
        a.append(String("--where"))
        a.append(f)
    if len(q.columns):
        var cols = String()
        for c in q.columns:
            cols.write("," if cols else "", c)
        a.append(String("--columns"))
        a.append(cols^)
    if q.sort:
        a.append(String("--sort"))
        a.append(q.sort)
    a.append(String("--seconds"))
    a.append(String(limits.seconds))
    a.append(String("--memory-mb"))
    a.append(String(limits.memory_mb))
    if csv:
        a.append(String("--csv"))
        a.append(csv)
        a.append(String("--max-rows"))
        a.append(String(limits.download_rows))
        return a^
    a.append(String("--offset"))
    a.append(String(q.cursor))
    a.append(String("--limit"))
    a.append(String(q.n))
    a.append(String("--max-rows"))
    a.append(String(limits.chart_rows if q.charted() else limits.sort_rows))
    if q.charted():
        a.append(String("--chart-x"))
        a.append(q.x)
        var ys = String()
        for v in q.y:
            ys.write("," if ys else "", v)
        a.append(String("--chart-y"))
        a.append(ys^)
        a.append(String("--chart-agg"))
        a.append(q.agg)
    if not partitions:
        a.append(String("--no-partitions"))
    return a^


@fieldwise_init
struct DataRead(Movable):
    """What `read_data` got: the JSON `morca_maintain data` printed, or
    why there's none (`error`, with the HTTP status that goes with it)."""

    var json: String
    var error: String
    var status: Int


def read_data(argv: List[String], limits: DataLimits) -> DataRead:
    """Runs `argv` (`data_argv`), killing it `GRACE_SECONDS` past its time
    limit. A mistake in the request (a column the table hasn't) is the
    JSON's `error`, 400 (404 for a snapshot the table hasn't); no binary or
    a read that failed, 503."""
    if len(argv) == 0 or not argv[0]:
        return DataRead(
            String(),
            String(
                "the data view needs the project's morca_maintain binary"
                " (beside morca, on PATH, or MORCA_MAINTAIN), which reads"
                " the table"
            ),
            503,
        )
    try:
        var got = capture(
            argv,
            limits.seconds + GRACE_SECONDS if limits.seconds > 0 else 0,
            DATA_NICE,
        )
        var text = String(got[1].strip())
        if got[0] != 0 or not text.startswith("{"):
            return DataRead(
                String(),
                String(
                    "morca_maintain data exited ",
                    got[0],
                    ": reading the table failed (the UI's log has its error)",
                ),
                503,
            )
        var v = loads(text)
        var err = v.try_at("/error")
        if err and err.value().is_string():
            var status = 400
            var st = v.try_at("/status")
            if st and st.value().int_value() == 404:
                status = 404
            return DataRead(String(), err.value().string_value(), status)
        return DataRead(text^, String(), 200)
    except e:
        return DataRead(String(), String(e), 503)


def data_binary() -> String:
    """`morca_maintain`, as `morca expire` finds it; empty without one."""
    var b = maintain_binary()
    if b and ("/" not in b or exists(b)):
        return b
    return String()
