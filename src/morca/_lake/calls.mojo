"""liblake's exports as the program calls them: one function each, over
`morca._lake.client.Api`, taking what the export reads as typed values (a
`String`, a `Span`, an `Enc`, `Exported` batches, a host) and raising the
error it reports.

**Why typed.** An export takes addresses as integers, and an integer keeps
nothing alive: Mojo ends a value after its last use, and for
`f(Int(s.unsafe_ptr()))` that is before `f` runs. Here every value an export
reads is an argument of the function that calls it, borrowed until that
function returns, so the compiler keeps the caller's value alive across the
call; callers pass values, never addresses. The out slots of a call are one
`_Call`, which `check` reads right after the call on every path, so it too
outlives the call (an export may write an out slot before it fails).

The table, reader and writer handles stay integers: each is owned by a
value of the caller's (`morca.tables.Table`, `BatchReader`, `FileWriter`),
held as a field or an argument across the call.

**The host** is anything `Hosting`: `morca._lakehost.HostBlock`
over the step's `Ctx`, or `NoHost` outside any step. A call whose callbacks
change the `Ctx` (a pin, a fence, a commit) takes only a `writable` host,
one over a `mut` borrow of it, and says so at compile time.
"""

from arrow_mlake.carrow_import import ImportedArray, ImportedStream
from parquet import RecordBatch

from morca._lake.abi import Enc, Slots, bytes_of, get_int, put_int, text_of
from morca._lake.client import Api, Exported


# ── the host ────────────────────────────────────────────────────────────────


trait Hosting:
    """What a call into liblake reaches the step through."""

    comptime writable: Bool
    """Whether the library may change the step's records through it
    (`Ctx.pin`, `fence`, `committed`)."""

    def host_addr(self) -> Int:
        """The host block's address, or 0 for none."""
        ...


struct NoHost(Hosting, Movable):
    """No host: a call outside any step, which checks and records nothing."""

    comptime writable = True

    def __init__(out self):
        pass

    def host_addr(self) -> Int:
        return 0


def _needs_writable[H: Hosting]():
    comptime assert H.writable, (
        "lake: this call changes the step's records: its host must be over"
        " a `mut` Ctx"
    )


# ── a call's out slots ──────────────────────────────────────────────────────


struct _Call(Movable):
    """A call's out slots on the heap (`morca._lake.abi.Slots`): the error's
    block, then `n` more. Read (`check`) after the call on every path, so
    it outlives the call."""

    var slots: Slots

    def __init__(out self, n: Int = 0):
        self.slots = Slots(2 + n)

    def err(self) -> Int:
        """The error's out block."""
        return self.slots.addr

    def out(self, i: Int) -> Int:
        """The address of out slot `i`; an out block is two."""
        return self.slots.addr + 16 + 8 * i

    def get(self, i: Int) -> Int:
        return self.slots[2 + i]

    def check(self, a: Api, failed: Bool) raises:
        """Raises the error the library wrote, if the call `failed`."""
        if failed:
            var msg = text_of(self.slots[0], self.slots[1])
            a.free_text(self.slots[0])
            raise Error(msg^)

    def take_bytes(self, a: Api, i: Int = 0) -> List[UInt8]:
        """The buffer the library wrote to the out block at slot `i`, copied
        and freed."""
        var b = bytes_of(self.get(i), self.get(i + 1))
        a.free_text(self.get(i))
        return b^


def _stream(addr: Int) raises -> List[RecordBatch]:
    """The batches of an `ArrowArrayStream` the library handed over."""
    var out = List[RecordBatch]()
    if addr == 0:
        return out^
    var s = ImportedStream(addr)
    while True:
        var b = s.next()
        if not b:
            break
        out.append(b.take())
    return out^


def _batch(c: _Call) raises -> RecordBatch:
    """The batch the library exported to out slots 0 and 1."""
    return ImportedArray(c.get(0), c.get(1)).into_batch()


# ── tables ──────────────────────────────────────────────────────────────────


