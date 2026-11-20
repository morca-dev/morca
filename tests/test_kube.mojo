"""What morca._internal.kube gives a run's pods: its secrets by reference to
its Secret, never by value, and `MORCA_SECRETS` naming them; the bucket's
settings, with the S3 keys from the stack's Secret, never as values.
tests/kind.sh runs it on a cluster.
"""

from std.os import setenv, unsetenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from json import loads

from morca._internal.kube import pod_env, s3_key_env, secret_env, secret_name
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


def test_s3_key_env_refers_to_the_stack_secret() raises:
    var env = loads(
        String(
            "[", s3_key_env("morca-s3", List[String](), '{"name": "A"}'), "]"
        )
    ).array_items()
    assert_equal(len(env), 3)
    assert_equal(env[1].at("/name").string_value(), "AWS_ACCESS_KEY_ID")
    assert_equal(env[2].at("/name").string_value(), "AWS_SECRET_ACCESS_KEY")
    for i in range(1, 3):
        assert_false(env[i].try_at("/value"))
        assert_equal(
            env[i].at("/valueFrom/secretKeyRef/name").string_value(),
            "morca-s3",
        )
        assert_true(env[i].at("/valueFrom/secretKeyRef/optional").bool_value())
    # A run's own secret of that name wins; no Secret, no entries.
    var skip: List[String] = ["AWS_SECRET_ACCESS_KEY"]
    var one = loads(String("[", s3_key_env("morca-s3", skip), "]"))
    assert_equal(len(one.array_items()), 1)
    assert_equal(s3_key_env("", List[String](), "x"), "x")


def test_pod_env_copies_the_bucket_but_never_its_keys() raises:
    _ = setenv("AWS_ACCESS_KEY_ID", "kind-access-key")
    _ = setenv("AWS_SECRET_ACCESS_KEY", "kind-secret-key")
    _ = setenv("AWS_SESSION_TOKEN", "kind-session-token")
    _ = setenv("AWS_ENDPOINT_URL_S3", "http://minio:9000")
    _ = setenv("MORCA_WAREHOUSE", "s3://morca/warehouse")
    _ = setenv("MORCA_LOGS", "/var/orca/logs")
    var copied: List[String] = ["AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"]
    var own: List[Tuple[String, String]] = [
        ("AWS_ACCESS_KEY_ID", "own-access-key")
    ]
    var text = pod_env(copied, own, s3_key_env("morca-s3", List[String]()))
    assert_false("kind-" in text)
    assert_false("own-access-key" in text)
    var values = Dict[String, String]()
    for e in loads(text).array_items():
        if e.try_at("/value"):
            values[e.at("/name").string_value()] = e.at("/value").string_value()
    assert_equal(values["AWS_ENDPOINT_URL_S3"], "http://minio:9000")
    assert_equal(values["MORCA_WAREHOUSE"], "s3://morca/warehouse")
    # A directory on the scheduler's host isn't one in a pod.
    assert_false("MORCA_LOGS" in values)
    _ = setenv("MORCA_LOGS", "s3://morca/logs")
    assert_true('"s3://morca/logs"' in pod_env(copied, own, ""))
    for n in [
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_ENDPOINT_URL_S3",
        "MORCA_WAREHOUSE",
        "MORCA_LOGS",
    ]:
        _ = unsetenv(n)


def test_mask_values() raises:
    var values: List[String] = ["s3cr3t-value", "abc"]
    var got = mask_values(
        String("a s3cr3t-value, abc, s3cr3t-values\n").as_bytes(), values
    )
    # Values under 4 bytes are left, as mask leaves them.
    assert_equal(String(unsafe_from_utf8=got), "a ***, abc, ***s\n")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
