"""`morca.toml`: one checked-in file for how each of a project's pipelines
runs (#145), read by `morca register` and `morca aws register`.

    [defaults]
    placement = "ec2"
    head_type = "t4g.medium"

    [pipelines.gharchive]
    worker_type = "c7g.xlarge"
    workers = "0..4"             # or a count, 4
    worker_procs = 1             # or "auto", one per vCPU
    max_runs = 2                 # over the code's Pipeline max_runs
    keys_per_run = 30            # over the code's: keys a run takes (#240)
    priority = 10                # higher starts first when room is short (#421)
    concurrency = { key = "lake", limit = 1 }   # across pipelines (#397)
    cpus = "1..16"               # a request: MIN..MAX (morca.resources)
    memory_gb = "2..24"          # or "auto", "auto..24" (morca.recommend)
    learn = false                # don't: "auto" is then no request
    env = { DISTA_WORKER_SLOTS = "4", GHARCHIVE_PARALLEL = "16" }
    secrets = { GITHUB_TOKEN = "orca/github-token" }   # Secrets Manager IDs
    fills = "all"                # fill the range by itself (morca.fill)
    fill_budget_per_day = 5.0    # and the rest of the fill* keys
    enabled = false              # `morca register` skips it (a stack's overlay)

    [stack]                      # for `morca aws up`; not read yet

`morca config check [<file>] [--secrets]` checks a file without a database,
for a project's CI: what registering checks, and that morca can size each
instance type (a warning for one its price table hasn't); with `--secrets`,
that each secret can be read (its value is never printed). The pipeline
page's Configuration (`config_html`) is `morca config show`'s.

What stays in the pipeline's code is what it does; this file says where and
how much. A key in `[pipelines.<name>]` beats the same key in `[defaults]`
(`env` and `secrets` are merged name by name), and a flag of `morca register`
beats both, recorded with the registration as an override. A pipeline the
file names is registered with exactly what it and its flags say: a key
taken out of the file goes back to its default. `[defaults]` applies only to
the pipelines the file names; one it doesn't name is registered as before,
each flag left out keeping what was registered.

A stack's overlay (`MORCA_CONFIG_OVERLAY`, `--overlay`; docs/morca-toml.md)
is laid on the file before anything is read (`TomlDoc.merge`): its values
replace the file's, its tables are merged key by key, and a pipeline it
names must be in the file. A value it set says so where it's shown.

The registration keeps the file's SHA-256 and its git commit (and whether
it had changes not committed) in `orca.pipelines.config`, with where each
value came from, for `morca config show`. `morca config export` writes the
file back from what's registered.

**Adding a key**: a name in `SCALAR_KEYS` and its check in `_canonical`
(and its types in `_canonical_toml`), which gives the value as text; it is
then read, merged, overridden, recorded, shown and exported like the
others, and only its consumer is new. The `fill*` keys (#155, `morca._internal.fill`)
were added this way, with no flag.
"""

from std.base64 import b64decode
from std.os import getenv
from std.os.path import exists

from objectstore.crypto import sha256_hex

from morca._internal.concurrency import (
    concurrency_text,
    parse_concurrency,
)
from morca._internal.control import parse_placement
from morca._internal.fill import (
    lag_text,
    parse_fill_budget,
    parse_fill_lag,
    fill_max_runs_auto,
    fill_max_runs_text,
    parse_fill_max_runs,
    parse_fill_order,
    parse_fill_window,
    parse_fills,
)
from morca._internal.json import quote
from morca._common.paths import absolute
from morca._internal.proc import (
    capture,
)
from morca._internal.resources import (
    canonical_cpus,
    canonical_memory_gb,
)
from morca._internal.secrets import (
    env_name_problem,
    parse_secrets,
    secret_problem,
)
from morca._internal.apps_config import AppConfig, apps_problem, read_apps
from morca._internal.dataset_config import datasets_problem
from morca._internal.pool_config import read_pools
from morca._internal.toml import (
    BOOLEAN,
    FLOAT,
    INTEGER,
    STRING,
    TABLE,
    TomlDoc,
    TomlValue,
    parse_toml,
    path_key,
    toml_key,
)

comptime CODE_DEFAULT = "code default"
comptime FROM_FILE = "morca.toml"
comptime FROM_FLAG = "flag"


