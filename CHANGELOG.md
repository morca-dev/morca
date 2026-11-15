# Changelog

## 0.33.0 - 2026-11-15

- **Data tab layout:** the table first, a commit picker at the top (searchable, in the URL), and Data/Schema tabs with column types under the headers. (#501)
- **morca ships prebuilt:** the package has `morca` and `morca_maintain` in `bin/`; `morca register` refuses pipelines built from another morca-mojo (`MORCA_MIXED_VERSIONS=1` warns). (#504)
- **Concurrency keys:** `concurrency = { key, limit }` in morca.toml caps runs across pipelines, schedulers and workers; a run waiting on an older version's run fails after `MORCA_HANDOVER_WAIT_SECONDS`, required once a key is declared. (#503)
- **Hetzner tools versioned on their own** (`deploy/hetzner/VERSION`, now 0.34.0), and deploys stop when the image needs newer tools; 0.33.0 images need 0.34.0. (#489, #494, #503)
- Docs: summary keys are `orca.*`, more public helpers listed, `workers=` explained. (#473)
- Faster pool and Hetzner tests; the runtime image is tagged on manifest lists too. (#491, #493)

## 0.32.0 - 2026-11-15

- **Faster Data tab:** manifests read once, in parallel, and cached on disk (`MORCA_DATA_CACHE`); a loading indicator on click. (#480)
- **Data tab on pipeline pages:** each dataset the pipeline writes, with its first rows. (#481)
- **Data view on a full disk:** the cache stops writing and shrinks below `MORCA_DATA_CACHE_MIN_FREE_MB`, rereads broken files, and `data.csv` answers 503 instead of crashing. (#484, #487)
- **Project images ship upgrade.toml** and CHANGELOG.md, so `deploy.sh` runs their upgrade steps. (#485)
- **`morca_maintain` on liblake (ABI 4):** expiry and the data view no longer compile iceberg. (#488)
- **Rust steps on liblake (ABI 5):** `morca.rust_step` no longer compiles iceberg. (#490)
- Hetzner test flake fixed. (#486)

## 0.31.0 - 2026-11-14

- **Reliable git download in image builds:** retries across three kernel.org mirrors, sha256 checked. (#470)
- **`morca backfill --dry-run`:** runs every check, writes nothing, and prints the plan or the refusal. (#475)

## 0.30.0 - 2026-11-14

- **Backfills as fills:** `morca backfill --rerun --as-fill` runs a big re-run in chunks, under the fill settings, and resumes across restarts; `--cancel` stops it. (#467)
- **Learned memory fits the host:** learned requests are capped at what the host can grant; `morca status` shows why runs wait, and a new watchdog rule, `unmet`, catches runs that can never start. (#463)
- **More of `morca.tables` on liblake:** a batch reader, typed partition values, schema lookup, row-group writing and `table_exists` (liblake ABI 3). (#466)

## 0.29.0 - 2026-11-14

- **liblake, the first lib-tin:** `morca.tables` runs in a prebuilt shared library shipped with the package, so pipelines no longer compile iceberg and parquet. Build batches with `morca.tables.BatchBuilder` instead of `iceberg.batch`; `-D MORCA_LAKE_SOURCE=1` builds the old way. (#457)
- **arrow-mlake 0.3.0**, with parquet 0.14.0, iceberg 0.12.0 and dista 0.5.1: field ids cross to liblake, and batches cross without copying. (#459)

## 0.28.0 - 2026-11-14

- **Pipeline priority:** `priority` in morca.toml orders starts across pipelines; new runs go before fills. (#433)
- **Runs yield the CPU** to the scheduler, UI and Postgres: a low `cpu.weight`, or `nice` without cgroups. (#451)
- **`morca retire <pipeline>`** stops a pipeline's runs; `morca register` brings it back. (#442)
- **Dataset Data tab:** schema, partitions, rows and a quick chart. (#438)
- **Parquet files from Rust workers** (`ctx.add_file`), committed with any streamed rows. (#429)
- **Pool machines follow deploys:** old-image machines drain and are replaced. (#444)
- **dista 0.5.0**, with `DISTA_WORKER_SLOTS = "auto"`. (#437)
- **json and flare as precompiled .mojoc** (json_mlake 0.5.1, flare_mlake 0.14.1, k8s-mojo 0.1.4). (#452, #456)
- **Fixes:** no deadlocks on runs (#443); shared upgrade steps run once (#441); a stopped scheduler ends its instance (#432); backup prune is best effort (#431); morca.toml in project images (#430); scheduler instances show their image (#439).
- **Faster CI:** test pipelines as one multi-call binary, fewer overlapping tests. (#448, #450)

## 0.27.0 - 2026-11-13

- **Steps in Rust:** `morca.rust_step` and the `morca-worker` crate (docs/rust-workers.md). (#422)
- **Hindcast example:** GFS forecast skill, with a Rust worker and Mojo steps. (#423)
- **Per-run cgroups on by default** on Hetzner; `CGROUPS=0` opts out. (#410)
- **Overlapping schedulers on by default.** Upgrading needs `DRAIN_SECONDS` in hetzner.env. (#411)
- **Distroless runtime image:** no bash or apt-get; install extras in a build stage. (#412)
- **A public API:** internal modules move to `morca._internal`. (#419)
- **All SQL in `morca.db`**, and no source file over 1,500 lines. (#363, #413, #415–#417)

## 0.26.0 - 2026-11-12

- **A stack's overlay on morca.toml**: a stack's own changes to the project's `morca.toml` (a dev stack's `fills`, a lab stack's pipelines) go in an overlay kept with the stack (`CONFIG_OVERLAY_FILE` in hetzner.env, `MORCA_CONFIG_OVERLAY`, `--overlay`), which deploy.sh sends and the image's morca checks before a deploy changes anything; `enabled = false` keeps a pipeline out of `morca register`, and `morca config show --file` prints the merged file. (#399)

- **Apps declare what they get in morca.toml**: an app's `[apps.<name>]` (port, check, env, `lake`, secrets, memory_gb) is what morca-stack gives it, in an env file of its own, instead of a fixed env with the UI's PostHog key; app secrets are `secrets/orca/<id>` keys in `SECRETS_FILE`, `APPS=console` needs no port, and `POSTHOG_HOST` (`MORCA_POSTHOG_HOST`) names the UI's analytics proxy, PostHog's own host without it. (#400)

- **Deploys don't wait for long runs:** a run can ask `morca.outdated()` (with `code_version()` and `desired_code_version()`) whether a newer version leads, and ends when its code decides, shown as outdated on its page and in `morca status`; an overlapping deploy returns once the new scheduler leads, the old one draining in the background with no limit unless `MORCA_DRAIN_SECONDS` is set. (#406)

## 0.25.1 - 2026-11-12

- **The commit is read at run time:** a pipeline built without `-D MORCA_COMMIT`/`-D MORCA_SOURCE` reads them from its environment, and the project Dockerfiles set them with `ENV` instead of compiling them in. A new commit no longer changes every program, so Mojo's compile cache can serve a rebuild. (census #153)

- **A wedged run keeps no process:** the scheduler fails, cancels or restarts a run whose heartbeat went stale only after it has killed and reaped the run's process, and its attempt says it was stopped for the stale heartbeat. (#398)

- **Cluster tests apart on one machine:** `MORCA_EC2_HEAD_PORT` (6390) sets the port of a run's dista head, which the tests set to one of their own; the stand-in clouds end an instance's processes with it. (#403)

## 0.25.0 - 2026-11-12

- **Breaking: orca is now morca.** The package `morca` (tin morca-mojo), the `morca` command, `morca.toml` and every `MORCA_*` variable replace their orca names, with no fallback. Upgrading means renaming them in a project; deploy/hetzner's `morca-stack` renames a server's keys on its first run. (#384)

- **Images moved to morca-dev:** the runtime image is now `ghcr.io/morca-dev/morca-runtime`, and the repository is `morca-dev/morca`. (#384)

- **Recent runs by batch**: the home page shows each backfill, fill pass or sensor pass as one row, running and failed runs first. (#359)

- **An exited scheduler-old no longer fails the deploy:** `morca-stack apply` first removes a `scheduler-old` or `scheduler-next` left behind that isn't running, saying so, so the overlap and the check go ahead; a running one still waits for `morca-stack drain-old`. (#391)

- **Long Read by lists wrap**: the Written by and Read by cells on Datasets (and the other pipeline lists) wrap between names within a maximum width. (#358)

- **No race in tests/crash.sh**: it waits for the step's error as well as the attempt's. (#386)

## 0.24.0 - 2026-11-11

- **One run over several workers of a pool**: `workers = N` on a pool pipeline lets a run's dista cluster spread over N more machines, guarded by a token. (#325)

- **Kubernetes runs keep their pods' last lines and samples**: a finished run's Job is kept until its pods finish. (#328)

- **Runs spread over machines a pool grows**: pool machines join a private network, and a run that wants more members grows the pool. (#334)

- **A runtime image per release:** each release pushes `ghcr.io/magmalake/orca-runtime:<version>`, which the project image `orca aws push` builds now starts `FROM`. (#336)

- **Pools lists live machines** Machines gone for over an hour are behind a "show all" link (`?gone=1`), and `/api/pools?gone=0` matches. (#338)

- **A snapshot sensed during a live run is queued behind it**: when that run read an older snapshot, its keys run again after it ends (#339)

- **Image build stages on Debian**: they start from `pixi:0.78.0-bookworm`, the same release as the runtime stage, instead of pixi's Ubuntu default. (#340)

- **Reusable CI for projects**: a project's CI can call orca's `project-image.yml`, `project-test.yml` and `project-release.yml`, pinned to an orca tag. (#344)

- **Runtime image locked and promoted:** it installs from a committed lock, and a release tags main's tested image instead of rebuilding it. (#345)

- **A run's Cluster card**: a run spread over pool workers shows its head and members on its page and in its JSON. (#346)

- **Ops › Pools shows the pools orca grows**: each one's types, live machines and last try; pool machines are named `orca-pool-<pool>-<n>`. (#347)

- **Pools fall back on a quota refusal**: a type the project's quota refuses moves the pool on to its next type at once. (#348)

- **`fill_max_runs = "auto"`**: fill runs go as many at once as the host has room for, up to a ceiling. (#350)

- **A gone worker's fill runs are audited**: a pool's fill run whose worker died is always queued again with why, in the audit log too. (#351)

## 0.23.0 - 2026-11-11

- **Hosts over time counts self-hosted workers**: Ops › Pools' chart shows them beside EC2 and the control host. (#305)

- **Internal: scheduler.mojo and state.mojo split into layered modules**: no behaviour change. (#308)

- **orca.toml reads arrays of inline tables**: `[{ a = 1 }, { a = 2 }]`, for config that lists entries. (#309)

- **`[pools.<name>]` in orca.toml**: a worker pool for orca to grow and shrink, recorded by `orca register`. (#310)

- **A Hetzner client for worker pools**: orca.machines creates, lists and deletes a pool's servers. (#312)

- **Worker pools grow and shrink themselves**: orca makes and removes `[pools.<name>]` machines as runs wait. (#313)

- **One `hetzner.env` for every laptop**: relative file names in it are read from its folder, and a laptop's own `ADMIN_IP` and ssh key can go in `~/.config/orca-hetzner/<NAME>.local.env`, read after it. (#315)

- **Hetzner stacks can run self-growing worker pools**: a pool token secret, and the image and login the machines use. (#316)

- **Log in from the Progress card**: "Log in to queue them" comes back to the pipeline's page and tab, not to a bare fragment. (#317)

- **A check after each deploy, and promote.sh**: `deploy.sh` ends with `orca-stack check` (containers, one scheduler, pipeline binaries, and `CANARY` runs on a dev stack) and fails when it fails; `promote.sh --from <dev settings>` deploys to production the tags the dev stack checked. (#318)

- **Sensors and fills honour `keys_per_run`**: above 1, a sensor tops up its queued runs and batches new keys, and fill runs take `keys_per_run` partitions each; `keys_per_run` can be set in `orca.toml`. (#319)

- **Hourly partitions**: `partitions=Hourly["2026-11-11T00"]` gives a pipeline a partition per hour (`Hour`, `YYYY-MM-DDTHH`), for schedules, fills, sensors, backfills and the coverage card. (#306)

- **Worker pools on EC2**: `provider = "ec2"` makes instances in the pool's subnets, with Ubuntu for each type's architecture. (#321)

- **Release upgrade steps**: `deploy.sh` reads the new image's `upgrade.toml` (`orca upgrade`), listing the before-deploy steps first (`--confirmed id,...`) and running the after-deploy ones once the pipelines are registered. (#324)

## 0.22.0 - 2026-11-10

- **A Lean model of retries**: `formal/` holds a Lean 4 model of a step's attempts and commits with a proof that a retried step never commits twice, checked in CI and against `orca.tables.append`; nothing changes for a pipeline. (#286)

- **Out of memory at the maximum fails at once**: a run killed for its memory at `memory_gb`'s maximum fails with that as its error, instead of retrying at the same limit and ending "interrupted: its process stopped, and its retries are spent". (#287)

- **A Lean model of pinned reads**: `formal/` gains a model of `Ctx.pin` with a proof that every attempt of a step reads the snapshot its first attempt read, checked in CI and against the memory and SQLite stores; nothing changes for a pipeline. (#288)

- **A Lean model of the schema floor**: `formal/` gains a model of `migration_floor`, `schema_ahead` and `State.migrate` with proofs that a binary goes on only if it knows every floor-raising migration the database has had, and is never refused otherwise; nothing changes for a deploy. (#289)

- **A Lean model of fencing**: `formal/` gains a model of a run's owner and heartbeat with a proof that a commit which lands within half the stale limit of its fence check lands while its process still owns the run, checked in CI and against `PgStore`; nothing changes for a pipeline. (#290)

- **A paused pipeline's stopped runs are queued again**: a run whose process stopped while its pipeline was paused (by hand or by the watchdog) goes back to queued instead of looking running until unpaused, which also kept a deploy's drain waiting. (#291)

- **A run no longer takes another run's commit for its own**: after orca's database was restored from a backup or made anew over the same warehouse, a new run given a lost run's number recognised that run's snapshots as its commits and skipped its writes; each run now has a random token that its commits carry (`orca.run-token`), and snapshots from before the upgrade are recognised by the number as before. (#293)

- **`replaces=` keeps the registry hash**: switching a step from `writes=` keeps its done keys. (#296)
- **Step `version=`**: raising it marks the step's outputs to be made again. (#296)

- **Fills follow `version=`**: raising a step's version fills its partitions again. (#298)

- **Out of memory at the maximum stays failed**: #287's failed run is no longer retried on the next pass. (#300)

- **Queue what a sensor is behind, with an estimate**: the Progress card's Following line has a Queue them button for the days or months not queued yet, and Start runs previews say about how long the backfill or the one run would take. (#301)

- **`max_runs = "auto"`**: runs as many at once as the host has room for, up to a ceiling. (#302)

- **A run held at its own memory limit no longer holds every start**: memory-pressure admission ignores the stall it causes. (#303)

## 0.21.1 - 2026-11-10

- **Long partition lists shortened**: a run over many partitions shows its first and last and the count on its page (the full list folds under them) and while a deploy waits for it. (#277)

- **Runs held at their memory limit are killed**: a run throttled at its cgroup's `memory.high` that can't reach `memory.max` used to hang for hours; after two minutes held there (`ORCA_RUN_MEMORY_HELD_SECONDS`) it now fails out of memory and retries bigger. (#279)

- **Out-of-memory raises expire**: the memory an out-of-memory kill raised a pipeline to now lasts until 20 of its runs after that one have succeeded, instead of for good, so one unusual run no longer holds every later run at its size. (#280)

- **Memory stall time per attempt**: each attempt of a run with a cgroup records how long its tasks waited on memory (`memory_stall_ms`, `memory_stall_full_ms`, from PSI), to tell a tight grant from a comfortable one. (#283)

- **Learned CPUs fit the host**: a `cpus = "auto"` request is at most what the host grants a run, so a pipeline whose runs peaked on more cores runs on fewer instead of waiting forever. (#284)

## 0.21.0 - 2026-11-09

- **`"auto"` requests**: `memory_gb = "auto"`, `cpus = "auto"` or `"auto..MAX"` in orca.toml admit and grant a pipeline's runs what its last 20 runs suggest, recorded on each run (`learned from 20 runs`), with no request until it has 3 and `learn = false` to turn it off (#275).

## 0.20.0 - 2026-11-09

- **Hetzner: every secret in one SOPS file.** `SECRETS_FILE` in `hetzner.env`
  is decrypted once per deploy, so an age-plugin-se key asks for Touch ID once
  (#265).

- **A request learned from the measured peaks, shown**: the pipeline's Resources card, `orca config show` and their JSON (`learned`) show the memory and CPUs its last 20 successful runs suggest (p95 of peak memory plus 15%, p90 of peak cores, at least the out-of-memory bump, within the declared range), applied nowhere yet (#PR).

## 0.19.0 - 2026-11-09

- **Hetzner: images come from the census's `dev` branch.** The first `up.sh`
  now starts on `ORCA_TAG=dev`, since the census no longer builds `latest`
  (mojo-census#90) (#259).

- **The Hetzner deploy tooling is a release asset.** Each GitHub release
  attaches `orca-hetzner-<version>.tar.gz`, so deploying needs no checkout of
  orca.mojo (#260, #247).

- **Hetzner: secret files encrypted with SOPS.** A `*_FILE` in `hetzner.env`
  named `*.sops` is decrypted on its way to the server, never to a file on
  the laptop (docs/hetzner.md#secrets-on-your-laptop-sops) (#261).

## 0.18.0 - 2026-11-09

- **Overlapping schedulers.** With `ORCA_OVERLAP=on` (off by default) a new
  scheduler takes over while the old one finishes its runs (#232).
- **`orca-stack apply` replaces only what changed.** `orca-stack plan`
  previews it; the first apply replaces every container once (#243, #230).
- **`deploy.sh` pauses the pipelines only when the scheduler is replaced**;
  `--all` replaces every container (#243, #230).
- **No downtime when the UI or an app is replaced.** The old container serves
  until the new one is healthy (#244, #231).
- **`orca ui` answers `/healthz`.** It returns 200 once the database answers
  and 503 otherwise, with no login needed (#244, #231).
- **Hetzner deploys that don't pause.** With `orca-stack configure OVERLAP=1`
  (off by default), `deploy.sh` overlaps the schedulers when it can (#232).
- **`orca ui` drains on SIGTERM**, finishing the requests in flight so a
  deploy no longer cuts a page off (#248).
- **The Hetzner tunnel runs a pinned cloudflared**, not `latest`; set
  `CLOUDFLARED_IMAGE` in `hetzner.env` to change it (#249).
- **orca-stack can deploy images from before 0.18**, whose UI has no
  `/healthz`, without leaving the pipelines paused (#251).
- **Pipeline pages: no stray vertical scrollbar beside the tabs** (#252).
- **`/healthz` answers 503 `draining` once `orca ui` starts draining**, so
  proxies stop routing to a UI that's going away (#253).
- **`fill_lag`** in orca.toml (such as `"2h"`) waits that long after a
  partition ends before filling it, for sources that publish late (#254).
- **A dev stack on Hetzner**, described in docs/hetzner.md with a release
  check list; the scripts say which stack they act on (#250).
- **A deploy that fails only on an unhealthy UI or app unpauses the
  pipelines** and names the containers it couldn't replace (#256).
- **`orca-stack quiesce` no longer waits for runs on remote workers**, since a
  scheduler restart doesn't stop them (#256).
- **`deploy.sh` syncs `/etc/orca/settings.env` from `hetzner.env`.** A hand
  edit there is now undone, so put it in `EXTRA_ENV_FILE` (#257).

## 0.17.0 - 2026-11-08

The backfill and rebuild forms show one copyable `orca login ... && orca
--remote ... backfill` line, and Ops › Control's Memory pressure and Runs
cards explain each value (#236).

- **`deploy.sh` registers the pipelines on every deploy**, and `orca-stack
  restore` unpauses what the deploy paused (#237).
- **The home page's pipelines table puts each pipeline's state first**, with
  Coverage, Running and Queued right after the name (#237).
- **Ops › Alerts lists every alert sent**, delivered or not and resolved or
  open; also `/api/alerts` and `orca alerts` (#238).

## 0.16.0 - 2026-11-08

- **Each pipeline shows one coverage number.** The home page and the pipeline
  page show how many of its partitions or keys are done (#227).
- **Finding which keys are done is fast for a pipeline without a mapped
  step**, 10 ms instead of over a second on 30,000 runs (#227).
- **Actions ask in a dialog in the UI's colours, not the browser's**, saying
  what will happen; without scripts the forms post as before (#233).
- **Code on hover on the lists.** Runs tables and the home page show a
  pipeline's or failed step's code on hover (#233).
- **Every code card leads with its docstring's first sentence** (#233).
- **An older orca runs on a newer, additive schema**, so a rollback needs no
  restore, except to a binary from before migration 24 (#234).
- **`deploy.sh` backs up before it deploys, and `--rollback` goes back** to
  the previous tags (docs/hetzner.md) (#234).

## 0.15.0 - 2026-11-08

- **A log or samples file an EC2 instance keeps is never left empty** or half
  written when the instance stops mid-copy (#218).
- **A run's `started` is when the scheduler started it**, not when its tick
  began, so runs that waited no longer look as if they overlapped (#218).
- **The web layer in modules, behind one router.** The `orca.ui_*`,
  `orca.terms` and `orca.step_cards` modules moved under `orca.ui` (#219).
- **`ORCA_WORKER_ADDR`: the worker API on a listener of its own**, so a slow
  page can't hold up remote workers (#219).
- **Fills on worker pools.** A `worker:<pool>` pipeline can use `fills =
  "all"`; `fill_max_runs` caps the whole pool (#221).
- **A run whose worker is gone is queued again** for the pool, whatever its
  trigger, within `run_retries` (#221).
- **Machine metrics on workers.** Runs on `orca worker` now have the Machines
  card (#221).
- **A worker's claim no longer stalls behind one pipeline's queue**, since it
  now looks at each pipeline's oldest queued run (#221).
- **Runs lists filter by status, date, partition and run**, and cancel, retry
  or backfill many runs at once (#223).
- **Ops › Pools: one page for every machine runs are placed on.** It replaces
  Fleet and Workers, whose old URLs redirect to it (#224).
- **Admission by memory pressure.** No new run starts while memory pressure is
  over `ORCA_ADMIT_MEMORY_PRESSURE` (10%) (#225, #202).
- **The pressure, shown** on Ops › Control, `/api/workers`, `/metrics` and
  `orca status` (#225, #202).
- **Runs get `ORCA_MEMORY_PRESSURE_FILE`**, and `orca.memory_pressure()` reads
  it, so a step can lower its parallelism while pressure is high (#225, #202).
- **Runs get a cgroup memory limit, and an out-of-memory kill retries
  bigger.** On Hetzner it needs `orca-stack configure CGROUPS=1` (#201).

## 0.14.0 - 2026-11-08

- **Each run's peak memory and CPU** are measured and shown on its page, its
  steps and attempts, and a pipeline's Resources card (#200, #171).
- **`orca register` with no arguments works**, registering every pipeline in
  `orca.toml` as documented (#204).
- **Runs on the local runner get their secrets.** A run with secrets writes
  its `driver.log` at the end rather than live (#205).
- **A run's page is cards, like a pipeline's**, with its steps as Table,
  Timeline and Graph tabs (#207).
- **Lineage reads Upstream and Downstream**, and its diagram has a legend
  (#207).
- **Graphs are drawn top to bottom**, so `/datasets` and a snapshot's lineage
  fit a phone's width (#207).
- **Runs sized to their share of the machine.** A pipeline can ask for `cpus`
  and `memory_gb` ranges, and a run starts once its minimum fits (#171, #207).
- **Help on every table, and on the values in it**, as a "?" on each column
  and an explanation on hover for fixed values such as statuses (#207).
- **The Configuration table explains itself and links each value to its line
  in orca.toml** (#207).
- **Code on hover is coloured** (#207).
- **A year of coverage.** A daily pipeline's Coverage card has a Year tab with
  twelve months and a strip for its whole range (#211).
- **How far a sensor is behind what it follows** is shown on its Progress card
  and as amber days on Coverage (#211).
- **Lists in pages, and pages that keep up by themselves**: runs and snapshots
  page by Newer and Older, and lists refresh live (#214).
- **A card per step, on hover**, with its signature, docstring, datasets and
  recent timings (#215).

## 0.13.0 - 2026-11-07

- **`orca config check`** validates orca.toml in CI with no database, and the
  pipeline page shows where each setting came from (#181).
- **The watchdog shows every threshold a rule checks, and which one tripped**,
  in `orca watchdog status`, `/watchdog` and `/api/watchdog` (#180).
- **The pipeline page has three tabs**, Overview, Runs and Operate, each its
  own page (#194).
- **The pipeline page's header is three cards**, Progress, Config and Code,
  with a "?" on each fact (#194).
- **Hovering a link to code shows the code** on every page (#194).
- **Steps: Graph and Table tabs** (#194).
- **Relative times and live pages work again in browsers** (#194).
- **`deploy/hetzner/deploy.sh` pauses, waits and resumes by itself**;
  `--force` keeps the old behaviour (#193).
- **`orca status <pipeline>` shows how long each run ran** instead of when it
  was created (#192).
- **Ops sections can be linked to**, such as `/ops/control#cpu` (#189).
- **PostHog analytics in the UI, when asked for**, with `ORCA_POSTHOG_KEY`
  (`POSTHOG_KEY` on Hetzner); unset, nothing is added (#195).

## 0.12.0 - 2026-11-07

- **Alerts to your phone through ntfy.** Set `ORCA_NOTIFY_URL` for failed
  runs, watchdog trips and more; `orca notify test` checks it (#184).
- **Images build for Neoverse N1**, as Hetzner CAX servers need; a project's
  own `Dockerfile.orca` should pass `--target-cpu` too (#178, mojo-census#35).
- **`docs/hetzner.md` corrections from the first real setup**, and
  `FIXED_COST` in `hetzner.env` for the Fleet page's Cost tile (#179).
- **The UI draws a run's timeline and the pipelines over time**, on the run
  page and as a Timeline tab on the home page (#175).
- **Remote workers over the API.** `placement = "worker:<pool>"` leaves a
  pipeline's runs to `orca worker` machines (docs/workers.md) (#173).

## 0.11.0 - 2026-11-07

- **A live run's page refreshes itself, and shows its settings**, its duration
  and links to the previous and next run (#172).
- **Watchdog "Keep paused"** (`orca watchdog ack`), a fixed-cost tile for the
  local runner, and orca's icon in the header (#172).
- **`orca register` with no paths registers the whole `orca.toml`**, and
  `orca-stack` starts cloudflared on HTTP/2 (#170).

## 0.10.0 - 2026-11-06

- **One Hetzner server.** `deploy/hetzner/` runs orca and the census on one
  server with the local runner; docs/hetzner.md is the runbook (#166).
- **Fills.** `fills = "all"` fills a pipeline's whole range within limits; on
  EC2 or Kubernetes it needs `fill_budget_per_day` (#155).
- **UI: an Ops menu with Control and Fleet.** `/system` and `/fleet` moved to
  `/ops/control` and `/ops/fleet` and redirect there (#160).

## 0.9.0 - 2026-11-06

- **`orca.toml` configures each pipeline.** `orca register` reads it; a key
  removed from it goes back to its default (#145, #134).
- **Small pipelines on the control instance** with `--placement control`; to
  read secrets the AWS stack needs updating (#144).
- **`orca aws replace-control`** swaps in a new control instance; on an older
  stack `orca aws up` needs `--yes` and restarts it once (#154).
- **A watchdog** pauses pipelines whose launches, cost, failures or stuck runs
  go past their limits, and never resumes them itself (#151).
- **A run whose tasks wait for workers that never come fails its attempt**
  after `ORCA_NO_WORKERS_SECONDS` (600) and is retried (#148).
- **Steps that replace their partitions.** `Step[..., replaces=[...]]` makes a
  rerun overwrite a partition instead of appending to it (#120).
- **`orca.tables.commit` refuses to remove files not in the current snapshot**
  (mojo-census GAPS #29) (#143).
- **`orca backfill --rerun` and `orca rerun` are refused for steps that
  append**, unless given `--allow-append` (#143).

## 0.8.0 - 2026-11-06

- **Caddy compresses what it serves.** An existing stack's Caddyfile has to be
  edited by hand on the instance; the PR has the steps (#126).
- **The control instance's own health** on a `/system` page, `/metrics` and a
  warning on `/`; a running stack needs the PR's steps (#96).
- **A warm pool for the ec2 runner**: a pipeline's next run reuses its
  instances; `ORCA_EC2_POOL_SECONDS=0` turns it off (#134).
- **A calendar for dated pipelines in the UI**, to pick days to run and see
  which are done (#112).

## 0.7.0 - 2026-11-05

## 0.6.1 - 2026-11-05

### Changed

- **Pins dista-mojo 0.3.0** (#133).

## 0.6.0 - 2026-11-05

- **Several dista worker processes per EC2 worker instance**, with `orca
  register --worker-procs N|auto` (#130).
- **`orca login` and `--remote`** run orca's commands from a laptop against
  the deployed UI, with no SSM or database access (#111).

## 0.5.0 - 2026-11-05

- **A Fleet page** (`/fleet`) shows hosts, cost and runs per hour; an existing
  stack needs its `sampler` started by hand (#127).

## 0.4.0 - 2026-11-05

- **Bounded table history.** Old snapshots and metadata expire by default, and
  `orca expire` does it by hand (mojo-census GAPS #27) (#124).
- **The lake's bucket is private unless asked.** Pass `PublicData=true` to
  `orca aws up` to keep it public as before (#122).

## 0.3.5 (2026-11-05)

- **Built against iceberg-mojo 0.9.1** (iceberg.mojo#70), deflate-mojo 0.2.0,
  avro-mojo 0.4.5 and parquet-mojo 0.12.1 (#118).
- **Data files written on workers, committed by the step** with
  `orca.tables.append_files` (#108).
- **A crash's stack dump is symbolized, and a crashed attempt says where**,
  naming the function, file and line (#117).
- **Errors say what orca was doing**, naming the dataset or EC2 action that
  failed (#117).

## 0.3.4 (2026-11-04)

- **Built against iceberg-mojo 0.9.0** (parquet-mojo 0.12.0), so data files go
  through the streaming Parquet writer (#116).
- **`/runs` filters are dropdowns, and the runs go back further than 100**,
  paging 50 at a time (#113).
- **The pipeline page's Start runs is one form with a preview** of what a
  backfill would queue (#113).
- **Actions sit beside the statuses they change**, such as Pause by each
  pipeline and Cancel or Retry by each run (#113).
- **A dataset's Rebuild section says what it does and what it runs**, with a
  preview (#113).
- **Runs tables say Tries, not Starts**; the JSON field is still `starts`
  (#113).
- **Fixed: `/runs` sorted run ids as text**, so the newest weren't first past
  run 9 (#113).

## 0.3.3 (2026-11-04)

- **A run's page charts its machines' CPU, memory, disk and network** beside
  its steps (#95).
- **Each run records its machines' metrics** with `orca sample`;
  `ORCA_SAMPLE_SECONDS=0` turns it off (#94).
- **Runs in a SQLite file: `ORCA_DATABASE_URL=sqlite:<path>`**, for a laptop,
  one VM or CI; the scheduler and UI still need Postgres (#82).
- **`MemoryStore` is a whole `RunStore`**, so `<pipeline> run` without a
  database behaves like a recorded run (#82).
- **A pipeline binary depends on the `RunStore` trait alone**; the old import
  paths still work (#82).
- **Links to code look like links to code** (#98).
- **A dataset's page links the steps that write and read it to their code**
  (#98).
- **A step's reads and commits are recorded through its run's `Store`** (#82).
- **One live run per partition.** Fires, sensors, rebuilds and the UI no
  longer queue a second run over a partition that has one (#62).
- **A manual, UI or rerun run whose process died no longer stays `running`**;
  it fails as `interrupted` and can be resumed or cancelled (#61).
- **A process that may have lost its run no longer commits** (#60).
- **Cancel stops a running step, and steps can time out** with `Step[...,
  timeout_seconds=N]` (#68).
- **A pipeline binary that hangs no longer stalls the scheduler or the UI**
  (#64).
- **Behind an HTTPS proxy, the UI's forms work** when `ORCA_UI_TRUST_PROXY=1`
  or `ORCA_UI_SECURE_COOKIES=1` is set (#57).
- **The UI refuses `partitions=@file:<path>`**, which let a logged-in user
  read files on the UI's host (#58).
- **Retries after `orca register` of a new build no longer loop**, and runs
  record an `error` (#63).
- **A Postgres blip no longer throws away a finished step**; writes are
  retried for `ORCA_DB_RETRY_SECONDS` (#67).
- **Cancel runs in bulk, and pause a pipeline**, with `orca cancel <pipeline>
  KEYS|@all`, `orca pause` and `orca unpause` (#73).
- **`<binary> run` no longer re-registers the pipeline**, and refuses
  unregistered code without `--allow-new-code` (#59).
- **A snapshot a sensor can't run no longer wedges it** (#65).
- **Retries that wait, and steps that say "not yet"**, with `backoff_seconds`
  and `defer(seconds, why)` (#66).
- **Built against dista-mojo 0.2.2, iceberg-mojo 0.8.7 and objectstore-mojo
  0.4.2**, with the S3 multipart fix (#110).

## 0.3.2 (2026-11-03)

- **Built against flare_mlake 0.13.2 and k8s-mojo 0.1.2**, so a Linux program
  linking flare's client beside dista compiles (#56).

## 0.3.1 (2026-11-03)

- **`ensure_table` adds the columns a table lacks**, and refuses incompatible
  changes; it needs iceberg-mojo with `UpdateSchema` (iceberg.mojo#64) (#54).
- **A dated pipeline may write a keyed sensor's keys** (#51).
- **Names can hold a `/`**, so a keyed pipeline's keys can be `owner/name`
  (#53).
- **`orca backfill --rerun`** queues keys that are already done, too (#52).
- **Built against the shim-loading fix releases**, so a pipeline binary built
  under pixi runs from a plain shell (#55).

## 0.3.0 (2026-11-03)

A project deploys itself to AWS.

- **`orca aws`** creates the stack, pushes the image and registers pipelines;
  the stack's `ImageTag` defaults to `latest` (#49).
- **The stack's warehouse is public**, so a project's tables can be read
  unsigned; logs and run state stay private (#50).
- **Scaling goes through the pipeline's binary** (#50).

## 0.2.0 (2026-11-03)

Workers sized to the work, secrets for runs, and the stack's public data.

- **Secrets for runs.** `orca register --secret NAME=ID` gives a run a Secrets
  Manager secret, masked in every log (#46).
- **Autoscaling on EC2.** `orca register --workers MIN..MAX` starts and drains
  workers as the run needs; it needs dista-mojo 0.2.0 (#44).
- **The stack's public data** bucket, which anyone may read, for a lake's
  public tables (#47).

## 0.1.0 (2026-11-03)

orca's first release, as mojoshelf tin `orca-mojo`: phases 1 to 5 of
DESIGN.md, keyed partitions, and the first of phase 6.

- **Pipelines in Mojo**, with compiler-checked steps, monthly, daily and keyed
  partitions, cron schedules and retries (#42).
- **Runs in Postgres**, resumable after any crash (#42).
- **The scheduler** (`orca`): schedules, backfills, retries, sensors, lineage
  and rebuilds (#42).
- **Runners:** local processes, a dista cluster per run on Kubernetes, or
  instances per run on EC2 (#42).
- **The UI** (`orca ui`): pipelines, runs, datasets and lineage, as HTML and
  JSON (#42).
- **Tables:** pinned Iceberg reads and recognisable commits from steps (#42).
