"""One contract for every provider (docs/groups.md): "give run R a worker
of group G, of this size, joined to this head with this token", and "take
it back". A provider is where a placement gets its workers, by name:

| Provider | Placement | Give | Take back |
|---|---|---|---|
| `pool` | `worker:<pool>` | A member's dista worker (`morca._internal.run_cluster`) | Drain, then kill |
| `local` | the local runner | The run's process forks them (`MORCA_WORKERS`, `MORCA_GROUPS`) | The run's end |
| `control` | `control` | The same, `MORCA_CONTROL_WORKERS` with no group | The run's end |
| `kubernetes` | the Kubernetes runner | A worker Pod per worker (`morca._internal.kube`) | The run's end |

Each builds a dista process's environment here, and nowhere else: the
reserved names `DISTA_ROLE`, `DISTA_HEAD`, `DISTA_ADVERTISE`,
`DISTA_TOKEN`, `DISTA_PORT` and `DISTA_GROUP`, the worker's slots, and its
GPUs (`MORCA_GRANT_GPUS`, `CUDA_VISIBLE_DEVICES`). The `ec2` placement isn't
a provider: it is to be retired and ignores groups
(`morca._internal.groups.placement_warning`).

- **pool**: a worker is told its head, address, the run's token and slots
  (`DISTA_WORKER_SLOTS`: the grant's CPUs, or `auto` when the pipeline's
  `env` says so); a member gives up on a head that's gone after
  `DISTA_CONNECT_TIMEOUT`. Its GPUs are those its host handed it.
- **local** and **control**: dista forks the head and workers inside the
  run's process, so morca gives that process only how many workers to fork,
  `MORCA_WORKERS` (control's, `MORCA_CONTROL_WORKERS`; the local runner's
  is the scheduler's own, as before) and `MORCA_GROUPS`, each group's
  fixed count (`gpu=2,io=1`, morca.tasks). The run's GPUs are the run's
  grant, which all its forked workers see.
- **kubernetes**: a worker learns its address from its pod's IP (a
  `fieldRef`), and has no token or slots, as before. One of a group gets
  `DISTA_GROUP`, and its GPUs are those Kubernetes gives the pod
  (`nvidia.com/gpu`), numbered from 0 inside it.
"""

from morca._internal.json import quote

comptime POOL = "pool"
comptime LOCAL = "local"
comptime CONTROL_PROVIDER = "control"
comptime KUBERNETES = "kubernetes"

comptime MEMBER_CONNECT_SECONDS = "10"
"""How long a pool member's dista worker tries a head that's gone."""
comptime GRANT_GPUS = "MORCA_GRANT_GPUS"
comptime CUDA_DEVICES = "CUDA_VISIBLE_DEVICES"
comptime GROUPS = "MORCA_GROUPS"
"""A local run's groups to fork, `name=count,...` (morca.tasks)."""
comptime POD_IP = "status.podIP"


def provider_of(placed: String) raises -> String:
    """The provider a run placed at `placed` gets its workers from: `pool`
    for `worker:<pool>`, else the placement's own name; raises for one that
    has none (`ec2`)."""
    if placed.startswith("worker:"):
        return POOL
    if placed == LOCAL or placed == CONTROL_PROVIDER or placed == KUBERNETES:
        return placed
    raise Error("morca: placement ", placed, " is no provider of workers")


@fieldwise_init
struct EnvVar(Copyable, Equatable, Movable):
    """One variable of a process: `value`, or on Kubernetes the pod's
    field `field` (`status.podIP`)."""

    var name: String
    var value: String
    var field: String

    def text(self) -> String:
        """`NAME=value`, as a spawned process gets it."""
        return String(self.name, "=", self.value)

    def json(self) -> String:
        """A container's `env` entry."""
        if self.field:
            return String(
                '{"name": ',
                quote(self.name),
                ', "valueFrom": {"fieldRef": {"fieldPath": ',
                quote(self.field),
                "}}}",
            )
        return String(
            '{"name": ', quote(self.name), ', "value": ', quote(self.value), "}"
        )


def _var(name: String, value: String) -> EnvVar:
    return EnvVar(name, value, String())


