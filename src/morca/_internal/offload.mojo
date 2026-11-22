"""Offload (#282): how much of a run's memory went to swap.

With `MORCA_RUN_SWAP_PCT` over 0 (`morca._internal.cgroup`), a run's cgroup
may hold that percent of its limit in swap (`memory.swap.max`), so a run a
little past its limit pushes its coldest pages out, to zswap's compressed
pool first where the host has it on, rather than being held at
`memory.high`. What it offloaded is kept per attempt, beside its peak and
stall time, so a grant that fit with offload can be told from one that
fit:

- `memory_swap_peak_bytes`: the most of its memory in swap at once, the
  cgroup's `memory.swap.current` sampled each tick, and at the reap
  `memory.swap.peak` where the kernel has it (6.5 and later);
- `memory_zswapped_peak_bytes`: the most of that in zswap at once,
  `memory.stat`'s `zswapped` (uncompressed bytes) sampled each tick; -1
  (null) where the kernel has no zswap.

Both are -1 (null) with `MORCA_RUN_SWAP_PCT` 0: nothing is sampled then.
A learned request counts the swap peak on top of the memory peak
(`morca._internal.db.recommend`), so offload never shrinks one.
"""

from morca._internal.cgroup import Contained
from morca._internal.sample import _read


@fieldwise_init
struct Offload(ImplicitlyCopyable, Movable):
    """A run's offload peaks, in bytes; -1 for unknown."""

    var swap_bytes: Int
    var zswapped_bytes: Int

    @staticmethod
    def none() -> Offload:
        return Offload(-1, -1)

    def merge(self, other: Offload) -> Offload:
        """The larger of each."""
        return Offload(
            max(self.swap_bytes, other.swap_bytes),
            max(self.zswapped_bytes, other.zswapped_bytes),
        )


def stat_value(text: String, name: String) -> Int:
    """The value `name` in a `memory.stat` file's `key value` lines; -1
    without it."""
    for line in text.splitlines():
        var words = line.split()
        if len(words) == 2 and String(words[0]) == name:
            try:
                return Int(String(words[1]))
            except:
                return -1
    return -1


def _bytes_file(path: String) -> Int:
    var t = String(_read(path).strip())
    if not t:
        return -1
    try:
        return Int(t)
    except:
        return -1


def offload_now(path: String) -> Offload:
    """The cgroup's swap (`memory.swap.current`) and zswapped memory
    (`memory.stat`) now."""
    return Offload(
        _bytes_file(String(path, "/memory.swap.current")),
        stat_value(_read(String(path, "/memory.stat")), "zswapped"),
    )


struct OffloadWatch(Copyable, Movable):
    """The offload peaks of each contained run so far, by its process: the
    scheduler's runs and a worker's alike."""

    var peaks: Dict[Int, Offload]

    def __init__(out self):
        self.peaks = Dict[Int, Offload]()

    def sample(mut self, contained: Dict[Int, Contained], swap_pct: Int):
        """Each of `contained`'s offload now, into its peaks; nothing with
        `swap_pct` 0, when no run may offload."""
        if swap_pct <= 0:
            return
        var gone = List[Int]()
        for e in self.peaks.items():
            if e.key not in contained:
                gone.append(e.key)
        for pid in gone:
            _ = self.peaks.pop(pid, Offload.none())
        for e in contained.items():
            if not e.value.path:
                continue
            var now = offload_now(e.value.path)
            self.peaks[e.key] = self.peaks.get(e.key, Offload.none()).merge(now)

    def take(mut self, pid: Int, path: String, swap_pct: Int) -> Offload:
        """At the reap, `pid`'s peaks, with what its cgroup (`path`) says
        now and, where the kernel keeps it, its `memory.swap.peak`; forgets
        it. Unknown (-1) with `swap_pct` 0."""
        var p = self.peaks.pop(pid, Offload.none())
        if swap_pct <= 0 or not path:
            return Offload.none()
        var peak = Offload(_bytes_file(String(path, "/memory.swap.peak")), -1)
        return p.merge(offload_now(path)).merge(peak)
