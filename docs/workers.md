# Remote workers

A remote worker runs a pool's runs on a machine other than the server, such
as a coding machine with spare CPU, another server or a laptop. The worker
talks only to `morca ui`'s API, over HTTPS. Nothing on it holds database
credentials. The scheduler stays the only brain. It fires, senses, queues,
retries and runs the watchdog, and keeps all state in its Postgres. A worker
only runs what it is given.

```text
server                                         worker (bgent)
──────                                         ──────────────
morca scheduler  ── queues runs, held           morca worker --pool bgent
                   "waiting for a worker"         │  polls POST /api/worker/claim
morca ui  ◀──────── HTTPS (Cloudflare Tunnel) ─────┤  gets a run's spec
  │  /api/worker/claim, /exited, /release         │  starts <binary> resume <run>
  │  /api/worker/store/<call>  ◀── the run's state calls, with the token
  ▼                                               ▼
Postgres                                       MORCA_WAREHOUSE, MORCA_LOGS
                                               (Object Storage, straight from the worker)
```

## Placing a pipeline on a pool

```toml
[pipelines.mojo_releases]
placement = "worker:bgent"
```

Or `morca register --placement worker:bgent`. A pool's name is 1 to 32 of
`a-z`, `0-9`, `-` and `_`. The scheduler never starts these runs. They stay
queued, held "waiting for a worker of pool bgent", and the pipeline's page
says so. `max_runs` and `morca pause` apply as for any pipeline: a worker is
given a run only while its pipeline isn't paused and has fewer than
`max_runs` live runs.

## Fills on a pool

