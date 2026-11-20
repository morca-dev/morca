"""What a crash left in a run's output: the stack dump Mojo's runtime prints
on a fatal signal (a segfault, `abort`, a failed bounds check), cut down to
a line for the error of the attempt it ended.

A dump's frames read `#<n> 0x<address> <function> <file>:<line>:<col>` when
the runtime finds `llvm-symbolizer` (`LLVM_SYMBOLIZER_PATH`, which the
project image sets, else `PATH`) and the binary has line tables (`mojo
build -g1`, as the image builds it). Without the symbolizer the dump starts
`Stack dump without symbol names` and its frames are addresses. A line
`ABORT: ...` or `At: ...: Assert Error: ...` just before the frames is what
`abort` or a failed `debug_assert` said.

The runners call `crash_summary` on the output of a start that ended: the
local runner when it reaps the process (`morca._internal.scheduler`), the ec2 runner's
`keep-log` on the head (`morca._internal.ec2`), and the Kubernetes runner as it keeps
the driver pod's log (`morca._internal.kube`); each marks the attempts the process
left `running` as failed with it.
"""

comptime _FRAMES = 4
"""How many of the dump's frames the summary names."""
comptime _LIMIT = 300
"""The most bytes of the message kept."""


def crash_summary(output: String) -> String:
    """`crashed: <message>; at <function> <file:line>, ...` for the last
    stack dump in `output` after its last `--- start` line (the runners
    mark each start so), or empty if there's none. The frames named are
    the first with a line number outside Mojo's standard library."""
    var lines = output.splitlines()
    var first = 0
    for i in range(len(lines)):
        if lines[i].startswith("--- start "):
            first = i + 1
    var dump = -1
    var symbols = True
    for i in range(first, len(lines)):
        var l = lines[i].strip()
        if l.startswith("#0 0x"):
            dump = i
            symbols = True
        elif l.startswith("Stack dump without symbol names"):
            dump = i
            symbols = False
    if dump < 0:
        return ""
    var out = String("crashed")
    if dump > first:
        var said = String(lines[dump - 1].strip())
        var cut = String()
        if said.startswith("ABORT: "):
            cut = String(said[byte=7:])
        elif said.startswith("At: "):
            cut = String(said[byte=4:])
        if cut:
            out.write(": ", _clip(cut))
    if not symbols:
        out.write(
            "; its stack dump has no symbol names (no llvm-symbolizer:",
            " set LLVM_SYMBOLIZER_PATH)",
        )
        return out^
    var named = List[String]()
    for i in range(dump, len(lines)):
        var l = String(lines[i].strip())
        if not l.startswith("#"):
            break
        # `#4 0x... boom /p/x.mojo:9:11`: the function and where it is. A
        # function the symbolizer names by its linkage name, such as
        # `morca::step::Step::run[<parameters>](<arguments>)`, is cut to
        # its path.
        var parts = l.split(" ", 2)
        if len(parts) < 3:
            continue
        var rest = String(parts[2])
        var sp = rest.rfind(" ").or_else(-1)
        if rest.startswith("(") or sp < 0:
            continue
        var at = String(rest[byte = sp + 1 :])
        if at.endswith(")") or at.startswith("Mojo/stdlib/"):
            continue
        var end = sp
        for c in ["[", "("]:
            var k = rest.find(c).or_else(-1)
            if k > 0 and k < end:
                end = k
        var name = String(rest[byte=:end])
        named.append(String(name, " ", at))
        if len(named) == _FRAMES:
            break
    if len(named) == 0:
        out.write(
            "; its stack dump has no line numbers (build with mojo build",
            " -g1)",
        )
        return out^
    out.write("; at ")
    for i in range(len(named)):
        out.write(", " if i else "", named[i])
    return out^


def crashed_by_signal(code: Int) -> Bool:
    """Whether an exit code (128 + the signal for a process a signal
    killed) is a crash's: SIGILL, SIGTRAP, SIGABRT, SIGBUS (7 on Linux, 10
    on macOS), SIGFPE or SIGSEGV, not a kill or an interrupt."""
    var sig = code - 128
    return sig in (4, 5, 6, 7, 8, 10, 11)


def _clip(s: String) -> String:
    var n = s.byte_length()
    if n <= _LIMIT:
        return s
    n = _LIMIT
    # Cut where a character starts.
    while n > 0 and (s.as_bytes()[n] & 0xC0) == 0x80:
        n -= 1
    return String(s[byte=:n], "...")
