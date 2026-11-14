"""Starting runs (`morca._internal.scheduler`): due retries, dead runs and queued ones,
within `max_runs`, memory pressure, grants and the vCPU budget; and a
control-placed run's process.
"""

from std.os import makedirs
from postgres import Transaction
from morca._internal.cgroup import (
    Cgroups,
    raised_request,
)
from morca._internal.control import (
    CONTROL,
    control_stage,
    fetch_secret,
    pool_of,
    pressure_reason,
    run_env,
    secrets_env,
    slots_reason,
)
from morca._internal.fill import (
    FillStatus,
    fill_status,
)
from morca._internal.system import system_now
from morca._internal.db.batches import mark_batch
import morca._internal.db.starting as starting_db
from morca._internal.db.live import hold_behind
from morca._internal.kube import (
    RunSpec,
    cpu_millis,
)
from morca._internal.logs import (
    is_remote,
    run_dir,
    stage_of,
)
from morca._internal.proc import spawn
from morca._internal.sample import (
    metrics_location,
    sample_seconds,
)
from morca._internal.resources import (
    Grant,
    admit,
    run_env as grant_env,
)
from morca._internal.pressure import pressure_env
from morca._internal.recommend import (
    DEFAULT,
    RunRequest,
)
from morca._internal.usage import Meter
from morca._internal.scheduler import (
    AUTO_ONE_AT_A_TIME,
    Scheduler,
    _BUDGET_LOCK,
    _CONTROL_LOCK,
    _ControlProc,
    _HOST_LOCK,
)
from morca._internal.registered import (
    Registered,
    _ec2_spec,
    fill_pipeline,
    recorded_cpus,
    recorded_memory_gb,
    run_request,
    say_capped,
    with_cap,
)
from morca._internal.pool_runs import (
    _fill_for_workers,
    _requeue_for_workers,
    _requeue_orphans,
)


def _taken(
    mut tx: Transaction,
    p: Registered,
    control: Bool,
    hold: String,
    stale: Float64,
    dead: String,
) raises -> String:
    """`hold`, why `p`'s runs wait for room on this host, naming the
    pipeline of a higher priority whose runs hold it, if one does (#421):
    "waiting: for capacity (gharchive, priority 10): needs 2 GB, ...". Of
    the control slots with `control`, else of the grants."""
    var ahead = starting_db.ahead_on_host(tx, p.priority, control, stale, dead)
    if not ahead:
        return hold
    ref a = ahead.value()
    var why = String(hold.removeprefix("waiting: ").removeprefix("held: "))
    return String(
        "waiting: for capacity (", a[0], ", priority ", a[1], "): ", why
    )


