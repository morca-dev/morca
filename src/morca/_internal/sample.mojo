"""The sampler: a run's machine metrics, one JSON line every few seconds.

```
morca sample --out <location> [--pid PID] [--until FILE] [--match PATH]
            [--dirs D,...] [--seconds S] [--count N] [--keep N]
            [--cgroup DIR] [--names DIR]
<pipeline> sample ...                       the same, from a pipeline binary
```

It runs beside every process that does a run's work, started by the runner:
on the ec2 runner by each instance's user data, next to dista (`morca._internal.ec2`);
on the local runner beside each run's process (`morca._internal.scheduler`); on the
kube runner in each pod (`morca._internal.kube`). The runners start it as
`<binary> sample`, since the pipeline's binary is what every instance and
image has; `morca sample` is the same command.

Every `--seconds` (`MORCA_SAMPLE_SECONDS`, default 5; the first line a fifth
of a second after it starts, so any instance it ran on leaves one) it reads `/proc` on Linux,
or sysctls and the Mach host calls on macOS, and appends a line:

```
{"v": 1, "t": 1762250000.123, "dt": 5.0, "host": "ip-10-0-1-5", "cores": 4,
 "cpu": {"user": 61.2, "system": 4.1, "iowait": 0.3, "steal": 0.0, "busiest": 99.0},
 "mem": {"total": 8053063680, "used": 3221225472, "available": 4831838208,
         "cache": 2147483648, "swap_total": 0, "swap_used": 0, "rss": 2952790016},
 "disk": [{"path": "/tmp", "total": 53687091200, "used": 9663676416, "free": 44023414784}],
 "io": {"read": 1048576, "write": 52428800}, "net": {"in": 1310720, "out": 655360},
 "containers": [{"name": "postgres", "mem": 412000000}], "self_cpu": 0.42}
```

- `t` is the Unix time, `dt` the seconds since the previous line.
- `cpu`: percentages of all cores' time over `dt`; `busiest` is the busiest
  core's. `iowait` and `steal` are always 0 on macOS.
- `mem`: bytes. `used` is `total - available` on Linux (`MemAvailable`),
  and app, wired and compressed memory on macOS; `cache` is the page cache
  (file-backed pages). `rss` is the resident set of the run's own
  processes: `--pid` and its descendants, and on Linux every process whose
  command is `--match` (on the ec2 runner, the binary in its containers,
  which aren't the script's children).
- `disk`: per directory the run writes to (`--dirs`, default `TMPDIR` or
  `/tmp`, and dista's `DISTA_SPILL_DIR` and `DISTA_STORE_DIR` when set), one
  per file system, in bytes; `free` is what an unprivileged process can use.
- `io` and `net`: bytes per second over `dt`, summed over whole disks and
  over interfaces other than loopback. `io` is `null` on macOS.
- `containers`: only with `--cgroup`; see below.
- `self_cpu`: the sampler's own CPU seconds so far, for its overhead.

Later fields may be added (CPU counters), so readers ignore keys they don't know; `v` changes only if one
that's here changes meaning.

`--out` is where the lines go: a file, a location in object storage (lines
are appended to its `morca._internal.logs.stage_of` staging file and the whole of it
uploaded every `MORCA_SAMPLE_UPLOAD_SECONDS`, 30 by default, and when the
sampler ends), or `-`, standard output with each line prefixed
`orca-sample `, for a pod whose log the scheduler keeps. The runners put it
at `<MORCA_LOGS>/<pipeline>/<run>/metrics/<instance>.jsonl`
(`metrics_location`).

`--keep N` keeps a file `--out` names to about its last N lines, for a
sampler that never ends (the control instance's, which the scheduler reads
back into the fleet page, `morca._internal.fleet`): once the file has 2 N it's
rewritten with its last N, atomically, so a reader sees either.

`--cgroup DIR` (the control instance's sampler) adds `containers`: the
memory of each Docker container, in bytes, as `docker stats` counts it
(`memory.current` less the page cache's inactive files), read from the
cgroup files under `DIR`, the host's `/sys/fs/cgroup` mounted read-only
(`system.slice/docker-<id>.scope` with the systemd driver, `docker/<id>` with
cgroupfs; cgroup v2 only). `--names DIR` is the host's
`/var/lib/docker/containers`, also read-only, whose `<id>/config.v2.json`
gives a container its name; without it a container is its first 12
characters of id. Reading files, not the Docker socket, keeps the sampler
unprivileged: the socket is root on the host, these mounts are not.

It ends after a last line once the `--pid` process has, or once the file
`--until` names exists, or after `--count` lines. SIGTERM ends it at once,
keeping the lines it wrote (Mojo's runtime threads take signals a blocked
main thread wouldn't, so it can't wait for one), which is why the runners
stop it with `--pid` or `--until`. A line it can't write is dropped with
one message, and it carries on: a sampler never fails a run.
"""

from std.ffi import c_int, external_call
from std.os import getenv, listdir, makedirs
from std.os.path import exists
from std.sys.info import CompilationTarget
from std.time import perf_counter_ns, sleep

from json import loads

