"""`morca --remote <url> host list|drain|undrain|remove ...`: `morca host`
(`morca._internal.hosts`) against a deployed `morca ui`, as the user
`morca login` logged in (`morca._internal.remote`).

`list` reads `/api/workers`, which needs no login, and prints what the
command prints over the database; a host is `not seen` after this
machine's `MORCA_STALE_SECONDS`, as it is there. `drain`, `undrain` and
`remove [--force]` post to `/api/hosts/<id>/...` with the token: the same
code, checks and `orca.audit` rows as the Pools page's buttons, from `cli`.
"""

from json import loads

from morca._internal.db.live import stale_limit
from morca._internal.hosts import HOST_USAGE, host_line
from morca._internal.remote import Api
from morca._internal.workers import WorkerRow, text_field


def _host_id(arg: String) raises -> Int:
    var id: Int
    try:
        id = Int(arg)
    except:
        id = 0
    if id <= 0:
        raise Error("morca: not a host's id (morca host list): ", arg)
    return id


def _usage(msg: String) -> Int:
    print(msg)
    print(HOST_USAGE)
    return 2


def _logged_in(api: Api) raises:
    if api.remote and not api.remote.value().token:
        raise Error(
            "morca: not logged in to ",
            api.remote.value().url,
            "; morca login ",
            api.remote.value().url,
            " first",
        )


def host_remote(mut api: Api, args: List[String]) raises -> Int:
    """`morca host ...` through `api`."""
    if len(args) < 3:
        return _usage("morca host needs list, drain, undrain or remove")
    var sub = args[2]
    if sub == "list":
        var pool = String()
        if len(args) == 5 and args[3] == "--pool":
            pool = args[4]
        elif len(args) != 3:
            return _usage("host list takes only --pool <pool>")
        var stale = Int(stale_limit())
        var n = 0
        for w in loads(api.get("/api/workers"))["workers"].array_items():
            var r = WorkerRow(
                Int(w["id"].int_value()),
                w["pool"].string_value(),
                w["label"].string_value(),
                w["state"].string_value(),
                w["name"].string_value(),
                w["image"].string_value(),
                w["last_seen"].string_value(),
                Int(w["seen_seconds_ago"].int_value()),
                Int(w["cpus"].int_value()),
                Int(w["memory_mb"].int_value()),
                w["running"].string_value(),
                w["expires"].string_value(),
                None,
                w["draining"].bool_value(),
                # None from a server before these (#220, part 3).
                text_field(w, "host_image"),
                text_field(w, "host_upgrade"),
            )
            if pool and r.pool != pool:
                continue
            print(host_line(r, stale))
            n += 1
        if n == 0:
            print("no hosts")
        return 0
    if (sub == "drain" or sub == "undrain") and len(args) == 4:
        var id = _host_id(args[3])
        _logged_in(api)
        var v = loads(
            api.post(
                String("/api/hosts/", id, "/", sub),
                List[Tuple[String, String]](),
            )
        )
        if sub == "drain":
            print(
                "draining host",
                id,
                "- it finishes its",
                v["running"].int_value(),
                "running runs and claims no more",
            )
        else:
            print("host", id, "claims runs again")
        return 0
    if sub == "remove" and (
        len(args) == 4 or (len(args) == 5 and args[4] == "--force")
    ):
        var id = _host_id(args[3])
        _logged_in(api)
        var fields = List[Tuple[String, String]]()
        if len(args) == 5:
            fields.append((String("force"), String("1")))
        _ = api.post(String("/api/hosts/", id, "/remove"), fields)
        print(
            "removed host",
            id,
            "- its token is revoked, and its worker exits at its next claim",
        )
        return 0
    return _usage(String("unknown: morca host ", sub))