def refuse_orca_toml() raises:
    """Raises when the project still has orca.toml and no morca.toml: the
    file was renamed with the project (#384), and a register that read no
    file would quietly drop its settings."""
    if exists("orca.toml") and not exists("morca.toml"):
        raise Error(
            "morca: this project has orca.toml, which morca doesn't read:"
            " rename it to morca.toml (and orca.<stack>.toml to"
            " morca.<stack>.toml)"
        )


comptime FROM_ENV = "environment"

comptime SCALAR_KEYS = [
    "placement",
    "head_type",
    "worker_type",
    "workers",
    "worker_procs",
    "max_runs",
    "keys_per_run",
    "cpus",
    "memory_gb",
    "learn",
    "fills",
    "fill_order",
    "fill_max_runs",
    "fill_budget_per_day",
    "fill_window",
    "fill_lag",
    "priority",
]
"""The keys of `[defaults]` and `[pipelines.<name>]` with one value. The
`fill*` keys (`morca._internal.fill`) and `priority` are the file's only: no
flag sets them."""
comptime MAP_KEYS = ["secrets", "env"]
"""The keys whose value is a table of names."""


def flag_of(key: String) -> String:
    """The `morca register` flag of `key`: `--head-type` of `head_type`."""
    return String("--", key.replace("_", "-"))


def parse_worker_procs(v: String) raises -> Int:
    """`--worker-procs`'s value: a count of at least 1, or `auto` (returned
    as 0), one process per vCPU of the worker type."""
    if v == "auto":
        return 0
    try:
        var n = Int(v)
        if n >= 1 and n <= 256:
            return n
    except:
        pass
    raise Error("--worker-procs is a count from 1 to 256 or auto, not ", v)


def parse_workers(v: String) raises -> Tuple[Int, Int]:
    """`--workers`' value, `N` or `MIN..MAX`: the fewest (-1 for a fixed
    count) and the most."""
    try:
        var dots = v.find("..").or_else(-1)
        if dots >= 0:
            var lo = Int(v[byte=:dots])
            var hi = Int(v[byte = dots + 2 :])
            if lo >= 0 and hi >= max(lo, 1):
                return (lo, hi)
        else:
            var n = Int(v)
            if n >= 1:
                return (-1, n)
    except:
        pass
    raise Error("not a count or a range MIN..MAX: ", v)


comptime AUTO_MAX_RUNS = 64
"""`max_runs = "auto"`'s ceiling when it names none."""


def parse_max_runs(v: String) raises -> Int:
    """`max_runs`' count, or for `auto` and `auto..N` its ceiling (64, or
    N): `max_runs_auto` says which."""
    var t = v
    if v == "auto":
        return AUTO_MAX_RUNS
    if v.startswith("auto.."):
        t = String(v[byte = String("auto..").byte_length() :])
    try:
        var n = Int(t)
        if n >= 1 and n <= 10000:
            return n
    except:
        pass
    raise Error(
        'max_runs is a count from 1 to 10000, "auto" or "auto..N", not ', v
    )


comptime MAX_KEYS_PER_RUN = 10000
"""The most keys `keys_per_run` may put in one run."""


def parse_keys_per_run(v: String) raises -> Int:
    """`keys_per_run`: how many keys a backfill, a sensor's run or a fill
    run takes (#240), from 1 to `MAX_KEYS_PER_RUN`."""
    try:
        var n = Int(v)
        if n >= 1 and n <= MAX_KEYS_PER_RUN:
            return n
    except:
        pass
    raise Error(
        "keys_per_run is a count from 1 to ", MAX_KEYS_PER_RUN, ", not ", v
    )


comptime MAX_PRIORITY = 1000
"""`priority`'s largest value; its smallest is the negative."""


def parse_priority(v: String) raises -> Int:
    """`priority` (#421): an integer from -1000 to 1000, 0 by default; the
    scheduler's pass starts the pipelines highest first."""
    try:
        var n = Int(v)
        if n >= -MAX_PRIORITY and n <= MAX_PRIORITY:
            return n
    except:
        pass
    raise Error(
        "priority is an integer from ",
        -MAX_PRIORITY,
        " to ",
        MAX_PRIORITY,
        ", not ",
        v,
    )


def max_runs_auto(v: String) -> Bool:
    """Whether `max_runs`' value is `auto` or `auto..N` (#266): as many
    runs at once as this host has room for, up to the ceiling."""
    return v == "auto" or v.startswith("auto..")


def max_runs_text(n: Int, auto: Bool) -> String:
    """`max_runs` as morca.toml writes it."""
    if not auto:
        return String(n)
    if n == AUTO_MAX_RUNS:
        return String("auto")
    return String("auto..", n)


