"""Worker groups in morca.toml (`morca._internal.groups`, docs/groups.md):
the keys a group takes and how they're checked, what falls back to the
pipeline's, the canonical form `register` records, and its stored JSON read
back; the members a running run wants by group on a pool, and which a
host is offered (`morca._internal.member_wants`); and how many each kind
wants from its head's demand (`morca._internal.member_demand`)."""

from std.testing import (
    TestSuite,
    assert_almost_equal,
    assert_equal,
    assert_false,
    assert_true,
)

from dista.scale import Demand
from json import loads

from morca._internal.config import (
    ProjectConfig,
    RegisterFlags,
    resolve,
)
from morca._internal.groups import (
    Group,
    ec2_ignores_groups,
    group_name_problem,
    groups_json,
    parse_groups,
)
from morca._internal.member_demand import (
    DEMAND_STALE_SECONDS,
    Member,
    Prior,
    decide_kind,
    own_workers,
)
from morca._internal.member_wants import (
    Kind,
    Want,
    group_request,
    groups_ask_gpus,
    gpu_host_takes,
    kind_wanted,
    kinds_of,
    offer_order,
    still_defers,
    wanted,
    wants_gpus_of,
)
from morca._internal.run_demand import drain_why
from morca._internal.scale_policy import ScaleKnobs
from morca._internal.secrets import env_name_problem

comptime EXAMPLE = """[defaults]
cpus = 2

[pipelines.embed]
placement = "worker:batch"
workers = "1..4"
cpus = 4
memory_gb = 8

[pipelines.embed.groups.gpu]
workers = "0..2"
gpus = 1
memory_gb = 16

[pipelines.embed.groups.decode]
workers = 3
cpus = "2..8"

[pipelines.plain]
"""


def _refused(text: String, why: String) raises:
    try:
        _ = ProjectConfig(text, "morca.toml")
    except e:
        if why not in String(e):
            raise Error("refused ", repr(text), " but said: ", e)
        return
    raise Error("accepted: ", repr(text))


def test_groups_are_read_by_name() raises:
    var f = ProjectConfig(EXAMPLE, "morca.toml")
    var gs = f.groups("embed")
    assert_equal(len(gs), 2)
    # By name, not the file's order.
    assert_equal(gs[0].name, "decode")
    assert_equal(gs[0].min_workers, 3)
    assert_equal(gs[0].max_workers, 3)
    assert_equal(gs[0].gpus, 0)
    assert_equal(gs[0].cpus, "2..8")
    assert_equal(gs[0].memory_gb, "")
    assert_equal(gs[1].name, "gpu")
    assert_equal(gs[1].min_workers, 0)
    assert_equal(gs[1].max_workers, 2)
    assert_equal(gs[1].gpus, 1)
    assert_equal(gs[1].cpus, "")
    assert_equal(gs[1].memory_gb, "16")
    assert_equal(len(f.groups("plain")), 0)
    assert_equal(len(f.groups("missing")), 0)


def test_unset_falls_back_to_the_pipeline() raises:
    var f = ProjectConfig(EXAMPLE, "morca.toml")
    var gs = f.groups("embed")
    var gpu = gs[1].effective("4", "8")
    assert_equal(gpu.cpus, "4")
    assert_equal(gpu.memory_gb, "16")
    var req = gpu.request()
    assert_equal(req.cpus_min, 4)
    assert_equal(req.memory_min_mb, 16 * 1024)
    # Its GPUs per worker, which admission grants exactly.
    assert_equal(req.gpus, 1)
    assert_equal(gs[0].effective("4", "8").request().gpus, 0)
    var decode = gs[0].effective("4", "8")
    assert_equal(decode.cpus, "2..8")
    assert_equal(decode.memory_gb, "8")
    # A pipeline with no request: the group asks for what it sets alone.
    var bare = gs[1].effective("", "")
    assert_equal(bare.cpus, "")
    assert_false(bare.request().cpus_max > 0)


