"""Datasets' settings (#435): a `[datasets.<name>]` table in morca.toml,
read and checked here and recorded by `morca register` in
`orca.dataset_settings`, which the UI reads.

    [datasets."hindcast.t2m"]
    public = false        # its Data tab only for those logged in

    [datasets.lake.raw]   # the same as [datasets."lake.raw"]
    public = false

A dataset's name is `namespace.table`, so its header is either quoted or
two keys deep. `public` (default `true`) says whether visitors who aren't
logged in see the dataset's data on its page (`/datasets/<name>?tab=data`
and `data.json`, `data.csv`); its structure, snapshots and lineage stay
public, as the rest of the UI is.
"""

import morca._internal.db.dataset_settings as settings_db

from morca._internal.json import quote
from morca._internal.state import State
from morca._internal.toml import BOOLEAN, TomlDoc, toml_key

comptime DATASET_KEYS = ["public"]


@fieldwise_init
struct DatasetConfig(Copyable, Movable):
    """A `[datasets.<name>]` table, checked."""

    var name: String
    var public: Bool


@fieldwise_init
struct DatasetProblem(Copyable, Movable):
    """Why a file's `[datasets]` is refused: the path it's about, for its
    `file:line`, the table and the reason."""

    var path: List[String]
    var table: String
    var msg: String


def _sub(path: List[String], key: String) -> List[String]:
    var p = path.copy()
    p.append(key)
    return p^


def _tables(doc: TomlDoc) -> List[Tuple[String, List[String]]]:
    """Each dataset's name and the path of its table: `[datasets."a.b"]`
    is `a.b`, and so is `[datasets.a.b]` (a table of tables)."""
    var out = List[Tuple[String, List[String]]]()
    for k in doc.keys(["datasets"]):
        var p: List[String] = ["datasets", k]
        if "." in k or not doc.has_table(p):
            out.append((k, p^))
            continue
        var nested = True
        for t in doc.keys(p):
            nested = nested and doc.has_table(_sub(p, t))
        if not nested or len(doc.keys(p)) == 0:
            out.append((k, p^))
            continue
        for t in doc.keys(p):
            out.append((String(k, ".", t), _sub(p, t)))
    return out^


def _name_problem(name: String) -> String:
    var dot = name.find(".").or_else(-1)
    if (
        dot <= 0
        or dot == name.byte_length() - 1
        or name.find(".", dot + 1).or_else(-1) >= 0
    ):
        return String(
            'a dataset is named namespace.table ([datasets."ns.table"]), not ',
            name,
        )
    return ""


def datasets_problem(doc: TomlDoc) -> Optional[DatasetProblem]:
    """The first thing wrong with the file's `[datasets]`, or none."""
    var top: List[String] = ["datasets"]
    if not doc.get(top):
        return None
    if not doc.has_table(top):
        return DatasetProblem(
            top.copy(), "datasets", 'is a table of [datasets."<name>"]'
        )
    for e in _tables(doc):
        ref name = e[0]
        ref path = e[1]
        var table = String("[datasets.", toml_key(name), "]")
        var why = _name_problem(name)
        if why:
            return DatasetProblem(path.copy(), table, why)
        if not doc.has_table(path):
            return DatasetProblem(path.copy(), table, "isn't a table")
        for key in doc.keys(path):
            var p = _sub(path, key)
            if key != "public":
                return DatasetProblem(
                    p.copy(),
                    table,
                    String("has no key ", toml_key(key), " (it has public)"),
                )
            if doc.get(p).value().kind != BOOLEAN:
                return DatasetProblem(
                    p.copy(), table, "public is true or false"
                )
    return None


def read_datasets(doc: TomlDoc) raises -> List[DatasetConfig]:
    """The file's `[datasets.<name>]` tables, checked, in the file's
    order."""
    var why = datasets_problem(doc)
    if why:
        var p = why.value().copy()
        raise Error(p.table, " ", p.msg)
    var out = List[DatasetConfig]()
    if not doc.has_table(["datasets"]):
        return out^
    for e in _tables(doc):
        var v = doc.get(_sub(e[1], "public"))
        out.append(DatasetConfig(e[0], not v or v.value().text == "true"))
    return out^


def record_datasets(
    mut db: State, datasets: List[DatasetConfig]
) raises -> List[String]:
    """Makes `orca.dataset_settings` what morca.toml says: each dataset
    upserted, and one the file no longer names deleted, which makes it
    public again. The datasets deleted."""
    var tx = db.conn.begin()
    var names = String("[")
    for i in range(len(datasets)):
        ref d = datasets[i]
        settings_db.upsert_dataset(tx, d.name, d.public)
        names.write(", " if i > 0 else "", quote(d.name))
    names.write("]")
    var gone = settings_db.delete_datasets_but(tx, names)
    tx.commit()
    return gone^


def private_datasets(mut db: State) raises -> List[String]:
    """The datasets whose data visitors not logged in don't see; their
    Data links carry `data-link--private`, which the stylesheet hides for
    them (`body.anon`)."""
    return settings_db.private_datasets(db.conn)


def dataset_public(mut db: State, name: String) raises -> Bool:
    """Whether morca.toml leaves `name`'s data public (the default)."""
    return settings_db.is_public(db.conn, name)
