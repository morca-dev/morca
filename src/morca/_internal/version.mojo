"""Which morca a binary was built from, so the `morca` the morca-mojo package
ships and a project's pipelines can be told apart when they're from
different releases (#455, docs/binaries.md).

`MORCA_VERSION` is the package's version, as pixi.toml's `[package]` and
shelf.toml say it; `tests/version.sh` (CI's lint job) fails when they
differ, so a release bumps it with them. `morca version` prints it, each
pipeline's `describe` says it (`"morca"`), and `morca register` refuses a
pipeline built from another one (`mismatch`), unless
`MORCA_MIXED_VERSIONS=1`, when it only warns.

`PROTOCOL_VERSION` is the version of the pipeline-binary protocol
(docs/pipeline-protocol.md) this morca speaks, which describe says as
`"protocol"` (#525). A binary not built with morca-mojo (#521) says that
and no `"morca"`; `morca register` refuses a protocol it doesn't speak.
"""

from std.os import getenv
from json import Value, loads

comptime MORCA_VERSION = "0.43.0"
"""morca-mojo's version: pixi.toml's `[package] version`."""

comptime PROTOCOL_VERSION = 1
"""The pipeline-binary protocol's version (docs/pipeline-protocol.md):
describe's `"protocol"`. Raised only when a change to the protocol would
break a binary written to the one before."""


def parse_describe(binary: String, describe: String) raises -> Value:
    """`describe`'s JSON, checked to be an object with a non-empty string
    `pipeline`; whitespace and key order don't matter (#524)."""
    var d: Value
    try:
        d = loads(describe)
    except e:
        raise Error(
            "morca: ",
            binary,
            " describe didn't print JSON (",
            e,
            "): ",
            describe,
        )
    if (
        not d.is_object()
        or "pipeline" not in d
        or not d["pipeline"].is_string()
        or not d["pipeline"].string_value()
    ):
        raise Error(
            "morca: ",
            binary,
            " describe printed no object with a `pipeline` name: ",
            describe,
        )
    return d^


def built_with(d: Value) raises -> String:
    """The morca version a pipeline's parsed `describe` names, or empty for
    a binary from before describe said it (morca-mojo 0.32.0 and older) or
    one not built with morca-mojo."""
    if "morca" in d and d["morca"].is_string():
        return d["morca"].string_value()
    return ""


def protocol_refusal(binary: String, d: Value) raises -> String:
    """Why this morca can't register the pipeline `binary`, whose parsed
    `describe` this is, for the protocol it says it speaks, or empty when
    it speaks this one or doesn't say (#525)."""
    if "protocol" not in d:
        return ""
    var p = d["protocol"].copy()
    if not p.is_int() or p.int_value() < 1:
        return String(
            binary, "'s describe has a protocol that isn't a version number"
        )
    if p.int_value() > PROTOCOL_VERSION:
        return String(
            binary,
            " speaks pipeline protocol ",
            p.int_value(),
            " and this morca speaks ",
            PROTOCOL_VERSION,
            ": upgrade morca",
        )
    return ""


def mismatch(binary: String, d: Value) raises -> String:
    """Why the pipeline `binary`, whose parsed `describe` this is, wasn't
    built from this morca, or empty when it was (or doesn't say)."""
    var theirs = built_with(d)
    if not theirs or theirs == MORCA_VERSION:
        return ""
    return String(
        binary,
        " was built with morca ",
        theirs,
        " and this morca is ",
        MORCA_VERSION,
    )


comptime MISMATCH_HINT = (
    "build the pipelines with, and run the `morca` of, one morca-mojo (the"
    " package ships `morca` in its bin/), or set MORCA_MIXED_VERSIONS=1 to"
    " register it anyway"
)
"""What `morca register` says to do about a `mismatch`."""


def mixed_allowed() -> Bool:
    """`MORCA_MIXED_VERSIONS=1`: a mismatch warns instead of refusing."""
    return getenv("MORCA_MIXED_VERSIONS") == "1"
