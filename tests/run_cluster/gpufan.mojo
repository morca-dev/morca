"""The pipeline of tests/run_cluster.sh's worker groups part (docs/groups.md):
a month's step fans out tasks of two kinds over the run's cluster, `plain`
ones that name no group and `model` ones of group `gpu`. dista sends each to
the workers of its group alone, so where a task ran says how morca started
its workers.

Each task writes `$GPUFAN_OUT/<kind>-<pid>.env`, `kind` `plain` or `model`
and `pid` its dista worker's, with that process's `DISTA_GROUP`,
`CUDA_VISIBLE_DEVICES`, `MORCA_GRANT_GPUS` (each `-` when unset) and
`HOSTNAME`, then sleeps `GPUFAN_SLEEP` (1) seconds.
"""

from std.ffi import c_int, external_call
from std.os import getenv
from std.time import sleep

from dista import ObjectRef, Task
from morca import (
    Ctx,
    Mapped,
    Month,
    Monthly,
    Pipeline,
    Step,
    Tasks,
    morca_main,
)


def _mark(kind: String, n: Int) raises -> Int:
    var out = getenv("GPUFAN_OUT")
    if out:
        var pid = Int(external_call["getpid", c_int]())
        with open(String(out, "/", kind, "-", pid, ".env"), "w") as f:
            f.write(
                "DISTA_GROUP=",
                getenv("DISTA_GROUP", "-"),
                "\nCUDA_VISIBLE_DEVICES=",
                getenv("CUDA_VISIBLE_DEVICES", "-"),
                "\nMORCA_GRANT_GPUS=",
                getenv("MORCA_GRANT_GPUS", "-"),
                "\nHOSTNAME=",
                getenv("HOSTNAME", "?"),
                "\n",
            )
    sleep(Float64(getenv("GPUFAN_SLEEP", "1")))
    return n


def plain(n: Int) raises -> Int:
    return _mark("plain", n)


def model(n: Int) raises -> Int:
    return _mark("model", n) * 2


comptime Plain = Task[Int, Int, plain]
comptime Model = Task[Int, Int, model, group="gpu"]
comptime GpuTasks = Tasks[Plain, Model]


def gpufan(mut ctx: Ctx, m: Month) raises -> Int:
    """8 plain tasks and 4 of group gpu, summed: 8 * 9 / 2 + 2 * (4 * 5 /
    2) = 56."""
    ref rt = ctx.runtime[GpuTasks]()
    var plains = List[ObjectRef[Int]]()
    var models = List[ObjectRef[Int]]()
    for i in range(1, 9):
        plains.append(rt.remote[Plain](i))
    for i in range(1, 5):
        models.append(rt.remote[Model](i))
    var total = 0
    for r in plains:
        total += rt.get(r)
    for r in models:
        total += rt.get(r)
    ctx.log(String(total, " from plain and model tasks"))
    return total


comptime Gpufan = Step["gpufan", Month, Int, gpufan, Mapped]


def main() raises:
    morca_main[
        Pipeline[
            "gpufan", Gpufan, tasks=GpuTasks, partitions=Monthly["2024-01"]
        ]
    ]()
