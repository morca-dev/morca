"""The knobs of dista's scaling policy, as morca sets them: shared by the
`ec2` placement (`morca._internal.ec2`, over instances) and pools
(`morca._internal.member_demand`, over a run's members by group).

- `MORCA_SCALE_UP_AFTER` (5 s): how long tasks stay ready with no free slot
  before more workers are asked for.
- `MORCA_SCALE_IDLE` (60 s): how long a worker stays idle before it may go.
- `MORCA_SCALE_STEP` (4): the most workers asked for at once, in machines
  (instances on `ec2`, members on a pool).
"""

from std.os import getenv

from dista.scale import Policy


@fieldwise_init
struct ScaleKnobs(Copyable, Movable):
    var up_after: Float64
    var idle: Float64
    var step: Int

    @staticmethod
    def from_env() raises -> ScaleKnobs:
        """The knobs from `MORCA_SCALE_*`, or their defaults."""
        return ScaleKnobs(
            Float64(getenv("MORCA_SCALE_UP_AFTER", "5")),
            Float64(getenv("MORCA_SCALE_IDLE", "60")),
            Int(getenv("MORCA_SCALE_STEP", "4")),
        )

    def policy(self, lo: Int, hi: Int, per: Int = 1) -> Policy:
        """The policy over dista worker processes: `lo` to `hi` of them, and
        `step` machines of `per` processes each at most at once."""
        return Policy(
            min_workers=lo,
            max_workers=hi,
            up_after=self.up_after,
            idle_before_down=self.idle,
            max_step=self.step * per,
        )
