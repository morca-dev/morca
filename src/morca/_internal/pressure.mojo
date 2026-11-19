"""Memory pressure (#202): Linux's pressure stall information (PSI) for
memory, read each tick, and the admission rule built on it.

    some avg10=1.53 avg60=0.87 avg300=0.24 total=1234567
    full avg10=0.00 avg60=0.12 avg300=0.03 total=34567

`some` is the share of the last 10, 60 and 300 seconds in which at least
one task was stalled waiting for memory (reclaim, swap-in, refaults);
`full` the share in which every runnable task was. Meta's TMO acts on the
same signal before memory runs out (Weiner et al., ASPLOS 2022).

**Which file** (`find_source`, once per process):

1. `MORCA_MEMORY_PRESSURE_FILE`, if set: that file, whatever it is (tests
   point it at a fixture);
2. on Linux, the cgroup v2 `memory.pressure` of the nearest cgroup, from
   this process's own up, whose `memory.max` is a limit: in a Docker
   container run with `--memory` that's the container's own
   (`/sys/fs/cgroup/memory.pressure`), which stalls when the container
   reaches its limit even with the host at ease;
3. the host's `/proc/pressure/memory`. Inside a container it is the host's
   (PSI isn't namespaced), which is what a container without a limit
   shares;
4. the own cgroup's `memory.pressure` though it has no limit, for a kernel
   with cgroup PSI but no readable `/proc/pressure`;
5. none: macOS, or a kernel built or booted without PSI (`psi=0`). Then
   nothing is held, and the scheduler says so once.

**Admission** (`Admission`): while `some avg10`, less what runs held at
their own memory limits explain (the most of their cgroups' `some avg10`),
is over the limit
(`MORCA_ADMIT_MEMORY_PRESSURE`, percent, default 10; 0 turns it off), no new
run starts on this host; runs already going go on. The hold ends once
`avg10` is under half the limit, or has stayed at most the limit for
`RESUME_SECONDS`, so a reading that hovers at the limit doesn't flap. A
hold that has lasted `MORCA_ADMIT_PRESSURE_GRACE_SECONDS` (600) with none of
morca's runs going on this host lets one run start at a time (`escape`): the
pressure isn't morca's, and morca shouldn't wait for it forever. The caller
logs and alerts once when that happens (`stuck`).

This module reads files and decides; it keeps nothing in a database, so a
step (`memory_pressure`, from `MORCA_MEMORY_PRESSURE_FILE`, which every run
on the local runner, the control host and a worker is given) and the
per-run cgroups of #201 can use it alone.
"""

from std.os import getenv
from std.os.path import exists
from std.sys.info import CompilationTarget

comptime PRESSURE_FILE = "MORCA_MEMORY_PRESSURE_FILE"
"""The file a run polls for its host's memory pressure, and the scheduler's
override of which file it reads."""
comptime ADMIT_LIMIT = "MORCA_ADMIT_MEMORY_PRESSURE"
"""The `some avg10` percent over which no new run starts; 0 turns it off."""
comptime DEFAULT_LIMIT: Float64 = 10.0
comptime GRACE = "MORCA_ADMIT_PRESSURE_GRACE_SECONDS"
comptime DEFAULT_GRACE: Float64 = 600.0
comptime RESUME_SECONDS: Float64 = 30.0
"""How long `avg10` stays at most the limit before a hold ends anyway."""
comptime WAITING_PRESSURE = "waiting: memory pressure "
"""How a run held by memory pressure's reason starts."""
comptime HOST_PSI = "/proc/pressure/memory"
comptime CGROUP_ROOT = "/sys/fs/cgroup"


def _read(path: String) -> String:
    try:
        with open(path, "r") as f:
            return f.read()
    except:
        return ""


# ---------------------------------------------------------------------------
# Parsing (pure)
# ---------------------------------------------------------------------------


@fieldwise_init
struct Stall(ImplicitlyCopyable, Movable, Writable):
    """One line of a PSI file: the percent of time stalled, averaged over
    10, 60 and 300 seconds, and the total stalled, in microseconds."""

    var avg10: Float64
    var avg60: Float64
    var avg300: Float64
    var total: Int

    @staticmethod
    def zero() -> Stall:
        return Stall(0.0, 0.0, 0.0, 0)


