"""Queueing runs over keys: backfills, the keys a pipeline has done or
holds, and what a rerun or an append refuses.
"""

from std.os.path import exists
from postgres import Transaction
from morca._internal.db.batches import mark_batch
import morca._internal.db.queueing as queueing_db
import morca._internal.db.starting as starting_db
from morca._internal.db.live import live_runs
from morca._internal.timekeys import parse_time_keys
from morca.name import (
    Name,
    parse_names,
    sort_texts,
)
from morca._internal.proc import (
    binary_seconds,
    capture,
)
from morca._internal.state import State
from morca._internal.registered import Registered


def dataset_cycle(mut db: State, describe: String) raises -> String:
    """How the pipeline `describe` gives would close a cycle across
    pipelines, through the datasets they write and read, or empty if it
    wouldn't. A pipeline reading a dataset it writes itself isn't one."""
    var got = queueing_db.dataset_edges(db.conn, describe)
    if len(got[1]) == 0:
        return ""
    var me = got[0]
    var src = List[String]()
    var dst = List[String]()
    var via = List[String]()
    for r in got[1]:
        src.append(r.src)
        dst.append(r.dst)
        via.append(r.ds)
    # A path from `me` back to `me`, breadth first, by the edge taken.
    var came = List[Int](length=len(src), fill=-2)
    var frontier = List[Int]()
    for i in range(len(src)):
        if src[i] == me:
            came[i] = -1
            frontier.append(i)
    while len(frontier) > 0:
        var next = List[Int]()
        for e in frontier:
            if dst[e] == me:
                var path = List[Int]()
                var at = e
                while at >= 0:
                    path.append(at)
                    at = came[at]
                var out = String()
                for k in range(len(path) - 1, -1, -1):
                    var i = path[k]
                    out.write(
                        src[i],
                        " writes ",
                        via[i],
                        ", which ",
                        dst[i],
                        " reads",
                        "; " if k > 0 else "",
                    )
                return out^
            for i in range(len(src)):
                if src[i] == dst[e] and came[i] == -2:
                    came[i] = e
                    next.append(i)
        frontier = next^
    return ""


def parse_keys_output(
    binary: String, text: String
) raises -> Tuple[Int64, List[String]]:
    """What `<binary> keys` printed: its keys snapshot, then its keys."""
    var lines = text.splitlines()
    if len(lines) == 0:
        raise Error("morca: ", binary, " keys printed nothing")
    var keys = List[String]()
    for i in range(1, len(lines)):
        if lines[i]:
            keys.append(String(lines[i]))
    return (Int64(Int(lines[0])), keys^)


def current_keys(
    p: Registered, timeout: Float64 = -1
) raises -> Tuple[Int64, List[String]]:
    """A keyed pipeline's keys snapshot and keys, as `<binary> keys`
    prints them, killed past `timeout` seconds (by default
    `MORCA_BINARY_SECONDS`)."""
    var got = capture(
        [p.binary, "keys"], timeout if timeout >= 0 else binary_seconds()
    )
    if got[0] != 0:
        raise Error("morca: ", p.binary, " keys exited ", got[0], ": ", got[1])
    return parse_keys_output(p.binary, got[1])


def keep_keys(
    mut db: State, pipeline: String, keys: Tuple[Int64, List[String]]
) raises:
    """Records the keys `<binary> keys` printed, in `orca.keys`."""
    var text = String()
    for i in range(len(keys[1])):
        text.write("\n" if i else "", keys[1][i])
    queueing_db.keep_keys(db.conn, pipeline, keys[0], text)


@fieldwise_init
struct KeptKeys(Copyable, Movable):
    """A pipeline's keys as `orca.keys` has them."""

    var snapshot: Int64
    var keys: List[String]
    var read_at: String
    var age: Float64
    """Seconds since they were read."""


def kept_keys(mut db: State, pipeline: String) raises -> Optional[KeptKeys]:
    var row = queueing_db.kept_keys(db.conn, pipeline)
    if not row:
        return None
    ref r = row.value()
    var keys = List[String]()
    for k in r.keys.split("\n"):
        if k:
            keys.append(String(k))
    return KeptKeys(r.snapshot, keys^, r.read_at, r.age)


def file_names(path: String) raises -> String:
    """The names in the file at `path`, a line each, as `NAME,NAME,...`
    (`@file:<path>`)."""
    var text: String
    with open(path, "r") as f:
        text = f.read()
    var joined = String()
    var at = 0
    for line in text.splitlines():
        at += 1
        var n = line.strip()
        if n:
            # The error names the line, not its text: a file's other
            # contents stay out of the message.
            try:
                _ = Name.parse(n)
            except:
                raise Error("morca: line ", at, " of ", path, " isn't a name")
            joined.write("," if joined else "", n)
    if not joined:
        raise Error("morca: no names in ", path)
    return joined^


