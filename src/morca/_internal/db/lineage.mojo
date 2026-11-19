"""Lineage's queries (`morca._internal.lineage`): walks over the snapshots attempts
read and committed (`orca.reads`, `orca.commits`), and the datasets
pipelines declare."""

from postgres import Connection, Params

comptime DEPTH = 20


@fieldwise_init
struct SnapshotRef(Copyable, Equatable, Movable, Writable):
    var dataset: String
    var snapshot: Int64

    def __eq__(self, other: Self) -> Bool:
        return self.dataset == other.dataset and self.snapshot == other.snapshot

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.dataset, "@", self.snapshot)


@fieldwise_init
struct Made(Copyable, Movable):
    """A snapshot, the attempt that made it, and what that attempt read."""

    var at: SnapshotRef
    var depth: Int
    """Steps from the snapshot the walk started at: 0 for it, 1 for its
    inputs' (back) or for what was made from it (forward)."""
    var pipeline: String
    var run: Int
    var step: String
    var partition: String
    var attempt: Int
    var code: String
    var ended: String
    var inputs: List[SnapshotRef]


comptime _MADE_COLUMNS = (
    "m.dataset, m.snapshot_id, m.depth, m.attempt, r.pipeline, r.id AS run,"
    " s.step, s.partition, a.attempt AS attempt_no, a.registry_hash AS code,"
    " coalesce(to_char(a.ended AT TIME ZONE 'UTC',"
    " 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), '') AS ended, coalesce((SELECT"
    " string_agg(i.dataset || '@' || i.snapshot_id, ',' ORDER BY i.dataset,"
    " i.snapshot_id) FROM orca.reads i WHERE i.attempt = m.attempt AND"
    " i.dataset IS NOT NULL AND i.snapshot_id >= 0), '') AS inputs"
)
"""What `_made` reads of each row of a walk `m` (dataset, snapshot_id,
depth, attempt): the attempt's run and step, and its inputs."""


def _made(
    mut conn: Connection, walk: String, start: SnapshotRef
) raises -> List[Made]:
    """Each snapshot of `walk`, a recursive CTE named `m`, once: at its
    smallest depth, by its earliest attempt."""
    # Nearest first, then by name, so a listing reads outward.
    var rows = conn.query(
        String(
            walk,
            " SELECT * FROM (SELECT DISTINCT ON (m.dataset, m.snapshot_id) ",
            _MADE_COLUMNS,
            " FROM m JOIN orca.attempts a ON a.id = m.attempt JOIN orca.steps",
            " s ON s.id = a.step JOIN orca.runs r ON r.id = s.run ORDER BY",
            " m.dataset, m.snapshot_id, m.depth, m.attempt) x ORDER BY depth,",
            " dataset, snapshot_id",
        ),
        Params().text(start.dataset).int64(start.snapshot).int64(DEPTH),
    )
    var out = List[Made]()
    for r in rows:
        var inputs = List[SnapshotRef]()
        var text = r.text("inputs")
        if text:
            for part in text.split(","):
                var at = part.rfind("@").or_else(-1)
                inputs.append(
                    SnapshotRef(
                        String(part[byte=:at]),
                        Int64(Int(part[byte = at + 1 :])),
                    )
                )
        out.append(
            Made(
                SnapshotRef(r.text("dataset"), r.int64("snapshot_id")),
                Int(r.int64("depth")),
                r.text("pipeline"),
                Int(r.int64("run")),
                r.text("step"),
                r.text("partition"),
                Int(r.int64("attempt_no")),
                r.text("code"),
                r.text("ended"),
                inputs^,
            )
        )
    return out^


def back(mut conn: Connection, start: SnapshotRef) raises -> List[Made]:
    """The snapshot, if a morca attempt made it, and everything it was made
    from: one `Made` per snapshot a morca attempt made."""
    return _made(
        conn,
        (
            "WITH RECURSIVE m (dataset, snapshot_id, attempt, depth) AS"
            " (SELECT c.dataset, c.snapshot_id, c.attempt, 0 FROM"
            " orca.commits c WHERE c.dataset = $1 AND c.snapshot_id = $2"
            " UNION SELECT c.dataset, c.snapshot_id, c.attempt, m.depth + 1"
            " FROM m JOIN orca.reads i ON i.attempt = m.attempt JOIN"
            " orca.commits c ON c.dataset = i.dataset AND c.snapshot_id ="
            " i.snapshot_id WHERE m.depth < $3)"
        ),
        start,
    )


