# morca on Kubernetes

November 1, 2026

How morca will create the pods a run needs, what that takes on AWS, how its cost stays bounded, and the small Kubernetes client it needs. This is phase 5 of [DESIGN.md](DESIGN.md). The client is built ([k8s.mojo](https://github.com/magmalake/k8s.mojo)), and so are the image, the manifests (`deploy/`) and a dista cluster per run (`morca._internal.kube`), tested on kind (`tests/kind.sh`), with the warehouse and the logs in object storage (MinIO on kind); AWS comes next (DESIGN.md, phase 5).

## Who creates the pods

**The morca scheduler does**, not the pipeline binary and not dista. The scheduler is the generic `morca` binary, deployed as a Kubernetes Deployment. For each run it creates a few objects, all labelled `orca.run=<id>`:

| Object | What it is |
|---|---|
| A Pod and a Service for the dista head | The Service gives the head a DNS name, which becomes `DISTA_HEAD` |
| N worker Pods, sized for the pipeline | dista's workers: the pipeline's image with `DISTA_ROLE=worker` |
| A Job for the driver | The pipeline binary: `taxi run ...`, or `taxi resume <run>` |
| A Secret, for a run with secrets | The values of its `secrets`, which its pods refer to by name |

Every pod also gets the bucket: the scheduler's `AWS_REGION`, `AWS_ENDPOINT_URL_S3` and the like, and `MORCA_WAREHOUSE` and `MORCA_LOGS` when they're in object storage, so steps reach the warehouse and attempts' logs and timelines go to the bucket. The S3 keys come from the stack's Secret `morca-s3` in `morca-runs` (`MORCA_RUN_S3_SECRET`) by `secretKeyRef`, so no Job or Pod object holds them. Before a run's objects go, the scheduler keeps its driver's, head's and workers' logs beside its attempts' (`driver.log`, `head.log`, `worker-<i>.log`).

The scheduler watches the Job, and deletes everything labelled with the run when it ends.

Beside the scheduler, in the `morca` namespace, `morca ui` is a Deployment of its own with an Ingress, rolled one pod at a time on `/healthz`, so replacing the scheduler leaves the UI up. A project's apps (`[apps.<name>]`, [docs/morca-toml.md](docs/morca-toml.md#apps)) are a Deployment and a Service each, which `morca config apps --kube` prints from the image's morca.toml for `kubectl apply`, as `morca-stack` reads the image's `morca config apps` on Hetzner. The scheduler doesn't apply them: it has no rights in `morca`, and an app changes only with its image, when the stack's manifests are applied anyway (deploy/k8s/ui.yaml).

The driver and workers ask for the pipeline's `cpus` and `memory_gb`, its minimum as their requests and its maximum as their limits, and the head for the runner's defaults ([docs/morca-toml.md](docs/morca-toml.md#on-kubernetes)). A pod killed for its memory, `OOMKilled` or `Evicted`, fails the run's attempts saying so, and the run starts again on a new cluster whose pods ask for 1.5 times the memory, up to `memory_gb`'s maximum, as a run killed in its cgroup does on Hetzner.

Why the scheduler, and not the driver asking for its own workers:

- **Cleanup.** If the driver crashes, something outside it has to delete the cluster. The scheduler outlives every run.
- **Permissions.** Only the scheduler's service account may create pods. Pipeline code, with its heavy dependencies, gets none.
- **Sizing and limits.** The scheduler already decides how many runs run at once, so it's where cluster sizes and budgets are enforced.

Inside a run nothing changes: the driver calls `Runtime(...)`, and in cluster mode dista finds its head through `DISTA_HEAD`, which the scheduler sets on the Job. The same step code runs locally and on Kubernetes.

Driver-side autoscaling, a run asking for more workers while it runs as Ray's autoscaler does, is left out. If phase 5 shows runs need it, the driver will ask the scheduler, not the Kubernetes API.

## How it talks to Kubernetes

The Kubernetes API is HTTPS with JSON. Creating a pod is `POST /api/v1/namespaces/morca-runs/pods` with the pod's spec as the body.

- **Authentication.** The scheduler runs under a **ServiceAccount**. Kubernetes mounts a token and the cluster's CA certificate into its pod (`/var/run/secrets/kubernetes.io/serviceaccount/`), and the scheduler sends the token as a bearer header.
- **Authorization.** A **Role** in the `morca-runs` namespace grants create, get, list, watch and delete on pods, jobs and services there, and create, get, list and delete on secrets (a run's own, `morca._internal.kube`), and nothing else.
- **Watching.** `GET ...?watch=true&labelSelector=morca.run%3D<id>` is a long-lived response with one JSON event per line.

### Cleanup, in layers

Orphaned clusters are the main cost risk, so cleanup doesn't depend on any one process:

1. The head, its Service and the workers carry **ownerReferences** to the driver Job. Deleting the Job makes Kubernetes delete them.
2. The Job sets **`activeDeadlineSeconds`**, so a stuck run is killed, and **`ttlSecondsAfterFinished`**, so a finished one is removed even while the scheduler is down.
3. **On start-up**, the scheduler deletes every `orca.run` object whose run Postgres doesn't list as running.

### Nodes

morca never creates EC2 instances. Pods ask for CPU and memory; the cluster's node autoscaler (Karpenter, built into EKS Auto Mode) starts nodes for pods that are waiting and removes nodes once they're empty. A pod no node will take, or whose image can't be pulled, holds its run, which says why on its page and alerts once, rather than starting again ([stuck pods](docs/morca-toml.md#stuck-pods)). Private images are pulled with the stack's `MORCA_KUBE_PULL_SECRET`.

## Secrets and backups

The manifests (`deploy/k8s/`) hold no passwords: the Secrets `morca-db` (Postgres's password and URL) and `morca-s3` (the bucket's keys) are made apart from them, as `deploy/k8s/local-secrets.yaml` says, and that file has them with passwords for kind only. Run secrets (`morca register --secret NAME=orca/<id>`) come from the Secret `morca-secrets` in `morca`, mounted in the scheduler, whose `MORCA_SECRET_FETCH` reads the key named by the id with each `/` as a `.` (`orca/github-token` is `orca.github-token`), so they need no AWS:

```sh
kubectl -n morca create secret generic morca-secrets --from-literal=orca.github-token=...
```

**Backups.** The CronJob `morca-backup` (`deploy/k8s/postgres-backup.yaml`) makes the dump `morca-stack backup` makes on Hetzner ([docs/hetzner.md](docs/hetzner.md#backups-and-restore)), every night at 02:30 UTC: `pg_dump -n orca -Fc`, checked that it reads back, uploaded to `MORCA_BACKUPS` (`s3://morca/backups/pg/<time>.dump`), the newest `MORCA_BACKUP_KEEP` (14) kept. A failed backup fails the Job and is pushed with `morca notify --kind backup-failed` when alerts are set up on it (`MORCA_NOTIFY_URL`, `MORCA_NOTIFY_SECRET`). `kubectl -n morca create job backup-now --from=cronjob/morca-backup` makes one now.

**Restore.** Into a new, empty Postgres (a lost volume) or over the old one, with the scheduler and the UI stopped so nothing writes or holds a connection meanwhile:

```sh
kubectl -n morca scale deployment/morca-scheduler deployment/morca-ui --replicas=0
kubectl -n morca delete job morca-restore --ignore-not-found
kubectl apply -f deploy/k8s/restore/restore.yaml        # the newest dump
kubectl -n morca wait --for=condition=complete job/morca-restore --timeout=600s
kubectl -n morca scale deployment/morca-scheduler deployment/morca-ui --replicas=1
```

The Job's `DUMP` names another dump (`20261107T023000Z.dump`), and `FORCE=1` drops an existing `orca` schema first; without it a database that has one is left alone and the Job fails (the file says how to set them). The warehouse and the logs are in the bucket and need no restore. Test a restore before you need one: `tests/kind.sh` restores into a new Postgres and checks the runs are back.

## Deploying

`deploy/k8s/deploy.sh <tag>` deploys the project's image at a tag, as `deploy/hetzner/deploy.sh` does on Hetzner ([docs/hetzner.md](docs/hetzner.md#deploying-code)), with kubectl's current context as the cluster. Its settings are `deploy/k8s/kube.env` (`KUBE_ENV` names another; `kube.env.example` says what each is): `MORCA_IMAGE`, the image without its tag, and `DRAIN_SECONDS` are required, and `HANDOVER_WAIT_SECONDS` once the image's morca.toml declares a concurrency key, as the census's does. The scheduler gets them from the ConfigMap `morca-settings` as `MORCA_OVERLAP` (on unless `OVERLAP=0`), `MORCA_DRAIN_SECONDS` and `MORCA_HANDOVER_WAIT_SECONDS`. In order, it:

1. checks the settings, and the new image's `morca config check` for a concurrency key without the wait limit, before anything changes;
2. when the tag changes, does the "before" steps of the image's `upgrade.toml` ([A release's upgrade steps](docs/hetzner.md#a-releases-upgrade-steps)), each asked for, run with `--yes` or named in `--confirmed`;
3. plans: the scheduler is replaced when its image or its settings change. A run is a Job, not the scheduler's process, so a replacement (a `Recreate`) doesn't stop it either way. When the new image's `morca scheduler can-overlap` says yes, nothing is paused: the old image's runs go on, see they're outdated once the new code is registered (`morca.outdated()`) and end when their code decides, and a run waiting on their concurrency key then starts on the new code. Otherwise (`OVERLAP=0`, a migration that raises the floor, a rollback) it pauses the pipelines, waits for the running runs (`--timeout`, an hour) and unpauses them at the end;
4. backs up the database, the CronJob `morca-backup` as a Job of its own, and stops if that fails (`--no-backup` doesn't back up);
5. applies the manifests (`MANIFESTS`, by default `morca.yaml`, `runs.yaml`, `postgres-backup.yaml` and `ui.yaml`, their `morca:dev` as the new image) and the apps from the image's `morca config apps --kube`, and waits for them to roll out;
6. waits until the new scheduler leads and registers the pipelines from the image's morca.toml (`morca register`);
7. does the "after" steps, unpauses what it paused, and records the tag and the one before it in the ConfigMap `morca-deployed`;
8. checks: Postgres answers, the Deployments run the new image, one scheduler instance leads, every pipeline's binary is in the image, and `CANARY`'s runs succeed.

When the rollout, the registration or the check fails, it rolls back to the tag before (`deploy.sh --rollback`, which doesn't overlap and runs no upgrade steps) and fails, unless `--no-rollback`. `deploy.sh --rollback` does it by hand. `--dry-run` prints the plan and the commands that would change something, and changes nothing; it runs no pod of the new image, so it lists no upgrade steps and shows the way without overlap. `tests/kind-deploy.sh` tests it on kind.

## Testing on a real cluster

`tests/kind.sh` runs on one kind node. `tests/k3s-hetzner.sh` (#559) runs on a real cluster: two Hetzner CAX (ARM) servers made for the test, k3s on them, the project's image from ghcr and a bucket of its own on Hetzner Object Storage. It isn't in CI, since each run costs money: about 0.04 for the started hour of two CAX21s. Ask before you run it. It checks that:

- a census pipeline (gharchive, one day) runs with its dista head on node a and its driver and workers on node b, and succeeds, with its logs and tables in the bucket;
- a backfill run whose node b is powered off mid-run is started again on node a 30 s or so later, workers included, and succeeds. A run of `morca start` isn't retried, by design (`run_retries` covers scheduled, backfilled, sensed and fill runs);
- the lost start's pods, stuck `Terminating` on the dead node, are swept. This fails until [#575](https://github.com/morca-dev/morca/issues/575).

```sh
S=../ops-secrets/dev/secrets.sops.yaml
eval "$(sops -d --extract '["s3.env"]' $S | sed "s/^\([^=]*\)=\(.*\)$/export \1='\2'/")"
GHCR_TOKEN=$(sops -d --extract '["ghcr-token"]' $S) GHCR_USER=... HCLOUD_CONTEXT=orca-dev tests/k3s-hetzner.sh
```

The script's header lists its settings: server type, location, image, days, workers and k3s version. It deletes everything it made (servers, firewall, SSH key and bucket, all named and labelled `morca-k3s-test-<time>`) on every exit, and prints what the servers cost. If something is left, it says so. `tests/k3s-hetzner.sh --cleanup` deletes whatever any earlier run left. Node a is tainted `PreferNoSchedule` and node b `NoSchedule`, and the runs' placement settings (`MORCA_KUBE_HEAD_NODE_SELECTOR`, `MORCA_KUBE_DRIVER_TOLERATIONS`, `MORCA_KUBE_WORKER_TOLERATIONS`) put each role where the checks expect it. k3s takes a node for NotReady after 20 s, and evicts its pods 30 s later.

## What it needs on AWS

Everything goes in the project's selected Region; confirm it in AWS Settings > View all projects > Overview > Additional Info > Region. The dista benchmarks ran in us-east-2. The project is on the paid plan.

| Resource | What for | Cost notes |
|---|---|---|
| **EKS cluster**, Auto Mode | The Kubernetes control plane, and Karpenter for nodes | The control plane is a fixed hourly fee, whether or not anything runs |
| **EC2 nodes** | A small always-on node for the scheduler; Spot nodes for run clusters | Run nodes exist only while runs do |
| **VPC and subnets** | Networking | A **NAT gateway** is the usual hidden cost. An S3 gateway endpoint, which has no charge, keeps S3 traffic off it |
| **S3 bucket** | The warehouse, logs, checkpoints | Lifecycle rules expire old logs |
| **Postgres** | morca's state | A small RDS instance, or a Postgres pod on an EBS volume. Either way with `synchronous_commit` on (see DESIGN.md's testing section) |
| **ECR repository** | Pipeline images | A lifecycle policy drops old images |
| **IAM roles**, through EKS Pod Identity | Run pods can read and write their bucket prefix and nothing else | The scheduler needs no AWS permissions, only Kubernetes RBAC |

**Quotas.** The free plan's on-demand vCPU quota was 16 and Spot 32. If the paid plan kept those, a 12-node run needs an increase, requested in Service Quotas.

**A cheaper first step** is k3s on one EC2 instance: no control-plane fee, and the same API, so morca doesn't change. It's a reasonable place to prove phase 5 before paying for EKS.

## Controlling cost

Limits stack from morca down to AWS, and each layer catches what the one above misses:

| Layer | Control |
|---|---|
| **morca** | `max_runs` per pipeline; a total vCPU budget across all runs, checked before a cluster is created; a maximum cluster size per pipeline; a deadline per run. morca records pods × size × duration per run in Postgres, and with `MORCA_KUBE_PRICE_VCPU_HOUR` and `MORCA_KUBE_PRICE_GB_HOUR` set the run page shows an estimated cost per run, fills keep to `fill_budget_per_day`, and the watchdog's `cost` rule counts the pods ([Kubernetes prices](docs/morca-toml.md#kubernetes-prices)). |
| **Kubernetes** | A **ResourceQuota** on `morca-runs`: a hard cap on the CPU and memory all run pods can request. If morca has a bug, extra pods just wait. |
| **Karpenter** | **NodePool limits**, such as `cpu: 64`: the most EC2 that can run at once, whatever asks for it. |
| **Spot** | Workers on Spot, typically 60–90% cheaper. A reclaimed worker means retried dista tasks, a lost driver means `morca resume`, both of which phase 1 already handles. The head and driver stay on on-demand: each role's node selector and tolerations are the stack's `MORCA_KUBE_<ROLE>_NODE_SELECTOR` and `_TOLERATIONS` ([where the pods go](docs/morca-toml.md#where-the-pods-go)). |
| **AWS** | **Budgets** alerts in the Billing and Cost Management console. A **spend limit** in AWS Settings > Billing, which pauses the *whole project* when it's reached; only the project owner can set it. Tags `morca.pipeline` and `orca.run` on what runs create, for cost allocation. |

## A Kubernetes client in Mojo

morca needs a small one, not a general client. Go's client-go is generated from the whole OpenAPI spec; morca uses about three resource kinds and five operations:

- create, get and delete for Pod, Job and Service;
- list and watch by label, where a watch is a stream of JSON lines;
- configuration in-cluster (the service-account token and CA) and from a kubeconfig, for local testing on kind, which authenticates with client certificates.

That's about 1,000–1,500 lines on what magmalake already has: HTTPS with a custom CA through objectstore's libcurl, or flare's TLS, and a JSON library. It goes in a tin of its own, [k8s.mojo](https://github.com/magmalake/k8s.mojo), rather than in morca: dista's planned `dista` command, for operating a cluster, needs the same calls.

Until it exists, phase 5 can be prototyped two ways:

- **Shell out to `kubectl`.** No Mojo code, but a binary in the image and errors that are hard to handle.
- **Apply templated manifests.** The scheduler writes YAML and something else applies it.

The narrow API makes the tin worth writing first.
