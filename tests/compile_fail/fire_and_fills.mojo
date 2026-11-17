# expect: fills= is fire='s old name; set only fire=
from morca import Cron, Ctx, Current, Mapped, Month, Pipeline, Step


def key(mut ctx: Ctx, m: Month) raises -> Int:
    return m.month


comptime Key = Step["key", Month, Int, key, Mapped]
comptime P = Pipeline[
    "p", Key, schedule=Cron["0 3 2 * *"], fire=Current, fills=Current
]


def main() raises:
    print(P.describe())
