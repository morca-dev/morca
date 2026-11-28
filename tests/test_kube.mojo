"""What morca._internal.kube gives a run's pods: its secrets by reference to
its Secret, never by value, and `MORCA_SECRETS` naming them; the bucket's
settings, with the S3 keys from the stack's Secret, never as values; and
their sizes, from the pipeline's request, with limits, and what a pod killed
for its memory says (morca._internal.kube_size); where they go, pull secrets,
node selectors, tolerations, anti-affinity and a priority class
(morca._internal.kube_place), and why a pod can't start; and the head's
and workers' own variables, a worker group's pods, their GPUs and what they
ask for in all (docs/groups.md, morca._internal.provider).
tests/kind.sh runs it on a cluster.
"""

from std.os import setenv, unsetenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from json import Value, loads

from morca._internal.kube import pod_env, s3_key_env, secret_env, secret_name
from morca._internal.kube_size import (
    EVICTED,
    OOM_KILLED,
    GroupPods,
    KubeDefaults,
    Killed,
    PodSize,
    pod_slugs,
    with_groups,
    killed_text,
    kube_sizes,
    next_memory_mb,
    pod_killed,
    pod_memory,
    pod_stuck,
    stuck_text,
)
from morca._internal.kube_place import KubePlacement, Toleration
from morca._internal.logs import mask_values
from morca._internal.provider import (
    KUBERNETES,
    ClusterProcess,
    cluster_env,
    driver_env,
    json_entries,
    pod_devices,
)
from morca._internal.resources import Request


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


def _same(
    got: PodSize, cpu: Int, cpu_limit: Int, mb: Int, mb_limit: Int
) raises:
    assert_equal(got.cpu_request, cpu)
    assert_equal(got.cpu_limit, cpu_limit)
    assert_equal(got.memory_request_mb, mb)
    assert_equal(got.memory_limit_mb, mb_limit)


def test_pod_sizes_from_the_request() raises:
    """Driver and workers from `cpus` and `memory_gb`, MIN the request and
    MAX the limit; the head and what isn't asked for from the defaults."""
    var d = KubeDefaults(500, 250, 1000, 2000, 512)
    var none = kube_sizes(Request(0, 0, 0, 0), 0, 0, d)
    _same(none.driver, 500, 2000, 512, 512)
    _same(none.head, 250, 2000, 512, 512)
    _same(none.worker, 1000, 2000, 512, 512)
    var r = Request.of("2..4", "1..3")
    var s = kube_sizes(r, r.memory_max_mb, 0, d)
    _same(s.driver, 2000, 4000, 1024, 3072)
    _same(s.worker, 2000, 4000, 1024, 3072)
    _same(s.head, 250, 2000, 512, 512)
    # Two pipelines with different memory_gb: different pods.
    var big = kube_sizes(Request.of("", "4"), 4096, 0, d)
    _same(big.worker, 1000, 2000, 4096, 4096)
    assert_true(big.worker.memory_limit_mb != s.worker.memory_limit_mb)
    # What the run asks for in all: the driver alone, or with its head and
    # workers.
    assert_equal(s.requests(0).cpu_millis, 2000)
    assert_equal(s.requests(0).memory_mb, 1024)
    assert_equal(s.requests(3).cpu_millis, 2000 + 250 + 3 * 2000)
    assert_equal(s.requests(3).memory_mb, 1024 + 512 + 3 * 1024)
    # A CPU limit under the request is the request; 0 is none.
    var under = KubeDefaults(500, 250, 3000, 1000, 512)
    var w = kube_sizes(Request(0, 0, 0, 0), 0, 0, under).worker
    _same(w, 3000, 3000, 512, 512)
    var unlimited = KubeDefaults(500, 250, 1000, 0, 512)
    var free = kube_sizes(Request(0, 0, 0, 0), 0, 0, unlimited)
    assert_equal(free.driver.cpu_limit, 0)
    var res = loads(free.driver.resources())
    assert_false(res.try_at("/limits/cpu"))
    assert_equal(res.at("/limits/memory").string_value(), "512Mi")
    res = loads(s.worker.resources())
    assert_equal(res.at("/requests/cpu").string_value(), "2000m")
    assert_equal(res.at("/limits/cpu").string_value(), "4000m")
    assert_equal(res.at("/requests/memory").string_value(), "1024Mi")
    assert_equal(res.at("/limits/memory").string_value(), "3072Mi")


