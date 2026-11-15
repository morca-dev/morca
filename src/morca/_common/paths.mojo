"""Paths made absolute, for the command line and for where datasets are."""

from std.ffi import external_call


def absolute(path: String) raises -> String:
    """`path`, made absolute against the working directory."""
    if path.startswith("/"):
        return path
    var buf = List[UInt8](length=4096, fill=0)
    var r = external_call["getcwd", Int](buf.unsafe_ptr(), Int(4096))
    if r == 0:
        raise Error("absolute: getcwd failed")
    var n = 0
    while buf[n] != 0:
        n += 1
    var cwd = String(from_utf8_lossy=Span(buf)[:n])
    var rel = path.removeprefix("./")
    return String(cwd, "/", rel)
