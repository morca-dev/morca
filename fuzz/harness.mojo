"""What every morca fuzz harness shares: replaying a saved input, and the
session's settings.

A harness's target writes the input it's about to run to
build/fuzz-<name>-last.bin first, so a hard abort still leaves the crashing
input behind; mozz saves the ones it catches to build/fuzz-crashes/<name>.
FUZZ_RUNS sets the iterations (default 100,000), FUZZ_REPLAY=<file> runs one
saved input instead. An error whose message contains "assertion failed" is a
finding; any other error is the code rejecting bad input, as it should.
"""

from std.os import getenv

from mozz import FuzzConfig, FuzzTarget, fuzz


def save_last(name: StaticString, data: List[UInt8]) raises:
    with open(String("build/fuzz-", name, "-last.bin"), "w") as f:
        f.write_bytes(Span(data))


def check(cond: Bool, msg: String) raises:
    """Raises a finding if `cond` is false."""
    if not cond:
        raise Error("assertion failed: ", msg)


def only_findings(e: Error) raises:
    """Re-raises `e` if it's a finding, and lets a rejection go."""
    if "assertion failed" in String(e):
        raise e.copy()


def run_harness[
    target: FuzzTarget
](name: StaticString, seeds: List[List[UInt8]], max_len: Int = 1024) raises:
    var replay = getenv("FUZZ_REPLAY")
    if replay:
        var data: List[UInt8]
        with open(replay, "r") as f:
            data = f.read_bytes()
        target(data)
        print("replayed", replay, "without a finding")
        return
    fuzz(
        target,
        FuzzConfig(
            max_runs=Int(getenv("FUZZ_RUNS", "100000")),
            seed=0,
            crash_dir=String("build/fuzz-crashes/", name),
            max_input_len=max_len,
        ),
        seeds,
    )


def bytes_of(s: StringSpan) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^
