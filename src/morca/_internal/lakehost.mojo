"""The host block over a step's `Ctx`: how liblake reaches the step from
inside a call (`morca._lake.abi` lays the block out, and the library's
`morca._lake.host.Host` calls it). It lives on the program's side, above
`morca._lake`, which knows no `Ctx`.
"""

from std.memory.alloc import unsafe_alloc

from morca.ctx import Ctx
from morca._lake.abi import (
    HOST_SIZE,
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
    CheckDeclaredFn,
    CommittedFn,
    Enc,
    FenceFn,
    LogFn,
    MadeFn,
    NameFn,
    PinFn,
    SameRunFn,
    SummaryFn,
    TextFn,
    decode_map,
    put_int,
    text_of,
)


struct _HostState(Movable):
    var ctx: Int
    var scratch: List[UInt8]
    var err: String

    def __init__(out self, ctx: Int):
        self.ctx = ctx
        self.scratch = List[UInt8]()
        self.err = String()


def _st(state: Int) -> Pointer[_HostState, MutAnyOrigin]:
    return Pointer[_HostState, MutAnyOrigin](unsafe_from_address=state)


def _ctx(state: Int) -> Pointer[Ctx, MutAnyOrigin]:
    return Pointer[Ctx, MutAnyOrigin](unsafe_from_address=_st(state)[].ctx)


def _hand(state: Int, var b: List[UInt8], out_n: Int) -> Int:
    """`b` kept in the host until its next callback, its address returned."""
    ref s = _st(state)[]
    s.scratch = b^
    put_int(out_n, 0, len(s.scratch))
    return Int(s.scratch.unsafe_ptr())


def _on_check_declared(
    state: Int, ds: Int, n: Int, write: Int
) abi("C") -> Int32:
    try:
        _ctx(state)[].check_declared(text_of(ds, n), write=write != 0)
        return 0
    except e:
        _st(state)[].err = String(e)
        return 1


def _on_pin(
    state: Int, loc: Int, n: Int, current: Int64, ds: Int, dn: Int, out_id: Int
) abi("C") -> Int32:
    try:
        var id = _ctx(state)[].pin(text_of(loc, n), current, text_of(ds, dn))
        put_int(out_id, 0, Int(id))
        return 0
    except e:
        _st(state)[].err = String(e)
        return 1


def _on_fence(state: Int) abi("C") -> Int32:
    try:
        _ctx(state)[].fence()
        return 0
    except e:
        _st(state)[].err = String(e)
        return 1


def _on_committed(
    state: Int, loc: Int, n: Int, id: Int64, ds: Int, dn: Int
) abi("C") -> Int32:
    try:
        _ctx(state)[].committed(text_of(loc, n), id, text_of(ds, dn))
        return 0
    except e:
        _st(state)[].err = String(e)
        return 1


def _on_summary(state: Int, loc: Int, n: Int, out_n: Int) abi("C") -> Int:
    var e = Enc()
    e.map(_ctx(state)[].summary(text_of(loc, n)))
    return _hand(state, e^.take(), out_n)


def _on_same_run(state: Int, t: Int, n: Int) abi("C") -> Int32:
    return 1 if _ctx(state)[].same_run(decode_map(t, n)) else 0


def _on_made(state: Int, loc: Int, n: Int, t: Int, tn: Int) abi("C") -> Int32:
    return 1 if _ctx(state)[].made(text_of(loc, n), decode_map(t, tn)) else 0


def _on_replaces(state: Int, ds: Int, n: Int) abi("C") -> Int32:
    return 1 if _ctx(state)[].replaces(text_of(ds, n)) else 0


def _on_declares_write(state: Int, ds: Int, n: Int) abi("C") -> Int32:
    return 1 if text_of(ds, n) in _ctx(state)[].declared_writes else 0


def _on_log(state: Int, msg: Int, n: Int) abi("C") -> None:
    _ctx(state)[].log(text_of(msg, n))


def _on_commits(state: Int, out_n: Int) abi("C") -> Int:
    var e = Enc()
    ref commits = _ctx(state)[].commits
    e.int(Int64(len(commits)))
    for c in commits:
        e.str(c.table)
        e.int(c.snapshot_id)
    return _hand(state, e^.take(), out_n)


def _on_error(state: Int, out_n: Int) abi("C") -> Int:
    ref s = _st(state)[]
    put_int(out_n, 0, s.err.byte_length())
    return Int(s.err.unsafe_ptr())


def _put_fn[FT: TrivialRegisterPassable](block: Int, at: Int, f: FT):
    Pointer[FT, MutUntrackedOrigin](unsafe_from_address=block + at)[] = f


struct HostBlock(Movable):
    """The host block for one call into the library, over `ctx`, whose
    address it keeps: the `Ctx` must outlive it, which a block made and
    dropped around one call does."""

    var addr: Int
    var state: Int

    def __init__(out self, ctx: Ctx):
        var st = unsafe_alloc[_HostState](1)
        st.unsafe_write(_HostState(Int(Pointer(to=ctx))))
        self.state = Int(st)
        self.addr = Int(unsafe_alloc[Int](HOST_SIZE // 8))
        var h = self.addr
        put_int(h, H_STATE, self.state)
        _put_fn[CheckDeclaredFn](h, H_CHECK_DECLARED, _on_check_declared)
        _put_fn[PinFn](h, H_PIN, _on_pin)
        _put_fn[FenceFn](h, H_FENCE, _on_fence)
        _put_fn[CommittedFn](h, H_COMMITTED, _on_committed)
        _put_fn[SummaryFn](h, H_SUMMARY, _on_summary)
        _put_fn[SameRunFn](h, H_SAME_RUN, _on_same_run)
        _put_fn[MadeFn](h, H_MADE, _on_made)
        _put_fn[NameFn](h, H_REPLACES, _on_replaces)
        _put_fn[NameFn](h, H_DECLARES_WRITE, _on_declares_write)
        _put_fn[LogFn](h, H_LOG, _on_log)
        _put_fn[TextFn](h, H_COMMITS, _on_commits)
        _put_fn[TextFn](h, H_ERROR, _on_error)

    def __deinit__(deinit self):
        var st = Pointer[_HostState, MutUntrackedOrigin](
            unsafe_from_address=self.state
        )
        st.unsafe_deinit_pointee()
        st.unsafe_free()
        Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=self.addr
        ).unsafe_free()