def load(a: Api, location: String) raises -> Int:
    var c = _Call()
    var h = a.load(Int(location.unsafe_ptr()), location.byte_length(), c.err())
    c.check(a, h == 0)
    return h


def load_dataset(a: Api, dataset: String) raises -> Int:
    var c = _Call()
    var h = a.load_dataset(
        Int(dataset.unsafe_ptr()), dataset.byte_length(), c.err()
    )
    c.check(a, h == 0)
    return h


def table[H: Hosting](a: Api, host: H, dataset: String) raises -> Int:
    var c = _Call()
    var h = a.table(
        host.host_addr(),
        Int(dataset.unsafe_ptr()),
        dataset.byte_length(),
        c.err(),
    )
    c.check(a, h == 0)
    return h


def ensure_table[
    H: Hosting
](
    a: Api,
    host: H,
    dataset: String,
    schema_json: String,
    spec_json: String,
    properties: Enc,
) raises -> Int:
    var c = _Call()
    var h = a.ensure_table(
        host.host_addr(),
        Int(dataset.unsafe_ptr()),
        dataset.byte_length(),
        Int(schema_json.unsafe_ptr()),
        schema_json.byte_length(),
        Int(spec_json.unsafe_ptr()),
        spec_json.byte_length(),
        properties.addr(),
        len(properties),
        c.err(),
    )
    c.check(a, h == 0)
    return h


def table_exists(a: Api, dataset: String) raises -> Bool:
    var c = _Call(1)
    var rc = a.table_exists(
        Int(dataset.unsafe_ptr()), dataset.byte_length(), c.out(0), c.err()
    )
    c.check(a, rc != 0)
    return c.get(0) != 0


def table_refresh(a: Api, h: Int) raises:
    var c = _Call()
    var rc = a.table_refresh(h, c.err())
    c.check(a, rc != 0)


def table_meta(a: Api, h: Int) raises -> List[UInt8]:
    var c = _Call(2)
    var rc = a.table_meta(h, c.out(0), c.err())
    c.check(a, rc != 0)
    return c.take_bytes(a)


def read_file(a: Api, h: Int, path: String) raises -> List[RecordBatch]:
    var c = _Call(1)
    var rc = a.read_file(
        h, Int(path.unsafe_ptr()), path.byte_length(), c.out(0), c.err()
    )
    c.check(a, rc != 0)
    return _stream(c.get(0))


def delete_file(a: Api, h: Int, path: String) raises:
    var c = _Call()
    var rc = a.delete_file(
        h, Int(path.unsafe_ptr()), path.byte_length(), c.err()
    )
    c.check(a, rc != 0)


# ── reading ─────────────────────────────────────────────────────────────────


def pin[H: Hosting](a: Api, host: H, h: Int) raises -> Int64:
    _needs_writable[H]()
    var c = _Call(1)
    var rc = a.pin(host.host_addr(), h, c.out(0), c.err())
    c.check(a, rc != 0)
    return Int64(c.get(0))


def scan(a: Api, h: Int, opts: Enc) raises -> List[RecordBatch]:
    var c = _Call(1)
    var rc = a.scan(h, opts.addr(), len(opts), c.out(0), c.err())
    c.check(a, rc != 0)
    return _stream(c.get(0))


def reader_open(a: Api, h: Int, opts: Enc) raises -> Int:
    """A batch reader's handle, or 0 for a scan with nothing to read."""
    var c = _Call(1)
    var rc = a.reader_open(h, opts.addr(), len(opts), c.out(0), c.err())
    c.check(a, rc != 0)
    return c.get(0)


def reader_next(a: Api, r: Int) raises -> Optional[RecordBatch]:
    """The reader's next batch, or nothing once it's done."""
    var c = _Call(2)
    var rc = a.reader_next(r, c.out(0), c.out(1), c.err())
    c.check(a, rc != 0)
    if c.get(0) == 0:
        return None
    return _batch(c)


