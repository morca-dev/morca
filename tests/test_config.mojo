"""What `morca register` reads from morca.toml (`morca._internal.config`): the keys it
checks, the order values win in, and what a registration records."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from json import loads

from morca._internal.config import (
    FROM_FILE,
    FROM_FLAG,
    ProjectConfig,
    RegisterFlags,
    canonical_flag,
    env_name_problem,
    parse_workers,
    resolve,
)
from morca._internal.apps_config import apps_text
from morca._internal.apps_kube import apps_kube
from morca._internal.dataset_config import read_datasets
from morca._internal.pool_config import NO_WAIT, read_pools

comptime EXAMPLE = """[defaults]
placement = "ec2"
head_type = "t4g.medium"
env = { SHARED = "d", ONLY_DEFAULT = "x" }

[pipelines.gharchive]
worker_type = "c7g.xlarge"
workers = "0..4"
worker_procs = 1
env = { DISTA_WORKER_SLOTS = "4", SHARED = "p", N = 16 }
max_runs = 2

[pipelines.mojo_repos]
placement = "control"
secrets = { GITHUB_TOKEN = "orca/github-token" }

[pipelines.bare]

[stack]
hostname = "orca.mlake.dev"
"""


def _refused(text: String, why: String) raises:
    try:
        _ = ProjectConfig(text, "morca.toml")
    except e:
        if why not in String(e):
            raise Error("refused ", repr(text), " but said: ", e)
        return
    raise Error("accepted: ", repr(text))


def test_the_example_reads() raises:
    var f = ProjectConfig(EXAMPLE, "morca.toml", "abc123", True)
    assert_equal(f.pipelines(), ["gharchive", "mojo_repos", "bare"])
    assert_true(f.has("bare"))
    assert_false(f.has("census"))
    assert_equal(f.hash.byte_length(), 64)
    assert_equal(f.commit, "abc123")


def test_entries_say_where() raises:
    # What `morca config check` checks, each with its file:line and table.
    var f = ProjectConfig(EXAMPLE, "morca.toml")
    var heads = f.entries("head_type")
    assert_equal(len(heads), 1)
    assert_equal(heads[0][0], "morca.toml:3: [defaults] head_type")
    assert_equal(heads[0][1], "t4g.medium")
    var workers = f.entries("worker_type")
    assert_equal(len(workers), 1)
    assert_equal(
        workers[0][0], "morca.toml:7: [pipelines.gharchive] worker_type"
    )
    var secrets = f.entries("secrets")
    assert_equal(len(secrets), 1)
    assert_equal(
        secrets[0][0],
        "morca.toml:15: [pipelines.mojo_repos] secrets: GITHUB_TOKEN",
    )
    assert_equal(secrets[0][1], "orca/github-token")
    assert_equal(len(f.entries("fills")), 0)


def test_pipeline_beats_defaults() raises:
    var f = ProjectConfig(EXAMPLE, "morca.toml")
    var r = resolve("gharchive", RegisterFlags(), f)
    assert_true(r.in_file)
    assert_equal(r.text("placement"), "ec2")
    assert_equal(r.values["placement"].detail, "[defaults]")
    assert_equal(r.text("head_type"), "t4g.medium")
    assert_equal(r.text("worker_type"), "c7g.xlarge")
    assert_equal(r.values["worker_type"].source, FROM_FILE)
    assert_equal(r.values["worker_type"].detail, "[pipelines.gharchive]")
    assert_equal(r.text("workers"), "0..4")
    assert_equal(r.text("worker_procs"), "1")
    assert_equal(r.text("max_runs"), "2")
    # env merges name by name, the pipeline's winning; a number is text.
    var env = r.env_pairs()
    assert_equal(len(env), 4)
    for kv in env:
        if kv[0] == "SHARED":
            assert_equal(kv[1], "p")
        if kv[0] == "N":
            assert_equal(kv[1], "16")
    var m = resolve("mojo_repos", RegisterFlags(), f)
    assert_equal(m.text("placement"), "control")
    assert_equal(m.secret_specs(), ["GITHUB_TOKEN=orca/github-token"])
    # [defaults] applies to a pipeline the file names, even with nothing
    # of its own, and to no other.
    var b = resolve("bare", RegisterFlags(), f)
    assert_equal(b.text("head_type"), "t4g.medium")
    var other = resolve("census", RegisterFlags(), f)
    assert_false(other.in_file)
    assert_equal(other.text("head_type"), "")
    assert_equal(len(other.env), 0)


def test_flags_beat_the_file_and_are_recorded() raises:
    var f = ProjectConfig(EXAMPLE, "morca.toml", "abc123")
    var flags = RegisterFlags()
    flags.values["workers"] = canonical_flag("workers", "2..8")
    flags.secrets.append("OTHER=orca/other")
    var r = resolve("gharchive", flags, f)
    assert_equal(r.text("workers"), "2..8")
    assert_equal(r.values["workers"].source, FROM_FLAG)
    assert_equal(r.values["workers"].detail, "--workers")
    assert_equal(r.secret_specs(), ["OTHER=orca/other"])
    var c = loads(r.config_json(f))
    assert_equal(c["file"].string_value(), "morca.toml")
    assert_equal(c["commit"].string_value(), "abc123")
    assert_equal(c["hash"].string_value(), f.hash)
    assert_equal(c["overrides"]["workers"].string_value(), "2..8")
    assert_equal(c["overrides"]["secrets"].string_value(), "OTHER=orca/other")
    assert_equal(c["sources"]["workers"]["source"].string_value(), FROM_FLAG)
    assert_equal(
        c["sources"]["env.SHARED"]["detail"].string_value(),
        "[pipelines.gharchive]",
    )
    assert_equal(
        c["sources"]["env.ONLY_DEFAULT"]["detail"].string_value(),
        "[defaults]",
    )
    # A pipeline the file doesn't name: flags only, no overrides, no file.
    var o = loads(resolve("census", flags, f).config_json(f))
    assert_false(o.get("file"))
    assert_equal(o["sources"]["workers"]["source"].string_value(), FROM_FLAG)


def test_values_are_checked() raises:
    _refused('[pipelines.a]\nworkers = "4..2"\n', "MIN..MAX")
    _refused("[pipelines.a]\nworkers = 0\n", "MIN..MAX")
    _refused("[pipelines.a]\nworkers = true\n", "a count or a string")
    _refused("[pipelines.a]\nworker_procs = 0\n", "1 to 256 or auto")
    _refused('[pipelines.a]\nworker_procs = "some"\n', "1 to 256 or auto")
    _refused('[pipelines.a]\nmax_runs = "2"\n', "is a count")
    _refused("[pipelines.a]\nmax_runs = 0\n", "from 1")
    _refused(
        '[pipelines.a]\nplacement = "moon"\n',
        "control, ec2, worker:<pool> or default",
    )
    _refused('[pipelines.a]\nhead_type = "big"\n', "not an instance type")
    _refused("[pipelines.a]\nhead_type = 3\n", "is a string")
    _refused('[pipelines.a]\nsecrets = "x"\n', "is a table")
    _refused('[pipelines.a]\nsecrets = { T = "prod/t" }\n', "under orca/")
    _refused('[pipelines.a]\nsecrets = { t = "orca/t" }\n', "A-Z")
    _refused('[pipelines.a]\nenv = { GITHUB_TOKEN = "v" }\n', "secret")
    _refused('[pipelines.a]\nenv = { DISTA_ROLE = "x" }\n', "by morca")
    _refused("[pipelines.a]\nenv = { X = [1] }\n", "a string, a number")
    _refused("[pipelines.a]\nenv = { X = { Y = 1 } }\n", "a string, a number")
    # The fill keys (morca.fill).
    _refused('[pipelines.a]\nfills = "some"\n', "since_registration")
    _refused('[defaults]\nfills = ["x"]\n', "fills: is a string")
    _refused('[pipelines.a]\nfill_order = "random"\n', '"oldest" or "newest"')
    _refused("[pipelines.a]\nfill_max_runs = 0\n", "from 1 to 10000")
    _refused('[pipelines.a]\nfill_max_runs = "2"\n', "is a count")
    _refused("[pipelines.a]\nfill_budget_per_day = -2\n", "from 0")
    _refused('[pipelines.a]\nfill_budget_per_day = "5"\n', "a number")
    _refused('[pipelines.a]\nfill_window = "6..6"\n', "UTC hours")
    _refused("[pipelines.a]\nfill_window = 6\n", "is a string")
    _refused('[pipelines.a]\nfill_lag = "2"\n', "a duration")
    _refused('[pipelines.a]\nfill_lag = "2w"\n', "a duration")
    _refused('[pipelines.a]\nfill_lag = "40d"\n', "at most 31d")
    _refused("[pipelines.a]\nfill_lag = 2\n", "a duration string")
    try:
        _ = ProjectConfig(
            '[pipelines.a]\nfills = "all"\n\nfill_window = "1..30"\n',
            "morca.toml",
        )
    except e:
        assert_true(
            String(e).startswith("morca.toml:4: [pipelines.a] fill_window:"),
            String(e),
        )


def test_fill_keys() raises:
    var f = ProjectConfig(
        String(
            '[defaults]\nfills = "all"\nfill_budget_per_day = 5\n',
            '[pipelines.a]\nfill_order = "newest"\nfill_max_runs = 3\n',
            'fill_window = "22..6"\nfill_budget_per_day = 2.5\n',
            'fill_lag = "120m"\n',
            "[pipelines.b]\nfill_lag = 0\n",
            '[pipelines.c]\nfill_lag = "90m"\n',
        ),
        "morca.toml",
    )
    var a = resolve("a", RegisterFlags(), f)
    assert_equal(a.text("fills"), "all")
    assert_equal(a.text("fill_order"), "newest")
    assert_equal(a.text("fill_max_runs"), "3")
    assert_equal(a.text("fill_budget_per_day"), "2.5")
    assert_equal(a.text("fill_window"), "22..6")
    assert_equal(a.text("fill_lag"), "2h")
    assert_equal(resolve("c", RegisterFlags(), f).text("fill_lag"), "90m")
    var b = resolve("b", RegisterFlags(), f)
    assert_equal(b.text("fill_budget_per_day"), "5.0")
    assert_equal(b.text("fill_order"), "")
    assert_equal(b.text("fill_lag"), "0")
    assert_equal(
        f.where("b", "fills", b.values["fills"].copy()),
        "morca.toml:2: [defaults]",
    )


def test_priority() raises:
    # `priority` (#421): an integer, from [defaults] or the pipeline's
    # table, laid over by a stack's overlay; no flag sets it.
    var f = ProjectConfig(
        String(
            "[defaults]\npriority = 5\n",
            "[pipelines.a]\npriority = -3\n",
            "[pipelines.b]\n",
        ),
        "morca.toml",
    )
    var a = resolve("a", RegisterFlags(), f)
    assert_equal(a.text("priority"), "-3")
    assert_equal(a.values["priority"].copy().detail, "[pipelines.a]")
    var b = resolve("b", RegisterFlags(), f)
    assert_equal(b.text("priority"), "5")
    assert_equal(b.values["priority"].copy().detail, "[defaults]")
    _write("build/test-config-priority.toml", "[pipelines.a]\npriority = 1\n")
    _write(
        "build/test-config-priority-overlay.toml",
        "[pipelines.a]\npriority = 10\n",
    )
    var o = ProjectConfig.load(
        "build/test-config-priority.toml",
        "build/test-config-priority-overlay.toml",
    )
    var ao = resolve("a", RegisterFlags(), o)
    assert_equal(ao.text("priority"), "10")
    assert_true("overlay" in ao.values["priority"].copy().detail)
    _refused('[pipelines.a]\npriority = "high"\n', "is an integer, not")
    _refused("[pipelines.a]\npriority = 1.5\n", "is an integer, not")
    _refused("[pipelines.a]\npriority = true\n", "is an integer, not")
    _refused("[pipelines.a]\npriority = 1001\n", "from -1000 to 1000")


def test_concurrency() raises:
    # `concurrency` (#397): a key and a limit, from [defaults] or the
    # pipeline's table, kept as key:limit; no flag sets it.
    var f = ProjectConfig(
        String(
            '[defaults]\nconcurrency = { key = "lake", limit = 2 }\n',
            "[pipelines.a]\n",
            '[pipelines.b]\nconcurrency = { key = "mojo_live", limit = 1 }\n',
        ),
        "morca.toml",
    )
    var a = resolve("a", RegisterFlags(), f)
    assert_equal(a.text("concurrency"), "lake:2")
    assert_equal(a.values["concurrency"].copy().detail, "[defaults]")
    var b = resolve("b", RegisterFlags(), f)
    assert_equal(b.text("concurrency"), "mojo_live:1")
    assert_equal(b.values["concurrency"].copy().detail, "[pipelines.b]")
    var none = resolve("c", RegisterFlags(), ProjectConfig())
    assert_equal(none.text("concurrency"), "")
    _refused("[pipelines.a]\nconcurrency = 1\n", "concurrency is a table")
    _refused(
        '[pipelines.a]\nconcurrency = { key = "k" }\n',
        "needs both key and limit",
    )
    _refused(
        '[pipelines.a]\nconcurrency = { key = "k", limit = 0 }\n',
        "limit is a count from 1 to 1000",
    )
    _refused(
        '[pipelines.a]\nconcurrency = { key = "k", limit = "1" }\n',
        "limit is a count, not",
    )
    _refused(
        '[pipelines.a]\nconcurrency = { key = "a b", limit = 1 }\n',
        "key is letters, digits",
    )
    _refused(
        '[pipelines.a]\nconcurrency = { key = "k", limit = 1, wait = 2 }\n',
        "has key and limit, not wait",
    )


def test_learned_requests() raises:
    # `auto` and `auto..MAX` (morca.recommend), and `learn`.
    var f = ProjectConfig(
        String(
            '[defaults]\nmemory_gb = "auto"\n',
            '[pipelines.a]\ncpus = "auto..8"\n',
            '[pipelines.b]\nmemory_gb = "auto..24.0"\nlearn = false\n',
        ),
        "morca.toml",
    )
    var a = resolve("a", RegisterFlags(), f)
    assert_equal(a.text("memory_gb"), "auto")
    assert_equal(a.text("cpus"), "auto..8")
    assert_equal(a.text("learn"), "")
    var b = resolve("b", RegisterFlags(), f)
    assert_equal(b.text("memory_gb"), "auto..24")
    assert_equal(b.text("learn"), "false")
    assert_equal(canonical_flag("cpus", "auto"), "auto")
    assert_equal(canonical_flag("memory_gb", "auto..2"), "auto..2")
    _refused('[pipelines.a]\nmemory_gb = "2..auto"\n', "lower end")
    _refused('[pipelines.a]\nmemory_gb = "auto.."\n', "auto..MAX")
    _refused('[pipelines.a]\ncpus = "auto..0"\n', "auto..MAX")
    _refused('[pipelines.a]\ncpus = "automatic"\n', "auto")
    _refused('[pipelines.a]\nlearn = "no"\n', "true or false")
    _refused("[pipelines.a]\nlearn = 0\n", "true or false")


def test_auto_max_runs() raises:
    # `max_runs = "auto"` and `"auto..N"` (#266): the ceiling is 64 or N.
    var f = ProjectConfig(
        String(
            '[pipelines.a]\nmax_runs = "auto"\n',
            '[pipelines.b]\nmax_runs = "auto..64"\n',
            '[pipelines.c]\nmax_runs = "auto..8"\n',
        ),
        "morca.toml",
    )
    assert_equal(resolve("a", RegisterFlags(), f).text("max_runs"), "auto")
    assert_equal(resolve("b", RegisterFlags(), f).text("max_runs"), "auto")
    assert_equal(resolve("c", RegisterFlags(), f).text("max_runs"), "auto..8")
    assert_equal(canonical_flag("max_runs", "auto..3"), "auto..3")
    # fill_max_runs too (#322).
    var g = ProjectConfig(
        (
            "[pipelines.a]\nfill_max_runs ="
            ' "auto"\n[pipelines.b]\nfill_max_runs = "auto..8"\n'
        ),
        "morca.toml",
    )
    assert_equal(resolve("a", RegisterFlags(), g).text("fill_max_runs"), "auto")
    assert_equal(
        resolve("b", RegisterFlags(), g).text("fill_max_runs"), "auto..8"
    )
    _refused('[pipelines.a]\nfill_max_runs = "lots"\n', "auto..N")
    assert_equal(canonical_flag("max_runs", "3"), "3")
    _refused('[pipelines.a]\nmax_runs = "auto.."\n', "auto..N")
    _refused('[pipelines.a]\nmax_runs = "auto..0"\n', "auto..N")
    _refused('[pipelines.a]\nmax_runs = "autos"\n', "auto..N")


comptime POOL = """[pools.lab]
provider = "hetzner"
machines = [
  { type = "cax31", wait = 600 },
  { type = "cpx32" },
]
locations = ["hel1", "nbg1"]
max_machines = 3
"""


def test_pools() raises:
    # [pools.<name>] (morca.pool_config, #267): checked with the file.
    var f = ProjectConfig(POOL, "morca.toml")
    var pools = read_pools(f.doc)
    assert_equal(len(pools), 1)
    ref p = pools[0]
    assert_equal(p.name, "lab")
    assert_equal(p.provider, "hetzner")
    assert_equal(len(p.machines), 2)
    assert_equal(p.machines[0].type, "cax31")
    assert_equal(p.machines[0].wait, 600)
    assert_equal(p.machines[1].wait, NO_WAIT)
    assert_equal(p.locations, ["hel1", "nbg1"])
    assert_equal(p.max_machines, 3)
    assert_equal(p.idle_seconds, 900)
    assert_equal(
        p.machines_json(),
        '[{"type": "cax31", "wait": 600}, {"type": "cpx32"}]',
    )
    assert_equal(p.locations_json(), '["hel1", "nbg1"]')
    var bare = (
        '[pools.lab]\nprovider = "ec2"\nmachines = [{ type = "c7g.large" }]\n'
    )
    assert_equal(
        read_pools(ProjectConfig(bare, "morca.toml").doc)[0].max_machines, 1
    )
    _refused('[pools.lab]\nmachines = [{ type = "a" }]\n', "needs a provider")
    _refused(
        '[pools.lab]\nprovider = "gcp"\nmachines = [{ type = "a" }]\n',
        'provider is "hetzner" or "ec2"',
    )
    _refused('[pools.lab]\nprovider = "ec2"\n', "needs machines")
    _refused(
        '[pools.lab]\nprovider = "ec2"\nmachines = ["a"]\n',
        "machines is a list of tables",
    )
    _refused(
        (
            '[pools.lab]\nprovider = "ec2"\nmachines = [{ type = "a" }, { type'
            ' = "b" }]\n'
        ),
        "needs a wait",
    )
    _refused(
        (
            '[pools.lab]\nprovider = "ec2"\nmachines = [{ type = "a", wait = 1,'
            ' size = 2 }, { type = "b" }]\n'
        ),
        "has no key size",
    )
    _refused(
        '[pools.lab]\nprovider = "ec2"\nmachines = [{ type = "A!" }]\n',
        "not a machine type",
    )
    _refused(
        (
            '[pools.lab]\nprovider = "ec2"\nmachines = [{ type = "a", wait = 5'
            ' }, { type = "a" }]\n'
        ),
        "twice",
    )
    _refused(
        '[pools.lab]\nprovider = "hetzner"\nmachines = [{ type = "cax31" }]\n',
        "needs locations",
    )
    _refused(
        (
            '[pools.lab]\nprovider = "ec2"\nmachines = [{ type = "a"'
            " }]\nmax_machines = 0\n"
        ),
        "max_machines is from 1",
    )
    _refused(
        (
            '[pools.lab]\nprovider = "ec2"\nmachines = [{ type = "a" }]\nidle'
            " = 5\n"
        ),
        "has no key idle",
    )
    _refused(
        '[pools.Lab]\nprovider = "ec2"\nmachines = [{ type = "a" }]\n',
        "a-z, 0-9",
    )


def test_keys_and_tables_are_checked() raises:
    _refused("[pipelines.a]\nworkrs = 4\n", "has no key workrs")
    _refused('[defaults]\nfils = "all"\n', "has no key fils")
    _refused("[pipeline.a]\n", "isn't a table morca knows")
    _refused("x = 1\n", "is a key at the top")
    _refused("[pipelines]\na = 1\n", "isn't a table")
    _refused("[pipelines.a]\nworkers = 4\nworkers = 5\n", "defined twice")
    # A message names the file and the line.
    try:
        _ = ProjectConfig("\n[pipelines.a]\n\nworkers = 0\n", "p/morca.toml")
    except e:
        assert_true(
            String(e).startswith("p/morca.toml:4: [pipelines.a] workers:"),
            String(e),
        )


def test_what_flags_and_names_take() raises:
    assert_equal(parse_workers("3")[0], -1)
    assert_equal(parse_workers("0..4")[1], 4)
    assert_equal(canonical_flag("worker_procs", "auto"), "auto")
    assert_equal(canonical_flag("workers", "5"), "5")
    assert_equal(env_name_problem("DISTA_WORKER_SLOTS"), "")
    assert_equal(env_name_problem("lower_ok"), "")
    assert_true(env_name_problem("1X") != "")
    assert_true(env_name_problem("A-B") != "")
    assert_true(env_name_problem("") != "")
    assert_true(env_name_problem("db_password") != "")


def test_no_file() raises:
    var none = ProjectConfig()
    assert_false(none.is_file())
    assert_false(resolve("x", RegisterFlags(), none).in_file)


def _write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def _load_refused(overlay: String, why: String) raises:
    _write("build/test-config-overlay.toml", overlay)
    try:
        _ = ProjectConfig.load(
            "build/test-config.toml", "build/test-config-overlay.toml"
        )
    except e:
        if why not in String(e):
            raise Error("refused ", repr(overlay), " but said: ", e)
        return
    raise Error("accepted: ", repr(overlay))


def test_a_stack_overlay() raises:
    # morca.toml with a stack's overlay laid on it (#332): a key replaces
    # the file's, a table is merged key by key, and where each value came
    # from says so.
    _write(
        "build/test-config.toml",
        """[defaults]