def _start(
    mut self: Scheduler, p: Registered, now: Int64, fill: Bool = False
) raises:
    """Starts queued runs, retries that are due and runs whose process
    died, up to `max_runs` live at once; none while `p` is paused, when
    they wait (runs already going go on). A control-placed pipeline's
    runs start here (`morca._internal.control`), within the control instance's
    limits; a queued run those hold, or that's placed on a runner this
    scheduler hasn't, is `held` with the reason. The startable runs go
    oldest first, by id, so a due retry goes before newer runs.

    With `fill`, the same for its fill runs (trigger `fill`), up to
    `fill_max_runs` beside the others: due retries first, then new
    runs over the partitions `morca._internal.fill.fill_status` gives, within its
    window and budget."""
    var pool = pool_of(p.placement)
    if pool:
        # A remote worker of the pool starts them (orca.workers).
        if fill:
            _fill_for_workers(self, p, now, pool)
        else:
            _requeue_for_workers(self, p, now, pool)
        return
    var dead = self._dead("$2")
    var control = p.placement == CONTROL
    var placed = String(CONTROL) if control else (
        String("ec2") if self.ec2 else (
            String("kubernetes") if self.runner else String("local")
        )
    )
    var hold = String()
    if p.placement == "ec2" and not self.ec2:
        hold = String(
            "held: placed on ec2, but this scheduler's runner",
            " (MORCA_RUNNER) is ",
            placed,
        )
    var pressure = String()
    if control:
        try:
            pressure = pressure_reason(system_now(self.db))
        except e:
            print("morca: can't read the control instance's samples:", e)
    if not control and not hold and (self.runner or self.ec2) and not p.image:
        if fill:
            return  # said once, by the pass for its other runs
        print(
            "morca: pipeline",
            p.name,
            "has no image (morca register --image), so its runs wait",
        )
        return
    # On EC2 with the warm pool, the keys of the instances its runs may
    # take, and whether some are still on their way to the pool from a
    # run that just ended: then nothing starts this tick, so the next
    # run takes them rather than new ones.
    var keys = List[String]()
    var settling = False
    if self.ec2 and not control:
        keys = self.ec2.value().pool_keys(_ec2_spec(p, 0, 0, False))
        settling = self.ec2.value().settling(self.db, keys)
    # Its request on this host (morca.resources), `auto` learned from its
    # runs (morca.recommend): resolved here, once for the starts this
    # pass makes, each granted from it for its life.
    var sized = RunRequest.none()
    if control or placed == "local":
        sized = run_request(
            self.db, p, self.room.cpus, self.room.memory_mb, "this host's most"
        )
        say_capped(self.db, p, sized)
    var tx = self.db.conn.begin()
    starting_db.lock_pipeline(tx, p.name)
    starting_db.lock_runs(tx, p.name)
    # A run of a scheduler instance that's gone, whose heartbeat is
    # stale, is queued again whatever its trigger, as a dead worker's
    # is; one its live instance still holds isn't dead
    # (morca.live.held_sql), so nothing below ends or restarts it.
    var lost = List[Tuple[Int, String]]()
    var local = control or placed == "local"
    if not fill:
        lost = _requeue_orphans(self, tx, p)
        self._end_dead(tx, p, dead)
    var live = starting_db.live_count(tx, p.name, self.stale, dead, fill)
    var free = 0 if p.paused or settling or hold else p.max_runs - live
    var status = Optional[FillStatus](None)
    if fill:
        status = fill_status(
            tx,
            fill_pipeline(
                p,
                placed,
                Int(self.ec2.value().pool_seconds) if self.ec2 else 0,
            ),
            now,
            p.run_retries,
        )
        free = 0 if settling or hold else status.value().slots
    var need = 0
    if control:
        need = 0  # no instance: nothing of the budget
    elif self.runner:
        need = self.runner.value().cpu_of(p.workers)
    elif self.ec2:
        need = self.ec2.value().cpu_of(
            p.workers > 0, p.head_type, p.worker_type, p.workers
        )
    if control and free > 0:
        if pressure:
            hold = pressure
            free = 0
        else:
            # Across pipelines: one start at a time counts the slots.
            starting_db.xact_lock(tx, _CONTROL_LOCK)
            var used = starting_db.control_running(
                tx, self.stale, self._dead("$1")
            )
            if used >= self.limits.max_runs:
                hold = _taken(
                    tx,
                    p,
                    True,
                    slots_reason(used, self.limits.max_runs),
                    self.stale,
                    self._dead("$1"),
                )
                free = 0
            else:
                free = min(free, self.limits.max_runs - used)
    # Memory pressure (orca.pressure): on this host, no start while it's
    # over the limit, but one at a time once a hold has lasted its
    # grace with none of morca's runs going.
    if (control or placed == "local") and free > 0 and not hold:
        var allowed = self.admission.allows(self._idle())
        if allowed == 0:
            hold = self.admission.hold
            free = 0
        elif allowed > 0:
            free = min(free, allowed)
    # A request (morca.resources): on this host, a start only if its
    # minimum fits what the running runs weren't granted, each with its
    # grant. A pipeline without one is started as ever.
    var request = sized.request
    if request.memory_min_mb > 0:
        # At least what an out-of-memory kill raised it to.
        request.memory_min_mb = raised_request(
            request.memory_min_mb,
            request.memory_max_mb,
            p.memory_raised_mb,
        )
    # max_runs = "auto" (#266): how many follows the host's room, which
    # admission below weighs; with no request to weigh yet (nothing
    # declared, nothing learned), one run at a time.
    if (
        ((p.max_runs_auto and not fill) or (p.fill.max_runs_auto and fill))
        and local
        and free > 0
        and not request.any()
    ):
        if live > 0:
            free = 0
            if not hold:
                hold = String(AUTO_ONE_AT_A_TIME)
        else:
            free = 1
    var grants = List[Grant]()
    var admitted = request.any() and (control or placed == "local")
    if admitted and free > 0:
        # Across pipelines: one start at a time weighs the grants.
        starting_db.xact_lock(tx, _HOST_LOCK)
        var g = starting_db.granted(tx, self.stale, self._dead("$1"))
        var got = admit(request, self.room, g[0], g[1], free)
        grants = got[0].copy()
        if len(grants) < free:
            # The ones that don't start say why; those that do, not.
            hold = _taken(
                tx,
                p,
                False,
                with_cap(got[1], sized),
                self.stale,
                self._dead("$1"),
            )
        free = len(grants)
    # Its queued runs say why they wait, or no longer do; one behind an
    # older live run of its keys, which run.
    starting_db.say_held(tx, p.name, hold, fill)
    hold_behind(tx, p.name)
    if self.budget > 0 and free > 0 and not control:
        # Across pipelines: one start at a time weighs the budget.
        starting_db.xact_lock(tx, _BUDGET_LOCK)
        var used = starting_db.cpu_in_use(tx, self.stale, self._dead("$1"))
        # The pool's idle instances count too, but those a run of `p`
        # would take are its own: k runs fit if the budget holds the
        # others and k runs' worth or those, whichever is more.
        var others = 0
        var mine = 0
        if len(keys) > 0:
            var b = keys[1] if len(keys) > 1 else keys[0]
            var pr = starting_db.pool_cpu(tx, keys[0], b)
            mine = pr[1]
            others = pr[0] - mine
        var room = self.budget - used - others
        if room < mine:
            free = 0
        else:
            free = min(free, room // need if need > 0 else free)
    var ids = List[Int64]()
    var new_code = List[Bool]()
    var starts = List[Int]()
    if free > 0:
        for r in starting_db.startable(
            tx,
            p.name,
            self.stale,
            p.run_retries,
            now,
            free,
            dead,
            fill,
        ):
            ids.append(r[0])
            new_code.append(r[1])
        if status:
            # New fill runs, over the partitions nothing has filled.
            ref next = status.value().next_keys
            var filled = List[Int64]()
            for i in range(min(free - len(ids), len(next))):
                ids.append(
                    starting_db.queue_fill(tx, p.name, p.registry_hash, next[i])
                )
                new_code.append(False)
                filled.append(ids[len(ids) - 1])
                print("fill", p.name, next[i], "run", ids[len(ids) - 1])
            mark_batch(tx, filled)
        for i in range(len(ids)):
            var id = ids[i]
            var grant = grants[i] if admitted else Grant.none()
            # `started` is the clock's now, not now(): that is when this
            # transaction began, before it waited on the locks above and
            # counted the slots and the budget, so a run that waited for
            # another to end could be recorded as started before it did.
            starts.append(
                starting_db.mark_started(
                    tx,
                    id,
                    need,
                    placed,
                    recorded_cpus(p, sized) if admitted else String(),
                    recorded_memory_gb(p, sized) if admitted else String(),
                    grant.cpus,
                    grant.memory_mb,
                    self.instance if local else 0,
                    sized.source,
                    sized.runs,
                )
            )
    tx.commit()
    for l in lost:
        print(
            String("requeued run ", l[0], " of ", p.name),
            ": ",
            l[1],
            sep="",
        )
    for i in range(len(ids)):
        var id = ids[i]
        var grant = grants[i] if admitted else Grant.none()
        if admitted:
            print(
                "granted",
                p.name,
                "run",
                id,
                grant.cpus,
                "CPUs and",
                grant.memory_mb,
                "MB (0: not asked for)",
                sized.text(),
                String(
                    "(", sized.cap_text(), ")"
                ) if sized.capped else String(),
            )
        elif sized.source == DEFAULT:
            print("run", id, "of", p.name, "requests", sized.text())
        if control:
            _start_control(self, p, Int(id), starts[i], new_code[i], grant)
            continue
        if self.runner:
            try:
                self.runner.value().start(
                    RunSpec(
                        Int(id),
                        starts[i],
                        p.name,
                        p.image,
                        p.binary,
                        p.workers,
                        new_code[i],
                        p.env.copy(),
                    )
                )
                print("started", p.name, "run", id, "on its cluster")
            except e:
                print("morca: run", id, "of", p.name, "can't start:", e)
                starting_db.fail_start(
                    self.db.conn, id, String("can't start: ", e)
                )
            continue
        if self.ec2:
            try:
                self.ec2.value().start(
                    self.db, _ec2_spec(p, Int(id), starts[i], new_code[i])
                )
                print("started", p.name, "run", id, "on its instances")
            except e:
                # Retried as a run whose process failed is.
                print("morca: run", id, "of", p.name, "can't start:", e)
                starting_db.fail_start(
                    self.db.conn, id, String("can't start: ", e)
                )
            continue
        # Its own variables, from morca.toml, its grant
        # (morca.resources), and its secrets, read now and named in
        # MORCA_SECRETS for masking; the rest it inherits.
        var env = grant_env(p.env, grant, pressure_env(self.psi))
        try:
            var secrets = List[Tuple[String, String]]()
            for s in p.secrets:
                secrets.append((s[0], fetch_secret(s[1])))
            env.extend(secrets_env(secrets))
        except e:
            # Retried as a run whose process failed is.
            print("morca: run", id, "of", p.name, "can't start:", e)
            starting_db.fail_start(self.db.conn, id, String("can't start: ", e))
            continue
        var log = String()
        var stage = String()
        # A run with secrets prints what it likes: its output is
        # staged outside MORCA_LOGS and appended to its driver.log,
        # masked, by keep-log once it ends, as a control-placed run's.
        var kept = len(p.secrets) > 0
        if self.logs:
            log = String(run_dir(p.name, Int(id)), "/driver.log")
            stage = control_stage(
                p.name, Int(id), starts[i]
            ) if kept else stage_of(log)
            makedirs(String(stage[byte = : stage.rfind("/")]), exist_ok=True)
        var argv: List[String] = [p.binary, "resume", String(id)]
        if new_code[i]:
            argv.append("--allow-new-code")
        if log:
            if kept:
                # keep-log heads it with the start.
                with open(stage, "w") as f:
                    f.write("")
            else:
                # Each start's output after a line of its own, as on
                # the other runners: a crash's dump is looked for after
                # the last.
                with open(stage, "a") as f:
                    f.write("--- start ", starts[i], "\n")
        var cg = self._contain(p, Int(id), starts[i], grant, False)
        var pid = spawn(
            argv,
            stage,
            env=env,
            nice=self.cgroups.nice_for(cg.path),
            cgroup=cg.path,
        )
        if cg.path:
            self._contained[pid] = cg^
        self._meters[pid] = Meter()
        self._spawned[pid] = (Int(id), starts[i], stage)
        if log and kept:
            self._kept[pid] = _ControlProc(
                Int(id), p.binary, stage, log, starts[i], env^, ""
            )
        elif is_remote(log):
            self._driver_logs[pid] = log
        print("started", p.name, "run", id, "pid", pid)
        if log and sample_seconds() > 0:
            # The machine's metrics while the run's process lives
            # (morca.sample); it ends once that process has.
            try:
                _ = spawn(
                    [
                        p.binary,
                        "sample",
                        "--out",
                        metrics_location(p.name, Int(id), "local"),
                        "--pid",
                        String(pid),
                    ]
                )
            except e:
                print("morca: no sampler for run", id, ":", e)


def _start_control(
    mut self: Scheduler,
    p: Registered,
    id: Int,
    start: Int,
    new_code: Bool,
    grant: Grant = Grant.none(),
):
    """Starts start `start` of `p`'s run `id` on this host
    (`morca._internal.control`): its binary's `resume`, in a process group of its
    own, at a lower CPU priority, first to go if memory runs out, with
    its secrets read now and given to it alone, and its output staged
    for `keep-log`. A run that can't start fails, and is retried as a
    run whose process failed is."""
    var c: _ControlProc
    var pid: Int
    var cg = self._contain(p, id, start, grant, True)
    try:
        var secrets = List[Tuple[String, String]]()
        for s in p.secrets:
            secrets.append((s[0], fetch_secret(s[1])))
        var extra = run_env(self.limits, p.image, secrets)
        extra.extend(pressure_env(self.psi))
        var env = grant_env(p.env, grant, extra)
        var location = String()
        var stage = String()
        if self.logs:
            location = String(run_dir(p.name, id), "/driver.log")
            stage = control_stage(p.name, id, start)
            makedirs(String(stage[byte = : stage.rfind("/")]), exist_ok=True)
            with open(stage, "w") as f:
                f.write("")
        var argv: List[String] = [p.binary, "resume", String(id)]
        if new_code:
            argv.append("--allow-new-code")
        pid = spawn(
            argv,
            stage,
            env=env,
            nice=self.limits.nice,
            group=True,
            first_to_go=True,
            cgroup=cg.path,
        )
        c = _ControlProc(id, p.binary, stage, location, start, env^, "")
    except e:
        print("morca: run", id, "of", p.name, "can't start:", e)
        if cg.path and not Cgroups.remove(cg.path):
            self._unswept.append(cg.path)
        try:
            starting_db.fail_start(
                self.db.conn, Int64(id), String("can't start: ", e)
            )
        except e2:
            print("morca: can't record run", id, "failing:", e2)
        return
    self._spawned[pid] = (id, start, c.stage)
    self._meters[pid] = Meter()
    if cg.path:
        self._contained[pid] = cg^
    var sampled = c.location != ""
    self._control[pid] = c^
    print("started", p.name, "run", id, "pid", pid, "on the control host")
    if sampled and sample_seconds() > 0:
        try:
            _ = spawn(
                [
                    p.binary,
                    "sample",
                    "--out",
                    metrics_location(p.name, id, CONTROL),
                    "--pid",
                    String(pid),
                ],
                nice=self.limits.nice,
            )
        except e:
            print("morca: no sampler for run", id, ":", e)
