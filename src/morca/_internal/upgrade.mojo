"""A release's upgrade steps (#323): what has to be done before or after a
deploy, which a project's image ships in `upgrade.toml` and the Hetzner
deploy shows or runs (`deploy/hetzner/deploy.sh`).

```toml
[[version]]
version = "1.2.0"

[[version.step]]
id = "1.2.0-retool"      # unique and stable
when = "after"           # before | after (the default)
run = "morca backfill --rerun mojo_retool @all"   # a morca command

[[version.step]]
id = "1.2.0-repos"       # a big re-run, throttled as fill runs (#465)
run = "morca backfill --rerun --as-fill mojo_repos 2023-01-01..2026-11-13"

[[version.step]]
id = "1.1.0-egress-hf"
when = "before"
manual = "The console downloads its model from huggingface.co: allow outbound HTTPS."
```

`morca upgrade --from <deployed> --to <new>` prints the steps of every
version after `--from` up to `--to`, a line each:

    step<TAB><id><TAB><before|after><TAB><run|manual><TAB><command or text>

What makes a step run once is that range: a deploy from 1.1.0 to 1.2.0 takes
1.2.0's steps, and the next deploy, from 1.2.0, doesn't. Nothing is recorded
in the database. A `--from` that isn't a version (a commit, empty) takes
only `--to`'s steps.

A command that several of those versions run (the same `run`, `when` too,
after trimming spaces) is printed once, at its last version's place, with
the ids of all of them, comma-separated (`merge_runs`, #343): a deploy from
1.1.0 to 1.3.0 whose 1.2.0 and 1.3.0 both re-read every repo re-reads once.
"""

from std.os import getenv
from std.os.path import exists

from morca._internal.toml import ARRAY, STRING, TomlDoc, parse_toml

comptime DEFAULT_FILE = "/opt/morca/upgrade.toml"


@fieldwise_init
struct UpgradeStep(Copyable, Movable):
    var version: String
    var id: String
    var when: String
    """`before` or `after`."""
    var kind: String
    """`run` or `manual`."""
    var text: String
    """The command (`morca ...`) or the instructions."""


def version_parts(v: String) -> List[Int]:
    """`1.2.0` (or `v1.2.0`, `1.2.0-rc1`) as `[1, 2, 0, pre]`, `pre` 0 for a
    prerelease and 1 for a release, so a prerelease sorts before its
    release; empty when `v` isn't a version (a commit, say)."""
    var full = String(v[byte=1:]) if v.startswith("v") else v
    var dash = full.find("-")
    var pre = 1 if dash < 0 else 0
    var s = String(full[byte=:dash]) if dash >= 0 else full
    var out = List[Int]()
    var parts = s.split(".")
    if len(parts) < 2 or len(parts) > 3:
        return List[Int]()
    for p in parts:
        var t = String(p)
        if t.byte_length() == 0:
            return List[Int]()
        for b in t.as_bytes():
            if b < UInt8(ord("0")) or b > UInt8(ord("9")):
                return List[Int]()
        try:
            out.append(Int(t))
        except:
            return List[Int]()
    while len(out) < 3:
        out.append(0)
    out.append(pre)
    return out^


def version_less(a: List[Int], b: List[Int]) -> Bool:
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            return a[i] < b[i]
    return len(a) < len(b)


def _string(doc: TomlDoc, path: List[String], what: String) raises -> String:
    var v = doc.get(path)
    if not v:
        return String()
    if v.value().kind != STRING:
        raise Error("upgrade: ", what, " must be a string")
    return v.value().text


