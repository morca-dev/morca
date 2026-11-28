"""Draining a member mid-run (docs/groups.md, "Demand per group"), the
worker's side: the dista workers it runs for other workers' runs
(`morca._internal.run_cluster`), their addresses, and draining them when
the scheduler says.

- **Addresses.** dista names the workers it would drain by their object
  servers' `ip:port`. A member's dista worker listens on a port of its
  own choosing, which this worker reads from the process
  (`listen_port`: `/proc` on Linux, `lsof` on macOS), and its address is
  that port at the IP `--advertise` resolves to, as dista's is. Each claim
  sends the addresses learned (`member_addresses`).
- **Draining.** A claim's answer lists the members to drain (`"drain"`).
  This worker drains each with dista's drain through the pipeline's binary
  (`<binary> dista-drain <head> <address>`, the run's token in its
  environment): the head sends it no more work and moves what it holds,
  and it exits once done (dista bounds that with `DISTA_DRAIN_SECONDS`,
  25). dista refuses to drain a group's last worker while the group has
  tasks: the refusal goes back with the next claim (`kept`), and the
  member runs on. One still running `DRAIN_GRACE_SECONDS` past dista's
  bound is killed (`overdue`).
"""

from std.ffi import c_int, external_call
from std.memory import stack_allocation
from std.os import getenv, listdir
from std.sys.info import CompilationTarget

from dista.socket import resolve_ipv4

from morca._internal.http_store import Body
from morca._internal.proc import capture
from morca._internal.worker_demand import env_value

comptime DRAIN_SECONDS = 3.0
"""The most `dista-drain` may take."""
comptime DRAIN_GRACE_SECONDS = 15.0
"""How long past `DISTA_DRAIN_SECONDS` a drained member may still run."""


def _hex(s: String) -> Int:
    """`s`'s hex digits as a number; -1 if it has another character."""
    var n = 0
    for b in s.as_bytes():
        var c = Int(b)
        if c >= ord("0") and c <= ord("9"):
            n = n * 16 + c - ord("0")
        elif c >= ord("A") and c <= ord("F"):
            n = n * 16 + c - ord("A") + 10
        elif c >= ord("a") and c <= ord("f"):
            n = n * 16 + c - ord("a") + 10
        else:
            return -1
    return n


def _socket_inode(path: String) -> Int:
    """The inode of the socket the fd link `path` is (`socket:[123]`); -1
    if it's no socket."""
    var p = List[UInt8](capacity=path.byte_length() + 1)
    for b in path.as_bytes():
        p.append(b)
    p.append(0)
    var buf = stack_allocation[128, UInt8]()
    var n = external_call["readlink", Int](p.unsafe_ptr(), buf, 127)
    comptime PREFIX = "socket:["
    if n <= PREFIX.byte_length():
        return -1
    for i in range(PREFIX.byte_length()):
        if buf[unsafe_offset=i] != PREFIX.as_bytes()[i]:
            return -1
    var inode = 0
    for i in range(PREFIX.byte_length(), n):
        var c = Int(buf[unsafe_offset=i])
        if c == ord("]"):
            return inode
        if c < ord("0") or c > ord("9"):
            return -1
        inode = inode * 10 + c - ord("0")
    return -1


def listen_ports_in(table: String, inodes: Dict[Int, Bool]) -> List[Int]:
    """The ports of the listening sockets of `table` (`/proc/net/tcp`'s
    form) whose inodes are among `inodes`."""
    var out = List[Int]()
    var first = True
    for line in table.split("\n"):
        if first:
            first = False  # the header
            continue
        var f = line.split()
        if len(f) < 10 or f[3] != "0A":
            continue
        var inode: Int
        try:
            inode = Int(String(f[9]))
        except:
            continue
        if inode not in inodes:
            continue
        var local = String(f[1])
        var colon = local.rfind(":").or_else(-1)
        if colon < 0:
            continue
        var port = _hex(String(local[byte = colon + 1 :]))
        if port > 0 and port not in out:
            out.append(port)
    return out^


def lsof_ports(text: String) -> List[Int]:
    """The ports of `lsof -Fn`'s `n*:41234` lines."""
    var out = List[Int]()
    for line in text.split("\n"):
        if not line.startswith("n"):
            continue
        var l = String(line)
        var colon = l.rfind(":").or_else(-1)
        if colon < 0:
            continue
        try:
            var port = Int(String(l[byte = colon + 1 :]))
            if port > 0 and port not in out:
                out.append(port)
        except:
            pass
    return out^


def listen_ports(pid: Int) -> List[Int]:
    """The TCP ports process `pid` listens on; none if they can't be read."""
    comptime if CompilationTarget.is_linux():
        try:
            var inodes = Dict[Int, Bool]()
            var fds = String("/proc/", pid, "/fd")
            for name in listdir(fds):
                var inode = _socket_inode(String(fds, "/", name))
                if inode >= 0:
                    inodes[inode] = True
            var out = List[Int]()
            for t in ["tcp", "tcp6"]:
                try:
                    with open(String("/proc/", pid, "/net/", t), "r") as f:
                        for p in listen_ports_in(f.read(), inodes):
                            if p not in out:
                                out.append(p)
                except:
                    pass
            return out^
        except:
            return List[Int]()
    else:
        try:
            var got = capture(
                [
                    String("/usr/sbin/lsof"),
                    String("-nP"),
                    String("-a"),
                    String("-p"),
                    String(pid),
                    String("-iTCP"),
                    String("-sTCP:LISTEN"),
                    String("-Fn"),
                ],
                3.0,
            )
            return lsof_ports(got[1])
        except:
            return List[Int]()