from morca._internal.logs import (
    is_remote,
    location_exists,
    publish,
    read_location,
    run_dir,
    stage_of,
)

comptime PREFIX = "orca-sample "
"""What starts a sample line written to standard output (`--out -`)."""

comptime _USAGE = """usage:
  sample --out <location>|- [--pid PID] [--until FILE] [--match PATH]
         [--dirs D,...] [--seconds S] [--count N] [--keep N]
         [--cgroup DIR] [--names DIR]"""


def sample_seconds() -> Float64:
    """`MORCA_SAMPLE_SECONDS`: the sampler's interval; 0 turns it off. A value
    that isn't a number is the default, 5."""
    var s = getenv("MORCA_SAMPLE_SECONDS", "5")
    try:
        return max(Float64(s), 0.0)
    except:
        return 5.0


def metrics_location(pipeline: String, run: Int, instance: String) -> String:
    """Where an instance's samples go under `MORCA_LOGS`; "" without it."""
    var dir = run_dir(pipeline, run)
    if not dir:
        return ""
    return String(dir, "/metrics/", instance, ".jsonl")


def machine_name(name: String) -> String:
    """The worker's name as its runs' metrics file names it
    (`metrics/worker-<name>.jsonl`): `worker-` and the name, with anything
    but letters, digits, `.`, `-` and `_` made `_`."""
    var out = String("worker-")
    for b in name.as_bytes():
        var c = Int(b)
        var ok = (
            (c >= 48 and c <= 57)
            or (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122)
            or c == 45
            or c == 46
            or c == 95
        )
        out.write(chr(c) if ok else "_")
    return out^


# ---------------------------------------------------------------------------
# Parsing what Linux's /proc says (pure, for the tests)
# ---------------------------------------------------------------------------


def _int(s: StringSpan) -> Int:
    try:
        return Int(String(s))
    except:
        return 0


def parse_proc_stat(text: String) -> List[List[Int]]:
    """/proc/stat's `cpu` lines: all cores first, then each core, as user,
    nice, system, idle, iowait, irq, softirq and steal ticks."""
    var out = List[List[Int]]()
    for line in text.splitlines():
        if not line.startswith("cpu"):
            continue
        var f = line.split()
        var t = List[Int](length=8, fill=0)
        for k in range(min(8, len(f) - 1)):
            t[k] = _int(f[k + 1])
        out.append(t^)
    return out^


def parse_meminfo(text: String) -> Dict[String, Int]:
    """/proc/meminfo, in bytes."""
    var out = Dict[String, Int]()
    for line in text.splitlines():
        var colon = line.find(":").or_else(-1)
        if colon <= 0:
            continue
        var f = line[byte = colon + 1 :].split()
        if len(f) == 0:
            continue
        var n = _int(f[0])
        if len(f) > 1 and f[1] == "kB":
            n *= 1024
        out[String(line[byte=:colon])] = n
    return out^


def _skipped_disk(name: String) -> Bool:
    """Devices whose traffic is another device's, or not a disk's."""
    for p in ["loop", "ram", "zram", "dm-", "md", "sr", "nbd", "fd"]:
        if name.startswith(p):
            return True
    return False


def parse_diskstats(text: String, disks: List[String]) -> Tuple[Int, Int]:
    """Bytes read and written, summed over the whole disks named in `disks`
    (all but `_skipped_disk` ones if it's empty, which counts partitions
    twice)."""
    var r = 0
    var w = 0
    for line in text.splitlines():
        var f = line.split()
        if len(f) < 10:
            continue
        var name = String(f[2])
        if len(disks) > 0:
            var known = False
            for d in disks:
                if d == name:
                    known = True
                    break
            if not known:
                continue
        elif _skipped_disk(name):
            continue
        r += _int(f[5]) * 512
        w += _int(f[9]) * 512
    return (r, w)


def parse_net_dev(text: String) -> Dict[String, Tuple[Int, Int]]:
    """/proc/net/dev: bytes received and sent per interface, but loopback."""
    var out = Dict[String, Tuple[Int, Int]]()
    for line in text.splitlines():
        var colon = line.find(":").or_else(-1)
        if colon <= 0:
            continue
        var name = String(line[byte=:colon].strip())
        if name == "lo":
            continue
        var f = line[byte = colon + 1 :].split()
        if len(f) < 9:
            continue
        out[name] = (_int(f[0]), _int(f[8]))
    return out^


def parse_pid_stat(text: String) -> Tuple[Int, Int]:
    """/proc/<pid>/stat's parent and resident pages; (-1, 0) if malformed."""
    var close = text.rfind(")").or_else(-1)
    if close < 0:
        return (-1, 0)
    var f = text[byte = close + 1 :].split()
    if len(f) < 22:
        return (-1, 0)
    return (_int(f[1]), _int(f[21]))


@fieldwise_init
struct PidUsage(ImplicitlyCopyable, Movable):
    """What /proc/<pid>/stat says one process uses."""

    var parent: Int
    """-1 if the line was malformed."""
    var rss_pages: Int
    var cpu_ticks: Int
    """utime + stime + cutime + cstime: its own CPU and that of the
    children it waited for, in clock ticks."""