def _instance_type(v: String) raises -> String:
    var dot = v.find(".").or_else(-1)
    var ok = dot > 0 and dot < v.byte_length() - 1
    for b in v.as_bytes():
        var c = Int(b)
        if not (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord(".")
            or c == ord("-")
        ):
            ok = False
    if not ok:
        raise Error("not an instance type: ", v)
    return v


def _canonical(key: String, text: String) raises -> String:
    """`key`'s value `text`, checked, as registration keeps it."""
    if key == "placement":
        return parse_placement(text)
    if key == "head_type" or key == "worker_type":
        return _instance_type(text)
    if key == "workers":
        var w = parse_workers(text)
        if w[0] < 0:
            return String(w[1])
        return String(w[0], "..", w[1])
    if key == "worker_procs":
        var n = parse_worker_procs(text)
        return String("auto") if n == 0 else String(n)
    if key == "max_runs":
        return max_runs_text(parse_max_runs(text), max_runs_auto(text))
    if key == "keys_per_run":
        return String(parse_keys_per_run(text))
    if key == "cpus":
        return canonical_cpus(text)
    if key == "memory_gb":
        return canonical_memory_gb(text)
    if key == "learn":
        if text != "true" and text != "false":
            raise Error("is true or false, not ", text)
        return text
    if key == "fills":
        return parse_fills(text)
    if key == "fill_order":
        return parse_fill_order(text)
    if key == "fill_max_runs":
        return fill_max_runs_text(
            parse_fill_max_runs(text), fill_max_runs_auto(text)
        )
    if key == "fill_budget_per_day":
        return String(parse_fill_budget(text))
    if key == "fill_window":
        var w = parse_fill_window(text)
        return String(w[0], "..", w[1])
    if key == "fill_lag":
        return lag_text(parse_fill_lag(text))
    if key == "priority":
        return String(parse_priority(text))
    raise Error("unknown key ", key)


def canonical_flag(key: String, text: String) raises -> String:
    """A flag's value for `key`, checked, as registration keeps it."""
    return _canonical(key, text)


def _canonical_toml(key: String, v: TomlValue) raises -> String:
    """`key`'s value in the file, checked: the types each takes."""
    if key == "cpus":
        if v.kind != INTEGER and v.kind != STRING:
            raise Error('is a count or a string "MIN..MAX", not ', v.kind)
        return _canonical(key, v.text)
    if key == "memory_gb":
        if v.kind != INTEGER and v.kind != FLOAT and v.kind != STRING:
            raise Error('is GB, a number or a string "MIN..MAX", not ', v.kind)
        return _canonical(key, v.text)
    if key == "learn":
        if v.kind != BOOLEAN:
            raise Error("is true or false, not ", v.kind)
        return _canonical(key, v.text)
    if key == "fill_max_runs" and v.kind == STRING:
        if not fill_max_runs_auto(v.text):
            raise Error('is a count, "auto" or "auto..N", not ', v.text)
        return _canonical(key, v.text)
    if key == "fill_max_runs" or key == "keys_per_run":
        if v.kind != INTEGER:
            raise Error("is a count, not ", v.kind)
        return _canonical(key, v.text)
    if key == "priority":
        if v.kind != INTEGER:
            raise Error("is an integer, not ", v.kind)
        return _canonical(key, v.text)
    if key == "fill_budget_per_day":
        if v.kind != INTEGER and v.kind != FLOAT:
            raise Error("is US dollars a day, a number, not ", v.kind)
        return _canonical(key, v.text)
    if key == "fills" or key == "fill_order" or key == "fill_window":
        if v.kind != STRING:
            raise Error("is a string, not ", v.kind)
        return _canonical(key, v.text)
    if key == "fill_lag":
        # `0` may be a number; any other lag needs its unit.
        if v.kind != STRING and not (v.kind == INTEGER and v.text == "0"):
            raise Error('is a duration string like "2h", or 0, not ', v.kind)
        return _canonical(key, v.text)
    var numeric = key == "workers" or key == "worker_procs" or key == "max_runs"
    if v.kind == INTEGER and numeric:
        return _canonical(key, v.text)
    if key == "max_runs" and v.kind == STRING:
        if not max_runs_auto(v.text):
            raise Error('is a count, "auto" or "auto..N", not ', v.text)
        return _canonical(key, v.text)
    if v.kind == STRING:
        return _canonical(key, v.text)
    if numeric and key != "max_runs":
        raise Error("is a count or a string, not ", v.kind)
    if key == "max_runs":
        raise Error('is a count, "auto" or "auto..N", not ', v.kind)
    raise Error("is a string, not ", v.kind)


