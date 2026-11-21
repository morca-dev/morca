"""Apps on Kubernetes (#565): a Deployment and a Service for each
`[apps.<name>]` of morca.toml, as `morca config apps --kube` prints them for
`kubectl apply -f -`. They give the app what `morca-stack` gives it on
Hetzner (docs/hetzner.md#apps):

- `PORT`, its `env`, and `MORCA_IMAGE_BYTES` when it's given;
- with `lake = true`, the stack's ConfigMap `morca-lake` (the warehouse
  settings) and Secret `morca-s3` (the S3 keys), as `envFrom`;
- each of its `secrets` by reference to its key of the Secret
  `morca-app-<name>`, which the stack's operator makes, so no Deployment
  holds a value;
- `memory_gb` as its memory request and limit, and its `check` as the
  readiness probe, so a rolling update keeps the old pod until the new one
  answers.

The scheduler doesn't apply them: it has no rights in the stack's own
namespace (K8S.md), and an app changes with its image, when the stack
applies its manifests anyway. Every value is a JSON string, which YAML reads
as it is.
"""

from morca._internal.apps_config import AppConfig
from morca._internal.json import quote

comptime KUBE_TAKEN = ["minio", "morca-scheduler", "morca-ui"]
"""deploy/k8s's own Services and Deployments, which an app can't be named."""


def kube_name(app: String) -> String:
    """An app's name as a Kubernetes object's (DNS-1123): `_` as `-`."""
    return app.replace("_", "-")


def secret_ref(app: String) -> String:
    """The Secret an app's `secrets` are keys of."""
    return String("morca-app-", kube_name(app))


def apps_kube(
    apps: List[AppConfig],
    image: String,
    namespace: String = "morca",
    image_bytes: String = "",
    pull_secret: String = "",
) raises -> String:
    """The manifests, a Deployment and a Service per app, each a YAML
    document; raises for an app without a port, a name taken, or an image
    or size that isn't one."""
    if not image or " " in image or "\n" in image or '"' in image:
        raise Error("--image is the image's reference, like ghcr.io/o/p:tag")
    for b in image_bytes.as_bytes():
        if Int(b) < ord("0") or Int(b) > ord("9"):
            raise Error("--image-bytes is a number of bytes: ", image_bytes)
    var out = String()
    for a in apps:
        var name = kube_name(a.name)
        for t in materialize[KUBE_TAKEN]():
            if name == t:
                raise Error(
                    "app ", a.name, ": ", t, " is one of deploy/k8s's own"
                )
        if a.port == 0:
            raise Error(
                "app ",
                a.name,
                " has no port: give [apps.",
                a.name,
                "] port in morca.toml",
            )
        var labels = String("{morca.app: ", quote(name), "}")
        out.write(
            "---\n# [apps.",
            a.name,
            "] of morca.toml (morca config apps --kube).\n",
        )
        if len(a.secrets) > 0:
            out.write(
                "# Its secrets are keys of the Secret ",
                secret_ref(a.name),
                ", which you make:\n",
            )
            for s in a.secrets:
                out.write("#   ", s[0], ": the value of ", s[1], "\n")
        out.write(
            "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: ",
            quote(name),
            "\n  namespace: ",
            quote(namespace),
            "\n  labels: ",
            labels,
            "\nspec:\n  replicas: 1\n",
            "  strategy: {type: RollingUpdate, rollingUpdate:",
            " {maxUnavailable: 0, maxSurge: 1}}\n",
            "  selector:\n    matchLabels: ",
            labels,
            "\n  template:\n    metadata:\n      labels: ",
            labels,
            "\n    spec:\n",
        )
        if pull_secret:
            out.write(
                "      imagePullSecrets: [{name: ", quote(pull_secret), "}]\n"
            )
        out.write(
            "      containers:\n        - name: ",
            quote(name),
            "\n          image: ",
            quote(image),
            "\n          command: [",
            quote(String("/opt/morca/bin/", a.name)),
            "]\n          env:\n",
            "            - {name: PORT, value: ",
            quote(String(a.port)),
            "}\n",
        )
        for e in a.env:
            out.write(
                "            - {name: ",
                quote(e[0]),
                ", value: ",
                quote(e[1]),
                "}\n",
            )
        if image_bytes:
            out.write(
                "            - {name: MORCA_IMAGE_BYTES, value: ",
                quote(image_bytes),
                "}\n",
            )
        for s in a.secrets:
            out.write(
                "            - name: ",
                quote(s[0]),
                "\n              valueFrom: {secretKeyRef: {name: ",
                quote(secret_ref(a.name)),
                ", key: ",
                quote(s[0]),
                "}}\n",
            )
        if a.lake:
            out.write(
                "          envFrom:\n",
                "            - configMapRef: {name: morca-lake}\n",
                "            - secretRef: {name: morca-s3}\n",
            )
        out.write(
            "          ports: [{containerPort: ",
            a.port,
            "}]\n          readinessProbe:\n            httpGet: {path: ",
            quote(a.check),
            ", port: ",
            a.port,
            "}\n            periodSeconds: 2\n",
        )
        if a.memory_mb > 0:
            var mem = String(a.memory_mb, "Mi")
            out.write(
                "          resources:\n            requests: {memory: ",
                mem,
                "}\n            limits: {memory: ",
                mem,
                "}\n",
            )
        out.write(
            "---\napiVersion: v1\nkind: Service\nmetadata:\n  name: ",
            quote(name),
            "\n  namespace: ",
            quote(namespace),
            "\n  labels: ",
            labels,
            "\nspec:\n  selector: ",
            labels,
            "\n  ports: [{port: ",
            a.port,
            ", targetPort: ",
            a.port,
            "}]\n",
        )
    return out^
