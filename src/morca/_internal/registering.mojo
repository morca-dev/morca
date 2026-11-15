"""`morca register`: recording a pipeline binary and how its runs run
(`register_pipeline`).
"""

from std.os.path import exists
from std.sys import stderr
import morca._internal.db.concurrency as concurrency_db
import morca._internal.db.pipelines as pipelines_db
from morca._internal.concurrency import parse_concurrency, wait_limit
import morca._internal.db.registering as registering_db
from morca._internal.config import (
    ProjectConfig,
    RegisterFlags,
    max_runs_auto,
    parse_keys_per_run,
    parse_max_runs,
    parse_priority,
    parse_worker_procs,
    parse_workers,
    resolve,
)
from morca._internal.fill import (
    fill_refusal,
    parse_fill_budget,
    fill_max_runs_auto,
    parse_fill_max_runs,
)
from morca._common.paths import absolute
from morca._internal.proc import (
    binary_seconds,
    capture,
)
from morca._internal.secrets import secrets_json
from morca._internal.version import MISMATCH_HINT, mismatch, mixed_allowed
from morca._internal.sensors import parse_sense
from morca._internal.scheduler import Scheduler
from morca._internal.registered import (
    registered,
    repeated_fill,
)
from morca._internal.queueing import (
    backfill,
    dataset_cycle,
    kind_mismatch,
)