def forward(mut conn: Connection, start: SnapshotRef) raises -> List[Made]:
    """Every snapshot made from `start`, directly or not."""
    return _made(
        conn,
        (
            "WITH RECURSIVE m (dataset, snapshot_id, attempt, depth) AS"
            " (SELECT c.dataset, c.snapshot_id, c.attempt, 1 FROM orca.reads"
            " i JOIN orca.commits c ON c.attempt = i.attempt WHERE i.dataset"
            " = $1 AND i.snapshot_id = $2 AND c.dataset IS NOT NULL AND NOT"
            " (c.dataset = $1 AND c.snapshot_id = $2) UNION SELECT"
            " c.dataset, c.snapshot_id, c.attempt, m.depth + 1 FROM m JOIN"
            " orca.reads i ON i.dataset = m.dataset AND i.snapshot_id ="
            " m.snapshot_id JOIN orca.commits c ON c.attempt = i.attempt"
            " WHERE c.dataset IS NOT NULL AND m.depth < $3 AND NOT"
            " (c.dataset = m.dataset AND c.snapshot_id = m.snapshot_id))"
        ),
        start,
    )


def latest(mut conn: Connection, dataset: String) raises -> Int64:
    """The dataset's newest snapshot morca knows of, committed or read, or
    -1 if it knows of none."""
    var rows = conn.query(
        (
            "SELECT snapshot_id FROM (SELECT snapshot_id, attempt FROM"
            " orca.commits WHERE dataset = $1 UNION ALL SELECT snapshot_id,"
            " attempt FROM orca.reads WHERE dataset = $1 AND snapshot_id >= 0)"
            " x ORDER BY attempt DESC LIMIT 1"
        ),
        Params().text(dataset),
    )
    return rows.row(0).int64("snapshot_id") if len(rows) == 1 else -1


@fieldwise_init
struct Dataset(Copyable, Movable):
    var name: String
    var writers: List[String]
    """The pipelines whose steps declare it in `writes=`."""
    var readers: List[String]
    var commits: Int
    var latest: Int64
    """The newest snapshot a morca attempt committed, or -1."""
    var latest_run: Int


comptime _DECLARED = (
    "SELECT DISTINCT p.name AS pipeline, k.kind, x.ds FROM orca.pipelines p,"
    " jsonb_array_elements(p.describe->'steps') AS s(st), (VALUES ('reads'),"
    " ('writes')) AS k(kind), jsonb_array_elements_text(coalesce(s.st->k.kind,"
    " '[]')) AS x(ds)"
)
"""Every (pipeline, `reads` or `writes`, dataset) the registered pipelines
declare."""


def _split(s: String) -> List[String]:
    var out = List[String]()
    if s:
        for p in s.split(","):
            out.append(String(p))
    return out^


def datasets(mut conn: Connection, only: String = "") raises -> List[Dataset]:
    """Every dataset a pipeline declares or an attempt touched, or the one
    named, by name."""
    var rows = conn.query(
        String(
            "WITH d AS (",
            _DECLARED,
            "), names AS (SELECT ds FROM d UNION SELECT dataset FROM",
            " orca.commits WHERE dataset IS NOT NULL UNION SELECT dataset",
            " FROM orca.reads WHERE dataset IS NOT NULL) SELECT n.ds,",
            " coalesce((SELECT string_agg(DISTINCT d.pipeline, ',') FROM d",
            " WHERE d.ds = n.ds AND d.kind = 'writes'), '') AS writers,",
            " coalesce((SELECT string_agg(DISTINCT d.pipeline, ',') FROM d",
            " WHERE d.ds = n.ds AND d.kind = 'reads'), '') AS readers,",
            " (SELECT count(DISTINCT c.snapshot_id) FROM orca.commits c WHERE",
            " c.dataset = n.ds) AS commits, coalesce(l.snapshot_id, -1) AS",
            " latest, coalesce(l.run, 0) AS latest_run FROM names n LEFT JOIN",
            " LATERAL (SELECT c.snapshot_id, s.run FROM orca.commits c JOIN",
            " orca.attempts a ON a.id = c.attempt JOIN orca.steps s ON s.id =",
            " a.step WHERE c.dataset = n.ds ORDER BY c.attempt DESC LIMIT 1) l",
            " ON true WHERE $1 = '' OR n.ds = $1 ORDER BY n.ds",
        ),
        Params().text(only),
    )
    var out = List[Dataset]()
    for r in rows:
        out.append(
            Dataset(
                r.text("ds"),
                _split(r.text("writers")),
                _split(r.text("readers")),
                Int(r.int64("commits")),
                r.int64("latest"),
                Int(r.int64("latest_run")),
            )
        )
    return out^


