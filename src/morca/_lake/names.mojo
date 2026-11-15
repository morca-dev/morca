"""Names and defaults that both sides of liblake need: where the warehouse
is, which dataset a location is, and the properties morca gives a table.
No iceberg here."""

from std.os import getenv

from morca._common.paths import absolute


def warehouse() -> String:
    """`MORCA_WAREHOUSE`: the root datasets are found under, or empty."""
    return getenv("MORCA_WAREHOUSE")


def _norm(path: String) raises -> String:
    """A location without its trailing slashes; a local one absolute."""
    var p = String(path.removeprefix("file://"))
    while p.endswith("/") and p.byte_length() > 1:
        var cut = String(p[byte = : p.byte_length() - 1])
        p = cut^
    if "://" in p:
        return p^
    return absolute(p)


def dataset_of(location: String) raises -> String:
    """The dataset a table at `location` is, `namespace.table`, or empty if
    it isn't directly under a namespace in the warehouse."""
    var root = warehouse()
    if not root:
        return ""
    var base = String(_norm(root), "/")
    var loc = _norm(location)
    if not loc.startswith(base):
        return ""
    var rel = loc[byte = base.byte_length() :]
    var parts = rel.split("/")
    if len(parts) != 2 or not parts[0] or not parts[1]:
        return ""
    return String(parts[0], ".", parts[1])


def _split(dataset: String) raises -> Tuple[String, String]:
    var dot = dataset.rfind(".")
    if dot <= 0 or dot == dataset.byte_length() - 1:
        raise Error("morca: a dataset is named namespace.table, not ", dataset)
    return (
        String(dataset[byte=:dot]),
        String(dataset[byte = dot + 1 :]),
    )


comptime DAY_MS: Int64 = 86_400_000
comptime DEFAULT_HISTORY_DAYS = 30
"""How long a morca table keeps its snapshots by default."""


def table_defaults() -> Dict[String, String]:
    """The properties `ensure_table` gives every table it creates, and adds
    to one that lacks them.

    - `write.metadata.delete-after-commit.enabled=true` and
      `write.metadata.previous-versions-max=100`: each commit deletes the
      metadata files older than the last hundred, so `metadata/` stops
      growing by one file per commit.
    - `history.expire.max-snapshot-age-ms` (30 days): the history the
      scheduler's expiry keeps (`morca expire`, `MORCA_EXPIRE_HOURS`). Its
      presence is also what makes the scheduler expire the table at all;
      a table morca didn't create keeps all its snapshots.
    """
    var d = Dict[String, String]()
    d["write.metadata.delete-after-commit.enabled"] = "true"
    d["write.metadata.previous-versions-max"] = "100"
    d["history.expire.max-snapshot-age-ms"] = String(
        DAY_MS * DEFAULT_HISTORY_DAYS
    )
    return d^