max_runs = 1

[pipelines.gharchive]
fills = "all"
fill_lag = "2h"
env = { SLOTS = "2", EVENTS = "off" }

[pipelines.mojo_repos]
placement = "worker:big"

[pipelines.ballast]
enabled = false
""",
    )
    _write(
        "build/test-config-overlay.toml",
        """[pipelines.gharchive]
fills = "since_registration"
env = { SLOTS = "1" }

[pipelines.mojo_repos]
placement = "control"

[pipelines.ballast]
enabled = true
""",
    )
    var f = ProjectConfig.load(
        "build/test-config.toml", "build/test-config-overlay.toml"
    )
    assert_equal(f.overlay, "build/test-config-overlay.toml")
    assert_equal(f.overlay_hash.byte_length(), 64)
    assert_true(f.enabled("ballast"))
    assert_true(f.enabled("gharchive"))
    var g = resolve("gharchive", RegisterFlags(), f)
    assert_equal(g.text("fills"), "since_registration")
    assert_equal(
        g.values["fills"].detail,
        "[pipelines.gharchive], overlay build/test-config-overlay.toml:2",
    )
    assert_equal(g.values["fills"].line, 0)
    assert_equal(g.text("fill_lag"), "2h")
    assert_equal(g.values["fill_lag"].detail, "[pipelines.gharchive]")
    assert_equal(g.values["fill_lag"].line, 6)
    assert_equal(g.text("max_runs"), "1")
    for kv in g.env_pairs():
        if kv[0] == "SLOTS":
            assert_equal(kv[1], "1")
        if kv[0] == "EVENTS":
            assert_equal(kv[1], "off")
    assert_equal(len(g.env_pairs()), 2)
    var m = resolve("mojo_repos", RegisterFlags(), f)
    assert_equal(m.text("placement"), "control")
    var locs = f.entries("placement")
    assert_equal(
        locs[0][0],
        "build/test-config-overlay.toml:6: [pipelines.mojo_repos] placement",
    )
    assert_true(
        '"overlay": "build/test-config-overlay.toml"' in g.config_json(f)
    )
    var shown = f.shown()
    assert_true(
        'fills = "since_registration"  # overlay'
        " build/test-config-overlay.toml:2"
        in shown
    )
    assert_true('fill_lag = "2h"\n' in shown)
    # Without it, the file alone.
    var plain = ProjectConfig.load("build/test-config.toml")
    assert_false(plain.enabled("ballast"))
    assert_equal(
        resolve("gharchive", RegisterFlags(), plain).text("fills"), "all"
    )
    # [defaults] enabled = false turns off all but those that say true.
    _write(
        "build/test-config-overlay.toml",
        "[defaults]\nenabled = false\n[pipelines.ballast]\nenabled = true\n",
    )
    var lab = ProjectConfig.load(
        "build/test-config.toml", "build/test-config-overlay.toml"
    )
    assert_false(lab.enabled("gharchive"))
    assert_false(lab.enabled("mojo_repos"))
    assert_true(lab.enabled("ballast"))
    # A pipeline the file hasn't, a bad value (at the overlay's line) and a
    # file that isn't TOML are refused.
    _load_refused(
        '[pipelines.gharchiv]\nfills = "all"\n',
        (
            "build/test-config-overlay.toml:1: [pipelines.gharchiv] isn't a"
            " pipeline of build/test-config.toml"
        ),
    )
    _load_refused(
        '\n[pipelines.gharchive]\nfills = "some"\n',
        "build/test-config-overlay.toml:3: [pipelines.gharchive] fills: is",
    )
    _load_refused(
        "[defaults]\nenabled = 1\n",
        "build/test-config-overlay.toml:2: [defaults] enabled is true or false",
    )
    _load_refused("[defaults\n", "build/test-config-overlay.toml:1")
    _load_refused(
        "[apps.console]\nport = 1\n",
        "[apps.console] isn't an app of build/test-config.toml",
    )
    try:
        _ = ProjectConfig.load("build/test-config.toml", "build/no-such.toml")
        raise Error("accepted a missing overlay")
    except e:
        assert_true("no build/no-such.toml" in String(e))


def test_apps() raises:
    # [apps.<name>] (#331): what an app gets, checked, and the lines
    # `morca config apps` prints for the stack's script.
    var f = ProjectConfig(
        """[apps.console]
