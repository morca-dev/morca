"""Worker pools in morca.toml: a `[pools.<name>]` table, read and checked
here, and recorded by `morca register`. A pool with a `provider` is one
morca grows and shrinks itself (#267): it's recorded in `orca.pools` too,
and acted on by the scheduler (`morca._internal.pool_scale`). One without
is self-hosted (#220): its machines join by hand (`morca worker`), and
morca only gives them the pool's settings.

    [pools.lab]
    provider = "hetzner"
    machines = [
      { type = "cax31", wait = 600 },   # prefer this; keep trying it 10 min
      { type = "cax21", wait = 600 },
      { type = "cpx32" },               # the last: no wait, keep trying it
    ]
    locations = ["hel1", "nbg1", "fsn1"]
    max_machines = 3
    idle_seconds = 900

A pipeline runs on the pool with `placement = "worker:lab"`, as on a pool of
workers started by hand. `machines` is the order of preference: morca tries
the first type in each location in turn, retries it until its `wait`
(seconds) has passed since it started trying, then moves to the next. The
last type has no `wait`: morca keeps trying it. A machine that's running is
never replaced by a type higher in the list.

Every pool, with a provider or not, may set what its workers are given
(`orca.pool_settings`, read by `/api/worker/claim`):

    [pools.bgent]
    max_runs = 3                                  # runs at once per worker
    env = { MOJO_HISTORY_WORKDIR = "/work/clones" }
    secrets = { GITHUB_TOKEN = "orca/github-token" }

`env` and `secrets` go to every run the pool's workers start, under the
pipeline's own (a pipeline's variable of the same name wins). `secrets`
are Secrets Manager IDs, which the worker reads with its own
`MORCA_SECRET_FETCH`: no value is in morca.toml or the database, and `env`
refuses a name that looks like a secret's.

`volumes = ["census-work:/work", "/srv/secrets:/etc/orca/secrets:ro"]` are
the mounts of a worker started in a container by `morca host join
--container` (`morca._internal.host_join`), which `/api/worker/join` gives
it: a Docker volume's name or an absolute path, then the absolute path in
the container, and `ro` or `rw`.
"""

from json import loads

import morca._internal.db.pools as pools_db

from morca._internal.control import pool_problem
from morca._internal.json import quote
from morca._internal.secrets import env_name_problem, secret_problem
from morca._internal.state import State
from morca._internal.toml import (
    ARRAY,
    INTEGER,
    STRING,
    TABLE,
    TomlDoc,
    toml_key,
)

comptime PROVIDERS = ["hetzner", "ec2"]
comptime GROWN_KEYS = [
    "machines",
    "locations",
    "max_machines",
    "idle_seconds",
]
"""The keys of a pool morca grows, which need a `provider`."""
comptime POOL_KEYS = [
    "provider",
    "machines",
    "locations",
    "max_machines",
    "idle_seconds",
    "max_runs",
    "env",
    "secrets",
    "volumes",
]
comptime MOST_VOLUMES = 32
"""The most volumes a pool may mount."""
comptime MOST_RUNS = 1000
"""The most a pool's `max_runs` may be."""
comptime DEFAULT_MAX_MACHINES = 1
comptime DEFAULT_IDLE_SECONDS = 900
comptime MAX_MACHINES = 100
comptime NO_WAIT = -1
"""A machine type's `wait` when it has none: keep trying it."""


@fieldwise_init
struct MachineChoice(Copyable, Movable):
    """One entry of a pool's `machines`: a provider's machine type, and how
    long to keep trying it before the next (`NO_WAIT` for the last)."""

    var type: String
    var wait: Int