def test_canonical_form() raises:
    # Spelled differently, the same groups: the same text register keeps.
    var a = ProjectConfig(
        (
            '[pipelines.p.groups.b]\nworkers = "2..2"\ncpus = "4..4"\n'
            "[pipelines.p.groups.a]\nworkers = 1\nmemory_gb = 2.0\ngpus = 0\n"
        ),
        "morca.toml",
    )
    var b = ProjectConfig(
        (
            "[pipelines.p.groups.a]\nworkers = 1\nmemory_gb = 2\n"
            "[pipelines.p.groups.b]\nworkers = 2\ncpus = 4\n"
        ),
        "morca.toml",
    )
    var ja = groups_json(a.groups("p"))
    assert_equal(ja, groups_json(b.groups("p")))
    assert_equal(
        ja,
        (
            '[{"name": "a", "workers": "1", "gpus": 0, "memory_gb": "2"},'
            ' {"name": "b", "workers": "2", "gpus": 0, "cpus": "4"}]'
        ),
    )
    _ = loads(ja)
    # A change in any value is a change in the text.
    var c = ProjectConfig(
        (
            "[pipelines.p.groups.a]\nworkers = 1\nmemory_gb = 2\ngpus = 1\n"
            "[pipelines.p.groups.b]\nworkers = 2\ncpus = 4\n"
        ),
        "morca.toml",
    )
    assert_true(groups_json(c.groups("p")) != ja)
    # No groups: no text, which is stored as null.
    assert_equal(groups_json(List[Group]()), "")
    # As `morca config show` and `export` write a group.
    var gs = ProjectConfig(EXAMPLE, "morca.toml").groups("embed")
    assert_equal(
        gs[1].toml_text(), '{ workers = "0..2", gpus = 1, memory_gb = "16" }'
    )
    assert_equal(gs[0].toml_text(), '{ workers = 3, cpus = "2..8" }')


def test_stored_round_trip() raises:
    var gs = ProjectConfig(EXAMPLE, "morca.toml").groups("embed")
    var back = parse_groups(groups_json(gs))
    assert_equal(len(back), 2)
    for i in range(2):
        assert_true(back[i] == gs[i])
    assert_equal(len(parse_groups("")), 0)
    # An export written back reads as the same groups.
    var text = String("[pipelines.embed]\n")
    for g in gs:
        text.write("groups.", g.name, " = ", g.toml_text(), "\n")
    var again = ProjectConfig(text, "morca.toml").groups("embed")
    assert_equal(groups_json(again), groups_json(gs))


def test_resolve_records_groups() raises:
    var f = ProjectConfig(EXAMPLE, "morca.toml", "abc123")
    var r = resolve("embed", RegisterFlags(), f)
    assert_equal(len(r.groups), 2)
    assert_equal(r.groups_json(), groups_json(f.groups("embed")))
    var c = loads(r.config_json(f))
    var src = c["sources"]["groups.gpu"].copy()
    assert_equal(src["source"].string_value(), "morca.toml")
    assert_equal(src["detail"].string_value(), "[pipelines.embed]")
    assert_equal(Int(src["line"].int_value()), 10)
    # A pipeline with none, or one the file doesn't name, records none.
    assert_equal(resolve("plain", RegisterFlags(), f).groups_json(), "")
    assert_equal(resolve("census", RegisterFlags(), f).groups_json(), "")


def test_names() raises:
    assert_equal(group_name_problem("gpu"), "")
    assert_equal(group_name_problem("gpu-a100_2"), "")
    var long = String("g")
    for _ in range(31):
        long.write("x")
    assert_equal(group_name_problem(long), "")
    long.write("x")
    assert_true(group_name_problem(long) != "")
    assert_true(group_name_problem("") != "")
    assert_true(group_name_problem("GPU") != "")
    assert_true(group_name_problem("1gpu") != "")
    assert_true(group_name_problem("_gpu") != "")
    assert_true(group_name_problem("gpu.a") != "")
    _refused(
        "[pipelines.p.groups.GPU]\nworkers = 1\n",
        "morca.toml:1: [pipelines.p] groups: a group's name is lowercase",
    )
    _refused(
        '[pipelines.p.groups."g p"]\nworkers = 1\n',
        "a group's name is lowercase letters",
    )


