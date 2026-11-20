"""Steps: the functions a pipeline runs, and the edges between them.

A step wraps a top-level `def` with a name, its input and output types, its
kind, and the step it follows:

```mojo
def download(mut ctx: Ctx, month: Month) raises -> RawFile: ...
def load(mut ctx: Ctx, raw: RawFile) raises -> Loaded: ...
def compact(mut ctx: Ctx, loaded: Seq[Loaded]) raises -> Int64: ...

comptime Download = Step["download", Month, RawFile, download, Mapped]
comptime Load = Step["load", RawFile, Loaded, load, Mapped, after=Download]
comptime Compact = Step["compact", Seq[Loaded], Int64, compact, Gather, after=Load]
```

A mapped step runs once per partition of a run, a gather step once per run.
The edge is checked when the pipeline is compiled:

| Step | Its input must be |
|---|---|
| first, mapped | the pipeline's partition key, such as `Month` |
| first, gather | a `Seq` of the key, every partition of the run |
| mapped, after a mapped step | that step's output |
| gather, after a mapped step | `Seq` of that step's output, one per partition in run order |
| gather, after a gather step | that step's output |

A mapped step can't follow a gather step. Types are compared by their
reflected names, which include their module; the first step's input is
checked by `Pipeline.check`, which knows the key.

A step declares the datasets it reads and writes, as `namespace.table`
names in the warehouse (`morca.tables`):

```mojo
comptime Clean = Step[
    "clean", Month, Int64, clean, Mapped,
    reads=["raw.events"], writes=["lake.events"],
]
```

A dataset in `replaces=` instead is one the step writes whose partitions a
new run *replaces* rather than appends to: `morca.tables.append` and
`append_files` to it make the run's first commit to each partition an
`overwrite` that removes what earlier runs left there, so
`morca backfill --rerun` leaves one copy of a key's rows (`morca.tables`,
"Replacing partitions"). A dataset in `replaces=` counts as written; it
needn't be in `writes=` as well.

```mojo
comptime Load = Step[
    "load", Day, Int64, load, Mapped, replaces=["gharchive.events"],
]
```

A step that fails is tried again up to `retries` times in the same run,
at once, or after `backoff_seconds` doubling with each retry:

```mojo
comptime Fetch = Step[
    "fetch", Month, RawFile, fetch, Mapped, retries=3, backoff_seconds=30,
]
```

A step that can't do its work yet, such as a download that isn't
published or an API that's out of requests, raises `defer(seconds, why)`
instead of failing: the attempt ends `deferred`, spending no retry, and its
run ends `deferred` and is started again by the scheduler that many seconds
later, without counting against `run_retries` (`morca._internal.scheduler`).

`timeout_seconds=N` bounds an attempt: one still going N seconds after it
started is stopped (`morca._internal.heartbeat`), as a failed attempt, and its run
fails, to be retried by the scheduler as any failed run is. A step can't be
interrupted where it is, so the run's process exits: its other partitions
and the step's own retries wait for the run's retry.

`morca.tables` refuses a scan of a dataset the step didn't declare in
`reads`, and a commit to one it didn't declare in `writes`, so the graph of
pipelines and datasets that `describe` gives is what the steps do.
"""

from std.reflection import reflect, reflect_fn

from dista.codec import decode, encode
from dista.seq import Seq

from morca.ctx import Ctx

comptime _DEFER = "morca: defer "
"""Starts the message of the error `defer` makes."""


def defer(seconds: Int, why: String = "") -> Error:
    """An error a step raises to say it can't do its work yet: try again
    in `seconds` (at least 1). Raised, it ends the attempt `deferred`
    instead of failed, and spends none of the step's retries or the run's.
    """
    return Error(_DEFER, max(seconds, 1), ": ", why)


def deferred_for(error: StringSpan) -> Int:
    """The seconds a `defer` error asks to wait, or 0 for another error."""
    if not error.startswith(_DEFER):
        return 0
    var rest = error[byte = _DEFER.byte_length() :]
    var colon = rest.find(":").or_else(-1)
    if colon <= 0:
        return 0
    try:
        return max(Int(rest[byte=:colon]), 1)
    except:
        return 0


def deferred_why(error: StringSpan) -> String:
    """The reason a `defer` error gives."""
    var colon = error.find(":", _DEFER.byte_length()).or_else(-1)
    return String(error[byte = colon + 1 :].strip()) if colon >= 0 else String()


