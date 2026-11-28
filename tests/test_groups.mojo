"""Worker groups in morca.toml (`morca._internal.groups`, docs/groups.md):
the keys a group takes and how they're checked, what falls back to the
pipeline's, the canonical form `register` records, and its stored JSON read
back. Recorded only: nothing here runs."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