@fieldwise_init
struct ClusterProcess(Copyable, Movable):
    """A dista head or worker of one run's cluster, as a provider starts
    it."""

    var role: String
    """`head` or `worker`."""
    var port: Int
    """The head's port."""
    var head: String
    """A worker's head, `host:port`."""
    var advertise: String
    """Where the others reach a worker; empty on Kubernetes (its pod's
    IP)."""
    var token: String
    """The run's cluster token; empty for none (Kubernetes)."""
    var slots: String
    """`DISTA_WORKER_SLOTS`'s value; empty for none."""
    var member: Bool
    """A pool member, which gives up on a head that's gone."""
    var group: String
    """The worker's group; empty for the workers with no group."""
    var gpus: Bool
    """Whether to say its GPUs (`devices`) at all."""
    var devices: String
    """Its GPUs' indexes as `MORCA_GRANT_GPUS` gives them; empty for none."""

    @staticmethod
    def head_at(port: Int, token: String = "") -> ClusterProcess:
        return ClusterProcess(
            "head", port, "", "", token, "", False, "", False, ""
        )

    @staticmethod
    def worker_of(
        head: String,
        advertise: String = "",
        token: String = "",
        slots: String = "",
        member: Bool = False,
        group: String = "",
    ) -> ClusterProcess:
        return ClusterProcess(
            "worker",
            0,
            head,
            advertise,
            token,
            slots,
            member,
            group,
            False,
            "",
        )


def gpu_env(devices: String) -> List[String]:
    """A process's GPUs, `devices` (`0,2`, empty for none): it sees those
    alone."""
    return [
        String(GRANT_GPUS, "=", devices),
        String(CUDA_DEVICES, "=", devices),
    ]


def pod_devices(gpus: Int) -> String:
    """The GPUs a pod given `gpus` sees, numbered from 0: `0,1`."""
    var out = String()
    for i in range(gpus):
        out.write("," if i else "", i)
    return out^


def cluster_env(provider: String, p: ClusterProcess) raises -> List[EnvVar]:
    """The variables a provider gives `p`, a head or worker of a run's
    cluster. `local` and `control` start none (`local_env`)."""
    if provider != POOL and provider != KUBERNETES:
        raise Error(
            "morca: the ", provider, " provider forks its workers in the run"
        )
    var out = List[EnvVar]()
    if p.role == "head":
        out.append(_var("DISTA_ROLE", "head"))
        out.append(_var("DISTA_PORT", String(p.port)))
        if p.token:
            out.append(_var("DISTA_TOKEN", p.token))
        return out^
    out.append(_var("DISTA_ROLE", "worker"))
    out.append(_var("DISTA_HEAD", p.head))
    if provider == KUBERNETES and not p.advertise:
        out.append(EnvVar("DISTA_ADVERTISE", String(), String(POD_IP)))
    else:
        out.append(_var("DISTA_ADVERTISE", p.advertise))
    if p.token:
        out.append(_var("DISTA_TOKEN", p.token))
    if p.slots:
        out.append(_var("DISTA_WORKER_SLOTS", p.slots))
    if p.member:
        out.append(_var("DISTA_CONNECT_TIMEOUT", MEMBER_CONNECT_SECONDS))
    if p.group:
        out.append(_var("DISTA_GROUP", p.group))
    if p.gpus:
        out.append(_var(GRANT_GPUS, p.devices))
        out.append(_var(CUDA_DEVICES, p.devices))
    return out^


def driver_env(
    provider: String, head: String, token: String = ""
) -> List[EnvVar]:
    """What a run's driver gets to join its cluster's head at `head`; none
    for `local` and `control`, whose driver forks its own."""
    var out = List[EnvVar]()
    if (provider == POOL or provider == KUBERNETES) and head:
        out.append(_var("DISTA_HEAD", head))
        if token:
            out.append(_var("DISTA_TOKEN", token))
    return out^


def local_env(provider: String, workers: Int, groups: String) -> List[String]:
    """What a `local` or `control` run's process gets to fork its workers:
    `MORCA_WORKERS` for control (`workers`; the local runner's process
    inherits the scheduler's), and `MORCA_GROUPS` when it has groups
    (`groups`, `name=count,...`)."""
    var out = List[String]()
    if provider == CONTROL_PROVIDER:
        out.append(String("MORCA_WORKERS=", workers))
    if groups and (provider == LOCAL or provider == CONTROL_PROVIDER):
        out.append(String(GROUPS, "=", groups))
    return out^


def texts(vars: List[EnvVar]) -> List[String]:
    """`vars` as `NAME=value`s, for a spawned process."""
    var out = List[String]()
    for v in vars:
        out.append(v.text())
    return out^


def json_entries(vars: List[EnvVar]) -> String:
    """`vars` as a container's `env` entries, comma-separated."""
    var out = String()
    for i in range(len(vars)):
        out.write(", " if i else "", vars[i].json())
    return out^


def worker_slots(env: List[String], slots: Int) -> String:
    """A pool worker's `DISTA_WORKER_SLOTS`: `auto` if the pipeline's `env`
    asks for it, else `slots` (0: one per core)."""
    for e in env:
        if e == "DISTA_WORKER_SLOTS=auto":
            return "auto"
    return String(slots)
