"""Worker groups (docs/groups.md): a pipeline's workers in named groups,
each with its own size and GPUs, from morca.toml.

    [pipelines.embed.groups.gpu]
    workers = "0..2"   # a count or MIN..MAX, as the pipeline's workers
    gpus = 1           # whole GPUs per worker, 0 by default
    cpus = 4           # per worker; unset, the pipeline's cpus
    memory_gb = 16     # per worker; unset, the pipeline's memory_gb

A group's name is lowercase letters, digits, `-` and `_`, starting with a
letter, at most 32 bytes. `register` keeps the groups in
`orca.pipelines.groups` (`groups_json`, by name, so the file's order
doesn't matter), `morca config show` and `export` show them, and nothing
uses them yet: no worker is started with a group, and no demand counts
one (PR 1 of docs/groups.md). The `ec2` placement ignores them
(`ec2_ignores_groups`).
"""

from json import loads

from morca._internal.json import quote
from morca._internal.resources import (
    Request,
    canonical_cpus,
    canonical_memory_gb,
    parse_workers,
)
from morca._internal.toml import (
    FLOAT,
    INTEGER,
    STRING,
    TABLE,
    TomlDoc,
    TomlValue,
    toml_key,
    toml_string,
)

comptime MAX_GROUP_NAME = 32
"""The longest group name, in bytes."""
comptime MAX_GPUS = 64
"""The most GPUs a group's worker may ask for."""
comptime GROUP_KEYS = ["workers", "gpus", "cpus", "memory_gb"]
"""The keys of `[pipelines.<name>.groups.<group>]`."""


@fieldwise_init
struct Group(Copyable, Equatable, Movable):
    """One group of a pipeline's workers, as registered: its values in
    their stored text forms (`morca._internal.resources`' canonical ones)."""

    var name: String
    var min_workers: Int
    """Its fewest workers; equal to `max_workers` for a count."""
    var max_workers: Int
    var gpus: Int
    """Whole GPUs per worker, 0 for none."""
    var cpus: String
    """CPUs per worker, `N` or `MIN..MAX`; empty for the pipeline's."""
    var memory_gb: String
    """Memory per worker in GB; empty for the pipeline's."""

    def workers_text(self) -> String:
        """`workers` as stored: `N` for a count, else `MIN..MAX`."""
        if self.min_workers == self.max_workers:
            return String(self.max_workers)
        return String(self.min_workers, "..", self.max_workers)

    def effective(self, cpus: String, memory_gb: String) -> Group:
        """The group with what it doesn't set taken from the pipeline's
        `cpus` and `memory_gb` (either empty for none)."""
        return Group(
            self.name,
            self.min_workers,
            self.max_workers,
            self.gpus,
            self.cpus if self.cpus else cpus,
            self.memory_gb if self.memory_gb else memory_gb,
        )

    def request(self) raises -> Request:
        """Its CPUs, memory and GPUs as a `Request`, as given: call it on
        `effective`'s result for the fallbacks."""
        var r = Request.of(self.cpus, self.memory_gb)
        r.gpus = self.gpus
        return r

    def toml_text(self) -> String:
        """The group as an inline table, as `morca config show` and
        `export` write it: `{ workers = "0..2", gpus = 1, cpus = "4" }`."""
        var out = String("{ workers = ")
        if self.min_workers == self.max_workers:
            out.write(self.max_workers)
        else:
            out.write(toml_string(self.workers_text()))
        if self.gpus > 0:
            out.write(", gpus = ", self.gpus)
        if self.cpus:
            out.write(", cpus = ", toml_string(self.cpus))
        if self.memory_gb:
            out.write(", memory_gb = ", toml_string(self.memory_gb))
        out.write(" }")
        return out^

    def json(self) -> String:
        var out = String(
            '{"name": ',
            quote(self.name),
            ', "workers": ',
            quote(self.workers_text()),
            ', "gpus": ',
            self.gpus,
        )
        if self.cpus:
            out.write(', "cpus": ', quote(self.cpus))
        if self.memory_gb:
            out.write(', "memory_gb": ', quote(self.memory_gb))
        out.write("}")
        return out^


def group_name_problem(name: String) -> String:
    """Why `name` can't be a group's, or empty if it can."""
    var n = name.byte_length()
    if n == 0:
        return "a group's name can't be empty"
    if n > MAX_GROUP_NAME:
        return String(
            "a group's name is at most ", MAX_GROUP_NAME, " bytes, not ", name
        )
    var first = True
    for b in name.as_bytes():
        var c = Int(b)
        var letter = c >= ord("a") and c <= ord("z")
        var other = (
            (c >= ord("0") and c <= ord("9")) or c == ord("-") or c == ord("_")
        )
        if not letter and (first or not other):
            return String(
                "a group's name is lowercase letters, digits, - and _,",
                " starting with a letter, not ",
                name,
            )
        first = False
    return ""


def is_group_key(key: String) -> Bool:
    for k in materialize[GROUP_KEYS]():
        if key == k:
            return True
    return False


