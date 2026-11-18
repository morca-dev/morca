"""`morca config show` and `morca config export` (`morca._internal.config`): each
pipeline's settings with where each came from, as text, HTML and JSON, and
the registered settings written back as a morca.toml.
"""

from std.os import getenv
from json import (
    Value,
    loads,
)
import morca._internal.db.config_show as config_db
from morca._internal.concurrency import concurrency_toml
from morca._internal.db.config_show import Settings
from morca._internal.fill import fill_max_runs_text
from morca._internal.fill import SINCE_REGISTRATION
from morca._internal.html import Html
from morca._internal.json import quote
from morca._internal.recommend import (
    Recommendation,
    learned,
)
from morca._internal.resources import Request
from morca._internal.secrets import parse_secrets
from morca._internal.source import (
    is_hex,
    web_url,
)
from morca._internal.state import State
from morca._internal.ui.terms import key_help
from morca._internal.toml import (
    toml_key,
    toml_string,
)
from morca._internal.config import (
    CODE_DEFAULT,
    FROM_ENV,
    FROM_FILE,
    FROM_FLAG,
    Setting,
    flag_of,
    max_runs_text,
    parse_env,
)


@fieldwise_init
struct _Row(Copyable, Movable):
    var key: String
    var setting: Setting


struct Shown(Movable):
    """One registered pipeline's effective configuration."""

    var name: String
    var file: String
    var hash: String
    var commit: String
    var dirty: Bool
    var source: String
    var repo_path: String
    """The file's path in its checkout, for links to its lines."""
    var overlay: String
    """The stack's overlay laid on the file, if one was."""
    var overrides: List[Tuple[String, String]]
    var rows: List[_Row]
    var learned: Optional[Recommendation]
    """The request its runs' peaks suggest (`morca._internal.recommend`), applied when
    it asks for `auto` and learns."""
    var auto: Bool
    """Whether its `cpus` or `memory_gb` is `auto`."""
    var learn: Bool
    """Whether it learns (`learn`, true unless set false)."""

    def __init__(out self, name: String):
        self.name = name
        self.file = String()
        self.hash = String()
        self.commit = String()
        self.dirty = False
        self.source = String()
        self.repo_path = String()
        self.overlay = String()
        self.overrides = List[Tuple[String, String]]()
        self.rows = List[_Row]()
        self.learned = None
        self.auto = False
        self.learn = True

    def add(
        mut self, key: String, value: String, source: String, detail: String
    ):
        self.rows.append(_Row(key, Setting(value, source, detail)))

    def applied_text(self) -> String:
        """Whether its runs start with what it learned, and why not."""
        if self.learned and self.learned.value().applied:
            return "applied: its request is auto"
        if self.auto and not self.learn:
            return "not applied: learn = false"
        return "shown, not applied: its request isn't auto"

    def json(self) -> String:
        var out = String('{"pipeline": ', quote(self.name))
        if self.file:
            out.write(
                ', "file": ',
                quote(self.file),
                ', "hash": ',
                quote(self.hash),
                ', "commit": ',
                quote(self.commit),
                ', "dirty": ',
                "true" if self.dirty else "false",
            )
            if self.overlay:
                out.write(', "overlay": ', quote(self.overlay))
        else:
            out.write(', "file": null')
        out.write(', "overrides": {')
        for i in range(len(self.overrides)):
            out.write(
                "" if i == 0 else ", ",
                quote(self.overrides[i][0]),
                ": ",
                quote(self.overrides[i][1]),
            )
        out.write('}, "settings": [')
        for i in range(len(self.rows)):
            ref r = self.rows[i]
            out.write(
                "" if i == 0 else ", ",
                '{"key": ',
                quote(r.key),
                ', "value": ',
                quote(r.setting.value),
                ', "source": ',
                quote(r.setting.source),
                ', "detail": ',
                quote(r.setting.detail),
                "}",
            )
        out.write('], "learned": ')
        if self.learned:
            out.write(self.learned.value().json())
        else:
            out.write("null")
        out.write("}")
        return out^

    def text(self) -> String:
        var out = String(self.name)
        if self.file:
            out.write("  registered from ", self.file)
            if self.commit:
                out.write(
                    " @ ",
                    self.commit[byte = : min(12, self.commit.byte_length())],
                )
                if self.dirty:
                    out.write(" (with changes not committed)")
                if self.source:
                    out.write(" of ", self.source)
            out.write(
                ", sha256 ",
                self.hash[byte = : min(12, self.hash.byte_length())],
            )
            if self.overlay:
                out.write(", with the overlay ", self.overlay)
        else:
            out.write("  not registered from morca.toml")
        out.write("\n")
        if len(self.overrides) > 0:
            out.write("  overrides:")
            for o in self.overrides:
                out.write(
                    " ",
                    flag_of(o[0]) if o[0] != "secrets" else String("--secret"),
                    " ",
                    o[1],
                )
            out.write("\n")
        var width = 0
        var vwidth = 0
        for r in self.rows:
            width = max(width, r.key.byte_length())
            vwidth = max(vwidth, r.setting.value.byte_length())
        vwidth = min(vwidth, 40)
        for r in self.rows:
            out.write("  ", r.key)
            for _ in range(width - r.key.byte_length() + 2):
                out.write(" ")
            out.write(r.setting.value)
            for _ in range(max(vwidth - r.setting.value.byte_length(), 0) + 2):
                out.write(" ")
            out.write(r.setting.source)
            if r.setting.detail:
                out.write(" ", r.setting.detail)
            out.write("\n")
        if self.learned and self.learned.value().runs > 0:
            ref l = self.learned.value()
            out.write("  ", l.text())
            if l.any():
                out.write(" (", l.source, "); ", self.applied_text())
            out.write("\n")
        return out^


