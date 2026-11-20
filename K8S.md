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

morca never creates EC2 instances. Pods ask for CPU and memory; the cluster's node autoscaler (Karpenter, built into EKS Auto Mode) starts nodes for pods that are waiting and removes nodes once they're empty.

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
| **Spot** | Workers on Spot, typically 60–90% cheaper. A reclaimed worker means retried dista tasks, a lost driver means `morca resume`, both of which phase 1 already handles. The head and driver stay on on-demand. |
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