def test_bad_groups_are_refused() raises:
    _refused(
        "[pipelines.p.groups.g]\ngpus = 1\n",
        "[pipelines.p] groups.g needs workers",
    )
    _refused(
        "[pipelines.p.groups.g]\nworkers = 1\nslots = 2\n",
        "groups.g has no key slots (it has workers, gpus, cpus and memory_gb)",
    )
    _refused(
        "[pipelines.p.groups.g]\nworkers = 0\n",
        "morca.toml:2: [pipelines.p] groups.g workers: not a count",
    )
    _refused('[pipelines.p.groups.g]\nworkers = "3..1"\n', "groups.g workers")
    _refused("[pipelines.p.groups.g]\nworkers = 1.5\n", "groups.g workers: is")
    _refused(
        "[pipelines.p.groups.g]\nworkers = 1\ngpus = -1\n",
        "groups.g gpus: is a count from 0 to 64",
    )
    _refused(
        "[pipelines.p.groups.g]\nworkers = 1\ngpus = 65\n",
        "groups.g gpus: is a count from 0 to 64",
    )
    _refused(
        '[pipelines.p.groups.g]\nworkers = 1\ngpus = "1"\n',
        "groups.g gpus: is a count of whole GPUs",
    )
    _refused(
        "[pipelines.p.groups.g]\nworkers = 1\ncpus = 0\n",
        "groups.g cpus: is CPUs",
    )
    _refused(
        "[pipelines.p.groups.g]\nworkers = 1\nmemory_gb = 0\n",
        "groups.g memory_gb: is GB",
    )
    _refused("[pipelines.p]\ngroups = 3\n", "groups is a table of")
    _refused("[pipelines.p]\ngroups = { g = 1 }\n", "groups.g isn't a table")
    _refused(
        "[defaults.groups.g]\nworkers = 1\n",
        "[defaults] groups is a pipeline's own",
    )
    # The known keys of a pipeline's table name groups.
    _refused("[pipelines.p]\ngroup = 1\n", "concurrency, enabled, groups,")


def test_ec2_ignores_groups() raises:
    var f = ProjectConfig(
        (
            '[defaults]\nplacement = "ec2"\n'
            "[pipelines.a.groups.g]\nworkers = 1\n"
            '[pipelines.b]\nplacement = "control"\n'
            "[pipelines.b.groups.g]\nworkers = 1\n"
            "[pipelines.c]\n"
        ),
        "morca.toml",
    )
    var w = f.group_warnings()
    assert_equal(len(w), 1)
    assert_true(w[0].startswith("morca.toml:"))
    assert_true("[pipelines.a] a declares groups (g)" in w[0])
    assert_true("the ec2 placement ignores groups" in w[0])
    assert_equal(ec2_ignores_groups("c", "ec2", List[Group]()), "")
    assert_equal(ec2_ignores_groups("b", "control", f.groups("b")), "")


def test_dista_names_are_reserved() raises:
    for n in ["DISTA_TOKEN", "DISTA_PORT", "DISTA_GROUP", "DISTA_ROLE"]:
        assert_true("is set by morca itself" in env_name_problem(String(n)))
    # A pipeline sets this one (docs/morca-toml.md, "auto" from the grant).
    assert_equal(env_name_problem("DISTA_WORKER_SLOTS"), "")
    _refused(
        '[pipelines.p]\nenv = { DISTA_GROUP = "gpu" }\n',
        "DISTA_GROUP is set by morca itself",
    )


def test_gpu_names_are_reserved() raises:
    """A grant's GPUs reach a process in these, which `env` can't set."""
    for n in ["MORCA_GRANT_GPUS", "CUDA_VISIBLE_DEVICES"]:
        assert_true("is set by morca itself" in env_name_problem(String(n)))


def _groups() raises -> List[Group]:
    return [
        Group("decode", 3, 3, 0, "2..8", ""),
        Group("gpu", 0, 2, 1, "4", "16"),
    ]


def _kinds(
    lo: Int, hi: Int, decided: Dict[String, Int], live: Dict[String, Int]
) raises -> List[Kind]:
    return kinds_of(lo, hi, _groups(), decided, live)