def test_pod_sizes_after_an_oom_kill() raises:
    """The raised memory is the least a pod asks for and is limited to, up
    to memory_gb's maximum; the head keeps the default."""
    var d = KubeDefaults(500, 250, 1000, 2000, 128)
    var s = kube_sizes(Request(0, 0, 0, 0), 0, 192, d)
    _same(s.driver, 500, 2000, 192, 192)
    _same(s.head, 250, 2000, 128, 128)
    var r = Request.of("", "1..3")
    _same(kube_sizes(r, 3072, 2048, d).worker, 1000, 2000, 2048, 3072)
    _same(kube_sizes(r, 3072, 5000, d).worker, 1000, 2000, 3072, 3072)
    # A raise under the request changes nothing.
    _same(kube_sizes(r, 3072, 512, d).worker, 1000, 2000, 1024, 3072)


def _pod(status: String) raises -> Value:
    return loads(
        String(
            '{"metadata": {"name": "morca-7-1-worker-0"}, "spec":',
            ' {"containers": [{"name": "main", "resources": {"requests":',
            ' {"cpu": "100m", "memory": "128Mi"}, "limits": {"memory":',
            ' "256Mi"}}}]}, "status": ',
            status,
            "}",
        )
    )


def test_pod_killed() raises:
    """OOMKilled from a container's state, Evicted from the pod's."""
    var oom = _pod(
        '{"phase": "Failed", "containerStatuses": [{"name": "main", "state":'
        ' {"terminated": {"exitCode": 137, "reason": "OOMKilled"}}}]}'
    )
    assert_equal(pod_killed(oom).reason, OOM_KILLED)
    assert_equal(pod_memory(oom, "requests"), 128)
    assert_equal(pod_memory(oom, "limits"), 256)
    var evicted = _pod(
        '{"phase": "Failed", "reason": "Evicted", "message": "The node was'
        ' low on resource: memory."}'
    )
    assert_equal(pod_killed(evicted).reason, EVICTED)
    assert_equal(
        pod_killed(evicted).message, "The node was low on resource: memory."
    )
    var done = _pod(
        '{"phase": "Succeeded", "containerStatuses": [{"name": "main",'
        ' "state": {"terminated": {"exitCode": 0, "reason": "Completed"}}}]}'
    )
    assert_equal(pod_killed(done).reason, "")
    assert_equal(pod_killed(_pod('{"phase": "Pending"}')).reason, "")


def test_killed_retry_asks_for_more() raises:
    """An OOM kill asks for 1.5 times the limit, an eviction 1.5 times the
    request, at most memory_gb's maximum."""
    var oom = Killed(String(OOM_KILLED), String())
    var ev = Killed(String(EVICTED), String("low on memory"))
    assert_equal(next_memory_mb(oom, 128, 128, 150, 0), 192)
    assert_equal(next_memory_mb(ev, 128, 256, 150, 0), 192)
    assert_equal(next_memory_mb(oom, 1024, 3072, 150, 4096), 4096)
    assert_equal(next_memory_mb(oom, 1024, 3072, 150, 3072), 3072)
    var t = killed_text(oom, "morca-7-1-x", "driver", 128, 192)
    assert_true(t.startswith("OOMKilled: pod morca-7-1-x (the driver)"), t)
    assert_true("128 MB" in t and "its retry asks for 192 MB" in t, t)
    t = killed_text(oom, "p", "worker", 3072, 3072)
    assert_true("the most it may ask for" in t, t)
    t = killed_text(ev, "p", "worker", 128, 192)
    assert_true(t.startswith("Evicted: pod p") and "(low on memory)" in t, t)
    t = killed_text(oom, "p", "head", 128, 0)
    assert_true("MORCA_POD_MEMORY" in t, t)


def _unset_place() raises:
    for n in [
        "MORCA_KUBE_PULL_SECRET",
        "MORCA_KUBE_DRIVER_NODE_SELECTOR",
        "MORCA_KUBE_HEAD_NODE_SELECTOR",
        "MORCA_KUBE_WORKER_NODE_SELECTOR",
        "MORCA_KUBE_DRIVER_TOLERATIONS",
        "MORCA_KUBE_HEAD_TOLERATIONS",
        "MORCA_KUBE_WORKER_TOLERATIONS",
        "MORCA_KUBE_WORKER_ANTI_AFFINITY",
        "MORCA_KUBE_PRIORITY_CLASS",
    ]:
        _ = unsetenv(n)