@fieldwise_init
struct PoolConfig(Copyable, Movable):
    """A `[pools.<name>]` table, checked."""

    var name: String
    var provider: String
    var machines: List[MachineChoice]
    var locations: List[String]
    var max_machines: Int
    var idle_seconds: Int
    var max_runs: Int
    """Runs at once on each of its workers; 0 when it doesn't say."""
    var env: List[Tuple[String, String]]
    """Variables every run of its workers gets, under the pipeline's."""
    var secrets: List[Tuple[String, String]]
    """Variables and the secret IDs their workers read them by."""
    var volumes: List[String]
    """`source:target[:ro|:rw]` mounts of its workers' containers
    (`morca host join --container`)."""

    def grown(self) -> Bool:
        """Whether morca makes its machines: it has a provider."""
        return Bool(self.provider)

    def machines_json(self) -> String:
        """`machines` as orca.pools keeps it: `[{"type": .., "wait": ..}]`,
        `wait` left out for none."""
        var out = String("[")
        for i in range(len(self.machines)):
            ref m = self.machines[i]
            out.write(", " if i > 0 else "", '{"type": ', quote(m.type))
            if m.wait != NO_WAIT:
                out.write(', "wait": ', m.wait)
            out.write("}")
        out.write("]")
        return out^

    def locations_json(self) -> String:
        var out = String("[")
        for i in range(len(self.locations)):
            out.write(", " if i > 0 else "", quote(self.locations[i]))
        out.write("]")
        return out^

    def env_json(self) -> String:
        return pairs_json(self.env, "value")

    def secrets_json(self) -> String:
        return pairs_json(self.secrets, "id")

    def volumes_json(self) -> String:
        return _names_json(self.volumes)


def pairs_json(pairs: List[Tuple[String, String]], b: String) -> String:
    """`[{"name": .., <b>: ..}, ...]`, as orca.pool_settings keeps them."""
    var out = String("[")
    for i in range(len(pairs)):
        out.write(
            ", " if i > 0 else "",
            '{"name": ',
            quote(pairs[i][0]),
            ", ",
            quote(b),
            ": ",
            quote(pairs[i][1]),
            "}",
        )
    out.write("]")
    return out^


def _type_problem(t: String) -> String:
    """Why `t` can't be a machine type, or empty: 1 to 64 of `a-z`, `0-9`,
    `.`, `-` and `_` (Hetzner's `cax31`, EC2's `c7g.large`)."""
    var b = t.as_bytes()
    if len(b) == 0 or len(b) > 64:
        return "a machine type is 1 to 64 characters"
    for c in b:
        if not (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("."))
            or c == UInt8(ord("-"))
            or c == UInt8(ord("_"))
        ):
            return String("not a machine type: ", quote(t))
    return ""


struct _Reader:
    """Reads one `[pools.<name>]` table, failing with its line."""

    var table: String
    var line: Int

    def __init__(out self, table: String, line: Int):
        self.table = table
        self.line = line

    def fail(self, line: Int, msg: String) raises:
        raise Error(line if line > 0 else self.line, ": ", self.table, " ", msg)


def _int(
    doc: TomlDoc,
    path: List[String],
    r: _Reader,
    key: String,
    least: Int,
    most: Int,
    default: Int,
) raises -> Int:
    var v = doc.get(path)
    guard case .Some(x) = v else:
        return default
    if x.kind != INTEGER:
        r.fail(x.line, String(key, " is a whole number, not ", x.kind))
    var n = x.as_int()
    if n < least or n > most:
        r.fail(x.line, String(key, " is from ", least, " to ", most))
    return n


def _pairs(
    doc: TomlDoc, base: List[String], r: _Reader, key: String
) raises -> List[Tuple[String, String]]:
    """`env` or `secrets` of a pool, checked as a pipeline's are."""
    var p = base.copy()
    p.append(key)
    var out = List[Tuple[String, String]]()
    var v = doc.get(p)
    if not v:
        return out^
    if not doc.has_table(p):
        r.fail(
            v.value().line,
            String(key, ' is a table of names: { NAME = "..." }'),
        )
    for name in doc.keys(p):
        var q = p.copy()
        q.append(name)
        var item = doc.get(q).value().copy()
        var why: String
        if key == "secrets":
            if item.kind != STRING:
                why = String(name, " is a Secrets Manager ID, a string")
            else:
                why = secret_problem(String(name, "=", item.text)).replace(
                    "--secret's ", ""
                )
        elif item.kind == TABLE or item.kind == ARRAY:
            why = String(name, " is a string, a number or a boolean")
        else:
            why = env_name_problem(name)
        if why:
            r.fail(item.line, String(key, ": ", why))
        out.append((name, item.text))
    return out^