comptime _VALUE_TERMS = ["placement", "fills", "fill_order", "spot"]
"""The keys whose values are one of a fixed set (`morca._internal.ui.terms`)."""


def config_html(
    mut h: Html, s: Shown, repo: String = "", code_line: String = ""
):
    """The pipeline page's Configuration (`id="config"`): what `morca config
    show` prints, where it was registered from, and the flags that
    overrode the file. Each key has its help, each value from a fixed set
    its meaning on hover, and From links to where the value is set where
    that's known: a morca.toml line at the registration's commit in `repo`
    (a repository's web address), or for a default from the pipeline's
    code, `code_line`, its declaration."""
    h.raw('<h2 id="config">Configuration</h2><p class="muted">')
    if s.file:
        h.raw("Registered from <code>")
        h.text(s.file)
        h.raw("</code>")
        if s.commit:
            h.raw(" @ <code>")
            h.text(s.commit[byte = : min(12, s.commit.byte_length())])
            h.raw("</code>")
            if s.dirty:
                h.raw(" (with changes not committed)")
            if s.source:
                h.text(" of ", s.source)
        h.raw(", sha256 <code>")
        h.text(s.hash[byte = : min(12, s.hash.byte_length())])
        h.raw("</code>.")
    else:
        h.raw(
            (
                "Not registered from morca.toml: from <code>morca"
                " register</code>'s"
            ),
            " flags, each left out keeping what was registered.",
        )
    h.raw("</p>")
    if len(s.overrides) > 0:
        h.raw(
            '<p class="warn">Registered with flags over the file, gone at',
            " the next registration without them:",
        )
        for o in s.overrides:
            h.raw(" <code>")
            h.text(
                flag_of(o[0]) if o[0] != "secrets" else String("--secret"),
                " ",
                o[1],
            )
            h.raw("</code>")
        h.raw("</p>")
    # The file at its commit, where a line of it can be linked.
    var file_url = String()
    var web = web_url(s.source) if s.source else repo
    if web and s.repo_path and s.commit and is_hex(s.commit) and not s.dirty:
        if not s.repo_path.startswith("/") and ".." not in s.repo_path:
            file_url = String(web, "/blob/", s.commit, "/", s.repo_path)
    h.raw(
        '<div class="scroll"><table><thead><tr><th data-help="config">Key</th>',
        '<th>Value</th><th data-help="config">From</th></tr></thead><tbody>',
    )
    for i in range(len(s.rows)):
        ref r = s.rows[i]
        h.raw("<tr><td><code>")
        h.text(r.key)
        h.raw("</code>")
        var help = key_help(r.key)
        if help:
            h.help(String("key-", i), r.key, help)
        h.raw("</td><td><code>")
        var termed = False
        for k in materialize[_VALUE_TERMS]():
            termed = termed or r.key == k
        if termed:
            h.term(r.key, r.setting.value)
        else:
            h.text(r.setting.value)
        h.raw("</code></td><td>")
        h.term("from", r.setting.source)
        if r.setting.detail:
            h.text(" ", r.setting.detail)
        if r.setting.source == FROM_FILE and file_url and r.setting.line > 0:
            h.raw(" ")
            h.code(
                String(file_url, "#L", r.setting.line),
                String(s.repo_path, ":", r.setting.line),
                s.commit,
            )
        elif (
            r.setting.source == CODE_DEFAULT
            and code_line
            and (r.setting.detail.startswith("the pipeline's"))
        ):
            h.raw(" ")
            h.code(code_line, "the Pipeline[...] line", "")
        h.raw("</td></tr>")
    h.raw("</tbody></table></div>")