def test_each_kind_wants_its_min_before_demand() raises:
    # Before its head reports demand, each kind wants its MIN: decode is a
    # count (3), gpu a range (0..2), the workers with no group 1..2.
    var k = _kinds(1, 2, Dict[String, Int](), Dict[String, Int]())
    assert_equal(len(k), 3)
    assert_equal(k[0].group, "")
    assert_equal(k[0].wanted, 1)
    assert_false(k[0].decided)
    assert_equal(k[1].group, "decode")
    assert_equal(k[1].wanted, 3)
    assert_equal(k[2].group, "gpu")
    assert_equal(k[2].wanted, 0)
    assert_equal(k[2].gpus, 1)
    var w = wanted(k, True)
    assert_equal(len(w), 2)
    assert_equal(w[0].group, "")
    assert_equal(w[0].short, 1)
    assert_equal(w[1].group, "decode")
    assert_equal(w[1].short, 3)


def test_each_kind_wants_what_was_decided() raises:
    # Decided counts, kept within each kind's range, less its live members.
    var decided = Dict[String, Int]()
    decided[""] = 7
    decided["gpu"] = 1
    decided["decode"] = 0
    var live = Dict[String, Int]()
    live["decode"] = 3
    var k = _kinds(1, 2, decided, live)
    assert_equal(k[0].wanted, 2)
    assert_true(k[0].decided)
    assert_equal(k[1].wanted, 3)
    assert_equal(k[2].wanted, 1)
    var w = wanted(k, True)
    assert_equal(len(w), 2)
    assert_equal(w[0].group, "")
    assert_equal(w[0].short, 2)
    assert_equal(w[1].group, "gpu")
    assert_equal(w[1].short, 1)
    assert_equal(w[1].gpus, 1)
    # More live members than wanted: none more, none taken back.
    live["gpu"] = 2
    live[""] = 2
    assert_equal(len(wanted(_kinds(1, 2, decided, live), True)), 0)


def test_a_head_that_reports_no_demand_wants_max() raises:
    # A run whose head's worker doesn't report demand (older, or with
    # MORCA_SCALE_REPORT_SECONDS=0) would never grow: each kind wants its
    # MAX until something is decided, as before demand.
    assert_equal(kind_wanted(1, 4, None, False), 4)
    assert_equal(kind_wanted(0, 2, None, False), 2)
    assert_equal(kind_wanted(1, 4, 2, False), 2)
    assert_equal(kind_wanted(3, 3, None, False), 3)
    var k = kinds_of(
        1, 2, _groups(), Dict[String, Int](), Dict[String, Int](), False
    )
    assert_equal(k[0].wanted, 2)
    assert_false(k[0].decided)
    assert_equal(k[1].wanted, 3)
    assert_equal(k[2].wanted, 2)
    var decided = Dict[String, Int]()
    decided["gpu"] = 1
    k = kinds_of(1, 2, _groups(), decided, Dict[String, Int](), False)
    assert_equal(k[2].wanted, 1)


def test_no_group_wants_as_before() raises:
    # A pipeline without groups and a fixed count wants that count from the
    # start, less its live members, as before demand.
    var live = Dict[String, Int]()
    live[""] = 1
    var none = List[Group]()
    var w = wanted(kinds_of(3, 3, none, Dict[String, Int](), live), True)
    assert_equal(len(w), 1)
    assert_equal(w[0].short, 2)
    assert_equal(
        len(wanted(kinds_of(1, 1, none, Dict[String, Int](), live), True)), 0
    )
    assert_equal(
        len(kinds_of(0, 0, none, Dict[String, Int](), Dict[String, Int]())), 0
    )
    # With groups and no workers of its own, only the groups' kinds.
    var g = _kinds(0, 0, Dict[String, Int](), Dict[String, Int]())
    assert_equal(len(g), 2)
    assert_equal(g[0].group, "decode")
    assert_equal(kind_wanted(1, 4, None), 1)
    assert_equal(kind_wanted(1, 4, 9), 4)
    assert_equal(kind_wanted(2, 4, 0), 2)


def test_an_older_worker_gets_no_group() raises:
    var k = _kinds(1, 1, Dict[String, Int](), Dict[String, Int]())
    var w = wanted(k, False)
    assert_equal(len(w), 1)
    assert_equal(w[0].group, "")
    assert_equal(
        len(
            wanted(
                _kinds(0, 0, Dict[String, Int](), Dict[String, Int]()), False
            )
        ),
        0,
    )