def kind_mismatch(mut db: State, describe: String) raises -> String:
    """How the pipeline `describe` gives would make a sensor run keys of the
    other kind, a keyed sensor reading a dataset a time-partitioned
    pipeline writes or the other way round, or empty if it wouldn't.

    A keyed sensor's own keys dataset needs no mapping, whoever writes it:
    a new snapshot of it offers the keys it holds, which are names already.
    So a dated pipeline may write the keys a keyed sensor runs."""
    var m = queueing_db.kind_mismatch(db.conn, describe)
    if not m:
        return ""
    ref r = m.value()
    return String(
        "the sensor ",
        r.reader,
        " (",
        r.rkind,
        ") reads ",
        r.ds,
        ", which ",
        r.writer,
        " (",
        r.wkind,
        ") writes, and no rule turns a name into a date or a date into a",
        " name",
    )


def partition_keys(p: Registered, keys: String) raises -> List[String]:
    """`keys` as the pipeline's partition keys, each checked: for time keys
    `KEY[..KEY][,...]` from its first partition on; for keyed partitions a
    list of names, `@all` or `@file:<path>`, each a current key."""
    var texts = List[String]()
    if p.kind == "keyed":
        var current = current_keys(p)[1].copy()
        if keys == "@all":
            return current^
        var have = Dict[String, Bool]()
        for k in current:
            have[k] = True
        var list = file_names(String(keys[byte=6:])) if keys.startswith(
            "@file:"
        ) else keys
        for n in parse_names(list):
            if n.text not in have:
                raise Error("morca: ", n, " isn't a key of ", p.keys_dataset)
            texts.append(n.text)
        return texts^
    return parse_time_keys(p.kind, keys, p.start)


@fieldwise_init
struct Queued(Movable):
    """What a backfill or a keyed sensor queued, and the keys it left."""

    var runs: List[Int]
    var done: List[String]
    """Keys left because they're done."""
    var live: List[String]
    """Keys left because a live run has them, that run in `live_runs`."""
    var live_runs: List[Int]
    var keys: List[String]
    """The keys queued (or, in a preview, that would be), sorted."""
    var batches: Int
    """How many runs those keys make, `keys_per_run` to a run; a preview
    counts them without queueing any."""

    def __init__(out self):
        self.runs = List[Int]()
        self.done = List[String]()
        self.live = List[String]()
        self.live_runs = List[Int]()
        self.keys = List[String]()
        self.batches = 0

    def skipped(self) -> List[String]:
        """A line for each reason keys were left, or none."""
        var out = List[String]()
        if len(self.done) > 0:
            var line = String("skipped ", len(self.done), " done: ")
            _list(line, self.done)
            out.append(line^)
        if len(self.live) > 0:
            var line = String("skipped ", len(self.live), " in live runs: ")
            var named = List[String]()
            for i in range(len(self.live)):
                named.append(
                    String(self.live[i], " (run ", self.live_runs[i], ")")
                )
            _list(line, named)
            out.append(line^)
        return out^


def _list(mut line: String, items: List[String]):
    """The first ten of `items`, comma-separated, and how many more."""
    for i in range(min(len(items), 10)):
        line.write(", " if i else "", items[i])
    if len(items) > 10:
        line.write(", and ", len(items) - 10, " more")


def done_keys(
    mut db: State, pipeline: String, keys: List[String]
) raises -> Dict[String, Bool]:
    """Which of `keys` are done for `pipeline` (`DONE_SQL`)."""
    var joined = String()
    for i in range(len(keys)):
        joined.write("," if i else "", keys[i])
    var out = Dict[String, Bool]()
    for k in queueing_db.done_keys(db.conn, pipeline, joined):
        out[k] = True
    return out^


def queue_keys(
    mut db: State,
    p: Registered,
    keys: List[String],
    trigger: String,
    rerun: Bool = False,
) raises -> Queued:
    """Queues runs of `p` over those of `keys` that aren't done and aren't
    in a live run, sorted, `keys_per_run` to a run; returns the runs, and
    the keys it left and why. With
    `rerun`, keys that are done are queued too, but never one in a live
    run. Under a lock on the pipeline's row, so two backfills don't both
    queue a key."""
    var tx = db.conn.begin()
    var got = _queue(tx, p, keys, trigger, rerun)
    tx.commit()
    return got^


