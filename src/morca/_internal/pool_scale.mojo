"""The pool autoscaler (#267): machines for the pools morca.toml declares
(`morca._internal.pool_config`), made and removed by the leading scheduler every
`MORCA_POOL_SCALE_SECONDS` (15).

**Demand.** A pool needs a machine while runs of its pipelines (placement
`worker:<pool>`, not paused) have been queued `MORCA_POOL_GROW_AFTER`
seconds (20) that a worker could start: no more of a pipeline's than
`max_runs` less its running ones, and its fill runs. Workers already in
the pool take what they have room for first; what's left waiting is the
demand.

**GPU machines.** A mixed pool lists its types with GPUs under
`gpu_machines` (docs/groups.md). The members of groups that ask for GPUs
are their demand, apart from the rest, which is the demand of `machines`.
Each kind grows and shrinks by its own demand, with a trying state and a
status of its own (`orca.pools.gpu_*`): a GPU machine is never made for
work that needs none, and an idle one is removed once no member wants a
GPU, whatever the other demand. `max_machines` caps both together.

**Growing.** While there's demand, no machine of the pool is still booting
(made, its worker not yet seen) and it has fewer than `max_machines`, the
autoscaler makes one, at most once every `MORCA_POOL_TRY_SECONDS` (60):

- it tries the type it's on (the first, to start with) in each location in
  turn; the first that the provider has is made;
- a type the worker image has no variant for (`morca._internal.registry`: the
  machine's architecture, as the provider says it, isn't among the
  image's) is skipped, saying so;
- when no location has the type, it keeps trying it until the type's
  `wait` has passed since it started, then moves to the next; the last has
  no wait and is tried for as long as there's demand;
- once one is made, or the demand goes, it starts again from the first.

The machine is named `orca-pool-<pool>-<n>`, labelled with the pool and this
stack's id (`orca.stack_identity`, so a project several stacks share keeps
them apart), and booted as a worker (`morca._internal.pool_boot`) with a token of its
own. `orca.pools.status` says what the last attempt came to.

**Shrinking.** A machine is removed (its token revoked, then the machine
deleted, then its row ended with why) when:

- it has run nothing for its pool's `idle_seconds` and the pool has no
  demand;
- its pool is no longer in morca.toml, once it's idle;
- its worker never showed up within `MORCA_POOL_BOOT_SECONDS` (900), or went
  silent for `MORCA_POOL_LOST_SECONDS` (300): its runs are queued again as
  any lost worker's are (`morca._internal.pool_runs`);
- it was made for another worker image than the scheduler's
  (`MORCA_WORKER_IMAGE`, which a deploy changes), once it's idle (#356);
- its worker was asked to drain (`morca host drain`, #220), once it's
  idle.

**Draining.** A machine runs the image it was made for (the boot answer
gives the one `orca.pool_machines.image` recorded), and its container keeps
running it. One whose image isn't the scheduler's drains: its worker is
given no more runs (`/api/worker/claim` refuses it), the runs it has
finish, and it's removed once idle, whatever the demand and without waiting
for `idle_seconds`. While busy it still counts toward `max_machines`, so the
cap holds; its replacement is made once it's gone, as for any demand.

**Strays.** A machine of the provider's with the pool's and this stack's
labels that `orca.pool_machines` doesn't have live (made, but the row
wasn't written) is deleted.
"""

from std.os import getenv
from std.time import perf_counter_ns

from json import loads
import morca._internal.db.pools as pools_db
from morca._internal.db.pools import LiveMachine

from morca._internal.machines import MachineSpec, Provider
from morca._internal.pool_boot import CREATED_BY, WORKER_IMAGE, boot_script
from morca._internal.pool_config import NO_WAIT
from morca._internal.registry import Registry
from morca._internal.state import State
from morca._internal.tokens import token_hash
from morca._internal.workers import create_worker_token


def _seconds(name: String, default: Float64) -> Float64:
    var v = getenv(name)
    if not v:
        return default
    try:
        return max(Float64(v), 0.0)
    except:
        return default


