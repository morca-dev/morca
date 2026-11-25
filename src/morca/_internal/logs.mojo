"""Where attempts' logs, drivers' logs and runs' timelines go.

With `MORCA_LOGS` set, each attempt logs to
`<MORCA_LOGS>/<pipeline>/<run>/<step>/<partition>/<attempt>.log` (the
partition is `_run` for a gather step, and a keyed one's `/` is written
`%2F`, `morca.name.path_segment`), a run of a pipeline with dista
tasks leaves its timeline at `<MORCA_LOGS>/<pipeline>/<run>/timeline.json`,
and the scheduler keeps a run's output at `.../<run>/driver.log`. Without
it, logs go to stdout only.

`MORCA_LOGS` is a directory, or a location in object storage such as
`s3://bucket/morca/logs` (objectstore's `FileIOResolver`, configured from the
`AWS_*` environment). An object can't be appended to, so for a remote root
a log is written to a staging file under `MORCA_LOG_STAGE` (default
`$TMPDIR/morca-logs`) and `publish`ed when it's complete: an attempt's when
the attempt ends, a timeline when the run does. `attempts.log` records
where the log ends up, which `read_location` reads either way.

Secrets are masked in every log written here: `MORCA_SECRETS` names the
environment variables that hold a run's secrets (`morca register --secret`),
and `mask` replaces their values with `***`.
"""

from std.ffi import c_int, external_call
from std.os import getenv, makedirs, remove
from std.os.path import exists

from objectstore.fileio import FileIOResolver

from morca.civil import Civil
from morca.name import path_segment


comptime _MASK = "***"


def _secret_values() -> List[String]:
    """The values of the variables `MORCA_SECRETS` names; short ones are
    left out, since masking them would hide ordinary text."""
    var out = List[String]()
    for n in getenv("MORCA_SECRETS").split(","):
        var name = String(n.strip())
        if not name:
            continue
        var v = getenv(name)
        if v.byte_length() >= 4:
            out.append(v^)
    return out^


def mask(text: String) -> String:
    """`text` with every secret's value replaced by `***`."""
    var out = text
    for v in _secret_values():
        out = out.replace(v, _MASK)
    return out^


def mask_bytes(data: Span[UInt8, _]) -> List[UInt8]:
    """`mask`, on bytes that may not be UTF-8."""
    return mask_values(data, _secret_values())


def mask_values(data: Span[UInt8, _], values: List[String]) -> List[UInt8]:
    """`data` with each of `values` replaced by `***`: what `mask_bytes`
    does with the run's secrets, for a process that doesn't have them in its
    environment (the scheduler, keeping a Kubernetes run's pod logs). Values
    shorter than 4 bytes are left, as `mask` leaves them."""
    var out = List[UInt8](capacity=len(data))
    for b in data:
        out.append(b)
    for v in values:
        if v.byte_length() < 4:
            continue
        var pat = v.as_bytes()
        var n = len(pat)
        var got = List[UInt8](capacity=len(out))
        var i = 0
        while i < len(out):
            var hit = i + n <= len(out)
            if hit:
                for k in range(n):
                    if out[i + k] != pat[k]:
                        hit = False
                        break
            if hit:
                for c in _MASK.as_bytes():
                    got.append(c)
                i += n
            else:
                got.append(out[i])
                i += 1
        out = got^
    return out^


def mask_main() -> Int:
    """`mask`: copies stdin to stdout a line at a time, `mask_bytes`ed, until
    stdin ends. A Kubernetes run with secrets (`morca._internal.kube`) has
    its pods' output go through it, so their logs never hold the values."""
    var buf = List[UInt8](length=65536, fill=0)
    var line = List[UInt8]()
    while True:
        var n = external_call["read", Int](c_int(0), buf.unsafe_ptr(), 65536)
        if n <= 0:
            break
        for i in range(n):
            line.append(buf[i])
            if buf[i] == UInt8(ord("\n")):
                _write_out(mask_bytes(Span(line)))
                line.clear()
    if len(line) > 0:
        _write_out(mask_bytes(Span(line)))
    return 0


