"""Queueing's queries (`morca._internal.queueing`): the datasets pipelines write and
read, the keys a pipeline has done, a keyed pipeline's keys
(`orca.keys`), and the runs a backfill queues."""

from postgres import Connection, Params, Transaction


@fieldwise_init
struct Edge(Copyable, Movable):
    """Pipeline `src` writes dataset `ds`, which pipeline `dst` reads."""

    var src: String
    var dst: String
    var ds: String


def dataset_edges(
    mut conn: Connection, describe: String
) raises -> Tuple[String, List[Edge]]:
    """The pipeline `describe` names, and every edge between two pipelines
    through a dataset, with that pipeline as `describe` has it and the
    others as registered."""
    var rows = conn.query(
        (
            "WITH d AS (SELECT name, describe FROM orca.pipelines WHERE name"
            " <> $1::jsonb->>'pipeline' UNION ALL SELECT $1::jsonb->>"
            "'pipeline', $1::jsonb), io AS (SELECT DISTINCT d.name, k.kind,"
            " x.ds FROM d, jsonb_array_elements(d.describe->'steps') AS s(st),"
            " (VALUES ('reads'), ('writes')) AS k(kind),"
            " jsonb_array_elements_text(coalesce(s.st->k.kind, '[]')) AS"
            " x(ds)) SELECT w.name AS src, r.name AS dst, w.ds, $1::jsonb->>"
            "'pipeline' AS me FROM io w JOIN io r ON r.ds = w.ds AND r.kind ="
            " 'reads' WHERE w.kind = 'writes' AND w.name <> r.name ORDER BY"
            " 1, 2, 3"
        ),
        Params().text(describe),
    )
    var edges = List[Edge]()
    if len(rows) == 0:
        return (String(), edges^)
    var me = rows.row(0).text("me")
    for r in rows:
        edges.append(Edge(r.text("src"), r.text("dst"), r.text("ds")))
    return (me^, edges^)


@fieldwise_init
struct Mismatch(Copyable, Movable):
    """A sensor of one kind of keys reading what a pipeline of the other
    kind writes."""

    var reader: String
    var rkind: String
    var ds: String
    var writer: String
    var wkind: String


def kind_mismatch(
    mut conn: Connection, describe: String
) raises -> Optional[Mismatch]:
    """The first sensor, with the pipeline `describe` gives either end,
    that would run keys of the other kind than what it reads."""
    var rows = conn.query(
        (
            "WITH d AS (SELECT name, describe FROM orca.pipelines WHERE name"
            " <> $1::jsonb->>'pipeline' UNION ALL SELECT $1::jsonb->>"
            "'pipeline', $1::jsonb), io AS (SELECT DISTINCT d.name,"
            " coalesce(d.describe->'partitions'->>'kind', 'monthly') AS"
            " pkind, coalesce((d.describe->>'sensor')::boolean, false) AS"
            " sensor, k.kind, x.ds, coalesce(d.describe->'partitions'->>"
            "'dataset', '') AS keys FROM d, jsonb_array_elements(d.describe->"
            "'steps') AS s(st), (VALUES ('reads'), ('writes')) AS k(kind),"
            " jsonb_array_elements_text(coalesce(s.st->k.kind, '[]')) AS"
            " x(ds) UNION SELECT d.name, 'keyed', coalesce((d.describe->>"
            "'sensor')::boolean, false), 'reads', d.describe->'partitions'->>"
            "'dataset', d.describe->'partitions'->>'dataset' FROM d WHERE"
            " d.describe->'partitions'->>'dataset' IS NOT NULL) SELECT w.name"
            " AS writer, w.pkind AS wkind, r.name AS reader, r.pkind AS rkind,"
            " w.ds FROM io w JOIN io r ON r.ds = w.ds AND r.kind = 'reads'"
            " WHERE w.kind = 'writes' AND w.name <> r.name AND r.sensor AND"
            " (w.pkind = 'keyed') <> (r.pkind = 'keyed') AND NOT (r.pkind ="
            " 'keyed' AND r.ds = r.keys) AND $1::jsonb->>'pipeline' IN"
            " (w.name, r.name) ORDER BY 1, 3, 5 LIMIT 1"
        ),
        Params().text(describe),
    )
    if len(rows) == 0:
        return None
    var r = rows.row(0)
    return Mismatch(
        r.text("reader"),
        r.text("rkind"),
        r.text("ds"),
        r.text("writer"),
        r.text("wkind"),
    )


def keep_keys(
    mut conn: Connection, pipeline: String, snapshot: Int64, keys: String
) raises:
    """Records `pipeline`'s keys (a line each) as of `snapshot`."""
    _ = conn.execute(
        (
            "INSERT INTO orca.keys (pipeline, snapshot_id, keys) VALUES ($1,"
            " $2, $3) ON CONFLICT (pipeline) DO UPDATE SET snapshot_id ="
            " EXCLUDED.snapshot_id, keys = EXCLUDED.keys, read_at = now()"
        ),
        Params().text(pipeline).int64(snapshot).text(keys),
    )


@fieldwise_init
struct KeysRow(Copyable, Movable):
    """A pipeline's row of `orca.keys`."""

    var snapshot: Int64
    var keys: String
    """A line each."""
    var read_at: String
    var age: Float64


def kept_keys(
    mut conn: Connection, pipeline: String
) raises -> Optional[KeysRow]:
    var rows = conn.query(
        (
            "SELECT snapshot_id, keys, to_char(read_at AT TIME ZONE 'UTC',"
            ' \'YYYY-MM-DD"T"HH24:MI:SS"Z"\') AS at, extract(epoch FROM'
            " now() - read_at)::float8 AS age FROM orca.keys WHERE pipeline ="
            " $1"
        ),
        Params().text(pipeline),
    )
    if len(rows) == 0:
        return None
    var r = rows.row(0)
    return KeysRow(
        r.int64("snapshot_id"), r.text("keys"), r.text("at"), r.float64("age")
    )