def scale_seconds() -> Float64:
    return _seconds("MORCA_POOL_SCALE_SECONDS", 15.0)


def stack_id(mut db: State) raises -> String:
    """This stack's id, made once (`orca.stack_identity`): the label that
    marks its machines as its own."""
    return pools_db.stack_id(db.conn)


def demand(
    mut db: State, pool: String, after: Float64
) raises -> Tuple[Int, Int]:
    """What `pool` needs machines for, without GPUs and with
    (`pools_db.demand`): the runs of its pipelines queued at least `after`
    seconds that a worker could start, per pipeline at most `max_runs` less
    its running ones, and its fill runs, and the members its running runs
    that spread (#268) still want, once they've run `after` seconds; those
    of groups that ask for GPUs apart."""
    return pools_db.demand(db.conn, pool, after)


def _live(mut db: State, pool: String) raises -> List[LiveMachine]:
    return pools_db.live_machines(db.conn, pool)


def _status(
    mut db: State, pool: String, text: String, gpu: Bool = False
) raises:
    pools_db.set_status(db.conn, pool, text, gpu)


def _remove(
    mut db: State, provider: Provider, m: LiveMachine, why: String
) raises -> Bool:
    """Revokes `m`'s token, deletes it at the provider, and ends its row
    with `why`. False (left for the next pass) if the provider refused."""
    if m.worker > 0:
        pools_db.revoke_worker(db.conn, m.worker)
    if m.provider_id:
        try:
            _ = provider.delete(m.provider_id)
        except e:
            print("morca: can't remove machine", m.name, ":", e)
            return False
    pools_db.end_machine(db.conn, m.id, why)
    print("removed machine", m.name, String("(", why, ")"))
    return True


def _image_of(m: LiveMachine) -> String:
    """The image `m` was made to run, or that it has none recorded."""
    return m.image if m.image else String("an image morca didn't record")


@fieldwise_init
struct _Pool(Copyable, Movable):
    var name: String
    var provider: String
    var machines: List[Tuple[String, Int]]
    var locations: List[String]
    var max_machines: Int
    var idle_seconds: Int
    var configured: Bool
    var trying: Int
    var trying_for: Float64
    """Seconds since it started trying `trying`; -1 if it isn't."""
    var since_try: Float64
    """Seconds since the last attempt; -1 for none."""
    var gpu_machines: List[Tuple[String, Int]]
    var gpu_trying: Int
    var gpu_trying_for: Float64
    var gpu_since_try: Float64

    def types(self, gpu: Bool) -> List[Tuple[String, Int]]:
        """Its `gpu_machines` for `gpu`, else its `machines`."""
        return self.gpu_machines.copy() if gpu else self.machines.copy()

    def trying_of(self, gpu: Bool) -> Tuple[Int, Float64, Float64]:
        """The type it's trying of that kind, since when, and its last try."""
        if gpu:
            return (self.gpu_trying, self.gpu_trying_for, self.gpu_since_try)
        return (self.trying, self.trying_for, self.since_try)


def _choices(text: String) raises -> List[Tuple[String, Int]]:
    var machines = List[Tuple[String, Int]]()
    for m in loads(text).array_items():
        var wait = NO_WAIT
        if "wait" in m and m["wait"].is_int():
            wait = Int(m["wait"].int_value())
        machines.append((m["type"].string_value(), wait))
    return machines^


def _pools(mut db: State) raises -> List[_Pool]:
    """The pools morca.toml has, then those it no longer has that still have
    machines live."""
    var out = List[_Pool]()
    for r in pools_db.pool_rows(db.conn):
        var machines = _choices(r.machines)
        var locations = List[String]()
        for l in loads(r.locations).array_items():
            locations.append(l.string_value())
        out.append(
            _Pool(
                r.name,
                r.provider,
                machines^,
                locations^,
                r.max_machines,
                r.idle_seconds,
                r.configured,
                r.trying,
                r.trying_for,
                r.since_try,
                _choices(r.gpu_machines),
                r.gpu_trying,
                r.gpu_trying_for,
                r.gpu_since_try,
            )
        )
    return out^