struct Setting(Copyable, Movable):
    """A value and where it came from: `CODE_DEFAULT`, `FROM_FILE`,
    `FROM_FLAG` or `FROM_ENV`, with a detail such as `[defaults]`, and for
    the file's, the line it's on."""

    var value: String
    var source: String
    var detail: String
    var line: Int
    """The file's line that sets it, from 1; 0 if not from the file, or
    registered before morca kept it."""

    def __init__(
        out self, value: String, source: String, detail: String, line: Int = 0
    ):
        self.value = value
        self.source = source
        self.detail = detail
        self.line = line


def is_scalar_key(key: String) -> Bool:
    for k in materialize[SCALAR_KEYS]():
        if key == k:
            return True
    return False


def is_map_key(key: String) -> Bool:
    return key == "secrets" or key == "env"


struct ProjectConfig(Movable):
    """A project's `morca.toml`, read and checked, or none (`path` empty)."""

    var path: String
    """The file as given, for messages; empty for no file."""
    var hash: String
    """The SHA-256 of its bytes, hex."""
    var commit: String
    """The git commit of the checkout it's in, or empty."""
    var dirty: Bool
    """Whether it differs from that commit."""
    var source: String
    """Where the commit is from (`MORCA_SOURCE`), for a file read outside a git
    checkout, as in the image; empty otherwise."""
    var repo_path: String
    """Its path in its checkout (`git ls-files --full-name`), for a link to
    its lines at the commit; empty outside a checkout."""
    var overlay: String
    """The stack's overlay laid on it (`apply_overlay`), or empty."""
    var overlay_hash: String
    var _overlaid: Dict[String, Int]
    """The paths the overlay set (`path_key`), to their lines in it."""
    var doc: TomlDoc

    def __init__(out self):
        """No file."""
        self.path = String()
        self.hash = String()
        self.commit = String()
        self.dirty = False
        self.source = String()
        self.repo_path = String()
        self.overlay = String()
        self.overlay_hash = String()
        self._overlaid = Dict[String, Int]()
        self.doc = TomlDoc()

    def __init__(
        out self,
        text: String,
        path: String,
        commit: String = "",
        dirty: Bool = False,
    ) raises:
        """`text`, the file `path` holds, checked: every key is one this
        morca knows, every value of its type."""
        self.path = path
        self.repo_path = String()
        self.hash = sha256_hex(text)
        self.commit = commit
        self.dirty = dirty
        self.source = String()
        self.overlay = String()
        self.overlay_hash = String()
        self._overlaid = Dict[String, Int]()
        try:
            self.doc = parse_toml(text)
        except e:
            raise Error(path, ":", e)
        self._check()

    @staticmethod
    def load(path: String, overlay: String = "") raises -> ProjectConfig:
        """The file at `path`, with its checkout's commit, and `overlay`
        laid on it if given."""
        if not exists(path):
            raise Error("morca: no ", path)
        var text: String
        with open(path, "r") as f:
            text = f.read()
        var full = absolute(path)
        var slash = full.rfind("/").or_else(-1)
        var dir = String(full[byte=:slash]) if slash > 0 else String("/")
        var commit = String()
        var dirty = False
        var repo_path = String()
        # sh keeps git's "fatal: not a git repository" off stderr.
        var base = String("git -C '", dir, "' ")
        try:
            var got = capture(
                ["sh", "-c", String(base, "rev-parse HEAD 2> /dev/null")], 10
            )
            if got[0] == 0:
                commit = String(got[1].strip())
                var st = capture(
                    [
                        "sh",
                        "-c",
                        String(
                            base,
                            "status --porcelain -- '",
                            String(full[byte = slash + 1 :]),
                            "' 2> /dev/null",
                        ),
                    ],
                    10,
                )
                dirty = st[0] != 0 or String(st[1].strip()) != ""
                var at = capture(
                    [
                        "sh",
                        "-c",
                        String(
                            base,
                            "ls-files --full-name -- '",
                            String(full[byte = slash + 1 :]),
                            "' 2> /dev/null",
                        ),
                    ],
                    10,
                )
                if at[0] == 0:
                    repo_path = String(at[1].strip())
        except:
            pass
        var source = String()
        if not commit and getenv("MORCA_COMMIT"):
            # Not in a checkout (the image): what the build recorded.
            commit = getenv("MORCA_COMMIT")
            source = getenv("MORCA_SOURCE")
        var cfg = ProjectConfig(text, path, commit, dirty)
        cfg.source = source
        cfg.repo_path = repo_path
        if overlay:
            cfg.apply_overlay(overlay)
        return cfg^

    def apply_overlay(mut self, path: String) raises:
        """The stack's overlay at `path` laid on the file (`TomlDoc.merge`),
        and the result checked again. A pipeline the overlay names must be
        in the file: a misspelt name would otherwise add one."""
        if not exists(path):
            raise Error("morca: no ", path, " (the overlay)")
        var text: String
        with open(path, "r") as f:
            text = f.read()
        var over: TomlDoc
        try:
            over = parse_toml(text)
        except e:
            raise Error(path, ":", e)
        for top in ["pipelines", "apps"]:
            for name in over.tables([String(top)]):
                if not self.doc.has_table([String(top), name]):
                    raise Error(
                        path,
                        ":",
                        over.get([String(top), name]).value().line,
                        ": [",
                        top,
                        ".",
                        toml_key(name),
                        "] isn't ",
                        "a pipeline" if top == "pipelines" else "an app",
                        " of ",
                        self.path,
                        ": an overlay changes the file's, it can't add one",
                    )
        for p in self.doc.merge(over):
            self._overlaid[path_key(p)] = over.get(p).value().line
        self.overlay = path
        self.overlay_hash = sha256_hex(text)
        self._check()

    def _loc(self, path: List[String]) -> String:
        """`file:line` of the value at `path`: the overlay's if it set it."""
        var o = self._overlaid.get(path_key(path))
        if o:
            return String(self.overlay, ":", o.value())
        return String(self.path, ":", self._line(path))

    def setting(
        self, value: String, path: List[String], label: String
    ) -> Setting:
        """`value`, from the file's `path` in the table `label`, with its
        line; one the overlay set names it and its line in the detail."""
        var o = self._overlaid.get(path_key(path))
        if o:
            return Setting(
                value,
                FROM_FILE,
                String(label, ", overlay ", self.overlay, ":", o.value()),
            )
        return Setting(value, FROM_FILE, label, self._line(path))

    def shown(self) -> String:
        """The file as register reads it (`morca config show --file`), each
        value the overlay set marked with its line there."""
        var notes = Dict[String, String]()
        for e in self._overlaid.items():
            notes[e.key] = String("overlay ", self.overlay, ":", e.value)
        var head = String("# ", self.path)
        if self.overlay:
            head.write(", with the overlay ", self.overlay, " laid on it")
        return String(head, "\n\n", self.doc.pretty(notes))

    def apps(self) raises -> List[AppConfig]:
        """Its `[apps.<name>]` tables (`morca config apps`)."""
        return read_apps(self.doc)

    def enabled(self, pipeline: String) -> Bool:
        """Whether `morca register` with no binaries registers `pipeline`:
        its `enabled`, else `[defaults]`'s, else true."""
        var v = self.doc.get(["pipelines", pipeline, "enabled"])
        if not v:
            v = self.doc.get(["defaults", "enabled"])
        return not v or v.value().text == "true"

    @staticmethod
    def from_b64(
        b64: String, path: String, commit: String, dirty: Bool
    ) raises -> ProjectConfig:
        """The file as `morca aws register` sends it: base64."""
        var bytes = b64decode(b64)
        return ProjectConfig(
            String(from_utf8_lossy=Span(bytes)), path, commit, dirty
        )

    def is_file(self) -> Bool:
        return self.path != ""

    def has(self, pipeline: String) -> Bool:
        """Whether the file has `[pipelines.<pipeline>]`."""
        return self.doc.has_table(["pipelines", pipeline])

    def pipelines(self) -> List[String]:
        return self.doc.tables(["pipelines"])

    def where(self, pipeline: String, key: String, s: Setting) -> String:
        """`file:line: [table]` of `key`'s value `s` from this file, for
        a refusal that needs the pipeline (`fills` on a keyed one)."""
        var p: List[String] = ["defaults", key]
        if s.detail != "[defaults]":
            p = ["pipelines", pipeline, key]
        return String(self._loc(p), ": ", s.detail)

    def entries(self, key: String) -> List[Tuple[String, String]]:
        """Each value of `key` in `[defaults]` and the `[pipelines.<name>]`
        tables, with `file:line: [table] key` for a message; for `secrets`
        or `env`, each of its names (`... secrets: NAME`)."""
        var out = List[Tuple[String, String]]()
        var tables = List[List[String]]()
        var labels = List[String]()
        if self.doc.has_table(["defaults"]):
            tables.append(["defaults"])
            labels.append("[defaults]")
        for name in self.pipelines():
            tables.append(["pipelines", name])
            labels.append(String("[pipelines.", toml_key(name), "]"))
        for t in range(len(tables)):
            var p = tables[t].copy()
            p.append(key)
            var v = self.doc.get(p)
            if not v:
                continue
            if is_map_key(key):
                for name in self.doc.keys(p):
                    var q = p.copy()
                    q.append(name)
                    var item = self.doc.get(q).value().copy()
                    out.append(
                        (
                            String(
                                self._loc(q),
                                ": ",
                                labels[t],
                                " ",
                                key,
                                ": ",
                                name,
                            ),
                            item.text,
                        )
                    )
            else:
                out.append(
                    (
                        String(
                            self._loc(p),
                            ": ",
                            labels[t],
                            " ",
                            key,
                        ),
                        v.value().text,
                    )
                )
        return out^

    def _fail(self, path: List[String], table: String, msg: String) raises:
        raise Error(self._loc(path), ": ", table, " ", msg)

    def _line(self, path: List[String]) -> Int:
        var v = self.doc.get(path)
        return v.value().line if v else 0

    def _check(self) raises:
        for top in self.doc.keys([]):
            var p: List[String] = [top]
            if not self.doc.has_table(p):
                self._fail(
                    p,
                    top,
                    (
                        "is a key at the top; the file has [defaults],"
                        " [pipelines.<name>], [pools.<name>], [apps.<name>],"
                        " [datasets.<name>] and [stack]"
                    ),
                )
            if top == "defaults":
                self._check_table(p, "[defaults]")
            elif top == "pipelines":
                for name in self.doc.keys(p):
                    var q: List[String] = ["pipelines", name]
                    if not self.doc.has_table(q):
                        self._fail(
                            q,
                            String("pipelines.", toml_key(name)),
                            (
                                "isn't a table: a pipeline's settings are"
                                " [pipelines.<name>]"
                            ),
                        )
                    self._check_table(
                        q, String("[pipelines.", toml_key(name), "]")
                    )
            elif top == "pools":
                # Worker pools morca grows itself (morca.pool_config).
                try:
                    _ = read_pools(self.doc)
                except e:
                    if self.overlay:
                        raise Error(self.path, " with ", self.overlay, ":", e)
                    raise Error(self.path, ":", e)
            elif top == "apps":
                # Apps beside the UI (morca.apps_config).
                var why = apps_problem(self.doc)
                if why:
                    var w = why.value().copy()
                    self._fail(w.path, w.table, w.msg)
            elif top == "datasets":
                # Datasets' settings (morca.dataset_config).
                var why = datasets_problem(self.doc)
                if why:
                    var w = why.value().copy()
                    self._fail(w.path, w.table, w.msg)
            elif top != "stack":
                # [stack] is for `morca aws up`, which doesn't read it yet.
                self._fail(
                    p,
                    String("[", toml_key(top), "]"),
                    (
                        "isn't a table morca knows: [defaults],"
                        " [pipelines.<name>], [pools.<name>], [apps.<name>],"
                        " [datasets.<name>] or [stack]"
                    ),
                )

    def _check_table(self, path: List[String], table: String) raises:
        for key in self.doc.keys(path):
            var p = path.copy()
            p.append(key)
            var v = self.doc.get(p).value().copy()
            if key == "enabled":
                if v.kind != BOOLEAN:
                    self._fail(p, table, "enabled is true or false")
            elif key == "concurrency":
                try:
                    _ = self.concurrency(p)
                except e:
                    self._fail(p, table, String("concurrency ", e))
            elif is_scalar_key(key):
                if v.kind == TABLE:
                    self._fail(p, table, String(key, " is a table"))
                try:
                    _ = _canonical_toml(key, v)
                except e:
                    self._fail(p, table, String(key, ": ", e))
            elif is_map_key(key):
                if v.kind != TABLE:
                    self._fail(
                        p,
                        table,
                        String(key, ' is a table, { NAME = "..." }'),
                    )
                for name in self.doc.keys(p):
                    var q = p.copy()
                    q.append(name)
                    var item = self.doc.get(q).value().copy()
                    var why = self._item_problem(key, name, item)
                    if why:
                        self._fail(q, table, String(key, ": ", why))
            else:
                var known = String()
                for k in materialize[SCALAR_KEYS]():
                    known.write(k, ", ")
                known.write("concurrency, enabled, secrets and env")
                self._fail(
                    p,
                    table,
                    String(
                        "has no key ", toml_key(key), " (it has ", known, ")"
                    ),
                )

    def concurrency(self, path: List[String]) raises -> String:
        """The `concurrency = { key = "...", limit = N }` at `path`, checked,
        as `concurrency_text` (#397)."""
        var v = self.doc.get(path).value().copy()
        if v.kind != TABLE:
            raise Error('is a table, { key = "...", limit = N }, not ', v.kind)
        var key = String()
        var limit = String()
        for k in self.doc.keys(path):
            var q = path.copy()
            q.append(k)
            var item = self.doc.get(q).value().copy()
            if k == "key":
                if item.kind != STRING:
                    raise Error("key is a string, not ", item.kind)
                key = item.text
            elif k == "limit":
                if item.kind != INTEGER:
                    raise Error("limit is a count, not ", item.kind)
                limit = item.text
            else:
                raise Error("has key and limit, not ", toml_key(k))
        if not key or not limit:
            raise Error('needs both key and limit: { key = "...", limit = N }')
        var c = parse_concurrency(String(key, ":", limit))
        return concurrency_text(c[0], c[1])

    def _item_problem(
        self, key: String, name: String, item: TomlValue
    ) -> String:
        if key == "secrets":
            if item.kind != STRING:
                return String(name, " is a Secrets Manager ID, a string")
            var why = secret_problem(String(name, "=", item.text))
            return why.replace("--secret's ", "")
        if item.kind == TABLE or item.kind == "array":
            return String(name, " is a string, a number or a boolean")
        return env_name_problem(name)

    def _map(
        self, path: List[String], key: String
    ) -> List[Tuple[String, String]]:
        """The names and values of `key`'s table under `path`."""
        var out = List[Tuple[String, String]]()
        var p = path.copy()
        p.append(key)
        for name in self.doc.keys(p):
            var q = p.copy()
            q.append(name)
            out.append((name, self.doc.get(q).value().text))
        return out^


