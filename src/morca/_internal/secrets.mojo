"""Secrets a pipeline's runs get: `morca register --secret NAME=ID`.

NAME is the environment variable a run reads; ID is the secret's ID in
Secrets Manager, under `orca/`, which is all the stack's run role may read.
On the ec2 runner each instance's script reads them at start with its role
and exports them, so the driver, the head and the workers all have them, and
`MORCA_SECRETS` lists their names for `morca._internal.logs.mask`, which keeps their
values out of every log morca writes. Postgres holds only the IDs.
"""

from json import loads

from morca._internal.json import quote


def _name_ok(name: String) -> Bool:
    if name.byte_length() == 0:
        return False
    var first = True
    for b in name.as_bytes():
        var c = Int(b)
        var letter = (c >= ord("A") and c <= ord("Z")) or c == ord("_")
        var digit = c >= ord("0") and c <= ord("9")
        if not letter and (first or not digit):
            return False
        first = False
    return True


def _id_ok(id: String) -> Bool:
    if not id.startswith("orca/") or id.byte_length() <= 5:
        return False
    for b in id.as_bytes():
        var c = Int(b)
        if not (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("A") and c <= ord("Z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord("/")
            or c == ord("_")
            or c == ord("+")
            or c == ord("=")
            or c == ord(".")
            or c == ord("@")
            or c == ord("-")
        ):
            return False
    return True


def secret_problem(spec: String) -> String:
    """What's wrong with `NAME=ID`, or "" if nothing is."""
    var eq = spec.find("=").or_else(-1)
    if eq < 0:
        return String("--secret wants NAME=ID, not ", spec)
    var name = String(spec[byte=:eq])
    var id = String(spec[byte = eq + 1 :])
    if not _name_ok(name):
        return String(
            "--secret's NAME is an environment variable, A-Z, 0-9 and _: ",
            name,
        )
    if not _id_ok(id):
        return String(
            "--secret's ID is a Secrets Manager secret under orca/: ", id
        )
    return ""


def secrets_json(specs: List[String]) -> String:
    """`NAME=ID`s as the JSON object Postgres keeps; "" for none."""
    if len(specs) == 0:
        return ""
    var out = String("{")
    for i in range(len(specs)):
        var eq = specs[i].find("=").or_else(-1)
        out.write(
            "" if i == 0 else ", ",
            quote(String(specs[i][byte=:eq])),
            ": ",
            quote(String(specs[i][byte = eq + 1 :])),
        )
    out.write("}")
    return out^


def parse_secrets(text: String) raises -> List[Tuple[String, String]]:
    """Postgres's JSON object back as (NAME, ID) pairs."""
    var out = List[Tuple[String, String]]()
    if not text or text == "{}":
        return out^
    for kv in loads(text).object_items():
        out.append((String(kv[0]), kv[1].string_value()))
    return out^


comptime _RESERVED_ENV = [
    "MORCA_DATABASE_URL",
    "MORCA_IMAGE",
    "MORCA_SECRETS",
    "MORCA_WORKERS",
    "DISTA_ROLE",
    "DISTA_HEAD",
    "DISTA_ADVERTISE",
    "DISTA_TOKEN",
    "DISTA_PORT",
    "DISTA_GROUP",
    "MORCA_GRANT_CPUS",
    "MORCA_GRANT_MEMORY_MB",
    "MORCA_GRANT_GPUS",
    "CUDA_VISIBLE_DEVICES",
    "MORCA_MEMORY_PRESSURE_FILE",
]
"""Variables morca gives a run itself, which `env` can't set. Of dista's,
`DISTA_WORKER_SLOTS` isn't here: a pipeline sets it (`"auto"` or a count,
docs/morca-toml.md), and a run cluster's worker reads it from `env`
(`morca._internal.worker_cluster`)."""


def env_name_problem(name: String) -> String:
    """Why `name` can't be a variable in `env`, or empty if it can."""
    var i = 0
    for b in name.as_bytes():
        var c = Int(b)
        var ok = (
            (c >= ord("A") and c <= ord("Z"))
            or (c >= ord("a") and c <= ord("z"))
            or c == ord("_")
            or (i > 0 and c >= ord("0") and c <= ord("9"))
        )
        if not ok:
            return String(
                "a variable's name is letters, digits and _, not ", name
            )
        i += 1
    if i == 0:
        return "a variable's name can't be empty"
    for r in materialize[_RESERVED_ENV]():
        if name == r:
            return String(name, " is set by morca itself")
    var upper = name.upper()
    for word in ["PASSWORD", "SECRET", "TOKEN", "DATABASE_URL"]:
        if word in upper:
            return String(
                name,
                " looks like a secret: put its Secrets Manager ID in",
                " secrets, not its value in env",
            )
    return ""
