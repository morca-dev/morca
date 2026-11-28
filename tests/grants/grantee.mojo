"""The pipeline of tests/grants.sh: one step that writes what its run was
granted (morca.resources) to a file, then takes a while, so the test can see
which runs overlap.

One pipeline per name: `run["wide"]()` runs the pipeline `wide`, which
scripts/pipelines.sh's binary does as `build/wide`; built on its own, `-D
GRANTEE=wide` makes `main` that one. For a month, the step writes
`$GRANTEE_OUT/<name>-<month>.env` with the run's
`MORCA_GRANT_CPUS`, `MORCA_GRANT_MEMORY_MB` and `DISTA_WORKER_SLOTS` (each
`-` when unset), and `GRANTEE_PARALLEL` as `morca.auto_count` reads it at
2 GB each, then `MORCA_GRANT_GPUS` and `CUDA_VISIBLE_DEVICES` only if set
(empty included), then sleeps `GRANTEE_SLEEP` (2) seconds.
"""

from std.os import getenv
from std.sys import get_defined_string
from std.time import sleep

from morca import (
    Ctx,
    Mapped,
    Month,
    Monthly,
    Pipeline,
    Step,
    auto_count,
    morca_main,
)

comptime NAME = get_defined_string["GRANTEE", "grantee"]()


def _env(name: String) -> String:
    var v = getenv(name)
    return v if v else String("-")


def grantee(mut ctx: Ctx, m: Month) raises -> Int:
    var out = getenv("GRANTEE_OUT")
    var parallel = auto_count("GRANTEE_PARALLEL", 16, memory_mb_each=2048)
    if out:
        with open(String(out, "/", ctx.pipeline, "-", m, ".env"), "w") as f:
            f.write(
                "MORCA_GRANT_CPUS=",
                _env("MORCA_GRANT_CPUS"),
                "\nMORCA_GRANT_MEMORY_MB=",
                _env("MORCA_GRANT_MEMORY_MB"),
                "\nDISTA_WORKER_SLOTS=",
                _env("DISTA_WORKER_SLOTS"),
                "\nGRANTEE_PARALLEL=",
                parallel,
                "\n",
            )
            for name in ["MORCA_GRANT_GPUS", "CUDA_VISIBLE_DEVICES"]:
                var v = getenv(name, "-")
                if v != "-":
                    f.write(name, "=", v, "\n")
    sleep(Float64(getenv("GRANTEE_SLEEP", "2")))
    return m.month


comptime Grantee = Step["grantee", Month, Int, grantee, Mapped]


def run[name: StaticString]() raises:
    morca_main[Pipeline[name, Grantee, partitions=Monthly["2024-01"]]]()


def main() raises:
    run[NAME]()
