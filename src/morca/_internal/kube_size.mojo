"""How big a run's pods are on Kubernetes (#560), and what a pod killed for
its memory says.

**Sizes.** The pods that run the pipeline's code, its driver and each of its
dista workers, are sized from the pipeline's `cpus` and `memory_gb`, `auto`
resolved as on the other runners (`morca._internal.recommend`), each pod
asking for the request alone:

| | requests | limits |
|---|---|---|
| `cpus = "MIN..MAX"` | MIN CPUs | MAX CPUs |
| no `cpus` | `MORCA_DRIVER_CPU` (500m), `MORCA_WORKER_CPU` (1) | `MORCA_POD_CPU_LIMIT` (2), at least the request; 0 for none |
| `memory_gb = "MIN..MAX"` | MIN GB | MAX GB |
| no `memory_gb` | `MORCA_POD_MEMORY` (512Mi) | the same |

The head, dista's coordinator, runs none of it: it asks for
`MORCA_HEAD_CPU` (250m) and `MORCA_POD_MEMORY`, limited as a pod without
`cpus` or `memory_gb` is.

**Out of memory.** A pod past its memory limit is killed by the kernel and
says `OOMKilled`; one the kubelet evicted from a node short of memory says
`Evicted`. Either fails the attempts of its run at that start, saying so
(`killed_text`), and the scheduler removes that start's cluster, so the run
starts again as one whose driver died does. A driver's or worker's kill
raises the pipeline's memory (`orca.pipelines.memory_raised_mb`, as on
cgroups, `morca._internal.cgroup`) to `MORCA_RUN_MEMORY_GROWTH` (1.5) times
the limit it was killed at (an eviction: the request it had), at most
`memory_gb`'s maximum: the retry's pods, and the pipeline's later runs',
ask for at least that, requests and limits, until 20 of its runs have
succeeded since. One killed at that maximum already fails, unretried.
"""

from std.os import getenv

from json import Value

from morca._internal.cgroup import raised_mb
from morca._internal.resources import Request, gb_text

comptime OOM_KILLED = "OOMKilled"
comptime EVICTED = "Evicted"


def cpu_millis(s: String) raises -> Int:
    """A CPU quantity, `500m` or `2` or `1.5`, in thousandths."""
    if s.endswith("m"):
        return Int(s[byte = : s.byte_length() - 1])
    return Int(Float64(s) * 1000.0 + 0.5)


def memory_mb(q: String) raises -> Int:
    """A Kubernetes memory quantity, `512Mi`, `2Gi`, `1G` or bytes, in MiB,
    rounded up."""
    var units: List[Tuple[String, Float64]] = [
        ("Ki", 1024.0),
        ("Mi", 1048576.0),
        ("Gi", 1073741824.0),
        ("Ti", 1099511627776.0),
        ("k", 1e3),
        ("M", 1e6),
        ("G", 1e9),
        ("T", 1e12),
    ]
    var bytes = -1.0
    for u in units:
        if q.endswith(u[0]):
            var n = String(q[byte = : q.byte_length() - u[0].byte_length()])
            bytes = Float64(n) * u[1]
            break
    if bytes < 0:
        bytes = Float64(q)
    var mb = bytes / 1048576.0
    var whole = Int(mb)
    return whole + 1 if Float64(whole) < mb else whole


@fieldwise_init
struct PodSize(ImplicitlyCopyable, Movable):
    """One pod's requests and limits: CPU in thousandths, memory in MiB; a
    CPU limit of 0 is none."""

    var cpu_request: Int
    var cpu_limit: Int
    var memory_request_mb: Int
    var memory_limit_mb: Int

    def resources(self) -> String:
        """The container's `resources`, as JSON."""
        var out = String(
            '{"requests": {"cpu": "',
            self.cpu_request,
            'm", "memory": "',
            self.memory_request_mb,
            'Mi"}, "limits": {',
        )
        if self.cpu_limit > 0:
            out.write('"cpu": "', self.cpu_limit, 'm", ')
        out.write('"memory": "', self.memory_limit_mb, 'Mi"}}')
        return out^


