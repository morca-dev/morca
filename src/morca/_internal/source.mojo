"""Where a pipeline binary's code came from: its git repository and commit,
given at build time:

    mojo build -D MORCA_SOURCE=https://github.com/me/lake \\
        -D MORCA_COMMIT=$(git rev-parse HEAD) \\
        -D MORCA_DIRTY=$(git diff --quiet HEAD && echo 0 || echo 1) ...

or, for the repository and commit, at run time: a binary built without the
defines reads `MORCA_SOURCE` and `MORCA_COMMIT` from its environment, which a
project image sets (`ENV`). An image's programs then don't change with each
commit, so Mojo's compile cache can serve a rebuild (census #153).

`describe` reports them, `morca register` and each run record them as a
version of the pipeline (`orca.pipeline_versions`), and `morca ui` links a
run to the commit it ran. A binary built without them has an empty source
and is shown as such.
"""

from std.os import getenv
from std.sys import get_defined_int, get_defined_string


def source_repo() -> String:
    """The repository: the define, else `MORCA_SOURCE` in the environment."""
    var r = String(get_defined_string["MORCA_SOURCE", ""]())
    return r if r else getenv("MORCA_SOURCE")


def source_commit() -> String:
    """The commit (the define, else `MORCA_COMMIT` in the environment), or
    "" if it isn't hex. `mojo build -D`
    reads a value of digits alone as a number, which a real SHA, with 40
    characters, practically never is."""
    var c = String(get_defined_string["MORCA_COMMIT", ""]())
    if not c:
        c = getenv("MORCA_COMMIT")
    return c if is_hex(c) else String()


def is_hex(s: String) -> Bool:
    for b in s.as_bytes():
        var digit = b >= UInt8(ord("0")) and b <= UInt8(ord("9"))
        if not digit and not (b >= UInt8(ord("a")) and b <= UInt8(ord("f"))):
            return False
    return True


def source_dirty() -> Bool:
    """Whether the tree it was built from had changes the commit lacks: the
    define only. A build with `-D MORCA_TEST_SOURCE_ENV=1`, which only
    scripts/pipelines.sh's test binary is, reads `MORCA_DIRTY` from the
    environment too when the define isn't given; in any other build that
    branch isn't compiled."""
    comptime d = get_defined_string["MORCA_DIRTY", ""]()
    comptime if get_defined_int["MORCA_TEST_SOURCE_ENV", 0]() == 1:
        if d == "":
            var e = getenv("MORCA_DIRTY")
            return e != "0" and e != "" and e != "false"
    return d != "0" and d != "" and d != "false"


def web_url(repo: String) -> String:
    """`repo`'s page, for the forms a remote is written in: https with or
    without `.git`, and `git@host:owner/name`; "" for anything else."""
    var r = String(repo.strip())
    if r.startswith("git@"):
        var colon = r.find(":").or_else(-1)
        if colon < 0:
            return ""
        var ssh = String(
            "https://", r[byte=4:colon], "/", r[byte = colon + 1 :]
        )
        r = ssh^
    elif r.startswith("ssh://git@"):
        var ssh = String("https://", r[byte=10:])
        r = ssh^
    if not r.startswith("https://") and not r.startswith("http://"):
        return ""
    if r.endswith(".git"):
        var bare = String(r[byte = : r.byte_length() - 4])
        r = bare^
    return String(r.rstrip("/"))


def commit_url(repo: String, commit: String) -> String:
    """The commit's tree on its host, or "" when either is unknown. GitHub,
    GitLab and Gitea all serve a tree at `<repo>/tree/<sha>`."""
    var web = web_url(repo)
    if not web or not commit:
        return ""
    if not is_hex(commit):
        return ""
    return String(web, "/tree/", commit)