def _spec(p: KubePlacement, role: StaticString) raises -> Value:
    return loads(String('{"restartPolicy": "Never"', p.spec(role, 7, 2), "}"))


def test_placement_unset_adds_nothing() raises:
    """A stack with none of the variables gets pod specs as before."""
    _unset_place()
    var p = KubePlacement.from_env()
    assert_equal(p.spec("driver", 7, 2), "")
    assert_equal(p.spec("head", 7, 2), "")
    assert_equal(p.spec("worker", 7, 2), "")
    assert_equal(KubePlacement.none().spec("worker", 7, 2), "")


def test_placement_per_role() raises:
    """Pull secrets and the priority class on every pod; each role its own
    node selector and tolerations; the workers their anti-affinity."""
    _unset_place()
    _ = setenv("MORCA_KUBE_PULL_SECRET", "ghcr-pull, other")
    _ = setenv(
        "MORCA_KUBE_DRIVER_NODE_SELECTOR",
        "karpenter.sh/capacity-type=on-demand",
    )
    _ = setenv(
        "MORCA_KUBE_WORKER_NODE_SELECTOR",
        "karpenter.sh/capacity-type=spot,pool=runs",
    )
    _ = setenv("MORCA_KUBE_WORKER_TOLERATIONS", "spot=true:NoSchedule,gpu")
    _ = setenv("MORCA_KUBE_WORKER_ANTI_AFFINITY", "preferred")
    _ = setenv("MORCA_KUBE_PRIORITY_CLASS", "morca-runs")
    var p = KubePlacement.from_env()
    var driver = _spec(p, "driver")
    assert_equal(
        driver.at("/imagePullSecrets/0/name").string_value(), "ghcr-pull"
    )
    assert_equal(driver.at("/imagePullSecrets/1/name").string_value(), "other")
    assert_equal(
        driver.at("/nodeSelector/karpenter.sh~1capacity-type").string_value(),
        "on-demand",
    )
    assert_false(driver.try_at("/tolerations"))
    assert_false(driver.try_at("/affinity"))
    assert_equal(driver.at("/priorityClassName").string_value(), "morca-runs")
    var head = _spec(p, "head")
    assert_false(head.try_at("/nodeSelector"))
    assert_equal(
        head.at("/imagePullSecrets/0/name").string_value(), "ghcr-pull"
    )
    var worker = _spec(p, "worker")
    assert_equal(
        worker.at("/nodeSelector/karpenter.sh~1capacity-type").string_value(),
        "spot",
    )
    assert_equal(worker.at("/nodeSelector/pool").string_value(), "runs")
    assert_equal(worker.at("/tolerations/0/key").string_value(), "spot")
    assert_equal(worker.at("/tolerations/0/operator").string_value(), "Equal")
    assert_equal(worker.at("/tolerations/0/value").string_value(), "true")
    assert_equal(
        worker.at("/tolerations/0/effect").string_value(), "NoSchedule"
    )
    assert_equal(worker.at("/tolerations/1/key").string_value(), "gpu")
    assert_equal(worker.at("/tolerations/1/operator").string_value(), "Exists")
    assert_false(worker.try_at("/tolerations/1/effect"))
    var term = worker.at(
        "/affinity/podAntiAffinity/preferredDuringSchedulingIgnoredDuringExecution/0"
    )
    assert_equal(term.at("/weight").int_value(), 100)
    assert_equal(
        term.at("/podAffinityTerm/topologyKey").string_value(),
        "kubernetes.io/hostname",
    )
    var labels = term.at("/podAffinityTerm/labelSelector/matchLabels")
    assert_equal(labels.at("/orca.run").string_value(), "7")
    assert_equal(labels.at("/orca.start").string_value(), "2")
    assert_equal(labels.at("/orca.role").string_value(), "worker")
    _ = setenv("MORCA_KUBE_WORKER_ANTI_AFFINITY", "required")
    worker = _spec(KubePlacement.from_env(), "worker")
    assert_equal(
        worker.at(
            "/affinity/podAntiAffinity/requiredDuringSchedulingIgnoredDuringExecution/0/topologyKey"
        ).string_value(),
        "kubernetes.io/hostname",
    )
    _unset_place()