@fieldwise_init
struct KubeDefaults(ImplicitlyCopyable, Movable):
    """The runner's sizes for what a pipeline doesn't ask for."""

    var driver_cpu: Int
    var head_cpu: Int
    var worker_cpu: Int
    var cpu_limit: Int
    """`MORCA_POD_CPU_LIMIT`, for a pod without `cpus`; 0 for none."""
    var memory_mb: Int

    @staticmethod
    def from_env() raises -> KubeDefaults:
        """`MORCA_DRIVER_CPU` (500m), `MORCA_HEAD_CPU` (250m),
        `MORCA_WORKER_CPU` (1), `MORCA_POD_CPU_LIMIT` (2) and
        `MORCA_POD_MEMORY` (512Mi)."""
        return KubeDefaults(
            cpu_millis(getenv("MORCA_DRIVER_CPU", "500m")),
            cpu_millis(getenv("MORCA_HEAD_CPU", "250m")),
            cpu_millis(getenv("MORCA_WORKER_CPU", "1")),
            cpu_millis(getenv("MORCA_POD_CPU_LIMIT", "2")),
            memory_mb(getenv("MORCA_POD_MEMORY", "512Mi")),
        )


@fieldwise_init
struct KubeRequests(ImplicitlyCopyable, Movable):
    """What a run's pods ask for in all."""

    var cpu_millis: Int
    var memory_mb: Int


def pods(workers: Int) -> Int:
    """A run's pods: its driver, and its head and workers if it has tasks."""
    return 1 if workers == 0 else 2 + workers


@fieldwise_init
struct KubeSizes(ImplicitlyCopyable, Movable):
    """A start's pods: its driver, head and each worker."""

    var driver: PodSize
    var head: PodSize
    var worker: PodSize

    @staticmethod
    def none() -> KubeSizes:
        """Nothing asked for: off Kubernetes."""
        var z = PodSize(0, 0, 0, 0)
        return KubeSizes(z, z, z)

    def requests(self, workers: Int) -> KubeRequests:
        """What a run with `workers` workers asks for in all: its driver
        alone without tasks, else with its head and workers. That's what
        the vCPU budget weighs and the price counts (`orca.runs.cpu_millis`,
        `pod_memory_mb`)."""
        if workers == 0:
            return KubeRequests(
                self.driver.cpu_request, self.driver.memory_request_mb
            )
        return KubeRequests(
            self.driver.cpu_request
            + self.head.cpu_request
            + workers * self.worker.cpu_request,
            self.driver.memory_request_mb
            + self.head.memory_request_mb
            + workers * self.worker.memory_request_mb,
        )


def _cpu(request: Request, default: Int, limit: Int) -> Tuple[Int, Int]:
    if request.cpus_min > 0:
        return (
            request.cpus_min * 1000,
            max(request.cpus_max, request.cpus_min) * 1000,
        )
    return (default, max(limit, default) if limit > 0 else 0)


def kube_sizes(
    request: Request, ceiling_mb: Int, raised: Int, d: KubeDefaults
) -> KubeSizes:
    """A start's pods, for a pipeline whose request is `request` (`auto`
    resolved), whose `memory_gb` allows `ceiling_mb` at most (its maximum,
    0 for none) and whose memory an out-of-memory kill raised to `raised`
    (0 for none)."""
    var req = d.memory_mb
    var lim = d.memory_mb
    if request.memory_min_mb > 0:
        req = request.memory_min_mb
        lim = max(request.memory_max_mb, req)
    req = max(req, raised)
    lim = max(lim, raised)
    if ceiling_mb > 0:
        req = min(req, ceiling_mb)
        lim = min(lim, ceiling_mb)
    lim = max(lim, req)
    var driver = _cpu(request, d.driver_cpu, d.cpu_limit)
    var worker = _cpu(request, d.worker_cpu, d.cpu_limit)
    var head = _cpu(Request(0, 0, 0, 0), d.head_cpu, d.cpu_limit)
    return KubeSizes(
        PodSize(driver[0], driver[1], req, lim),
        PodSize(head[0], head[1], d.memory_mb, d.memory_mb),
        PodSize(worker[0], worker[1], req, lim),
    )