def plan_files(a: Api, h: Int, opts: Enc) raises -> List[UInt8]:
    var c = _Call(2)
    var rc = a.plan_files(h, opts.addr(), len(opts), c.out(0), c.err())
    c.check(a, rc != 0)
    return c.take_bytes(a)


def count(a: Api, h: Int, opts: Enc) raises -> Int64:
    var c = _Call(1)
    var rc = a.count(h, opts.addr(), len(opts), c.out(0), c.err())
    c.check(a, rc != 0)
    return Int64(c.get(0))


def find_commit[H: Hosting](a: Api, host: H, h: Int) -> Int64:
    return a.find_commit(host.host_addr(), h)


# ── batches and schemas ─────────────────────────────────────────────────────


def empty_batch(a: Api, schema_json: String) raises -> RecordBatch:
    var c = _Call(2)
    var rc = a.empty_batch(
        Int(schema_json.unsafe_ptr()),
        schema_json.byte_length(),
        c.out(0),
        c.out(1),
        c.err(),
    )
    c.check(a, rc != 0)
    return _batch(c)


def concat(a: Api, batches: Exported) raises -> RecordBatch:
    var c = _Call(2)
    var rc = a.concat(
        batches.n(),
        batches.arrays_addr(),
        batches.schemas_addr(),
        c.out(0),
        c.out(1),
        c.err(),
    )
    c.check(a, rc != 0)
    return _batch(c)


def schema_fields(a: Api, schema_json: String) raises -> List[UInt8]:
    var c = _Call(2)
    var rc = a.schema_fields(
        Int(schema_json.unsafe_ptr()),
        schema_json.byte_length(),
        c.out(0),
        c.err(),
    )
    c.check(a, rc != 0)
    return c.take_bytes(a)


# ── writing ─────────────────────────────────────────────────────────────────


def write_files(a: Api, h: Int, batches: Exported) raises -> List[UInt8]:
    var c = _Call(2)
    var rc = a.write_files(
        h,
        batches.n(),
        batches.arrays_addr(),
        batches.schemas_addr(),
        c.out(0),
        c.err(),
    )
    c.check(a, rc != 0)
    return c.take_bytes(a)


def writer_new(a: Api, h: Int) raises -> Int:
    var c = _Call()
    var w = a.writer_new(h, c.err())
    c.check(a, w == 0)
    return w


def writer_options(a: Api, w: Int) -> List[UInt8]:
    var c = _Call(2)
    a.writer_options(w, c.out(0))
    return c.take_bytes(a)


def writer_write(
    a: Api, w: Int, opts: Enc, batches: Exported, row_group: Bool
) raises:
    var c = _Call()
    var rc = a.writer_write(
        w,
        opts.addr(),
        len(opts),
        batches.n(),
        batches.arrays_addr(),
        batches.schemas_addr(),
        1 if row_group else 0,
        c.err(),
    )
    c.check(a, rc != 0)


def writer_close(a: Api, w: Int) raises:
    var c = _Call()
    var rc = a.writer_close(w, c.err())
    c.check(a, rc != 0)


def writer_finish(a: Api, w: Int) raises -> List[UInt8]:
    var c = _Call(2)
    var rc = a.writer_finish(w, c.out(0), c.err())
    c.check(a, rc != 0)
    return c.take_bytes(a)


def files_info(a: Api, files: Span[UInt8, _]) raises -> List[UInt8]:
    var c = _Call(2)
    var rc = a.files_info(
        Int(files.unsafe_ptr()), len(files), c.out(0), c.err()
    )
    c.check(a, rc != 0)
    return c.take_bytes(a)


def files_concat(
    a: Api, x: Span[UInt8, _], y: Span[UInt8, _]
) raises -> List[UInt8]:
    var c = _Call(2)
    var rc = a.files_concat(
        Int(x.unsafe_ptr()),
        len(x),
        Int(y.unsafe_ptr()),
        len(y),
        c.out(0),
        c.err(),
    )
    c.check(a, rc != 0)
    return c.take_bytes(a)