def _is_dataset(name: StaticString) -> Bool:
    """Whether `name` is `namespace.table`: a dot with a name either side,
    and nothing that would leave the warehouse."""
    var dot = name.rfind(".").or_else(-1)
    return (
        dot > 0
        and dot < name.byte_length() - 1
        and "/" not in name
        and ".." not in name
    )


@fieldwise_init
struct StepKind(Equatable, TrivialRegisterPassable, Writable):
    """Whether a step runs once per partition or once per run."""

    var value: Int

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def write_to(self, mut writer: Some[Writer]):
        writer.write("gather" if self.value == 1 else "mapped")


comptime Mapped = StepKind(0)
"""Runs once per partition of the run."""
comptime Gather = StepKind(1)
"""Runs once per run, over every partition's output of the step before."""


trait StepLike:
    """What a pipeline needs from a step, without knowing its function."""

    comptime A: Copyable & Deinitable
    """The input type."""
    comptime R: Copyable & Deinitable
    """The output type."""

    @staticmethod
    def step_name() -> StaticString:
        """The step's name in its pipeline; empty for `NoStep`."""
        ...

    @staticmethod
    def kind() -> StepKind:
        ...

    @staticmethod
    def upstream() -> StaticString:
        """The name of the step this one follows; empty for a first step."""
        ...

    @staticmethod
    def max_retries() -> Int:
        """How many times a failed attempt is retried, in the same run."""
        ...

    @staticmethod
    def backoff() -> Int:
        """Seconds before the first retry, doubling before each after it."""
        ...

    @staticmethod
    def timeout() -> Int:
        """Seconds an attempt may take before it's stopped; 0 for no limit."""
        ...

    @staticmethod
    def code_version() -> Int:
        """The step's `version=`: raising it says its outputs must be made
        again, so its pipeline's keys are no longer done; 0 when not set."""
        ...

    @staticmethod
    def upstream_function() -> StaticString:
        """The function of the step this one follows; empty for a first step."""
        ...

    @staticmethod
    def function() -> StaticString:
        """The step function's linkage name."""
        ...

    @staticmethod
    def input_type() -> StaticString:
        ...

    @staticmethod
    def output_type() -> StaticString:
        ...

    @staticmethod
    def dataset_reads() -> List[String]:
        """The datasets the step declared in `reads=`."""
        ...

    @staticmethod
    def dataset_writes() -> List[String]:
        """The datasets the step declared in `writes=` or `replaces=`."""
        ...

    @staticmethod
    def dataset_replaces() -> List[String]:
        """The datasets the step declared in `replaces=`: written, with a new
        run replacing their partitions."""
        ...

    @staticmethod
    def check():
        """Asserts at compile time that the step's input matches its edge."""
        ...

    @staticmethod
    def run(mut ctx: Ctx, input: Span[UInt8, _], mut out: List[UInt8]) raises:
        """Decodes the input, calls the function, appends the encoded output."""
        ...


struct NoStep(StepLike):
    """What a first step follows."""

    comptime A = NoneType
    comptime R = NoneType

    @staticmethod
    def step_name() -> StaticString:
        return ""

    @staticmethod
    def kind() -> StepKind:
        return Mapped

    @staticmethod
    def upstream() -> StaticString:
        return ""

    @staticmethod
    def max_retries() -> Int:
        return 0

    @staticmethod
    def backoff() -> Int:
        return 0

    @staticmethod
    def timeout() -> Int:
        return 0

    @staticmethod
    def code_version() -> Int:
        return 0

    @staticmethod
    def upstream_function() -> StaticString:
        return ""

    @staticmethod
    def function() -> StaticString:
        return ""

    @staticmethod
    def input_type() -> StaticString:
        return ""

    @staticmethod
    def output_type() -> StaticString:
        return ""

    @staticmethod
    def dataset_reads() -> List[String]:
        return List[String]()

    @staticmethod
    def dataset_writes() -> List[String]:
        return List[String]()

    @staticmethod
    def dataset_replaces() -> List[String]:
        return List[String]()

    @staticmethod
    def check():
        pass

    @staticmethod
    def run(mut ctx: Ctx, input: Span[UInt8, _], mut out: List[UInt8]) raises:
        raise Error("NoStep doesn't run")


