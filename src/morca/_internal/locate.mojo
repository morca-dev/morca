"""Where a pipeline's step functions and dista tasks are defined in its
source, so `morca ui` can link each one to its line at the commit a run ran.

    morca locate ./build/taxi --root .     # writes ./build/taxi.source.json

`describe` names each function by its module path, `taxi::trips(...)` or
`lake::steps::parse(...)`; the module is a file, `taxi.mojo` or
`lake/steps.mojo`, under one of the source tree's directories. `locate`
finds the file whose path ends with it and the line of its top-level `def`
(or `fn`), and the line declaring the pipeline itself (`Pipeline[` with its
name first), kept as `"pipeline"`. The map, `{"pipeline":
"examples/taxi/taxi.mojo#L243", "taxi::trips": "examples/taxi/taxi.mojo#L42",
...}`, is written beside the binary, and `morca register` records it with the
pipeline's version. Paths are relative to `--root`, which is the
repository's root for the links to work.
"""

from std.os import listdir
from std.os.path import isdir

from json import loads

from morca._internal.json import quote


def function_key(name: String) -> String:
    """`module::fn`, without the arguments describe writes after it."""
    var paren = name.find("(").or_else(-1)
    return String(name[byte=:paren]) if paren >= 0 else name


def _module_file(key: String) -> String:
    """`a::b::fn` -> `a/b.mojo`; "" for a name without a module."""
    var at = key.rfind("::").or_else(-1)
    if at < 0:
        return ""
    return String(key[byte=:at].replace("::", "/"), ".mojo")


def _def_line(text: String, fn_name: String) -> Int:
    """The 1-based line of the top-level `def fn_name(` or
    `def fn_name[`, or 0."""
    var line = 1
    var at = 0
    var n = text.byte_length()
    while at < n:
        var end = text.find("\n", at).or_else(-1)
        if end < 0:
            end = n
        var l = String(text[byte=at:end])
        for kw in ["def ", "fn "]:
            if l.startswith(kw):
                var rest = String(l[byte = String(kw).byte_length() :])
                if rest.startswith(fn_name) and rest.byte_length() > (
                    fn_name.byte_length()
                ):
                    var c = rest[byte=fn_name.byte_length()]
                    if c == "(" or c == "[":
                        return line
        line += 1
        at = end + 1
    return 0


def _pipeline_line(text: String, name: String) -> Int:
    """The 1-based line of `Pipeline[` whose first parameter is `"name"`,
    or 0."""
    var want = String('"', name, '"')
    var at = 0
    while True:
        var p = text.find("Pipeline[", at).or_else(-1)
        if p < 0:
            return 0
        var q = p + 9
        var n = text.byte_length()
        while q < n and (
            text[byte=q] == " " or text[byte=q] == "\n" or text[byte=q] == "\t"
        ):
            q += 1
        if String(text[byte = q : min(n, q + want.byte_length())]) == want:
            return String(text[byte=:p]).count("\n") + 1
        at = p + 1


def mojo_files(root: String) raises -> List[String]:
    """The `.mojo` files under `root`, as paths relative to it, skipping
    hidden directories and `build`."""
    var out = List[String]()
    var dirs: List[String] = [String("")]
    while len(dirs) > 0:
        var rel = dirs.pop()
        var full = String(root, "/", rel) if rel else root
        for e in listdir(full):
            var name = String(e)
            if name.startswith(".") or name == "build":
                continue
            var path = String(rel, "/", name) if rel else name
            if isdir(String(root, "/", path)):
                dirs.append(path)
            elif name.endswith(".mojo"):
                out.append(path)
    return out^


def locate(describe: String, root: String) raises -> String:
    """The map of `describe`'s step functions and tasks to `file#Lline`
    under `root`, as JSON; a function it can't find is left out."""
    var d = loads(describe)
    var names = List[String]()
    for s in d["steps"].array_items():
        names.append(function_key(s["function"].string_value()))
    for t in d["tasks"].array_items():
        names.append(function_key(t.string_value()))
    var files = mojo_files(root)
    var out = String("{")
    var first = True
    # The pipeline, looked for first in its steps' files.
    var pipeline = d["pipeline"].string_value()
    var ordered = List[String]()
    for key in names:
        var want = _module_file(key)
        for f in files:
            if (
                f == want or f.endswith(String("/", want))
            ) and f not in ordered:
                ordered.append(f)
    for f in files:
        if f not in ordered:
            ordered.append(f)
    for f in ordered:
        var text: String
        with open(String(root, "/", f), "r") as h:
            text = h.read()
        var line = _pipeline_line(text, pipeline)
        if line > 0:
            out.write('"pipeline": ', quote(String(f, "#L", line)))
            first = False
            break
    var done = List[String]()
    for key in names:
        if key in done:
            continue
        done.append(key)
        var want = _module_file(key)
        if not want:
            continue
        var fn_name = String(key[byte = key.rfind("::").or_else(-1) + 2 :])
        for f in files:
            if f != want and not f.endswith(String("/", want)):
                continue
            var text: String
            with open(String(root, "/", f), "r") as h:
                text = h.read()
            var line = _def_line(text, fn_name)
            if line > 0:
                out.write(
                    "" if first else ", ",
                    quote(key),
                    ": ",
                    quote(String(f, "#L", line)),
                )
                first = False
                break
    out.write("}")
    return out^