def _path_problem(p: String) -> String:
    """Why `p` can't be a volume's path, or empty: absolute, and none of
    what a shell, an env file or Docker's `-v` would read otherwise."""
    if not p.startswith("/"):
        return String("a path is absolute: ", quote(p))
    for b in p.as_bytes():
        if (
            b <= 0x20
            or b == 0x7F
            or b == UInt8(ord(":"))
            or b == UInt8(ord(","))
            or b == UInt8(ord("'"))
            or b == UInt8(ord('"'))
            or b == UInt8(ord("\\"))
            or b == UInt8(ord("$"))
            or b == UInt8(ord("`"))
        ):
            return String("not a path a volume can have: ", quote(p))
    return ""


def volume_problem(v: String) -> String:
    """Why `v` can't be one of a pool's `volumes`, or empty:
    `source:target[:ro|:rw]`, the source a Docker volume's name (`a-z`,
    `A-Z`, `0-9`, `_`, `.`, `-`, a letter or digit first) or an absolute
    path, the target an absolute path."""
    var parts = v.split(":")
    if len(parts) < 2 or len(parts) > 3:
        return String(
            "a volume is source:target or source:target:ro, not ", quote(v)
        )
    var source = String(parts[0])
    var target = String(parts[1])
    if len(parts) == 3 and parts[2] != "ro" and parts[2] != "rw":
        return String(
            "a volume's mode is ro or rw, not ", quote(String(parts[2]))
        )
    if source.startswith("/"):
        var why = _path_problem(source)
        if why:
            return why
    else:
        var b = source.as_bytes()
        if len(b) == 0 or len(b) > 64:
            return String("a volume's name is 1 to 64 characters: ", quote(v))
        for i in range(len(b)):
            var c = b[i]
            var alnum = (
                (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
                or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
                or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            )
            if not alnum and (
                i == 0
                or (
                    c != UInt8(ord("_"))
                    and c != UInt8(ord("."))
                    and c != UInt8(ord("-"))
                )
            ):
                return String(
                    "a volume's source is a name or an absolute path, not ",
                    quote(source),
                )
    return _path_problem(target)


def _volumes(
    doc: TomlDoc, base: List[String], r: _Reader
) raises -> List[String]:
    """A pool's `volumes`, checked: no two on the same target."""
    var p = base.copy()
    p.append("volumes")
    var out = List[String]()
    var v = doc.get(p)
    guard case .Some(l) = v else:
        return out^
    if l.kind != ARRAY or doc.is_table_array(l):
        r.fail(l.line, 'volumes is a list of strings: ["name:/path", ...]')
    if len(l.items) > MOST_VOLUMES:
        r.fail(l.line, String("volumes: at most ", MOST_VOLUMES))
    var targets = List[String]()
    for i in range(len(l.items)):
        if l.item_kinds[i] != STRING:
            r.fail(l.line, "volumes: each is a string, source:target[:ro]")
        var why = volume_problem(l.items[i])
        if why:
            r.fail(l.line, String("volumes: ", why))
        var target = String(l.items[i].split(":")[1])
        if target in targets:
            r.fail(l.line, String("volumes: two on ", target))
        targets.append(target)
        out.append(l.items[i])
    return out^


def read_pool(doc: TomlDoc, name: String) raises -> PoolConfig:
    """`[pools.<name>]` of `doc`, checked; raises `<line>: [pools.<name>]
    <why>`."""
    var base: List[String] = ["pools", name]
    var top = doc.get(base)
    var r = _Reader(
        String("[pools.", toml_key(name), "]"),
        top.value().line if top else 0,
    )
    if not top or top.value().kind != TABLE:
        r.fail(0, "isn't a table: a pool's settings are [pools.<name>]")
    var why = pool_problem(name)
    if why:
        r.fail(0, why)
    for key in doc.keys(base):
        var known = False
        for k in materialize[POOL_KEYS]():
            known = known or k == key
        if not known:
            var p = base.copy()
            p.append(key)
            r.fail(
                doc.get(p).value().line,
                String(
                    "has no key ",
                    toml_key(key),
                    " (it has provider, machines, locations, max_machines,",
                    " idle_seconds, max_runs, env, secrets and volumes)",
                ),
            )
    # provider
    var pp = base.copy()
    pp.append("provider")
    var pv = doc.get(pp)
    var max_runs_p = base.copy()
    max_runs_p.append("max_runs")
    var max_runs = _int(doc, max_runs_p, r, "max_runs", 1, MOST_RUNS, 0)
    var env = _pairs(doc, base, r, "env")
    var secrets = _pairs(doc, base, r, "secrets")
    var volumes = _volumes(doc, base, r)
    if not pv:
        # Self-hosted (#220): its machines join by hand, and only the
        # settings above apply.
        for key in materialize[GROWN_KEYS]():
            var kp = base.copy()
            kp.append(key)
            var kv = doc.get(kp)
            if kv:
                r.fail(
                    kv.value().line,
                    String(
                        key,
                        " is for a pool morca grows, which needs a provider",
                        ' ("hetzner" or "ec2"); without one, its machines',
                        " join by hand (morca worker)",
                    ),
                )
        return PoolConfig(
            name,
            "",
            List[MachineChoice](),
            List[String](),
            0,
            0,
            max_runs,
            env^,
            secrets^,
            volumes^,
        )
    if pv.value().kind != STRING:
        r.fail(pv.value().line, "provider is a string")
    var provider = pv.value().text
    var ok = False
    for p in materialize[PROVIDERS]():
        ok = ok or p == provider
    if not ok:
        r.fail(
            pv.value().line,
            String('provider is "hetzner" or "ec2", not ', quote(provider)),
        )
    # machines
    var mp = base.copy()
    mp.append("machines")
    var mv = doc.get(mp)
    if not mv:
        r.fail(0, 'needs machines: [{ type = "...", wait = 600 }, ...]')
    ref m = mv.value()
    if not doc.is_table_array(m):
        r.fail(
            m.line,
            'machines is a list of tables: [{ type = "...", wait = 600 }, ...]',
        )
    var machines = List[MachineChoice]()
    for i in range(len(m.items)):
        var ep = mp.copy()
        ep.append(m.items[i])
        var line = m.line
        for k in doc.keys(ep):
            var kp = ep.copy()
            kp.append(k)
            line = doc.get(kp).value().line
            if k != "type" and k != "wait":
                r.fail(
                    line,
                    String(
                        "machines: has no key ",
                        toml_key(k),
                        " (an entry has type and wait)",
                    ),
                )
        var tp = ep.copy()
        tp.append("type")
        var tv = doc.get(tp)
        if not tv or tv.value().kind != STRING:
            r.fail(line, "machines: each entry has a type, a string")
        var t = tv.value().text
        var tw = _type_problem(t)
        if tw:
            r.fail(tv.value().line, String("machines: ", tw))
        var wp = ep.copy()
        wp.append("wait")
        var last = i == len(m.items) - 1
        var wait = _int(doc, wp, r, "machines: wait", 0, 86400, NO_WAIT)
        if wait == NO_WAIT and not last:
            r.fail(
                tv.value().line,
                String(
                    "machines: ",
                    quote(t),
                    " needs a wait (seconds to keep trying it before the",
                    " next); only the last may leave it out",
                ),
            )
        for seen in machines:
            if seen.type == t:
                r.fail(
                    tv.value().line, String("machines: ", quote(t), " twice")
                )
        machines.append(MachineChoice(t, wait))
    # locations
    var lp = base.copy()
    lp.append("locations")
    var lv = doc.get(lp)
    var locations = List[String]()
    if lv:
        ref l = lv.value()
        if l.kind != ARRAY or doc.is_table_array(l):
            r.fail(l.line, 'locations is a list of strings: ["hel1", ...]')
        for i in range(len(l.items)):
            if l.item_kinds[i] != STRING or not l.items[i]:
                r.fail(l.line, "locations: each is a non-empty string")
            locations.append(l.items[i])
    if provider == "hetzner" and len(locations) == 0:
        r.fail(0, 'needs locations on hetzner: ["hel1", "nbg1", ...]')
    var xp = base.copy()
    xp.append("max_machines")
    var ip = base.copy()
    ip.append("idle_seconds")
    return PoolConfig(
        name,
        provider,
        machines^,
        locations^,
        _int(doc, xp, r, "max_machines", 1, MAX_MACHINES, DEFAULT_MAX_MACHINES),
        _int(doc, ip, r, "idle_seconds", 10, 86400, DEFAULT_IDLE_SECONDS),
        max_runs,
        env^,
        secrets^,
        volumes^,
    )


def read_pools(doc: TomlDoc) raises -> List[PoolConfig]:
    """Every `[pools.<name>]` of `doc`, checked, in the file's order."""
    var out = List[PoolConfig]()
    for name in doc.keys(["pools"]):
        out.append(read_pool(doc, name))
    return out^


def record_pools(mut db: State, pools: List[PoolConfig]) raises -> List[String]:
    """Makes `orca.pools` and `orca.pool_settings` what morca.toml says,
    `pools`: each pool's settings upserted, each pool with a provider in
    `orca.pools` too, and a pool the file no longer has (or that no longer
    has a provider) deleted there, so the scheduler stops adding machines
    to it and removes the ones it has once idle. The pools deleted from
    `orca.pools`."""
    var tx = db.conn.begin()
    var keep = List[String]()
    var all = List[String]()
    for p in pools:
        all.append(p.name)
        pools_db.upsert_settings(
            tx,
            p.name,
            p.provider,
            p.env_json(),
            p.secrets_json(),
            p.max_runs,
        )
        pools_db.set_volumes(tx, p.name, p.volumes_json())
        if not p.grown():
            continue
        keep.append(p.name)
        pools_db.upsert_pool(
            tx,
            p.name,
            p.provider,
            p.machines_json(),
            p.locations_json(),
            p.max_machines,
            p.idle_seconds,
        )
    var gone = pools_db.delete_pools_but(tx, _names_json(keep))
    pools_db.delete_settings_but(tx, _names_json(all))
    tx.commit()
    return gone^


def _names_json(names: List[String]) -> String:
    var out = String("[")
    for i in range(len(names)):
        out.write(", " if i > 0 else "", quote(names[i]))
    out.write("]")
    return out^


@fieldwise_init
struct PoolSettings(Copyable, Movable):
    """What a pool's workers are given (`orca.pool_settings`): none for a
    pool morca.toml doesn't declare."""

    var max_runs: Int
    """Runs at once on each worker; 0 for no limit of the pool's."""
    var env: List[Tuple[String, String]]
    var secrets: List[Tuple[String, String]]

    @staticmethod
    def none() -> PoolSettings:
        return PoolSettings(
            0, List[Tuple[String, String]](), List[Tuple[String, String]]()
        )


def _pairs_of(text: String, b: String) raises -> List[Tuple[String, String]]:
    var out = List[Tuple[String, String]]()
    for p in loads(text).array_items():
        out.append((p["name"].string_value(), p[b].string_value()))
    return out^


def pool_settings(mut db: State, pool: String) raises -> PoolSettings:
    """`pool`'s settings, as `morca register` recorded them."""
    var got = pools_db.settings(db.conn, pool)
    guard case .Some(s) = got else:
        return PoolSettings.none()
    return PoolSettings(
        s.max_runs, _pairs_of(s.env, "value"), _pairs_of(s.secrets, "id")
    )


def under_pool(
    pool: List[Tuple[String, String]], own: List[Tuple[String, String]]
) -> List[Tuple[String, String]]:
    """`own` (a pipeline's variables) after those of `pool` it doesn't
    name: a pipeline's variable wins over its pool's."""
    var out = List[Tuple[String, String]]()
    for p in pool:
        var shadowed = False
        for o in own:
            shadowed = shadowed or o[0] == p[0]
        if not shadowed:
            out.append(p)
    for o in own:
        out.append(o)
    return out^


def pool_volumes(mut db: State, pool: String) raises -> List[String]:
    """`pool`'s volumes, as `morca register` recorded them."""
    var out = List[String]()
    for v in loads(pools_db.volumes(db.conn, pool)).array_items():
        out.append(v.string_value())
    return out^


def pool_slots(slots: Int, max_runs: Int, running: String) -> Int:
    """The runs a worker asking for `slots`, running the comma-separated
    runs `running`, may claim under its pool's `max_runs` (0: no limit)."""
    if max_runs <= 0:
        return slots
    var n = 0
    for x in running.split(","):
        if String(x).strip():
            n += 1
    return max(min(slots, max_runs - n), 0)