def test_gpu_hosts_are_offered_gpu_members_first() raises:
    var asks: List[Int] = [0, 1, 0, 2]
    var on_gpu = offer_order(asks, 2)
    assert_equal(len(on_gpu), 4)
    assert_equal(on_gpu[0], 1)
    assert_equal(on_gpu[1], 3)
    assert_equal(on_gpu[2], 0)
    assert_equal(on_gpu[3], 2)
    var elsewhere = offer_order(asks, 0)
    for i in range(4):
        assert_equal(elsewhere[i], i)


def test_a_gpu_host_keeps_its_place() raises:
    # A host without GPUs takes anything admission lets it.
    assert_true(gpu_host_takes(0, 0, True, True))
    # A member that asks for GPUs, always (admission checks they're free).
    assert_true(gpu_host_takes(2, 1, True, True))
    # One that asks for none: only when no host without GPUs has room and
    # its run wants no member of a group this host could serve.
    assert_true(gpu_host_takes(1, 0, False, False))
    assert_false(gpu_host_takes(1, 0, False, True))
    assert_false(gpu_host_takes(1, 0, True, False))
    var wants: List[Want] = [Want("", 0, 1), Want("big", 4, 1)]
    assert_false(wants_gpus_of(wants, 2))
    assert_true(wants_gpus_of(wants, 4))
    assert_false(wants_gpus_of([Want("", 0, 1)], 8))


def test_a_groups_request() raises:
    var r = group_request(Group("gpu", 0, 2, 1, "4", "16"))
    assert_equal(r.cpus_min, 4)
    assert_equal(r.cpus_max, 4)
    assert_equal(r.memory_min_mb, 16 * 1024)
    assert_equal(r.gpus, 1)
    assert_true(r.any())
    var gpus_only = group_request(Group("gpu", 1, 1, 1, "", ""))
    assert_equal(gpus_only.cpus_min, 0)
    assert_equal(gpus_only.memory_min_mb, 0)
    assert_equal(gpus_only.gpus, 1)
    assert_true(gpus_only.any())
    # `auto` isn't learned for a group: not asked for.
    var auto = group_request(Group("decode", 1, 1, 0, "auto", ""))
    assert_equal(auto.cpus_min, 0)
    assert_false(auto.any())


# Demand per group (`morca._internal.member_demand`): `dista status --json`
# as a pool run's head answers it (its shape taken from a gpufan run of
# tests/run_cluster.sh), and what each kind wants from it.


def _worker(address: String, group: String, running: Int, idle: Int) -> String:
    return String(
        '{"address":"',
        address,
        '","node":"h","registry":"0x1","running":',
        running,
        ',"slots":1,"group":"',
        group,
        '","idle_seconds":',
        idle,
        ',"held_bytes":0,"actor":0,"draining":false}',
    )


def _group(name: String, workers: Int, ready: Int, running: Int) -> String:
    return String(
        '{"group":"',
        name,
        '","workers":',
        workers,
        ',"slots":',
        workers,
        ',"tasks_ready":',
        ready,
        ',"tasks_waiting":0,"tasks_running":',
        running,
        ',"actors_waiting":0}',
    )


def _status(workers: List[String], groups: List[String]) raises -> Demand:
    var out = String(
        '{"tasks_ready":0,"tasks_waiting":0,"tasks_running":0,',
        '"actors_waiting":0,"tasks_done":3,"tasks_failed":0,"drivers":1,',
        '"pipeline":2,"checkpoints":false,"driver_objects":[{"driver":1,',
        '"held":0,"client":false}],"workers":[',
        ",".join(workers),
        '],"groups":[',
        ",".join(groups),
        "]}\n",
    )
    return Demand.parse(out)


def _knobs() -> ScaleKnobs:
    return ScaleKnobs(5, 60, 4)


