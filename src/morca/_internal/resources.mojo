"""Resource requests and grants (#171): runs sized to their share of the
machine.

    [pipelines.gharchive]
    cpus = "1..16"           # or a count, 4: MIN = MAX
    memory_gb = "2..24"      # GB, decimals allowed: "0.5..2"
    # or "auto", "auto..24": learned from its runs (morca.recommend)

**Requests.** A pipeline asks for a range of CPUs and memory in morca.toml
(`[defaults]` or its own table) or with `morca register --cpus` and
`--memory-gb`. Either can be left out. A pipeline with neither is started
as before: no admission check, no grant.

**Admission.** On the local runner and for control-placed runs, the
scheduler starts a run of a pipeline with a request only if its minimum
fits in what this host's running runs haven't been granted: the host's
CPUs and memory (`host_capacity`: cgroup limits if set, else
`/proc/meminfo` and the cores; `sysctl` on macOS; `MORCA_HOST_CPUS` and
`MORCA_HOST_MEMORY_MB` override both), less a reserve for the scheduler,
Postgres and the UI (`MORCA_RESERVE_CPUS`, 1, and `MORCA_RESERVE_MEMORY_MB`,
1536), less the grants of the runs going there. Otherwise the run waits,
queued, `held` with why (`WAITING`...): "waiting: needs 2 GB, 1.3 GB free of
grants". Runs without a request take no part: they're neither checked nor
counted. `max_runs` and `fill_max_runs` stay as caps on top; with
`max_runs = "auto"` (#266) the grants alone decide how many run at once, up
to its ceiling, and a pipeline with no request to weigh starts one at a time.

**Grants.** A run that starts gets up to its maximum from what's left,
fixed for that start's life, in `MORCA_GRANT_CPUS` and
`MORCA_GRANT_MEMORY_MB`, and recorded on the run (`orca.runs.grant_cpus`,
`grant_memory_mb`, with the request it had). A remote worker (`morca
worker`) admits the runs it takes the same way against its own host, with
the same variables (its reserve defaults to 0 CPUs and 512 MB).

**Learned requests.** `cpus` and `memory_gb` may be `auto`, or have `auto`
as a range's lower end (`"auto..24"`): what the pipeline's runs suggest
(`morca._internal.recommend`), at most the range's maximum, resolved each time a run
starts (`resolve_request`); without one, no request of that resource.
`Request.of` reads `auto` as `cpus_auto` or `memory_auto` with a minimum of
0 and the maximum given (0 for none).

**`"auto"` in `env`.** An `env` value `"auto"` is passed to the run as it
is, for the pipeline to size itself from the grant (`auto_count`).
`DISTA_WORKER_SLOTS = "auto"` too: dista (0.5.0 on) sizes each worker from
`MORCA_GRANT_*`, dividing the grant among a local run's workers, and
without a grant takes a slot per core.

**GPUs** (docs/groups.md). A worker counts its host's GPUs once at start
(`host_gpus`) and says how many with each claim. A request's `gpus` are
whole and granted exactly, never as a range; admission decides how many a
start holds, and the worker picks which free devices (`Gpus`) and passes
them as `MORCA_GRANT_GPUS` and `CUDA_VISIBLE_DEVICES`. Only a group asks
for GPUs (`morca._internal.groups`), so until members by group land no
run's request does.
"""

from std.os import getenv
from std.sys.info import CompilationTarget, num_logical_cores

from morca._internal.proc import capture
from morca._internal.sample import _read, _sysctl_u64, parse_meminfo

comptime MAX_CPUS = 1024
comptime MAX_MEMORY_GB = 65536.0
comptime WAITING = "waiting: needs "
"""How a run held by admission's reason starts."""

