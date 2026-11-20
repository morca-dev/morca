"""What morca._internal.kube gives a run's pods: its secrets by reference to
its Secret, never by value, and `MORCA_SECRETS` naming them. tests/kind.sh
runs it on a cluster.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from json import loads

from morca._internal.kube import pod_env, secret_env, secret_name
from morca._internal.logs import mask_values


def test_secret_env_refers_to_the_secret() raises:
    var names: List[String] = ["GITHUB_TOKEN", "API_KEY"]
    var env = loads(
        String(
            "[",
            secret_env(names, secret_name(7, 2), '{"name": "A", "value": "1"}'),
            "]",
        )
    )
    var items = env.array_items()
    assert_equal(len(items), 4)
    assert_equal(items[0].at("/name").string_value(), "A")
    assert_equal(items[1].at("/name").string_value(), "GITHUB_TOKEN")
    assert_equal(
        items[1].at("/valueFrom/secretKeyRef/name").string_value(),
        "morca-7-2-secrets",
    )
    assert_equal(
        items[2].at("/valueFrom/secretKeyRef/key").string_value(), "API_KEY"
    )
    assert_false(items[1].try_at("/value"))
    assert_equal(items[3].at("/name").string_value(), "MORCA_SECRETS")
    assert_equal(items[3].at("/value").string_value(), "GITHUB_TOKEN,API_KEY")


def test_secret_env_without_secrets() raises:
    assert_equal(secret_env(List[String](), "s", "x"), "x")
    assert_equal(secret_env(List[String](), "s"), "")


def test_pod_env_leaves_secret_names_to_the_secret() raises:
    # The pipeline's own variable of a secret's name gives way to the
    # secret, as on the local runner.
    var own: List[Tuple[String, String]] = [
        ("GITHUB_TOKEN", "plain"),
        ("REGION", "eu"),
    ]
    var names: List[String] = ["GITHUB_TOKEN"]
    var taken: List[String] = ["GITHUB_TOKEN", "MORCA_SECRETS"]
    var env = loads(
        pod_env(
            List[String](), own, secret_env(names, "morca-1-1-secrets"), taken
        )
    ).array_items()
    var seen = String()
    for e in env:
        if e.at("/name").string_value() == "MORCA_SAMPLE_SECONDS":
            continue
        seen.write(e.at("/name").string_value(), " ")
        assert_true(
            not e.try_at("/value") or e.at("/value").string_value() != "plain"
        )
    assert_equal(seen, "REGION GITHUB_TOKEN MORCA_SECRETS ")


def test_mask_values() raises:
    var values: List[String] = ["s3cr3t-value", "abc"]
    var got = mask_values(
        String("a s3cr3t-value, abc, s3cr3t-values\n").as_bytes(), values
    )
    # Values under 4 bytes are left, as mask leaves them.
    assert_equal(String(unsafe_from_utf8=got), "a ***, abc, ***s\n")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