port = 8080
check = "/healthz"
env = { CONSOLE_SEMANTIC = "1", N = 2 }
lake = true
secrets = { POSTHOG_KEY = "orca/posthog-key" }
memory_gb = 1.5

[apps.bare]
""",
        "morca.toml",
    )
    var apps = f.apps()
    assert_equal(len(apps), 2)
    assert_equal(apps[0].port, 8080)
    assert_equal(apps[0].memory_mb, 1536)
    assert_true(apps[0].lake)
    assert_equal(apps[1].port, 0)
    assert_equal(apps[1].check, "/")
    assert_false(apps[1].lake)
    assert_equal(
        apps_text(apps),
        String(
            "console port 8080\nconsole check /healthz\nconsole lake true\n",
            "console memory_mb 1536\nconsole env CONSOLE_SEMANTIC=1\n",
            "console env N=2\nconsole secret POSTHOG_KEY orca/posthog-key\n",
            "bare port 0\nbare check /\nbare lake false\nbare memory_mb 0\n",
        ),
    )
    _refused(
        "[apps.console]\nprt = 1\n",
        "morca.toml:2: [apps.console] has no key prt",
    )
    _refused("[apps.console]\nport = 0\n", "port is a number from 1 to 65535")
    _refused('[apps.console]\nport = "8080"\n', "port is a number")
    _refused('[apps.console]\ncheck = "healthz"\n', "check is a path")
    _refused("[apps.console]\nlake = 1\n", "lake is true or false")
    _refused("[apps.console]\nmemory_gb = 0\n", "memory_gb is a number of GB")
    _refused(
        '[apps.console]\nenv = { PORT = "1" }\n',
        "env: PORT is set by the stack",
    )
    _refused(
        '[apps.console]\nenv = { AWS_ACCESS_KEY_ID = "x" }\n',
        "env: AWS_ACCESS_KEY_ID comes with lake = true",
    )
    _refused(
        '[apps.console]\nenv = { API_TOKEN = "x" }\n',
        "env: API_TOKEN looks like a secret",
    )
    _refused(
        '[apps.console]\nenv = { A = "x\\ny" }\n', "env: a value is one line"
    )
    _refused(
        '[apps.console]\nsecrets = { K = "posthog-key" }\n',
        "secrets: ID is a Secrets Manager secret under orca/",
    )
    _refused(
        '[apps.console]\nsecrets = { K = "orca/../db-password" }\n',
        "secrets: K: an ID has no .. or //",
    )
    _refused("[apps.ui]\n", "ui is one of the stack's own containers")
    _refused("[apps.Console]\n", "an app's name is lower-case")
    _refused("apps = 1\n", "is a key at the top")


def test_apps_kube() raises:
    # `morca config apps --kube` (#565): a Deployment and a Service per app,
    # with what morca-stack gives it on Hetzner.
    var f = ProjectConfig(
        """[apps.my_console]