comptime GRANT_CPUS = "MORCA_GRANT_CPUS"
comptime GRANT_MEMORY_MB = "MORCA_GRANT_MEMORY_MB"
comptime GRANT_GPUS = "MORCA_GRANT_GPUS"
comptime CUDA_DEVICES = "CUDA_VISIBLE_DEVICES"
comptime HOST_GPUS = "MORCA_HOST_GPUS"
comptime GPU_COUNT_SECONDS = 10.0
"""How long `host_gpus` waits for `nvidia-smi`."""
comptime AUTO = "auto"


def _auto_max(v: String) -> Tuple[Bool, String]:
    """Whether `v` is `auto` or `auto..MAX`, and its `MAX` (empty for
    none)."""
    if v == AUTO:
        return (True, String())
    if v.startswith("auto.."):
        var hi = String(v[byte = String("auto..").byte_length() :])
        return (True, hi if hi else String("none"))
    return (False, v)


def parse_cpus(v: String) raises -> Tuple[Int, Int]:
    """`cpus`' value, `N` or `MIN..MAX`: whole CPUs from 1 to 1024. `auto`
    is (0, 0) and `auto..MAX` (0, MAX), learned (`morca._internal.recommend`).
    """
    var a = _auto_max(v)
    if a[0]:
        if not a[1]:
            return (0, 0)
        var hi = 0
        try:
            hi = Int(a[1])
        except:
            pass
        if hi < 1 or hi > MAX_CPUS:
            raise Error(
                "is CPUs, auto..MAX with MAX from 1 to ", MAX_CPUS, ", not ", v
            )
        return (0, hi)
    if v.endswith("..auto"):
        raise Error("is CPUs with auto as a range's lower end only, not ", v)
    var lo: Int
    var hi: Int
    try:
        var dots = v.find("..").or_else(-1)
        if dots >= 0:
            lo = Int(v[byte=:dots])
            hi = Int(v[byte = dots + 2 :])
        else:
            lo = Int(v)
            hi = lo
    except:
        raise Error("is CPUs, N, MIN..MAX, auto or auto..MAX, not ", v)
    if lo < 1 or hi > MAX_CPUS or hi < lo:
        raise Error(
            "is CPUs from 1 to ",
            MAX_CPUS,
            ", MIN..MAX with MIN <= MAX, not ",
            v,
        )
    return (lo, hi)


def parse_workers(v: String) raises -> Tuple[Int, Int]:
    """`--workers`' value, `N` or `MIN..MAX`: the fewest (-1 for a fixed
    count) and the most."""
    try:
        var dots = v.find("..").or_else(-1)
        if dots >= 0:
            var lo = Int(v[byte=:dots])
            var hi = Int(v[byte = dots + 2 :])
            if lo >= 0 and hi >= max(lo, 1):
                return (lo, hi)
        else:
            var n = Int(v)
            if n >= 1:
                return (-1, n)
    except:
        pass
    raise Error("not a count or a range MIN..MAX: ", v)


def _mb_of_gb(gb: Float64) -> Int:
    return Int(gb * 1024.0 + 0.5)


def parse_memory_gb(v: String) raises -> Tuple[Int, Int]:
    """`memory_gb`'s value, `N` or `MIN..MAX` in GB (decimals allowed), as
    MB: more than 0 and at most 65536 GB. `auto` is (0, 0) and `auto..MAX`
    (0, MAX), learned (`morca._internal.recommend`)."""
    var a = _auto_max(v)
    if a[0]:
        if not a[1]:
            return (0, 0)
        var hi = 0.0
        try:
            hi = Float64(a[1])
        except:
            pass
        if not (hi > 0.0 and hi <= MAX_MEMORY_GB) or _mb_of_gb(hi) < 1:
            raise Error(
                "is GB, auto..MAX with MAX over 0 and up to 65536, not ", v
            )
        return (0, _mb_of_gb(hi))
    if v.endswith("..auto"):
        raise Error("is GB with auto as a range's lower end only, not ", v)
    var lo: Float64
    var hi: Float64
    try:
        var dots = v.find("..").or_else(-1)
        if dots >= 0:
            lo = Float64(String(v[byte=:dots]))
            hi = Float64(String(v[byte = dots + 2 :]))
        else:
            lo = Float64(v)
            hi = lo
    except:
        raise Error("is GB, N, MIN..MAX, auto or auto..MAX, not ", v)
    if not (lo > 0.0 and hi <= MAX_MEMORY_GB and hi >= lo) or _mb_of_gb(lo) < 1:
        raise Error(
            "is GB over 0 and up to 65536, MIN..MAX with MIN <= MAX, not ", v
        )
    return (_mb_of_gb(lo), _mb_of_gb(hi))