def _source(
    sources: Optional[Value], key: String
) raises -> Tuple[String, String]:
    """Where the registration says `key` came from; a value registered
    before morca kept that could only have come from a flag."""
    if sources:
        var s = sources.value().get(key)
        if s:
            return (
                s.value()["source"].string_value(),
                s.value()["detail"].string_value(),
            )
    return (String(FROM_FLAG), String(""))


def _has_source(sources: Optional[Value], key: String) raises -> Bool:
    """Whether the registration says where `key` came from."""
    if sources:
        if sources.value().get(key):
            return True
    return False


def _line_of(sources: Optional[Value], key: String) raises -> Int:
    """The file's line the registration says `key` is set on, or 0."""
    if sources:
        var s = sources.value().get(key)
        if s:
            var l = s.value().get("line")
            if l:
                return Int(l.value().int_value())
    return 0


def _run_env_names() -> List[String]:
    var out = List[String]()
    for n in getenv("MORCA_RUN_ENV").split(","):
        if n.strip():
            out.append(String(n.strip()))
    return out^


def shown(mut db: State, only: String = "") raises -> List[Shown]:
    """The effective configuration of each registered pipeline (or the one
    named), with the source of every value. Values morca's runners take from
    their environment when nothing is registered (`MORCA_EC2_HEAD_TYPE`,
    `MORCA_EC2_WORKER_TYPE`, `MORCA_RUN_ENV`'s variables) are read from this
    process's, which is the scheduler's when run beside it."""
    var out = List[Shown]()
    for r in config_db.settings(db.conn, only):
        var s = Shown(r.name)
        var sources = Optional[Value](None)
        if r.config:
            var c = loads(r.config)
            var f = c.get("file")
            if f and f.value().is_string():
                s.file = f.value().string_value()
                s.hash = c["hash"].string_value()
                s.commit = c["commit"].string_value()
                s.dirty = c["dirty"].bool_value()
                var so = c.get("source")
                if so and so.value().is_string():
                    s.source = so.value().string_value()
                var ov = c.get("overlay")
                if ov and ov.value().is_string():
                    s.overlay = ov.value().string_value()
                var rp = c.get("repo_path")
                if rp and rp.value().is_string():
                    s.repo_path = rp.value().string_value()
                for kv in c["overrides"].object_items():
                    s.overrides.append((String(kv[0]), kv[1].string_value()))
            var src = c.get("sources")
            if src:
                sources = src.value().copy()
        # placement
        if not r.placement:
            s.add(
                "placement",
                "default",
                CODE_DEFAULT,
                String(
                    "the scheduler's runner, ", getenv("MORCA_RUNNER", "local")
                ),
            )
        else:
            var w = _source(sources, "placement")
            s.add("placement", r.placement.value(), w[0], w[1])
        for t in range(2):
            var key = String("head_type") if t == 0 else String("worker_type")
            var var_name = String("MORCA_EC2_HEAD_TYPE") if t == 0 else String(
                "MORCA_EC2_WORKER_TYPE"
            )
            var have = r.head_type.copy() if t == 0 else r.worker_type.copy()
            if have:
                var w = _source(sources, key)
                s.add(key, have.value(), w[0], w[1])
            elif getenv(var_name):
                s.add(key, getenv(var_name), FROM_ENV, var_name)
            else:
                s.add(
                    key,
                    "c7g.large" if t == 0 else "c7g.xlarge",
                    CODE_DEFAULT,
                    "the ec2 runner's",
                )
        if r.ec2_workers:
            var w = _source(sources, "workers")
            var v = String(r.ec2_workers.value())
            if r.ec2_min_workers:
                v = String(r.ec2_min_workers.value(), "..", v)
            var detail = w[1]
            if not r.tasks:
                detail.write(
                    "; " if detail else "", "unused: the pipeline has no tasks"
                )
            s.add("workers", v, w[0], detail)
        elif not r.tasks:
            s.add("workers", "0", CODE_DEFAULT, "the pipeline has no tasks")
        elif r.code_workers:
            s.add(
                "workers",
                r.code_workers.value(),
                CODE_DEFAULT,
                "the pipeline's code",
            )
        else:
            s.add("workers", "2", CODE_DEFAULT, "")
        if not r.worker_procs:
            s.add("worker_procs", "1", CODE_DEFAULT, "")
        else:
            var w = _source(sources, "worker_procs")
            var n = r.worker_procs.value()
            s.add(
                "worker_procs",
                String("auto") if n == 0 else String(n),
                w[0],
                w[1],
            )
        if not r.max_runs:
            s.add(
                "max_runs",
                r.code_max_runs,
                CODE_DEFAULT,
                "the pipeline's max_runs",
            )
        else:
            var w = _source(sources, "max_runs")
            s.add(
                "max_runs",
                max_runs_text(Int(r.max_runs.value()), r.max_runs_auto),
                w[0],
                w[1],
            )
        if not r.keys_per_run:
            s.add(
                "keys_per_run",
                r.code_keys_per_run,
                CODE_DEFAULT,
                "the pipeline's keys_per_run",
            )
        else:
            var w = _source(sources, "keys_per_run")
            s.add("keys_per_run", String(r.keys_per_run.value()), w[0], w[1])
        # The scheduler's order across pipelines (#421): always shown.
        if r.priority == 0 and not _has_source(sources, "priority"):
            s.add("priority", "0", CODE_DEFAULT, "")
        else:
            var w = _source(sources, "priority")
            s.add("priority", String(r.priority), w[0], w[1])
        # A concurrency key across pipelines (#397), only when it has one.
        if r.concurrency_key:
            var w = _source(sources, "concurrency")
            s.add(
                "concurrency",
                concurrency_toml(r.concurrency_key, Int(r.concurrency_limit)),
                w[0],
                w[1],
            )
        # A request (morca.resources), only when it has one.
        for key in ["cpus", "memory_gb"]:
            if r.cpus if key == "cpus" else r.memory_gb:
                var w = _source(sources, key)
                s.add(
                    key, (r.cpus if key == "cpus" else r.memory_gb), w[0], w[1]
                )
        var learn = not r.learn or r.learn.value()
        if not learn:
            var w = _source(sources, "learn")
            s.add("learn", "false", w[0], w[1])
        _show_fills(s, r, sources)
        if r.image:
            s.add("image", r.image, FROM_FLAG, "--image")
        if r.spot:
            s.add("spot", "true", FROM_FLAG, "--spot")
        for kv in parse_secrets(r.secrets):
            var key = String("secrets.", kv[0])
            var w = _source(sources, key)
            s.add(key, kv[1], w[0], w[1])
        var env = parse_env(r.env)
        for kv in env:
            var key = String("env.", kv[0])
            var w = _source(sources, key)
            s.add(key, kv[1], w[0], w[1])
        for n in _run_env_names():
            var mine = False
            for kv in env:
                if kv[0] == n:
                    mine = True
            if not mine and getenv(n):
                s.add(String("env.", n), getenv(n), FROM_ENV, "MORCA_RUN_ENV")
        for ref row in s.rows:
            if row.setting.source == FROM_FILE:
                row.setting.line = _line_of(sources, row.key)
        var l = learned(db, s.name, r.cpus, r.memory_gb)
        s.auto = Request.of(r.cpus, r.memory_gb).auto()
        s.learn = learn
        l.applied = s.auto and learn and l.any()
        s.learned = l^
        out.append(s^)
    return out^