def test_a_group_grows_from_none_at_once() raises:
    # Group gpu (0..1) has 4 tasks ready and no worker: dista starts one at
    # once, so it wants 1. Its MIN before any decision is 0.
    var d = _status(
        [_worker("h:1", "", 1, 0)],
        [_group("", 1, 0, 1), _group("gpu", 0, 4, 0)],
    )
    var got = decide_kind(d, "gpu", 0, 1, _knobs(), 1000, None)
    assert_equal(got.wanted, 1)
    assert_equal(got.short_since, 0)
    # Asked for again before it joined: pending, not asked for twice.
    got = decide_kind(d, "gpu", 0, 1, _knobs(), 1005, Prior(1, 0, 1000))
    assert_equal(got.wanted, 1)
    # No tasks of the group: it stays at its MIN.
    var idle = _status([_worker("h:1", "", 0, 3)], [_group("", 1, 0, 0)])
    assert_equal(decide_kind(idle, "gpu", 0, 1, _knobs(), 1000, None).wanted, 0)


def test_the_heads_own_worker_is_no_member() raises:
    # The workers with no group, 1..4: the head's host's dista worker and
    # one member, both busy, 10 tasks ready. dista counts 2 workers, and
    # wants 6 (12 tasks, 2 a worker), at most 4 members + 1.
    assert_equal(own_workers(""), 1)
    assert_equal(own_workers("gpu"), 0)
    var d = _status(
        [_worker("h:1", "", 2, 0), _worker("m:1", "", 2, 0)],
        [_group("", 2, 10, 4)],
    )
    # Short for the first time: it waits MORCA_SCALE_UP_AFTER.
    var got = decide_kind(d, "", 1, 4, _knobs(), 1000, Prior(1, 0, 999))
    assert_equal(got.wanted, 1)
    assert_almost_equal(got.short_since, 1000)
    # Still short 5 s later: 3 more dista workers, so 4 members, not 5.
    got = decide_kind(d, "", 1, 4, _knobs(), 1005, Prior(1, 1000, 1000))
    assert_equal(got.wanted, 4)
    assert_equal(got.short_since, 0)
    # MORCA_SCALE_STEP caps one decision: 1 more at a time.
    got = decide_kind(
        d, "", 1, 4, ScaleKnobs(5, 60, 1), 1005, Prior(1, 1000, 1000)
    )
    assert_equal(got.wanted, 2)


def test_a_stale_decision_waits_again() raises:
    var d = _status(
        [_worker("h:1", "", 2, 0), _worker("m:1", "", 2, 0)],
        [_group("", 2, 10, 4)],
    )
    var old = 1000.0 - DEMAND_STALE_SECONDS - 1
    var got = decide_kind(d, "", 1, 4, _knobs(), 1000, Prior(1, old, old))
    assert_equal(got.wanted, 1)
    assert_almost_equal(got.short_since, 1000)


def test_a_fixed_count_wants_it_whatever_the_demand() raises:
    var busy = _status([], [_group("gpu", 0, 40, 0)])
    assert_equal(decide_kind(busy, "gpu", 2, 2, _knobs(), 1000, None).wanted, 2)
    var idle = _status([_worker("h:1", "", 0, 300)], [_group("", 1, 0, 0)])
    assert_equal(decide_kind(idle, "", 1, 1, _knobs(), 1000, None).wanted, 1)
    assert_equal(
        decide_kind(idle, "", 3, 3, _knobs(), 1000, Prior(3, 0, 999)).wanted, 3
    )


def test_idle_members_are_wanted_no_more() raises:
    # Two idle members of gpu (0..2) past MORCA_SCALE_IDLE and no tasks:
    # dista would drain both, so it wants none (PR 4b stops them).
    var d = _status(
        [
            _worker("h:1", "", 0, 90),
            _worker("g:1", "gpu", 0, 90),
            _worker("g:2", "gpu", 0, 90),
        ],
        [_group("", 1, 0, 0), _group("gpu", 2, 0, 0)],
    )
    assert_equal(
        decide_kind(d, "gpu", 0, 2, _knobs(), 1000, Prior(2, 0, 999)).wanted, 0
    )
    # From a head before groups, the group is empty and the workers with no
    # group are the whole demand.
    var old = Demand.parse('{"tasks_ready":0,"pipeline":2,"workers":[]}')
    assert_false(old.has_groups)
    assert_equal(decide_kind(old, "gpu", 0, 2, _knobs(), 1000, None).wanted, 0)
    assert_equal(decide_kind(old, "", 1, 2, _knobs(), 1000, None).wanted, 1)
    assert_true(groups_ask_gpus(_groups()))
    assert_false(groups_ask_gpus([Group("decode", 1, 1, 0, "", "")]))


