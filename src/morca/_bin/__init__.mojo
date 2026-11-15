"""The programs the morca-mojo package builds into its bin/ (#455,
docs/binaries.md): `morca` from `morca_main` and `morca_maintain` from
`maintain_main`. They're here, inside the package, and not only in bin/,
because pixi-build-mojo builds a package's binaries from a work directory of
its own, where `-I src` finds nothing: Mojo finds `morca` from a file inside
it, as it does for liblake. bin/scheduler.mojo and bin/morca_maintain.mojo
are the same two lines, which morca's own tests and a project that builds
its own `morca` use.
"""