def files_decode(
    a: Api, buf: Span[UInt8, _], mut pos: Int
) raises -> List[UInt8]:
    """The entries encoded in `buf` from `pos`, which it moves past them."""
    var c = _Call(3)
    put_int(c.out(2), 0, pos)
    var rc = a.files_decode(
        Int(buf.unsafe_ptr()), len(buf), c.out(2), c.out(0), c.err()
    )
    c.check(a, rc != 0)
    pos = c.get(2)
    return c.take_bytes(a)


# ── a Rust step's sink (`morca._lake.rust_sink`) ────────────────────────────


def sink_new(
    a: Api, h: Int, name: String, dir: String, flush_bytes: Int
) raises -> Int:
    var c = _Call()
    var sink = a.sink_new(
        h,
        Int(name.unsafe_ptr()),
        name.byte_length(),
        Int(dir.unsafe_ptr()),
        dir.byte_length(),
        flush_bytes,
        c.err(),
    )
    c.check(a, sink == 0)
    return sink


def sink_schema(a: Api, sink: Int, stream: ImportedStream) raises:
    """Checks `stream`'s schema, which the library reads during the call."""
    var c = _Call()
    var rc = a.sink_schema(sink, stream.schema_address(), c.err())
    c.check(a, rc != 0)


def sink_put(a: Api, sink: Int, stream: ImportedStream, array: Slots) raises:
    """Moves the `ArrowArray` in `array` (10 slots), one of `stream`'s, to
    the library, leaving `array` released; the library reads it with the
    stream's schema during the call."""
    debug_assert(array.n >= 10, "lake: an ArrowArray takes 10 slots")
    var c = _Call()
    var rc = a.sink_put(sink, array.addr, stream.schema_address(), c.err())
    c.check(a, rc != 0)


def sink_take(a: Api, sink: Int, path: String) raises:
    var c = _Call()
    var rc = a.sink_take(
        sink, Int(path.unsafe_ptr()), path.byte_length(), c.err()
    )
    c.check(a, rc != 0)


def sink_finish(a: Api, sink: Int) raises -> List[UInt8]:
    var c = _Call(2)
    var rc = a.sink_finish(sink, c.out(0), c.err())
    c.check(a, rc != 0)
    return c.take_bytes(a)


# ── committing ──────────────────────────────────────────────────────────────


def append[
    H: Hosting
](a: Api, host: H, h: Int, batches: Exported, mode: Int) raises -> Int64:
    _needs_writable[H]()
    var c = _Call()
    var id = a.append(
        host.host_addr(),
        h,
        batches.n(),
        batches.arrays_addr(),
        batches.schemas_addr(),
        mode,
        c.err(),
    )
    c.check(a, id == -2)
    return id


def append_files[
    H: Hosting
](a: Api, host: H, h: Int, files: Span[UInt8, _], mode: Int) raises -> Int64:
    _needs_writable[H]()
    var c = _Call()
    var id = a.append_files(
        host.host_addr(), h, Int(files.unsafe_ptr()), len(files), mode, c.err()
    )
    c.check(a, id == -2)
    return id


def commit[
    H: Hosting
](a: Api, host: H, h: Int, operation: String, changes: Enc) raises -> Int64:
    _needs_writable[H]()
    var c = _Call()
    var id = a.commit(
        host.host_addr(),
        h,
        Int(operation.unsafe_ptr()),
        operation.byte_length(),
        changes.addr(),
        len(changes),
        c.err(),
    )
    c.check(a, id == -2)
    return id


# ── maintenance ─────────────────────────────────────────────────────────────


def expire(a: Api, ask: Enc) raises -> List[UInt8]:
    var c = _Call(2)
    var rc = a.expire(ask.addr(), len(ask), c.out(0), c.err())
    c.check(a, rc != 0)
    return c.take_bytes(a)


def data(a: Api, args: Enc) raises -> List[UInt8]:
    var c = _Call(2)
    var rc = a.data(args.addr(), len(args), c.out(0), c.err())
    c.check(a, rc != 0)
    return c.take_bytes(a)