port = 8080
check = "/healthz"
env = { CONSOLE_SEMANTIC = "1" }
lake = true
secrets = { POSTHOG_KEY = "orca/posthog-key" }
memory_gb = 0.5

[apps.bare]
port = 9000
""",
        "morca.toml",
    )
    var y = apps_kube(f.apps(), "ghcr.io/o/p:1", "apps", "12345", "pull")
    for want in [
        'name: "my-console"\n  namespace: "apps"',
        'command: ["/opt/morca/bin/my_console"]',
        '- {name: PORT, value: "8080"}',
        '- {name: "CONSOLE_SEMANTIC", value: "1"}',
        '- {name: MORCA_IMAGE_BYTES, value: "12345"}',
        (
            'valueFrom: {secretKeyRef: {name: "morca-app-my-console", key:'
            ' "POSTHOG_KEY"}}'
        ),
        "#   POSTHOG_KEY: the value of orca/posthog-key",
        "- configMapRef: {name: morca-lake}",
        "- secretRef: {name: morca-s3}",
        'httpGet: {path: "/healthz", port: 8080}',
        "limits: {memory: 512Mi}",
        'imagePullSecrets: [{name: "pull"}]',
        "maxUnavailable: 0",
        "kind: Service",
        "ports: [{port: 9000, targetPort: 9000}]",
    ]:
        assert_true(String(want) in y, String(want))
    # The bare app: no lake, no limit, its check /.
    var bare = String(y[byte = y.find("[apps.bare]").or_else(-1) :])
    assert_false("envFrom" in bare)
    assert_false("resources" in bare)
    assert_true('httpGet: {path: "/", port: 9000}' in bare)
    # Without a size, no MORCA_IMAGE_BYTES, never an empty one.
    assert_false("MORCA_IMAGE_BYTES" in apps_kube(f.apps(), "img:1"))
    for bad in ["", "img 1"]:
        try:
            _ = apps_kube(f.apps(), bad)
            raise Error("accepted the image ", bad)
        except e:
            assert_true("--image is" in String(e))
    try:
        _ = apps_kube(f.apps(), "img:1", image_bytes="12k")
        raise Error("accepted a size that isn't one")
    except e:
        assert_true("--image-bytes is a number" in String(e))
    var noport = ProjectConfig("[apps.web]\n", "morca.toml")
    try:
        _ = apps_kube(noport.apps(), "img:1")
        raise Error("accepted an app without a port")
    except e:
        assert_true("app web has no port" in String(e))
    var taken = ProjectConfig("[apps.minio]\nport = 1\n", "morca.toml")
    try:
        _ = apps_kube(taken.apps(), "img:1")
        raise Error("accepted an app named minio")
    except e:
        assert_true("minio is one of deploy/k8s's own" in String(e))


def test_datasets() raises:
    # [datasets.<name>] (#435): public, quoted or two keys deep.
    var f = ProjectConfig(
        (
            '[datasets."hindcast.t2m"]\npublic = false\n\n'
            "[datasets.lake.raw]\npublic = true\n\n[datasets.lake.obs]\n"
        ),
        "morca.toml",
    )
    var ds = read_datasets(f.doc)
    assert_equal(len(ds), 3)
    assert_equal(ds[0].name, "hindcast.t2m")
    assert_false(ds[0].public)
    assert_equal(ds[1].name, "lake.raw")
    assert_true(ds[1].public)
    assert_equal(ds[2].name, "lake.obs")
    assert_true(ds[2].public)
    assert_equal(len(read_datasets(ProjectConfig("", "morca.toml").doc)), 0)
    _refused('[datasets."a.b"]\npublic = "no"\n', "public is true or false")
    _refused('[datasets."a.b"]\nhidden = true\n', "has no key hidden")
    _refused("[datasets.raw]\npublic = false\n", "namespace.table")
    _refused('[datasets."a.b.c"]\n', "namespace.table")
    _refused("datasets = 1\n", "is a key at the top")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
