# Worker groups and GPUs on pools: a plan

November 27, 2026 · a plan for step 4 of [layers.md](layers.md), nothing
here is built

dista now routes a task or an actor to the workers of a named group, reports
demand per group and runs flows (dista #152 to #167). morca can't use any of
it yet: a run asks for a count of workers, a host reports CPUs and memory
only, and no worker is started with a group. This plan closes that for
pools, which [layers.md](layers.md) makes the one model, and then for the
other ways a run gets workers.

## What exists, and what is missing

| Part | Today | Missing |
|---|---|---|
| Request | `workers`, `cpus`, `memory_gb` per pipeline (`Registered`, `Request`) | Workers per group, each group with its own size and GPUs |
| Host facts | CPUs and memory, less a reserve (`host_room`), sent with each claim | GPUs |
| Grant | `Grant(cpus, memory_mb)`, as `MORCA_GRANT_*` | GPUs, and which devices |
| Members of a run | `join_claim` hands an idle worker a `MemberSpec` (head, token, grant) | The group the member serves; `DISTA_GROUP` on its dista worker |
| Pool demand | SQL: queued runs, plus `workers` less the live members | What each running run's head wants, per group |
| Taking a member back | Only when its run ends | Draining one while the run goes on |
| Scaling by dista's demand | Only the `ec2` placement (`decide` and `dista-drain`) | The same on pools |

Two things found while reading that this plan fixes on the way:

- On a pool, `workers = "MIN..MAX"` ignores MIN and asks for MAX members,
  and `Pipeline[workers=]` in code is ignored (the SQL reads only the
  registered column).
- The `DISTA_*` names morca sets aren't reserved in a pipeline's `env`.

## Requests: groups beside `workers`

```toml
[pipelines.embed]
placement = "worker:batch"
workers = "1..4"            # the workers with no group, as today
cpus = 4

[pipelines.embed.groups.gpu]
workers = "0..2"
gpus = 1                    # per worker
cpus = 4
memory_gb = 16
```

- A group has `workers` (a count or a range), and `cpus`, `memory_gb` and
  `gpus` per worker. What it doesn't set falls back to the pipeline's.
- The keys outside `groups` keep their meaning: they describe the workers
  with no group, which is where dista sends a task that names none.
- Groups are stored as one `jsonb` column on `orca.pipelines`, and copied
  into the run's `spec` when it starts. Both are additive.
- In code, a task names its group (`Task[..., group="gpu"]` in dista).
  `register` and `config check` refuse a pipeline whose tasks name a group
  the pipeline doesn't declare, if the binary's `describe` can list them;
  otherwise the run fails at its first such task with dista's message.

## Hosts and grants: GPUs

- `morca worker` counts its GPUs once at start: `MORCA_HOST_GPUS` if set,
  else the devices `nvidia-smi` lists, else none. It sends the count with
  each claim, and the scheduler stores it beside `room_cpus`.
- `Grant` gains the GPUs it holds, as device indexes. The worker hands them
  out itself, since only it knows which are free, and sets
  `MORCA_GRANT_GPUS` and `CUDA_VISIBLE_DEVICES` on the member's process.
- A GPU is granted whole, to one member at a time. A member of a group that
  asks for none gets none, and its `CUDA_VISIBLE_DEVICES` is empty.
- A host with GPUs serves groups without them only when no host without
  GPUs has room, so a decode worker doesn't take the place a model needs.

## Members by group

- `orca.run_members` gains the member's group. `join_claim` picks, for an
  idle host, a running run and a group of it that is short of members and
  that the host can serve (room for its size, a free GPU if it asks one).
- `start_dista_worker` sets `DISTA_GROUP`. The claiming host's own dista
  worker has no group, as today.
- The driver and head stay on the claiming host.

## Demand per group

- The host that runs a run's head asks it for its status (`<binary>
  dista-status`, which exists) every few polls and sends the answer with
  its claim. The scheduler can't always reach the head, and the host can.
- The scheduler keeps the last answer on the run and calls dista's
  `decide` once per group, with the group's range as the policy's bounds.
  The result is how many members of each group the run wants now.
- `join_claim` and the pool's demand query use those wanted counts where
  they used `workers`. Before the first answer a run wants each group's
  MIN, which is also the fix for the ignored MIN.
- When `decide` says a group has too many, the scheduler tells the member's
  host to stop it. The host drains the dista worker first (`dista-drain`)
  and kills it when it has left or after a timeout.
- A pool grows when wanted members have no host. A group that asks for
  GPUs needs a machine type that has them: a pool lists those under
  `gpu_machines`, with the same shape as `machines`, and is otherwise
  unchanged.

## One contract for every provider

"Give run R a worker of group G, of this size, from this image, joined to
this head with this token", and "take it back". After the PRs above the
pool path is that contract, in `MemberSpec` and the stop list. The last PR
names it and moves the other providers behind it:

| Provider | Give | Take back |
|---|---|---|
| Pool host (`morca worker`) | `join_claim` to `MemberSpec` | Drain, then kill |
| Local and `control` | Fork with `Runtime(groups=...)`, sized from the run's grant | The run's end |
| Kubernetes | A worker Pod per member, sized from the group, with `DISTA_GROUP` and `nvidia.com/gpu` | Delete the Pod after a drain |

- One function builds a dista worker's environment for all three.
- Kubernetes and local get groups but no scaling in this plan: they start
  each group at its MAX and MIN respectively. Scaling there follows if the
  gate needs it.
- The `ec2` placement gets none of this. It is to be retired
  ([layers.md](layers.md)), and `register` warns when a pipeline placed on
  it declares groups.
- `register` and `config check` warn about group keys a placement ignores.
  The full table of keys per placement is
  [#369](https://github.com/morca-dev/morca/issues/369), not this plan.

## Not in this plan

- Labels other than GPUs (a GPU model, a zone). A second pool does that job
  until something needs more.
- A fraction of a GPU, or several members sharing one.
- A group whose members come from another pool than the run's.
- Moving the `ec2` placement's users to pools, and removing it.
- Jobs that aren't runs, a shared head and named actors.

## PRs

| # | What | Tests |
|---|---|---|
| 0 | Move the dista pin to the release with groups and flows | The existing suite |
| 1 | Groups in `morca.toml`, `Registered`, the database and `describe`; `config check`; reserve the `DISTA_*` names. No change in what runs. (done) | Unit tests of the parser and the stored form |
| 2 | GPUs: the host's count, the claim, `Grant`, admission, the UI's host and run pages (done) | `test-grants` with `MORCA_HOST_GPUS` |
| 3 | Members by group on pools: `run_members`, `join_claim`, `DISTA_GROUP`, MIN honoured | `test-run-cluster` with a GPU group on a mixed pair of hosts: the group's task runs only there |
| 4 | Demand per group: the head's status with the claim, `decide` per group, draining a member, `gpu_machines` in a growing pool | `test-pool-scale` with a group that grows from 0 and drains when idle |
| 5 | The contract by name: one environment builder, groups on local, `control` and Kubernetes, warnings for the `ec2` placement | `test-kube`, and a local run with two groups |

Each PR leaves a pipeline without groups behaving as it does today, except
for the MIN fix in PR 3.

## Defaults (confirmed 2026-11-27)

1. Groups are declared per pipeline in `morca.toml`, with the keys above,
   and the un-grouped keys keep meaning the workers with no group.
2. GPUs are counted whole and matched by count. No other labels yet.
3. A mixed pool is one pool with `machines` and `gpu_machines`, not a pool
   per group.
4. The head's host reports dista's demand, and the scheduler decides with
   dista's `decide`. Pools take over the scaling the `ec2` placement has.
5. Pools first, then local and Kubernetes with groups but without scaling.
   The `ec2` placement gets nothing.
