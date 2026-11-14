# morca.toml

`morca.toml` sits at the root of a project's repository and says how each
pipeline runs. The pipeline's code still says what it does (steps, partitions,
schedule, reads and writes); the file says where it runs and how much it uses.
`morca register` and `morca aws register` read it. The code that reads it is in
`src/morca/_internal/config.mojo`, and the TOML parser is in `src/morca/_internal/toml.mojo`.

```toml
[defaults]
placement = "ec2"
head_type = "t4g.medium"

[pipelines.gharchive]
worker_type = "c7g.xlarge"
workers = "0..4"
worker_procs = 1
max_runs = 2
env = { DISTA_WORKER_SLOTS = "4", GHARCHIVE_PARALLEL = "16" }
fills = "all"                # fill 2023-01-01 to yesterday by itself
fill_order = "oldest"
fill_max_runs = 2
fill_budget_per_day = 5.0    # estimated US dollars a UTC day
fill_window = "22..6"        # UTC hours fill runs start in
fill_lag = "2h"              # a day fills 2 hours after it ends

[pipelines.mojo_live]
priority = 10                # starts before gharchive when room is short

[pipelines.mojo_repos]
placement = "control"
secrets = { GITHUB_TOKEN = "orca/github-token" }
cpus = "1..2"                # a request: started once 1 CPU and
memory_gb = "0.5..2"         # 0.5 GB fit on the host, given up to 2 and 2

[stack]
hostname = "orca.mlake.dev"
```

## Tables