@fieldwise_init
struct Psi(ImplicitlyCopyable, Movable, Writable):
    """A PSI file's `some` and `full` lines; `has_full` is False for a file
    without one (`/proc/pressure/cpu` before 5.13, or a fixture)."""

    var some: Stall
    var full: Stall
    var has_full: Bool


def _stall_of(words: List[String], line: String) raises -> Stall:
    var s = Stall.zero()
    var seen = 0
    for i in range(1, len(words)):
        ref w = words[i]
        var eq = w.find("=").or_else(-1)
        if eq < 0:
            raise Error("not a PSI line: ", line)
        var key = String(w[byte=:eq])
        var val = String(w[byte = eq + 1 :])
        try:
            if key == "avg10":
                s.avg10 = Float64(val)
                seen += 1
            elif key == "avg60":
                s.avg60 = Float64(val)
                seen += 1
            elif key == "avg300":
                s.avg300 = Float64(val)
                seen += 1
            elif key == "total":
                s.total = Int(val)
        except:
            raise Error("not a PSI line: ", line)
    if seen < 3:
        raise Error("not a PSI line: ", line)
    return s


def parse_psi(text: String) raises -> Psi:
    """A PSI file's text; raises without a `some` line, or on a line that
    isn't `some|full avg10=.. avg60=.. avg300=.. total=..`."""
    var p = Psi(Stall.zero(), Stall.zero(), False)
    var has_some = False
    for raw in text.split("\n"):
        var line = String(raw.strip())
        if not line:
            continue
        var words = List[String]()
        for w in line.split():
            words.append(String(w))
        var kind = words[0]
        if kind == "some":
            p.some = _stall_of(words, line)
            has_some = True
        elif kind == "full":
            p.full = _stall_of(words, line)
            p.has_full = True
        else:
            raise Error("not a PSI line: ", line)
    if not has_some:
        raise Error("no `some` line in the PSI file")
    return p


def read_psi(path: String) -> Optional[Psi]:
    """The PSI file at `path`, or None if it can't be read or parsed (no
    file, PSI off in the kernel, a fixture half written)."""
    if not path:
        return None
    var text = _read(path)
    if not text:
        return None
    try:
        return parse_psi(text)
    except:
        return None


def memory_pressure() -> Optional[Psi]:
    """This run's host's memory pressure, from the file
    `MORCA_MEMORY_PRESSURE_FILE` names (which morca gives every run it
    starts where there is one), or None. A step can poll it and lower its
    own parallelism while `some.avg10` is high."""
    return read_psi(getenv(PRESSURE_FILE))


# ---------------------------------------------------------------------------
# Which file
# ---------------------------------------------------------------------------


@fieldwise_init
struct Source(Boolable, Copyable, Movable, Writable):
    """The PSI file a host's memory pressure is read from: `kind` is
    `file` (`MORCA_MEMORY_PRESSURE_FILE`), `cgroup` (a cgroup with a memory
    limit), `host` (`/proc/pressure/memory`), `cgroup-unlimited`, or empty
    with no `path` for none."""

    var path: String
    var kind: String
    var limit_bytes: Int
    """The cgroup's `memory.max` for `cgroup`; else 0."""

    @staticmethod
    def none() -> Source:
        return Source(String(), String(), 0)

    def __bool__(self) -> Bool:
        return self.path.byte_length() > 0

    def describe(self) -> String:
        """In words, for a log line and Ops › Control."""
        if self.kind == "file":
            return String(self.path, " (", PRESSURE_FILE, ")")
        if self.kind == "cgroup":
            return String(
                self.path,
                " (this cgroup's, limited to ",
                self.limit_bytes // (1024 * 1024),
                " MB)",
            )
        if self.kind == "host":
            return String(self.path, " (the host's)")
        if self.kind == "cgroup-unlimited":
            return String(self.path, " (this cgroup's, with no limit)")
        return "none: no PSI here (macOS, or a kernel without it)"


