"""Keyed partitions: keys that are names, read from a column of a dataset.

```mojo
from morca.keyed import Keyed

comptime Labels = Pipeline[
    "labels", Label, Score, partitions=Keyed["av2.logs", "log_id"], keys_per_run=100
]
```

The keys are the distinct values of `column` in the current snapshot of the
warehouse dataset `dataset` (`MORCA_WAREHOUSE`), each a `Name`. They live in
data rather than in the source because there can be thousands and they
grow. A value that isn't a name, or is null, isn't a key: it's left out,
and `keys` says how many there were on stderr. `--partitions` takes a list of names, `@all` for every current key,
or `@file:<path>` for a list one per line; a range is refused, and so is a
name the dataset doesn't have, so a typo doesn't make a run of nothing.
`<binary> keys` prints the snapshot and the keys, for the scheduler, which
links no iceberg.

A keyed pipeline has no calendar, so `schedule=` and `fire=` don't compile
with one (`Pipeline.check`). It reads the keys through `morca.tables`
(liblake), so only binaries with a keyed pipeline load the library.
"""

from std.sys import stderr

from morca.name import Name, parse_names, sort_texts
from morca.partitions import Partitions
from morca.tables import load_dataset, strings_of


def _read_file(path: String) raises -> String:
    """The names in `path`, one per line, as a comma-separated list."""
    var text: String
    with open(path, "r") as f:
        text = f.read()
    var joined = String()
    var at = 0
    for line in text.splitlines():
        at += 1
        var n = line.strip()
        if n:
            # The error names the line, not its text: a file's other
            # contents stay out of the message.
            try:
                _ = Name.parse(n)
            except:
                raise Error("line ", at, " of ", path, " isn't a name")
            joined.write("," if joined else "", n)
    if not joined:
        raise Error("no names in ", path)
    return joined^


struct Keyed[dataset_: StaticString, column_: StaticString](Partitions):
    """A partition per distinct value of `column_` in the dataset
    `dataset_` (`namespace.table`)."""

    comptime K = Name

    @staticmethod
    def kind() -> StaticString:
        return "keyed"

    @staticmethod
    def start() -> StaticString:
        return ""

    @staticmethod
    def dataset() -> StaticString:
        return Self.dataset_

    @staticmethod
    def column() -> StaticString:
        return Self.column_

    @staticmethod
    def parse(s: StringSlice, check: Bool) raises -> List[Name]:
        if s == "@all":
            var out = List[Name]()
            for k in Self.keys()[1]:
                out.append(Name(k))
            if len(out) == 0:
                raise Error(Self.dataset_, " has no keys")
            return out^
        var names: List[Name]
        if s.startswith("@file:"):
            names = parse_names(_read_file(String(s[byte=6:])))
        else:
            names = parse_names(s)
        if check:
            var have = Dict[String, Bool]()
            for k in Self.keys()[1]:
                have[k] = True
            for n in names:
                if n.text not in have:
                    raise Error(
                        n,
                        " isn't a key of ",
                        Self.dataset_,
                        " (",
                        Self.column_,
                        ")",
                    )
        return names^

    @staticmethod
    def fill(
        year: Int, month: Int, day: Int, hour: Int, previous: Bool
    ) raises -> Name:
        raise Error("morca: keyed partitions have no calendar to fill")

    @staticmethod
    def keys() raises -> Tuple[Int64, List[String]]:
        var t = load_dataset(Self.dataset_)
        if not t.metadata.has_current_snapshot:
            return (Int64(-1), List[String]())
        var id = t.metadata.current_snapshot_id
        var values = List[Optional[String]]()
        var scan = t.scan().use_snapshot(id).select([String(Self.column_)])
        for b in scan.to_batches():
            values.extend(strings_of(b, String(Self.column_)))
        var seen = Dict[String, Bool]()
        var out = List[String]()
        var bad = List[String]()
        var n_bad = 0
        for v in values:
            if not v or v.value() in seen:
                continue
            var s = v.value()
            seen[s] = True
            # Each must be a name, or it can't be a partition: one that
            # isn't is left out, and said, rather than stopping the rest.
            try:
                _ = Name.parse(s)
            except e:
                n_bad += 1
                if len(bad) < 5:
                    bad.append(String(e))
                continue
            out.append(s)
        if n_bad > 0:
            var why = String()
            for i in range(len(bad)):
                why.write("; " if i else "", bad[i])
            print(
                "morca: ",
                Self.dataset_,
                " (",
                Self.column_,
                ") has ",
                n_bad,
                " values that aren't names, left out of its keys: ",
                why,
                "; ..." if n_bad > len(bad) else "",
                sep="",
                file=stderr,
            )
        sort_texts(out)
        return (id, out^)
