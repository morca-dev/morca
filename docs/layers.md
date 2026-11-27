# Layers: from a pipeline orchestrator to a Ray replacement

November 26, 2026 · a proposal, nothing here is built unless it says "today"

morca and dista together should replace Ray for Mojo programs. This names
the layers of that system, says which exist, and proposes what to build
next. It is a map for the other design documents ([DESIGN.md](../DESIGN.md),
dista's [DESIGN.md](https://github.com/morca-dev/dista/blob/main/DESIGN.md)),
not a replacement for them.

## Decisions this starts from

| Question | Decision (2026-11-26) |
|---|---|
| Which Ray workload is the next gate? | Ray Data: batch inference over a dataset larger than memory. |
| Is a cluster always made for one run? | No. Machines are shared and outlive runs. |
| Can a live channel cross a step boundary? | No. A step boundary stays durable: small values in the state database, and table snapshots. |
| How many projects share a fleet? | One, for now. A machine's agent runs one image, the server's. |
| Where does the flow library live? | In dista, as the package `dista.flow`. |
| Which GPU is the gate measured on? | Metal, which Mojo targets, on the M4 worker. |
| What becomes of the `ec2` placement? | Pools that grow replace it. EC2 stays as a pool provider. |

## Why the layers were unclear

The vision draws one stack: morca over dista over the tins over Kubernetes.
The code isn't one stack. morca sits on both sides of dista:

- **Under it**, morca gets the machines: the runners (`local`, `control`,
  `kubernetes`, `ec2`), pools of remote workers, requests and grants,
  autoscaling.
- **Over it**, morca orchestrates: pipelines, partitions, schedules,
  lineage and the UI.

Getting machines is therefore a feature of the orchestrator, and only a
pipeline run can ask for them. Ray's value is mostly in the two layers that
are thin or missing here: how running things talk to each other, and the
libraries built on that.

## The layers

| | Layer | What it answers | Ray's name for it | Lives in | Today |
|---|---|---|---|---|---|
| 1 | **Fleet** | Which machines exist, and which job gets how much of each | autoscaler, KubeRay, the raylet's resources | morca | Built for runs: placements, `[pools]`, grants. No GPUs or labels. |
| 2 | **Core** | Run this function there, keep this state, hold this result | Ray Core | dista | Tasks, actors, objects, shuffles, spilling, draining. |
| 3 | **Communication** | How tasks and actors hand each other data while they run | generators, `ray.wait`, nested refs, named actors | dista | `ObjectRef`, ordered actor calls, `TaskMany`. No streams. |
| 4 | **Flows** | A dataset through a chain of operators, in bounded memory | Ray Data | new, on dista | Nothing: the taxi and shuffle jobs are written by hand. |
| 5 | **Durable orchestration** | When work runs, in what order, what a retry repeats, what made this table | none (Airflow or Dagster beside Ray) | morca | Built: this is what morca is. |

Layer 5 is drawn on top, but it calls layer 1 directly. That is the honest
picture: morca is the control plane on both ends, and dista is the data
plane between them.

## Three boundaries, three kinds of communication

"How do steps talk to each other" has a different answer at each boundary,
and mixing them is what made the question hard:

| Boundary | Lifetime | What crosses it | Owner |
|---|---|---|---|
| Operator to operator, inside a step | A run | Refs to Arrow batches, as produced, with backpressure | dista (layers 3 and 4) |
| Step to step, inside a pipeline | Forever | A small typed value in the state database; table snapshots | morca |
| Pipeline to pipeline | Forever | A committed snapshot, seen by a sensor | morca |

- **A step is the unit of retry, so its edges must replay.** A resumed run
  hands a step the input the first attempt had. A live channel across that
  edge would have nothing to replay from. So everything live goes inside
  one step, which is already a whole dista program.
- **Between pipelines the channel is a table.** A finer channel is a
  smaller partition, not a queue: sub-day partitions and append-triggered
  runs ([#306](https://github.com/morca-dev/morca/issues/306)).
- **What steps still lack is in the durable kind**: several inputs
  ([#380](https://github.com/morca-dev/morca/issues/380)), run parameters
  ([#383](https://github.com/morca-dev/morca/issues/383)) and a versioned
  codec for outputs ([#366](https://github.com/morca-dev/morca/issues/366)).
  None of them is a new primitive.

## Layer 1: a shared fleet

Ray shares a cluster by having every worker process load any job's code.
dista can't: every process of a job is the job's one compiled binary. So
sharing here means **shared machines, and worker processes per job**:

```text
fleet     machine A (8 CPU)        machine B (8 CPU)        machine C (GPU)
          agent                    agent                    agent
            │                        │                        │
job 41    head, driver, worker     worker                   worker (group gpu)
job 42    head, driver, worker
```

Most of this exists for pools of remote workers ([workers.md](workers.md)):
`morca worker` is the agent, it admits a run against its host and gives it
a grant, another machine of the pool joins a running run as a member, each
run start has its own `DISTA_TOKEN`, and a pool grows when its runs want
more members. The proposal is to make that the one model, not one placement
among five:

1. **One contract for every provider.** "Give job J a worker of group G,
   of this size, from this image, joined to this head", and "take it back".
   The host agent, Kubernetes and a local fork each implement it. This also
   answers [#369](https://github.com/morca-dev/morca/issues/369), where each
   placement supports a different subset of features.
2. **Worker groups.** A job asks for groups, not a count: `decode = 2..8`
   workers of 2 CPUs, `gpu = 1..2` workers of one GPU. A machine reports
   its GPUs and labels beside its CPUs and memory, and a grant can hold a
   GPU.
3. **Demand per group.** dista's head already reports demand
   (`dista status --json`) and has a pure scaling policy
   (`dista.scale.decide`). Both become per group, and the fleet grows the
   group that is short.
4. **A head per job, kept.** dista has a generic head that serves several
   programs at once. A head per job costs one small process, and keeps one
   job's token, queue and failure away from another's. A shared head becomes
   worth it only for things that outlive a job (below).

Not in this step: anything other than a run asking for machines. A service
that several pipelines call needs a job that isn't a run, named actors and
a shared head. It follows the Ray Data gate, and gets its own design.

## Layers 2 and 3: what dista adds

Three additions, each small, each needed by the gate:

| | Addition | Shape | Why the gate needs it |
|---|---|---|---|
| 1 | **Wait for any** | `rt.wait(refs, count, timeout)` returns the refs that are ready. Today there is `rt.ready(ref)` and a blocking `get`. | An executor that drives several operators must act on whichever finishes first. |
| 2 | **Streamed results** | A task that puts results one at a time. Each is its own object, the caller reads them as they come, and `put` blocks once a window of them is unread. | A read task over a large file can't hold every batch, and `TaskMany` needs the count before it runs. |
| 3 | **Groups** | A worker says its group in its hello. A task or an actor names the group it runs on, and the head sends it nowhere else. | The model runs on the GPU workers and decoding on the others. |

- **Groups, not numeric resources.** Ray counts CPUs, GPUs and custom
  resources per task. Here the fleet already sized each worker process
  (its slots and memory come from its grant), so dista only has to route
  by a name.
- **Deferred still**: refs nested in values
  ([dista#68](https://github.com/morca-dev/dista/issues/68)) and named
  actors. An executor in the driver holds every ref and handle itself and
  passes refs in the shapes that work today. Both come back with services.
- **Queues and topics are not core.** With streams and actor handles they
  are a small actor, as in Ray.

## Layer 4: flows

A flow is a chain of operators over batches, run by an executor in the
driver. It is a library on dista, `dista.flow`, not part of the core:

```mojo
comptime Embed = Flow[
    Read[scan_files],                              # streamed: one batch at a time
    Map[tokenize],                                 # tasks, any worker
    MapWith[Encoder, encode, group="gpu", pool=1..2],  # actors holding the model
    Write[append_files],
]
```

- **Operators are declared at compile time**, as tasks and steps are, and
  an operator whose input isn't the previous one's output doesn't compile.
- **The executor streams.** Every operator runs at once. Each has a budget
  of batches in flight, and an operator that is full stops the one before
  it, back to the read. Peak memory is the sum of the budgets, whatever the
  dataset's size.
- **An actor pool is part of the library**: N actors of one kind, each call
  sent to the least busy, grown and shrunk within its range from the queue
  before it.
- **A flow runs inside a step.** The step pins its input snapshot, runs the
  flow and commits once. A failure repeats the step, so the partition is
  the checkpoint: keep partitions small rather than checkpoint a flow.

## The gate

The census already embeds repositories with the encoder tin (`mojo_embed`).
The gate is that workload as a flow, over a corpus several times larger
than the cluster's memory:

| Target | Bar |
|---|---|
| Memory | Peak stays under a fixed budget as the corpus grows |
| Recovery | A worker killed mid-run costs its batches, and the output is exact |
| Groups | The model runs only on the workers of its group, on a pool of mixed machines |
| Speed | Rows per second per core at least Ray Data's on the same machines, same model |
| Sharing | Two runs of different pipelines share the pool's machines while it runs |

## Order of work

| # | What | Repo |
|---|---|---|
| 1 | `rt.wait`; streamed results | dista |
| 2 | Groups: the hello, task and actor placement, demand per group | dista |
| 3 | `dista.flow`: operators, the streaming executor, the actor pool | dista |
| 4 | Worker groups and GPUs in requests, grants and `[pools]`; one provider contract | morca |
| 5 | The embedding flow and its Ray Data counterpart; measure the gate | census, dista `bench/` |

1 to 3 are done in dista. The plan for 4 is [groups.md](groups.md).

1 to 3 need nothing from morca and run in dista's local mode, so the flow
can be measured against Ray Data on one machine before 4 exists.

## Retiring the `ec2` placement

Pools that grow replace it, and EC2 stays as a pool provider.

- **It is the cluster per run this proposal leaves.** An `ec2` run gets a
  head and worker instances of its own, and waits for them to boot.
- **The warm pool exists to hide that boot.** It keeps instances per
  pipeline and per env. A shared pool keeps machines for every pipeline,
  so it does the same job with fewer idle machines.
- **Pools already make EC2 machines** (`provider = "ec2"` in `[pools]`),
  so nothing is lost: `placement = "ec2"` becomes `worker:<pool>` on such a
  pool.
- **Order:** first worker groups and demand per group on pools (step 4
  above), then move the `ec2` placement's users to a pool, then remove the
  placement and the warm pool in a breaking release.

Kubernetes stays a provider of its own: there the shared cluster is
Kubernetes, and a worker is a pod.