def own_cgroup(proc_self_cgroup: String) -> String:
    """The cgroup v2 path in `/proc/self/cgroup`'s text (`0::/path`), or
    empty for none (cgroup v1 only)."""
    for raw in proc_self_cgroup.split("\n"):
        var line = String(raw.strip())
        if line.startswith("0::"):
            return String(line[byte=3:])
    return ""


def _limit_of(text: String) -> Int:
    """A `memory.max`'s bytes, or 0 for `max`, none or junk."""
    var t = String(text.strip())
    if not t or t == "max":
        return 0
    try:
        return max(Int(t), 0)
    except:
        return 0


def pick_source(
    override: String,
    cgroup_dirs: List[String],
    limits: List[Int],
    has_pressure: List[Bool],
    host_ok: Bool,
) -> Source:
    """The choice `find_source` makes, from what it found: `override`
    (`MORCA_MEMORY_PRESSURE_FILE`), the cgroup directories from this
    process's own up to the root of the mount, each one's `memory.max` in
    bytes (0 for none) and whether it has a readable `memory.pressure`, and
    whether `/proc/pressure/memory` reads."""
    if override:
        return Source(override, "file", 0)
    for i in range(len(cgroup_dirs)):
        if limits[i] > 0 and has_pressure[i]:
            return Source(
                String(cgroup_dirs[i], "/memory.pressure"), "cgroup", limits[i]
            )
    if host_ok:
        return Source(HOST_PSI, "host", 0)
    if len(cgroup_dirs) > 0 and has_pressure[0]:
        return Source(
            String(cgroup_dirs[0], "/memory.pressure"), "cgroup-unlimited", 0
        )
    return Source.none()


def cgroup_dirs(rel: String, root: String = CGROUP_ROOT) -> List[String]:
    """The directories under `root` of cgroup `rel` and its parents, own
    first, to `root` itself. With a private cgroup namespace (Docker's
    default on cgroup v2) `rel` is `/` and `root` is the container's
    cgroup."""
    var out = List[String]()
    var r = String(rel.strip().rstrip("/"))
    while r:
        out.append(String(root, r))
        var slash = r.rfind("/").or_else(-1)
        if slash <= 0:
            break
        var parent = String(r[byte=:slash])
        r = parent^
    out.append(String(root))
    return out^


def find_source() -> Source:
    """Where this host's memory pressure is read from; see the module's
    docs. Reads files, so it's called once."""
    var override = getenv(PRESSURE_FILE)
    var dirs = List[String]()
    var limits = List[Int]()
    var has = List[Bool]()
    var host_ok = False
    comptime if CompilationTarget.is_linux():
        if not override:
            var rel = own_cgroup(_read("/proc/self/cgroup"))
            if rel:
                var candidates = cgroup_dirs(rel)
                for d in candidates:
                    # A path from the host's view, which a private
                    # namespace doesn't have, is skipped: its root is
                    # still there.
                    if not exists(d):
                        continue
                    dirs.append(d)
                    limits.append(_limit_of(_read(String(d, "/memory.max"))))
                    has.append(
                        read_psi(String(d, "/memory.pressure")).__bool__()
                    )
            host_ok = read_psi(HOST_PSI).__bool__()
    return pick_source(override, dirs, limits, has, host_ok)


# ---------------------------------------------------------------------------
# Admission (pure)
# ---------------------------------------------------------------------------