def _queue(
    mut tx: Transaction,
    p: Registered,
    keys: List[String],
    trigger: String,
    rerun: Bool = False,
    dry: Bool = False,
) raises -> Queued:
    """`queue_keys` in `tx`; with `dry`, what it would queue, queueing
    nothing."""
    starting_db.lock_pipeline(tx, p.name)
    var got = Queued()
    var live = live_runs(tx, p.name)
    var joined = String()
    for i in range(len(keys)):
        joined.write("," if i else "", keys[i])
    var done = Dict[String, Bool]()
    if not rerun:
        for k in queueing_db.done_keys(tx, p.name, joined):
            done[k] = True
    var seen = Dict[String, Bool]()
    var todo = List[String]()
    for k in keys:
        if k in seen:
            continue
        seen[k] = True  # each once
        var in_run = live.get(k)
        if in_run:
            got.live.append(k)
            got.live_runs.append(in_run.value())
        elif k in done:
            got.done.append(k)
        else:
            todo.append(k)
    sort_texts(todo)
    got.keys = todo.copy()
    ref runs = got.runs
    var i = 0
    while i < len(todo):
        var batch = String()
        var j = i
        while j < len(todo) and j < i + p.keys_per_run:
            batch.write("," if j > i else "", todo[j])
            j += 1
        got.batches += 1
        if dry:
            i = j
            continue
        runs.append(
            queueing_db.queue_run(tx, p.name, p.registry_hash, batch, trigger)
        )
        i = j
    var ids = List[Int64]()
    for r in runs:
        ids.append(Int64(r))
    mark_batch(tx, ids)
    return got^


def appending_writes(
    mut db: State, pipeline: String, from_step: Int = 0
) raises -> List[String]:
    """`step <name> writes <dataset>` for each dataset a step of `pipeline`
    writes without replacing it (in `writes=`, not `replaces=`), from its
    `from_step`th step on (0, the first): what a new run over a key that
    already has rows appends to again. A pipeline registered before
    `replaces=` existed appends to all it writes."""
    var out = List[String]()
    for r in queueing_db.appending_writes(db.conn, pipeline, from_step):
        out.append(String("step ", r[0], " writes ", r[1]))
    return out^


def append_again(
    pipeline: String, what: String, writes: List[String], how: String
) -> String:
    """Why a rerun of `what` is refused: it appends again (`writes`, from
    `appending_writes`). `how` says how to rerun anyway."""
    var line = String(
        "morca: rerunning ",
        what,
        " appends again to what ",
        pipeline,
        " appended to before, duplicating those rows: ",
    )
    _list(line, writes)
    line.write(
        ". Declare a dataset in its step's replaces= to have a new run",
        " replace its partitions (morca.tables), or ",
        how,
    )
    return line^


comptime ALLOW_APPEND_HOW = "pass --allow-append to append anyway"


def rerun_refusal(mut db: State, p: Registered, keys: String) raises -> String:
    """Why `morca backfill --rerun` of `keys` is refused without
    `--allow-append`, or empty: some are done, and the pipeline's steps
    append to datasets (`appending_writes`), so a new run of them would
    leave their rows twice."""
    var writes = appending_writes(db, p.name)
    if len(writes) == 0:
        return ""
    var done = done_keys(db, p.name, partition_keys(p, keys))
    if len(done) == 0:
        return ""
    var names = List[String]()
    for k in done.keys():
        names.append(k)
    sort_texts(names)
    var what = String()
    _list(what, names)
    what.write(" (done)")
    return append_again(p.name, what, writes, ALLOW_APPEND_HOW)


def backfill(
    mut db: State,
    p: Registered,
    keys: String,
    rerun: Bool = False,
    allow_append: Bool = False,
    dry: Bool = False,
) raises -> Queued:
    """Queues runs for the keys in `keys` that aren't done and aren't in a
    live run, `keys_per_run` to a run; returns the runs it queued and the
    keys it left. With `rerun` (`morca backfill --rerun`) the done ones are
    queued again too, as for a day whose source has changed since; unless
    `allow_append`, that's refused for a pipeline whose steps append to
    what they write (`rerun_refusal`). With `dry` (`morca backfill
    --dry-run`, the Start runs preview), the same checks and the same
    count, in a transaction it rolls back, queueing nothing."""
    if rerun and not allow_append:
        var why = rerun_refusal(db, p, keys)
        if why:
            raise Error(why)
    var texts = partition_keys(p, keys)
    if not dry:
        return queue_keys(db, p, texts, "backfill", rerun)
    var tx = db.conn.begin()
    var got = _queue(tx, p, texts, "backfill", rerun, dry=True)
    tx.rollback()
    return got^


def preview_backfill(
    mut db: State,
    p: Registered,
    keys: String,
    rerun: Bool = False,
    allow_append: Bool = False,
) raises -> Queued:
    """What `backfill` would queue now, queueing nothing: the keys, how many
    runs they make, and the keys it would leave and why; or its refusal."""
    return backfill(db, p, keys, rerun, allow_append, dry=True)


def _last_line(path: String) -> String:
    """The last line with text in the file at `path`, at most 300 bytes of
    it, or empty if there's none or it can't be read."""
    if not path or not exists(path):
        return ""
    try:
        var text: String
        with open(path, "r") as f:
            text = f.read()
        var lines = text.splitlines()
        for i in range(len(lines) - 1, -1, -1):
            var line = String(lines[i].strip())
            if line and not line.startswith("--- start "):
                var n = line.byte_length()
                if n > 300:
                    # Cut where a character starts.
                    n = 300
                    while n > 0 and (line.as_bytes()[n] & 0xC0) == 0x80:
                        n -= 1
                    return String(line[byte=:n])
                return line^
    except:
        pass
    return ""