def test_idle_members_are_drained_by_address() raises:
    # gpu (0..2): two idle members, past MORCA_SCALE_IDLE, no tasks. With
    # both known by address, both drain, fewest held bytes first.
    var d = _status(
        [
            _worker("h:1", "", 0, 90),
            _worker("g:1", "gpu", 0, 90),
            _worker("g:2", "gpu", 0, 90),
        ],
        [_group("", 1, 0, 0), _group("gpu", 2, 0, 0)],
    )
    var both: List[Member] = [Member("g:1", False), Member("g:2", False)]
    var got = decide_kind(
        d, "gpu", 0, 2, _knobs(), 1000, Prior(2, 0, 999), both^
    )
    assert_equal(got.wanted, 0)
    assert_equal(len(got.drain), 2)
    # A worker that is no member it knows (its host hasn't said its
    # address yet) is taken as busy: only g:2 drains.
    var one: List[Member] = [Member("g:2", False)]
    got = decide_kind(d, "gpu", 0, 2, _knobs(), 1000, Prior(2, 0, 999), one^)
    assert_equal(got.drain, ["g:2"])
    assert_equal(got.wanted, 1)
    # Its MIN is kept: 1..2 drains one.
    var all: List[Member] = [Member("g:1", False), Member("g:2", False)]
    got = decide_kind(d, "gpu", 1, 2, _knobs(), 1000, Prior(2, 0, 999), all^)
    assert_equal(len(got.drain), 1)
    assert_equal(got.wanted, 1)
    # One being drained already counts as gone: the next answer, before
    # the head has heard of it, drains no other below the MIN.
    var marked: List[Member] = [Member("g:1", True), Member("g:2", False)]
    got = decide_kind(
        d, "gpu", 1, 2, _knobs(), 1005, Prior(1, 0, 1000), marked^
    )
    assert_equal(len(got.drain), 0)
    assert_equal(got.wanted, 1)


def test_the_heads_own_worker_is_never_drained() raises:
    # The workers with no group, 0..2: the head's host's own worker and a
    # member, both idle. Only the member drains; the head's is no member.
    var d = _status(
        [_worker("h:1", "", 0, 90), _worker("m:1", "", 0, 90)],
        [_group("", 2, 0, 0)],
    )
    var ms: List[Member] = [Member("m:1", False)]
    var got = decide_kind(d, "", 0, 2, _knobs(), 1000, Prior(1, 0, 999), ms^)
    assert_equal(got.drain, ["m:1"])
    assert_equal(got.wanted, 0)
    var none = List[Member]()
    got = decide_kind(d, "", 0, 2, _knobs(), 1000, Prior(1, 0, 999), none^)
    assert_equal(len(got.drain), 0)


def test_the_last_worker_of_a_group_with_tasks_stays() raises:
    # gpu (0..1): its one member idle, but a task of the group is waiting
    # for its inputs: dista's rule keeps the last worker.
    var d = _status(
        [_worker("h:1", "", 1, 0), _worker("g:1", "gpu", 0, 90)],
        [
            _group("", 1, 0, 1),
            String(
                '{"group":"gpu","workers":1,"slots":1,"tasks_ready":0,',
                '"tasks_waiting":2,"tasks_running":0,"actors_waiting":0}',
            ),
        ],
    )
    var ms: List[Member] = [Member("g:1", False)]
    var got = decide_kind(d, "gpu", 0, 1, _knobs(), 1000, Prior(1, 0, 999), ms^)
    assert_equal(len(got.drain), 0)
    assert_equal(got.wanted, 1)


def test_why_a_member_is_drained() raises:
    assert_equal(drain_why("gpu", 0, 0, 2), "drained: group gpu wants 0 (0..2)")
    assert_equal(drain_why("", 1, 1, 1), "drained: no group wants 1 (1)")


def test_a_gpu_host_defers_for_a_while() raises:
    # A host with GPUs leaves a head or a member with no GPU to one
    # without for MORCA_GPU_DEFER_SECONDS at most, then takes it.
    assert_true(still_defers(0, 60))
    assert_true(still_defers(59.9, 60))
    assert_false(still_defers(60, 60))
    assert_false(still_defers(0, 0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