def pct_text(x: Float64) -> String:
    """A percent for a reason: whole from 10, else to a tenth without a
    trailing `.0`: `23`, `7.5`, `0`."""
    if x >= 10.0:
        return String(Int(x + 0.5))
    var tenths = Int(max(x, 0.0) * 10.0 + 0.5)
    if tenths % 10 == 0:
        return String(tenths // 10)
    return String(tenths // 10, ".", tenths % 10)


def admit_limit() -> Float64:
    """`MORCA_ADMIT_MEMORY_PRESSURE`, percent; 10 when unset, and 0 (off)
    for a value that isn't a number from 0."""
    var v = getenv(ADMIT_LIMIT)
    if not v:
        return DEFAULT_LIMIT
    try:
        var x = Float64(v)
        if x >= 0.0:
            return x
    except:
        pass
    print("morca:", ADMIT_LIMIT, "is a percent from 0, not", v, "- off")
    return 0.0


def grace_seconds() -> Float64:
    var v = getenv(GRACE)
    if not v:
        return DEFAULT_GRACE
    try:
        return max(Float64(v), 0.0)
    except:
        return DEFAULT_GRACE


struct Admission(Copyable, Movable):
    """Whether this host starts new runs, from each reading of its memory
    pressure (`observe`), with hysteresis. Times are seconds on any clock
    that only goes forward."""

    var limit: Float64
    """`some avg10` percent over which runs wait; 0 for off."""
    var grace: Float64
    """How long a hold lasts, with none of morca's runs going, before one
    may start anyway."""
    var holding: Bool
    var held_since: Float64
    var calm_since: Float64
    """While holding, when `avg10` came to at most the limit; -1 if it
    isn't."""
    var reading: Optional[Psi]
    """The newest reading; None without one."""
    var hold: String
    """While holding: the reason a run waits (`WAITING_PRESSURE`...); else
    empty."""
    var escape: Bool
    """Holding past `grace` with nothing of morca's going: one run may
    start while none is."""
    var stuck: Bool
    """`escape` became true at this reading: log it and alert, once a
    hold."""
    var released: Bool
    """A hold ended at this reading."""

    def __init__(out self, limit: Float64, grace: Float64 = DEFAULT_GRACE):
        self.limit = limit
        self.grace = grace
        self.holding = False
        self.held_since = 0.0
        self.calm_since = -1.0
        self.reading = None
        self.hold = String()
        self.escape = False
        self.stuck = False
        self.released = False

    @staticmethod
    def from_env() -> Admission:
        return Admission(admit_limit(), grace_seconds())

    def observe(
        mut self,
        psi: Optional[Psi],
        now: Float64,
        idle: Bool,
        own: Float64 = 0.0,
    ):
        """Takes a reading (None: none could be read, which holds nothing),
        at `now`, with `idle` whether none of morca's runs is going on this
        host. `own` is the part of `some avg10` that runs held at their own
        memory limits explain (`morca._internal.cgroup.own_limit_pressure`), which
        holds nothing: the host may have memory to spare, and such a run is
        killed and retried bigger in its own time."""
        self.reading = psi
        self.stuck = False
        self.released = False
        var was = self.holding
        if self.limit <= 0.0 or not psi:
            self.holding = False
        else:
            var avg = max(psi.value().some.avg10 - own, 0.0)
            if not self.holding:
                if avg > self.limit:
                    self.holding = True
                    self.held_since = now
                    self.calm_since = -1.0
            elif avg < self.limit / 2.0:
                self.holding = False
            elif avg <= self.limit:
                if self.calm_since < 0.0:
                    self.calm_since = now
                elif now - self.calm_since >= RESUME_SECONDS:
                    self.holding = False
            else:
                self.calm_since = -1.0
        if not self.holding:
            self.hold = String()
            self.calm_since = -1.0
            self.escape = False
            self.released = was
            return
        var avg = max(psi.value().some.avg10 - own, 0.0)
        self.hold = String(
            WAITING_PRESSURE,
            pct_text(avg),
            "%, easing" if avg <= self.limit else "%",
            " (limit ",
            pct_text(self.limit),
            "%)",
        )
        var past = idle and now - self.held_since >= self.grace
        if past and not self.escape:
            self.stuck = True
        # Once past the grace a hold stays escapable while it lasts: a run
        # that started under it doesn't make the next wait the grace again.
        self.escape = self.escape or past

    def held(self) -> Bool:
        return self.holding

    def allows(self, idle: Bool) -> Int:
        """How many starts this host may make now: none while holding, but
        one while `escape` and `idle`; -1 for no limit from pressure."""
        if not self.holding:
            return -1
        if self.escape and idle:
            return 1
        return 0


def pressure_env(s: Source) -> List[String]:
    """`MORCA_MEMORY_PRESSURE_FILE=<path>` for a run's process, so a step can
    poll its host's pressure (`memory_pressure`); nothing without one."""
    var out = List[String]()
    if s:
        out.append(String(PRESSURE_FILE, "=", s.path))
    return out^
