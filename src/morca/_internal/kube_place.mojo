"""Where a run's pods go on Kubernetes (#561): the stack's pull secrets, a
node selector and tolerations for each role, the workers' anti-affinity and
a priority class, from the scheduler's environment.

| Variable | | Example |
|---|---|---|
| `MORCA_KUBE_PULL_SECRET` | Secrets in the runs' namespace that pull their images (`imagePullSecrets`), comma-separated | `ghcr-pull` |
| `MORCA_KUBE_DRIVER_NODE_SELECTOR`, `MORCA_KUBE_HEAD_NODE_SELECTOR`, `MORCA_KUBE_WORKER_NODE_SELECTOR` | the role's `nodeSelector`, `key=value` pairs, comma-separated | `karpenter.sh/capacity-type=on-demand` |
| `MORCA_KUBE_DRIVER_TOLERATIONS`, `MORCA_KUBE_HEAD_TOLERATIONS`, `MORCA_KUBE_WORKER_TOLERATIONS` | the role's `tolerations`, each `key[=value][:effect]` as `kubectl taint` writes them (no value: any), comma-separated | `spot=true:NoSchedule` |
| `MORCA_KUBE_WORKER_ANTI_AFFINITY` | `preferred` or `required`: a run's workers on different nodes (`kubernetes.io/hostname`), if possible or always | `preferred` |
| `MORCA_KUBE_PRIORITY_CLASS` | every run pod's `priorityClassName`, a PriorityClass the cluster has | `morca-runs` |

None is set by default, and a pod spec then has none of these fields, as
before. A bad value stops the scheduler as it starts.
"""

from std.os import getenv

from morca._internal.json import quote


@fieldwise_init
struct Toleration(Copyable, Movable):
    """One `key[=value][:effect]`: `Equal` with a value, else `Exists`; an
    empty effect tolerates every one."""

    var key: String
    var value: String
    var effect: String

    @staticmethod
    def parse(s: String) raises -> Toleration:
        var rest = String(s.strip())
        var effect = String()
        var colon = rest.rfind(":")
        if colon >= 0:
            effect = String(rest[byte = colon + 1 :])
            var head = String(rest[byte=:colon])
            rest = head^
            if (
                effect != "NoSchedule"
                and effect != "PreferNoSchedule"
                and effect != "NoExecute"
            ):
                raise Error(
                    (
                        "a toleration's effect is NoSchedule, PreferNoSchedule"
                        " or NoExecute, not "
                    ),
                    quote(effect),
                    " (",
                    quote(s),
                    ")",
                )
        var value = String()
        var eq = rest.find("=")
        if eq >= 0:
            value = String(rest[byte = eq + 1 :])
            var key = String(rest[byte=:eq])
            rest = key^
        if not rest:
            raise Error("a toleration needs a key: ", quote(s))
        return Toleration(rest^, value^, effect^)

    def json(self) -> String:
        var out = String('{"key": ', quote(self.key))
        if self.value:
            out.write(', "operator": "Equal", "value": ', quote(self.value))
        else:
            out.write(', "operator": "Exists"')
        if self.effect:
            out.write(', "effect": ', quote(self.effect))
        out.write("}")
        return out^


def _items(s: String) -> List[String]:
    var out = List[String]()
    for part in s.split(","):
        if part.strip():
            out.append(String(part.strip()))
    return out^


def node_selector(s: String) raises -> List[Tuple[String, String]]:
    """`key=value,key2=value2` as pairs."""
    var out = List[Tuple[String, String]]()
    for item in _items(s):
        var eq = item.find("=")
        if eq <= 0:
            raise Error("a node selector is key=value pairs, not ", quote(s))
        out.append(
            (
                String(item[byte=:eq].strip()),
                String(item[byte = eq + 1 :].strip()),
            )
        )
    return out^