def object_port(ports: List[Int], env: List[String]) -> Int:
    """A dista worker's object server's port among the `ports` it listens
    on: the one that isn't its metrics port (`DISTA_METRICS_PORT` in its
    `env`); 0 when that leaves none or several."""
    var metrics = env_value(env, "DISTA_METRICS_PORT")
    var found = 0
    for p in ports:
        if metrics and String(p) == metrics:
            continue
        if found:
            return 0
        found = p
    return found


def drain_kill_seconds(env: List[String]) -> Float64:
    """How long a drained member may run before it's killed: its
    `DISTA_DRAIN_SECONDS` (25) and `DRAIN_GRACE_SECONDS`."""
    var secs = 25.0
    try:
        var v = env_value(env, "DISTA_DRAIN_SECONDS")
        if v:
            secs = max(Float64(v), 0.0)
    except:
        pass
    return secs + DRAIN_GRACE_SECONDS


@fieldwise_init
struct MemberProc(Copyable, Movable):
    """A member's dista worker, as this worker runs it."""

    var member: Int
    var binary: String
    var head: String
    var env: List[String]
    """Its environment, with the run's `DISTA_TOKEN`."""
    var address: String
    """Its object server's `ip:port`; empty until learned."""
    var drained_at: Float64
    """When dista was asked to drain it (monotonic seconds); 0 if not."""


struct MemberDrains(Movable):
    """This worker's members' dista workers, by pid, what to send of them
    with the next claim, and their draining."""

    var procs: Dict[Int, MemberProc]
    var kept: List[Tuple[Int, String]]
    """Members dista wouldn't drain, with why, not sent yet."""

    def __init__(out self):
        self.procs = Dict[Int, MemberProc]()
        self.kept = List[Tuple[Int, String]]()

    def add(
        mut self,
        pid: Int,
        member: Int,
        binary: String,
        head: String,
        env: List[String],
        token: String,
    ):
        var e = env.copy()
        e.append(String("DISTA_TOKEN=", token))
        self.procs[pid] = MemberProc(member, binary, head, e^, "", 0)

    def ended(mut self, pid: Int):
        _ = self.procs.pop(pid, MemberProc(0, "", "", List[String](), "", 0))

    def learn(mut self, advertise: String):
        """The addresses of the members' dista workers not known yet."""
        if not advertise:
            return
        var ip: String
        try:
            var a = resolve_ipv4(advertise)
            ip = String(
                Int(a[0]), ".", Int(a[1]), ".", Int(a[2]), ".", Int(a[3])
            )
        except:
            return
        var found = List[Tuple[Int, Int]]()
        for e in self.procs.items():
            if e.value.address:
                continue
            var port = object_port(listen_ports(e.key), e.value.env)
            if port > 0:
                found.append((e.key, port))
        for f in found:
            try:
                self.procs[f[0]].address = String(ip, ":", f[1])
            except:
                pass

    def addresses_json(self) -> String:
        """The claim's `member_addresses`: `[{"member": 5, "address":
        "10.0.0.3:41234"}]`."""
        var out = String("[")
        var first = True
        for e in self.procs.items():
            if not e.value.address:
                continue
            out.write(
                "" if first else ", ",
                Body()
                .int("member", Int64(e.value.member))
                .text("address", e.value.address)
                .finish(),
            )
            first = False
        out.write("]")
        return out^

    def kept_json(self) -> String:
        """The claim's `kept`: `[{"member": 5, "why": "..."}]`."""
        var out = String("[")
        for i in range(len(self.kept)):
            out.write(
                ", " if i else "",
                Body()
                .int("member", Int64(self.kept[i][0]))
                .text("why", self.kept[i][1])
                .finish(),
            )
        out.write("]")
        return out^

    def sent(mut self):
        """The refusals went with a claim."""
        self.kept.clear()

    def drain(mut self, member: Int, now: Float64):
        """Drains `member`'s dista worker through its head, unless it is
        being drained already or its address isn't known; a refusal is
        kept for the next claim."""
        var pid = -1
        for e in self.procs.items():
            if e.value.member == member:
                pid = e.key
        if pid < 0:
            return
        try:
            ref p = self.procs[pid]
            if p.drained_at > 0 or not p.address:
                return
            var why = String()
            try:
                var got = capture(
                    [p.binary, "dista-drain", p.head, p.address],
                    DRAIN_SECONDS,
                    env=p.env,
                )
                if got[0] != 0:
                    why = String(got[1].strip())
                    if not why:
                        why = String("dista-drain exited ", got[0])
            except e:
                why = String(e)
            if why:
                print("member", member, "not drained:", why, flush=True)
                self.kept.append((member, why))
                return
            p.drained_at = now
            print("draining member", member, "pid", pid, flush=True)
        except:
            pass

    def overdue(self, now: Float64) -> List[Int]:
        """The pids of drained members still running past their time."""
        var out = List[Int]()
        for e in self.procs.items():
            ref p = e.value
            if p.drained_at > 0 and now - p.drained_at > drain_kill_seconds(
                p.env
            ):
                out.append(e.key)
        return out^