@fieldwise_init
struct RegisterFlags(Copyable, Movable):
    """What `morca register`'s command line gave."""

    var values: Dict[String, String]
    """A `SCALAR_KEYS` key to its flag's value, checked."""
    var secrets: List[String]
    """`--secret NAME=ID`s, which replace the pipeline's when given."""
    var image: String
    var spot: Bool

    def __init__(out self):
        self.values = Dict[String, String]()
        self.secrets = List[String]()
        self.image = String()
        self.spot = False


def _set(mut list: List[Tuple[String, Setting]], name: String, var s: Setting):
    """`name`'s entry in `list`, replaced or added."""
    for ref e in list:
        if e[0] == name:
            e[1] = s^
            return
    list.append((name, s^))


struct Resolved(Movable):
    """What one pipeline is registered with: its settings from the file and
    the flags, each with where it came from."""

    var name: String
    var in_file: Bool
    """Whether the file names it; if not, flags left out keep what was
    registered, as before morca.toml."""
    var values: Dict[String, Setting]
    var secrets: List[Tuple[String, Setting]]
    var env: List[Tuple[String, Setting]]
    var overrides: List[Tuple[String, String]]
    """The flags given over the file's values, key and value."""

    def __init__(out self, name: String, in_file: Bool):
        self.name = name
        self.in_file = in_file
        self.values = Dict[String, Setting]()
        self.secrets = List[Tuple[String, Setting]]()
        self.env = List[Tuple[String, Setting]]()
        self.overrides = List[Tuple[String, String]]()

    def text(self, key: String) -> String:
        """`key`'s value, or empty if neither the file nor a flag set it."""
        var s = self.values.get(key)
        return s.value().value if s else String()

    def secret_specs(self) -> List[String]:
        var out = List[String]()
        for s in self.secrets:
            out.append(String(s[0], "=", s[1].value))
        return out^

    def env_pairs(self) -> List[Tuple[String, String]]:
        var out = List[Tuple[String, String]]()
        for e in self.env:
            out.append((e[0], e[1].value))
        return out^

    def env_json(self) -> String:
        """`env` as the JSON object Postgres keeps; empty for none."""
        return env_json(self.env_pairs())

    def config_json(self, file: ProjectConfig) -> String:
        """`orca.pipelines.config`: where each value came from, and for a
        pipeline the file names, the file's hash, commit and the flags that
        overrode it."""
        var src = String("{")
        var first = True
        for e in self.values.items():
            src.write("" if first else ", ", _source_json(e.key, e.value))
            first = False
        for e in self.secrets:
            src.write(
                "" if first else ", ",
                _source_json(String("secrets.", e[0]), e[1]),
            )
            first = False
        for e in self.env:
            src.write(
                "" if first else ", ", _source_json(String("env.", e[0]), e[1])
            )
            first = False
        src.write("}")
        var out = String('{"sources": ', src)
        if self.in_file:
            out.write(
                ', "file": ',
                quote(file.path),
                ', "hash": ',
                quote(file.hash),
                ', "commit": ',
                quote(file.commit),
                ', "dirty": ',
                "true" if file.dirty else "false",
            )
            if file.source:
                out.write(', "source": ', quote(file.source))
            if file.repo_path:
                out.write(', "repo_path": ', quote(file.repo_path))
            if file.overlay:
                out.write(
                    ', "overlay": ',
                    quote(file.overlay),
                    ', "overlay_hash": ',
                    quote(file.overlay_hash),
                )
            out.write(', "overrides": {')
            for i in range(len(self.overrides)):
                out.write(
                    "" if i == 0 else ", ",
                    quote(self.overrides[i][0]),
                    ": ",
                    quote(self.overrides[i][1]),
                )
            out.write("}")
        out.write("}")
        return out^