A pool-placed pipeline with `fills = "all"` fills its range as a local one
does ([morca.toml](morca-toml.md#fills)): the scheduler queues its fill runs
in the same order (`fill_order`), within the same `fill_window`, and never
over a partition that is done or in a queued or running run, or that a fill
run ever took. It doesn't start them: they stay queued, held "waiting for
a worker of pool <pool>", until a worker claims one.

**The budget.** `fill_max_runs` caps the pipeline's live fill runs across
the whole pool: the ones running on any worker and the ones queued for
one. So a fill never has more than `fill_max_runs` runs going, however many
workers the pool has, and the scheduler queues a new one only as one ends.
What one machine takes is that worker's own `--max-runs` and, for a
pipeline with a request, what its host can grant. Fill runs don't count
against `max_runs`, and the pipeline's other runs are claimed first; across
the pool's pipelines, the highest [`priority`](morca-toml.md#priority)
first, then every pipeline's other runs before any fill runs. A
worker's machine runs anyway, so a pool's fill runs cost nothing against
`fill_budget_per_day`. The pipeline page's Fill line and the coverage
calendar count the queued fill runs as live.

A two-machine pool, the server and a Mac, filling gharchive two at a time,
oldest first:

```toml
[pipelines.gharchive]
placement = "worker:gharchive"
fills = "all"
fill_order = "oldest"
fill_max_runs = 2      # across the pool
```

```sh
# On the server, once: a token per machine.
morca worker-token create --pool gharchive --label hetzner
morca worker-token create --pool gharchive --label bgent

# On each machine, its own token in worker.env (below), one run at a time:
docker run -d --name orca-worker --restart always --env-file worker.env \
    -v "$PWD/secrets:/etc/orca/secrets:ro" -v "$PWD/secret-fetch:/etc/orca/secret-fetch:ro" \
    ghcr.io/<owner>/<image>:<tag> worker --pool gharchive --max-runs 1 \
    --name hetzner --remote https://morca.example.com    # --name bgent on the Mac
```

With `fill_max_runs = 2` and `--max-runs 1` on each, each machine runs one
fill run; with `--max-runs 2` on both, still two at once in all, wherever
they land. Give each machine its own token: the scheduler tells which runs
a worker still has by what its token's worker last said.

When a worker dies, its fill runs are queued again for the pool (below),
so the fill goes on on the other machine.

## One run over several workers

A pipeline with dista tasks can spread one run's cluster over several
workers of its pool (#268). `workers = N` (or `--workers N`) on a pipeline
placed `worker:<pool>` lets each run use up to N more machines than the one
that starts it; without it, a run stays on one machine, as before. This is
what `Pipeline[workers=]` means on a pool. A local run forks `MORCA_WORKERS`
dista workers (default 4) and ignores the pipeline's `workers`; `workers`
applies on EC2 (worker instances), on Kubernetes (dista workers) and on a
pool (extra machines).

```toml
[pipelines.fanout]
placement = "worker:lab"
workers = 2      # up to 2 more machines join each run
```

- **The worker that claims the run** starts it as a cluster of its own: a
  dista head on a free port, a dista worker, and the run's driver joining
  them. It reports the head's address, the one it was started with
  `--advertise <address>` (or `MORCA_WORKER_ADVERTISE`), to the UI.
- **Another worker of the pool** with room and nothing to start is given
  the run to join: it starts a dista worker against that head, sized as a
  run of the pipeline would be on its machine and counted against its room
  as one. dista uses a worker that joins a running job at once.
- **A cluster token.** morca makes one for each run start and gives it, as
  `DISTA_TOKEN`, to the run's head, its driver and every member, the
  members over the worker API's TLS. dista refuses any connection without
  it (dista#124), so nothing else on the network joins the run, submits to
  it or fetches its results. It authenticates, it doesn't encrypt: keep the
  pool's machines on a private network.
- **When the run ends,** each member is told to stop on its worker's next
  claim, and a member's dista worker gives up on a head that's gone within
  10 s anyway. `orca.run_members` keeps who joined each run start, with its
  grant, and when and why it ended.

A worker without `--advertise` neither starts a run as a cluster nor joins
one: such a run runs on its machine alone.

**On a pool morca grows** (`[pools.<name>]`), this is set up for you:
- every Hetzner machine joins a private network of the stack's, and its
  worker advertises its address there, read from the provider's metadata
  (EC2: its private address);
- its worker runs with host networking, so dista's ports are on that
  address;
- a running run that wants more members than have joined counts as the
  pool's demand, so the pool grows for it (up to `max_machines`), and the
  new machine joins the run;
- a machine running only a member is busy, not idle.

## Tokens

On the server:

```sh
morca worker-token create --pool bgent --label bgent   # prints the token, once
morca worker-token list                                # id, pool, label, state, worker, last seen
morca worker-token revoke 3
```

A worker token is an API token, `orca_` and 64 hex digits, like `morca
login`'s. The server keeps only its SHA-256, in `orca.workers`. It is scoped
to one pool. It can claim that pool's runs and make the state calls of the
runs it claimed. It can do nothing else, and a user's token gets nothing
from the worker API. It lasts `--days`, by default and at most
`MORCA_WORKER_TOKEN_DAYS` (365). A revoked token stays listed as revoked, and
the worker using it is refused and exits. Each claim is a row of
`orca.audit`, user `worker:<label>`, source `worker`.

## Running a worker

```sh
MORCA_WORKER_TOKEN=orca_... MORCA_IMAGE=ghcr.io/morca-dev/census:0.11.0 \
MORCA_WAREHOUSE=s3://... MORCA_LOGS=s3://... MORCA_SECRET_FETCH=/etc/orca/fetch-secret \
  morca worker --pool bgent --remote https://orca.mlake.dev
```

| Flag | Default | |
|---|---|---|
| `--pool` | (required) | the pool, which must be the token's |
| `--remote` | `MORCA_REMOTE` | the UI; `https`, or `http` to this machine only |
| `--token-file` | `MORCA_WORKER_TOKEN` | the token, the file's first line |
| `--max-runs` | 1 | runs at once on this worker |
| `--poll-seconds` | 2 | how often it asks for a run, and beats |
| `--dir` | `$TMPDIR/morca-worker` | where a run's output is staged |
| `--image` | `MORCA_IMAGE` | the worker's version (below) |
| `--name` | the host name | how Ops and the run's page name it |

A worker with `MORCA_DATABASE_URL` set refuses to start.

A run it is given starts the way the local runner starts one. The pipeline's
binary runs at the path it was registered with, which the worker's image
must have too, as `<binary> resume <run>`, in a process group of its own.
It gets the pipeline's `env`, its secrets read on the worker with the
worker's own `MORCA_SECRET_FETCH` (the spec names them, never their values),
and `MORCA_STATE_URL` and `MORCA_STATE_TOKEN` in place of a database. Data and
logs go straight from the worker to `MORCA_WAREHOUSE` and `MORCA_LOGS`, as
any run's do. When the process ends, `<binary> keep-log` appends its output,
masked, to the run's `driver.log`.

A pipeline with a request (`cpus`, `memory_gb`: [morca.toml](morca-toml.md#requests-and-grants))
is admitted against the worker's own host, as the scheduler admits a local
run: each claim says what the worker can grant (its CPUs and memory, the
cgroup's limits if set, less `MORCA_RESERVE_CPUS`, 0, and
`MORCA_RESERVE_MEMORY_MB`, 512, of the worker's environment), and the UI
gives it a run only if the run's minimum fits less what the worker's
running runs were granted. The run gets its grant in `MORCA_GRANT_CPUS` and
`MORCA_GRANT_MEMORY_MB`, recorded on the run. One that doesn't fit stays
queued, held saying which worker had no room, for another worker of the
pool. A worker from before requests says nothing of its room, and its runs
are started as before.

Its runs yield the CPU to the worker and the rest of its host as the
scheduler's do ([hetzner.md](hetzner.md#a-cgroup-per-run)): a run's cgroup
has `cpu.weight` `MORCA_RUN_CPU_WEIGHT` (20) and, with a CPU grant,
`cpu.max`; without one the run starts at `nice` `MORCA_RUN_NICE` (10).

A worker also reads its own host's [memory pressure](morca-toml.md#memory-pressure)
each poll (the same files, in the same order, and the same
`MORCA_ADMIT_MEMORY_PRESSURE` of its own environment) and claims nothing while
`some avg10` is over the limit; the runs it has go on. It sends the reading
with its heartbeat, so its pool's queued runs say `waiting: memory pressure
23% (limit 10%) on worker <name>`, and `/api/workers` (`memory_pressure`)
show it. A hold that lasts `MORCA_ADMIT_PRESSURE_GRACE_SECONDS` (600) with
none of its runs going lets it claim one at a time, and raises the
`memory-pressure` alert once. Its runs get `MORCA_MEMORY_PRESSURE_FILE` too.

## A worker on another machine

The simplest worker is the server's own image in Docker, at the same tag,
so the pipeline binaries are at the paths they were registered with
(`/opt/morca/pipelines/<name>` in a project image).

On the server, once, a token for the pool:

```sh
morca worker-token create --pool bgent --label bgent
```

On the worker, `worker.env` (mode 600) holds the token, the bucket and
where secrets come from:

```sh
MORCA_WORKER_TOKEN=orca_...
MORCA_WAREHOUSE=s3://<bucket>/warehouse
MORCA_LOGS=s3://<bucket>/logs
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=<location>
AWS_ENDPOINT_URL_S3=https://<location>.your-objectstorage.com   # S3-compatible storage only
MORCA_SECRET_FETCH=sh /etc/orca/secret-fetch
```

Then:

```sh
docker run -d --name orca-worker --restart always --env-file worker.env \
    -v "$PWD/secrets:/etc/orca/secrets:ro" -v "$PWD/secret-fetch:/etc/orca/secret-fetch:ro" \
    ghcr.io/<owner>/<image>:<tag> worker --pool bgent --remote https://morca.example.com
```

- `secret-fetch` can be a copy of the server's
  ([`deploy/hetzner/server/secret-fetch`](../deploy/hetzner/server/secret-fetch)):
  it prints `/etc/orca/secrets/<id>`, so a pipeline's
  `GITHUB_TOKEN = "orca/github-token"` reads `secrets/orca/github-token`.
- Pass `--image` (or `MORCA_IMAGE`) only if the pipelines were registered
  with `--image`, and then the same value: [Versions](#failures).
- The worker needs only outbound HTTPS, to the UI and to the bucket.
- `docker logs orca-worker` shows each run it starts and how it exited;
  Ops > Pools shows its heartbeat.

**Deploying.** The worker runs the code of its own image, so keep it on
the server's tag: deploy the server first (`deploy.sh <tag>`), then
restart the worker on the same tag (`docker rm -f orca-worker`, then the
`docker run` above with the new tag). In between, a worker on the old tag
runs the old code, unless the pipelines are registered with `--image`: then
it is given nothing until it matches.

## The run's state over HTTPS

A pipeline binary with `MORCA_STATE_URL` records its run through
`morca._internal.http_store.HttpStore`, the HTTP implementation of the `RunStore`
trait that `PgStore` and `SqliteStore` implement. Each call is a `POST
/api/worker/store/<call>` of JSON. The UI makes the same call on `PgStore`,
so every check is the same code as for a run that writes to Postgres
itself: the run is still this process's, it isn't cancelled, and its
heartbeat is fresh enough to commit. The calls are `run_info`, `claim`,
`version`, `ran_version`, `interrupt`, `prior`, `steps`, `start_attempt`,
`finish_attempt`, `skip`, `pinned_reads`, `record` (reads and commits, so
lineage and `find_commit`'s retry guard work as before), `fence`,
`set_log`, `finish_run`, `defer_run`, `cancel_requested` and `beat`.
Encoded inputs and outputs travel as hex.

A call that can't reach the UI, or gets a 5xx, is retried for
`MORCA_DB_RETRY_SECONDS`, as Postgres is. A call that is refused (401, 403,
or 409 for a lost or cancelled run) is final, and the run stops. A fence
that can't be made within half the stale limit refuses the commit.

## Failures

- **A dead worker.** Each run's heartbeat thread beats over the API. It
  also exits its process once the worker that started it (`MORCA_WORKER_PID`)
  isn't its parent any more. So when a worker is killed, or its machine
  goes to sleep, the run's heartbeat goes stale. A run whose worker is
  gone is queued again for the pool, whatever its trigger (a manual, UI or
  rerun run too, which on other runners fails `interrupted`): one whose
  heartbeat is stale and whose worker hasn't been seen for half the stale
  limit (`MORCA_STALE_SECONDS`), or has been seen since without it (a
  restarted worker). Its next start resumes it after its last step done.
  A run a worker claimed and never started has its start given back. Each
  is a row of `orca.audit` (user `scheduler`, action
  `/api/worker/requeue`, saying why) and a line of the scheduler's log.
  A run that started counts that start, and past `run_retries` it fails as
  on any runner, so a run that takes its worker down can't loop. A run
  whose process stopped while its worker goes on is the dead-run rule
  every runner has: queued again within `run_retries` if the scheduler
  retries its trigger, else failed `interrupted: its process stopped`,
  resumable from the UI. A machine that wakes up finds its run lost at
  its next call, and a commit is fenced.
- **A process that never claimed its run** (a missing binary, a `resume`
  that refused) has the run failed, saying why (`/api/worker/exited`).
- **What a run uses.** The worker samples each run's process tree every
  poll, as the scheduler does a local run's, and sends the samples with
  `/api/worker/exited`; the UI records each attempt's peak memory and CPU
  from them ([the UI](ui.md#what-a-run-uses)). Beside each run's process
  it also starts `<binary> sample`, as the scheduler does beside a local
  run, which writes the machine's metrics to
  `<MORCA_LOGS>/<pipeline>/<run>/metrics/worker-<name>.jsonl`, so the run's
  page has its Machines card (`MORCA_SAMPLE_SECONDS=0` in the worker's
  environment turns it off).
- **Versions.** A run needs its pipeline's image (`morca register
  --image`; `morca config show <pipeline>` prints it) to be the worker's
  (`--image`, `MORCA_IMAGE`), both empty included, so there's no silent
  drift. A worker of another image isn't
  given the run, and the run stays queued, held saying why. The worker
  checks the spec again and puts back a run that isn't for it
  (`/api/worker/release`). Pin the same tag in `deploy.sh` and the worker's
  script.

## In the UI

Ops > Pools (`/ops/pools?kind=self-hosted`, and `/api/pools` as JSON; see
[ui.md](ui.md#pools)) has a row per worker token, the machine its worker
runs on, in pool `worker:<pool>`: its name, state (`live`, or `gone` when
the token is revoked or expired or the worker hasn't been heard from for
`MORCA_STALE_SECONDS`), image, CPUs, memory, current runs and last
heartbeat, and the worker's token and label. Its page lists the runs it
claimed, and draws the machine's samples over its latest run (the
sampler the worker starts beside each run). `/api/workers` is still each token as JSON, and `/ops/workers`
redirects to Pools. A run's page says where it ran: the worker's name, and
the token's id and label.

## Network

Outbound HTTPS only, through the server's existing Cloudflare Tunnel. No
firewall change is needed, and Postgres stays reachable only on the
server.

### A listener of its own

By default `morca ui` answers the worker API (`/api/worker/...`) on the same
port as its pages, so a page that is slow to render (a large pipeline's
Overview, Control's charts) can hold up a worker's claims and heartbeats,
and its runs' store calls, behind it. Set `MORCA_WORKER_ADDR` (`host:port`)
and `morca ui` also serves the worker API on that address, from a thread of
its own:

```sh
MORCA_UI_ADDR=127.0.0.1:8270 MORCA_WORKER_ADDR=127.0.0.1:8271 morca ui
```

Point `morca worker --remote` at it (through the tunnel, a hostname of its
own for that port); the runs it starts record themselves there too. That
address answers only the worker API: anything else is 404. The UI's own
port keeps answering the worker API as well, so workers can move over one
at a time. Unset, nothing changes.
