"""Where a pipeline's code is: each step's line at the commit a run, or
the registration, was built from (`CodeLinks`), for the link beside every
step a page shows.
"""

from json import loads
import morca._internal.db.code_view as code_db

from morca._internal.locate import function_key
from morca._internal.source import is_hex, web_url
from morca._internal.state import State
from morca._internal.views.runs import RunRow, version_rows
from morca._internal.db.run_view import VersionRow


def _code_url(v: VersionRow, location: String) -> String:
    """`file#Lline` at the version's commit, or "" if it can't be linked."""
    var web = web_url(v.source)
    if not web or not v.commit or not location or not is_hex(v.commit):
        return ""
    if location.startswith("/") or ".." in location:
        return ""
    return String(web, "/blob/", v.commit, "/", location)


@fieldwise_init
struct CodeRef(Copyable, Defaultable, Movable):
    """A line of a version's code on its host: its URL, where it is
    (`file.mojo:26`), and the commit."""

    var url: String
    var at: String
    var commit: String

    def __init__(out self):
        self.url = ""
        self.at = ""
        self.commit = ""

    def __bool__(self) -> Bool:
        return self.url.byte_length() > 0


def _code_ref(v: VersionRow, location: String) -> CodeRef:
    """`file#Lline` at the version's commit, or an empty one."""
    var url = _code_url(v, location)
    if not url:
        return CodeRef()
    return CodeRef(url, location.replace("#L", ":"), v.commit)


struct CodeLinks(Copyable, Movable):
    """A version's code on its host: the pipeline's declaration, each
    step's function and each dista task, from `morca._internal.locate`'s map."""

    var pipeline: CodeRef
    var steps: Dict[String, CodeRef]
    """Step name to its function's line."""
    var tasks: List[Tuple[String, CodeRef]]
    """A task's function name and its line."""

    def __init__(out self):
        self.pipeline = CodeRef()
        self.steps = Dict[String, CodeRef]()
        self.tasks = List[Tuple[String, CodeRef]]()

    def step(self, name: String) -> CodeRef:
        return self.steps.get(name, CodeRef())


def code_links(
    mut db: State, pipeline: String, v: Optional[VersionRow]
) -> CodeLinks:
    var out = CodeLinks()
    if not v or not v.value().locations:
        return out^
    ref ver = v.value()
    try:
        var fn_step = Dict[String, String]()
        var d = loads(code_db.describe(db.conn, pipeline))
        for st in d["steps"].array_items():
            fn_step[function_key(st["function"].string_value())] = st[
                "name"
            ].string_value()
        for kv in loads(ver.locations).object_items():
            var at = _code_ref(ver, kv[1].string_value())
            if not at:
                continue
            var key = kv[0]
            if key == "pipeline":
                out.pipeline = at^
            elif key in fn_step:
                out.steps[fn_step[key]] = at^
            else:
                out.tasks.append(
                    (String(key[byte = key.rfind("::") + 2 :]), at^)
                )
    except:
        pass
    return out^


def code_of(
    mut db: State,
    mut cache: Dict[String, CodeLinks],
    pipeline: String,
    run: Int = 0,
) -> CodeLinks:
    """The code of the version `run` ran or, if it recorded none or there's
    no run, of the version `pipeline` is registered with; each version's
    worked out once per `cache`."""
    try:
        var found = code_db.run_code_version(
            db.conn, run
        ) if run else code_db.pipeline_code_version(db.conn, pipeline)
        if not found or not found.value()[1]:
            return CodeLinks()
        var name = found.value()[0]
        var id = found.value()[1]
        var key = String(name, "\0", id)
        if key not in cache:
            var vs = version_rows(db, id=id)
            cache[key] = code_links(
                db,
                name,
                vs[0].copy() if len(vs) > 0 else Optional[VersionRow](None),
            )
        return cache[key].copy()
    except:
        return CodeLinks()


@fieldwise_init
struct RunCode(Copyable, Movable):
    """What a runs table shows of a run's code, at the commit the run ran:
    its pipeline's declaration, and its failed step and that step's
    function."""

    var pipeline: CodeRef
    var failed: String
    """The first step that failed, or empty."""
    var step: CodeRef
    """`failed`'s function, or an empty one."""


def runs_code(mut db: State, runs: List[RunRow]) -> Dict[Int, RunCode]:
    """Each run's `RunCode`, by id: one query for the runs' versions and
    failed steps, then each version's code (`code_links`) once."""
    var out = Dict[Int, RunCode]()
    if len(runs) == 0:
        return out^
    var ids = String()
    for r in runs:
        ids.write("," if ids else "", r.id)
    try:
        var rows = code_db.run_versions(db.conn, ids)
        var cache = Dict[String, CodeLinks]()
        for row in rows:
            var v = row.version
            if not v:
                continue
            var name = row.pipeline
            var key = String(name, "\0", v)
            if key not in cache:
                var vs = version_rows(db, id=v)
                cache[key] = code_links(
                    db,
                    name,
                    vs[0].copy() if len(vs) > 0 else Optional[VersionRow](None),
                )
            ref links = cache[key]
            var failed = row.failed
            out[row.id] = RunCode(
                links.pipeline.copy(), failed, links.step(failed)
            )
    except:
        pass
    return out^


def pipeline_srcs(mut db: State, names: List[String]) -> Dict[String, String]:
    """Each pipeline's declaration at the version it's registered with, as
    the URL of its line (`CodeLinks.pipeline`), for those that have one."""
    var out = Dict[String, String]()
    var cache = Dict[String, CodeLinks]()
    for name in names:
        var at = code_of(db, cache, name).pipeline.copy()
        if at:
            out[name] = at.url
    return out^
