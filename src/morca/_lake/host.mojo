"""The library's view of the step: the methods of `morca.Ctx` that the tables
code uses, each a call through the host block (`morca._lake.abi`). The
program fills the block (`morca._lakehost.HostBlock`)."""

from morca._lake.abi import (
    CheckDeclaredFn,
    CommittedFn,
    FenceFn,
    LogFn,
    MadeFn,
    NameFn,
    PinFn,
    SameRunFn,
    SummaryFn,
    TextFn,
    H_CHECK_DECLARED,
    H_COMMITS,
    H_COMMITTED,
    H_DECLARES_WRITE,
    H_ERROR,
    H_FENCE,
    H_LOG,
    H_MADE,
    H_PIN,
    H_REPLACES,
    H_SAME_RUN,
    H_STATE,
    H_SUMMARY,
    RawDec,
    Slots,
    decode_map,
    encode_map,
    get_int,
    text_of,
)


def _fn[FT: TrivialRegisterPassable](block: Int, at: Int) -> FT:
    var addr = get_int(block, at)
    return Pointer(to=addr).unsafe_bitcast[FT]()[]


@fieldwise_init
struct HostCommit(Copyable, Movable):
    """A commit the step made in this run, as `Ctx.commits` holds it."""

    var table: String
    var snapshot_id: Int64


struct Host(Copyable, Movable):
    """The host block at `block`; copies are views of the same block."""

    var block: Int

    def __init__(out self, block: Int):
        self.block = block

    def _state(self) -> Int:
        return get_int(self.block, H_STATE)

    def _error(self) -> Error:
        """The error the last callback that failed left in the host."""
        var n = Slots(1)
        var p = _fn[TextFn](self.block, H_ERROR)(self._state(), n.addr)
        return Error(text_of(p, n[0]))

    def check_declared(self, dataset: String, write: Bool) raises:
        var f = _fn[CheckDeclaredFn](self.block, H_CHECK_DECLARED)
        var rc = f(
            self._state(),
            Int(dataset.unsafe_ptr()),
            dataset.byte_length(),
            1 if write else 0,
        )
        if rc != 0:
            raise self._error()

    def declares_write(self, dataset: String) -> Bool:
        var f = _fn[NameFn](self.block, H_DECLARES_WRITE)
        return (
            f(self._state(), Int(dataset.unsafe_ptr()), dataset.byte_length())
            != 0
        )

    def replaces(self, dataset: String) -> Bool:
        var f = _fn[NameFn](self.block, H_REPLACES)
        return (
            f(self._state(), Int(dataset.unsafe_ptr()), dataset.byte_length())
            != 0
        )

    def pin(
        self, table: String, current: Int64, dataset: String = ""
    ) raises -> Int64:
        var out = Slots(1)
        var f = _fn[PinFn](self.block, H_PIN)
        var rc = f(
            self._state(),
            Int(table.unsafe_ptr()),
            table.byte_length(),
            current,
            Int(dataset.unsafe_ptr()),
            dataset.byte_length(),
            out.addr,
        )
        if rc != 0:
            raise self._error()
        return Int64(out[0])

    def fence(self) raises:
        if _fn[FenceFn](self.block, H_FENCE)(self._state()) != 0:
            raise self._error()

    def committed(
        self, table: String, snapshot_id: Int64, dataset: String = ""
    ) raises:
        var f = _fn[CommittedFn](self.block, H_COMMITTED)
        var rc = f(
            self._state(),
            Int(table.unsafe_ptr()),
            table.byte_length(),
            snapshot_id,
            Int(dataset.unsafe_ptr()),
            dataset.byte_length(),
        )
        if rc != 0:
            raise self._error()

    def summary(self, table: String) -> Dict[String, String]:
        var n = Slots(1)
        var f = _fn[SummaryFn](self.block, H_SUMMARY)
        var p = f(
            self._state(), Int(table.unsafe_ptr()), table.byte_length(), n.addr
        )
        return decode_map(p, n[0])

    def same_run(self, summary: Dict[String, String]) -> Bool:
        return self._same_run(encode_map(summary))

    def _same_run(self, s: List[UInt8]) -> Bool:
        """`s` is borrowed for the call, so it outlives the callback that
        reads it through its address."""
        var f = _fn[SameRunFn](self.block, H_SAME_RUN)
        return f(self._state(), Int(s.unsafe_ptr()), len(s)) != 0

    def made(self, table: String, summary: Dict[String, String]) -> Bool:
        return self._made(table, encode_map(summary))

    def _made(self, table: String, s: List[UInt8]) -> Bool:
        var f = _fn[MadeFn](self.block, H_MADE)
        return (
            f(
                self._state(),
                Int(table.unsafe_ptr()),
                table.byte_length(),
                Int(s.unsafe_ptr()),
                len(s),
            )
            != 0
        )

    def log(self, msg: String):
        _fn[LogFn](self.block, H_LOG)(
            self._state(), Int(msg.unsafe_ptr()), msg.byte_length()
        )

    def commits(self) -> List[HostCommit]:
        var n = Slots(1)
        var p = _fn[TextFn](self.block, H_COMMITS)(self._state(), n.addr)
        var out = List[HostCommit]()
        try:
            var d = RawDec(p, n[0])
            for _ in range(Int(d.int())):
                var t = d.str()
                out.append(HostCommit(t^, d.int()))
        except:
            pass
        return out^