def test_placement_refuses_bad_values() raises:
    _unset_place()
    for kv in [
        ("MORCA_KUBE_WORKER_NODE_SELECTOR", "spot"),
        ("MORCA_KUBE_WORKER_TOLERATIONS", "spot=true:Never"),
        ("MORCA_KUBE_HEAD_TOLERATIONS", "=x:NoSchedule"),
        ("MORCA_KUBE_WORKER_ANTI_AFFINITY", "always"),
    ]:
        _ = setenv(kv[0], kv[1])
        var refused = False
        try:
            _ = KubePlacement.from_env()
        except e:
            refused = True
            assert_true(kv[0] in String(e), String(e))
        assert_true(refused, kv[0])
        _ = unsetenv(kv[0])
    var t = Toleration.parse("dedicated:NoExecute")
    assert_equal(t.key, "dedicated")
    assert_equal(t.value, "")
    assert_equal(t.effect, "NoExecute")


def test_pod_stuck() raises:
    """Unschedulable from the PodScheduled condition, an image pull from a
    container's waiting state; nothing for a pod that's starting or ran."""
    var unsched = _pod(
        '{"phase": "Pending", "conditions": [{"type": "PodScheduled",'
        ' "status": "False", "reason": "Unschedulable", "message": "0/1 nodes'
        " are available: 1 node(s) didn't match Pod's node affinity/selector."
        '"}]}'
    )
    var s = pod_stuck(unsched)
    assert_equal(s.reason, "Unschedulable")
    var t = stuck_text(s, "morca-7-1", "driver")
    assert_true(
        t.startswith(
            "held: pod morca-7-1 (the driver) can't be scheduled"
            " (Unschedulable): 0/1 nodes are available"
        ),
        t,
    )
    for reason in ["ImagePullBackOff", "ErrImagePull"]:
        var pull = _pod(
            String(
                '{"phase": "Pending", "conditions": [{"type": "PodScheduled",',
                ' "status": "True"}], "containerStatuses": [{"name": "main",',
                ' "state": {"waiting": {"reason": "',
                reason,
                (
                    '", "message": "Back-off pulling image'
                    ' \\"morca:missing\\""}}}]}'
                ),
            )
        )
        s = pod_stuck(pull)
        assert_equal(s.reason, reason)
        t = stuck_text(s, "morca-7-1-worker-0", "worker")
        assert_true(
            t.startswith(
                String(
                    "held: pod morca-7-1-worker-0 (the worker) can't pull its",
                    " image (",
                    reason,
                    '): Back-off pulling image "morca:missing"',
                )
            ),
            t,
        )
    # Pulling, or waiting for a node the autoscaler hasn't said no to yet.
    var creating = _pod(
        '{"phase": "Pending", "containerStatuses": [{"name": "main",'
        ' "state": {"waiting": {"reason": "ContainerCreating"}}}]}'
    )
    assert_equal(pod_stuck(creating).reason, "")
    assert_equal(pod_stuck(_pod('{"phase": "Pending"}')).reason, "")
    var running = _pod(
        '{"phase": "Running", "conditions": [{"type": "PodScheduled",'
        ' "status": "False", "reason": "Unschedulable"}]}'
    )
    assert_equal(pod_stuck(running).reason, "")
    var long = String()
    for _ in range(100):
        long.write("abcdef")
    t = stuck_text(
        pod_stuck(
            _pod(
                String(
                    '{"phase": "Pending", "containerStatuses": [{"state":',
                    ' {"waiting": {"reason": "ErrImagePull", "message": "',
                    long,
                    '"}}}]}',
                )
            )
        ),
        "p",
        "driver",
    )
    assert_true(t.endswith("..."), t)
    assert_true(t.byte_length() < 400, t)