def parse_upgrade(text: String) raises -> List[UpgradeStep]:
    """The steps of an `upgrade.toml`, in the file's order. Raises for a
    version that isn't one, a step without an id, with both or neither of
    `run` and `manual`, a `when` that isn't `before` or `after`, a `run`
    that isn't an `morca` command, or an id used twice."""
    var doc = parse_toml(text)
    var out = List[UpgradeStep]()
    var versions = doc.get(["version"])
    if not versions:
        return out^
    if versions.value().kind != ARRAY:
        raise Error(
            "upgrade: `version` must be an array of tables ([[version]])"
        )
    var ids = Dict[String, Bool]()
    for vi in versions.value().items:
        var vp: List[String] = ["version", vi]
        var vpath = vp.copy()
        vpath.append("version")
        var version = _string(doc, vpath, "a version's `version`")
        if len(version_parts(version)) == 0:
            raise Error("upgrade: '", version, "' isn't a version (X.Y.Z)")
        var sp = vp.copy()
        sp.append("step")
        var steps = doc.get(sp)
        if not steps:
            continue
        for si in steps.value().items:
            var p = sp.copy()
            p.append(si)
            var idp = p.copy()
            idp.append("id")
            var id = _string(doc, idp, "a step's `id`")
            if id.byte_length() == 0:
                raise Error("upgrade: a step of ", version, " has no id")
            if id in ids:
                raise Error("upgrade: the step id '", id, "' is used twice")
            ids[id] = True
            var wp = p.copy()
            wp.append("when")
            var when = _string(doc, wp, String("the step ", id, "'s `when`"))
            if when.byte_length() == 0:
                when = "after"
            if when != "before" and when != "after":
                raise Error(
                    "upgrade: the step ",
                    id,
                    ": when is before or after, not '",
                    when,
                    "'",
                )
            var rp = p.copy()
            rp.append("run")
            var mp = p.copy()
            mp.append("manual")
            var run = _string(doc, rp, String("the step ", id, "'s `run`"))
            var manual = _string(
                doc, mp, String("the step ", id, "'s `manual`")
            )
            if (run.byte_length() > 0) == (manual.byte_length() > 0):
                raise Error(
                    "upgrade: the step ", id, " needs one of run and manual"
                )
            if run.byte_length() > 0:
                if not run.startswith("morca "):
                    raise Error(
                        "upgrade: the step ",
                        id,
                        " runs '",
                        run,
                        "': only morca commands run",
                    )
                # What morca-stack upgrade-run passes on: words of these, no quoting.
                for b in run.as_bytes():
                    var ok = (
                        (b >= UInt8(ord("a")) and b <= UInt8(ord("z")))
                        or (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
                        or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
                        or b == UInt8(ord(" "))
                        or b == UInt8(ord("."))
                        or b == UInt8(ord("_"))
                        or b == UInt8(ord(":"))
                        or b == UInt8(ord("/"))
                        or b == UInt8(ord("@"))
                        or b == UInt8(ord("="))
                        or b == UInt8(ord(","))
                        or b == UInt8(ord("+"))
                        or b == UInt8(ord("-"))
                    )
                    if not ok:
                        raise Error(
                            "upgrade: the step ",
                            id,
                            "'s command has '",
                            chr(Int(b)),
                            "': letters, digits, spaces and ._:/@=,+- only",
                        )
                out.append(UpgradeStep(version, id, when, "run", run))
            else:
                out.append(
                    UpgradeStep(
                        version, id, when, "manual", manual.replace("\t", " ")
                    )
                )
    return out^


def select_steps(
    steps: List[UpgradeStep], from_v: String, to_v: String, when: String = ""
) raises -> List[UpgradeStep]:
    """The steps of each version after `from_v` up to `to_v`, in version
    order and then the file's (only `to_v`'s when `from_v` isn't a
    version), and only those `when` (`before`, `after`) when given."""
    var to = version_parts(to_v)
    if len(to) == 0:
        raise Error("upgrade: --to '", to_v, "' isn't a version")
    var frm = version_parts(from_v)
    var picked = List[UpgradeStep]()
    for ref s in steps:
        if when.byte_length() > 0 and s.when != when:
            continue
        var v = version_parts(s.version)
        var in_range: Bool
        if len(frm) == 0:
            in_range = not version_less(v, to) and not version_less(to, v)
        else:
            in_range = version_less(frm, v) and not version_less(to, v)
        if in_range:
            picked.append(s.copy())
    # Stable by version: an insertion sort keeps the file's order within one.
    for i in range(1, len(picked)):
        var j = i
        while j > 0 and version_less(
            version_parts(picked[j].version),
            version_parts(picked[j - 1].version),
        ):
            picked.swap_elements(j - 1, j)
            j -= 1
    return picked^


def merge_runs(steps: List[UpgradeStep]) -> List[UpgradeStep]:
    """`steps` with each command (`run`, the same `when` and text after
    trimming spaces) once, where it last comes, so after whatever the
    earlier versions' steps change; its id is the ids of every step that
    asked for it, in order, comma-separated. Manual steps stay as they are.
    """
    var keys = List[String]()
    for ref s in steps:
        keys.append(String(s.when, "\t", s.text.strip()))
    var out = List[UpgradeStep]()
    for i in range(len(steps)):
        if steps[i].kind != "run":
            out.append(steps[i].copy())
            continue
        var later = False
        for j in range(i + 1, len(steps)):
            if steps[j].kind == "run" and keys[j] == keys[i]:
                later = True
                break
        if later:
            continue
        var ids = String()
        for j in range(i + 1):
            if steps[j].kind == "run" and keys[j] == keys[i]:
                if ids.byte_length() > 0:
                    ids += ","
                ids += steps[j].id
        out.append(
            UpgradeStep(
                steps[i].version,
                ids,
                steps[i].when,
                "run",
                String(steps[i].text.strip()),
            )
        )
    return out^


def step_line(s: UpgradeStep) -> String:
    return String(
        "step\t",
        s.id,
        "\t",
        s.when,
        "\t",
        s.kind,
        "\t",
        s.text.replace("\n", " "),
    )


def upgrade_command(args: List[String]) raises -> Int:
    """`morca upgrade [--file F] [--from V] --to V [--when before|after]`."""
    var file = getenv("MORCA_UPGRADE", DEFAULT_FILE)
    var from_v = String()
    var to_v = String()
    var when = String()
    var i = 2
    while i < len(args):
        var a = args[i]
        if i + 1 >= len(args):
            print("morca upgrade:", a, "needs a value")
            return 2
        if a == "--file":
            file = args[i + 1]
        elif a == "--from":
            from_v = args[i + 1]
        elif a == "--to":
            to_v = args[i + 1]
        elif a == "--when":
            when = args[i + 1]
            if when != "before" and when != "after":
                print("morca upgrade: --when is before or after")
                return 2
        else:
            print("morca upgrade: unknown argument", a)
            return 2
        i += 2
    if to_v.byte_length() == 0:
        print("morca upgrade needs --to <version>")
        return 2
    if not exists(file):
        return 0
    var text: String
    with open(file, "r") as f:
        text = f.read()
    for ref s in merge_runs(
        select_steps(parse_upgrade(text), from_v, to_v, when)
    ):
        print(step_line(s))
    return 0