def _show_fills(mut s: Shown, r: Settings, sources: Optional[Value]) raises:
    """The `fill*` keys (`morca._internal.fill`): `fills` always, the others when the
    pipeline fills or sets them."""
    var fills = r.fills
    if fills:
        var w = _source(sources, "fills")
        s.add("fills", fills, w[0], w[1])
    else:
        s.add("fills", SINCE_REGISTRATION, CODE_DEFAULT, "")
    var any = (
        fills == "all"
        or r.fill_order != ""
        or r.fill_max_runs > 0
        or r.fill_budget >= 0
        or r.fill_window != ""
        or r.fill_lag != ""
    )
    if not any:
        return
    if r.fill_order:
        var w = _source(sources, "fill_order")
        s.add("fill_order", r.fill_order, w[0], w[1])
    else:
        s.add("fill_order", "oldest", CODE_DEFAULT, "")
    if r.fill_max_runs > 0:
        var w = _source(sources, "fill_max_runs")
        s.add(
            "fill_max_runs",
            fill_max_runs_text(Int(r.fill_max_runs), r.fill_max_runs_auto),
            w[0],
            w[1],
        )
    else:
        s.add("fill_max_runs", "1", CODE_DEFAULT, "")
    if r.fill_budget >= 0:
        var w = _source(sources, "fill_budget_per_day")
        s.add("fill_budget_per_day", String(r.fill_budget), w[0], w[1])
    else:
        s.add(
            "fill_budget_per_day",
            "none",
            CODE_DEFAULT,
            "fill runs on ec2 or kubernetes don't start without one",
        )
    if r.fill_window:
        var w = _source(sources, "fill_window")
        s.add("fill_window", r.fill_window, w[0], w[1])
    else:
        s.add("fill_window", "0..24", CODE_DEFAULT, "all day")
    if r.fill_lag:
        var w = _source(sources, "fill_lag")
        s.add("fill_lag", r.fill_lag, w[0], w[1])
    else:
        s.add("fill_lag", "0", CODE_DEFAULT, "a partition fills once it ends")