def register_pipeline(
    mut self: Scheduler,
    binary: String,
    now: Int64,
    flags: RegisterFlags = RegisterFlags(),
    file: ProjectConfig = ProjectConfig(),
) raises -> String:
    """Records the pipeline `binary` describes, with its path; its
    schedule counts from `now` the first time, and a sensor from now the
    first time it's one, with the snapshots its datasets have now seen.
    Queued runs move to the new code, and so do failed ones waiting for
    a retry with no step done. How its runs run is `flags` over what
    `file`, the project's morca.toml (`morca._internal.config`), says for it: for a
    pipeline the file names, exactly that, a setting neither gives
    going back to its default; for one it doesn't, the flags given,
    each left out keeping what was registered (`--workers MIN..MAX`
    scales an EC2 run's workers, `--worker-procs` is the dista worker
    processes per EC2 worker instance, `--secret`s replace the
    pipeline's, `--placement` is `control`, `ec2` or `default`).
    Returns the pipeline's name."""
    var path = absolute(binary)
    var got = capture([path, "describe"], binary_seconds())
    if got[0] != 0 or not got[1].startswith('{"pipeline": '):
        raise Error("morca: ", path, " describe exited ", got[0], ": ", got[1])
    # The pipeline and this morca from one release (#455).
    var other = mismatch(path, got[1])
    if other and not mixed_allowed():
        raise Error("morca: ", other, ": ", MISMATCH_HINT)
    if other:
        print("morca: warning:", other, file=stderr)
    var cycle = dataset_cycle(self.db, got[1])
    if cycle:
        raise Error("morca: ", path, " can't be registered: ", cycle)
    var mismatch = kind_mismatch(self.db, got[1])
    if mismatch:
        raise Error("morca: ", path, " can't be registered: ", mismatch)
    var info = registering_db.described(self.db.conn, got[1])
    var sensor = info.sensor
    var r = resolve(info.name, flags, file)
    var workers = 0
    var min_workers = -1
    if r.text("workers"):
        var w = parse_workers(r.text("workers"))
        min_workers = w[0]
        workers = w[1]
    var worker_procs = -1
    if r.text("worker_procs"):
        worker_procs = parse_worker_procs(r.text("worker_procs"))
    var max_runs = -1
    var auto_runs = False
    if r.text("max_runs"):
        max_runs = parse_max_runs(r.text("max_runs"))
        auto_runs = max_runs_auto(r.text("max_runs"))
    # Fills (morca.fill): only from the file.
    if r.text("fills") == "all":
        var why = fill_refusal(info.kind, info.start, sensor, r.name)
        if why:
            var at = file.where(r.name, "fills", r.values["fills"].copy())
            raise Error(
                "morca: ",
                at,
                ' fills = "all" can\'t be registered: ',
                why,
                '. Set fills = "since_registration" for it in its',
                " own table",
            )
    var keys_per_run = -1
    if r.text("keys_per_run"):
        keys_per_run = parse_keys_per_run(r.text("keys_per_run"))
    var fill_max_runs = -1
    var fill_auto = False
    if r.text("fill_max_runs"):
        fill_max_runs = parse_fill_max_runs(r.text("fill_max_runs"))
        fill_auto = fill_max_runs_auto(r.text("fill_max_runs"))
    var priority = 0
    if r.text("priority"):
        priority = parse_priority(r.text("priority"))
    # A concurrency key (#397) needs the wait limit, as the scheduler
    # does: refused before anything is registered.
    var ckey = String()
    var climit = 0
    if r.text("concurrency"):
        var c = parse_concurrency(r.text("concurrency"))
        ckey = c[0]
        climit = c[1]
        try:
            _ = wait_limit()
        except e:
            raise Error(
                String(e), " (", r.name, " declares concurrency key ", ckey, ")"
            )
    var fill_budget = -1.0
    if r.text("fill_budget_per_day"):
        fill_budget = parse_fill_budget(r.text("fill_budget_per_day"))
    var seen = String()
    if sensor:
        var sensed = capture([path, "sense"], binary_seconds())
        if sensed[0] != 0:
            raise Error(
                "morca: ", path, " sense exited ", sensed[0], ": ", sensed[1]
            )
        if len(parse_sense(sensed[1])) == 0:
            raise Error(
                "morca: ",
                path,
                " is a sensor, but reads no dataset it doesn't write",
            )
        if info.new_sensor:
            seen = sensed[1]
    # in_file: the file names it, so what it and the flags say is all of
    # it; otherwise a value not given keeps what was registered.
    var res = registering_db.register(
        self.db.conn,
        registering_db.Registration(
            got[1],
            path,
            now,
            sensor,
            flags.image,
            r.text("head_type"),
            r.text("worker_type"),
            workers,
            flags.spot,
            min_workers,
            secrets_json(r.secret_specs()),
            worker_procs,
            r.text("placement"),
            r.in_file,
            max_runs,
            r.env_json(),
            r.config_json(file),
            r.text("fills"),
            r.text("fill_order"),
            fill_max_runs,
            fill_budget,
            r.text("fill_window"),
            r.text("cpus"),
            r.text("memory_gb"),
            r.text("fill_lag"),
            r.text("learn"),
            auto_runs,
            keys_per_run,
            fill_auto,
            priority,
        ),
    )
    var name = res[0]
    if r.in_file:
        concurrency_db.set_key(self.db.conn, name, ckey, climit)
    var version = self.db.version(name, res[1], got[1], res[2])
    # The data version before and after (#297), for the notice below:
    # a first registration has no before.
    var dv = registering_db.data_versions(self.db.conn, name, version)
    var data_changed = dv[0] and dv[1] != dv[2]
    var data_version = dv[2]
    pipelines_db.set_version(self.db.conn, name, version)
    # Where its functions are, if `morca locate` left a map beside it.
    var map = String(path, ".source.json")
    if exists(map):
        var text: String
        with open(map, "r") as f:
            text = f.read()
        registering_db.set_locations(self.db.conn, version, text)
    # What its datasets hold now isn't new to it.
    for c in parse_sense(seen):
        if c.snapshot >= 0:
            registering_db.seen(self.db.conn, name, c.dataset, c.snapshot)
    # Registered again, a retired pipeline is back (#427).
    if pipelines_db.change_retired(self.db.conn, name, False):
        print("morca:", name, "was retired: registered again")
    for q in registered(self.db, name):
        if data_changed:
            var what = String(
                "its steps' version= is now ",
                data_version if data_version else "none",
            )
            if q.fill.all:
                print(
                    "morca:",
                    q.name,
                    String(what, ":"),
                    "its fill runs its partitions again, within its",
                    "fill limits",
                )
            else:
                print(
                    "morca:",
                    q.name,
                    String(what, ":"),
                    "its keys are no longer done; regenerate its history",
                    "with `morca backfill",
                    q.name,
                    '<range>` (or fills = "all")',
                )
        var twice = repeated_fill(q, now)
        if twice:
            print("morca: warning:", twice)
        if q.fill.all and q.fill.budget < 0:
            print(
                "morca: warning:",
                q.name,
                "fills its range with no fill_budget_per_day: its fill",
                "runs start only where they cost nothing (placement",
                "control, or the local runner); on ec2 or kubernetes",
                "they wait for a budget",
            )
    # A retry of a run with steps done would run the new code over the
    # old code's outputs, which only a resume that says so may do.
    registering_db.move_to_code(self.db.conn, name, res[1])
    return name^
