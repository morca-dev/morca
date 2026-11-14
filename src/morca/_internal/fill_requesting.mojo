"""`morca backfill --as-fill` and `morca backfill --cancel` (#465): asking
for keys to be run as fill runs, and cancelling that ask
(`morca._internal.fill_requests`).
"""

from std.os import getenv

import morca._internal.db.fill_requests as requests_db
import morca._internal.db.starting as starting_db
from morca.name import sort_texts
from morca._internal.actions import cancel_kill_seconds
from morca._internal.queueing import partition_keys, rerun_refusal
from morca._internal.registered import Registered
from morca._internal.state import State


def request_fill(
    mut db: State,
    p: Registered,
    keys: String,
    rerun: Bool = False,
    allow_append: Bool = False,
) raises -> String:
    """Records `keys` as a fill request of `p`, for the scheduler to run as
    fill runs, and says so in a line. Refused as `morca backfill --rerun`
    is without `allow_append`; with an open request, the keys it hasn't
    are added to it, but one that differs in `rerun` is refused."""
    if rerun and not allow_append:
        var why = rerun_refusal(db, p, keys)
        if why:
            raise Error(why)
    var asked = partition_keys(p, keys)
    if len(asked) == 0:
        raise Error("morca: no keys of ", p.name, " in '", keys, "'")
    var tx = db.conn.begin()
    starting_db.lock_pipeline(tx, p.name)
    var open = requests_db.open_request(tx, p.name)
    var have = Dict[String, Bool]()
    var all = List[String]()
    if open:
        ref o = open.value()
        if o.rerun != rerun:
            tx.rollback()
            raise Error(
                "morca: ",
                p.name,
                " has fill request ",
                o.id,
                " (",
                o.spec,
                ") going ",
                "with" if o.rerun else "without",
                " --rerun; ask the same way to add to it, or cancel it",
                " first (morca backfill --cancel ",
                p.name,
                ")",
            )
        for k in o.keys.split(","):
            if k:
                have[String(k)] = True
                all.append(String(k))
    var added = 0
    for k in asked:
        if k not in have:
            have[k] = True
            all.append(k)
            added += 1
    sort_texts(all)
    var joined = String()
    for i in range(len(all)):
        joined.write("," if i else "", all[i])
    var how = String(
        "keys_per_run ",
        p.keys_per_run,
        ", fill_max_runs ",
        p.fill.max_runs,
        ", ",
        p.fill.window_text(),
    )
    if open:
        ref o = open.value()
        if added > 0:
            requests_db.merge_request(tx, o.id, joined, keys)
        tx.commit()
        return String(
            "added ",
            added,
            " keys to fill request ",
            o.id,
            " of ",
            p.name,
            " (",
            len(asked) - added,
            " already in it), ",
            len(all),
            " in all, as fill runs (",
            how,
            ")",
        )
    var id = requests_db.add_request(
        tx, p.name, joined, keys, rerun, getenv("USER", "")
    )
    tx.commit()
    return String(
        "fill request ",
        id,
        " of ",
        p.name,
        ": ",
        len(all),
        " keys, as fill runs (",
        how,
        "); morca backfill --cancel ",
        p.name,
        " stops it",
    )


def cancel_fill(mut db: State, p: Registered) raises -> String:
    """Cancels `p`'s open fill request and, as `morca cancel` does, its
    runs that are queued, running or due to be retried; says so in a
    line. Raises if it has none."""
    var tx = db.conn.begin()
    starting_db.lock_pipeline(tx, p.name)
    var id = requests_db.cancel_request(tx, p.name)
    if id == 0:
        tx.rollback()
        raise Error("morca: ", p.name, " has no open fill request")
    var n = requests_db.cancel_request_runs(
        tx, id, p.run_retries, cancel_kill_seconds()
    )
    tx.commit()
    return String(
        "cancelled fill request ", id, " of ", p.name, " and ", n, " runs"
    )