@fieldwise_init
struct Flow(Copyable, Movable):
    """An edge of the graph of pipelines and datasets: a pipeline reads a
    dataset, or writes one."""

    var pipeline: String
    var dataset: String
    var writes: Bool


def flows(mut conn: Connection) raises -> List[Flow]:
    """Every pipeline's declared reads and writes."""
    var rows = conn.query(
        String(_DECLARED, " ORDER BY pipeline, kind DESC, ds"), Params()
    )
    var out = List[Flow]()
    for r in rows:
        out.append(
            Flow(r.text("pipeline"), r.text("ds"), r.text("kind") == "writes")
        )
    return out^


@fieldwise_init
struct Commit(Copyable, Movable):
    """A snapshot of a dataset a morca attempt committed."""

    var snapshot: Int64
    var pipeline: String
    var run: Int
    var step: String
    var partition: String
    var ended: String
    var attempt: Int
    """The attempt that first committed it: with the snapshot, its place
    in the list (`SnapshotCursor`)."""

    def cursor(self) -> SnapshotCursor:
        return SnapshotCursor(self.attempt, self.snapshot)


@fieldwise_init
struct SnapshotCursor(ImplicitlyCopyable, Movable, Writable):
    """A place in a dataset's list of snapshots, `<attempt>.<snapshot>` in
    a URL; attempt 0 is none."""

    var attempt: Int
    var snapshot: Int64

    @staticmethod
    def parse(s: String) -> SnapshotCursor:
        """`<attempt>.<snapshot>`, or none if it isn't one."""
        var dot = s.find(".").or_else(-1)
        if dot <= 0:
            return SnapshotCursor(0, 0)
        try:
            var a = Int(s[byte=:dot])
            var n = Int64(Int(s[byte = dot + 1 :]))
            if a > 0:
                return SnapshotCursor(a, n)
        except:
            pass
        return SnapshotCursor(0, 0)

    def write_to(self, mut w: Some[Writer]):
        w.write(self.attempt, ".", self.snapshot)


def commits(
    mut conn: Connection,
    dataset: String,
    limit: Int = 50,
    before: SnapshotCursor = SnapshotCursor(0, 0),
    after: SnapshotCursor = SnapshotCursor(0, 0),
) raises -> List[Commit]:
    """The dataset's snapshots morca committed, newest first (by the attempt
    that first committed each, then the snapshot): those after `before` if
    it's set; with `after` set, the `limit` just before it, oldest first."""
    var rows = conn.query(
        String(
            "SELECT * FROM (SELECT DISTINCT ON (c.snapshot_id) c.snapshot_id,",
            " r.pipeline, r.id AS run, s.step, s.partition,",
            " coalesce(to_char(a.ended AT TIME ZONE 'UTC',",
            " 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), '') AS ended, c.attempt FROM",
            " orca.commits c JOIN orca.attempts a ON a.id = c.attempt JOIN",
            " orca.steps s ON s.id = a.step JOIN orca.runs r ON r.id = s.run",
            # A snapshot's first attempt is under the cursor if any is.
            " WHERE c.dataset = $1 AND ($3 = 0 OR (c.attempt, c.snapshot_id)",
            " < ($3, $4)) ORDER BY c.snapshot_id, c.attempt) x WHERE ($5 = 0",
            " OR (attempt, snapshot_id) > ($5, $6)) ORDER BY attempt ",
            "ASC" if after.attempt else "DESC",
            ", snapshot_id ",
            "ASC" if after.attempt else "DESC",
            " LIMIT $2",
        ),
        Params()
        .text(dataset)
        .int64(Int64(limit))
        .int64(Int64(before.attempt))
        .int64(before.snapshot)
        .int64(Int64(after.attempt))
        .int64(after.snapshot),
    )
    var out = List[Commit]()
    for r in rows:
        out.append(
            Commit(
                r.int64("snapshot_id"),
                r.text("pipeline"),
                Int(r.int64("run")),
                r.text("step"),
                r.text("partition"),
                r.text("ended"),
                Int(r.int64("attempt")),
            )
        )
    return out^
