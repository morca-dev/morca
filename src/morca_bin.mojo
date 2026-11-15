"""`morca`, as the morca-mojo package builds it into its bin/ (#455,
docs/binaries.md): bin/scheduler.mojo's two lines.

Here, in src/ beside the `morca` package rather than in bin/, because
pixi-build-mojo builds a package's binaries in a work directory of its own,
where `-I src` finds nothing: Mojo finds `morca` from a file in the
directory that holds it. Not inside the package, which can't have a
`main()`.
"""

from morca.command import morca_command


def main() raises:
    morca_command()
