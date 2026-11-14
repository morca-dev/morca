"""liblake's root (#454): the library's C symbols, each forwarding to its
function in `morca._lake.lib`. `mojo build --emit shared-lib` exports only
the root module's `@export` functions, and an `@export` function is
compiled into every program that imports its module, so the exports live
here, where only the library's build reaches them, and `morca._lake.lib`
(which `-D MORCA_LAKE_SOURCE=1` builds call directly) has none.

    scripts/build-liblake.sh   # mojo build --emit shared-lib -g1 ... this file

Keep it in step with `morca._lake.lib`: one forwarder per `lake_*`
function there, with its signature.
"""

import morca._lake.lib as lib


@export("lake_abi_version")
def lake_abi_version() abi("C") -> UInt32:
    return lib.lake_abi_version()


@export("lake_free_text")
def lake_free_text(p: Int) abi("C"):
    lib.lake_free_text(p)


@export("lake_load")
def lake_load(loc: Int, n: Int, err: Int) abi("C") -> Int:
    return lib.lake_load(loc, n, err)


@export("lake_load_dataset")
def lake_load_dataset(ds: Int, n: Int, err: Int) abi("C") -> Int:
    return lib.lake_load_dataset(ds, n, err)


@export("lake_table")
def lake_table(host: Int, ds: Int, n: Int, err: Int) abi("C") -> Int:
    return lib.lake_table(host, ds, n, err)


@export("lake_ensure_table")
def lake_ensure_table(
    host: Int,
    ds: Int,
    ds_n: Int,
    schema: Int,
    schema_n: Int,
    spec: Int,
    spec_n: Int,
    props: Int,
    props_n: Int,
    err: Int,
) abi("C") -> Int:
    return lib.lake_ensure_table(
        host, ds, ds_n, schema, schema_n, spec, spec_n, props, props_n, err
    )


@export("lake_table_free")
def lake_table_free(h: Int) abi("C"):
    lib.lake_table_free(h)


@export("lake_table_copy")
def lake_table_copy(h: Int) abi("C") -> Int:
    return lib.lake_table_copy(h)


@export("lake_table_refresh")
def lake_table_refresh(h: Int, err: Int) abi("C") -> Int32:
    return lib.lake_table_refresh(h, err)


@export("lake_table_meta")
def lake_table_meta(h: Int, out_block: Int, err: Int) abi("C") -> Int32:
    return lib.lake_table_meta(h, out_block, err)


@export("lake_pin")
def lake_pin(host: Int, h: Int, out_id: Int, err: Int) abi("C") -> Int32:
    return lib.lake_pin(host, h, out_id, err)


@export("lake_scan")
def lake_scan(
    h: Int, opts: Int, opts_n: Int, out_stream: Int, err: Int
) abi("C") -> Int32:
    return lib.lake_scan(h, opts, opts_n, out_stream, err)


@export("lake_plan_files")
def lake_plan_files(
    h: Int, opts: Int, opts_n: Int, out_block: Int, err: Int
) abi("C") -> Int32:
    return lib.lake_plan_files(h, opts, opts_n, out_block, err)


@export("lake_count")
def lake_count(
    h: Int, opts: Int, opts_n: Int, out_n: Int, err: Int
) abi("C") -> Int32:
    return lib.lake_count(h, opts, opts_n, out_n, err)


@export("lake_reader_open")
def lake_reader_open(
    h: Int, opts: Int, opts_n: Int, out_reader: Int, err: Int
) abi("C") -> Int32:
    return lib.lake_reader_open(h, opts, opts_n, out_reader, err)


@export("lake_reader_next")
def lake_reader_next(
    r: Int, out_array: Int, out_schema: Int, err: Int
) abi("C") -> Int32:
    return lib.lake_reader_next(r, out_array, out_schema, err)


@export("lake_reader_free")
def lake_reader_free(r: Int) abi("C"):
    lib.lake_reader_free(r)


@export("lake_schema_fields")
def lake_schema_fields(
    schema: Int, schema_n: Int, out_block: Int, err: Int
) abi("C") -> Int32:
    return lib.lake_schema_fields(schema, schema_n, out_block, err)