def parse_pid_usage(text: String) -> PidUsage:
    """/proc/<pid>/stat's parent, resident pages and CPU ticks."""
    var close = text.rfind(")").or_else(-1)
    if close < 0:
        return PidUsage(-1, 0, 0)
    var f = text[byte = close + 1 :].split()
    if len(f) < 22:
        return PidUsage(-1, 0, 0)
    return PidUsage(
        _int(f[1]),
        _int(f[21]),
        _int(f[11]) + _int(f[12]) + _int(f[13]) + _int(f[14]),
    )


@fieldwise_init
struct CpuShare(Copyable, Movable):
    """Percentages of all cores' time between two readings."""

    var user: Float64
    var system: Float64
    var iowait: Float64
    var steal: Float64
    var busiest: Float64


def _busy(prev: List[Int], cur: List[Int]) -> Float64:
    var total = 0
    for k in range(8):
        total += cur[k] - prev[k]
    if total <= 0:
        return 0.0
    var idle = (cur[3] - prev[3]) + (cur[4] - prev[4])
    return 100.0 * Float64(total - idle) / Float64(total)


def cpu_share(prev: List[List[Int]], cur: List[List[Int]]) -> CpuShare:
    """The share of each kind of CPU time between `prev` and `cur`, readings
    as `parse_proc_stat` gives them."""
    if len(prev) == 0 or len(cur) == 0:
        return CpuShare(0, 0, 0, 0, 0)
    var d = List[Int](length=8, fill=0)
    var total = 0
    for k in range(8):
        d[k] = cur[0][k] - prev[0][k]
        total += d[k]
    var busiest = 0.0
    for c in range(1, min(len(prev), len(cur))):
        busiest = max(busiest, _busy(prev[c], cur[c]))
    if total <= 0:
        return CpuShare(0, 0, 0, 0, busiest)
    var t = Float64(total)
    return CpuShare(
        100.0 * Float64(d[0] + d[1]) / t,
        100.0 * Float64(d[2] + d[5] + d[6]) / t,
        100.0 * Float64(d[4]) / t,
        100.0 * Float64(d[7]) / t,
        busiest,
    )


