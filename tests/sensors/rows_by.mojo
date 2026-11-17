"""Reads a dataset with morca.tables, outside any step, and prints each
value of a string column with how many rows have it, sorted: the
conformance suite's Mojo reader of a table another binary replaced
(tests/conformance/replace*.json, "rows").

    rows_by <warehouse> <dataset> <column>
"""

from std.os import setenv
from std.sys import argv

from morca.tables import load_dataset


def main() raises:
    var args = argv()
    if len(args) != 4:
        raise Error("usage: rows_by <warehouse> <dataset> <column>")
    _ = setenv("MORCA_WAREHOUSE", String(args[1]))
    var column = String(args[3])
    var by = Dict[String, Int]()
    for b in load_dataset(String(args[2])).scan().to_batches():
        for i in range(b.num_columns()):
            if b.name(i) == column:
                for v in b.column_str(i)[0]:
                    by[v] = by.get(v, 0) + 1
    var keys = List[String]()
    for k in by.keys():
        keys.append(k)
    sort(keys)
    for k in keys:
        print(k, by[k])
