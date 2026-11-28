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

## A pool's settings

A `[pools.<name>]` table in morca.toml declares a pool. With a `provider`,
morca makes and removes its machines ([morca.toml](morca-toml.md#worker-pools));
without one it is self-hosted: its machines join by hand, each with its own
token and `morca worker` (below), and morca gives their workers the pool's
settings:

```toml
[pools.bgent]
max_runs = 3                                       # runs at once on each worker
env = { MOJO_HISTORY_WORKDIR = "/work/clones" }
secrets = { GITHUB_TOKEN = "orca/github-token" }   # IDs, read on the worker
volumes = ["census-work:/work"]                    # a container's mounts
```

| Key | | |
|---|---|---|
| `max_runs` | 1 to 1000 | Runs at once on each worker of the pool. The UI never gives a worker more; a worker started without `--max-runs` takes it as its own. Unset: each worker's `--max-runs` (1). |
| `env` | table of names | Variables every run on the pool's workers gets, under the pipeline's own: a pipeline's `env` of the same name wins. A name that looks like a secret's (`TOKEN`, `PASSWORD`, ...) is refused. |
| `secrets` | table of names to IDs | Secrets every run gets, read on the worker with its own `MORCA_SECRET_FETCH`, as a pipeline's are: morca.toml, the database and the claim hold only the IDs. |
| `volumes` | list of `source:target[:ro\|:rw]` | The mounts of a worker that `morca host join --container` starts (below): a Docker volume's name or an absolute path, then an absolute path in the container. At most 32, no two on one target, and no space, quote, `:`, `,` or `$` in a path. A worker run as a service, not in a container, has none. |

`morca register` with the file records every pool in `orca.pool_settings`
(and those with a provider in `orca.pools` too); a pool the file no longer
has loses its settings. They travel in each claim's answer, over the
worker API's TLS: the run's spec has the pool's `env` and secret IDs merged
under the pipeline's, and the answer has the pool's `max_runs`. A worker
from before this gets the variables (they are in the spec) but keeps its
own `--max-runs`, which the UI caps at the pool's. The volumes go to
`morca host join`, which asks `/api/worker/join` for them.

## Joining a machine: morca host join

On the machine, once, with a token from the server in a file only its
owner can read:

```sh
# On the server:
morca worker-token create --pool bgent --label bgent      # prints the token
# On the machine, the token alone in /etc/morca/token (chmod 600), and the
# bucket's keys in /etc/morca/bucket.env (chmod 600, NAME=value lines):
sudo morca host join https://morca.example.com --pool bgent \
    --token-file /etc/morca/token --env-file /etc/morca/bucket.env
```

It asks the UI's `/api/worker/join` with the token, which checks it is a
live token of the pool and answers the pool's volumes and `max_runs` and
the server's worker image (`MORCA_WORKER_IMAGE`), then installs and starts
one of:

| | Installs | Restarts |
|---|---|---|
| systemd (Linux, the default there) | `/etc/systemd/system/morca-worker-<pool>.service`, running this `morca worker` | always, but not after exit 3 (its token refused: `morca host remove`) |
| launchd (macOS, the default there) | `/Library/LaunchDaemons/dev.morca.worker.<pool>.plist`, its log in `/var/log/morca-worker-<pool>.log` | `KeepAlive`, at most every 30 s |
| `--container` | `/etc/morca/worker-<pool>-container.sh`, which runs `docker run --rm` of the image `host-<pool>.json` names (`--image`, else the server's) with the token file mounted read-only, the env files given and the pool's volumes mounted, and moves it to the server's image after a deploy ([below](#following-the-servers-image)); the systemd unit or launchd job above runs the script (`--service` picks which) | the script starts the container again; its service restarts the script, but not after exit 3 |

Beside it, `/etc/morca/worker-<pool>.env` (mode 600) has the worker's own
settings: `MORCA_REMOTE` and each `--set NAME=value` (`MORCA_RESERVE_CPUS=2`,
say; a name that looks like a secret's is refused). `/etc/morca/host-<pool>.json`
(mode 600) records what was installed.

**No secret leaves its file.** The token stays in the file named with
`--token-file`, and the bucket's keys and the like in the `--env-file`s,
which the service reads in place (`morca worker --env-file`); both must be
mode 600, or the join is refused. Nothing it writes or prints holds one.
The join is a row of `orca.audit` (user `worker:<label>`, action
`/api/worker/join`).

| Flag | Default | |
|---|---|---|
| `<url>` | `MORCA_REMOTE` | the UI |
| `--pool` | (required) | the token's pool |
| `--token-file` | (required) | the token, on its first line; mode 600 |
| `--name` | the host name | how Ops names it |
| `--service` | systemd on Linux, launchd on macOS | |
| `--container` | | Docker, its script run by the service |
| `--image` | the server's `MORCA_WORKER_IMAGE` | the container's image |
| `--env-file` | none | the user's env files, read in place; mode 600 (repeat it) |
| `--set NAME=value` | none | written to its own env file (repeat it) |
| `--advertise` | none | its address for runs spread over the pool ([below](#one-run-over-several-workers)); a container gets host networking |
| `--dir` | `/var/lib/morca/<pool>/stage` | where runs' output is staged |
| `--user` | root | the user the service runs as, who must own the token and env files |
| `--binary` | this `morca` | the `morca` a service runs |
| `--root <dir>` | `/` | write every file under `<dir>`, with the paths in them too, and start nothing |
| `--dry-run` | | print the files and what it would run, and write nothing |

Run it again to change any of it: the files are written again and the
service restarted. `morca host join --uninstall --pool bgent` stops the
service (or removes the container) and deletes what `host-<pool>.json`
lists. The token stays live on the server until `morca host remove`.

### Following the server's image

Each claim's answer has the server's worker image (`worker_image`, its
`MORCA_WORKER_IMAGE`), and the worker says what it makes of it
(`morca._internal.host_follow`):

- **In a container** (its worker runs with `--host-image <image>`): when
  the server's image isn't the one it runs, it **drains itself**: it claims
  nothing new and finishes the runs it has (a deploy never stops a run).
  Once idle it writes the image to `.host-upgrade` in its stage directory
  and exits 4. The script then `docker pull`s that image, writes it into
  `host-<pool>.json` and starts the container on it.
- **If the pull fails** (the registry wants a login the machine hasn't:
  `docker login` there, which keeps it as docker always does; morca writes
  no credential anywhere), or the new container exits within 60 s (an image
  whose morca doesn't know `--host-image`, say), the script writes why to
  `.host-upgrade-failed` and starts the old image again. Its worker logs
  why, claims runs again, and doesn't try that image again until `morca
  host upgrade` asks it to or the server's image moves on. A worker started
  again on its old image with `.host-upgrade` still there (nothing
  replaced it) counts that as a failure too, so a host never drains in a
  loop.
- **As a service** (systemd or launchd, `--host-service`): a binary can't
  swap itself. When the server's image isn't its own (`MORCA_IMAGE`, none
  for a plain binary) it logs that once, reports `needs-upgrade`, and keeps
  claiming runs; install the server's version and restart the service by
  hand.

A worker of a version before this, or a UI with no `MORCA_WORKER_IMAGE`
(or of a version before this), changes nothing: the host keeps its image
and claims runs. A worker the pool autoscaler made doesn't follow either:
the autoscaler replaces it ([Deploying](#a-worker-on-another-machine)).

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
one: such a run runs on its machine alone. A run of a pipeline with
[groups](#members-by-group) isn't given to such a worker at all: it stays
queued, held "its worker groups need a worker that runs it over the pool,
started with --advertise", for one that has an address.

### Members by group

A pipeline may declare [worker groups](morca-toml.md#worker-groups), each
with its own `workers`, size and GPUs ([groups.md](groups.md)). On a pool,
a run of it spreads over the pool's workers as a cluster even when its own
`workers` is unset, and wants members of each group beside those with no
group:

- **A member of a group** is a worker of the pool that joins the run with
  a dista worker started with `DISTA_GROUP=<group>`, so dista's head sends
  it that group's tasks (`Task[..., group="gpu"]`) and no others. It is
  sized by the group's `cpus` and `memory_gb` (the pipeline's where it
  sets none), granted the group's `gpus` whole from those its host has
  free (`MORCA_GRANT_GPUS` and `CUDA_VISIBLE_DEVICES` on its process), and
  recorded in `orca.run_members` with its group (`worker_group`, migration
  72). The worker that started the run, with the head, the driver and its
  own dista worker, has no group, as before.
- **How many.** The workers with no group want the pipeline's `workers`,
  as before. Each group wants its MAX (`workers = "0..2"` wants 2), until
  morca asks dista how many each group needs
  ([groups.md](groups.md#demand-per-group)); a pool that grows counts the
  missing members of the groups that ask for no GPU as its demand, as it
  does those with no group.
- **Which host.** An idle worker is offered, of the oldest running run
  first, a member it can serve: one its room fits, with a free GPU if the
  group asks one. A host with GPUs is offered the members that ask for
  GPUs first. It joins as one that asks for none only when its run wants
  no member of a group the host could serve, and no other live worker of
  the pool on a host without GPUs (one that has an address, a free slot
  and room for it) could take it, so a member that needs no GPU doesn't
  take the place a model needs. A machine is one member of a run at most.
- **Older workers.** A worker's claim says it understands groups; one
  from before them is offered only members with no group, as before.
- **The run's page** lists each member's group and the GPUs it was
  granted in its Cluster card.

Only pools use groups for now: a local run, `control`, Kubernetes and the
`ec2` placement start their workers as before, with no group.

**On a pool morca grows** (`[pools.<name>]`), this is set up for you:
- every Hetzner machine joins a private network of the stack's, and its
  worker advertises its address there, read from the provider's metadata
  (EC2: its private address);
- its worker runs with host networking, so dista's ports are on that
  address;
- a running run that wants more members than have joined counts as the
  pool's demand, so the pool grows for it (up to `max_machines`), and the
  new machine joins the run (a group's that asks for GPUs doesn't count
  yet: a pool has no machine type with GPUs until `gpu_machines`,
  [groups.md](groups.md#demand-per-group));
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

## Hosts: list, drain, remove

On the server, a host is a worker token's machine, whether it joined by
hand or the pool autoscaler made it:

```sh
morca host list [--pool bgent]   # id, pool, name, state, image, server_image, upgrade, CPUs, memory, runs, last seen
morca host drain 3               # finishes its runs, claims no more
morca host undrain 3             # claims again
morca host remove 3 [--force]    # revokes its token: its worker exits
morca host upgrade 3             # a --container host moves to the server's image now
```

- **Drain** (maintenance, a laptop going to sleep, before a restart): the
  worker is given no new runs, finishes the ones it has, and keeps beating,
  so its runs aren't taken for lost. Its log says it drains, and Ops >
  Pools and `/api/workers` (`draining`) show it. A machine the autoscaler
  made is removed once it's idle. `undrain` lets it claim again.
- **Remove** revokes the host's token: its worker is refused at its next
  claim and exits (code 3). A host with runs running is refused, saying to
  drain it first; with `--force` its runs are queued again for the pool as
  any lost worker's are.
- **Upgrade** asks a host `morca host join --container` installed to move
  to the server's image at its next claim, also one it failed to move to
  before ([Following the server's image](#following-the-servers-image)): it
  drains and is replaced once idle, as after a deploy. A service, or a
  worker that reports no image of its own, is refused, saying why.
- Each is a row of `orca.audit` (`host drain`, `host undrain`, `host
  remove`, `host upgrade`, source `local`), as `morca worker-token` writes.

The same from anywhere, as a user of a deployed UI (`morca login` first,
as for the other `--remote` commands):

```sh
morca --remote orca.example.com host list --pool bgent
morca --remote orca.example.com host drain 3
morca --remote orca.example.com host remove 3 --force
```

`list` reads `/api/workers`, which needs no login (a host is `not seen`
after this machine's `MORCA_STALE_SECONDS`). The others post to `POST
/api/hosts/<id>/drain`, `/undrain` and `/remove` (`{"force": "1"}`) with
the login's token, and are audited as the user's from `cli`. Ops > Pools
has them as buttons (below).

The `state` is `live`, `draining`, `not seen` (silent for
`MORCA_STALE_SECONDS`), `revoked` or `expired`. `image` is the image its
container runs, else the worker's `MORCA_IMAGE`; `server_image` the
server's worker image as the host last heard it (else this shell's
`MORCA_WORKER_IMAGE`); `upgrade` what the host says of it: `current`,
`draining` (to move), `failed` (it runs the old image and claims runs), or
`needs-upgrade` (a service); `-` for a worker that doesn't say. `/api/workers`
has them as `host_image` and `host_upgrade` (`orca.workers`, migration 69).

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
| `--max-runs` | its pool's `max_runs`, else 1 | runs at once on this worker, at most its pool's `max_runs` |
| `--poll-seconds` | 2 | how often it asks for a run, and beats |
| `--dir` | `$TMPDIR/morca-worker` | where a run's output is staged |
| `--image` | `MORCA_IMAGE` | the worker's version (below) |
| `--name` | the host name | how Ops and the run's page name it |
| `--env-file` | none | `NAME=value` lines (as Docker's `--env-file`), read first; a variable already set wins (repeat it) |
| `--host-image` | none | the image its container runs: it follows the server's ([`morca host join --container`](#following-the-servers-image) passes it) |
| `--host-service` | none | `systemd` or `launchd`: it reports when the server's image moves on (`morca host join` passes it) |

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
`MORCA_RESERVE_MEMORY_MB`, 512, of the worker's environment, and its
[GPUs](morca-toml.md#requests-and-grants), counted once at start), and the UI
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
the server's tag. A machine the pool autoscaler made is drained and
replaced once idle, and one joined with `morca host join --container`
follows by itself: after `deploy.sh <tag>` it finishes its runs, then its
script starts it on the server's new image
([Following the server's image](#following-the-servers-image)); `morca host
list` shows where each host is. A worker started by hand, as above, is
restarted by hand: `docker rm -f orca-worker`, then the `docker run` with
the new tag (or join it with `morca host join --container` instead). In
between, a worker on the old tag runs the old code, unless the pipelines
are registered with `--image`: then it is given nothing until it matches.

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
`MORCA_STALE_SECONDS`, `not seen` beside it then), image (with the server's
tag beside it, `MORCA_WORKER_IMAGE`, when both are known), CPUs, memory,
current runs and last heartbeat, and the worker's token and label. A host
asked to drain (`morca host drain`) is `draining`.

A host whose token is still good has **Drain** (**Undrain** while it
drains) and **Remove** beside its state, on its row and its page. They do
what `morca host` does, audited the same way as the logged-in user's from
`ui`. While login is on, a visitor sees "Log in to ..." in their place,
and a POST without a session is refused. Remove asks first, and while the
host has runs running the server refuses it with a page that confirms it
("Remove it anyway"), which queues them again. Its page lists the runs it
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