def fixed1(x: Float64) -> String:
    """`x` to one decimal, as JSON."""
    var n = Int(x * 10.0 + (0.5 if x >= 0 else -0.5))
    var sign = String("-") if n < 0 else String()
    n = abs(n)
    return String(sign, n // 10, ".", n % 10)


def _fixed3(x: Float64) -> String:
    var n = Int(x * 1000.0 + 0.5)
    var frac = String(n % 1000)
    while frac.byte_length() < 3:
        frac = String("0", frac)
    return String(n // 1000, ".", frac)


# ---------------------------------------------------------------------------
# Reading the machine
# ---------------------------------------------------------------------------


def _read(path: String) -> String:
    """The file's text; "" if it can't be read."""
    try:
        with open(path, "r") as f:
            return f.read()
    except:
        return ""


def _cstr(s: String) -> List[UInt8]:
    var b = List[UInt8](capacity=s.byte_length() + 1)
    for c in s.as_bytes():
        b.append(c)
    b.append(0)
    return b^


def _u64(b: List[UInt8], at: Int) -> Int:
    """The little-endian 64-bit value at `at`."""
    var v = 0
    for k in range(8):
        v |= Int(b[at + k]) << (8 * k)
    return v


def _u32(b: List[UInt8], at: Int) -> Int:
    var v = 0
    for k in range(4):
        v |= Int(b[at + k]) << (8 * k)
    return v


def _peek(address: Int, n: Int) -> List[UInt8]:
    """A copy of `n` bytes at `address`, memory a C call handed back."""
    var b = List[UInt8](length=n, fill=0)
    _ = external_call["memcpy", Int](b.unsafe_ptr(), address, n)
    return b^


def _wall() -> Float64:
    var ts = List[Int64](length=2, fill=0)
    _ = external_call["clock_gettime", Int32](Int32(0), ts.unsafe_ptr())
    return Float64(ts[0]) + Float64(ts[1]) / 1e9


def _self_cpu() -> Float64:
    """This process's user and system CPU seconds (getrusage)."""
    var buf = List[UInt8](length=256, fill=0)
    _ = external_call["getrusage", c_int](c_int(0), buf.unsafe_ptr())
    var p = buf.copy()
    return (
        Float64(_u64(p, 0))
        + Float64(_u32(p, 8)) / 1e6
        + Float64(_u64(p, 16))
        + Float64(_u32(p, 24)) / 1e6
    )


def _hostname() -> String:
    var buf = List[UInt8](length=256, fill=0)
    if external_call["gethostname", c_int](buf.unsafe_ptr(), Int(255)) != 0:
        return "unknown"
    var n = 0
    while n < 255 and buf[n] != 0:
        n += 1
    return String(from_utf8_lossy=Span(buf)[:n])


def alive(pid: Int) -> Bool:
    """Whether a process `pid` is running: one that has exited is dead,
    though its parent hasn't reaped it yet (a shell running the sampler in
    front doesn't reap the job it watches until the sampler ends)."""
    if external_call["kill", c_int](c_int(pid), c_int(0)) != 0:
        return False
    comptime if CompilationTarget.is_macos():
        # PROC_PIDTBSDINFO: pbi_status is SZOMB (5) for a zombie, or the
        # call fails for one.
        var info = List[UInt8](length=160, fill=0)
        var n = external_call["proc_pidinfo", c_int](
            c_int(pid), c_int(3), UInt64(0), info.unsafe_ptr(), c_int(136)
        )
        return n >= 8 and _u32(info, 4) != 5
    else:
        var st = _read(String("/proc/", pid, "/stat"))
        var close = st.rfind(")").or_else(-1)
        if close < 0:
            return True
        var f = st[byte = close + 1 :].split()
        return not (len(f) > 0 and f[0] == "Z")


def container_mem(current: String, stat: String) -> Int:
    """A container's memory as `docker stats` counts it: a cgroup v2
    `memory.current` less `inactive_file` from `memory.stat`; -1 if
    `current` isn't a number."""
    var used: Int
    try:
        used = Int(current.strip())
    except:
        return -1
    for line in stat.splitlines():
        if line.startswith("inactive_file "):
            try:
                used -= Int(line[byte=14:].strip())
            except:
                pass
    return max(used, 0)


def container_name(config: String) -> String:
    """The name in a container's `config.v2.json` (`/postgres`), without the
    slash; empty if there is none."""
    try:
        var v = loads(config)
        var got = v.try_at("/Name")
        if got:
            return String(got.value().string_or("").lstrip("/"))
    except:
        pass
    return String()


def container_ids(root: String) -> List[Tuple[String, String]]:
    """The Docker containers' cgroups under `root`, as (id, directory): the
    systemd driver's `system.slice/docker-<id>.scope` and cgroupfs's
    `docker/<id>`."""
    var out = List[Tuple[String, String]]()
    var base = String(root.rstrip("/"))
    try:
        var slice = String(base, "/system.slice")
        for d in listdir(slice):
            if d.startswith("docker-") and d.endswith(".scope"):
                var id = String(d[byte = 7 : d.byte_length() - 6])
                out.append((id, String(slice, "/", d)))
    except:
        pass
    try:
        var plain = String(base, "/docker")
        for d in listdir(plain):
            if d.byte_length() == 64:
                out.append((String(d), String(plain, "/", d)))
    except:
        pass
    return out^


@fieldwise_init
struct Disk(Copyable, Movable):
    var path: String
    var total: Int
    var used: Int
    var free: Int
    var fsid: Int


def _disk(path: String) -> Optional[Disk]:
    """The file system holding `path`: statvfs on Linux, statfs on macOS
    (whose statvfs counts blocks in 32 bits)."""
    if not exists(path):
        return None
    var buf = List[UInt8](length=4096, fill=0)
    var c = _cstr(path)
    comptime if CompilationTarget.is_macos():
        if (
            external_call["statfs", c_int](c.unsafe_ptr(), buf.unsafe_ptr())
            != 0
        ):
            return None
        var p = buf.copy()
        var bs = _u32(p, 0)
        var blocks = _u64(p, 8)
        var bfree = _u64(p, 16)
        var bavail = _u64(p, 24)
        return Disk(
            path, blocks * bs, (blocks - bfree) * bs, bavail * bs, _u64(p, 48)
        )
    else:
        if (
            external_call["statvfs", c_int](c.unsafe_ptr(), buf.unsafe_ptr())
            != 0
        ):
            return None
        var p = buf.copy()
        var bs = _u64(p, 8)  # f_frsize
        var blocks = _u64(p, 16)
        var bfree = _u64(p, 24)
        var bavail = _u64(p, 32)
        return Disk(
            path, blocks * bs, (blocks - bfree) * bs, bavail * bs, _u64(p, 64)
        )


@fieldwise_init
struct Mem(Copyable, Movable):
    var total: Int
    var used: Int
    var available: Int
    var cache: Int
    var swap_total: Int
    var swap_used: Int


def _sysctl_u64(name: String) -> Int:
    var buf = List[UInt8](length=8, fill=0)
    var len = List[Int](length=1, fill=8)
    var c = _cstr(name)
    if (
        external_call["sysctlbyname", c_int](
            c.unsafe_ptr(), buf.unsafe_ptr(), len.unsafe_ptr(), Int(0), Int(0)
        )
        != 0
    ):
        return 0
    return _u64(buf, 0)


struct Sampler(Movable):
    """The readings a line is the difference of, and what to read."""

    var root: Int
    var argv0: String
    var dirs: List[String]
    var host: String
    var cores: Int
    var disks: List[String]
    """Linux's whole disks, from /sys/block."""
    var task: UInt32
    """macOS: this task's port, to free what host_processor_info returns."""
    var cpu: List[List[Int]]
    var io: Tuple[Int, Int]
    var net: Dict[String, Tuple[Int, Int]]
    var net_total: Tuple[Int, Int]
    var at: Int
    """perf_counter_ns of the readings."""
    var cgroup: String
    """`--cgroup`: where the containers' cgroups are; empty for none."""
    var names: String
    """`--names`: where the containers' config files are."""
    var known: Dict[String, String]
    """Container ids and the names read for them."""

    def __init__(
        out self,
        root: Int,
        argv0: String,
        var dirs: List[String],
        cgroup: String = "",
        names: String = "",
    ):
        self.cgroup = cgroup
        self.names = names
        self.known = Dict[String, String]()
        self.root = root
        self.argv0 = argv0
        self.dirs = dirs^
        self.host = _hostname()
        self.disks = List[String]()
        self.task = 0
        comptime if CompilationTarget.is_macos():
            self.task = external_call["task_self_trap", UInt32]()
        else:
            try:
                for d in listdir("/sys/block"):
                    if not _skipped_disk(d):
                        self.disks.append(d)
            except:
                pass
        self.cpu = List[List[Int]]()
        self.io = (0, 0)
        self.net = Dict[String, Tuple[Int, Int]]()
        self.net_total = (0, 0)
        self.at = 0
        self.cores = 0
        self.cpu = self._cpu()
        self.cores = max(len(self.cpu) - 1, 1)
        self.io = self._io()
        _ = self._net_delta()
        self.net_total = (0, 0)
        self.at = Int(perf_counter_ns())

    def _cpu(self) -> List[List[Int]]:
        comptime if CompilationTarget.is_macos():
            var n = List[UInt32](length=1, fill=0)
            var info = List[Int](length=1, fill=0)
            var count = List[UInt32](length=1, fill=0)
            var host = external_call["mach_host_self", UInt32]()
            # PROCESSOR_CPU_LOAD_INFO: user, system, idle, nice per core.
            if (
                external_call["host_processor_info", c_int](
                    host,
                    c_int(2),
                    n.unsafe_ptr(),
                    info.unsafe_ptr(),
                    count.unsafe_ptr(),
                )
                != 0
            ):
                return List[List[Int]]()
            var p = _peek(info[0], Int(count[0]) * 4)
            var out = List[List[Int]]()
            out.append(List[Int](length=8, fill=0))
            for c in range(Int(n[0])):
                var t = List[Int](length=8, fill=0)
                t[0] = _u32(p, c * 16)
                t[2] = _u32(p, c * 16 + 4)
                t[3] = _u32(p, c * 16 + 8)
                t[1] = _u32(p, c * 16 + 12)
                for k in range(8):
                    out[0][k] += t[k]
                out.append(t^)
            _ = external_call["vm_deallocate", c_int](
                self.task, info[0], Int(count[0]) * 4
            )
            return out^
        else:
            return parse_proc_stat(_read("/proc/stat"))

    def _mem(self) -> Mem:
        comptime if CompilationTarget.is_macos():
            var total = _sysctl_u64("hw.memsize")
            var buf = List[UInt8](length=256, fill=0)
            var count = List[UInt32](length=1, fill=38)  # HOST_VM_INFO64_COUNT
            var host = external_call["mach_host_self", UInt32]()
            _ = external_call["host_statistics64", c_int](
                host, c_int(4), buf.unsafe_ptr(), count.unsafe_ptr()
            )
            var p = buf.copy()
            var page = Int(external_call["getpagesize", c_int]())
            var wired = _u32(p, 12)
            var purgeable = _u32(p, 88)
            var compressed = _u32(p, 128)
            var external = _u32(p, 136)
            var internal = _u32(p, 140)
            var used = (internal - purgeable + wired + compressed) * page
            var swap = List[UInt8](length=32, fill=0)
            var len = List[Int](length=1, fill=32)
            var name = _cstr("vm.swapusage")
            _ = external_call["sysctlbyname", c_int](
                name.unsafe_ptr(),
                swap.unsafe_ptr(),
                len.unsafe_ptr(),
                Int(0),
                Int(0),
            )
            return Mem(
                total,
                used,
                max(total - used, 0),
                (external + purgeable) * page,
                _u64(swap, 0),
                _u64(swap, 16),
            )
        else:
            var m = parse_meminfo(_read("/proc/meminfo"))
            var total = m.get("MemTotal", 0)
            var avail = m.get("MemAvailable", m.get("MemFree", 0))
            var swap = m.get("SwapTotal", 0)
            return Mem(
                total,
                max(total - avail, 0),
                avail,
                m.get("Cached", 0) + m.get("Buffers", 0),
                swap,
                max(swap - m.get("SwapFree", 0), 0),
            )

    def _io(self) -> Tuple[Int, Int]:
        comptime if CompilationTarget.is_macos():
            return (0, 0)
        else:
            return parse_diskstats(_read("/proc/diskstats"), self.disks)

    def _net_now(self) -> Dict[String, Tuple[Int, Int]]:
        comptime if CompilationTarget.is_macos():
            # getifaddrs: each AF_LINK entry's if_data holds 32-bit byte
            # counts, ifi_ibytes and ifi_obytes.
            var out = Dict[String, Tuple[Int, Int]]()
            var head = List[Int](length=1, fill=0)
            if external_call["getifaddrs", c_int](head.unsafe_ptr()) != 0:
                return out^
            var at = head[0]
            while at != 0:
                var ifa = _peek(at, 56)
                var addr = _u64(ifa, 24)
                var data = _u64(ifa, 48)
                if addr != 0 and data != 0 and Int(_peek(addr, 2)[1]) == 18:
                    # AF_LINK
                    var np = _u64(ifa, 8)
                    var n = external_call["strlen", Int](np)
                    var name = String(from_utf8_lossy=Span(_peek(np, n)))
                    var d = _peek(data, 48)
                    if not name.startswith("lo"):
                        out[name] = (_u32(d, 40), _u32(d, 44))
                at = _u64(ifa, 0)
            external_call["freeifaddrs", NoneType](head[0])
            return out^
        else:
            return parse_net_dev(_read("/proc/net/dev"))

    def _net_delta(mut self) -> Tuple[Int, Int]:
        """Bytes in and out since the last call: per interface, as macOS's
        counters wrap at 4 GiB."""
        var now = self._net_now()
        var din = 0
        var dout = 0
        for e in now.items():
            var cur = e.value
            if e.key in self.net:
                var prev = self.net.get(e.key, (0, 0))
                din += _delta(prev[0], cur[0])
                dout += _delta(prev[1], cur[1])
        self.net = now^
        return (din, dout)

    def _rss(self) -> Int:
        """The resident bytes of `root`'s process tree, and on Linux of the
        processes whose command is `argv0`."""
        return tree_rss(self.root, self.argv0)

    def _containers(mut self) -> String:
        """`[{"name": ..., "mem": bytes}, ...]` for the containers under
        `--cgroup`, by name."""
        var out = String("[")
        var n = 0
        for c in container_ids(self.cgroup):
            var id = c[0]
            var mem = container_mem(
                _read(String(c[1], "/memory.current")),
                _read(String(c[1], "/memory.stat")),
            )
            if mem < 0:
                continue
            var name = self.known.get(id, "")
            if not name and self.names:
                name = container_name(
                    _read(
                        String(
                            self.names.rstrip("/"), "/", id, "/config.v2.json"
                        )
                    )
                )
                if name:
                    self.known[id] = name
            if not name:
                name = String(id[byte = : min(12, id.byte_length())])
            out.write(
                ", " if n else "",
                '{"name": "',
                _json_safe(name),
                '", "mem": ',
                mem,
                "}",
            )
            n += 1
        out.write("]")
        return out^

    def line(mut self) -> String:
        """A JSON line covering the time since the last one."""
        var now = Int(perf_counter_ns())
        var dt = max(Float64(now - self.at) / 1e9, 1e-3)
        self.at = now
        var cpu = self._cpu()
        var share = cpu_share(self.cpu, cpu)
        self.cpu = cpu^
        var mem = self._mem()
        var io = self._io()
        var dio = (max(io[0] - self.io[0], 0), max(io[1] - self.io[1], 0))
        self.io = io
        var dnet = self._net_delta()
        var s = String(
            '{"v": 1, "t": ',
            _fixed3(_wall()),
            ', "dt": ',
            fixed1(dt),
            ', "host": "',
            _json_safe(self.host),
            '", "cores": ',
            self.cores,
            ', "cpu": {"user": ',
            fixed1(share.user),
            ', "system": ',
            fixed1(share.system),
            ', "iowait": ',
            fixed1(share.iowait),
            ', "steal": ',
            fixed1(share.steal),
            ', "busiest": ',
            fixed1(share.busiest),
            '}, "mem": {"total": ',
            mem.total,
            ', "used": ',
            mem.used,
            ', "available": ',
            mem.available,
            ', "cache": ',
            mem.cache,
            ', "swap_total": ',
            mem.swap_total,
            ', "swap_used": ',
            mem.swap_used,
            ', "rss": ',
            self._rss(),
            '}, "disk": [',
        )
        var fsids = List[Int]()
        for d in self.dirs:
            var got = _disk(d)
            if not got:
                continue
            ref g = got.value()
            var seen = False
            for f in fsids:
                if f == g.fsid:
                    seen = True
            if seen:
                continue
            s.write(
                ", " if len(fsids) else "",
                '{"path": "',
                _json_safe(g.path),
                '", "total": ',
                g.total,
                ', "used": ',
                g.used,
                ', "free": ',
                g.free,
                "}",
            )
            fsids.append(g.fsid)
        s.write("], ")
        comptime if CompilationTarget.is_macos():
            s.write('"io": null')
        else:
            s.write(
                '"io": {"read": ',
                Int(Float64(dio[0]) / dt),
                ', "write": ',
                Int(Float64(dio[1]) / dt),
                "}",
            )
        s.write(
            ', "net": {"in": ',
            Int(Float64(dnet[0]) / dt),
            ', "out": ',
            Int(Float64(dnet[1]) / dt),
            "}",
        )
        if self.cgroup:
            s.write(', "containers": ', self._containers())
        s.write(', "self_cpu": ', _fixed3(_self_cpu()), "}")
        return s^


def _delta(prev: Int, cur: Int) -> Int:
    if cur >= prev:
        return cur - prev
    comptime if CompilationTarget.is_macos():
        return cur + (1 << 32) - prev
    else:
        return cur  # a counter that was reset


def _json_safe(s: String) -> String:
    """`s` without what would need escaping in a JSON string."""
    var out = String()
    for c in s.codepoint_slices():
        if c == '"' or c == "\\" or c.as_bytes()[0] < 32:
            out.write("_")
        else:
            out.write(c)
    return out^


def tree_rss(root: Int, argv0: String = "") -> Int:
    """The resident bytes of `root`'s process tree, and on Linux of the
    processes whose command is `argv0`; the scheduler checks a control-placed
    run's against its cap with it (morca.control)."""
    if root <= 0 and not argv0:
        return 0
    comptime if CompilationTarget.is_macos():
        var total = 0
        var todo: List[Int] = [root]
        var buf = List[Int32](length=4096, fill=0)
        var info = List[UInt8](length=128, fill=0)
        var n = 0
        while len(todo) > 0 and n < 10000:
            var pid = todo.pop()
            n += 1
            if (
                external_call["proc_pidinfo", c_int](
                    c_int(pid),
                    c_int(4),  # PROC_PIDTASKINFO
                    UInt64(0),
                    info.unsafe_ptr(),
                    c_int(96),
                )
                == 96
            ):
                total += _u64(info, 8)
            # PROC_PPID_ONLY: the children's pids, as bytes.
            var got = Int(
                external_call["proc_listpids", c_int](
                    UInt32(6),
                    UInt32(pid),
                    buf.unsafe_ptr(),
                    c_int(4096 * 4),
                )
            )
            for k in range(got // 4):
                if buf[k] > 0:
                    todo.append(Int(buf[k]))
        return total
    else:
        var page = Int(external_call["getpagesize", c_int]())
        var parent = Dict[Int, Int]()
        var rss = Dict[Int, Int]()
        var matched = List[Int]()
        var pids: List[String]
        try:
            pids = listdir("/proc")
        except:
            return 0
        for name in pids:
            var pid: Int
            try:
                pid = Int(name)
            except:
                continue
            var st = parse_pid_stat(_read(String("/proc/", pid, "/stat")))
            if st[0] < 0:
                continue
            parent[pid] = st[0]
            rss[pid] = st[1] * page
            if argv0:
                var cmd = _read(String("/proc/", pid, "/cmdline"))
                var nul = cmd.find("\0").or_else(-1)
                var first = String(cmd[byte=:nul]) if nul >= 0 else cmd
                if first == argv0:
                    matched.append(pid)
        var total = 0
        for e in rss.items():
            var p = e.key
            var hops = 0
            var counted = False
            while p > 0 and hops < 64:
                if p == root:
                    counted = True
                    break
                for m in matched:
                    if m == p:
                        counted = True
                if counted:
                    break
                p = parent.get(p, 0)
                hops += 1
            if counted:
                total += e.value
        return total


def tree_usage(roots: List[Int]) -> Dict[Int, Tuple[Int, Float64]]:
    """Each root's process tree's resident bytes and CPU seconds (its own
    and its descendants', with what they waited for: so a child's time
    stays counted once it ends), from one pass over /proc; the scheduler
    and `morca worker` sample their runs with it each tick (morca.usage).
    Empty on macOS, which has no /proc: there the runs' usage is what
    `wait4` says at their end."""
    var out = Dict[Int, Tuple[Int, Float64]]()
    comptime if CompilationTarget.is_linux():
        if len(roots) == 0:
            return out^
        var page = Int(external_call["getpagesize", c_int]())
        # _SC_CLK_TCK is 2 on Linux.
        var hz = Int(external_call["sysconf", Int](c_int(2)))
        if hz <= 0:
            hz = 100
        var procs = Dict[Int, PidUsage]()
        var pids: List[String]
        try:
            pids = listdir("/proc")
        except:
            return out^
        for name in pids:
            var pid: Int
            try:
                pid = Int(name)
            except:
                continue
            var u = parse_pid_usage(_read(String("/proc/", pid, "/stat")))
            if u.parent >= 0:
                procs[pid] = u
        var root_of = Dict[Int, Int]()
        for r in roots:
            root_of[r] = r
            out[r] = (0, 0.0)
        var rss = Dict[Int, Int]()
        var ticks = Dict[Int, Int]()
        for e in procs.items():
            # Up the parents to a root, or to init: the ones walked are
            # under the same one.
            var walked = List[Int]()
            var p = e.key
            var found = -1
            while p > 1 and len(walked) < 64:
                if p in root_of:
                    found = root_of.get(p, -1)
                    break
                walked.append(p)
                p = procs.get(p, PidUsage(0, 0, 0)).parent
            for w in walked:
                root_of[w] = found
            if found >= 0:
                rss[found] = rss.get(found, 0) + e.value.rss_pages * page
                ticks[found] = ticks.get(found, 0) + e.value.cpu_ticks
        for r in roots:
            if r in procs:
                out[r] = (rss.get(r, 0), Float64(ticks.get(r, 0)) / Float64(hz))
            else:
                _ = out.pop(r, (0, 0.0))
    return out^


def default_dirs() -> List[String]:
    """The directories a run writes to: the temporary one and dista's."""
    var out: List[String] = [String(getenv("TMPDIR", "/tmp").rstrip("/"))]
    for n in ["DISTA_SPILL_DIR", "DISTA_STORE_DIR"]:
        var d = getenv(n)
        if d:
            out.append(d)
    return out^


def append_line(path: String, line: String) raises:
    """Appends `line` and a newline to the file at `path`."""
    var c = _cstr(path)
    var mode = _cstr("a")
    var f = external_call["fopen", Int](c.unsafe_ptr(), mode.unsafe_ptr())
    if f == 0:
        raise Error("can't open ", path)
    var text = String(line, "\n")
    var n = external_call["fwrite", Int](
        text.unsafe_ptr(), Int(1), text.byte_length(), f
    )
    var closed = external_call["fclose", c_int](f)
    if n != text.byte_length() or closed != 0:
        raise Error("can't write ", path)


def _trim(path: String, keep: Int) raises:
    """Rewrites the file at `path` with its last `keep` lines, if it has more
    than twice that; a reader sees the old file or the new, never half."""
    var text = _read(path)
    var lines = text.splitlines()
    if len(lines) <= 2 * keep:
        return
    var out = String()
    for i in range(len(lines) - keep, len(lines)):
        out.write(lines[i], "\n")
    var tmp = String(path, ".tmp")
    with open(tmp, "w") as f:
        f.write(out)
    var a = _cstr(tmp)
    var b = _cstr(path)
    if external_call["rename", c_int](a.unsafe_ptr(), b.unsafe_ptr()) != 0:
        raise Error("can't replace ", path)


def _parent(path: String) -> String:
    var at = path.rfind("/").or_else(-1)
    return String(path[byte=:at]) if at > 0 else String(".")


def _usage(msg: String) -> Int:
    print(msg)
    print(_USAGE)
    return 2


def sample_main(args: List[String]) -> Int:
    """`sample`, with `args[2:]` its arguments. Never raises: whatever goes
    wrong, the run it watches goes on."""
    var dest = String()
    var root = 0
    var argv0 = String()
    var dirs = default_dirs()
    var seconds = sample_seconds()
    var count = 0
    var keep = 0
    var until = String()
    var cgroup = String()
    var names = String()
    var i = 2
    try:
        while i < len(args):
            if i + 1 >= len(args):
                return _usage(String("sample: ", args[i], " needs a value"))
            var v = args[i + 1]
            if args[i] == "--out":
                dest = v
            elif args[i] == "--pid":
                root = Int(v)
            elif args[i] == "--match":
                argv0 = v
            elif args[i] == "--dirs":
                dirs = List[String]()
                for d in v.split(","):
                    if d.strip():
                        dirs.append(String(d.strip()))
            elif args[i] == "--seconds":
                seconds = Float64(v)
            elif args[i] == "--keep":
                keep = Int(v)
            elif args[i] == "--until":
                until = v
            elif args[i] == "--cgroup":
                cgroup = v
            elif args[i] == "--names":
                names = v
            elif args[i] == "--count":
                count = Int(v)
            else:
                return _usage(String("sample: unknown argument ", args[i]))
            i += 2
    except e:
        return _usage(String("sample: ", e))
    if not dest:
        return _usage("sample needs --out")
    if seconds <= 0:
        return 0
    var upload = 30.0
    try:
        upload = Float64(getenv("MORCA_SAMPLE_UPLOAD_SECONDS", "30"))
    except:
        pass
    var remote = is_remote(dest)
    var path = dest if dest == "-" else stage_of(dest)
    try:
        if dest != "-":
            makedirs(_parent(path), exist_ok=True)
        # A restarted sampler adds to what's there, here or remotely.
        if remote and not exists(path) and location_exists(dest):
            var before = read_location(dest)
            with open(path, "w") as f:
                f.write_bytes(Span(before))
    except e:
        print("morca sample: can't stage", dest, ":", e)
    var s = Sampler(root, argv0, dirs^, cgroup, names)
    var written = 0
    var failed = False
    var start = Float64(perf_counter_ns()) / 1e9
    # The first line at once (a fifth of a second, for the CPU's delta),
    # so a script that waits for it knows there's one, however short its run.
    var due = start + min(seconds, 0.2)
    var uploaded = start
    var dirty = False
    while True:
        var gone = (root > 0 and not alive(root)) or (
            until != "" and exists(until)
        )
        var now = Float64(perf_counter_ns()) / 1e9
        if gone or now >= due:
            var line = s.line()
            try:
                if dest == "-":
                    print(PREFIX, line, sep="", flush=True)
                else:
                    append_line(path, line)
                    dirty = True
                    if keep > 0 and not remote and written % keep == keep - 1:
                        _trim(path, keep)
                failed = False
            except e:
                if not failed:
                    print("morca sample: dropped a line:", e)
                failed = True
            written += 1
            due = max(due + seconds, now + seconds / 2)
        var last = gone or (count > 0 and written >= count)
        if remote and dirty and (last or now - uploaded >= upload):
            try:
                publish(dest)
                dirty = False
            except e:
                print("morca sample: can't upload", dest, ":", e)
            uploaded = now
        if last:
            break
        sleep(min(0.25, max(due - now, 0.01)))
    return 0