def test_cluster_pods_env_is_as_before() raises:
    """The kubernetes provider gives the head and the workers with no group
    what they had before it named the contract."""
    assert_equal(
        json_entries(cluster_env(KUBERNETES, ClusterProcess.head_at(6390))),
        (
            '{"name": "DISTA_ROLE", "value": "head"}, {"name":'
            ' "DISTA_PORT", "value": "6390"}'
        ),
    )
    assert_equal(
        json_entries(
            cluster_env(
                KUBERNETES, ClusterProcess.worker_of("morca-1-1-head:6390")
            )
        ),
        (
            '{"name": "DISTA_ROLE", "value": "worker"}, {"name":'
            ' "DISTA_HEAD", "value": "morca-1-1-head:6390"}, {"name":'
            ' "DISTA_ADVERTISE", "valueFrom": {"fieldRef": {"fieldPath":'
            ' "status.podIP"}}}'
        ),
    )
    var d = driver_env(KUBERNETES, "morca-1-1-head:6390")
    assert_equal(len(d), 1)
    assert_equal(d[0].text(), "DISTA_HEAD=morca-1-1-head:6390")
    assert_equal(len(driver_env(KUBERNETES, "")), 0)


def test_a_group_pods_env() raises:
    """A group's worker gets DISTA_GROUP and the GPUs it sees, from 0."""
    var p = ClusterProcess.worker_of("h:6390", group="gpu")
    p.gpus = True
    p.devices = pod_devices(2)
    var env = loads(String("[", json_entries(cluster_env(KUBERNETES, p)), "]"))
    var got = Dict[String, String]()
    for e in env.array_items():
        var v = e.get("value")
        got[
            e["name"].string_value()
        ] = v.value().string_value() if v else String("<field>")
    assert_equal(got["DISTA_GROUP"], "gpu")
    assert_equal(got["MORCA_GRANT_GPUS"], "0,1")
    assert_equal(got["CUDA_VISIBLE_DEVICES"], "0,1")
    assert_equal(got["DISTA_ADVERTISE"], "<field>")
    assert_false("DISTA_TOKEN" in got)
    # A group without GPUs sees none.
    p.devices = pod_devices(0)
    var none = loads(String("[", json_entries(cluster_env(KUBERNETES, p)), "]"))
    for e in none.array_items():
        if e["name"].string_value() == "CUDA_VISIBLE_DEVICES":
            assert_equal(e["value"].string_value(), "")


def test_a_groups_gpus_are_limits() raises:
    var s = PodSize(1000, 2000, 1024, 2048)
    var gpu = loads(s.resources(1)).at("/limits").get("nvidia.com/gpu")
    assert_true(Bool(gpu))
    assert_equal(gpu.value().string_value(), "1")
    assert_false(Bool(loads(s.resources()).at("/limits").get("nvidia.com/gpu")))
    assert_equal(s.resources(), s.resources(0))


def test_group_pods_are_counted_with_the_run() raises:
    var d = KubeDefaults(500, 250, 1000, 2000, 512)
    var sizes = kube_sizes(Request(0, 0, 0, 0), 0, 0, d)
    var g: List[GroupPods] = [
        GroupPods("gpu", 2, 1, PodSize(4000, 4000, 16384, 16384)),
        GroupPods("io", 0, 0, PodSize(1000, 2000, 512, 512)),
    ]
    var plain = with_groups(sizes, 2, List[GroupPods]())
    assert_equal(plain.cpu_millis, sizes.requests(2).cpu_millis)
    var both = with_groups(sizes, 2, g)
    assert_equal(both.cpu_millis, sizes.requests(2).cpu_millis + 8000)
    assert_equal(both.memory_mb, sizes.requests(2).memory_mb + 32768)
    # Only groups have workers: the head is counted too.
    var only = with_groups(sizes, 0, g)
    assert_equal(only.cpu_millis, 500 + 250 + 8000)
    # No worker at all: the driver alone, as before.
    assert_equal(with_groups(sizes, 0, List[GroupPods]()).cpu_millis, 500)


def test_group_pod_names() raises:
    var z = PodSize(0, 0, 0, 0)
    var g: List[GroupPods] = [
        GroupPods("a-b", 1, 0, z),
        GroupPods("a_b", 1, 0, z),
        GroupPods("gpu_big", 1, 0, z),
    ]
    var slugs = pod_slugs(g)
    assert_equal(slugs[0], "a-b")
    assert_equal(slugs[1], "g1")
    assert_equal(slugs[2], "gpu-big")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
