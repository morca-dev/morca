"""Hand-over's queries (`morca._internal.handover`): whether a run is outdated, its
code against its pipeline's and its scheduler instance's draining."""

from postgres import Connection, Params


def label_sql(v: String) -> String:
    """`version_label` in SQL, over the `orca.pipeline_versions` row `v`
    (null for none: empty)."""
    return String(
        "CASE WHEN ",
        v,
        ".id IS NULL THEN '' WHEN ",
        v,
        ".commit_sha <> '' THEN left(",
        v,
        ".commit_sha, 12) || CASE WHEN ",
        v,
        ".dirty THEN '+dirty' ELSE '' END ELSE 'code ' || ",
        v,
        ".registry_hash END",
    )


def differs_sql(a: String, b: String) -> String:
    """SQL true when the versions `a` and `b` (rows of
    `orca.pipeline_versions`) are other code: the commit, its dirtiness or
    the registry hash differ; false when either is null."""
    return String(
        "coalesce(",
        a,
        ".registry_hash <> ",
        b,
        ".registry_hash OR ",
        a,
        ".commit_sha <> ",
        b,
        ".commit_sha OR ",
        a,
        ".dirty <> ",
        b,
        ".dirty, false)",
    )


def draining_sql(s: String, r: String) -> String:
    """SQL true when the run `r` (a row of `orca.runs`) is held by the
    scheduler instance `s` (its `orca.schedulers` row, null for none) and
    that instance drains: a newer one leads, or it was asked to."""
    return String(
        "coalesce((",
        s,
        ".draining_since IS NOT NULL OR ",
        s,
        ".drain_asked IS NOT NULL) AND ",
        s,
        ".ended IS NULL AND ",
        r,
        ".id::text = ANY(string_to_array(",
        s,
        ".running, ',')), false)",
    )


def outdated_sql() -> String:
    """One run's outdatedness, for the run `$1` (module doc): `outdated`,
    `mine` and `desired` (labels), `differs` (other code is registered),
    `newer` (registered after the run's), `draining` (its instance drains)
    and `leader` (the newest instance that doesn't drain, which leads or
    is about to, or 0)."""
    var draining = draining_sql("s", "r")
    return String(
        "SELECT r.status = 'running' AND (",
        differs_sql("rv", "pv"),
        " OR ",
        draining,
        ") AS outdated, ",
        label_sql("rv"),
        " AS mine, ",
        label_sql("pv"),
        " AS desired, ",
        differs_sql("rv", "pv"),
        " AS differs, coalesce(pv.id > rv.id, false) AS newer, ",
        draining,
        " AS draining, coalesce((SELECT max(l.id) FROM orca.schedulers l",
        " WHERE l.ended IS NULL AND l.draining_since IS NULL AND",
        " l.drain_asked IS NULL), 0) AS leader",
        " FROM orca.runs r JOIN orca.pipelines p ON p.name = r.pipeline",
        " LEFT JOIN orca.pipeline_versions rv ON rv.id = r.version",
        " LEFT JOIN orca.pipeline_versions pv ON pv.id = p.version",
        " LEFT JOIN orca.schedulers s ON s.id = r.instance WHERE r.id = $1",
    )


@fieldwise_init
struct Outdatedness(Copyable, Movable):
    """`outdated_sql`'s row."""

    var outdated: Bool
    var mine: String
    var desired: String
    var differs: Bool
    var newer: Bool
    var leader: Int


def outdatedness(
    mut conn: Connection, run: Int
) raises -> Optional[Outdatedness]:
    """`outdated_sql` of `run`; None if there's no such run."""
    var rows = conn.query(outdated_sql(), Params().int64(Int64(run)))
    if len(rows) == 0:
        return None
    var r = rows.row(0)
    return Outdatedness(
        r.bool("outdated"),
        r.text("mine"),
        r.text("desired"),
        r.bool("differs"),
        r.bool("newer"),
        Int(r.int64("leader")),
    )