def group_value(key: String, v: TomlValue) raises -> String:
    """A group's `key`, checked, in its stored text form."""
    if key == "workers":
        if v.kind != INTEGER and v.kind != STRING:
            raise Error('is a count or a string "MIN..MAX", not ', v.kind)
        var w = parse_workers(v.text)
        if w[0] < 0:
            return String(w[1])
        if w[0] == w[1]:
            return String(w[1])
        return String(w[0], "..", w[1])
    if key == "gpus":
        if v.kind != INTEGER:
            raise Error("is a count of whole GPUs, not ", v.kind)
        var n = -1
        try:
            n = Int(v.text)
        except:
            pass
        if n < 0 or n > MAX_GPUS:
            raise Error("is a count from 0 to ", MAX_GPUS, ", not ", v.text)
        return String(n)
    if key == "cpus":
        if v.kind != INTEGER and v.kind != STRING:
            raise Error('is a count or a string "MIN..MAX", not ', v.kind)
        return canonical_cpus(v.text)
    if key == "memory_gb":
        if v.kind != INTEGER and v.kind != FLOAT and v.kind != STRING:
            raise Error('is GB, a number or a string "MIN..MAX", not ', v.kind)
        return canonical_memory_gb(v.text)
    raise Error("unknown key ", key)


@fieldwise_init
struct GroupProblem(Copyable, Movable):
    """Why a table's `groups` is refused: the path it's about, for its
    `file:line`, and the reason."""

    var path: List[String]
    var msg: String


def groups_problem(doc: TomlDoc, path: List[String]) -> Optional[GroupProblem]:
    """The first thing wrong with `groups` at `path` (`[pipelines.<name>]`'s
    or `[defaults]`'), or none."""
    var p = path.copy()
    p.append("groups")
    var v = doc.get(p)
    if not v:
        return None
    if path[0] == "defaults":
        return GroupProblem(
            p^,
            "groups is a pipeline's own: [pipelines.<name>.groups.<group>]",
        )
    if v.value().kind != TABLE:
        return GroupProblem(
            p^,
            "groups is a table of [pipelines.<name>.groups.<group>]",
        )
    for name in doc.keys(p):
        var q = p.copy()
        q.append(name)
        var why = group_name_problem(name)
        if why:
            return GroupProblem(q^, String("groups: ", why))
        if not doc.has_table(q):
            return GroupProblem(
                q^,
                String(
                    "groups.",
                    toml_key(name),
                    " isn't a table: a group's settings are",
                    " [pipelines.<name>.groups.<group>]",
                ),
            )
        var label = String("groups.", toml_key(name))
        for key in doc.keys(q):
            var k = q.copy()
            k.append(key)
            if not is_group_key(key):
                return GroupProblem(
                    k^,
                    String(
                        label,
                        " has no key ",
                        toml_key(key),
                        " (it has workers, gpus, cpus and memory_gb)",
                    ),
                )
            var item = doc.get(k).value().copy()
            try:
                _ = group_value(key, item)
            except e:
                return GroupProblem(k^, String(label, " ", key, ": ", e))
        var w = q.copy()
        w.append("workers")
        if not doc.get(w):
            return GroupProblem(
                q^,
                String(label, ' needs workers, a count or "MIN..MAX"'),
            )
    return None


def read_groups(doc: TomlDoc, pipeline: String) raises -> List[Group]:
    """`[pipelines.<pipeline>.groups.*]`, checked (`groups_problem`), by
    name."""
    var out = List[Group]()
    var p: List[String] = ["pipelines", pipeline, "groups"]
    if not doc.has_table(p):
        return out^
    for name in doc.keys(p):
        var q = p.copy()
        q.append(name)
        var values = Dict[String, String]()
        for key in doc.keys(q):
            var k = q.copy()
            k.append(key)
            values[key] = group_value(key, doc.get(k).value())
        out.append(
            group_of(
                name,
                values.get("workers", ""),
                values.get("gpus", "0"),
                values.get("cpus", ""),
                values.get("memory_gb", ""),
            )
        )
    return by_name(out^)


def group_of(
    name: String,
    workers: String,
    gpus: String,
    cpus: String,
    memory_gb: String,
) raises -> Group:
    """A group from its stored text forms."""
    var w = parse_workers(workers)
    var lo = w[1] if w[0] < 0 else w[0]
    return Group(name, lo, w[1], Int(gpus) if gpus else 0, cpus, memory_gb)


def by_name(var groups: List[Group]) -> List[Group]:
    """`groups` sorted by name: their stored, canonical order."""
    for i in range(1, len(groups)):
        var j = i
        while j > 0 and groups[j].name < groups[j - 1].name:
            groups.swap_elements(j, j - 1)
            j -= 1
    return groups^


def groups_json(groups: List[Group]) -> String:
    """`orca.pipelines.groups`: a JSON array of the groups by name; empty
    for none, which is stored as null."""
    if len(groups) == 0:
        return ""
    var sorted = by_name(groups.copy())
    var out = String("[")
    for i in range(len(sorted)):
        out.write("" if i == 0 else ", ", sorted[i].json())
    out.write("]")
    return out^


def parse_groups(text: String) raises -> List[Group]:
    """`groups_json`'s array back; empty text (null) is none."""
    var out = List[Group]()
    if not text:
        return out^
    for v in loads(text).array_items():
        var cpus = v.get("cpus")
        var memory = v.get("memory_gb")
        out.append(
            group_of(
                v["name"].string_value(),
                v["workers"].string_value(),
                String(v["gpus"].int_value()),
                cpus.value().string_value() if cpus else String(),
                memory.value().string_value() if memory else String(),
            )
        )
    return out^


def ec2_ignores_groups(
    pipeline: String, placement: String, groups: List[Group]
) -> String:
    """A warning when a pipeline placed on `ec2` declares groups, which
    that placement ignores (docs/groups.md); empty otherwise."""
    if placement != "ec2" or len(groups) == 0:
        return ""
    var names = String()
    for g in groups:
        names.write(", " if names else "", g.name)
    return String(
        pipeline,
        " declares groups (",
        names,
        ") but is placed on ec2: the ec2 placement ignores groups",
    )
