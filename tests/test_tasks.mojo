"""Dista inside steps: one runtime per run, reached through `Ctx.runtime`."""

from std.testing import TestSuite, assert_equal, assert_true

from dista import ObjectRef, Seq, Task
from morca import (
    Ctx,
    Gather,
    Mapped,
    Month,
    Pipeline,
    Step,
    Tasks,
    parse_months,
)


def square(x: Int) -> Int:
    return x * x


def worker_of(x: Int) raises -> String:
    """Which process ran it."""
    from std.ffi import external_call

    return String(external_call["getpid", Int32]())


comptime Square = Task[Int, Int, square]
comptime WorkerOf = Task[Int, String, worker_of]
comptime TheseTasks = Tasks[Square, WorkerOf]


def fan(mut ctx: Ctx, m: Month) raises -> Int:
    """100 squares over the run's workers, summed."""
    ref rt = ctx.runtime[TheseTasks]()
    var refs = List[ObjectRef[Int]]()
    for i in range(100):
        refs.append(rt.remote[Square](i + m.month))
    var t = 0
    for r in refs:
        t += rt.get(r)
    return t


def workers_seen(mut ctx: Ctx, sums: Seq[Int]) raises -> Int:
    """How many distinct worker processes 200 tasks ran on."""
    ref rt = ctx.runtime[TheseTasks]()
    var refs = List[ObjectRef[String]]()
    for i in range(200):
        refs.append(rt.remote[WorkerOf](i))
    var seen = List[String]()
    for r in refs:
        var w = rt.get(r)
        if w not in seen:
            seen.append(w^)
    return len(seen)


def wrong_runtime(mut ctx: Ctx, m: Month) raises -> Int:
    ref rt = ctx.runtime[Tasks[Square]]()
    return rt.get(rt.remote[Square](2))


def no_runtime(mut ctx: Ctx, m: Month) raises -> Int:
    ref rt = ctx.runtime[TheseTasks]()
    return rt.get(rt.remote[Square](2))


comptime Fan = Step["fan", Month, Int, fan, Mapped]
comptime Seen = Step["seen", Seq[Int], Int, workers_seen, Gather, after=Fan]
comptime Fans = Pipeline["fans", Fan, Seen, tasks=TheseTasks]

comptime Wrong = Step["wrong", Month, Int, wrong_runtime, Mapped]
comptime Wrongs = Pipeline["wrongs", Wrong, tasks=TheseTasks]
comptime None_ = Step["none", Month, Int, no_runtime, Mapped]
comptime Nones = Pipeline["nones", None_]


def _sum_squares(offset: Int) -> Int:
    var t = 0
    for i in range(100):
        t += (i + offset) * (i + offset)
    return t


def test_steps_fan_out_over_the_runs_workers() raises:
    var res = Fans.run(parse_months("2024-01..2024-02"))
    assert_true(res.succeeded())
    assert_equal(res.output[Int]("fan", "2024-01"), _sum_squares(1))
    assert_equal(res.output[Int]("fan", "2024-02"), _sum_squares(2))
    # MORCA_WORKERS defaults to 4.
    assert_equal(res.output[Int]("seen"), 4)


def test_the_runtime_type_is_checked() raises:
    var res = Wrongs.run(parse_months("2024-01"))
    assert_true("the run's runtime has tasks" in res.steps[0].error)
    res = Nones.run(parse_months("2024-01"))
    assert_true("has no dista runtime" in res.steps[0].error)


def test_tasks_are_part_of_the_dag() raises:
    assert_true('"tasks": ["test_tasks::square(' in Fans.describe())
    comptime Fewer = Pipeline["fans", Fan, Seen, tasks=Tasks[Square]]
    assert_true(Fans.registry_hash() != Fewer.registry_hash())
    comptime Bare = Pipeline["fans", Fan, Seen]
    assert_true('"tasks": []' in Bare.describe())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
