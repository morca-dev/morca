"""What a run on Kubernetes costs (#564): a price per vCPU-hour and per
GiB-hour, set for the stack, applied to what the run's pods ask for.

    MORCA_KUBE_PRICE_VCPU_HOUR=0.04    # US dollars a vCPU an hour
    MORCA_KUBE_PRICE_GB_HOUR=0.005     # US dollars a GiB of memory an hour

morca can't see what a cluster's nodes cost, so the stack says what a
pod's requests cost instead: the cluster's node price spread over what
the nodes hold, or a managed cluster's per-pod rates (GKE Autopilot and
EKS Fargate bill vCPU-hours and GiB-hours). A run's price an hour is the
CPU its pods ask for (`orca.runs.cpu_millis`) times the vCPU price, plus
their memory (`orca.runs.pod_memory_mb`) times the GiB price, and its cost
is that times how long it ran. With one of the two set, the other counts
nothing; with neither (or a value that isn't a number), Kubernetes runs
have no price, and a fill with `fill_budget_per_day` starts no run there
(`morca._internal.fill`), as before. The fill, the watchdog's `cost` rule
(`morca._internal.watchdog`) and the run page all price runs this way.

The requests are the Kubernetes runner's (`morca._internal.kube_size`):
each pod's, from the pipeline's `cpus` and `memory_gb` or the runner's
defaults, a driver alone for a run without dista tasks and a driver, a head
and its workers for one with them.
"""

from std.os import getenv


comptime VCPU_HOUR = "MORCA_KUBE_PRICE_VCPU_HOUR"
comptime GB_HOUR = "MORCA_KUBE_PRICE_GB_HOUR"
comptime PRICE_HINT = (
    "set MORCA_KUBE_PRICE_VCPU_HOUR and MORCA_KUBE_PRICE_GB_HOUR to price them"
)
"""What an unpriced Kubernetes run's reason says to do."""


@fieldwise_init
struct KubePrice(ImplicitlyCopyable, Movable):
    """US dollars a vCPU-hour and a GiB-hour; -1 for one that isn't set."""

    var vcpu_hour: Float64
    var gb_hour: Float64

    def priced(self) -> Bool:
        """Whether either price is set."""
        return self.vcpu_hour >= 0 or self.gb_hour >= 0

    def hourly(self, cpu_millis: Int, memory_mb: Int) -> Float64:
        """US dollars an hour of pods asking for `cpu_millis` thousandths
        of a vCPU and `memory_mb` MiB in all; -1 when unpriced."""
        if not self.priced():
            return -1.0
        return (
            max(self.vcpu_hour, 0.0) * Float64(cpu_millis) / 1000.0
            + max(self.gb_hour, 0.0) * Float64(memory_mb) / 1024.0
        )

    def cost(
        self, cpu_millis: Int, memory_mb: Int, seconds: Float64
    ) -> Float64:
        """US dollars of those pods for `seconds`; -1 when unpriced."""
        var h = self.hourly(cpu_millis, memory_mb)
        if h < 0:
            return -1.0
        return h * max(seconds, 0.0) / 3600.0


def _price(name: StaticString) -> Float64:
    var v = getenv(name)
    if not v:
        return -1.0
    try:
        var f = Float64(v)
        return f if f >= 0 else -1.0
    except:
        return -1.0  # not a number: unpriced, so a budget fails closed


def kube_price() -> KubePrice:
    """The stack's prices, from the environment."""
    return KubePrice(_price(VCPU_HOUR), _price(GB_HOUR))


def cost_text(dollars: Float64) -> String:
    """`$1.23`, or `$0.0042` under a dollar, where cents would read 0."""
    if dollars >= 1.0:
        var c = Int(dollars * 100.0 + 0.5)
        return String("$", c // 100, ".", String(c % 100 + 100)[byte=1:])
    var m = Int(dollars * 10000.0 + 0.5)
    return String("$0.", String(m % 10000 + 10000)[byte=1:])
