"""The lake lib-tin (#454): `morca.tables` over a shared library, liblake.

- `abi`, `names`, `client`: no iceberg; the program builds them.
- `host`, `impl`, `lib`: the library, and `liblake` its root; `rust_sink`,
  `rust_schema` and `rust_files` are its side of a Rust step.
"""
