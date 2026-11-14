"""liblake's C ABI as both sides see it: the version, the host block's
layout, and how values cross. Nothing here imports iceberg: the wrapper
(`morca.tables`) and the library (`morca._lake.lib`) both build it.

**What crosses.** Integers, and pointers with lengths. Anything bigger than
a number is a byte buffer in the `Enc`/`Dec` encoding below (8-byte
little-endian integers; a string is its length, then its bytes; a list or a
map is its count, then its items). Rows are Arrow C Data Interface structs.

**Who frees what.** The side that allocated: a buffer the library returns
(through an out block, below) is freed with `lake_free_text`; a buffer a
host callback returns is the host's and is valid until its next callback.
A batch given to the library is moved to it: the library imports it
without copying and releases it, so the caller must not. A scan's
`ArrowArrayStream` is the caller's to release; its batches import without
copying too, and are released when the last of them dies.

**Out blocks and errors.** An out block is two 8-byte heap slots, the
address of a buffer and its length (`Slots`). A fallible export takes `err`,
an out block, and on failure writes the error's text there and returns its
failure value (0 for a handle, -2 for a snapshot id, 1 for a status).
Slots live on the heap because the optimiser doesn't know a call through a
pointer writes a stack variable whose address went as an integer, and may
read the old value back (LIB-TINS.md §5, item 3).

**The host block** is how the library reaches the step's `Ctx`: `HOST_SIZE`
bytes, the host's state address first, then `abi("C")` callbacks the
library calls on the caller's thread, inside the call.
"""

from std.memory.alloc import unsafe_alloc

comptime ABI_VERSION: UInt32 = 3
"""What `lake_abi_version()` returns. Bump it with any change to a signature,
an encoding, the host block or who owns what. 2: batches given to the
library are moved to it, not borrowed (arrow-mlake-mojo 0.3.0). 3: a data
file's partition values in `lake_plan_files` and `lake_files_info`, write
options and row groups in `lake_writer_write`, a status from
`lake_writer_finish`, and batch readers, schema fields, table exists and a
table's files (#464)."""

# Host block slots, as byte offsets.
comptime H_STATE = 0
comptime H_CHECK_DECLARED = 8
comptime H_PIN = 16
comptime H_FENCE = 24
comptime H_COMMITTED = 32
comptime H_SUMMARY = 40
comptime H_SAME_RUN = 48
comptime H_MADE = 56
comptime H_REPLACES = 64
comptime H_DECLARES_WRITE = 72
comptime H_LOG = 80
comptime H_COMMITS = 88
comptime H_ERROR = 96
comptime HOST_SIZE = 104

# Host callbacks: (state, ...), text as (address, length), out values in
# heap slots.
comptime CheckDeclaredFn = def(Int, Int, Int, Int) thin abi("C") -> Int32
comptime PinFn = def(Int, Int, Int, Int64, Int, Int, Int) thin abi("C") -> Int32
comptime FenceFn = def(Int) thin abi("C") -> Int32
comptime CommittedFn = def(Int, Int, Int, Int64, Int, Int) thin abi(
    "C"
) -> Int32
comptime SummaryFn = def(Int, Int, Int, Int) thin abi("C") -> Int
comptime SameRunFn = def(Int, Int, Int) thin abi("C") -> Int32
comptime MadeFn = def(Int, Int, Int, Int, Int) thin abi("C") -> Int32
comptime NameFn = def(Int, Int, Int) thin abi("C") -> Int32
comptime LogFn = def(Int, Int, Int) thin abi("C") -> None
comptime TextFn = def(Int, Int) thin abi("C") -> Int

# Scan modes (`Enc` of a scan's options, first field).
comptime SNAP_CURRENT: Int64 = -2
"""Scan the table's current snapshot."""
comptime SNAP_NONE: Int64 = -1
"""Scan nothing: the step pinned a table that had no snapshot."""

# Append modes.
comptime MODE_APPEND = 0
comptime MODE_REPLACE = 1
comptime MODE_BY_STEP = 2
"""Replace if the step declared the dataset in `replaces=`, else append."""


def get_int(block: Int, at: Int) -> Int:
    return Pointer[Int, MutUntrackedOrigin](unsafe_from_address=block + at)[]


def put_int(block: Int, at: Int, v: Int):
    Pointer[Int, MutUntrackedOrigin](unsafe_from_address=block + at)[] = v


def text_of(addr: Int, n: Int) -> String:
    """A copy of the `n` bytes at `addr`, as a String."""
    if n <= 0 or addr == 0:
        return String()
    var p = Pointer[UInt8, ImmUntrackedOrigin](unsafe_from_address=addr)
    var buf = List[UInt8](capacity=n)
    for i in range(n):
        buf.append(p[unsafe_offset=i])
    return String(unsafe_from_utf8=Span(buf))


