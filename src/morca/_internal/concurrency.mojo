"""Concurrency keys (#397): `concurrency = { key = "mojo_live", limit = 1 }`
in morca.toml, a limit on the runs that hold one key at once, across every
pipeline that declares it and every scheduler instance and worker.

    [pipelines.mojo_live]
    concurrency = { key = "mojo_live", limit = 1 }

A run holds its pipeline's key while it runs (`orca.runs.concurrency_key`,
recorded as it starts). A start counts the live runs holding the key under
an advisory lock on it (`morca._internal.db.concurrency.lock_key`), in the
same transaction as the start, so two schedulers (an old and a new one
during a deploy's overlap) or a scheduler and a worker's claim never both
take the last slot. A queued run over the limit waits, and says for which
run (`held`, and `runs.waits_on` for the runs list).

**The wait limit.** A run that waits on a key held by a run of an older
code version (one that's outdated, `morca._internal.handover`) waits at
most `MORCA_HANDOVER_WAIT_SECONDS`, then fails, "timed out waiting for run
12 (version aaaa1111aaaa)". The old run is left alone: nothing is killed.
The setting is required when a registered pipeline declares a key: the
scheduler refuses to start without it (`check_wait_limit`), and so does
`morca register` of such a pipeline. Without a key nothing is required and
runs start as before.

This module is the setting's text and the wait limit; the queries are
`morca._internal.db.concurrency`, the scheduler's and the workers' part
`morca._internal.key_wait`.
"""

from std.os import getenv

comptime WAIT_ENV = "MORCA_HANDOVER_WAIT_SECONDS"
"""How long a run may wait on a key an older version's run holds."""

comptime MAX_LIMIT = 1000
"""A key's largest `limit`."""


def key_problem(key: String) -> String:
    """Why `key` can't be a concurrency key, or empty: 1 to 64 letters,
    digits, `_`, `-` and `.`."""
    if key.byte_length() == 0 or key.byte_length() > 64:
        return String("is 1 to 64 characters, not ", key.byte_length())
    for b in key.as_bytes():
        var c = Int(b)
        if not (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("A") and c <= ord("Z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord("_")
            or c == ord("-")
            or c == ord(".")
        ):
            return String("is letters, digits, _, - and ., not ", key)
    return String()


def concurrency_text(key: String, limit: Int) -> String:
    """How registration keeps a key and its limit: `mojo_live:1`."""
    return String(key, ":", limit)


def parse_concurrency(text: String) raises -> Tuple[String, Int]:
    """`concurrency_text`'s key and limit, checked."""
    var colon = text.rfind(":")
    if colon <= 0:
        raise Error('is { key = "...", limit = N }, not ', text)
    var key = String(text[byte=:colon])
    var why = key_problem(key)
    if why:
        raise Error("key ", why)
    var limit: Int
    try:
        limit = Int(String(text[byte = colon + 1 :]))
    except:
        raise Error("limit is a count from 1 to ", MAX_LIMIT)
    if limit < 1 or limit > MAX_LIMIT:
        raise Error("limit is a count from 1 to ", MAX_LIMIT, ", not ", limit)
    return (key^, limit)


def concurrency_toml(key: String, limit: Int) -> String:
    """The value as morca.toml writes it."""
    return String('{ key = "', key, '", limit = ', limit, " }")


def wait_limit() raises -> Float64:
    """`MORCA_HANDOVER_WAIT_SECONDS`, required when a pipeline declares a
    concurrency key: how long a run may wait on a key held by a run of an
    older code version before it fails. Raises when it's unset, not a
    number, or not above 0."""
    var v = getenv(WAIT_ENV)
    var how = String(
        ": a pipeline declares a concurrency key (concurrency = { key, limit }",
        " in morca.toml), and ",
        WAIT_ENV,
        " is how long, in seconds, a run waiting on the key may wait for a",
        " run of an older code version to end before it fails",
        " (docs/morca-toml.md#concurrency-keys). Set it (in the Hetzner",
        " stack, HANDOVER_WAIT_SECONDS in hetzner.env)",
    )
    if not v:
        raise Error("morca: ", WAIT_ENV, " isn't set", how)
    var n: Float64
    try:
        n = Float64(v)
    except:
        raise Error(
            "morca: ", WAIT_ENV, " isn't a number of seconds (", v, ")", how
        )
    if not n > 0:
        raise Error("morca: ", WAIT_ENV, " isn't above 0 (", v, ")", how)
    return n
