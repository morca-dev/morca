# The pipeline-binary protocol

The prebuilt `morca` binary (the scheduler, the UI, `morca worker` and the
runners) never links a pipeline's code. It starts a **pipeline binary** and
deals with it only through four things: the binary's command line, its
environment, the run store (Postgres, SQLite, or the UI's worker API) and the
Iceberg tables. This page writes that contract down, so that a second
implementation, such as a pipeline binary written in Rust (#521), can be
built from it. The conformance suite (`tests/conformance.py`, #519) tests
against it: `pixi run conformance <binary> <manifest>`.

Today the Mojo side of the contract is `morca_main` (`src/morca/_cli.mojo`),
`Pipeline` (`src/morca/pipeline.mojo`), `Ctx` (`src/morca/ctx.mojo`) and the
`RunStore` implementations under `src/morca/_internal/`. Each rule below cites
the code it comes from as `path:line`, against morca-mojo 0.34.0.

**Contract or incidental.** Each rule is marked:

- **Contract**: the scheduler, the UI or another process relies on it. A
  second implementation must do the same, and a change to it changes this
  page and the conformance suite in the same PR.
- **Incidental**: what the Mojo binary happens to do today. Nothing outside
  the binary depends on it, so a second implementation may differ.

If a rule isn't marked, it is contract.

## Contents

- [A run's life](#a-runs-life)
- [Subcommands](#subcommands), and [which placement needs which](#which-placement-needs-which)
- [`describe` and the registry hash](#describe-and-the-registry-hash)
- [Environment](#environment)
- [The run store](#the-run-store)
- [Tables](#tables)
- [Step inputs and outputs](#step-inputs-and-outputs)
- [Logs](#logs)
- [Versions](#versions)
- [Exit codes](#exit-codes)
- [A first implementation](#a-first-implementation)

## A run's life

1. **Registration.** `morca register <binary>` runs `<binary> describe` and
   stores the JSON it prints as the pipeline's registration
   (`src/morca/_internal/registering.mojo:69-71`). From then on the scheduler
   reads the DAG, partitions, schedule and retries from that stored JSON
   (`src/morca/_internal/db/registered.mojo:76-100`). It doesn't run the
   binary again to find them out.
2. **Queueing.** The scheduler decides which partition keys a run covers (from
   the schedule, a sensor, a fill or a user) and inserts the run row itself,
   with the registered `registry_hash` and the keys comma-joined in
   `runs.partitions` (`src/morca/_internal/db/starting.mojo:253-270`).
3. **Starting.** It marks the run `running` with `owner = 'scheduler'` and no
   heartbeat, counts a start (`src/morca/_internal/db/starting.mojo:297-310`),
   and launches **`<binary> resume <run>`** (`src/morca/_internal/starting.mojo:479-481`).
   Every placement starts a run this way. Nothing outside the binary ever
   runs `run --partitions`.
4. **Claiming.** The binary claims the run in the store, which makes it the
   run's owner, and keeps a heartbeat going while it runs.
5. **Steps.** For each step and partition that hasn't succeeded yet, it
   records an attempt, runs the step, and records the result. Reads and
   commits to tables are recorded as they happen, and every commit carries
   the `orca.*` summary keys.
6. **Ending.** It records the run's outcome (`succeeded`, `failed`,
   `deferred` or `cancelled`), clears its heartbeat and exits.

The scheduler learns how a run ended from the run row, not from the process.
The exit code and the output matter only when the process never claimed
the run, or crashed (see [Exit codes](#exit-codes)).

## Subcommands

`morca_main` parses `argv[1]` (`src/morca/_cli.mojo:148-323`). An unknown
command, or a known one with the wrong number of arguments, prints the usage
and exits 2 (`src/morca/_cli.mojo:106-110`, `:322-323`).

Two checks run before any command except `sample` (**incidental**, but they
keep a broken binary from being registered):

- `MORCA_DATABASE_URL` and `MORCA_STATE_URL` both set is a usage error, exit
  2 (`src/morca/_cli.mojo:156-157`).
- A scheduled pipeline parses its cron expression and loads its zone, so a
  bad schedule fails every command (`src/morca/_cli.mojo:160-161`).

### Which placement needs which

A placement says where a pipeline's runs start ([placement.md](placement.md)).
A first implementation can leave out every subcommand its placements don't
need.

| Subcommand | Called by | `default` (local) | `control` | `ec2` | `worker:<pool>` | kubernetes runner |
|---|---|---|---|---|---|---|
| `describe` | `morca register`, `morca locate` | yes | yes | yes | yes | yes |
| `resume <run> [--allow-new-code]` | the runner, to start every run | yes | yes | yes | yes | yes |
| `sense` | the scheduler, for a sensor pipeline | sensor only | sensor only | sensor only | sensor only | sensor only |
| `keys` | the scheduler and UI, for a keyed pipeline | keyed only | keyed only | keyed only | keyed only | keyed only |
| `sample --out ... --pid ...` | the runner, beside each run | optional | optional | optional | optional | optional |
| `keep-log <stage> <location> <start>` | the runner, after the run's process ends | with secrets | yes | yes | yes | no |
| `put-log <local> <location>` | the EC2 instance script | no | no | yes | no | no |
| `pool-wait`, `pool-next` | the EC2 warm pool | no | no | pools only | no | no |
| `dista-status`, `dista-drain` | the scheduler, scaling an EC2 run | no | no | with dista tasks | no | no |
| no arguments, `DISTA_ROLE` set | the runner, for a dista head or worker | with dista tasks | with dista tasks | with dista tasks | with dista tasks | with dista tasks |
| `run`, `status`, `fires` | people and tests | no | no | no | no | no |

"Optional" means a runner that can't start `sample` only logs it
(`src/morca/_internal/starting.mojo:512-527`), and the run's Machines card
stays empty. "With secrets" means the local runner hands the driver log to
`keep-log` only for a run with secrets, so they're masked; without secrets
it keeps the log itself (`src/morca/_internal/tick.mojo:91-100`).

### `describe`

`<binary> describe` prints the DAG as one line of JSON and exits 0
(`src/morca/_cli.mojo:164-166`). See [`describe` and the registry
hash](#describe-and-the-registry-hash) for its fields.

- The output must be **one JSON object with a non-empty string
  `pipeline`**, or `morca register` refuses the binary
  (`src/morca/_internal/version.mojo`, `parse_describe`). It's parsed, so
  whitespace and key order don't matter: a JSON serialiser's compact output
  (`{"pipeline":"x",...}`) registers (#524). morca before 0.35.0 required
  the output to start with the bytes `{"pipeline": ` (one space); a binary
  that must register with those writes that prefix
  ([Versions](#versions)).
- `describe` is killed after `MORCA_BINARY_SECONDS` (default 300)
  (`src/morca/_internal/proc.mojo:202-208`). It needs no database and no
  warehouse.

### `resume <run> [--allow-new-code]`

Continues a run at whatever isn't done (`src/morca/_cli.mojo:285-310`,
`:373-424`). The runner starts every run this way. `--allow-new-code` is
passed when the run row has `allow_new_code` set
(`src/morca/_internal/starting.mojo:479-481`).

It needs `MORCA_DATABASE_URL` or `MORCA_STATE_URL`; with neither it's a usage
error, exit 2 (`src/morca/_cli.mojo:286-287`). In order, it:

1. migrates the schema (`store.migrate()`, `src/morca/_cli.mojo:379`; see
   [Migrations](#migrations));
2. reads the run (`run_info`) and refuses, exit 3, a run of another pipeline
   (`src/morca/_cli.mojo:380-389`) or of another registry hash unless
   `--allow-new-code` was given (`:390-400`);
3. **claims** the run as `process_owner()`, with `MORCA_STALE_SECONDS` as the
   stale limit (`:401-402`);
4. records the version it ran (`version`, then `ran_version`, `:403-405`);
5. **interrupts** what a previous process left running (`interrupt`, `:406`);
6. loads the steps that already succeeded, with their outputs (`prior`, `:407`);
7. prints `resuming run <run> with <n> steps done and <m> interrupted`
   (`:408-416`) (**incidental**);
8. parses `runs.partitions` back into keys and runs what's left
   (`_execute`, `:417-424`; see [Executing](#executing)).

### `run --partitions <keys> [--allow-new-code]`

Starts a new run and runs it (`src/morca/_cli.mojo:250-284`, `:334-370`).
No runner uses it, so for a second implementation it is a convenience for
people and tests, not contract.

- `--partitions` takes `KEY[..KEY][,...]` for a calendar pipeline, or names,
  `@all` or `@file:<path>` for a keyed one (`src/morca/_cli.mojo:94-103`).
  A key that doesn't parse is a usage error, exit 2 (`:265-270`).
- With `MORCA_STATE_URL` it's refused, exit 2: a worker only resumes the run
  it was given (`:271-275`).
- Without `MORCA_DATABASE_URL` the run is recorded in memory only
  (`MemoryStore`, `:277-279`). Its run numbers are 0 or negative, so its
  commits are never recognised as a retry's (`Ctx.made`,
  `src/morca/ctx.mojo:256-257`).
- If the pipeline isn't registered with a binary yet, `run` registers it
  (`register`, with no binary path). If it is, and the registered hash
  isn't this binary's, it exits 2 unless given `--allow-new-code`
  (`src/morca/_cli.mojo:344-360`).
- It creates the run with trigger `manual`, prints `run <id>`, and runs it
  (`:365-370`). Nothing parses the `run <id>` line (**incidental**).

### `status [<run> | --before <run>] [--status <s>[,<s>...]]`

Lists the latest 20 runs, or one run's steps
(`src/morca/_cli.mojo:311-321`, `:427-470`). For people only
(**incidental**).

### `sense`

For a sensor pipeline (`"sensor": true` in describe). The scheduler runs it
every `MORCA_SENSE_SECONDS` (default 60)
(`src/morca/_internal/sensing.mojo:58-67`), and `morca register` runs it once
for a sensor (`src/morca/_internal/registering.mojo:144-156`).

It prints one line per **sensed dataset**: each dataset a step reads and no
step writes, once, in step order, then a keyed pipeline's keys dataset
(`src/morca/pipeline.mojo:327-347`). Each line is

```text
<dataset> <snapshot> <orca|other> <partitions|->
```

(`src/morca/_cli.mojo:232-249`):

- `snapshot` is the table's current snapshot ID in `MORCA_WAREHOUSE`, or `-1`
  when there's no table or no snapshot;
- `orca` means the current snapshot's summary has an `orca.run` key, and
  `other` means it doesn't;
- `partitions` is that summary's `orca.partitions`, or `-` when it's empty
  or missing.

The scheduler splits each non-blank line on whitespace and needs exactly
four fields, or the whole poll fails (`src/morca/_internal/sensors.mojo:179-196`).
It acts only on lines with `snapshot >= 0` and `other`
(`src/morca/_internal/sensing.mojo:62-66`). For a dataset that morca's own
steps wrote, it uses `orca.commits` instead. A nonzero exit is recorded as
the pipeline's sense error, with the output
(`src/morca/_internal/sensing.mojo:283-296`).

`sense` with sensed datasets and no `MORCA_WAREHOUSE` raises, exit 3
(`src/morca/_cli.mojo:235-236`). How the current snapshot is found is under
[The warehouse](#the-warehouse).

### `keys`

For a keyed pipeline (`"partitions": {"kind": "keyed", ...}`). It prints the
keys dataset's snapshot ID on the first line, then one key per line
(`src/morca/_cli.mojo:222-231`). On a pipeline that isn't keyed it's a usage
error, exit 2.

The scheduler parses the first line as an integer and takes every later
non-empty line as a key. Empty output is an error
(`src/morca/_internal/queueing.mojo:78-89`). The keys are stored in
`orca.keys` (`:98-113`). It runs from the sensor loop
(`src/morca/_internal/sensing.mojo:315-319`) and for backfills and the UI
(`src/morca/_internal/queueing.mojo:197`), killed after `MORCA_BINARY_SECONDS`.

### `fires [<count>] [--after <time>]`

A scheduled pipeline's next fires, each with the partition it runs
(`src/morca/_cli.mojo:473-509`). The scheduler computes fires itself, from
the `schedule` in describe (`src/morca/_internal/sensing.mojo:380-420`), so
this is for people only (**incidental**). The scheduler's computation must
agree with the binary's partition keys, though: see [Partition
keys](#partition-keys).

### `sample --out <location>|- [--pid PID] [--seconds S] ...`

Writes this machine's metrics as JSON lines while `--pid` lives
(`src/morca/_cli.mojo:150-152`, format in `src/morca/_internal/sample.mojo:1-40`).
The runners start `<binary> sample` because the pipeline binary is what every
instance and image has. `morca sample` is the same command
(`src/morca/_internal/sample.mojo:9-14`). A second implementation may leave
it out, as above, or exec `morca sample` where `morca` is on the path.

### `keep-log <stage> <location> <start>`

After a run's process ends, the runner hands its staged driver output to
`keep-log` (`src/morca/_cli.mojo:167-194`): local runs with secrets and
control runs (`src/morca/_internal/scheduler.mojo:975-985`), workers
(`src/morca/_internal/worker.mojo:535-544`) and EC2 heads
(`src/morca/_internal/ec2.mojo:847-865`). It:

1. appends `--- start <start>\n` and the file at `<stage>` to `<location>`
   (local or object storage, see [Logs](#logs));
2. if the output holds a crash (a Mojo stack trace, `src/morca/_internal/crash.mojo`)
   and `MORCA_RUN` is set, interrupts that run's running attempts with the
   crash's first frames, if the run is still `running` (`src/morca/_cli.mojo:179-193`, `:326-331`).

It exits 0 even when it can't record the crash. A nonzero exit is only
logged by the runner, which then removes the stage file anyway
(`src/morca/_internal/tick.mojo:51-56`). The worker keeps it
(`src/morca/_internal/worker.mojo:472-478`). Step 2 is **incidental** where
the runner reaps the crash itself (the local and control runners,
`src/morca/_internal/scheduler.mojo:942-970`), but on EC2 it is the only
thing that fails a crashed driver's attempts before its heartbeat goes stale.

The output to mask is the values of the variables `MORCA_SECRETS` names
(`src/morca/_internal/logs.mojo:37-57`), and secrets are already masked
before the runner writes them to the stage file.

### `put-log <local> <location>`

EC2 only: copies a local file to a location, replacing it
(`src/morca/_cli.mojo:210-215`). The instance script uses it every
`MORCA_CLUSTER_LOG_SECONDS` for its dista logs and metrics
(`src/morca/_internal/ec2.mojo:529-554`). Output is discarded.

### `pool-wait <instance> <run> <start>` and `pool-next <instance> <run> <start> <seconds>`

EC2 warm pools only (`src/morca/_cli.mojo:216-221`, `src/morca/_internal/pool.mojo`).
Both need `MORCA_DATABASE_URL` (`src/morca/_internal/pool.mojo:103-107`).
`pool-wait` returns once the instance's run is over. `pool-next` waits up to
`<seconds>` for the next run handed to this instance and prints
`next <run> <start> <head|-> <1|0>` (the last is `allow_new_code`), or exits 1
to say the instance should shut down (`src/morca/_internal/pool.mojo:84-100`).
The script reads the line with `grep "^next "`
(`src/morca/_internal/ec2.mojo:885-902`).

### `dista-status <head>` and `dista-drain <head> <worker>`

EC2 runs with dista tasks only (`src/morca/_cli.mojo:195-209`). They exist
because the `morca` binary can't link dista. `dista-status` prints the head's
status JSON (`dista status --json`), which the scheduler parses with
`dista.scale.Demand.parse` and reads `tasks_ready`, `tasks_waiting`,
`actors_waiting` and `workers` from (`src/morca/_internal/ec2.mojo:1171-1207`).
A nonzero exit means the head isn't up yet, or has gone. `dista-drain` asks
the head to drain a worker, and exits 1 with the error if it can't
(`src/morca/_internal/ec2.mojo:1223-1236`). Both are killed after 10 s.

A second implementation without dista tasks (#521 rules dista out of Rust
steps) needs neither.

### No arguments, `DISTA_ROLE` set

A pipeline with dista tasks is also its own dista head and worker. With
`DISTA_ROLE` set, the binary serves as that role and exits, whatever its
arguments (`src/morca/_cli.mojo:130-132`). The runners start it with
`DISTA_ROLE=head` or `worker` and `DISTA_PORT`, `DISTA_HEAD`,
`DISTA_ADVERTISE`, `DISTA_TOKEN`, `DISTA_WORKER_SLOTS`
(`src/morca/_internal/worker_cluster.mojo:39-87`,
`src/morca/_internal/ec2.mojo:799-830`, `src/morca/_internal/kube.mojo:327-366`).
Only for a pipeline whose describe lists `tasks`.

## `describe` and the registry hash

`describe` prints one JSON object (`src/morca/pipeline.mojo:234-314`). The
registration parses it and keeps it as `orca.pipelines.describe` (jsonb), and
the scheduler and UI read it there with SQL, so key order and whitespace
don't matter. A field morca doesn't know is kept and ignored, so a new
optional field never breaks an older scheduler.

morca before 0.35.0 checked two things in the text instead: the prefix
`{"pipeline": ` and the `"morca": "<version>"` key, found by searching from
the end. morca-mojo binaries keep both (`pipeline` first, `morca` last), so
older schedulers still register them.

An example, from a test's stand-in binary (`tests/fake_sensor:10`):

```json
{"pipeline": "fake_sensor", "registry_hash": "0x5e45e",
 "partitions": {"kind": "monthly", "start": null},
 "schedule": null, "max_runs": 1, "run_retries": 0, "sensor": true,
 "keys_per_run": 1, "workers": 2,
 "steps": [{"name": "load", "kind": "mapped", "after": null, "function": "load",
            "input": "morca.month.Month", "output": "Int",
            "reads": ["raw.a", "raw.b"], "writes": ["lake.ab"]}],
 "tasks": [], "source": {"repo": "", "commit": "", "dirty": false},
 "protocol": 1, "morca": "0.34.0"}
```

| Field | Written at | Read by | Default when absent |
|---|---|---|---|
| `pipeline` | `pipeline.mojo:242` | the registration's name (`db/registering.mojo:114`) | required |
| `registry_hash` | `pipeline.mojo:243` | the registration's code; compared with each run's (`db/registering.mojo:115`, `db/scheduler.mojo:205`, `:251-255`) | required |
| `partitions.kind` | `pipeline.mojo:244` | `monthly`, `weekly`, `daily`, `hourly` or `keyed`: how the scheduler makes keys (`db/registered.mojo:83`) | `monthly` |
| `partitions.start` | `pipeline.mojo:245-248` | the first key a fill covers (`db/registered.mojo:84`) | none |
| `partitions.dataset`, `.column` | `pipeline.mojo:249-251`, keyed only | the keys dataset, sensed and shown (`db/registered.mojo:93`, `db/sensing.mojo:32`) | none |
| `schedule` | `pipeline.mojo:252-263` | `cron`, `tz`, `fire` (`previous` or `current`: the partition each fire runs), `catchup` (`db/registered.mojo:79-83`); `null` for none. `fills` repeats `fire` for one release, for older schedulers, which read only `fills`; the scheduler reads `fire`, then `fills` (#370) | none; `fire` defaults to `previous` |
| `max_runs` | `pipeline.mojo:264` | runs at once, unless morca.toml says (`db/registered.mojo:85`) | 1 |
| `run_retries` | `pipeline.mojo:265` | starts of a run after a failure (`db/registered.mojo:87`) | 3 |
| `retry_seconds`, `max_retry_seconds` | `pipeline.mojo:267-270`, only when set | the backoff between run retries (`db/registered.mojo:88-89`) | 0 |
| `sensor` | `pipeline.mojo:271` | whether `sense` is polled (`db/registered.mojo:90`) | false |
| `keys_per_run` | `pipeline.mojo:272` | keys a queued run covers (`db/registered.mojo:92`) | 1 |
| `workers` | `pipeline.mojo:273` | EC2 workers for a pipeline with tasks (`db/registered.mojo:95-96`) | 2 |
| `steps[]` | `pipeline.mojo:274-301` | see below | required |
| `tasks` | `pipeline.mojo:302-305` | dista task names; non-empty means the run gets a cluster (`db/registered.mojo:95`, `db/config_show.mojo:13`) | `[]` |
| `source` | `pipeline.mojo:306-308` | `repo`, `commit`, `dirty`: the row of `orca.pipeline_versions` (`db/runs.mojo:50-86`), and whether a run is [outdated](#the-stop-notice-a-newer-version-leads) | empty |
| `protocol` | `pipeline.mojo:311` | the version of this protocol the binary speaks, checked at registration ([Versions](#versions)) | not checked |
| `morca` | `pipeline.mojo:312` | the morca-mojo it was built with, checked at registration; only for binaries built with morca-mojo ([Versions](#versions)) | not checked |

Paths in the table are under `src/morca/` and `src/morca/_internal/`.

Each element of `steps`, in run order:

| Field | Read by |
|---|---|
| `name` | step rows, the UI, fills, lineage (`db/queueing.mojo:233`, `db/lineage.mojo:168`) |
| `kind` | `mapped` (once per partition) or `gather` (once per run); a key counts as done when every mapped step succeeded for it (`db/queueing.mojo:148-156`) |
| `after` | the step it follows, or `null` for the first; the UI's graph |
| `function`, `input`, `output` | shown in the UI only (`ui/step_cards.mojo:266-273`) (**incidental** values: Mojo type and linkage names) |
| `timeout_seconds` | only when set; shown in the UI. The binary enforces it ([Timeouts](#timeouts-and-a-cancel-that-ran-out)) |
| `version` | only when set; the run's data version (`migrations.mojo:9-23`), so a fill redoes keys made at another version |
| `reads`, `writes` | dataset names `ns.table`. `writes` includes `replaces`. Used for sensing, lineage, cycles at registration and appending writes (`db/sensing.mojo:28-33`, `registering.mojo:90`, `db/queueing.mojo:231-237`) |
| `replaces` | only when non-empty: datasets whose partitions a rerun replaces instead of appending to (`db/queueing.mojo:231-237`) |

### The registry hash

`registry_hash` names the DAG's code. **What's contract** is how it's used:

- It's a string. The scheduler takes it from describe at registration
  (`src/morca/_internal/db/registering.mojo:115`) and compares it as text
  with each run's `registry_hash`. It never computes one itself.
- A binary must report the same hash in `describe` as it uses at `resume`
  and in its attempt rows. `resume` refuses a run whose hash isn't the
  binary's, unless given `--allow-new-code` (`src/morca/_cli.mojo:390-400`).
- Two builds with the same DAG should have the same hash, and a change to
  the DAG should change it. The scheduler treats runs of another hash as
  other code: it doesn't start them unless they allow new code
  (`src/morca/_internal/db/scheduler.mojo:205`), fails queued ones
  (`:241-255`), and counts a key done only under the hash it was made with
  or a data version that matches (`src/morca/_internal/db/queueing.mojo:148-156`).
- It goes into `orca.code` on every commit ([Summary keys](#summary-keys)).

**What's incidental** is how the Mojo binary computes it
(`src/morca/pipeline.mojo:190-232`): the 64-bit FNV-1a
(`dista.task.fnv1a64`) of a text with the pipeline's name, then for each
step its name, kind, upstream, function, `reads`/`writes` datasets and
`version`, then its dista tasks, its partition kind and a keyed pipeline's
dataset and column, printed with Mojo's `hex()` (`0x` and lower-case
digits, no padding). A Rust implementation may hash differently: a pipeline
moved from Mojo to Rust is new code either way, since its `function`s
differ.

## Environment

The local and control runners pass their own environment through and add to
it (`src/morca/_internal/proc.mojo:41`). The others build it
(`src/morca/_internal/worker.mojo:255-269`, the EC2 user data at
`src/morca/_internal/ec2.mojo:396-435`, the Job at
`src/morca/_internal/kube.mojo:122-140`, `:268-283`). The pipeline's own
`env` from morca.toml is added on every runner.

| Variable | Set by | What the binary does with it |
|---|---|---|
| `MORCA_DATABASE_URL` | local, control: inherited; EC2: `MORCA_EC2_DATABASE_URL` or the scheduler's; kubernetes: from a secret | The run store: `postgres://...`, or `sqlite:<path>` (`sqlite:///abs/path` for an absolute one) for SQLite (`src/morca/_cli.mojo:153`, `:19-22`). Never set on a worker (`src/morca/_internal/worker.mojo:34-35`). |
| `MORCA_STATE_URL`, `MORCA_STATE_TOKEN` | the worker (`worker.mojo:264-266`) | The run store over the UI's worker API ([HTTP store](#the-http-store)). With it, `run` is refused and `resume`, `status <run>` and `keep-log` use the API. |
| `MORCA_RUN` | the worker (`worker.mojo:269`); EC2 for `keep-log` (`ec2.mojo:852`) | The run whose attempts `keep-log` fails on a crash (`src/morca/_cli.mojo:180`). Not set for a local `resume`: the run is in `argv`. |
| `MORCA_STALE_SECONDS` | inherited, copied to EC2 and kubernetes (`ec2.mojo:167-174`, `kube.mojo:268-283`) | The stale limit (default 30): claim, heartbeat interval, fence and DB retry (`src/morca/_cli.mojo:517-522`). Must be the scheduler's value. |
| `MORCA_DB_RETRY_SECONDS` | the operator | How long store calls for the owned run are retried; default `MORCA_STALE_SECONDS` (`src/morca/_internal/store.mojo:138-150`). |
| `MORCA_WAREHOUSE` | inherited, copied to EC2 | The table root ([The warehouse](#the-warehouse)); `sense` needs it. |
| `MORCA_LOGS` | inherited, copied to EC2 | Where attempt logs go, a directory or object storage ([Logs](#logs)). Without it nothing is logged to files. |
| `MORCA_LOG_STAGE` | inherited | Where a log bound for object storage is written first; default `$TMPDIR/morca-logs` (`src/morca/_internal/logs.mojo:104-114`). |
| `MORCA_IMAGE` | control (`control.mojo:209`), worker (`worker.mojo:263`), EC2, kubernetes | Recorded with the run's version (`src/morca/_cli.mojo:367`, `:404`). |
| `MORCA_GRANT_CPUS`, `MORCA_GRANT_MEMORY_MB` | every runner, when greater than 0 (`resources.mojo:505-515`) | What this start of the run was granted. The binary sizes its own parallelism from it (`src/morca/_internal/resources.mojo:319-325`, `:518-535`). **Incidental** use; the grant is enforced outside the binary (cgroups, memory kills). |
| `MORCA_MEMORY_PRESSURE_FILE` | every runner (`pressure.mojo:476-482`) | The PSI file steps read memory pressure from (`src/morca/_internal/pressure.mojo:179`, `:294`). **Incidental**. |
| `MORCA_SECRETS` | every runner with secrets (`control.mojo:214-225`) | Comma-separated names of variables that hold secrets; their values are set beside it. The binary masks those values in every log it writes (`src/morca/_internal/logs.mojo:37-57`). |
| `MORCA_WORKER_PID` | the worker (`worker.mojo:267`) | The worker that started the process. The heartbeat exits the process once that isn't its parent any more (`src/morca/_internal/http_store.mojo:425-456`). |
| `MORCA_WORKERS` | control (`control.mojo:207`) | Local dista workers a run forks (default 4) (`src/morca/tasks.mojo:194-202`). Dista only. |
| `MORCA_HEAD_WAIT_SECONDS` | copied to EC2 | How long the driver waits for its dista head (default 300) (`src/morca/tasks.mojo:146-150`). Dista only. |
| `DISTA_ROLE`, `DISTA_HEAD`, `DISTA_PORT`, `DISTA_TOKEN`, ... | the runners, for a pipeline with tasks | See [No arguments](#no-arguments-dista_role-set). |
| `MORCA_SAMPLE_SECONDS` | copied to EC2 and kubernetes | `sample`'s interval (default 5). |

The Mojo binary also reads a few variables of its own (**incidental**):
`MORCA_DATA_CACHE*` (`src/morca/_lake/datacache.mojo:206-214`),
`MORCA_ZONEINFO` (`src/morca/tz.mojo:266`), `MORCA_NOW` (a test clock,
`src/morca/civil.mojo:134`), and the `AWS_*` variables for object storage.

## The run store

A pipeline binary records its run in one of four stores, all implementing
the `RunStore` trait (`src/morca/_internal/store.mojo:341-458`, built on
`Store` at `:271-338`):

| Store | When | Code |
|---|---|---|
| `PgStore` | `MORCA_DATABASE_URL=postgres://...` | `src/morca/_internal/state.mojo`, SQL in `db/runs.mojo` and `db/steps.mojo` |
| `SqliteStore` | `MORCA_DATABASE_URL=sqlite:...` | `src/morca/_internal/sqlite_store.mojo`, SQL in `db/sqlite_runs.mojo` |
| `HttpStore` | `MORCA_STATE_URL` | `src/morca/_internal/http_store.mojo` |
| `MemoryStore` | neither, `run` only | `src/morca/_internal/store.mojo:509-882` |

The rules are stated below in terms of `RunStore`'s methods, with
`PgStore`'s SQL as the reference. The Postgres schema is `orca`; SQLite has
the same tables without the prefix, with times as Unix seconds, booleans as
integers and byte columns as lower-case hex text
(`src/morca/_internal/db/sqlite_schema.mojo:16-110`,
`src/morca/_internal/db/sqlite_runs.mojo:1-88`).

### Statuses and identity

- Run and step statuses are the strings `running`, `succeeded`, `failed`,
  `skipped`, `deferred` and `cancelled` (`src/morca/_internal/store.mojo:24-31`).
  The scheduler also writes `queued`. A binary writes no other status.
- A process's owner name is `<hostname>:<pid>` (`process_owner`,
  `src/morca/_internal/store.mojo:194-202`). It goes into `runs.owner` and
  `attempts.host`. **Contract** that it's unique per live process and isn't
  `scheduler`, which the scheduler uses for a run it started and nobody has
  claimed yet; the format is **incidental**.

### The rows a binary writes

Only the columns a pipeline binary reads or writes
(`src/morca/_internal/migrations.mojo`):

- **`orca.pipelines`** (`:52-57`): `name`, `registry_hash`, `describe`, and
  `binary_path`, set only by `morca register` (`:106`). The binary writes a
  row only from `run`, for an unregistered pipeline.
- **`orca.pipeline_versions`** (`:227-238`): one row per `(pipeline,
  registry_hash, source, commit_sha, dirty, image)`, with `data_version`.
- **`orca.runs`** (`:58-69` and later): `id`, `pipeline`, `registry_hash`,
  `partitions` (the keys, comma-joined), `trigger`, `status`, `owner`,
  `heartbeat`, `started`, `ended`, `error`, `version`, `retry_at`,
  `deferrals`, `cancel_requested`, `cancel_at`, `token` (a UUID made by the
  database, `:729-741`).
- **`orca.steps`** (`:70-80`): `run`, `step`, `partition` (empty for a gather
  step), `ord` (the step's index in describe's `steps`), `status`, `input`
  and `output` (bytes), `error`; unique on `(run, step, partition)`.
- **`orca.attempts`** (`:81-92`): `step` (the step row's ID), `attempt`
  (1, 2, ... per step row), `status`, `host`, `registry_hash`, `started`,
  `ended`, `error`, `log`; unique on `(step, attempt)`.
- **`orca.reads`** and **`orca.commits`** (`:93-100`, `:138-139`):
  `attempt` (the attempt row's ID), `table_name` (the table's location),
  `snapshot_id`, `dataset` (`ns.table`, or null for a table outside the
  warehouse).

The usage columns of attempts (peak memory, CPU) are written by the runners
and the UI, not by the binary.

### Methods

Each method of the trait, what it does and the SQL it runs in `PgStore`.
Paths are under `src/morca/_internal/`.

| Method | Effect | Reference |
|---|---|---|
| `migrate()` | brings the schema up to date; see [Migrations](#migrations) | `state.mojo:103-135` |
| `register(pipeline, hash, describe)` | upserts `orca.pipelines` (name, hash, describe), then records a version | `db/runs.mojo:18-34`, `state.mojo:137-148` |
| `scheduled_hash(pipeline)` | the registered hash, or empty if no binary is registered: `SELECT registry_hash FROM orca.pipelines WHERE name=$1 AND binary_path IS NOT NULL` | `db/runs.mojo:37-47` |
| `version(pipeline, hash, describe, image)` | upserts the `pipeline_versions` row from describe's `source` and the steps' `version`s; returns its ID | `db/runs.mojo:50-86` |
| `ran_version(run, version)` | `UPDATE orca.runs SET version=$2 WHERE id=$1` | `db/runs.mojo:92-97` |
| `create_run(pipeline, hash, keys, trigger, owner)` | inserts a run, already `running`, owned and beating | `db/runs.mojo:100-126` |
| `run_info(run)` | pipeline, hash, partitions, status, owner, error | `db/runs.mojo:129-150` |
| `claim(run, owner, stale)` | see [Claiming](#claiming) | `db/runs.mojo:153-169`, `state.mojo:192-217` |
| `interrupt(run, why="")` | see [Interrupting](#interrupting) | `db/steps.mojo:15-38`, `state.mojo:219-232` |
| `prior(run)` | the run's succeeded steps with their outputs: `SELECT step, partition, output FROM orca.steps WHERE run=$1 AND status='succeeded'` | `db/steps.mojo:65-79` |
| `own(run, owner, hash)` | no SQL: says which run and owner the calls below are for | `state.mojo:484-487` |
| `start_heartbeat(interval, timeouts)`, `stop_heartbeat()` | see [Heartbeat](#heartbeat) | `heartbeat.mojo` |
| `start_attempt(step, partition, ord, input)` | in one transaction: the [ownership check](#ownership-at-every-step) (cancel counts), upsert the step row `running` with its input, insert attempt `max+1` `running`; returns the attempt number | `state.mojo:568-583`, `db/steps.mojo:119-184` |
| `set_log(step, partition, attempt, location)` | `UPDATE orca.attempts SET log=$2 WHERE id=$1` | `db/steps.mojo:272-277` |
| `finish_attempt(step, partition, attempt, status, output, error)` | in one transaction: the ownership check (cancel doesn't count), the attempt's status, `ended` and error, then the step's status, error and output (kept only for `succeeded`) | `state.mojo:700-714`, `db/steps.mojo:204-243` |
| `skip(step, partition, ord, reason)` | upserts the step row `skipped` with the reason, no attempt; ownership-checked (cancel counts) | `db/steps.mojo:246-269` |
| `pinned_reads(step, partition)` | see [Pinned reads](#pinned-reads) | `db/steps.mojo:280-298` |
| `run_token()` | `SELECT coalesce(token::text,'') FROM orca.runs WHERE id=$1` | `db/runs.mojo:245-256` |
| `record(commit, table_snapshot)` | inserts into `orca.commits` or `orca.reads` for the current attempt; not ownership-checked | `db/steps.mojo:301-319`, `state.mojo:608-610` |
| `fence()` | see [Fencing a commit](#fencing-a-commit) | `db/runs.mojo:259-272`, `state.mojo:626-666` |
| `cancel_requested()` | `SELECT cancel_requested FROM orca.runs WHERE id=$1` | `db/runs.mojo:201-210` |
| `finish_run(status)` | `UPDATE orca.runs SET status=$2, ended=now(), heartbeat=NULL WHERE id=$1 AND owner=$3` | `db/runs.mojo:172-183` |
| `defer_run(until)` | `... SET status='deferred', ended=now(), heartbeat=NULL, retry_at=$3, deferrals=deferrals+1 WHERE id=$1 AND owner=$2` | `db/runs.mojo:186-198` |
| `steps(run)`, `runs(limit, before, status)` | listings for `status` (**incidental**) | `db/steps.mojo:82-116`, `db/runs.mojo:213-242` |

### Claiming

A process may claim a run that is `queued`, `failed`, `deferred`, or
`running` with a heartbeat that is null or older than the stale limit. The
check and the takeover are one guarded update, so two processes can't both
win (`src/morca/_internal/db/runs.mojo:153-169`):

```sql
UPDATE orca.runs SET status = 'running', owner = $2, heartbeat = now(),
       ended = NULL, error = NULL
 WHERE id = $1 AND status IN ('queued', 'running', 'failed', 'deferred')
   AND (heartbeat IS NULL OR heartbeat < now() - make_interval(secs => $3))
RETURNING id
```

The scheduler starts a run with a null heartbeat, so the process it starts
can claim it at once. A claim that updates nothing raises, saying the run's
status or who holds it (`src/morca/_internal/state.mojo:192-217`), and
`resume` exits 3. The scheduler then fails the run, because nobody claimed
it ([Exit codes](#exit-codes)).

### Interrupting

Right after claiming, `resume` interrupts what an earlier process left
running, in one transaction (`src/morca/_internal/db/steps.mojo:15-38`):
every `running` attempt of the run becomes `failed` with `ended = now()` and
the error `why`, or `interrupted: the process running it stopped`
(`src/morca/_internal/store.mojo:33`); every `running` step becomes
`failed` with `why`, or `interrupted`. It returns how many attempts it
failed. `keep-log` and the runners call it too, with a crash's summary as
`why`.

### Heartbeat

While it runs steps, the owner beats on a thread of its own, with its own
connection (`src/morca/_internal/heartbeat.mojo:59-70`), every
`MORCA_STALE_SECONDS / 5` seconds (`src/morca/_internal/heartbeat.mojo:101-103`;
6 s by default). A failed beat drops the connection and tries again on the
next one. Each beat (`src/morca/_internal/state.mojo:361-376`):

1. refreshes the heartbeat if this process still owns the run running:
   `UPDATE orca.runs SET heartbeat = now() WHERE id = $1 AND owner = $2 AND
   status = 'running'` (`src/morca/_internal/db/runs.mojo:290-298`);
2. runs the [watchdog query](#timeouts-and-a-cancel-that-ran-out) and, if it
   finds something, stops the process;
3. asks whether the run is [outdated](#the-stop-notice-a-newer-version-leads).

A run whose heartbeat is older than `MORCA_STALE_SECONDS` is dead to the
scheduler: it kills a process of its own whose run went stale, and restarts
or fails the run (`src/morca/_internal/scheduler.mojo:1193-1235`). So the
heartbeat must keep going while a step runs, however long the step takes.

### Ownership at every step

`start_attempt`, `skip` and `finish_attempt` each run, in their own
transaction (`src/morca/_internal/db/runs.mojo:275-287`):

```sql
UPDATE orca.runs SET heartbeat = now()
 WHERE id = $1 AND owner = $2 AND status = 'running'
RETURNING cancel_requested
```

No row means another process took the run (or it ended): the call raises
`morca: lost run <run> to another process; stopping`, and the binary stops
without writing more. For `start_attempt` and `skip`, `cancel_requested`
true raises `morca: run <run> was cancelled; stopping`
(`src/morca/_internal/state.mojo:541-552`). `finish_attempt` doesn't look at
the cancel, so an attempt that ran is still recorded.

These two errors start with `\x1f` (`FINAL`,
`src/morca/_internal/store.mojo:133`), which tells the retry loop not to
retry them (**incidental** mechanism).

### Fencing a commit

Before each commit to a table, the binary checks that it may still commit
(`Ctx.fence`, `src/morca/ctx.mojo:162-165`, called from
`src/morca/_lake/impl.mojo:908`, `:966`, `:1291`):

```sql
SELECT coalesce(owner, '') AS owner, status,
       coalesce(heartbeat > now() - make_interval(secs => $2), false) AS fresh
  FROM orca.runs WHERE id = $1
```

with `$2 = MORCA_STALE_SECONDS / 2` (`src/morca/_internal/db/runs.mojo:259-272`).
It commits only if the owner is this process, the status is `running` and
the heartbeat is fresh. Otherwise it raises `morca: not committing: ...`,
which fails the attempt. A database it can't reach is retried for at most
half the stale limit, then the commit is refused too
(`src/morca/_internal/state.mojo:626-666`). The half is what makes the fence
safe: another process can only claim the run once its heartbeat is a whole
stale limit old.

### Cancelling

A user's cancel sets `cancel_requested`. A run that isn't running becomes
`cancelled` at once. A running one gets `cancel_at = now() +
MORCA_CANCEL_KILL_SECONDS` (default 60) and keeps running
(`src/morca/_internal/db/actions.mojo:10-23`, `src/morca/_internal/actions.mojo:64-71`).
The binary notices in two ways:

- **Between attempts.** The next `start_attempt` or `skip` raises the cancel
  error. The executor then checks `cancel_requested()`, ends the run with
  `finish_run('cancelled')`, prints `run cancelled` and exits 1
  (`src/morca/_cli.mojo:547-556`). If the run wasn't asked to cancel, the
  error is raised, `resume` exits 3, and the run stays `running` until its
  heartbeat goes stale.
- **During an attempt**, once `cancel_at` has passed: the heartbeat's
  watchdog query finds it ([below](#timeouts-and-a-cancel-that-ran-out)).

### Timeouts, and a cancel that ran out

The heartbeat is given the steps' timeouts as `step=seconds,...`
(`src/morca/pipeline.mojo:313-325`, `src/morca/_cli.mojo:545`). Each beat
runs one query for a cancel that's due and for a running attempt older than
its step's timeout (`src/morca/_internal/db/runs.mojo:317-328`). If it finds
one, in one transaction (`src/morca/_internal/state.mojo:290-326`):

- a **timeout** fails that attempt and its step (`timed out after N s
  (timeout_seconds), so its process was stopped`) and fails the run with
  that error;
- a **due cancel** fails every running attempt and step, and sets the run
  `cancelled` with a null heartbeat (`src/morca/_internal/db/runs.mojo:363-371`);
- either adds an `orca.audit` row (`'orca', 'stop', run, detail`,
  `src/morca/_internal/db/runs.mojo:374-382`),

and then the process exits at once with `_exit(1)`
(`src/morca/_internal/state.mojo:367-369`). The step isn't asked to stop: the
process ends.

Over SQLite the beat handles timeouts but not cancels
(`src/morca/_internal/sqlite_store.mojo:111-160`); a SQLite run is cancelled
only between attempts. A `MemoryStore` run has no heartbeat.

### The stop notice: a newer version leads

morca never stops a long run for a deploy. Instead each beat asks whether the
run is **outdated** (`src/morca/_internal/handover.mojo:1-42`,
`src/morca/_internal/db/handover.mojo`): its status is `running`, and either

- the pipeline is now registered with other code (the run's
  `orca.pipeline_versions` row and the pipeline's differ in registry hash,
  source commit or dirtiness), or
- the scheduler instance holding the run drains: a newer one leads, or it
  was asked to (`draining_sql`, [overlap.md](overlap.md)).

The answer is kept in an atomic the steps read through `morca.outdated()`.
What a step does with it is up to the step; by default nothing happens. A
Rust step's stop flag is set from it (`src/morca/rust_step.mojo:58-70`).
Not knowing keeps the last answer and never stops the beat
(`src/morca/_internal/state.mojo:370-376`). Over SQLite, and in memory,
a run is never outdated.

**Contract**: the query is the scheduler's (the schema and
`outdated_sql`); a second implementation should run the same query, or
receive the same fields over HTTP, and give its steps the same flag.
Honouring it is up to each step.

### Retrying the database

Every `PgStore` call for the owned run (start, finish, skip, pinned reads,
run token, record, set log, finish run, defer run, cancel requested) is
retried on a new connection for `MORCA_DB_RETRY_SECONDS`, waiting 0.25 s and
doubling up to 4 s (`DbRetry`, `src/morca/_internal/state.mojo:272-287`;
`Backoff`, `src/morca/_internal/store.mojo:153-191`). `FINAL` errors aren't
retried. The calls before the run is owned (migrate, register, claim) are
made once. The length of the budget is **incidental**; that a database blip
shorter than the stale limit doesn't fail a run is what users rely on.

### Executing

What `_execute` does once the run is claimed (`src/morca/_cli.mojo:525-578`,
`src/morca/pipeline.mojo:390-463` and `:451-591`):

1. `own`, then start the heartbeat.
2. For each step in describe order, for each key for a mapped step or once
   for a gather step:
   - skip it with no store call if `prior` holds it `succeeded`
     (`src/morca/pipeline.mojo:466-470`);
   - if its upstream didn't succeed, `skip` it with `not run: <step>
     [<key>] didn't succeed` (`:468-473`);
   - else read `pinned_reads` and `run_token` once, then for each try up to
     the step's retries, with a backoff that doubles: `start_attempt`,
     `set_log`, run the step, `finish_attempt` as `succeeded`, `failed`
     (and retry) or `deferred` (and stop retrying) (`:475-586`).
3. Stop the heartbeat. Then `defer_run(until)` if a step deferred and none
   failed, else `finish_run(outcome)`: `succeeded` if every step did, else
   `failed` (`src/morca/_cli.mojo:568-572`).
4. Print one line per step and partition, then `run <outcome>` or `run
   deferred until <time>Z` (`:573-577`). Nothing parses these lines
   (**incidental**), except that a runner shows a failed start's last line.
5. Exit 0 for `succeeded`, else 1.

A deferred step's error is `deferred until <time>Z: <why>`
(`src/morca/pipeline.mojo:563-589`), and the run's `retry_at` is when the
scheduler starts it again.

If a store call raises (the database stayed away, or the run was lost), the
binary exits 3 and leaves the run `running`; once its heartbeat is stale the
scheduler resumes or fails it (`src/morca/_cli.mojo:535-543`).

### Migrations

The Mojo binary runs `migrate()` before `run`, `resume` and `status`
(`src/morca/_cli.mojo:342`, `:379`, `:430`): under an advisory lock, it
applies the migrations it knows that the database hasn't had, and runs on a
database that's ahead of it when the newer migrations are additive
(`src/morca/_internal/state.mojo:103-135`). **Incidental** for a second
implementation: the schema is morca's, and the scheduler migrates it at
start. A second implementation should check that the schema has every
column it uses rather than migrate it.

### The HTTP store

A run on a remote worker records itself over the UI's API
(`src/morca/_internal/http_store.mojo`; [workers.md](workers.md)). Each call
is `POST <MORCA_STATE_URL>/api/worker/store/<call>` with a JSON body and
`Authorization: Bearer <MORCA_STATE_TOKEN>` (`:58`, `:355-381`). The URL
must be `https`, or `http` to localhost (`:306-324`). Byte strings travel as
hex (`:65-95`). The server runs the same `PgStore` code
(`src/morca/_internal/workers.mojo:854-991`), so every rule above holds.

- The calls are `run_info`, `claim`, `version`, `ran_version`, `interrupt`,
  `prior`, `steps`, `start_attempt`, `finish_attempt`, `skip`,
  `pinned_reads`, `run_token`, `record`, `fence`, `set_log`, `finish_run`,
  `defer_run`, `cancel_requested` and `beat`. `register`,
  `scheduled_hash`, `create_run` and `runs` aren't available, and
  `migrate` does nothing (`src/morca/_internal/http_store.mojo:505-590`).
- 401, 403, and 409 (a lost or cancelled run, or `not committing`) are final.
  Other failures are retried for `MORCA_DB_RETRY_SECONDS`.
- `beat` sends the timeouts and answers with `stop`, which, when non-empty,
  makes the process exit 1, and the outdated fields (`:425-456`).

Each call's exact body is in `http_store.mojo`; the conformance suite should
pin them.

## Tables

### The warehouse

`MORCA_WAREHOUSE` is the root of a filesystem catalog: dataset `ns.table`
is the Iceberg table at `<warehouse>/ns/table`, a local directory, `file://`
or object storage such as `s3://bucket/warehouse`
(`src/morca/tables/__init__.mojo:27-32`, `src/morca/_internal/warehouse.mojo:1-15`).
There is no REST catalog. A table's current metadata file is
`version-hint.text`'s, else the highest-numbered `v<N>.metadata.json` or
`<N>-<uuid>.metadata.json` (`src/morca/_internal/warehouse.mojo:87-119`).
The scheduler's own readers (the UI's data views, `morca_maintain`) use the
same layout, so a second implementation must write tables where and as they
look.

### Datasets

A step declares the datasets it reads and writes, and those are what
describe lists. The Mojo binary refuses, at run time, a read or a commit of a
warehouse table the step didn't declare (`src/morca/ctx.mojo:184-200`).
**Contract** that what a step reads and writes is what describe says: the
scheduler's sensors, lineage and fills depend on it.

### Summary keys

Every commit a step makes carries these snapshot summary properties
(`Ctx.summary`, `src/morca/ctx.mojo:202-226`; passed to every commit at
`src/morca/_lake/impl.mojo:905`, `:961`, `:1268`):

| Key | Value | Read by |
|---|---|---|
| `orca.pipeline` | the pipeline's name | `find_commit` (`ctx.mojo:258`) |
| `orca.run` | the run's ID in decimal | `find_commit`; its presence marks a snapshot as morca's for `sense` (`src/morca/_internal/warehouse.mojo:158-163`); the UI's snapshot list (`src/morca/_lake/dataread.mojo:142`) |
| `orca.step` | the step's name | `find_commit` |
| `orca.partition` | the step's partition key; empty for a gather step | `find_commit` |
| `orca.partitions` | the keys the commit holds, comma-joined: the partition for a mapped step, the run's keys for a gather step | `sense`'s fourth column, so a sensor downstream knows which keys to run; the UI (`dataread.mojo:144`) |
| `orca.commit` | how many commits this attempt made to this table before this one, in decimal: `0` for the first | `find_commit` |
| `orca.attempt` | the attempt number | nothing (**incidental**) |
| `orca.code` | the registry hash | nothing (**incidental**) |
| `orca.reads` | every table read so far, `<location>@<snapshot>,...` | nothing; lineage is in `orca.reads` (**incidental**) |
| `orca.run-token` | the run's token, when it has one | `find_commit` |

A replace also writes `orca.replaced-files` and `orca.replaced-records`
(`src/morca/_lake/impl.mojo:1269-1270`), which nothing reads
(**incidental**). The keys keep the `orca.` prefix through the morca rename
(#384), since tables already carry them.

### Recording reads and commits

Each read and each commit is recorded as it happens, through `record`
(`src/morca/_internal/store.mojo:233-268`), with the table's location, the
snapshot ID and the dataset. A read records the snapshot the step scanned;
a commit records the snapshot it made, or the one it found it had made.
**Contract**: the scheduler uses `orca.commits` to sense other pipelines'
commits to the datasets a sensor reads (`src/morca/_internal/db/sensing.mojo:20-48`),
and the UI shows lineage from both.

### Finding an earlier attempt's commit

A retry, or a resume after a crash, must not commit again what an earlier
attempt of the same run already committed. Before every commit, the Mojo
binary reloads the table and looks for a snapshot this commit would be
(`_found`, `src/morca/_lake/impl.mojo:787-799`; `find_commit`, `:406-418`):
the first snapshot whose summary has (`Ctx.made`, `src/morca/ctx.mojo:241-265`)

- `orca.pipeline`, `orca.run`, `orca.step` and `orca.partition` equal to this
  step's, and `orca.commit` equal to the number of commits this attempt has
  made to this table so far, each **present** (a missing key doesn't match an
  empty value), and
- `orca.run-token` equal to the run's, unless either has none
  (`src/morca/ctx.mojo:267-275`).

`orca.attempt` isn't compared, so any attempt's commit matches. If one
matches, the binary records it as this attempt's commit and doesn't write.
A run numbered 0 or below (in memory) never matches. A step that writes
data files before committing them calls `find_commit` first, so its retry
doesn't write the files again (`src/morca/tables/__init__.mojo:53-71`).

The run token is what keeps two databases over the same tables, or a
database restored from a backup, from taking each other's commits for their
own (#292).

### Pinned reads

Every attempt of a step reads the snapshots the first attempt read, so a
retry or a resume sees the same data:

- `pinned_reads(step, partition)` returns, for each table, the snapshot an
  attempt of this run's step and partition read; reads are ordered newest
  attempt first and folded so the earliest attempt's wins
  (`src/morca/_internal/db/steps.mojo:280-298`). It's read once per step
  and partition (`src/morca/pipeline.mojo:501`).
- When the step scans a table, it reads the snapshot it already read in
  this attempt, else the pinned one, else the current one, and records that
  read (`Ctx.pin`, `src/morca/ctx.mojo:148-160`). A snapshot of `-1` pins a
  table as empty.
- A table first read by a later attempt is pinned for the attempts after it
  (`src/morca/pipeline.mojo:555-557`).

The table's key is its **location**, not its dataset name.

## Step inputs and outputs

Each step row keeps its input and, once it succeeds, its output, as bytes
(`orca.steps.input`, `orca.steps.output`). The Mojo binary encodes them
with dista's codec (`dista.codec.encode` and `decode`): a step decodes its
input, raising if bytes are left over, and appends its result's encoding to
its output (`src/morca/step.mojo:448-457`). The input of a first step is its
partition key's encoding, or a gather step's `Seq` of keys; a gather step
over a mapped one gets an `int64` count and the upstream outputs one after
the other (`src/morca/pipeline.mojo:421-459`).

Who reads them:

- **The same pipeline's binary, on resume.** `prior` hands it the outputs of
  the steps that succeeded, which become the next steps' inputs as they
  are; the executor doesn't decode them (`src/morca/pipeline.mojo:426-430`).
- **A rerun** copies a run's succeeded steps into a new run, bytes and all
  (`copy_steps`, `src/morca/_internal/db/actions.mojo:162-174`), and its
  process resumes from them.
- Nothing else. The UI shows the step's type names from describe, not its
  output, and the scheduler never decodes either column.

So the encoding is **incidental** to morca: only the pipeline's own code
reads it. It becomes contract between the builds of one pipeline, since a
resume or a rerun under new code (`--allow-new-code`) decodes outputs an
older build wrote. A pipeline rewritten in another language must therefore
read the old outputs, or not be resumed across the change.

### Partition keys

Keys are text the scheduler and the binary both make and parse, so their
format is **contract** for each partition kind: `monthly` `YYYY-MM`,
`weekly` `YYYY-Www`, `daily` `YYYY-MM-DD`, `hourly` `YYYY-MM-DDTHH`
(`src/morca/month.mojo:55`, `week.mojo:111`, `day.mojo:73`,
`hour.mojo:80`), and for `keyed` the names the keys dataset holds. The
scheduler queues runs with keys it computed from the schedule and describe's
`partitions` (`src/morca/_internal/sensing.mojo:380-420`), and `resume` parses
them from `runs.partitions` (`src/morca/_cli.mojo:422`). The same keys go
into `orca.steps.partition` and `orca.partition`.

## Logs

With `MORCA_LOGS` set, each attempt writes its log to
`<MORCA_LOGS>/<pipeline>/<run>/<step>/<partition or _run>/<attempt>.log`
(`src/morca/_internal/logs.mojo:96-133`) and records that location with
`set_log`. A location in object storage is written under `MORCA_LOG_STAGE`
first and copied when the attempt ends (`publish`, `:136-145`). The UI reads
whatever `attempts.log` names, so **contract** is that the location is
recorded and readable by morca; the layout is **incidental**, though the
run's directory, `<MORCA_LOGS>/<pipeline>/<run>`, is where runners put the
driver log and metrics (`driver.log`, `metrics/`, `timeline.json`).

## Versions

- **The protocol.** describe's `"protocol": <n>` is the version of **this
  protocol** the binary speaks; it is 1 (`PROTOCOL_VERSION`,
  `src/morca/_internal/version.mojo`). `morca register` refuses a binary
  whose `protocol` isn't an integer from 1 to the version it speaks,
  whatever `MORCA_MIXED_VERSIONS` says, and registers one without the key
  unchecked (#525). The version goes up only for a change an older binary
  can't follow; a new optional field or subcommand doesn't raise it.
- **`MORCA_VERSION`.** describe's last key, `"morca": "<version>"`, is the
  morca-mojo the binary was built with (`src/morca/pipeline.mojo:312`).
  `morca register` refuses a binary of another version unless
  `MORCA_MIXED_VERSIONS=1`, and registers one without the key unchecked
  (`src/morca/_internal/version.mojo`, [binaries.md](binaries.md#versions)).
  A binary not built with morca-mojo says `protocol` and leaves `morca` out.
- **Older schedulers.** morca before 0.35.0 reads neither `protocol` nor
  the JSON: it needs the bytes `{"pipeline": ` first, and checks the last
  `"morca": "<version>"` if there is one. A binary that must register with
  such a scheduler prints describe that way, and the `morca` of that
  scheduler.
- **The registry hash** says which DAG a run ran ([above](#the-registry-hash)).
- **The source.** describe's `source` (`repo`, `commit`, `dirty`) and
  `MORCA_IMAGE` make the run's version row, which the UI shows and the
  outdated check compares (`src/morca/_internal/db/runs.mojo:50-86`).
- **The schema.** An older binary runs on a newer schema as long as the
  newer migrations are additive (AGENTS.md, "Migrations"). A second
  implementation names its columns in every query, as morca does, so a new
  column never breaks it.

## Exit codes

What the binary returns (`src/morca/_cli.mojo:46-52`, `:127-145`):

| Code | Meaning |
|---|---|
| 0 | the command did its work; for `run` and `resume`, the run succeeded |
| 1 | the run failed, deferred or was cancelled; or the heartbeat stopped the process (a timeout, a cancel that ran out, `stop` from the UI); `pool-next`: shut down; `dista-drain`: couldn't |
| 2 | a usage error, a key that doesn't parse, `run` with code the scheduler wasn't given |
| 3 | any other error: the database, a claim refused, a run of another pipeline or code |

What the runners do with it:

- **For `resume`, 0, 1, 2 and 3 aren't outcomes.** The outcome is what the
  binary wrote to `orca.runs` (`src/morca/_internal/tick.mojo:58-81`).
- **A process that exits without claiming its run** (still `running`, owner
  `scheduler`, the same start) has the run failed with `its process (pid N)
  exited <code> before claiming it: <last line of its output>`
  (`src/morca/_internal/scheduler.mojo:902-928`,
  `src/morca/_internal/db/scheduler.mojo:124-136`). A worker reports the same
  through `/api/worker/exited`.
- **A crash**, an exit of 128 plus SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGFPE or
  SIGSEGV (`src/morca/_internal/crash.mojo:104-109`), has the run's running
  attempts interrupted with the crash's summary from the driver log
  (`src/morca/_internal/scheduler.mojo:942-970`).
- **Any other exit after a claim** is judged by the run row: a run left
  `running` goes stale and is restarted within `run_retries`, or failed
  (`src/morca/_internal/scheduler.mojo:1193-1235`,
  `src/morca/_internal/db/starting.mojo:229-236`).
- For `describe`, `sense`, `keys` and `dista-drain`, nonzero is an error that
  shows the output. For `keep-log`, it's logged.

## A first implementation

For `default` and `control` placement on Postgres or SQLite, with no dista
tasks, a pipeline binary needs:

1. `describe`: one JSON object with the fields above and `"protocol": 1`
   (no `morca`, unless it's built with morca-mojo).
2. `resume <run> [--allow-new-code]`: claim, version, interrupt, prior,
   execute with a heartbeat, ownership checks at every attempt, the commit
   fence, timeouts and cancels, and ending the run.
3. `sense` for a sensor pipeline and `keys` for a keyed one.
4. `keep-log`, for control runs and runs with secrets.
5. On every commit: the summary keys, `find_commit` before writing, reads
   and commits recorded, reads pinned.
6. The environment above, and the exit codes.

`MORCA_STATE_URL` (workers), `put-log`, the pool commands, the dista
commands and `DISTA_ROLE` come with the placements that need them.
