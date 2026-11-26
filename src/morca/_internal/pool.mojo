"""An EC2 instance's side of the warm pool (`morca._internal.ec2`,
`MORCA_EC2_POOL_SECONDS`): the two commands its script runs between runs,
through the pipeline's binary, over `MORCA_DATABASE_URL`.

```
<binary> pool-wait <instance> <run> <start>             a worker: until its run is over
<binary> pool-next <instance> <run> <start> <seconds>   until it's handed another run
```

The scheduler hands an idle instance to a run by ending its row in
`orca.instances` and inserting one for the new run, `pooled`, in one
transaction. So the instance learns of its next run from its own rows, and
Postgres, which every instance reaches already, is the only channel: no
other service, port or permission. `pool-next` marks the row of the run the
instance served `idle` (its work has stopped: the head's driver and dista
head have exited, a worker's processes are killed), and beats `polled`
every second, which the scheduler checks before it hands the instance out.
When a new row appears, it records that it `joined`, prints `next <run>
<start> <head address> <0|1>` (the last, whether the run may use new code) and
exits 0; when its row ends with no other (the scheduler shut the idle
instance down), or `seconds` and a minute more pass, it exits 1 and the
script shuts the instance down.

`pool-wait`, beside a worker's processes, exits 0 once the run isn't running
at that start any more, or the worker's row has ended: dista workers don't
end with their head, so this is how a worker knows to stop. Both ride out
a database that can't be reached for a while, retrying every second.
"""

from std.os import getenv
from std.time import perf_counter_ns, sleep

import morca._internal.db.ec2 as ec2_db

from morca._internal.state import State


def _over(mut db: State, iid: String, run: Int, start: Int) raises -> Bool:
    return ec2_db.run_over(db.conn, iid, run, start)


def pool_wait_main(args: List[String]) raises -> Int:
    """`pool-wait <instance> <run> <start>`: returns once the run is over
    for the instance."""
    var iid = args[2]
    var run = Int(args[3])
    var start = Int(args[4])
    var url = getenv_url()
    var db: Optional[State] = None
    var said = False
    while True:
        try:
            if not db:
                db = State(url)
            if _over(db.value(), iid, run, start):
                return 0
        except e:
            if not said:
                print("morca: pool-wait can't read run", run, ":", e)
                said = True
            db = None
        sleep(1.0)


def pool_next_main(args: List[String]) raises -> Int:
    """`pool-next <instance> <run> <start> <seconds>`: waits, idle, for the
    run the scheduler hands the instance; see the module's doc."""
    var iid = args[2]
    var run = Int(args[3])
    var start = Int(args[4])
    var limit = Float64(args[5]) + 60
    var url = getenv_url()
    var t0 = perf_counter_ns()
    var db: Optional[State] = None
    var said = False
    while Float64(perf_counter_ns() - t0) / 1e9 < limit:
        try:
            if not db:
                db = State(url)
            ref c = db.value().conn
            if ec2_db.beat_idle(c, iid, run, start) == 0:
                var got = ec2_db.join_handed(c, iid)
                guard case .Some(h) = got else:
                    return 1  # ended: the scheduler shut it down
                print(
                    "next",
                    h.run,
                    h.start,
                    h.head if h.head else String("-"),
                    1 if h.allow_new_code else 0,
                )
                return 0
        except e:
            if not said:
                print("morca: pool-next can't reach the database:", e)
                said = True
            db = None
        sleep(1.0)
    return 1


def getenv_url() raises -> String:
    var url = getenv("MORCA_DATABASE_URL")
    if not url:
        raise Error("morca: the pool's commands need MORCA_DATABASE_URL")
    return url^