def bytes_of(addr: Int, n: Int) -> List[UInt8]:
    """A copy of the `n` bytes at `addr`."""
    var buf = List[UInt8](capacity=max(n, 0))
    if n <= 0 or addr == 0:
        return buf^
    var p = Pointer[UInt8, ImmUntrackedOrigin](unsafe_from_address=addr)
    for i in range(n):
        buf.append(p[unsafe_offset=i])
    return buf^


def alloc_bytes(b: Span[UInt8, _]) -> Int:
    """`b` copied into memory of this side's allocator, NUL-terminated;
    freed with `free_text` on the same side."""
    var n = len(b)
    var p = unsafe_alloc[UInt8](n + 1)
    for i in range(n):
        p[unsafe_offset=i] = b[i]
    p[unsafe_offset=n] = 0
    return Int(p)


def free_text(addr: Int):
    if addr != 0:
        Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=addr
        ).unsafe_free()


def give(out_block: Int, b: Span[UInt8, _]):
    """Hands `b` to the other side through an out block."""
    put_int(out_block, 0, alloc_bytes(b))
    put_int(out_block, 8, len(b))


def give_text(out_block: Int, s: String):
    give(out_block, s.as_bytes())


struct Slots(Movable):
    """`n` 8-byte out-parameters on the heap, zeroed (see the module doc)."""

    var addr: Int
    var n: Int

    def __init__(out self, n: Int = 2):
        var p = unsafe_alloc[Int](n)
        for i in range(n):
            p[unsafe_offset=i] = 0
        self.addr = Int(p)
        self.n = n

    def __getitem__(self, i: Int) -> Int:
        return get_int(self.addr, 8 * i)

    def __deinit__(deinit self):
        Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=self.addr
        ).unsafe_free()


# ── the encoding ────────────────────────────────────────────────────────────


struct Enc(Movable, Sized):
    """Values written one after another (see the module doc)."""

    var buf: List[UInt8]

    def __init__(out self):
        self.buf = List[UInt8]()

    def int(mut self, v: Int64):
        var u = UInt64(v)
        for i in range(8):
            self.buf.append(UInt8((u >> UInt64(8 * i)) & 0xFF))

    def bool(mut self, v: Bool):
        self.int(Int64(1) if v else Int64(0))

    def bytes(mut self, b: Span[UInt8, _]):
        self.int(Int64(len(b)))
        self.buf.extend(b)

    def str(mut self, s: String):
        self.bytes(s.as_bytes())

    def strs(mut self, l: List[String]):
        self.int(Int64(len(l)))
        for s in l:
            self.str(s)

    def map(mut self, d: Dict[String, String]):
        self.int(Int64(len(d)))
        for e in d.items():
            self.str(e.key)
            self.str(e.value)

    def addr(self) -> Int:
        return Int(self.buf.unsafe_ptr())

    def take(deinit self) -> List[UInt8]:
        return self.buf^

    def __len__(self) -> Int:
        return len(self.buf)


struct Dec:
    """Reads what `Enc` wrote, from `n` bytes at `addr` (not copied: the
    bytes must outlive it)."""

    var addr: Int
    var n: Int
    var pos: Int

    def __init__(out self, addr: Int, n: Int):
        self.addr = addr
        self.n = n
        self.pos = 0

    def _need(self, k: Int) raises:
        if k < 0 or self.pos + k > self.n:
            raise Error(
                "lake: a buffer ended early (",
                k,
                " bytes at ",
                self.pos,
                " of ",
                self.n,
                ")",
            )

    def _at(self, i: Int) -> UInt8:
        return Pointer[UInt8, ImmUntrackedOrigin](
            unsafe_from_address=self.addr
        )[unsafe_offset=i]

    def int(mut self) raises -> Int64:
        self._need(8)
        var u: UInt64 = 0
        for i in range(8):
            u |= UInt64(self._at(self.pos + i)) << UInt64(8 * i)
        self.pos += 8
        return Int64(u)

    def bool(mut self) raises -> Bool:
        return self.int() != 0

    def bytes(mut self) raises -> List[UInt8]:
        var k = Int(self.int())
        self._need(k)
        var out = bytes_of(self.addr + self.pos, k)
        self.pos += k
        return out^

    def str(mut self) raises -> String:
        var k = Int(self.int())
        self._need(k)
        var s = text_of(self.addr + self.pos, k)
        self.pos += k
        return s^

    def strs(mut self) raises -> List[String]:
        var out = List[String]()
        for _ in range(Int(self.int())):
            out.append(self.str())
        return out^

    def map(mut self) raises -> Dict[String, String]:
        var d = Dict[String, String]()
        for _ in range(Int(self.int())):
            var k = self.str()
            d[k] = self.str()
        return d^

    def done(self) -> Bool:
        return self.pos >= self.n


def encode_map(d: Dict[String, String]) -> List[UInt8]:
    var e = Enc()
    e.map(d)
    return e^.take()


def decode_map(addr: Int, n: Int) -> Dict[String, String]:
    try:
        var d = Dec(addr, n)
        return d.map()
    except:
        return Dict[String, String]()