@fieldwise_init
struct RolePlacement(Copyable, Movable):
    """One role's nodes: its `nodeSelector` and `tolerations`."""

    var selector: List[Tuple[String, String]]
    var tolerations: List[Toleration]

    @staticmethod
    def from_env(role: StaticString) raises -> RolePlacement:
        """`MORCA_KUBE_<ROLE>_NODE_SELECTOR` and `..._TOLERATIONS`."""
        var name = String("MORCA_KUBE_", role, "_NODE_SELECTOR")
        var tol = String("MORCA_KUBE_", role, "_TOLERATIONS")
        var tolerations = List[Toleration]()
        try:
            for t in _items(getenv(tol)):
                tolerations.append(Toleration.parse(t))
        except e:
            raise Error(tol, ": ", e)
        try:
            return RolePlacement(node_selector(getenv(name)), tolerations^)
        except e:
            raise Error(name, ": ", e)


def _role_spec(mut out: String, p: RolePlacement):
    """A role's `nodeSelector` and `tolerations`, if it has them."""
    if p.selector:
        out.write(', "nodeSelector": {')
        for i in range(len(p.selector)):
            out.write(
                ", " if i else "",
                quote(p.selector[i][0]),
                ": ",
                quote(p.selector[i][1]),
            )
        out.write("}")
    if p.tolerations:
        out.write(', "tolerations": [')
        for i in range(len(p.tolerations)):
            out.write(", " if i else "", p.tolerations[i].json())
        out.write("]")


@fieldwise_init
struct KubePlacement(Copyable, Movable):
    """The stack's placement of run pods (the module's variables)."""

    var pull_secrets: List[String]
    var driver: RolePlacement
    var head: RolePlacement
    var worker: RolePlacement
    var worker_anti_affinity: String
    """Empty, `preferred` or `required`."""
    var priority_class: String

    @staticmethod
    def none() -> KubePlacement:
        """Nothing set: pods as before."""
        return KubePlacement(
            List[String](),
            RolePlacement(List[Tuple[String, String]](), List[Toleration]()),
            RolePlacement(List[Tuple[String, String]](), List[Toleration]()),
            RolePlacement(List[Tuple[String, String]](), List[Toleration]()),
            String(),
            String(),
        )

    @staticmethod
    def from_env() raises -> KubePlacement:
        var anti = String(getenv("MORCA_KUBE_WORKER_ANTI_AFFINITY").strip())
        if anti and anti != "preferred" and anti != "required":
            raise Error(
                (
                    "MORCA_KUBE_WORKER_ANTI_AFFINITY is preferred or required,"
                    " not "
                ),
                quote(anti),
            )
        return KubePlacement(
            _items(getenv("MORCA_KUBE_PULL_SECRET")),
            RolePlacement.from_env("DRIVER"),
            RolePlacement.from_env("HEAD"),
            RolePlacement.from_env("WORKER"),
            anti^,
            String(getenv("MORCA_KUBE_PRIORITY_CLASS").strip()),
        )

    def spec(self, role: StaticString, run: Int, start: Int) -> String:
        """The pod spec's fields for a pod of `role` (`driver`, `head` or
        `worker`) of the run's start, as JSON members each after a `, `;
        empty with nothing set."""
        var out = String()
        if self.pull_secrets:
            out.write(', "imagePullSecrets": [')
            for i in range(len(self.pull_secrets)):
                out.write(
                    ", " if i else "",
                    '{"name": ',
                    quote(self.pull_secrets[i]),
                    "}",
                )
            out.write("]")
        if role == "worker":
            _role_spec(out, self.worker)
        elif role == "head":
            _role_spec(out, self.head)
        else:
            _role_spec(out, self.driver)
        if role == "worker" and self.worker_anti_affinity:
            var term = String(
                '{"labelSelector": {"matchLabels": {"orca.run": "',
                run,
                '", "orca.start": "',
                start,
                '", "orca.role": "worker"}}, "topologyKey":',
                ' "kubernetes.io/hostname"}',
            )
            out.write(', "affinity": {"podAntiAffinity": {')
            if self.worker_anti_affinity == "required":
                out.write(
                    '"requiredDuringSchedulingIgnoredDuringExecution": [',
                    term,
                    "]",
                )
            else:
                out.write(
                    '"preferredDuringSchedulingIgnoredDuringExecution":',
                    ' [{"weight": 100, "podAffinityTerm": ',
                    term,
                    "}]",
                )
            out.write("}}")
        if self.priority_class:
            out.write(', "priorityClassName": ', quote(self.priority_class))
        return out^