@export("lake_table_exists")
def lake_table_exists(ds: Int, n: Int, out_yes: Int, err: Int) abi("C") -> Int32:
    return lib.lake_table_exists(ds, n, out_yes, err)


@export("lake_read_file")
def lake_read_file(
    h: Int, path: Int, path_n: Int, out_stream: Int, err: Int
) abi("C") -> Int32:
    return lib.lake_read_file(h, path, path_n, out_stream, err)


@export("lake_delete_file")
def lake_delete_file(h: Int, path: Int, path_n: Int, err: Int) abi("C") -> Int32:
    return lib.lake_delete_file(h, path, path_n, err)


@export("lake_empty_batch")
def lake_empty_batch(
    schema: Int, schema_n: Int, out_array: Int, out_schema: Int, err: Int
) abi("C") -> Int32:
    return lib.lake_empty_batch(schema, schema_n, out_array, out_schema, err)


@export("lake_concat")
def lake_concat(
    n: Int, arrays: Int, schemas: Int, out_array: Int, out_schema: Int, err: Int
) abi("C") -> Int32:
    return lib.lake_concat(n, arrays, schemas, out_array, out_schema, err)


@export("lake_find_commit")
def lake_find_commit(host: Int, h: Int) abi("C") -> Int64:
    return lib.lake_find_commit(host, h)


@export("lake_append")
def lake_append(
    host: Int, h: Int, n: Int, arrays: Int, schemas: Int, mode: Int, err: Int
) abi("C") -> Int64:
    return lib.lake_append(host, h, n, arrays, schemas, mode, err)


@export("lake_append_files")
def lake_append_files(
    host: Int, h: Int, files: Int, files_n: Int, mode: Int, err: Int
) abi("C") -> Int64:
    return lib.lake_append_files(host, h, files, files_n, mode, err)


@export("lake_commit")
def lake_commit(
    host: Int,
    h: Int,
    op: Int,
    op_n: Int,
    changes: Int,
    changes_n: Int,
    err: Int,
) abi("C") -> Int64:
    return lib.lake_commit(host, h, op, op_n, changes, changes_n, err)


@export("lake_write_files")
def lake_write_files(
    h: Int, n: Int, arrays: Int, schemas: Int, out_block: Int, err: Int
) abi("C") -> Int32:
    return lib.lake_write_files(h, n, arrays, schemas, out_block, err)


@export("lake_writer_new")
def lake_writer_new(h: Int, err: Int) abi("C") -> Int:
    return lib.lake_writer_new(h, err)


@export("lake_writer_options")
def lake_writer_options(w: Int, out_block: Int) abi("C"):
    lib.lake_writer_options(w, out_block)


@export("lake_writer_write")
def lake_writer_write(
    w: Int,
    opts: Int,
    opts_n: Int,
    n: Int,
    arrays: Int,
    schemas: Int,
    row_group: Int,
    err: Int,
) abi("C") -> Int32:
    return lib.lake_writer_write(
        w, opts, opts_n, n, arrays, schemas, row_group, err
    )


@export("lake_writer_close")
def lake_writer_close(w: Int, err: Int) abi("C") -> Int32:
    return lib.lake_writer_close(w, err)


@export("lake_writer_finish")
def lake_writer_finish(w: Int, out_block: Int, err: Int) abi("C") -> Int32:
    return lib.lake_writer_finish(w, out_block, err)


@export("lake_writer_free")
def lake_writer_free(w: Int) abi("C"):
    lib.lake_writer_free(w)


@export("lake_files_info")
def lake_files_info(
    files: Int, files_n: Int, out_block: Int, err: Int
) abi("C") -> Int32:
    return lib.lake_files_info(files, files_n, out_block, err)


@export("lake_files_concat")
def lake_files_concat(
    a: Int, a_n: Int, b: Int, b_n: Int, out_block: Int, err: Int
) abi("C") -> Int32:
    return lib.lake_files_concat(a, a_n, b, b_n, out_block, err)


@export("lake_files_decode")
def lake_files_decode(
    buf: Int, n: Int, pos: Int, out_block: Int, err: Int
) abi("C") -> Int32:
    return lib.lake_files_decode(buf, n, pos, out_block, err)