comptime DONE_SQL = (
    "WITH k AS (SELECT DISTINCT unnest(string_to_array($2, ',')) AS key), p"
    " AS (SELECT pp.describe, coalesce((SELECT v.data_version FROM"
    " orca.pipeline_versions v WHERE v.id = pp.version), '') AS dv FROM"
    " orca.pipelines pp WHERE pp.name = $1), h AS (SELECT registry_hash,"
    " coalesce(max(data_version), '') AS dv FROM orca.pipeline_versions WHERE"
    " pipeline = $1 GROUP BY registry_hash), m AS (SELECT x->>'name' AS step"
    " FROM p, jsonb_array_elements(p.describe->'steps') AS x WHERE x->>'kind'"
    " = 'mapped') SELECT k.key FROM k WHERE CASE WHEN EXISTS (SELECT 1 FROM m)"
    " THEN NOT EXISTS (SELECT 1 FROM m WHERE NOT EXISTS (SELECT 1 FROM"
    " orca.steps st JOIN orca.runs r ON r.id = st.run LEFT JOIN h ON"
    " h.registry_hash = r.registry_hash WHERE r.pipeline = $1 AND st.step ="
    " m.step AND st.partition = k.key AND st.status = 'succeeded' AND"
    " coalesce(h.dv, '') = (SELECT dv FROM p))) ELSE false END UNION ALL"
    " SELECT k.key FROM k WHERE k.key IN (SELECT"
    " unnest(string_to_array(r.partitions, ',')) FROM orca.runs r LEFT JOIN h"
    " ON h.registry_hash = r.registry_hash WHERE NOT EXISTS (SELECT 1 FROM m)"
    " AND r.pipeline = $1 AND r.status = 'succeeded' AND coalesce(h.dv, '') ="
    " (SELECT dv FROM p))"
)
"""Of the comma-separated keys `$2`, those done for pipeline `$1`: every
mapped step of its current `describe` has succeeded for the key in a run of
any of its code with its current data version (the same steps' `version=`,
as `morca._internal.db.fill._SAME_DATA` has it, #508). A run's data version
is its registry hash's in `orca.pipeline_versions`; a hash recorded before
data versions (null), or not at all, has none. So new code that keeps every
`version=` (a renamed type in a step's signature, a read added) leaves keys
done, a raised `version=` leaves them not done, and a new mapped step leaves
them not done until it has run. A pipeline with no mapped step has a key
done when a run over it of its current data version succeeded. The two are
separate halves, each empty when the other applies. The first looks each
key's steps up by index (the `CASE` keeps Postgres from hashing every step
of every pipeline instead), with the pipeline's few hashes' data versions
read once (`h`, by `pipeline_versions`'s unique index); the second joins the
keys to its runs' keys, read once, rather than scanning the runs again for
each key (1.2 s for 1,500 keys over 30,000 runs when it was a `CASE` branch
too, 10 ms now)."""


def done_keys(
    mut conn: Connection, pipeline: String, keys: String
) raises -> List[String]:
    """Which of `keys` (comma-separated) are done for `pipeline`
    (`DONE_SQL`)."""
    var out = List[String]()
    for r in conn.query(DONE_SQL, Params().text(pipeline).text(keys)):
        out.append(r.text("key"))
    return out^


def done_keys(
    mut tx: Transaction, pipeline: String, keys: String
) raises -> List[String]:
    """`done_keys`, in `tx`."""
    var out = List[String]()
    for r in tx.query(DONE_SQL, Params().text(pipeline).text(keys)):
        out.append(r.text("key"))
    return out^


def queue_run(
    mut tx: Transaction,
    pipeline: String,
    registry_hash: String,
    keys: String,
    trigger: String,
) raises -> Int:
    """A new queued run of `pipeline` over `keys` (comma-separated)."""
    return Int(
        tx.query(
            (
                "INSERT INTO orca.runs (pipeline, registry_hash,"
                " partitions, trigger, status) VALUES ($1, $2, $3, $4,"
                " 'queued') RETURNING id"
            ),
            Params()
            .text(pipeline)
            .text(registry_hash)
            .text(keys)
            .text(trigger),
        )
        .row(0)
        .int64("id")
    )


comptime APPENDING_SQL = (
    "SELECT x.st->>'name' AS step, w.ds FROM orca.pipelines p,"
    " jsonb_array_elements(p.describe->'steps') WITH ORDINALITY AS x(st, n),"
    " jsonb_array_elements_text(coalesce(x.st->'writes', '[]'::jsonb)) AS"
    " w(ds) WHERE p.name = $1 AND x.n > $2 AND NOT coalesce(x.st->'replaces',"
    " '[]'::jsonb) ? w.ds ORDER BY x.n, w.ds"
)
"""`step` and `ds` for each dataset a step of pipeline `$1` after its
first `$2` declares in `writes=` and not in `replaces=`."""


def appending_writes(
    mut conn: Connection, pipeline: String, from_step: Int
) raises -> List[Tuple[String, String]]:
    """Each step and dataset of `APPENDING_SQL`."""
    var out = List[Tuple[String, String]]()
    for r in conn.query(
        APPENDING_SQL, Params().text(pipeline).int64(Int64(from_step))
    ):
        out.append((r.text("step"), r.text("ds")))
    return out^
