"""A run's dista cluster over several workers of its pool (#268,
`morca._internal.run_cluster`), as its page and JSON show it: the worker that started
it, holding its head, then each worker that joined it, with their grants
and when and why each ended (`morca._internal.db.run_view.cluster_rows`);
and how many members of each kind it wants (`cluster_wants`).
"""

import morca._internal.db.run_cluster as cluster_db
import morca._internal.db.run_view as run_db
from morca._internal.db.run_view import ClusterRow

from morca._internal.groups import parse_groups
from morca._internal.member_wants import Kind, kinds_of
from morca._internal.run_cluster import live_by_group
from morca._internal.state import State


def cluster_rows(mut db: State, run: Int) raises -> List[ClusterRow]:
    """Run `run`'s cluster: its head at its current start, if it spread,
    then every member it had, each start's, in the order they joined. Empty
    for a run on one machine."""
    return run_db.cluster_rows(db.conn, run)


@fieldwise_init
struct ClusterWants(Copyable, Movable):
    """What a run's cluster wants, by kind of member, at its current start
    (`morca._internal.member_wants.kinds_of`), and when its head's demand
    last came (empty for never: each kind wants its MIN)."""

    var kinds: List[Kind]
    var demand_at: String

    @staticmethod
    def none() -> ClusterWants:
        return ClusterWants(List[Kind](), String())


def cluster_wants(mut db: State, run: Int) raises -> ClusterWants:
    """Run `run`'s kinds of members with what each wants and has; none for
    a run without a head."""
    var got = cluster_db.kinds_row(db.conn, run)
    if not got:
        return ClusterWants.none()
    ref k = got.value()
    return ClusterWants(
        kinds_of(
            k.lo,
            k.hi,
            parse_groups(k.groups),
            live_by_group(k.decided),
            live_by_group(k.live),
        ),
        k.demand_at,
    )
