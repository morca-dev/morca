"""Table maintenance for a project's datasets: snapshot expiry.

The `morca` binary doesn't link iceberg, so expiry runs in a binary of the
project's own, `bin/morca_maintain.mojo`,

```mojo
from morca.maintain import maintain_main

def main() raises:
    maintain_main()
```

which `morca expire` and the scheduler's periodic expiry run (it is found as
`$MORCA_MAINTAIN`, beside the `morca` binary, or on `PATH`). Run by hand it
takes the snapshots to keep besides the policy's with `--retain`; `morca
expire` works those out from Postgres (`morca._internal.expiry.retained`) and passes
them, which is how a run that can still resume keeps the snapshots it read
and the ones it committed.

    morca_maintain expire <dataset> [--older-than 30d|12h|90m|<ms>]
        [--keep N] [--retain ID,...] [--if-policy] [--dry-run] [--report]

Without `--older-than` and `--keep` the table's own
`history.expire.max-snapshot-age-ms` and `history.expire.min-snapshots-to-keep`
decide (iceberg's defaults where unset: five days, one snapshot);
`--if-policy` expires nothing when the table has no
`history.expire.max-snapshot-age-ms`, which is how the scheduler leaves
tables morca didn't create alone. An expiry gives a table morca's metadata
defaults (`write.metadata.delete-after-commit.enabled`,
`write.metadata.previous-versions-max`) when it lacks them, so its own
commit already deletes the old metadata files it drops from the log. `--report` lists `metadata/` before and
after, to count its files.

Both commands run inside liblake (`lake_expire`, `lake_data`, #471), as
`morca.tables` does, so `morca_maintain` compiles no iceberg; with
`-D MORCA_LAKE_SOURCE=1` the library's code is compiled in instead.
"""

from std.sys import argv

from morca._lake.abi import Enc, Slots
from morca._lake.client import api, take_bytes, take_error
from morca._lake.expire import ExpireAsk, Expiry


comptime USAGE = """usage:
  morca_maintain expire <dataset> [--older-than 30d|12h|90m|<ms>] [--keep N]
      [--retain ID,...] [--if-policy] [--dry-run] [--report]
  morca_maintain data <dataset> [--snapshot ID] [--where COL:OP:VALUE]...
      [--columns A,B] [--sort [-]COL] [--offset N] [--limit N]
      [--chart-x COL --chart-y A,B [--chart-agg avg|sum]] [--csv PATH]
      [--max-rows N] [--seconds S] [--memory-mb M] [--no-partitions]
      [--no-rows]"""


def parse_duration_ms(text: String) raises -> Int64:
    """`30d`, `12h`, `90m`, `45s` or plain milliseconds."""
    if text.byte_length() == 0:
        raise Error("morca: an empty duration")
    var unit: Int64 = 1
    var digits = text
    if text.endswith("d"):
        unit = 86_400_000
    elif text.endswith("h"):
        unit = 3_600_000
    elif text.endswith("m"):
        unit = 60_000
    elif text.endswith("s"):
        unit = 1_000
    if unit != 1:
        digits = String(text[byte = : text.byte_length() - 1])
    try:
        var n = Int64(Int(digits))
        if n < 0:
            raise Error("negative")
        return n * unit
    except:
        raise Error("morca: not a duration: ", text, " (30d, 12h, 90m, ms)")


def expire_dataset(ask: ExpireAsk) raises -> Expiry:
    """Expires `ask.dataset`'s snapshots, inside liblake
    (`morca._lake.expire_impl`): older than `ask.older_than_ms` ago (or by
    the table's properties when that is -1), keeping at least `ask.keep`
    (or the table's `history.expire.min-snapshots-to-keep`) and every
    snapshot in `ask.retain`."""
    var a = api()
    var e = ask.encode()
    var got = Slots()
    var err = Slots()
    var rc = a.expire(e.addr(), len(e), got.addr, err.addr)
    _ = e^
    if rc != 0:
        raise take_error(a, err)
    var b = take_bytes(a, got)
    var expiry = Expiry.decode(Int(b.unsafe_ptr()), len(b))
    _ = b^  # read through its address above
    return expiry^


def data_text(args: List[String]) raises -> String:
    """What `morca_maintain data` prints for `args` (those after `data`),
    read inside liblake (`morca._lake.dataread`)."""
    var a = api()
    var e = Enc()
    e.strs(args)
    var got = Slots()
    var err = Slots()
    var rc = a.data(e.addr(), len(e), got.addr, err.addr)
    _ = e^
    if rc != 0:
        raise take_error(a, err)
    var b = take_bytes(a, got)
    return String(unsafe_from_utf8=Span(b))


def _usage(msg: String = ""):
    if msg:
        print(msg)
    print(USAGE)


def maintain_main() raises:
    """The `morca_maintain` command (see the module doc)."""
    var args = List[String]()
    for a in argv():
        args.append(String(a))
    if len(args) >= 3 and args[1] == "data":
        # The UI's data view (morca._lake.dataread, in liblake).
        var rest = List[String]()
        for k in range(2, len(args)):
            rest.append(args[k])
        print(data_text(rest))
        return
    if len(args) < 3 or args[1] != "expire":
        _usage()
        raise Error("morca_maintain: expected `expire <dataset>`")
    var dataset = args[2]
    var older: Int64 = -1
    var keep = -1
    var retain = List[Int64]()
    var if_policy = False
    var dry_run = False
    var report = False
    var i = 3
    while i < len(args):
        var a = args[i]
        if a == "--older-than" and i + 1 < len(args):
            older = parse_duration_ms(args[i + 1])
            i += 2
        elif a == "--keep" and i + 1 < len(args):
            keep = Int(args[i + 1])
            i += 2
        elif a == "--retain" and i + 1 < len(args):
            for part in args[i + 1].split(","):
                if part.byte_length() > 0:
                    retain.append(Int64(Int(String(part))))
            i += 2
        elif a == "--if-policy":
            if_policy = True
            i += 1
        elif a == "--dry-run":
            dry_run = True
            i += 1
        elif a == "--report":
            report = True
            i += 1
        else:
            _usage()
            raise Error("morca_maintain: unknown argument: ", a)
    print(
        expire_dataset(
            ExpireAsk(dataset, older, keep, retain^, if_policy, dry_run, report)
        )
    )