struct Step[
    name: StaticString,
    A_: Copyable & Deinitable,
    R_: Copyable & Deinitable,
    f: def(mut Ctx, A_) thin raises -> R_,
    kind_: StepKind,
    *,
    after: StepLike = NoStep,
    retries: Int = 0,
    backoff_seconds: Int = 0,
    timeout_seconds: Int = 0,
    reads: List[StaticString] = [],
    writes: List[StaticString] = [],
    replaces: List[StaticString] = [],
    version: Int = 0,
](StepLike):
    """A step named `name` running `f` on an `A_` to make an `R_`."""

    comptime A = Self.A_
    comptime R = Self.R_

    @staticmethod
    def step_name() -> StaticString:
        return Self.name

    @staticmethod
    def kind() -> StepKind:
        return Self.kind_

    @staticmethod
    def upstream() -> StaticString:
        return Self.after.step_name()

    @staticmethod
    def max_retries() -> Int:
        return Self.retries

    @staticmethod
    def backoff() -> Int:
        return Self.backoff_seconds

    @staticmethod
    def timeout() -> Int:
        return Self.timeout_seconds

    @staticmethod
    def code_version() -> Int:
        return Self.version

    @staticmethod
    def upstream_function() -> StaticString:
        return Self.after.function()

    @staticmethod
    def function() -> StaticString:
        return reflect_fn[Self.f].linkage_name()

    @staticmethod
    def input_type() -> StaticString:
        return reflect[Self.A_].name()

    @staticmethod
    def output_type() -> StaticString:
        return reflect[Self.R_].name()

    @staticmethod
    def dataset_reads() -> List[String]:
        var out = List[String]()
        comptime for i in range(len(Self.reads)):
            comptime d = Self.reads[i]
            out.append(String(d))
        return out^

    @staticmethod
    def dataset_writes() -> List[String]:
        var out = List[String]()
        comptime for i in range(len(Self.writes)):
            comptime d = Self.writes[i]
            out.append(String(d))
        comptime for i in range(len(Self.replaces)):
            comptime d = Self.replaces[i]
            if String(d) not in out:
                out.append(String(d))
        return out^

    @staticmethod
    def dataset_replaces() -> List[String]:
        var out = List[String]()
        comptime for i in range(len(Self.replaces)):
            comptime d = Self.replaces[i]
            out.append(String(d))
        return out^

    @staticmethod
    def check():
        comptime assert Self.name != "", "a step needs a name"
        comptime assert Self.retries >= 0, "retries can't be negative"
        comptime assert (
            Self.backoff_seconds >= 0
        ), "backoff_seconds can't be negative"
        comptime assert (
            Self.timeout_seconds >= 0
        ), "timeout_seconds can't be negative"
        comptime assert Self.version >= 0, "version can't be negative"
        comptime for i in range(len(Self.reads)):
            comptime assert _is_dataset(
                Self.reads[i]
            ), "a dataset is named namespace.table"
        comptime for i in range(len(Self.writes)):
            comptime assert _is_dataset(
                Self.writes[i]
            ), "a dataset is named namespace.table"
        comptime for i in range(len(Self.replaces)):
            comptime assert _is_dataset(
                Self.replaces[i]
            ), "a dataset is named namespace.table"
        comptime a = reflect[Self.A_].name()
        comptime if Self.after.step_name() == "":
            # A first step takes the pipeline's partition key, which the
            # pipeline checks: a step doesn't know it.
            pass
        elif Self.kind_ == Gather:
            comptime if Self.after.kind() == Gather:
                comptime assert (
                    a == reflect[Self.after.R].name()
                ), "a gather step after a gather step takes its output"
            else:
                comptime assert (
                    a == reflect[Seq[Self.after.R]].name()
                ), "a gather step takes a Seq of the mapped step's output"
        else:
            comptime assert (
                Self.after.kind() == Mapped
            ), "a mapped step can't follow a gather step"
            comptime assert (
                a == reflect[Self.after.R].name()
            ), "a mapped step takes the output of the step it follows"

    @staticmethod
    def run(mut ctx: Ctx, input: Span[UInt8, _], mut out: List[UInt8]) raises:
        var pos = 0
        var a = decode[Self.A_](input, pos)
        if pos != len(input):
            raise Error(
                Self.name, ": ", len(input) - pos, " input bytes left over"
            )
        var r = Self.f(ctx, a)
        encode(r, out)