def show_json(items: List[Shown], one: Bool) -> String:
    """`morca config show --json`: the pipeline's object, or for all of them
    `{"pipelines": [...]}`."""
    if one and len(items) == 1:
        return items[0].json()
    var out = String('{"pipelines": [')
    for i in range(len(items)):
        out.write("" if i == 0 else ", ", items[i].json())
    out.write("]}")
    return out^


def _inline(pairs: List[Tuple[String, String]]) -> String:
    var out = String("{ ")
    for i in range(len(pairs)):
        out.write(
            "" if i == 0 else ", ",
            toml_key(pairs[i][0]),
            " = ",
            toml_string(pairs[i][1]),
        )
    out.write(" }")
    return out^


def export_toml(mut db: State) raises -> String:
    """`morca config export`: an `morca.toml` with a `[pipelines.<name>]` for
    each registered pipeline holding what's registered for it beyond the
    defaults, which registering from it again gives back."""
    var out = String(
        (
            "# morca.toml, written by `morca config export` from the"
            " registrations\n"
        ),
        "# in morca's database. `morca register` reads it (morca.config).\n",
    )
    for r in config_db.settings(db.conn, ""):
        out.write("\n[pipelines.", toml_key(r.name), "]\n")
        if r.placement:
            out.write("placement = ", toml_string(r.placement.value()), "\n")
        if r.head_type:
            out.write("head_type = ", toml_string(r.head_type.value()), "\n")
        if r.worker_type:
            out.write(
                "worker_type = ", toml_string(r.worker_type.value()), "\n"
            )
        if r.ec2_workers:
            if not r.ec2_min_workers:
                out.write("workers = ", r.ec2_workers.value(), "\n")
            else:
                out.write(
                    'workers = "',
                    r.ec2_min_workers.value(),
                    "..",
                    r.ec2_workers.value(),
                    '"\n',
                )
        if r.worker_procs:
            var n = r.worker_procs.value()
            if n == 0:
                out.write('worker_procs = "auto"\n')
            else:
                out.write("worker_procs = ", n, "\n")
        if r.max_runs:
            if r.max_runs_auto:
                var t = max_runs_text(Int(r.max_runs.value()), True)
                out.write("max_runs = ", toml_string(t), "\n")
            else:
                out.write("max_runs = ", r.max_runs.value(), "\n")
        if r.keys_per_run:
            out.write("keys_per_run = ", r.keys_per_run.value(), "\n")
        if r.priority != 0:
            out.write("priority = ", r.priority, "\n")
        if r.concurrency_key:
            out.write(
                "concurrency = ",
                concurrency_toml(r.concurrency_key, Int(r.concurrency_limit)),
                "\n",
            )
        for key in ["cpus", "memory_gb"]:
            if r.cpus if key == "cpus" else r.memory_gb:
                out.write(
                    key,
                    " = ",
                    toml_string((r.cpus if key == "cpus" else r.memory_gb)),
                    "\n",
                )
        if r.learn and not r.learn.value():
            out.write("learn = false\n")
        if r.fills:
            out.write("fills = ", toml_string(r.fills), "\n")
        if r.fill_order:
            out.write("fill_order = ", toml_string(r.fill_order), "\n")
        if r.fill_max_runs > 0:
            if r.fill_max_runs_auto:
                var t = fill_max_runs_text(Int(r.fill_max_runs), True)
                out.write("fill_max_runs = ", toml_string(t), "\n")
            else:
                out.write("fill_max_runs = ", r.fill_max_runs, "\n")
        if r.fill_budget >= 0:
            out.write("fill_budget_per_day = ", String(r.fill_budget), "\n")
        if r.fill_window:
            out.write("fill_window = ", toml_string(r.fill_window), "\n")
        if r.fill_lag:
            out.write("fill_lag = ", toml_string(r.fill_lag), "\n")
        var env = parse_env(r.env)
        if len(env) > 0:
            out.write("env = ", _inline(env), "\n")
        var secrets = parse_secrets(r.secrets)
        if len(secrets) > 0:
            out.write("secrets = ", _inline(secrets), "\n")
    return out^
