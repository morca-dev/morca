"""The lake lib-tin (#454): `morca.tables` over a shared library, liblake.

- `abi`, `names`, `client`, `calls`, `schema`, `batch`, `expire`: no
  iceberg; the program builds them. `calls` is how it calls the library.
- `host`, `impl`, `lib`, `expire_impl`, `dataread` (with `dataask`,
  `datarows`, `datacache`): the library, and `liblake` its root;
  `rust_sink`, `rust_schema` and `rust_files` are its side of a Rust step.

Nothing here imports `morca._internal` or knows a `Ctx`: `morca._internal`
(and `morca.tables`) import this package, never the other way round, and
the host block over a step's `Ctx` is `morca._lakehost`'s. What the
two share lives in `morca._common`.
"""