def _source_json(key: String, s: Setting) -> String:
    var out = String(
        quote(key),
        ': {"source": ',
        quote(s.source),
        ', "detail": ',
        quote(s.detail),
    )
    if s.line > 0:
        out.write(', "line": ', s.line)
    out.write("}")
    return out^


def env_json(env: List[Tuple[String, String]]) -> String:
    """Names and values as a JSON object; empty for none."""
    if len(env) == 0:
        return ""
    var out = String("{")
    for i in range(len(env)):
        out.write(
            "" if i == 0 else ", ", quote(env[i][0]), ": ", quote(env[i][1])
        )
    out.write("}")
    return out^


def parse_env(text: String) raises -> List[Tuple[String, String]]:
    """`env_json`'s object back as (NAME, value) pairs."""
    return parse_secrets(text)


def resolve(
    name: String, flags: RegisterFlags, file: ProjectConfig
) raises -> Resolved:
    """`name`'s registration from `file` and `flags`: `[defaults]`, then
    `[pipelines.<name>]`, then the flags."""
    var r = Resolved(name, file.has(name))
    if r.in_file:
        var tables: List[List[String]] = [
            ["defaults"],
            ["pipelines", name],
        ]
        var labels: List[String] = [
            String("[defaults]"),
            String("[pipelines.", toml_key(name), "]"),
        ]
        for t in range(2):
            if not file.doc.has_table(tables[t]):
                continue
            for key in materialize[SCALAR_KEYS]():
                var p = tables[t].copy()
                p.append(String(key))
                var v = file.doc.get(p)
                if v:
                    r.values[String(key)] = file.setting(
                        _canonical_toml(String(key), v.value()), p, labels[t]
                    )
            var cp = tables[t].copy()
            cp.append("concurrency")
            if file.doc.get(cp):
                r.values["concurrency"] = file.setting(
                    file.concurrency(cp), cp, labels[t]
                )
            for m in ["secrets", "env"]:
                for kv in file._map(tables[t], m):
                    var p = tables[t].copy()
                    p.append(String(m))
                    p.append(kv[0])
                    var st = file.setting(kv[1], p, labels[t])
                    if m == "secrets":
                        _set(r.secrets, kv[0], st^)
                    else:
                        _set(r.env, kv[0], st^)
    for e in flags.values.items():
        if r.in_file:
            r.overrides.append((e.key, e.value))
        r.values[e.key] = Setting(e.value, FROM_FLAG, flag_of(e.key))
    if len(flags.secrets) > 0:
        if r.in_file:
            var joined = String()
            for s in flags.secrets:
                joined.write("," if joined else "", s)
            r.overrides.append(("secrets", joined))
        r.secrets = List[Tuple[String, Setting]]()
        for s in flags.secrets:
            var eq = s.find("=").or_else(-1)
            _set(
                r.secrets,
                String(s[byte=:eq]),
                Setting(String(s[byte = eq + 1 :]), FROM_FLAG, "--secret"),
            )
    return r^


# `morca config show` and `morca config export`: from the registrations.