def _sweep(mut db: State, provider: Provider, pool: String) raises:
    """Deletes the provider's machines of `pool` and this stack that no live
    row has."""
    var known = Dict[String, Bool]()
    for id in pools_db.provider_ids(db.conn, pool):
        known[id] = True
    for m in provider.machines(pool):
        if m.id not in known:
            _ = provider.delete(m.id)
            print("deleted stray machine", m.name, "of pool", pool)


struct PoolScaler(Movable):
    """The autoscaler's state between passes: when it last ran, this stack's
    id, and the worker image's architectures (read once per image)."""

    var last: Float64
    var owner: String
    var image: String
    var arches: List[String]
    var arches_why: String
    var arches_at: Float64
    """When they were read (`perf_counter_ns` seconds): a tag can be
    pushed again, so they're read again after `MORCA_POOL_IMAGE_SECONDS`
    (600)."""

    def __init__(out self):
        self.last = -1.0e18
        self.owner = String()
        self.image = String()
        self.arches = List[String]()
        self.arches_why = String()
        self.arches_at = 0.0

    def due(mut self, now: Float64) -> Bool:
        if now - self.last < scale_seconds():
            return False
        self.last = now
        return True

    def _image_arches(mut self, image: String) -> Bool:
        """Reads `image`'s architectures if it's new; False if they can't be
        read (`arches_why`), when every type is tried."""
        var now = Float64(perf_counter_ns()) / 1e9
        if image == self.image and now - self.arches_at < _seconds(
            "MORCA_POOL_IMAGE_SECONDS", 600.0
        ):
            return len(self.arches) > 0
        self.image = image
        self.arches_at = now
        self.arches = List[String]()
        self.arches_why = String()
        try:
            self.arches = Registry.from_env().arches(image)
        except e:
            self.arches_why = String(e)
            print(
                "morca: pools: can't tell the worker image's architectures:", e
            )
        return len(self.arches) > 0

    def scale(mut self, mut db: State) raises:
        """One pass over every pool."""
        if not self.owner:
            self.owner = stack_id(db)
        for p in _pools(db):
            try:
                self._pool(db, p)
            except e:
                print("morca: can't scale pool", p.name, ":", e)
                _status(db, p.name, String("error: ", e))

    def _pool(mut self, mut db: State, p: _Pool) raises:
        var provider = Provider.of(p.provider, self.owner)
        var wants = demand(
            db, p.name, _seconds("MORCA_POOL_GROW_AFTER", 20.0)
        ) if p.configured else (0, 0)
        var live = _live(db, p.name)
        var boot_s = _seconds("MORCA_POOL_BOOT_SECONDS", 900.0)
        var lost_s = _seconds("MORCA_POOL_LOST_SECONDS", 300.0)
        var kept = 0
        var booting = 0
        var booting_gpu = 0
        # The image a machine made now would run: one made for another
        # (before a deploy) drains, and is removed once idle (#356).
        var image = getenv(WORKER_IMAGE)
        for m in live:
            if not m.seen and m.age >= boot_s:
                _ = _remove(
                    db,
                    provider,
                    m,
                    String("never joined in ", Int(boot_s), " s"),
                )
                continue
            if m.seen and m.silent >= lost_s:
                _ = _remove(
                    db,
                    provider,
                    m,
                    String("its worker went silent for ", Int(lost_s), " s"),
                )
                continue
            if not m.seen:
                if m.gpu:
                    booting_gpu += 1
                else:
                    booting += 1
                kept += 1
                continue
            # Each kind of machine by its own demand (docs/groups.md).
            var want = wants[1] if m.gpu else wants[0]
            var outdated = Bool(image) and m.image != image
            if outdated != m.draining:
                pools_db.drain(db.conn, m.id, outdated)
                if outdated:
                    print(
                        "draining machine",
                        m.name,
                        "of pool",
                        p.name,
                        String(
                            "(it runs ",
                            _image_of(m),
                            ", the pool's image is now ",
                            image,
                            ")",
                        ),
                    )
            if m.busy:
                if m.idle_for >= 0.0:
                    pools_db.clear_idle(db.conn, m.id)
                kept += 1
                continue
            if m.idle_for < 0.0:
                pools_db.mark_idle(db.conn, m.id)
            if not p.configured:
                if _remove(db, provider, m, "its pool left morca.toml"):
                    continue
            elif m.drained and _remove(
                db, provider, m, "drained on request (morca host drain)"
            ):
                continue
            elif outdated and _remove(
                db,
                provider,
                m,
                String(
                    "replaced: it ran ", _image_of(m), ", the pool runs ", image
                ),
            ):
                continue
            elif (
                want == 0
                and m.idle_for >= Float64(p.idle_seconds)
                and _remove(
                    db, provider, m, String("idle ", p.idle_seconds, " s")
                )
            ):
                continue
            kept += 1
        _sweep(db, provider, p.name)
        if not p.configured:
            return
        if self._kind(db, provider, p, False, wants[0], booting, kept):
            kept += 1
        _ = self._kind(db, provider, p, True, wants[1], booting_gpu, kept)

    def _kind(
        mut self,
        mut db: State,
        provider: Provider,
        p: _Pool,
        gpu: Bool,
        want: Int,
        booting: Int,
        kept: Int,
    ) raises -> Bool:
        """Grows `p`'s machines of one kind (with GPUs for `gpu`) for its
        demand, `want`, with `booting` of them not joined yet and `kept`
        machines of both live; whether it made one."""
        var t = p.trying_of(gpu)
        if want == 0:
            if gpu or t[0] > 0 or t[1] >= 0.0:
                pools_db.stop_trying(db.conn, p.name, gpu)
            return False
        if gpu and len(p.gpu_machines) == 0:
            _status(
                db,
                p.name,
                String(
                    "can't grow: ",
                    want,
                    " member" if want == 1 else " members",
                    " of groups that ask for GPUs, and the pool has no",
                    " gpu_machines",
                ),
                True,
            )
            return False
        if booting > 0 or kept >= p.max_machines:
            return False
        var every = _seconds("MORCA_POOL_TRY_SECONDS", 60.0)
        if t[2] >= 0.0 and t[2] < every:
            return False
        return self._grow(db, provider, p, gpu)

    def _grow(
        mut self, mut db: State, provider: Provider, p: _Pool, gpu: Bool
    ) raises -> Bool:
        """Tries to make one machine for `p` of one kind (with GPUs for
        `gpu`), by the wait rule over the types the worker image runs on;
        whether it made one."""
        pools_db.mark_try(db.conn, p.name, gpu)
        var machines = p.types(gpu)
        var tried = p.trying_of(gpu)
        var image = getenv(WORKER_IMAGE)
        var remote = getenv("MORCA_POOL_REMOTE", getenv("MORCA_UI_URL"))
        if not image or not remote:
            _status(
                db,
                p.name,
                String(
                    "can't grow: the scheduler needs ",
                    WORKER_IMAGE,
                    " and MORCA_UI_URL",
                ),
                gpu,
            )
            return False
        # The types the image runs on, in order; the others said.
        var checked = self._image_arches(image)
        var usable = List[Int]()
        var skipped = String()
        for k in range(len(machines)):
            var t = machines[k][0]
            if checked:
                var arch = provider.arch(t)
                if arch not in self.arches:
                    skipped.write(
                        t, " skipped: ", image, " has no linux/", arch, "; "
                    )
                    continue
            usable.append(k)
        if len(usable) == 0:
            _status(
                db,
                p.name,
                String(
                    skipped, "can't grow: the image runs on none of its types"
                ),
                gpu,
            )
            return False
        # The type it's on: the one it was trying, else the next usable one
        # after it, else back to the first.
        var at = -1
        for u in range(len(usable)):
            if usable[u] >= tried[0]:
                at = u
                break
        var trying_for = max(tried[1], 0.0)
        if at < 0 or usable[at] != tried[0]:
            trying_for = 0.0
            if at < 0:
                at = 0
        var locations = p.locations.copy()
        if len(locations) == 0:
            locations.append("")
        # A type refused for the project's quota: the next usable type may
        # fit, this pass (waiting doesn't free quota); every location shares
        # the quota, so it isn't tried in the others.
        var i: Int
        var t: String
        var wait: Int
        while True:
            i = usable[at]
            t = machines[i][0]
            wait = machines[i][1]
            var quota_hit = False
            for loc in locations:
                var made = self._make(
                    db, provider, p.name, t, loc, image, remote, gpu
                )
                if made[0]:
                    pools_db.grew(
                        db.conn, p.name, String(skipped, made[1]), gpu
                    )
                    return True
                if made[3]:
                    skipped.write(t, " refused for quota: ", made[1], "; ")
                    quota_hit = True
                    break
                if not made[2]:
                    # A refusal that isn't stock: say it, try again later.
                    pools_db.refused(
                        db.conn, p.name, i, String(skipped, made[1]), gpu
                    )
                    return False
            if not quota_hit:
                break
            if at + 1 >= len(usable):
                _status(
                    db,
                    p.name,
                    String(
                        skipped,
                        "can't grow: the project's quota fits none of its",
                        " types",
                    ),
                    gpu,
                )
                return False
            at += 1
            trying_for = 0.0
        var places = String(" in ", ", ".join(p.locations)) if len(
            p.locations
        ) else String()
        var last = at == len(usable) - 1
        if wait != NO_WAIT and trying_for >= Float64(wait) and not last:
            var next = usable[at + 1]
            pools_db.try_next(
                db.conn,
                p.name,
                next,
                String(
                    skipped,
                    "no ",
                    t,
                    places,
                    " for ",
                    wait,
                    " s: trying ",
                    machines[next][0],
                    " next",
                ),
                gpu,
            )
            return False
        var left = String(
            " (", Int(trying_for), " of ", wait, " s)"
        ) if wait != NO_WAIT and not last else String(
            " (the last: keeps trying)"
        )
        pools_db.keep_trying(
            db.conn,
            p.name,
            i,
            usable[at] != tried[0],
            String(skipped, "waiting: no ", t, places, " yet", left),
            gpu,
        )
        return False

    def _make(
        mut self,
        mut db: State,
        provider: Provider,
        pool: String,
        machine_type: String,
        location: String,
        image: String,
        remote: String,
        gpu: Bool = False,
    ) raises -> Tuple[Bool, String, Bool, Bool]:
        """Makes one machine: (made, what it came to, out of stock, refused
        for quota)."""
        var id = pools_db.next_machine_id(db.conn)
        # orca-pool-<pool>-<n>: plainly a pool's, beside the stack's own.
        var name = String("orca-pool-", pool.replace("_", "-"), "-", id)
        var issued = create_worker_token(
            db, pool, name, 30, String(CREATED_BY, pool)
        )
        var worker = pools_db.worker_id(db.conn, token_hash(issued.token))
        var script = boot_script(
            remote,
            pool,
            name,
            issued.token,
            getenv("MORCA_POOL_WORKER_COMMAND"),
            gpu,
        )
        var arch = String()
        try:
            arch = provider.arch(machine_type)
        except:
            pass
        var got = provider.create(
            MachineSpec(name, machine_type, location, script, pool)
        )
        if not got.ok:
            # Nothing was made: the token goes with it.
            pools_db.delete_worker(db.conn, worker)
            return (
                False,
                String(
                    "can't make ", machine_type, " in ", location, ": ", got.why
                ),
                got.no_stock,
                got.quota(),
            )
        pools_db.add_machine(
            db.conn,
            id,
            pool,
            provider.kind,
            name,
            machine_type,
            arch,
            location,
            got.id,
            got.address,
            worker,
            image,
            gpu,
        )
        var what = String("made ", name, ": ", machine_type)
        if gpu:
            what.write(" (GPUs)")
        if location:
            what.write(" in ", location)
        print("pool", pool, what)
        return (True, what^, False, False)
