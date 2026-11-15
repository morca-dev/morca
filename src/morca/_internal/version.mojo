"""Which morca a binary was built from, so the `morca` the morca-mojo package
ships and a project's pipelines can be told apart when they're from
different releases (#455, docs/binaries.md).

`MORCA_VERSION` is the package's version, as pixi.toml's `[package]` and
shelf.toml say it; `tests/version.sh` (CI's lint job) fails when they
differ, so a release bumps it with them. `morca version` prints it, each
pipeline's `describe` says it (`"morca"`), and `morca register` refuses a
pipeline built from another one (`mismatch`), unless
`MORCA_MIXED_VERSIONS=1`, when it only warns.
"""

from std.os import getenv

comptime MORCA_VERSION = "0.32.0"
"""morca-mojo's version: pixi.toml's `[package] version`."""


def built_with(describe: String) -> String:
    """The morca version a pipeline's `describe` (JSON) names, or empty for
    a binary from before describe said it (morca-mojo 0.32.0 and older)."""
    comptime key: StaticString = '"morca": "'
    var at = describe.rfind(key)
    if at < 0:
        return ""
    var start = at + key.byte_length()
    var end = describe.find('"', start)
    if end < 0:
        return ""
    return String(describe[byte=start:end])


def mismatch(binary: String, describe: String) -> String:
    """Why the pipeline `binary`, whose `describe` this is, wasn't built from
    this morca, or empty when it was (or doesn't say)."""
    var theirs = built_with(describe)
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
