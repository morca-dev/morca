# expect: a step follows a step not in its pipeline
from dista import Seq
from morca import Ctx, Mapped, Month, Pipeline, Step


def key(mut ctx: Ctx, m: Month) raises -> Int:
    return m.month


def double(mut ctx: Ctx, x: Int) raises -> Int:
    return x * 2


def name(mut ctx: Ctx, x: Int) raises -> String:
    return String(x)


def total(mut ctx: Ctx, xs: Seq[Int]) raises -> Int:
    return len(xs)


def count(mut ctx: Ctx, x: Int) raises -> Int:
    return x


def by_month(mut ctx: Ctx, xs: Seq[Month]) raises -> Int:
    return len(xs)


comptime Key = Step["key", Month, Int, key, Mapped]
comptime Double = Step["double", Int, Int, double, Mapped, after=Key]
comptime P = Pipeline["p", Double]


def main() raises:
    print(P.describe())