| Table | What it is |
|---|---|
| `[defaults]` | Values for every pipeline the file names. It doesn't apply to pipelines the file leaves out. |
| `[pipelines.<name>]` | One pipeline's own values, by the name its `describe` gives. An empty table is allowed: the pipeline is then "in the file" and gets `[defaults]`. |
| `[pools.<name>]` | A pool of workers morca grows and shrinks itself: [Worker pools](#worker-pools). |
| `[apps.<name>]` | An app beside the UI and what it gets: [Apps](#apps). |
| `[datasets."<name>"]` | A dataset's settings: whether visitors see its data. [Datasets](#datasets). |
| `[stack]` | Reserved for `morca aws up`, which doesn't read it yet. It is accepted and not checked. |

Any other table, and any key at the top level, is refused.

## Keys

Each key can go in `[defaults]` or in `[pipelines.<name>]`.

| Key | Type | Default when absent | Replaces the flag | Notes |
|---|---|---|---|---|
| `placement` | string: `"control"`, `"ec2"`, `"worker:<pool>"` or `"default"` | `default`, the scheduler's runner (`MORCA_RUNNER`) | `--placement` | `control` runs on the scheduler's host (`morca._internal.control`). `worker:<pool>` runs on a remote worker of that pool (`morca worker`), never the scheduler: [workers.md](workers.md). All four: [placement.md](placement.md). |
| `head_type` | string, an instance type | `MORCA_EC2_HEAD_TYPE`, else `c7g.large` | `--head-type` | Only used on EC2. |
| `worker_type` | string, an instance type | `MORCA_EC2_WORKER_TYPE`, else `c7g.xlarge` | `--worker-type` | Only used on EC2. |
| `workers` | integer `N` (at least 1), or string `"MIN..MAX"` | the code's `workers`, else 2; 0 for a pipeline without tasks | `--workers` | With `MIN..MAX`, the run scales between the two. |
| `worker_procs` | integer from 1 to 256, or `"auto"` | 1 | `--worker-procs` | `auto` means one dista process per vCPU. |
| `max_runs` | integer from 1 to 10000, or string `"auto"` or `"auto..N"` | the code's `Pipeline[..., max_runs=]`, else 1 | `--max-runs` (new) | Overrides the code's value. `auto`: [How many at once](#how-many-at-once). |
| `cpus` | integer `N` from 1 to 1024, or string `"MIN..MAX"`, `"auto"` or `"auto..MAX"` | none: no request | `--cpus` | Whole CPUs the run asks for. See [Requests and grants](#requests-and-grants); `auto`: [Learned requests](#learned-requests). |
| `memory_gb` | number `N` (decimals allowed), or string `"MIN..MAX"`, `"auto"` or `"auto..MAX"`, over 0 and up to 65536 | none: no request | `--memory-gb` | GB of memory the run asks for. |
| `learn` | boolean | `true` | none | `false`: `auto` asks for nothing instead of what its runs suggest. See [Learned requests](#learned-requests). |
| `secrets` | table of `NAME = "orca/<id>"` | none | `--secret NAME=ID` | Secrets Manager IDs only, never values. A `--secret` flag replaces the whole set. |
| `env` | table of `NAME = "value"` (numbers and booleans become text) | none | none (it replaces `MORCA_RUN_ENV` for pipeline settings) | See [env](#env-morca_run_env-and-the-warm-pool) below. |
| `fills` | string: `"all"` or `"since_registration"` | `since_registration` | none | `all`: the scheduler fills the pipeline's whole range by itself. See [Fills](#fills). |
| `fill_order` | string: `"oldest"` or `"newest"` | `oldest` | none | Which end of the range fills first. |
| `fill_max_runs` | integer from 1 to 10000, or string `"auto"` or `"auto..N"` | 1 | none | Fill runs at once, on top of `max_runs`. `auto`: as many as the host has room for, up to 64 (or N), as [`max_runs = "auto"`](#how-many-at-once) does. |
| `keys_per_run` | integer from 1 to 10000 | the code's `Pipeline[..., keys_per_run=]`, else 1 | none | Keys a run takes: a backfill's runs, a sensor's runs above 1, and fill runs. See [Keys per run](#keys-per-run). |
| `fill_budget_per_day` | number from 0 to 100000, US dollars | none | none | Estimated spend of fill runs a UTC day. Fill runs on EC2 or Kubernetes don't start without it. |
| `fill_window` | string `"A..B"`, UTC hours: A from 0 to 23, B from 1 to 24 | `"0..24"`, all day | none | Fill runs start from hour A up to hour B. `"22..6"` wraps past midnight. |
| `priority` | integer from -1000 to 1000 | 0 | none | Higher starts first when room is short. See [Priority](#priority). |
| `enabled` | boolean | `true` | none | `false`: `morca register` without binaries skips the pipeline (it prints `skipping <name>`); one already registered stays as it is. For a pipeline only some stacks run, turned on by [a stack's overlay](#a-stacks-overlay). |
| `fill_lag` | string, a duration: a whole number of `s`, `m`, `h` or `d`, up to `31d`; or `0` | `0`, none | none | How long after its end a partition is filled. See [The lag](#the-lag). |

`image` (`--image`) and `--spot` stay flags only. The `fill*` keys,
`learn`, `priority` and `enabled` are the file's only: no flag sets them.

### What is refused

- Unknown keys, such as `workrs`.
- A value of the wrong type.
- A `workers` range like `4..2`.
- A `cpus` or `memory_gb` range like `"4..2"`, `cpus = 0`, `cpus = 1.5` or `memory_gb = 0`; `auto` anywhere but alone or as a range's lower end (`"2..auto"`), or `"auto.."` without its maximum.
- A secret ID outside `orca/`.
- A `fill_window` like `"6..6"` or `"1..30"`, a negative `fill_budget_per_day`, or `fill_max_runs = 0`.
- A `priority` that isn't an integer (`"high"`, `1.5`), or is outside -1000..1000.
- A `fill_lag` without a unit (`"2"`, `2`), with one morca doesn't know (`"2w"`), or over `31d`.
- `fills = "all"` for a keyed pipeline, a sensor, or one with no first partition. `morca register` refuses it with the file and line, because it has to see the pipeline first; see [Fills](#fills).
- An `env` name that isn't a valid variable name.
- An `env` name that looks like a secret (`*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*DATABASE_URL*`). Put those in `secrets` instead.
- An `env` variable that morca sets itself: `MORCA_DATABASE_URL`, `MORCA_IMAGE`, `MORCA_SECRETS`, `MORCA_WORKERS`, `DISTA_ROLE`, `DISTA_HEAD`, `DISTA_ADVERTISE`, `MORCA_GRANT_CPUS`, `MORCA_GRANT_MEMORY_MB`, `MORCA_MEMORY_PRESSURE_FILE`.

Each refusal names the file and line, and nothing is registered:

```text
morca.toml:7: [pipelines.gharchive] has no key workrs (it has placement, head_type, worker_type, workers, worker_procs, max_runs, keys_per_run, cpus, memory_gb, learn, fills, fill_order, fill_max_runs, fill_budget_per_day, fill_window, fill_lag, priority, enabled, secrets and env)
morca.toml:3: [pipelines.toy] workers: not a count or a range MIN..MAX: 4..2
```

### TOML that morca reads

morca reads this part of TOML 1.0:
- comments
- headers, with dotted and quoted keys
- basic strings (with every escape) and literal strings
- decimal integers, floats and booleans
- arrays of these, over several lines, with a trailing comma allowed
- inline tables, nested

Defining a key or table twice is refused, as TOML refuses it. These are left out, and each is refused with a message that says so: `[[arrays of tables]]`, multi-line strings, dates and times, hexadecimal, octal and binary integers, `inf`, `nan`.

## Precedence

Each value comes from the first of these that sets it, highest first:

1. **flag**: a flag given to `morca register`. It is recorded as an override.
2. **morca.toml `[pipelines.<name>]`**
3. **morca.toml `[defaults]`**
4. **environment**: what the runner uses when nothing is registered. For instance types that is `MORCA_EC2_HEAD_TYPE` and `MORCA_EC2_WORKER_TYPE`; for `env`, the variables named in `MORCA_RUN_ENV`.
5. **code default**: what the pipeline declares (`max_runs`, `workers`), else morca's built-in value.

`env` and `secrets` are merged one name at a time: a pipeline's `env.X` beats `[defaults]`'s `env.X`, and other names from `[defaults]` are kept.

**A pipeline the file names** is registered with exactly what the file and the flags say:
- A key you remove from the file goes back to its default at the next registration.
- A flag applies to that registration only. The next `morca register` without the flag goes back to the file's value.

**A pipeline the file doesn't name** keeps the behaviour from before morca.toml: a flag left out keeps what was registered. `morca register` prints a warning that the pipeline isn't in the file.

### Which file is read

| How | File |
|---|---|
| `morca register --config F` | `F` |
| `MORCA_CONFIG=F` | `F` |
| neither | `./morca.toml`, if it exists |
| `--no-config` | none |

### A stack's overlay

A project ships one `morca.toml`. What differs between the stacks that run it
(a dev stack that never fills, a lab stack that runs one pipeline) is a fact
about each stack, kept with that stack's settings, not in the project: an
overlay, a small file in the same format laid on `morca.toml` before
anything reads it.

```toml
# ops/dev/morca.overlay.toml: the dev stack's
[pipelines.gharchive]
fills = "since_registration"     # never the backfill from 2023

[pipelines.mojo_history]
placement = "control"            # no worker pool here

[pipelines.ballast]
enabled = true                   # in morca.toml with enabled = false
```

| How | Overlay |
|---|---|
| `--overlay F` (`register`, `config check`, `config show --file`) | `F` |
| `MORCA_CONFIG_OVERLAY=F` | `F` |
| neither | none |

It is laid on whichever file is read ([above](#which-file-is-read)); `--no-config`
and `morca aws register` read none.

- **Merging.** A key in the overlay replaces the file's value at that path,
  whatever it was (a table or an array included). A table is merged key by
  key: what the overlay leaves out keeps the file's value. So `env = { A =
  "1" }` in an overlay changes `A` and keeps the file's other names, and
  `[defaults]` in an overlay doesn't beat a pipeline's own key in the file:
  set it in `[pipelines.<name>]`. An overlay can't remove a key; set it to
  its default (`fills = "since_registration"`, `placement = "default"`).
- **Pipelines.** An overlay can change the file's pipelines, not add one:
  a `[pipelines.<name>]` the file hasn't is refused, so a misspelt name
  fails instead of adding a pipeline. A pipeline only one stack runs is in
  `morca.toml` with `enabled = false` and enabled by that stack's overlay;
  `[defaults] enabled = false` and `enabled = true` on the one it wants turn
  off all the others.
- **Checking.** The result is checked as a file is: a bad value in the
  overlay is refused with the overlay's `file:line`. `morca config check
  --overlay F` checks the two together, and `morca config show --file
  --overlay F` prints the result, each value the overlay set marked
  `# overlay F:line`.
- **Recorded.** A registration records the overlay's path and SHA-256 beside
  the file's, and `morca config show` names it and gives each value it set
  as `morca.toml [pipelines.x], overlay F:line`.

On Hetzner, deploy.sh sends a stack's overlay and morca-stack checks it in
the image before a deploy changes anything: [hetzner.md](hetzner.md#a-stacks-overlay).

### Registering without paths

`morca register` with no pipeline binaries registers every `[pipelines.<name>]` the file names (but those with `enabled = false`), each as `<dir>/<name>`. `<dir>` is `MORCA_PIPELINES_DIR` if it is set, else the directory `pipelines/` next to the file if it exists; with neither, `morca register` refuses and says so. A table whose binary doesn't exist is an error naming it, and nothing is registered. Binaries given on the command line work as before (and a pipeline in the file that you leave out isn't touched).

A project's image sets `MORCA_CONFIG`, `MORCA_PIPELINES_DIR`, `MORCA_COMMIT` and `MORCA_SOURCE`, so `morca register` alone registers the whole file.

`morca aws register` takes the same `--config` and `--no-config`. It checks the file on your machine, then sends the file whole (base64) to the control instance's `morca register`, with its git commit. A bad file is refused before anything is sent.

### What a registration records

`orca.pipelines.config` (migration 29) holds:
- the file's name
- its SHA-256
- its git commit, and whether the file had uncommitted changes; for a file outside a git checkout (an image), the commit in `MORCA_COMMIT`, with `MORCA_SOURCE` as the commit's source, when they are set
- the flags that overrode it
- the source of every value

`orca.pipelines.env` and `orca.pipelines.max_runs` hold the pipeline's env and its `max_runs` override.

## env, MORCA_RUN_ENV and the warm pool

- **A pipeline's `env` goes only to its own runs**, on every runner:

  | Runner | How the env is passed |
  |---|---|
  | local | the run's process environment |
  | control | the run's process environment |
  | worker:&lt;pool&gt; | the run's process environment, on the worker |
  | Kubernetes | each pod's `env` |
  | EC2 | exported in each instance's script, and passed to its containers |

- **`MORCA_RUN_ENV` keeps working as a fallback for the whole stack.** The scheduler's variables named in it are copied to every run, as before. If a pipeline's `env` sets one of those names, the pipeline's value wins and the scheduler's isn't copied.
- **On EC2 the env is part of the warm pool's key** (#134). An instance from the pool is only handed to a run of the same pipeline started with the same env. Changing a value and registering again launches new instances, and the old ones shut down after `MORCA_EC2_POOL_SECONDS`. The env is also kept in the run's spec (`orca.runs.spec`), so workers started later in a live run get the env its start had.
- **Settings for the whole stack stay in `/etc/orca.env`**: the database URL, warehouse, logs, runner, `MORCA_VCPU_BUDGET` and so on. Pipeline settings, such as `DISTA_WORKER_SLOTS` for one pipeline, belong in morca.toml.

## Requests and grants

`cpus` and `memory_gb` are a pipeline's **request**: the least it needs to
start and the most it can use, `"MIN..MAX"` (a single number is both). Its
runs are then sized to their share of the machine (#171, `src/morca/_internal/resources.mojo`):

```toml
[pipelines.gharchive]
cpus = "1..16"
memory_gb = "2..24"
env = { DISTA_WORKER_SLOTS = "auto", GHARCHIVE_PARALLEL = "auto" }
```

- **Admission.** On the local runner (`MORCA_RUNNER=local`, as on the
  Hetzner server) and for control-placed runs, the scheduler starts a run
  only if its minimum fits what this host can grant less what the runs
  going there were granted. What it can grant is the host's CPUs and memory
  (the cgroup's limits if set, else `/proc/meminfo` and its cores; `sysctl`
  on macOS; `MORCA_HOST_CPUS` and `MORCA_HOST_MEMORY_MB` override them) less
  a reserve for the scheduler, Postgres and the UI: `MORCA_RESERVE_CPUS`
  (1) and `MORCA_RESERVE_MEMORY_MB` (1536). A run that doesn't fit stays
  queued, and its page, its pipeline's page (**Waiting**) and their JSON
  (`held`, `waiting`) say why: `waiting: needs 2 GB, 1.3 GB free of grants`,
  or `waiting: needs 30 GB, more than the 6.5 GB this host grants at most`,
  and so does `morca status`, under the pipeline's line. A run that waits
  `MORCA_WATCHDOG_UNMET_MINUTES` (10) for more than the host can ever grant
  trips the watchdog's `unmet` rule ([docs/watchdog.md](watchdog.md)),
  which pauses its pipeline and sends its alert.
  `max_runs` and `fill_max_runs` still cap the runs on top.
- **Grants.** A run that starts gets up to its maximum of what's left, in
  `MORCA_GRANT_CPUS` and `MORCA_GRANT_MEMORY_MB`. The grant is fixed for that
  start: nothing shrinks or is killed mid-run, and a retry is granted
  again. It's recorded on the run (`orca.runs.grant_cpus`,
  `grant_memory_mb`, with the request it had: migration 36) and shown on
  its page beside the peak it used. The first of two runs that start at
  once takes up to its maximum, the second what's left.
- **Remote workers** (`morca worker`) admit the runs they take the same way,
  against their own host, with the same variables; a worker's reserve
  defaults to 0 CPUs and 512 MB. A run that doesn't fit is left queued for
  another worker, held saying which one had no room, or, more than any
  worker of the pool seen in the last 10 minutes grants, `waiting: needs 5
  GB, more than the 3.5 GB a worker of pool g grants at most`.
- **No request, no change.** A pipeline without `cpus` or `memory_gb` is
  started as before: no check, no grant. Its runs aren't counted against
  the others' either, so on a shared host give every pipeline a request,
  or keep the reserve large enough for the ones without.
- **Not on EC2 or Kubernetes**, whose runs get machines of their own: the
  request is kept but not used there yet.
- **The control placement's memory cap** (`MORCA_CONTROL_MEMORY_MB`, 1024)
  still kills a control-placed run over it, whatever its grant: set it at
  least as high as the largest `memory_gb` maximum you place there.
- **Enforced where morca can make cgroups** (`morca._internal.cgroup`;
  [docs/hetzner.md](hetzner.md#a-cgroup-per-run)): a run's grant is its
  cgroup's `memory.high`, and `MORCA_RUN_MEMORY_MARGIN` (25) percent above it
  the kernel kills the run, it alone. A run held at its grant short of that
  (throttled, its memory not reclaimable: at the limit with its tasks
  stalled on memory, PSI) for `MORCA_RUN_MEMORY_HELD_SECONDS` (120; 0: never)
  is killed by morca the same way. The attempt fails `out of memory at
  <limit>`, and the pipeline then asks for `MORCA_RUN_MEMORY_GROWTH` (1.5)
  times that at least, up to `memory_gb`'s maximum and what the host can
  grant (more would wait forever): its retry and its later
  runs, until 20 of its runs after the one killed have succeeded
  (registering a different `memory_gb` forgets it sooner). Killed at that
  maximum already, the run fails then, with the kill as its error, rather
  than retrying at the same limit. A run without a
  request is limited to `MORCA_RUN_MEMORY_MB` (default what the host can
  grant). Set the scheduler's and the worker's environment; the UI reads
  `MORCA_RUN_MEMORY_GROWTH` for workers' runs.

### Learned requests

From the peaks of a pipeline's last 20 successful measured runs ([What a
run uses](ui.md#what-a-run-uses)), morca works out the request they suggest
(#269, `src/morca/_internal/recommend.mojo`): memory is the 95th percentile of their
peak memory plus 15%, rounded up to a quarter GB and never below what an
out-of-memory kill raised the pipeline to; CPUs are the 90th percentile of
their peak cores, rounded up, at least 1 (none on macOS, which doesn't
measure peak cores). Both are clamped to the declared `cpus` and
`memory_gb`, saying so, and with fewer than 3 such runs there's none. The
pipeline's Resources card shows it beside **Requested**, `morca config show`
prints it after the settings (`learned from 20 runs: 3.25 GB, 2 CPUs`), and
both JSONs have `learned`.

**Turning it on.** `memory_gb = "auto"` or `cpus = "auto"` asks for it:
it is then the request's minimum and maximum. `auto` as a range's lower
end, `memory_gb = "auto..24"`, asks for it at most 24 GB, granted up to 24.
Learned CPUs and memory are also at most what the host grants a run (on a
pool of workers, the most its largest worker grants), so a run whose peaks
reach more than that runs with less rather than waiting forever (#462).
A capped memory is logged once each time the cap changes, and shown in
`morca config show` and on the pipeline's card (`learned from 20 runs: 2.5
GB, capped at 2.2 GB, this host's most`, `"capped"` in the JSON), and in
a waiting run's reason. A declared request isn't capped: one over what the
host grants waits, as above.
`morca register --memory-gb auto` does the same. Each start of a run on the
local runner, the control host or a remote worker is admitted and granted
from it (cgroup limit, kill and out-of-memory retry as above), resolved
when that start is admitted and fixed for its life. The scheduler keeps it
on the pipeline (`orca.pipelines.learned`) and works it out again only
after a new successful run's peaks are recorded, an out-of-memory raises
the pipeline, or its request is registered differently. The card and
`morca config show` then say **applied** (`"applied": true`).

**Fallback.** With no recommendation yet (fewer than 3 measured runs, or
CPUs on macOS) that resource has no request, as without `cpus` or
`memory_gb`: no admission check, no grant, the default cgroup limit. Give
a new pipeline its first runs that way, or start with a declared range and
switch to `auto` once it has some.

**Off switch.** `learn = false` in the pipeline's table (or `[defaults]`)
keeps `auto` at that fallback; the card and `morca config show` still show
the recommendation, **not applied**.

**What's recorded.** Each run keeps its latest start's request
(`request_cpus`, `request_memory_gb`: the learned values, such as `3.25`)
and where it came from (`request_source`: `declared`, `learned` or
`default`; `request_runs`: how many runs a learned one is from; migration
44). Its page shows it beside the grant (**Requested** `3.25 GB · learned
from 20 runs`), and its JSON has `request_source`. Before rolling morca back
past this, register without `auto`: an older morca refuses it.

### How many at once

`max_runs = "auto"` starts another run of the pipeline whenever its request
fits in what this host's running runs weren't granted, up to a ceiling of
64 (`"auto..N"` sets the ceiling to N). A bigger host runs more of them at
once with no change to morca.toml: at 2 GB a run, 4 on a host with 8 GB to
grant, 12 on one with 24.

```toml
[pipelines.gharchive]
memory_gb = "auto"     # learned from its runs
max_runs = "auto"
```

It needs a request to weigh, declared or learned. Until it has one (no
`cpus` or `memory_gb`, or `auto` with nothing learned yet), it starts one
run at a time, and its queued runs say so: `waiting: max_runs = "auto"
starts one run at a time until its runs have a request to weigh`. On EC2,
Kubernetes and remote workers, where there is no host's room to weigh, the
ceiling is the limit (a worker still admits what it takes against its own
host). `fill_max_runs = "auto"` works the same way for fill runs. An older
morca reads `"auto"` as its ceiling.

### Memory pressure

Requests are estimates, and a host can be short of memory while its grants
add up: page cache, Postgres, a run past its estimate. So on top of
`max_runs`, `fill_max_runs` and the grants, the scheduler reads the host's
memory pressure each tick: Linux's pressure stall information (PSI), the
share of time tasks were stalled waiting for memory. It applies to every
pipeline started on the local runner or the control host, with a request or
without one, and to the runs a [remote worker](workers.md) claims, which
reads its own host's.

| Variable | Default | |
|---|---|---|
| `MORCA_ADMIT_MEMORY_PRESSURE` | 10 | the `some avg10` percent over which no new run starts; 0 turns it off |
| `MORCA_ADMIT_PRESSURE_GRACE_SECONDS` | 600 | how long a hold lasts with none of morca's runs going before runs start one at a time |
| `MORCA_MEMORY_PRESSURE_FILE` | found | the PSI file to read instead of the one morca finds |

- **The hold.** While `some avg10` is over the limit, no new run starts on
  that host; runs already going go on. A queued run says why, on its page,
  its pipeline's (**Waiting**), the runs and home pages, and in the JSON:
  `waiting: memory pressure 23% (limit 10%)`; on a worker's pool, `... on
  worker <name>`. The hold ends once `avg10` is under half the limit, or has
  stayed at most the limit for 30 s (`... 7%, easing (limit 10%)` until
  then), so a reading at the limit doesn't flap.
- **Never forever.** A hold that has lasted the grace with none of morca's
  runs going on the host isn't morca's doing: the scheduler (or worker) logs
  it, raises the `memory-pressure` [alert](alerts.md) once, and starts runs
  there one at a time until the pressure eases.
- **Which file.** In order: `MORCA_MEMORY_PRESSURE_FILE`; the cgroup v2
  `memory.pressure` of the nearest cgroup, from the scheduler's own up,
  whose `memory.max` is a limit (a Docker container run with `--memory`);
  the host's `/proc/pressure/memory`; the scheduler's own cgroup's
  `memory.pressure` though it has no limit. Without any (macOS, or a kernel
  built or booted without PSI) nothing is held, and the scheduler says so
  once when it starts. [hetzner.md](hetzner.md#memory-pressure) has what
  that means in the stack's container.
- **Runs can read it too.** Every run started on the local runner, the
  control host or a worker gets `MORCA_MEMORY_PRESSURE_FILE`, the file its
  host's pressure was read from, which `env` can't set. A step can poll it
  (`morca.memory_pressure()`, which returns the `some` and `full` averages,
  or None) and lower its own parallelism while it's high. The file is
  Linux's: `some avg10=1.53 avg60=0.87 avg300=0.24 total=1234567`, then a
  `full` line the same; read it whole, as often as every second.
- **Where it shows.** Ops › Control's **Memory pressure** card and
  `memory_pressure` in `/api/system` (and in `/` and `/runs`' JSON); each
  worker's in `/api/workers` (`memory_pressure`); the gauges
  `morca_memory_pressure_some_avg10` (`_avg60`, `_avg300`, `full_*`) and
  `morca_admission_memory_pressure_held` on `/metrics`, labelled by `host`;
  and a line of `morca status`.

### When a run counts as dead

The scheduler takes a running run's process for dead when its heartbeat is
too old, or, before its first beat, when the run was started too long ago.
A dead run is queued again if its trigger retries (within `run_retries`),
else it fails `interrupted: its process stopped`. A run on a machine or pod
that starts slowly is taken for dead once the start grace runs out, so raise
it there.

| Variable | Default | |
|---|---|---|
| `MORCA_STALE_SECONDS` | 30 | how old a running run's heartbeat can be |
| `MORCA_START_SECONDS` | the stale limit; 300 when `MORCA_RUNNER` is `kubernetes` or `ec2` | the grace before a run's first heartbeat |

### "auto" from the grant

An `env` value `"auto"` is passed to the run as it is, for the pipeline to
size itself from its grant: `morca.auto_count("GHARCHIVE_PARALLEL", 16,
memory_mb_each=1500)` reads a number as given, 16 when unset, and for
`auto` the granted CPUs, at most the granted memory over 1500 MB (the
pipeline keeps its per-unit estimate in its own code); without a grant,
the host's cores.

`DISTA_WORKER_SLOTS = "auto"` is passed through the same way, and dista
(0.5.0 on) sizes its workers from the grant: slots from `MORCA_GRANT_CPUS`
and a memory budget from `MORCA_GRANT_MEMORY_MB`, divided among the run's
local workers (`MORCA_WORKERS`), with the tasks in flight adapting to
throughput and memory pressure (morca-dev/dista#123). A run cluster's
worker on another host takes that host's whole grant; a run with no grant,
as on EC2 and Kubernetes, gets a slot per core and no budget. A number, such
as `"4"`, is passed as it is and works as before: that many slots, no
budget, no adapting.

## Secrets without Secrets Manager

`secrets` ids are read with `MORCA_SECRET_FETCH` when it is set: the
scheduler runs `<MORCA_SECRET_FETCH> <id>` through `sh -c` and uses what it
prints (trailing newlines dropped). To keep them in files, as on a single
server (see [hetzner.md](hetzner.md)), set it to a command that reads one:

```sh
MORCA_SECRET_FETCH='sh /etc/orca/secret-fetch'   # prints /etc/orca/secrets/<id>, mode 600, root only
```

The ids still start with `orca/`; the script must refuse `..`. For an
S3-compatible store instead of S3, set `AWS_ENDPOINT_URL_S3` (and
`AWS_REGION`, the keys) in the scheduler's environment file, not in `env`.

## morca config show

```text
$ morca config show gharchive
gharchive  registered from morca.toml @ 3f2a9c1d0b7e, sha256 b0e8af31ea3e
  overrides: --workers 0..8
  placement               ec2         morca.toml [defaults]
  head_type               t4g.medium  morca.toml [defaults]
  worker_type             c7g.xlarge  morca.toml [pipelines.gharchive]
  workers                 0..8        flag --workers
  worker_procs            1           morca.toml [pipelines.gharchive]
  max_runs                2           morca.toml [pipelines.gharchive]
  keys_per_run            1           code default (the pipeline's keys_per_run)
  priority                0           code default
  image                   …/morca:3f2a9c1  flag --image
  env.GHARCHIVE_PARALLEL  16          morca.toml [pipelines.gharchive]
  env.DISTA_WORKER_SLOTS  4           morca.toml [pipelines.gharchive]
  env.MORCA_PUBLIC_WAREHOUSE  …        environment MORCA_RUN_ENV
```

Without a pipeline name it prints every registered pipeline. Values that come from the environment are read from the environment of the process running the command. On AWS, run it as `sudo docker exec scheduler morca config show` to see the scheduler's environment.

`--json` prints the same for scripts. With a pipeline name it prints one object; without one it prints `{"pipelines": [...]}`:

```json
{"pipeline": "gharchive", "file": "morca.toml", "hash": "b0e8…", "commit": "3f2a…", "dirty": false,
 "overrides": {"workers": "0..8"},
 "settings": [{"key": "placement", "value": "ec2", "source": "morca.toml", "detail": "[defaults]"}, …]}
```

`source` is one of `code default`, `morca.toml`, `flag` or `environment`.

The UI's pipeline page has the same under **Configuration** (`/pipelines/<name>#config`, and `config` in `/api/pipelines/<name>`): where it was registered from, the flags that overrode the file, and each value with its source. A run's **Settings** link to it. The values from the environment are the UI's environment, which on AWS is the scheduler's.

## morca config check

```text
$ morca config check                    # ./morca.toml, or $MORCA_CONFIG
morca.toml: ok, 3 pipelines
$ morca config check --overlay ../ops/dev/morca.overlay.toml
morca.toml with ../ops/dev/morca.overlay.toml: ok, 3 pipelines (1 not enabled)
$ morca config check ci/morca.toml --secrets
ci/morca.toml:9: [pipelines.mojo_repos] secrets: GITHUB_TOKEN: can't read secret orca/github-token: exit 254
morca: ci/morca.toml has 1 problem(s)
```

It checks a file for a project's CI and needs no database. It refuses what `morca register` would refuse, with the same `file:line: [table] key: why`. It also checks that morca can size each `head_type` and `worker_type` (the vCPUs `worker_procs = "auto"` and the fleet use; `MORCA_EC2_VCPUS` adds types), and warns about a type that isn't in morca's price table, which Ops > Pools' cost tile and the watchdog's cost rule count as $0 an hour. `--secrets` also reads each secret the way the scheduler does (`MORCA_SECRET_FETCH`, else Secrets Manager with the `AWS_*` credentials or the instance role) and never prints a value. It exits 1 if anything is wrong.

`morca config show --file [<file>] [--overlay F]` prints the file as
`morca register` would read it, with the overlay (or `MORCA_CONFIG_OVERLAY`)
laid on it, and needs no database.

## morca config export

```text
$ morca config export            # writes ./morca.toml; refuses to replace one without --force
$ morca config export --out -    # prints it instead
# morca.toml, written by `morca config export` from the registrations
# in morca's database. `morca register` reads it (morca.config).

[pipelines.gharchive]
placement = "ec2"
head_type = "t4g.medium"
worker_type = "c7g.xlarge"
workers = "0..4"
worker_procs = 1
env = { DISTA_WORKER_SLOTS = "4", GHARCHIVE_PARALLEL = "16" }
```

The export has a table for every registered pipeline, holding what is registered for it beyond the defaults. Registering from the exported file gives the same registration back. It writes no `[defaults]`: move values shared by several pipelines there by hand.

## Migrating from register flags

1. Run `morca config export` against the deployed database. On AWS: `sudo docker exec scheduler morca config export --out -`, and copy the output into the project's `morca.toml`.
2. Move pipeline variables from `/etc/orca.env` into each pipeline's `env`. These are the variables `MORCA_RUN_ENV` names for a single pipeline, for example `DISTA_WORKER_SLOTS`. Keep stack settings in `/etc/orca.env`. Once no pipeline relies on a name, drop it from `MORCA_RUN_ENV`.
3. Optionally move shared values into `[defaults]`.
4. Commit the file, then register as usual without the flags: `morca aws register gharchive` or `morca register ./build/gharchive`.
5. Check with `morca config show <pipeline>`. Every value should say `morca.toml`, and the header should name the commit.

From then on a flag is a one-off, such as `--workers 0..8` for a backfill. The next registration without it goes back to the file.

## Apps

An app is a long-running binary of the project's image beside the UI (the
census console), `/opt/morca/bin/<name>`. Its table says what the stack
gives it, as a pipeline's says how its runs run; the stack names which apps
it runs ([hetzner.md](hetzner.md#apps)).

```toml
[apps.console]
port = 8080
check = "/healthz"
env = { CONSOLE_SEMANTIC = "1" }
lake = true
secrets = { POSTHOG_KEY = "orca/posthog-key" }
memory_gb = 1
```

| Key | Type | Default | What it is |
|---|---|---|---|
| `port` | integer from 1 to 65535 | none: the stack's must | Where it listens, as `PORT`. |
| `check` | string, a path | `/` | Answers 200 once the app is ready; a new one serves only then. |
| `env` | table of `NAME = "value"` | none | Its variables. Not `PORT`, the lake's, or a name that looks like a secret's (`PASSWORD`, `SECRET`, `TOKEN`); one line each. |
| `lake` | boolean | `false` | `true`: the warehouse settings (`MORCA_WAREHOUSE`, `MORCA_PUBLIC_WAREHOUSE`, `AWS_REGION`, `AWS_ENDPOINT_URL_S3`) and the stack's S3 keys. |
| `secrets` | table of `NAME = "orca/<id>"` | none | Each secret's value as `NAME`. IDs only, never values. |
| `memory_gb` | number over 0 | none: no limit | Its memory limit. |

An app gets nothing it doesn't ask for: never morca's database. The name
is lower-case letters, digits, `_` and `-`, and not one of the stack's own
containers (`scheduler`, `ui`, `sampler`, `cloudflared`, `postgres`). An
overlay can change an app the file has, not add one.

`morca config apps [<file>] [--overlay F]` prints them a line per fact, as
the stack's script reads them, with secrets by ID:

```text
console port 8080
console check /healthz
console lake true
console memory_mb 1024
console env CONSOLE_SEMANTIC=1
console secret POSTHOG_KEY orca/posthog-key
```

## Datasets

A `[datasets."<namespace>.<table>"]` table holds a dataset's settings
(`src/morca/_internal/dataset_config.mojo`). The name has a dot, so quote
it, or write it two keys deep: `[datasets.hindcast.t2m]` is the same.

```toml
[datasets."hindcast.t2m"]
public = false
```

| Key | Type | Default | What it is |
|---|---|---|---|
| `public` | boolean | `true` | `false`: the dataset's Data tab (`/datasets/<name>?tab=data`, `data.json` and `data.csv`; [the UI](ui.md#a-datasets-data)) is shown only to those logged in, once login is on. Its Overview, snapshots and lineage stay public. |

`morca register` records the file's datasets and only those: a dataset
the file no longer names is public again. `morca config check` checks the
table: an unknown key, a `public` that isn't `true` or `false`, or a name
that isn't `namespace.table` is refused.

## Worker pools

A `[pools.<name>]` table makes a pool of [remote workers](workers.md) that
morca grows and shrinks itself (#267). Pipelines run on it with
`placement = "worker:<name>"`, as on workers started by hand.

```toml
[pools.lab]
provider = "hetzner"
machines = [
  { type = "cax31", wait = 600 },   # prefer this; keep trying it for 10 min
  { type = "cax21", wait = 600 },
  { type = "cpx32" },               # the last: no wait, keep trying it
]
locations = ["hel1", "nbg1", "fsn1"]
max_machines = 3
idle_seconds = 900
```

| Key | Type | Default | |
|---|---|---|---|
| `provider` | `"hetzner"` or `"ec2"` | (required) | Where the machines are made. |
| `machines` | list of `{ type, wait }` | (required) | Machine types in order of preference. `wait` is how many seconds morca keeps trying a type before moving to the next; every entry but the last needs one. |
| `locations` | list of strings | none | Where to try each type, in order: Hetzner locations (required there), or EC2 subnet IDs (none: the default subnet, or `MORCA_EC2_SUBNET`). |
| `max_machines` | 1 to 100 | 1 | The most machines the pool has at once. |
| `idle_seconds` | 10 to 86400 | 900 | How long a machine may sit idle, with nothing queued for the pool, before it's removed. |

`morca register` with the file records its pools in `orca.pools`. A pool the
file no longer has is deleted there, and its machines are removed once
idle. A machine that's running is never replaced by a type higher in the
list: the order only matters when morca adds one.

The leading scheduler grows and shrinks each pool (`morca._internal.pool_scale`):

- **Grow.** While runs of the pool's pipelines have waited 20 s that a
  worker could start (at most `max_runs` less those running, per
  pipeline), no machine of it is still booting, and it has fewer than
  `max_machines`, it makes one. It tries the type it's on in each location
  in turn, keeps trying it for its `wait`, then moves to the next. It skips
  a type whose architecture (as the provider says) the worker image has no
  variant for. `orca.pools.status` says what the last try came to.
- **Boot.** The machine's startup script holds only a worker token of its
  own. With it, the machine asks the UI's `/api/worker/boot` for the image
  it was made for, the login to pull it and the bucket's variables, then
  runs `morca worker` in Docker with run cgroups.
- **Deploys.** A machine keeps the image it booted with. Once the
  scheduler's `MORCA_WORKER_IMAGE` is another (a deploy), the machine
  drains: it's given no new runs, finishes those it has, and is removed
  once idle, without waiting for `idle_seconds`. A machine of the new
  image replaces it as runs wait, within `max_machines`.
- **Shrink.** A machine idle for `idle_seconds` with nothing waiting is
  removed: its token revoked, then the machine deleted. So is one whose
  worker never shows up (15 min) or goes silent (5 min), whose runs are
  queued again, and a machine with the pool's and this stack's labels that
  morca doesn't know.

What the scheduler and the UI need, in their environment:

| Variable | |
|---|---|
| `MORCA_HCLOUD_TOKEN`, or `MORCA_HCLOUD_TOKEN_SECRET` | Hetzner's API token (scheduler), or the secret that holds it. |
| `MORCA_HCLOUD_FIREWALL`, `MORCA_HCLOUD_SSH_KEYS`, `MORCA_HCLOUD_IMAGE` | The firewall and SSH keys (names) to give each machine, and its OS image (`ubuntu-24.04`). |
| `MORCA_HCLOUD_NETWORK`, `MORCA_HCLOUD_NETWORK_ZONE`, `MORCA_HCLOUD_NETWORK_RANGE` | The private network every Hetzner machine joins (`orca-<stack id>`, made in `eu-central` over `10.77.0.0/16` if it isn't there; `none` for none). One run spread over several machines talks over it, and each machine's worker advertises its address on it. |
| `AWS_REGION` and credentials (or an instance role) | EC2's API (scheduler), for `provider = "ec2"`. |
| `MORCA_POOL_EC2_SECURITY_GROUP`, `MORCA_POOL_EC2_PROFILE` | On EC2, each instance's security group and instance profile (else `MORCA_EC2_SECURITY_GROUP`, `MORCA_EC2_PROFILE`). The profile's role is how its worker reaches the bucket. |
| `MORCA_POOL_EC2_AMI_ARM64`, `MORCA_POOL_EC2_AMI_AMD64` | On EC2, the image to pin per architecture; else Ubuntu 24.04 from Canonical's public SSM parameter. |
| `MORCA_WORKER_IMAGE` | The image the machines run, the server's own (scheduler and UI). |
| `MORCA_UI_URL` (or `MORCA_POOL_REMOTE`) | Where machines reach the UI. |
| `MORCA_REGISTRY_USER`, `MORCA_REGISTRY_TOKEN_SECRET` | The login to pull a private image: the UI hands it to a booting machine, and the scheduler reads the image's architectures with it. |
| `MORCA_POOL_SCALE_SECONDS` (15), `MORCA_POOL_GROW_AFTER` (20), `MORCA_POOL_TRY_SECONDS` (60), `MORCA_POOL_BOOT_SECONDS` (900), `MORCA_POOL_LOST_SECONDS` (300), `MORCA_POOL_IMAGE_SECONDS` (600) | How often it looks, how long runs wait before it grows, between tries, for a machine to join, for a worker gone silent, and between reads of the image's architectures. |


## Priority

When the host has room for fewer runs than could start, `priority` says
which pipeline's go first (#421). Each scheduler pass takes the pipelines
highest priority first, then by name, and each takes what host capacity the
ones before it left: memory and CPUs granted to requests, the control
slots, `MORCA_VCPU_BUDGET`.

```toml
[pipelines.mojo_live]       # hourly, meant to run on time
priority = 10

[pipelines.gharchive]       # a long backfill, priority 0
fills = "all"
```

- **New runs before fills.** Within one priority, every pipeline's other
  runs (scheduled, sensed, backfilled, manual, and due retries) start
  before any pipeline's fill runs, so a fill uses only the room they left.
  A higher priority's fill runs still go before a lower priority's other
  runs.
- **A retry keeps its place.** Within a pipeline, the runs that may start
  go oldest first by run id, so a due retry of an old partition starts
  before newer runs.
- **Why a run waits.** A run held for room on this host while a pipeline
  of higher priority has runs holding it names that pipeline:
  `waiting: for capacity (mojo_live, priority 10): needs 2 GB, 0 GB free of grants`.
- **Nothing is stopped.** A run that has started keeps its room; priority
  only orders the starts. Steps of one run run in order, and which dista
  worker a task goes to is dista's.
- **Worker pools.** A remote worker claims the queued runs of its pool in
  the same order: the highest priority first, then the other runs before
  the fill runs, each oldest first.

An older morca ignores `priority`: it starts the pipelines by name, as it
did.

## Keys per run

`keys_per_run` is how many keys one run takes (#240). The code sets it
(`Pipeline[..., keys_per_run=N]`, default 1); morca.toml overrides it, so a
deployment sizes it without a rebuild. A run's fixed cost (a worker claiming
it, a dista cluster, loading tables, a replace commit) is then paid once per
batch, not per key.

- **A backfill** queues runs of up to `keys_per_run` of the keys it takes.
- **A fill run** takes up to `keys_per_run` partitions, in `fill_order`.
  `fill_max_runs` still caps the runs.
- **A sensor**, above 1: the keys of new snapshots go first to its sensor
  runs that are queued and haven't started, up to `keys_per_run` each,
  oldest first, then to new runs of up to `keys_per_run`, in key order. A
  catch-up behind an upstream that commits one day a run so makes a run per
  `keys_per_run` days instead of one per day, while a new day in steady
  state is still one run of one key. At 1, the default, a sensor queues one
  run over everything one tick sensed, as before.

A run over many keys fails as a whole when one key fails, and its retry
resumes with the steps already done skipped.

## Fills

With `fills = "all"` a pipeline fills its whole range by itself, within limits (#155, `src/morca/_internal/fill.mojo`). People change the limits; nobody has to drive a long backfill by hand.

The default, `fills = "since_registration"`, is what morca did before. A schedule fills from the pipeline's registration on, and `morca backfill` fills the rest by hand.

### What the scheduler does

On every tick, after the other runs of every pipeline of its [priority](#priority) have started, the scheduler queues and starts fill runs for it:

- **The range** is the pipeline's first partition through the last one that has ended on its schedule's wall clock (UTC without a schedule), at least `fill_lag` ago: yesterday for a daily pipeline, last month for a monthly one. The partition still going is the schedule's. See [The lag](#the-lag).
- **`keys_per_run` partitions per fill run** (one by default), in `fill_order`; a run's own partitions are in ascending order. The run's trigger is `fill` (`orca.runs.trigger`), so the runs page can filter for them.
- **A partition is taken** when it's done in a run of any of the pipeline's code, when a live run has it, or when a fill run of it was ever queued. A fill never runs a partition twice. A fill run that fails is retried like a scheduled run, up to `run_retries`. A partition whose fill run failed past its retries, or was cancelled, is left to a person: `morca backfill`, or resume in the UI. Running done partitions again stays `morca backfill --rerun`.
- **Fill runs don't count against `max_runs`.** At most `fill_max_runs` fill runs are going, beside up to `max_runs` other runs.
- **On a worker pool** (`placement = "worker:<pool>"`) the scheduler queues the fill runs the same way and leaves them for a worker of the pool to claim. `fill_max_runs` caps the fill runs going across the whole pool, the queued ones included; each worker's `--max-runs` caps what one machine takes. See [Fills on a pool](workers.md#fills-on-a-pool).
- **Fill runs never starve scheduled runs.** While any of the pipeline's scheduled, backfill or other runs are queued, no fill run starts. Fill runs still take room in the stack-wide limits (`MORCA_VCPU_BUDGET`, the control instance's slots) once they're going.

### The lag

`fill_lag` (default `0`) holds a partition back for a while after it ends, for a source that publishes its data late. A partition is filled once its end is at least `fill_lag` in the past: a daily day D from D+1 00:00 plus the lag, a monthly month from the 1st of the next month plus the lag, both on the schedule's wall clock (UTC without a schedule).

GH Archive puts each hour's file up some minutes after the hour. With no lag, the fill starts the day that just ended at 00:00 UTC, before its last hour is there. Its attempts fail until the file appears, and enough failures in an hour trip the [watchdog](watchdog.md), which pauses the pipeline. With `fill_lag = "2h"` the day is filled from 02:00 UTC.

Until then the partition is outside the range: the fill doesn't count it in its total, nor does the pipeline's [coverage](ui.md#coverage-in-one-number), so it never shows as missing. The Fill line says when it fills (`Next: 2026-11-09 fills from 2026-11-10 02:00 UTC (fill_lag 2h)`), and the API gives it as `waits_for_lag` (below). The lag holds back fill runs only: a schedule fires when its cron says, and `morca backfill` runs what it's given.

### What stops a fill

The pipeline page and `/api/pipelines/<name>` say which of these stopped it, in this order:

| Idle because | |
|---|---|
| `complete` | Every partition of the range is done, or the last ones are running. |
| `paused` | `morca pause`, the UI's Pause button, or the [watchdog](watchdog.md) tripping: it pauses the pipeline, and a fill stops like everything else. The reason names the watchdog's rule when the watchdog paused it. |
| `outside its window` | The UTC hour is outside `fill_window`. A fill run that has started goes on past the window's end. |
| `no budget` | The runs cost money (EC2 or Kubernetes) and `fill_budget_per_day` isn't set. |
| `price unknown` | Neither morca.fleet's price table nor a Kubernetes cluster can price the run. The [cost estimate](#the-cost-estimate) fails closed. |
| `budget` | Today's estimated spend plus what the next run may cost would go over `fill_budget_per_day`. It starts again at 00:00 UTC. |
| `waiting` | Other runs of the pipeline are queued, and they start first. |
| `at fill_max_runs` | As many fill runs are going as `fill_max_runs` allows: running, or on a worker pool queued for a worker. |

### The cost estimate

The estimate is conservative and fails closed. The AWS project's spend limit pauses the whole project, so a fill must stop well before it.

- **Price.** A run's price is an hour of its head instance plus its most workers, at on-demand prices from morca.fleet's table (`hourly_price` in `src/morca/_internal/fleet.mojo`). That's the us-east-2 on-demand price for the types morca uses. The estimate is multiplied by 1.2 for what the table leaves out: EBS, transfer and requests.
- **Spend today.** It sums each fill run's instances (`orca.instances`) since 00:00 UTC, at their own types' prices. An instance still up counts to now, including its idle time in the warm pool.
- **Before starting a run**, morca adds what the fill runs going and the new one may still cost. The expected time of a run is the longest of the pipeline's last 20 ended fill runs, or an hour before any has ended. It is at least a minute (EC2's minimum), plus `MORCA_EC2_POOL_SECONDS` of idle time in the pool. A run already going is charged that time less what it has run. The run starts only if the spend plus that is within `fill_budget_per_day`.
- **Unknown prices.** No fill run starts on a budget when the price isn't known: an instance type that isn't in the table (today's runs' or the next run's), or a run on Kubernetes. The reason says which type.
- **Free runs.** A run on the control host (`placement = "control"`) or a local process costs nothing beyond the machine already running. Its fill needs no budget.

The budget is per pipeline, so a `fill_budget_per_day` in `[defaults]` gives each pipeline in the file that much. The estimate can't see a run that lasts longer than every earlier one until it has. The watchdog's `cost` rule (`MORCA_WATCHDOG_COST_DAY`, $25) is the stack-wide backstop: it pauses everything.

### Progress

The pipeline page has a **Fill** line: partitions done of the range's total, fill runs going, partitions in live runs, waiting for a retry and failed. It also gives the rate (partitions an hour over the fill runs that ended in the last six hours), the ETA at that rate, and today's estimated spend against the budget. When the fill is idle, the line says why, and a partition that waits for `fill_lag` is on a line of its own. `/api/pipelines/<name>` is the page's JSON, with a `fill` object:

```json
{"on": true, "total": 1405, "done": 380, "live": 2, "failed": 0, "retrying": 0, "left": 1023,
 "running": 2, "rate_per_hour": 41.5, "eta_seconds": 88770, "spent_today": 1.734,
 "budget_per_day": 5.0, "price_per_hour": 0.6134, "expected_run_seconds": 210,
 "cost_is_estimate": true,
 "waits_for_lag": {"partition": "2026-11-09", "fillable_at": "2026-11-10T02:00:00Z"},
 "idle": null}
```

`morca config show` lists the `fill*` keys, with their defaults, for a pipeline that fills, and `cpus` and `memory_gb` for one with a request.

### Keyed pipelines and sensors don't fill

`morca register` refuses `fills = "all"` for them, with the file and line:

- **Keyed pipelines.** Their keys come from a dataset, so there's no range to fill. Their sensor or `morca backfill <p> @all` queues the keys that aren't done.
- **Sensors.** Their runs follow their inputs' snapshots. Filling their range by itself would run partitions whose input may not be there.
- **No first partition.** A pipeline whose partitions have no first one has no range.

If `fills = "all"` is in `[defaults]`, set `fills = "since_registration"` in such a pipeline's own table.

### Operating a fill

Operations go through the UI or the remote CLI (`morca login` and `morca --remote`, #128), which write audit rows: pause, unpause, cancel, backfill and resume. To change a limit, edit `morca.toml`, commit it, and register again (`morca aws register <pipeline>`). SSM `sudo docker exec scheduler ...` is for debugging only.

## Not yet

- Drift warnings on the pipeline page (registered from morca.toml @ X, which has since changed): the control instance has no checkout to compare with.
- `[stack]` read by `morca aws up`.
