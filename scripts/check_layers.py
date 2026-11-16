#!/usr/bin/env python3
"""Checks that morca's packages form layers (AGENTS.md, "No circular imports").

customs checks cycles between modules; this checks the packages above them:

- `morca._common` imports nothing of morca's but `_common`;
- `morca._lake` imports only `_lake` and `_common`;
- `morca._internal` imports `_internal`, `_lake`, `_common`, and only those
  public modules that import no `_internal` module, directly or through
  others (`morca.civil`, `morca.day`, ...): never `morca.ctx`,
  `morca.pipeline` or `morca` itself, which would close a cycle through
  `_internal`.

Run `python3 scripts/check_layers.py [REPO]` (default: this repo). Exits 1 on a finding.
"""

import os
import re
import sys

SRC = "src"


def blank(text):
    """The text with comments and string literals blanked, lines kept."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "#":
            j = text.find("\n", i)
            j = n if j < 0 else j
            i = j
            continue
        if c in "\"'":
            q = text[i : i + 3]
            if q in ('"""', "'''"):
                j = text.find(q, i + 3)
                j = n if j < 0 else j + 3
            else:
                j = i + 1
                while j < n and text[j] != c and text[j] != "\n":
                    j += 2 if text[j] == "\\" else 1
                j += 1
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:j]))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def modules():
    """Module name to file, for each module of the `morca` package."""
    mods = {}
    root = os.path.join(SRC, "morca")
    for d, _, files in os.walk(root):
        if not os.path.exists(os.path.join(d, "__init__.mojo")):
            continue
        pkg = os.path.relpath(d, SRC).replace(os.sep, ".")
        for f in files:
            if not f.endswith(".mojo"):
                continue
            name = pkg if f == "__init__.mojo" else pkg + "." + f[:-5]
            mods[name] = os.path.join(d, f)
    return mods


IMPORT = re.compile(
    r"^[ \t]*(?:from\s+(\.*[\w.]*)\s+import\s+(\([^)]*\)|[^\n]*(?:\\\n[^\n]*)*)"
    r"|import\s+([^\n]*))",
    re.M,
)


def imports(name, path, mods):
    """(line, imported module) for each morca module `name` imports."""
    text = blank(open(path, encoding="utf-8").read())
    pkg = name if path.endswith("__init__.mojo") else name.rpartition(".")[0]
    found = []
    for m in IMPORT.finditer(text):
        line = text.count("\n", 0, m.start()) + 1
        if m.group(1) is not None:
            base = m.group(1)
            if base.startswith("."):
                dots = len(base) - len(base.lstrip("."))
                parts = pkg.split(".")
                parts = parts[: len(parts) - (dots - 1)] if dots > 1 else parts
                rest = base.lstrip(".")
                base = ".".join(parts + ([rest] if rest else []))
            targets = [base]
            names = re.sub(r"[()\\]", " ", m.group(2))
            for item in names.split(","):
                word = item.split()
                if word:
                    targets.append(base + "." + word[0])
        else:
            targets = [t.split()[0] for t in m.group(3).split(",") if t.split()]
        for t in targets:
            while t and t not in mods:
                t = t.rpartition(".")[0]
            if t and t != name and (line, t) not in found:
                found.append((line, t))
    return found


def layer(name):
    parts = name.split(".")
    if len(parts) > 1 and parts[1] in ("_common", "_lake", "_internal"):
        return parts[1]
    return "public"


def main():
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    os.chdir(sys.argv[1] if len(sys.argv) > 1 else here)
    mods = modules()
    graph = {n: imports(n, p, mods) for n, p in mods.items()}

    # Public modules that reach `_internal`, directly or through others.
    reaches = {n for n in mods if layer(n) == "public" and any(
        layer(t) == "_internal" for _, t in graph[n])}
    changed = True
    while changed:
        changed = False
        for n in mods:
            if layer(n) == "public" and n not in reaches and any(
                    t in reaches for _, t in graph[n]):
                reaches.add(n)
                changed = True

    allowed = {
        "_common": {"_common"},
        "_lake": {"_lake", "_common"},
        "_internal": {"_internal", "_lake", "_common"},
    }
    bad = 0
    for n in sorted(mods):
        lay = layer(n)
        if lay == "public":
            continue
        for line, t in graph[n]:
            tl = layer(t)
            if tl in allowed[lay]:
                continue
            if lay == "_internal" and tl == "public" and t not in reaches:
                continue
            why = (
                f"{t} imports morca._internal, directly or through others"
                if tl == "public" and lay == "_internal"
                else f"morca.{lay} may import only "
                + ", ".join("morca." + a for a in sorted(allowed[lay]))
            )
            print(f"{mods[n]}:{line}: {n} imports {t}: {why}")
            bad += 1
    print(f"check_layers: {len(mods)} modules: {bad} imports across layers")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