def _write_out(data: List[UInt8]):
    var at = 0
    while at < len(data):
        var n = external_call["write", Int](
            c_int(1), data.unsafe_ptr().unsafe_offset(at), len(data) - at
        )
        if n <= 0:
            return
        at += n


def logs_dir() -> String:
    return getenv("MORCA_LOGS")


def is_remote(location: String) -> Bool:
    """Whether `location` is in object storage, not on this machine."""
    return "://" in location and not location.startswith("file://")


def run_dir(pipeline: String, run: Int) -> String:
    """The run's directory under `MORCA_LOGS`, or "" without it."""
    var root = logs_dir()
    if not root:
        return ""
    return String(root.rstrip("/"), "/", pipeline, "/", run)


def stage_of(location: String) -> String:
    """Where a log bound for `location` is written first: `location` itself
    on this machine, else its path under `MORCA_LOG_STAGE`."""
    if not is_remote(location):
        return location
    var root = getenv("MORCA_LOG_STAGE")
    if not root:
        root = String(getenv("TMPDIR", "/tmp").rstrip("/"), "/morca-logs")
    var rel = location[byte = location.find("://").or_else(-1) + 3 :]
    return String(root, "/", rel)


def _parent(path: String) -> String:
    var at = path.rfind("/").or_else(-1)
    return String(path[byte=:at]) if at > 0 else String(".")


def attempt_log(
    pipeline: String, run: Int, step: String, partition: String, attempt: Int
) raises -> String:
    """Where the attempt's log ends up, `stage_of` it ready to be written;
    "" without `MORCA_LOGS`."""
    var dir = run_dir(pipeline, run)
    if not dir:
        return ""
    # A keyed partition can hold `/` (`owner/name`): one directory still.
    dir.write("/", step, "/", path_segment(partition) if partition else "_run")
    var log = String(dir, "/", attempt, ".log")
    makedirs(_parent(stage_of(log)), exist_ok=True)
    return log^


def publish(location: String) raises:
    """Copies a remote `location`'s staging file to it; nothing for a local
    one, which was written in place."""
    if not is_remote(location):
        return
    var data: List[UInt8]
    with open(stage_of(location), "r") as f:
        data = f.read_bytes()
    FileIOResolver().write(location, Span(mask_bytes(Span(data))))


def write_location(location: String, data: Span[UInt8, _]) raises:
    """Writes `data` to `location`, local or remote, replacing it, with
    secrets masked. A local file is replaced whole: written beside it and
    renamed over it, so a reader (or a `put-log` killed with its instance)
    never leaves or sees it truncated, as an object's PUT doesn't."""
    var masked = mask_bytes(data)
    if is_remote(location):
        FileIOResolver().write(location, Span(masked))
        return
    makedirs(_parent(location), exist_ok=True)
    var tmp = String(
        location, ".", Int(external_call["getpid", c_int]()), ".tmp"
    )
    try:
        with open(tmp, "w") as f:
            f.write_bytes(Span(masked))
    except e:
        try:
            remove(tmp)
        except:
            pass
        raise e
    var to = location
    if (
        external_call["rename", c_int](
            tmp.as_c_string_span(), to.as_c_string_span()
        )
        != 0
    ):
        try:
            remove(tmp)
        except:
            pass
        raise Error("morca: can't replace ", location)


def read_location(location: String) raises -> List[UInt8]:
    """What's at `location`, local or remote; raises if there's nothing."""
    if is_remote(location):
        return FileIOResolver().read_all(location)
    with open(location, "r") as f:
        return f.read_bytes()


def location_exists(location: String) -> Bool:
    if not is_remote(location):
        return exists(location)
    try:
        _ = FileIOResolver().read_all(location)
        return True
    except:
        return False


def utc_now() -> String:
    """The time now, to the second, as `YYYY-MM-DDTHH:MM:SSZ`."""
    return String(Civil.of(external_call["time", Int64](Int(0))), "Z")