def _num_text(x: Float64) -> String:
    """`x` without a trailing `.0`."""
    if Float64(Int(x)) == x:
        return String(Int(x))
    return String(x)


def canonical_cpus(v: String) raises -> String:
    var r = parse_cpus(v)
    if r[0] == 0:
        return String(AUTO) if r[1] == 0 else String("auto..", r[1])
    if r[0] == r[1]:
        return String(r[0])
    return String(r[0], "..", r[1])


def canonical_memory_gb(v: String) raises -> String:
    var r = parse_memory_gb(v)
    if r[0] == 0:
        if r[1] == 0:
            return String(AUTO)
        return String("auto..", _num_text(Float64(_auto_max(v)[1])))
    var dots = v.find("..").or_else(-1)
    if dots < 0:
        return _num_text(Float64(v))
    var lo = Float64(String(v[byte=:dots]))
    var hi = Float64(String(v[byte = dots + 2 :]))
    if lo == hi:
        return _num_text(lo)
    return String(_num_text(lo), "..", _num_text(hi))


def gb_text(mb: Int) -> String:
    """`mb` as GB to a tenth, without a trailing `.0`: `1.3`, `2`."""
    var tenths = (max(mb, 0) * 10 + 512) // 1024
    if tenths % 10 == 0:
        return String(tenths // 10)
    return String(tenths // 10, ".", tenths % 10)


struct Request(ImplicitlyCopyable, Movable):
    """A pipeline's range of CPUs and memory, and its whole GPUs; 0s for a
    resource it doesn't ask for. `cpus_auto` and `memory_auto` mark a
    learned one (`auto`, or `auto..MAX` with its maximum), which
    `morca._internal.recommend.resolve_request` makes a range before
    admission."""

    var cpus_min: Int
    var cpus_max: Int
    var memory_min_mb: Int
    var memory_max_mb: Int
    var cpus_auto: Bool
    var memory_auto: Bool
    var gpus: Int
    """Whole GPUs, granted exactly; only a group asks for them."""

    def __init__(
        out self,
        cpus_min: Int,
        cpus_max: Int,
        memory_min_mb: Int,
        memory_max_mb: Int,
        cpus_auto: Bool = False,
        memory_auto: Bool = False,
        gpus: Int = 0,
    ):
        self.cpus_min = cpus_min
        self.cpus_max = cpus_max
        self.memory_min_mb = memory_min_mb
        self.memory_max_mb = memory_max_mb
        self.cpus_auto = cpus_auto
        self.memory_auto = memory_auto
        self.gpus = gpus

    @staticmethod
    def of(cpus: String, memory_gb: String) raises -> Request:
        """From the registered `cpus` and `memory_gb`, each empty for none."""
        var r = Request(0, 0, 0, 0)
        if cpus:
            var c = parse_cpus(cpus)
            r.cpus_min = c[0]
            r.cpus_max = c[1]
            r.cpus_auto = c[0] == 0
        if memory_gb:
            var m = parse_memory_gb(memory_gb)
            r.memory_min_mb = m[0]
            r.memory_max_mb = m[1]
            r.memory_auto = m[0] == 0
        return r

    def any(self) -> Bool:
        return (
            self.cpus_min > 0
            or self.memory_min_mb > 0
            or self.cpus_auto
            or self.memory_auto
            or self.gpus > 0
        )

    def auto(self) -> Bool:
        """Whether either resource is learned."""
        return self.cpus_auto or self.memory_auto

    def cpus_text(self) -> String:
        """Its CPUs as `cpus` says them: `2`, `1..16`, `auto..16`; empty
        for none."""
        if self.cpus_auto:
            return String(AUTO) if self.cpus_max == 0 else String(
                "auto..", self.cpus_max
            )
        if self.cpus_min == 0:
            return String()
        if self.cpus_min == self.cpus_max:
            return String(self.cpus_min)
        return String(self.cpus_min, "..", self.cpus_max)

    def memory_gb_text(self) -> String:
        """Its memory as `memory_gb` says it, to the hundredth of a GB:
        `3.25`, `2..24`, `auto..24`; empty for none."""
        if self.memory_auto:
            return String(AUTO) if self.memory_max_mb == 0 else String(
                "auto..", gb_hundredths(self.memory_max_mb)
            )
        if self.memory_min_mb == 0:
            return String()
        if self.memory_min_mb == self.memory_max_mb:
            return gb_hundredths(self.memory_min_mb)
        return String(
            gb_hundredths(self.memory_min_mb),
            "..",
            gb_hundredths(self.memory_max_mb),
        )


def gb_hundredths(mb: Int) -> String:
    """`mb` as GB to the hundredth, as `memory_gb` takes it: `3.25`, `3.5`,
    `4`."""
    var hundredths = (max(mb, 0) * 100 + 512) // 1024
    var out = String(hundredths // 100)
    var frac = hundredths % 100
    if frac:
        out.write(".", frac // 10)
        if frac % 10:
            out.write(frac % 10)
    return out^


def devices_text(devices: List[Int]) -> String:
    """Device indexes as `MORCA_GRANT_GPUS` gives them: `0,2`; empty for
    none."""
    var out = String()
    for i in range(len(devices)):
        out.write("," if i else "", devices[i])
    return out^


struct Grant(ImplicitlyCopyable, Movable):
    """What a start of a run was given; 0 for a resource it didn't ask
    for."""

    var cpus: Int
    var memory_mb: Int
    var gpus: Int
    """How many whole GPUs it holds, as admission decided."""
    var devices: String
    """Which: the indexes of the devices the worker handed it (`Gpus`),
    as `MORCA_GRANT_GPUS` gives them (`0,2`); empty until then and for
    none. Text, not a list, so a grant stays implicitly copyable."""

    def __init__(
        out self,
        cpus: Int,
        memory_mb: Int,
        gpus: Int = 0,
        devices: String = "",
    ):
        self.cpus = cpus
        self.memory_mb = memory_mb
        self.gpus = gpus
        self.devices = devices

    @staticmethod
    def none() -> Grant:
        return Grant(0, 0)

    def device_list(self) -> List[Int]:
        """Its devices' indexes."""
        var out = List[Int]()
        for d in self.devices.split(","):
            try:
                var t = String(d.strip())
                if t:
                    out.append(Int(t))
            except:
                pass
        return out^

    @staticmethod
    def from_env() -> Grant:
        """This run's grant, from `MORCA_GRANT_CPUS`,
        `MORCA_GRANT_MEMORY_MB` and `MORCA_GRANT_GPUS`; 0 and none for what
        isn't set."""
        var g = Grant(0, 0)
        g.devices = getenv(GRANT_GPUS)
        var list = g.device_list()
        g.gpus = len(list)
        g.devices = devices_text(list)
        try:
            if getenv(GRANT_CPUS):
                g.cpus = max(Int(getenv(GRANT_CPUS)), 0)
        except:
            pass
        try:
            if getenv(GRANT_MEMORY_MB):
                g.memory_mb = max(Int(getenv(GRANT_MEMORY_MB)), 0)
        except:
            pass
        return g

    def env(self, host_gpus: Int = 0) -> List[String]:
        """`NAME=value` for a run's process. On a host with GPUs
        (`host_gpus`), and for a grant that holds some, also its devices in
        `MORCA_GRANT_GPUS` and `CUDA_VISIBLE_DEVICES`, empty for none, so a
        process sees only the GPUs it was given; on a host without, neither.
        """
        var out = List[String]()
        if self.cpus > 0:
            out.append(String(GRANT_CPUS, "=", self.cpus))
        if self.memory_mb > 0:
            out.append(String(GRANT_MEMORY_MB, "=", self.memory_mb))
        if host_gpus > 0 or self.gpus > 0 or self.devices:
            out.append(String(GRANT_GPUS, "=", self.devices))
            out.append(String(CUDA_DEVICES, "=", self.devices))
        return out^


struct Room(ImplicitlyCopyable, Movable):
    """What a host can grant its runs in all: its capacity less its
    reserve; and its GPUs, with those its live grants don't hold."""

    var cpus: Int
    var memory_mb: Int
    var capacity_cpus: Int
    var capacity_memory_mb: Int
    var gpus: Int
    """The GPUs the host has."""
    var free_gpus: Int
    """Those of them no live grant holds."""

    def __init__(
        out self,
        cpus: Int,
        memory_mb: Int,
        capacity_cpus: Int,
        capacity_memory_mb: Int,
        gpus: Int = 0,
        free_gpus: Int = 0,
    ):
        self.cpus = cpus
        self.memory_mb = memory_mb
        self.capacity_cpus = capacity_cpus
        self.capacity_memory_mb = capacity_memory_mb
        self.gpus = gpus
        self.free_gpus = free_gpus


struct Gpus(Movable):
    """A worker's GPUs, as it hands them out (docs/groups.md): which of
    the host's devices are free. Admission decides how many a start holds;
    the worker takes that many here when it starts the process, and gives
    them back when the process ends."""

    var busy: List[Bool]

    def __init__(out self, count: Int):
        self.busy = List[Bool](length=max(count, 0), fill=False)

    def count(self) -> Int:
        """The GPUs the host has."""
        return len(self.busy)

    def free(self) -> Int:
        var n = 0
        for b in self.busy:
            if not b:
                n += 1
        return n

    def take(mut self, n: Int) raises -> List[Int]:
        """The `n` free devices with the lowest indexes, now held; raises if
        fewer are free."""
        var out = List[Int]()
        if n <= 0:
            return out^
        if n > self.free():
            raise Error(
                "morca worker: granted ",
                n,
                " GPUs, but ",
                self.free(),
                " of its ",
                self.count(),
                " are free",
            )
        for i in range(len(self.busy)):
            if len(out) == n:
                break
            if not self.busy[i]:
                self.busy[i] = True
                out.append(i)
        return out^

    def give_back(mut self, devices: List[Int]):
        """Frees `devices`, those `take` gave; others are ignored."""
        for d in devices:
            if d >= 0 and d < len(self.busy):
                self.busy[d] = False


def _env_int(name: StaticString, default: Int) raises -> Int:
    var s = getenv(name)
    if not s:
        return default
    try:
        var n = Int(s)
        if n >= 0:
            return n
    except:
        pass
    raise Error("morca: ", name, " must be a number from 0, not ", s)


def _cgroup_int(path: String) -> Int:
    """The number in a cgroup file, or -1 for `max`, none or no file."""
    var t = String(_read(path).strip())
    if not t or t == "max":
        return -1
    try:
        return Int(t)
    except:
        return -1


def host_capacity() raises -> Tuple[Int, Int]:
    """This host's CPUs and memory in MB, as a run here may use them:
    `MORCA_HOST_CPUS` and `MORCA_HOST_MEMORY_MB` if set; else on Linux the
    cgroup's limits (v2 `cpu.max` and `memory.max`, or v1's) where they're
    lower than the cores and `/proc/meminfo`'s MemTotal; else `sysctl`."""
    var cpus = num_logical_cores()
    var mb: Int
    comptime if CompilationTarget.is_linux():
        mb = parse_meminfo(_read("/proc/meminfo")).get("MemTotal", 0) // (
            1024 * 1024
        )
        var limit = _cgroup_int("/sys/fs/cgroup/memory.max")
        if limit < 0:
            limit = _cgroup_int("/sys/fs/cgroup/memory/memory.limit_in_bytes")
        if limit > 0 and limit // (1024 * 1024) < mb:
            mb = limit // (1024 * 1024)
        var quota = -1
        var period = 0
        var cpu_max = _read("/sys/fs/cgroup/cpu.max")
        var words = cpu_max.split()
        if len(words) == 2 and String(words[0]) != "max":
            try:
                quota = Int(String(words[0]))
                period = Int(String(words[1]))
            except:
                quota = -1
        if quota < 0:
            quota = _cgroup_int("/sys/fs/cgroup/cpu/cpu.cfs_quota_us")
            period = _cgroup_int("/sys/fs/cgroup/cpu/cpu.cfs_period_us")
        if quota > 0 and period > 0:
            cpus = min(cpus, max((quota + period - 1) // period, 1))
    else:
        mb = _sysctl_u64("hw.memsize") // (1024 * 1024)
    cpus = _env_int("MORCA_HOST_CPUS", cpus)
    mb = _env_int("MORCA_HOST_MEMORY_MB", mb)
    return (cpus, mb)


def count_gpus(listing: String) -> Int:
    """The GPUs `nvidia-smi -L` lists: its lines `GPU <n>: ...` (a MIG
    device's indented line under one isn't another)."""
    var n = 0
    for line in listing.split("\n"):
        if line.startswith("GPU "):
            n += 1
    return n


def host_gpus(
    smi: List[String] = ["nvidia-smi", "-L"],
    timeout: Float64 = GPU_COUNT_SECONDS,
) raises -> Int:
    """This host's GPUs: `MORCA_HOST_GPUS` if set (a number from 0, else
    this raises); else the devices `smi` lists, run for at most `timeout`
    seconds; none if it isn't there, fails or takes longer."""
    if getenv(HOST_GPUS):
        return _env_int(HOST_GPUS, 0)
    try:
        var got = capture(smi, timeout=timeout)
        if got[0] != 0:
            return 0
        return count_gpus(got[1])
    except:
        return 0


def host_room(worker: Bool = False) raises -> Room:
    """What this host can grant: `host_capacity` less `MORCA_RESERVE_CPUS`
    and `MORCA_RESERVE_MEMORY_MB` (1 and 1536 beside the scheduler, Postgres
    and the UI; 0 and 512 on a worker)."""
    var cap = host_capacity()
    var rc = _env_int("MORCA_RESERVE_CPUS", 0 if worker else 1)
    var rm = _env_int("MORCA_RESERVE_MEMORY_MB", 512 if worker else 1536)
    return Room(max(cap[0] - rc, 0), max(cap[1] - rm, 0), cap[0], cap[1])


def _cpus_text(n: Int) -> String:
    return String(n, " CPU" if n == 1 else " CPUs")


def gpus_text(n: Int) -> String:
    return String(n, " GPU" if n == 1 else " GPUs")


def admit(
    req: Request,
    room: Room,
    granted_cpus: Int,
    granted_mb: Int,
    most: Int,
    host: String = "this host",
) -> Tuple[List[Grant], String]:
    """Up to `most` starts of a pipeline asking for `req`, on a host that can
    grant `room` and has granted its running runs `granted_cpus` and
    `granted_mb`: each start's grant, the first up to its maximum from what's
    left, the next from what that left, until a minimum doesn't fit; and
    exactly its GPUs, from those `room` has free. With fewer than `most`,
    also why the next one waits."""
    var out = List[Grant]()
    var free_cpus = room.cpus - granted_cpus
    var free_mb = room.memory_mb - granted_mb
    var free_gpus = room.free_gpus
    while len(out) < most:
        var why = List[String]()
        if req.memory_min_mb > 0 and req.memory_min_mb > free_mb:
            if req.memory_min_mb > room.memory_mb:
                why.append(
                    String(
                        gb_text(req.memory_min_mb),
                        " GB, more than the ",
                        gb_text(room.memory_mb),
                        " GB ",
                        host,
                        " grants at most",
                    )
                )
            else:
                why.append(
                    String(
                        gb_text(req.memory_min_mb),
                        " GB, ",
                        gb_text(free_mb),
                        " GB free of grants",
                    )
                )
        if req.cpus_min > 0 and req.cpus_min > free_cpus:
            if req.cpus_min > room.cpus:
                why.append(
                    String(
                        _cpus_text(req.cpus_min),
                        ", more than the ",
                        room.cpus,
                        " ",
                        host,
                        " grants at most",
                    )
                )
            else:
                why.append(
                    String(
                        _cpus_text(req.cpus_min),
                        ", ",
                        max(free_cpus, 0),
                        " free of grants",
                    )
                )
        if req.gpus > 0 and req.gpus > free_gpus:
            if req.gpus > room.gpus:
                why.append(
                    String(
                        gpus_text(req.gpus),
                        ", more than the ",
                        room.gpus,
                        " ",
                        host,
                        " grants at most",
                    )
                )
            else:
                why.append(
                    String(
                        gpus_text(req.gpus),
                        ", ",
                        max(free_gpus, 0),
                        " free of grants",
                    )
                )
        if len(why) > 0:
            var text = String(WAITING)
            for i in range(len(why)):
                text.write("; needs " if i else "", why[i])
            if host != "this host" and "grants at most" not in text:
                text.write(" on ", host)
            return (out^, text^)
        var g = Grant(0, 0)
        if req.cpus_min > 0:
            g.cpus = min(req.cpus_max, free_cpus)
            free_cpus -= g.cpus
        if req.memory_min_mb > 0:
            g.memory_mb = min(req.memory_max_mb, free_mb)
            free_mb -= g.memory_mb
        g.gpus = max(req.gpus, 0)
        free_gpus -= g.gpus
        out.append(g)
    return (out^, String())


def run_env(
    env: List[Tuple[String, String]],
    g: Grant,
    extra: List[String] = [],
    host_gpus: Int = 0,
) -> List[String]:
    """A start's `NAME=value`s: the pipeline's `env` as it is (`auto`
    included), then `g`'s variables (`Grant.env` on a host of `host_gpus`),
    then `extra`."""
    var out = List[String]()
    for kv in env:
        out.append(String(kv[0], "=", kv[1]))
    out.extend(g.env(host_gpus))
    out.extend(extra.copy())
    return out^


def auto_count(
    name: String, default: Int, memory_mb_each: Int = 0
) raises -> Int:
    """A pipeline's count of work in flight, from its variable `name`: a
    number as given, `default` if unset, and for `auto` the run's granted
    CPUs (else this host's cores), at most the granted memory over
    `memory_mb_each` when both are known; at least 1.

        var parallel = auto_count("GHARCHIVE_PARALLEL", 16, memory_mb_each=1500)
    """
    var v = getenv(name)
    if not v:
        return default
    if v != AUTO:
        try:
            return Int(v)
        except:
            raise Error(name, " is a number or auto, not ", v)
    var g = Grant.from_env()
    var n = g.cpus if g.cpus > 0 else num_logical_cores()
    if memory_mb_each > 0 and g.memory_mb > 0:
        n = min(n, g.memory_mb // memory_mb_each)
    return max(n, 1)