def kube_requests(workers: Int) raises -> KubeRequests:
    """What a run with `workers` dista workers of a pipeline without `cpus`
    or `memory_gb` asks for, from the runner's variables."""
    return kube_sizes(
        Request(0, 0, 0, 0), 0, 0, KubeDefaults.from_env()
    ).requests(workers)


# ── pods killed ──────────────────────────────────────────────────────────────


@fieldwise_init
struct Killed(Copyable, Movable):
    """Why Kubernetes ended a pod, if for its memory: `OOMKilled`, `Evicted`
    or empty, and what its status says."""

    var reason: String
    var message: String


def pod_killed(pod: Value) -> Killed:
    """Whether `pod` was killed for its memory: a container of it ended
    `OOMKilled`, or the pod was `Evicted`."""
    try:
        var reason = pod.try_at("/status/reason")
        if reason and reason.value().string_value() == EVICTED:
            var m = pod.try_at("/status/message")
            return Killed(
                String(EVICTED),
                m.value().string_value() if m else String(),
            )
        var statuses = pod.try_at("/status/containerStatuses")
        if not statuses:
            return Killed(String(), String())
        for c in statuses.value().array_items():
            for at in [
                "/state/terminated/reason",
                "/lastState/terminated/reason",
            ]:
                var r = c.try_at(String(at))
                if r and r.value().string_value() == OOM_KILLED:
                    return Killed(String(OOM_KILLED), String())
    except:
        pass
    return Killed(String(), String())


def pod_memory(pod: Value, which: StaticString) raises -> Int:
    """Its first container's memory `requests` or `limits`, in MiB; 0 for
    none."""
    var v = pod.try_at(
        String("/spec/containers/0/resources/", which, "/memory")
    )
    return memory_mb(v.value().string_value()) if v else 0


def _mb_text(mb: Int) -> String:
    return String(gb_text(mb), " GB") if mb >= 1024 else String(mb, " MB")


def killed_text(
    k: Killed, pod: String, role: String, at_mb: Int, next_mb: Int
) -> String:
    """An attempt's error after its run's pod `pod` (its `role`) was killed
    for its memory at `at_mb` (an OOM kill's limit, an eviction's request),
    and what its retry asks for (`next_mb`; 0 for the head, which the
    pipeline's memory doesn't size)."""
    var t = String()
    if k.reason == OOM_KILLED:
        t.write(
            "OOMKilled: pod ",
            pod,
            " (the ",
            role,
            ") passed its memory limit, ",
            _mb_text(at_mb),
            ", and Kubernetes killed it",
        )
    else:
        t.write(
            "Evicted: pod ",
            pod,
            " (the ",
            role,
            "), asking for ",
            _mb_text(at_mb),
            ", was evicted",
        )
        if k.message:
            t.write(" (", k.message, ")")
    if next_mb <= 0:
        t.write("; the head's memory is MORCA_POD_MEMORY's")
    elif next_mb > at_mb:
        t.write("; its retry asks for ", _mb_text(next_mb))
    elif k.reason == OOM_KILLED:
        t.write("; that's the most it may ask for (memory_gb's maximum)")
    return t^


def next_memory_mb(
    k: Killed, request_mb: Int, limit_mb: Int, growth_pct: Int, ceiling_mb: Int
) -> Int:
    """What the pipeline asks for after a pod with `request_mb` and
    `limit_mb` was killed as `k` says: `growth_pct` percent of the limit
    after an OOM kill, of the request after an eviction, at most
    `ceiling_mb` (0 for none) and never less."""
    var at = limit_mb if k.reason == OOM_KILLED else request_mb
    return raised_mb(at, growth_pct, ceiling_mb)
