# morca on one Hetzner Cloud server

One ARM server, a fixed monthly price, nothing launched on demand. morca runs
its runs on the server itself (`MORCA_RUNNER=local`), the warehouse and the
logs are in Hetzner Object Storage, Postgres keeps its data on a Volume, and
Cloudflare Tunnel brings the UI and the console in, so the firewall opens SSH
(from your address) and nothing else. The scripts are in
[`deploy/hetzner/`](../deploy/hetzner/); nothing has to be typed over SSH by
hand. It is the same stack as [`deploy/aws/morca.yaml`](../deploy/aws/morca.yaml)
(same images, env names and `pg_dump` format) without the instances, Caddy,
Secrets Manager and ECR.

```
laptop: hcloud + ssh + deploy/hetzner/*.sh
   |
   v                          Hetzner Cloud server (CAX21, Ubuntu)
firewall: tcp/22 from you     +-- docker network "morca" ---------------------------+
                              | postgres  (data on the Volume, /mnt/orca-data)     |
Cloudflare ---- tunnel ------>| cloudflared -> ui:8270, console:8080               |
 orca.mojourney.dev               | scheduler (local runner), ui, sampler, console     |
 mojourney.dev             +----------------------------------------------------+
                                        |  S3 API (outbound)
                                        v
                              Hetzner Object Storage: warehouse/, logs/, backups/pg/
```

## What you do first (consoles, once)

1. **Hetzner Cloud**: a project, and an API token with read & write
   (Security > API tokens). On the laptop: `hcloud context create morca` and
   paste the token (it stays in hcloud's config, not in this repo).
2. **Object Storage** (same console): a bucket, in the **same location as
   the server** (`LOCATION` in `hetzner.env`). A bucket in another location
   works (it was tried with the bucket in nbg1 and the server in fsn1), but
   every byte of the warehouse and the logs then crosses locations. And
   and S3 credentials (access key and secret). Put them in a file of two
   lines, `AWS_ACCESS_KEY_ID=...` and `AWS_SECRET_ACCESS_KEY=...`, mode 600.
3. **Cloudflare**: Zero Trust > Networks > Tunnels > create a tunnel
   ("Cloudflared"), and copy its token into a file as one line,
   `TUNNEL_TOKEN=...`, mode 600. Add two public hostnames to the tunnel:
   `orca.mojourney.dev` to service `http://ui:8270`, and `mojourney.dev` to
   `http://console:8080`. (If those names are on the AWS stack, Cloudflare
   replaces their DNS records with the tunnel's CNAME; if it can't create the
   CNAME, delete the existing A (and AAAA) records for the names first: a
   name that already has an A record cannot also get the tunnel's CNAME, and
   Cloudflare says so only when you save the hostname.) The CNAMEs must
   be **Proxied** (orange cloud): a DNS-only CNAME resolves to a private
   `fd10::` address and the site is unreachable. The tunnel runs over HTTP/2
   (`TUNNEL_TRANSPORT_PROTOCOL=http2`, set by `morca-stack` unless
   `tunnel.env` sets it), because QUIC over UDP 7844 kept timing out on
   Hetzner ("timeout: no recent network activity").
4. **A GitHub token** for the census's `mojo_repos`, in a file (read-only
   access to public repositories is enough).
5. **Your address** for the firewall: `curl -4 ifconfig.me`, plus `/32`.
6. **Tools** on the machine you deploy from: `hcloud` **with a context**
   (`hcloud context create morca`, step 1; `up.sh` and `deploy.sh` both call
   it), `ssh`, `jq`, POSIX `sh`. Keep `hetzner.env` outside the repository,
   where no commit can pick it up, and point the scripts at it:
   `mkdir -p ~/.config/morca-hetzner && cp hetzner.env.example ~/.config/morca-hetzner/hetzner.env`
   (from the scripts' directory, [below](#first-setup))
   and `export HETZNER_ENV=~/.config/morca-hetzner/hetzner.env` (or put the
   export in your shell's profile).
7. **Images**: the scheduler's image is the project's, built on morca's
   runtime image (`ghcr.io/morca-dev/morca-runtime:<morca version>`) and
   named after the project (`MORCA_IMAGE`; the census's is still
   `ghcr.io/morca-dev/census:<tag>`); see [Images](#images).

## First setup

The scripts don't need a checkout of morca: each release has them as
`morca-hetzner-<version>.tar.gz`, which unpacks to `morca-hetzner-<version>/`
(its `VERSION` file says which, and the scripts print it). The newest:

```sh
curl -fsSL https://github.com/morca-dev/morca/releases/latest/download/morca-hetzner.tar.gz | tar -xz
```

Then, in that directory (or `deploy/hetzner` of a checkout):

```sh
cd morca-hetzner-<version>
cp hetzner.env.example hetzner.env     # fill in every line: the file says what each is
./up.sh --dry-run                      # prints every hcloud and ssh command; runs none
./up.sh
```

`up.sh` creates (or leaves alone, if it exists) the SSH key, the firewall,
the Volume (formatted once, delete-protected), and the server with
`cloud-init.yaml` (Docker, and the Volume mounted before Docker starts so that
Postgres can never start on the root disk). Then, over SSH, it puts the
settings and secrets on the server (`/etc/orca`, mode 600, sent on standard
input and never printed), installs `morca-stack` and the backup timer, and
starts the containers. Run it again to fix drift in the Hetzner resources,
starting again only the containers whose settings changed (see [Deploying
code](#deploying-code)). It does not restart a scheduler that has runs
running unless you add `--force` (a restart kills them). A setting changed
in `hetzner.env` later doesn't need `up.sh`: every `deploy.sh` brings the
server's settings in line with it first ([Settings](#settings-from-hetznerenv)).

Then, once per new database:

```sh
ssh root@<ip>                          # up.sh prints the address
docker exec -it scheduler morca user add <you>      # reads a password
```

and register the pipelines (below). Open `https://orca.mojourney.dev`.

Secrets without Secrets Manager: `MORCA_SECRET_FETCH` is
`sh /etc/orca/secret-fetch`, which prints `/etc/orca/secrets/<id>`, so the
pipeline's `secrets = { GITHUB_TOKEN = "orca/github-token" }` reads
`/etc/orca/secrets/orca/github-token`, which `up.sh` writes from
`GITHUB_TOKEN_FILE`. More secrets: put the file there and use its id.

### Secrets on your laptop: SOPS

The secret files `hetzner.env` names (`S3_CREDENTIALS_FILE`,
`TUNNEL_TOKEN_FILE`, `GITHUB_TOKEN_FILE`, `NTFY_TOPIC_FILE`,
`NTFY_TOKEN_FILE`, `GHCR_TOKEN_FILE`) can be encrypted with
[SOPS](https://github.com/getsops/sops) and [age](https://age-encryption.org),
so the laptop keeps one private key instead of plain tokens. A file named
`*.sops` or `*.sops.<ext>` (`s3.sops.env`, `github-token.sops`) is sent as
`sops -d` decrypts it, through a shell variable and ssh's standard input,
never written to a file on the laptop; the server still gets its plain
`/etc/orca` files, mode 600. `--dry-run` prints `+ sops -d <file> | ssh ...`.

```sh
brew install sops age
mkdir -p ~/Library/Application\ Support/sops/age    # macOS; ~/.config/sops/age on Linux
age-keygen -o ~/Library/Application\ Support/sops/age/keys.txt   # prints the public key, age1...
```

Back the key file up offline (more than one key can be in it, one per
line). SOPS looks there by default; elsewhere, set `SOPS_AGE_KEY_FILE`.

A private repository for the encrypted files, one directory per stack and
a key each, so a laptop with only the dev key can't read production's:

```yaml
# .sops.yaml
creation_rules:
  - path_regex: ^prod/
    age: age1<production's public key>
  - path_regex: ^dev/
    age: age1<dev's public key>
```

From the repository's top (`.sops.yaml` picks the key by the name given in
`--filename-override`, not the plain file's path):

```sh
sops -e --filename-override prod/s3.sops.env ~/.config/morca-hetzner/s3.env > prod/s3.sops.env
sops -e --input-type binary --filename-override prod/github-token.sops \
    ~/.config/morca-hetzner/github_token > prod/github-token.sops
sops edit prod/s3.sops.env                    # to change one later
```

A file that isn't `KEY=value` lines (a bare token) must be encrypted with
`--input-type binary`: as an env file SOPS rejects it, and its error message
quotes the offending line, the secret itself.

then in `hetzner.env` `S3_CREDENTIALS_FILE=$HOME/dev/ops-secrets/prod/s3.sops.env`
and so on (or relative, [below](#one-hetznerenv-for-every-laptop)), and delete the plain files. SOPS reads the extension: `.env` is
an env file (the keys stay readable, the values are encrypted), no known
extension is binary (the whole file). Losing the age key loses the files,
so keep its backup off the laptop; if it leaks, change the secrets
themselves, not only the key, since git keeps every old encrypted version.

#### One file for every secret (recommended)

Each `*.sops*` file is its own `sops -d`, so a key that asks before each
use (an [age-plugin-se](https://github.com/remko/age-plugin-se) Secure
Enclave key: Touch ID) asks once per file. `SECRETS_FILE` in `hetzner.env`
names one SOPS YAML file with every secret instead, decrypted once per
`up.sh` or `deploy.sh` (one Touch ID) into a shell variable, never a file.
Its keys are the server's file names under `/etc/orca`, each value that
file's content; a key it has replaces the `*_FILE` setting (setting both is
an error), and an unknown key is refused:

```yaml
s3.env: |
  AWS_ACCESS_KEY_ID=...
  AWS_SECRET_ACCESS_KEY=...
tunnel.env: TUNNEL_TOKEN=...
secrets/orca/github-token: ...   # GITHUB_TOKEN_FILE's
secrets/orca/ntfy-topic: ...     # NTFY_TOPIC_FILE's
secrets/orca/ntfy-token: ...     # NTFY_TOKEN_FILE's
ghcr-token: ...                  # GHCR_TOKEN_FILE's
```

Write it with `sops edit prod/secrets.sops.yaml`, or, from the repository's
top as above, from the plain files through a pipe (never a plain temporary
file):

```sh
p=~/.config/morca-hetzner
{ echo 's3.env: |'; sed 's/^/  /' $p/s3.env
  echo 'tunnel.env: |'; sed 's/^/  /' $p/tunnel.env
  echo 'secrets/orca/github-token: |'; sed 's/^/  /' $p/github_token
} | sops -e --filename-override prod/secrets.sops.yaml /dev/stdin > prod/secrets.sops.yaml
```

Each value reaches the server with one trailing newline, as a `*.sops*`
file's does. A Secure Enclave key: `age-plugin-se keygen -o se-key.txt`
(Touch ID or the login password; `--access-control any-biometry` for Touch
ID only), then `age-plugin-se recipients -i se-key.txt` prints its public
key, `age1se1...`, for `.sops.yaml`; add the identity's line to `keys.txt`
or point `SOPS_AGE_KEY_FILE` at `se-key.txt`.
`--dry-run` doesn't decrypt: it prints `+ sops -d <file> (once)` and a
`| ssh ... morca-stack sync <name>` line for each secret no `*_FILE` setting
gives, assuming the file has them.

#### One `hetzner.env` for every laptop

`hetzner.env` holds no secret, so it can live in the secrets repository
too (`prod/hetzner.env`), one copy for every laptop. Two things make that
work:

- **Relative file names.** A relative `SECRETS_FILE`, `*_FILE` or
  `EXTRA_ENV_FILE` is read from the folder `hetzner.env` is in, so
  `SECRETS_FILE=secrets.sops.yaml` works wherever the repository is cloned.
- **A file of each laptop's own.** `ADMIN_IP` (the firewall's ssh source)
  and `SSH_PUBLIC_KEY_FILE` belong to a laptop, not the stack. Put them in
  `~/.config/morca-hetzner/<NAME>.local.env` (`orca.local.env`; or the file
  `HETZNER_LOCAL_ENV` names, which must then exist). It's read after the
  shared file, so whatever it sets wins, and its own relative names are read
  from its folder. It can't set `NAME`, which picks it.

```sh
# ~/.config/morca-hetzner/orca.local.env
ADMIN_IP=203.0.113.7/32
SSH_PUBLIC_KEY_FILE=$HOME/.ssh/id_ed25519.pub
```

The scripts' first line names both files: `deploy.sh: stack morca, settings
.../ops-secrets/prod/hetzner.env and ~/.config/morca-hetzner/orca.local.env`.
Two laptops share the stack's firewall, which lets in one `ADMIN_IP`: the
last `up.sh` sets it.

## The census: `morca.toml`

The census's `morca.toml` lives in the mojo-census repository, next to the
code it configures, and the image has it (`MORCA_CONFIG=/opt/morca/morca.toml`,
the pipelines at `MORCA_PIPELINES_DIR=/opt/morca/pipelines`, and the build's
`MORCA_COMMIT` and `MORCA_SOURCE`, which `morca config show` reports as the
file's commit). Read the file there, not here: each setting has a comment,
and the numbers move as the census does, so this page quotes none.
`DISTA_WORKER_SLOTS` is how many dista workers run in one process on the
server, and gharchive's `GHARCHIVE_PARALLEL` is how many hours are in flight
at once. Their defaults are sized for four AWS instances; each hour in
flight takes about 1 GB (processes of 2 to 4.4 GB), and 3 and 3 on the
CAX21 swapped hard, so the census's `morca.toml` sets both lower for it
(mojo-census#37). Raise both on a bigger server (during an import on the
CAX41, register again with more, and set them back after); too many took
the CAX21's memory to 99.6% and then OOM (the watchdog paused everything). `cloud-init.yaml` also
creates a 4 GB `/swapfile` (in `/etc/fstab`) if the server has no swap, so a
burst is slow instead of fatal; a server made before that can run
`fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`
and add `/swapfile none swap sw 0 0` to `/etc/fstab`.

Instead of numbers that are wrong after a rescale, a pipeline can ask for a
range with `cpus` and `memory_gb` and set `DISTA_WORKER_SLOTS = "auto"`: the
scheduler then starts its run once the minimum fits beside the others' and
grants it up to the maximum of what's left, so the next run after
`rescale.sh up` is simply given more, and dista sizes its workers to that
grant, memory included ([morca.toml](morca-toml.md#auto-from-the-grant)).
A pipeline's own `"auto"`, like `GHARCHIVE_PARALLEL`, needs its code to read
the grant (`morca.auto_count`).

Register (the binaries are in the image; `up.sh` doesn't do this because
what to register is the project's):

```sh
ssh root@<ip> docker exec scheduler morca register
```

To change a setting: edit `morca.toml` in mojo-census, merge it, deploy the
new image (`./deploy.sh <tag>`), and register again. (For a quick try,
`docker exec` can still register another file with `--config` and explicit
binaries; the next registration from the image takes it back.) This needs
a morca with `morca register` reading the file's tables (after 0.10.0);
before that, name the binaries:
`docker exec scheduler sh -c 'cd /opt/morca/pipelines && morca register gharchive gharchive_index mojo_repos mojo_history mojo_activity mojo_stats mojo_versions'`.

`morca config show` says what was registered. A pipeline with `placement`
left out runs on the scheduler's runner, here the local one. Ops > Pools
says the runner launches no instances, its Cost tile shows
`MORCA_FIXED_COST` (`FIXED_COST` in `hetzner.env`, free text such as
`€8.49/month`; "Fixed" if unset), and the watchdog's cost
rule reads "fixed price" and never trips; its launch, idle, failing, stuck
and control rules stay on.

## Memory pressure

Grants are estimates, and on one server everything shares the memory:
Postgres, the UI, the page cache and every run. So the scheduler also
stops starting runs while the machine stalls on memory
([morca.toml](morca-toml.md#memory-pressure)): while Linux's pressure stall
information reads `some avg10` over `MORCA_ADMIT_MEMORY_PRESSURE` (10%, in
`morca.env`; 0 turns it off), new runs wait, saying `waiting: memory
pressure 23% (limit 10%)`, and the runs already going go on. Ops › Control
has the current reading, and `/metrics` and `morca status` too.

What it reads, here: the scheduler runs in a container and its runs are
child processes in that container. Inside a container
`/proc/pressure/memory` is the host's (PSI isn't namespaced), while the
container's own cgroup has `/sys/fs/cgroup/memory.pressure`. The stack
starts the scheduler with no `--memory` limit, so its cgroup can't run
short by itself, and the scheduler reads the host's file: the right signal
when Postgres and the runs compete for the server's memory. Give the
scheduler's container a `--memory` limit and it reads its own cgroup's
instead, which stalls at that limit even with the host at ease. The log's
first lines say which (`morca: memory pressure from /proc/pressure/memory
(the host's) ...`). Ubuntu's kernel has PSI on; on a kernel without it (or
booted with `psi=0`) nothing is held and the log says so once.

Each run gets `MORCA_MEMORY_PRESSURE_FILE`, the same file, to poll if it
wants to lower its own parallelism (`morca.memory_pressure()`). The
watchdog's memory rule stays the last line of defence: it pauses pipelines
once memory is nearly full, which pressure should keep from happening.

## Deploying code

```sh
./deploy.sh a1b2c3d                    # pulls ghcr.io/morca-dev/census:a1b2c3d, starts again what changed
./deploy.sh a1b2c3d console=latest     # one app on another tag
./deploy.sh --all a1b2c3d              # every container again, changed or not
./deploy.sh --rollback                 # back to the tags deployed before (see Rolling back)
```

The tag is the project's image tag: see [Images](#images). This replaces
`morca aws app` and `morca aws up` for code changes, and needs `hcloud` with a
context like `up.sh`.

### Settings from `hetzner.env`

Before it plans, `deploy.sh` (`--rollback` too) writes the server's
settings as `up.sh` does, from `hetzner.env` as it is now (`sync_settings`
in `lib.sh`, which both run):

- `/etc/orca/settings.env` (`AWS_REGION`, `MORCA_WAREHOUSE` and the rest,
  the ntfy ids, `MORCA_FIXED_COST`, `MORCA_POSTHOG_KEY`, then
  `EXTRA_ENV_FILE`'s lines), and the secret files (`s3.env`, `tunnel.env`,
  `ghcr-token`, `secrets/orca/*`): each only if it differs, mode 600, sent
  on ssh's standard input (`morca-stack sync`);
- the stack settings `MORCA_IMAGE`, `CLOUDFLARED_IMAGE`, `BUCKET`,
  `BACKUP_KEEP`, `GHCR_USER`, `OVERLAP` (1 unless `hetzner.env` says 0)
  and `DRAIN_SECONDS` (`morca-stack configure`), and the apps
  (`morca-stack app`). Not the tags: those are `deploy.sh`'s, and
  `MORCA_TAG` in `hetzner.env` is only the first `up.sh`'s. `CGROUPS` (on
  unless set to 0) and `HEALTH_TIMEOUT`, set on the server by hand, aren't
  in `hetzner.env` and are left alone.

Before any of that, `deploy.sh` and `up.sh` check that `hetzner.env` has
the [drain limit](#the-drain-limit), `DRAIN_SECONDS`, as a whole number of
seconds above 0, and stop without changing anything on the server when it
is missing, 0 or negative.

It prints what changed, never a value: for `settings.env` the keys added,
removed or changed, for a secret file only that it changed, for a stack
setting old -> new (none is a secret):

```
deploy.sh 10:02:11: the server's settings from hetzner.env (names only, never values):
  morca-stack: settings.env: added MORCA_POSTHOG_KEY
  morca-stack: BACKUP_KEEP 14 -> 30
deploy.sh 10:02:12: the plan:
  scheduler replace settings: its env file changed
  ui replace settings: its env file changed
  sampler keep unchanged
  console replace settings: its env file changed
```

The plan then replaces the containers whose env file changed, and a
changed scheduler quiesces (or overlaps) as a new tag does. A setting
emptied in `hetzner.env` (`POSTHOG_KEY=`, an `EXTRA_ENV_FILE` line taken
out) is removed from `settings.env`, as `up.sh` writes it; `GHCR_USER=`
removes it from `stack.conf`. So `hetzner.env` is where settings change:
an edit made by hand to `/etc/orca/settings.env` is undone by the next
deploy (put the line in `EXTRA_ENV_FILE`). A secret file `hetzner.env` no
longer names (`NTFY_TOKEN_FILE=`) stays on the server, unused once its id
is out of `settings.env`. `--dry-run` prints the `morca-stack sync`
commands and the keys `settings.env` would have, and reads and writes
nothing on the server.

A rollback syncs too: it puts back the tags deployed before, not the
settings, which the server keeps no history of. To undo a setting, change
it back in `hetzner.env` and deploy (or roll back): the next one applies it.

**Only what changed starts again.** `morca-stack apply` compares what each
container would be started with against what it runs, and leaves it
running when nothing differs: the image (the tag, and the image's id, so a
tag pushed again counts), the env file it reads (`morca.env`, `app-<name>.env`,
`tunnel.env`, and `secret-fetch`), and its flags and mounts (`CGROUPS`'s
among them). A hash of those is the container's `orca.stack.spec` label.
It prints a line for each:

```
scheduler: unchanged
ui: replaced (image ac0c766 -> b2b9558)
sampler: replaced (image ac0c766 -> b2b9558)
console: unchanged
```

The scheduler, UI and sampler run the morca tag, so a new morca tag replaces
the three; an app on its own tag (the census console) is replaced only when
its tag changes. Postgres is never restarted. A container started by an
`morca-stack` from before the label has none, so the first apply with this
one replaces every container once. `morca-stack plan` with the same
arguments says what an apply would do (`ui replace image ac0c766 ->
b2b9558`) and changes nothing; `apply --all` replaces every container, as
`apply` did before, and `apply --only console` that one alone.

**The UI and the apps without downtime.** The tunnel reaches them by name
on the `morca` network (`http://ui:8270`, `http://console:8080`), so
`apply` replaces them side by side instead of stopping them first:

1. it starts the new container as `ui-next` (or `console-next`) on the
   `morca` network, where nothing resolves `ui` to it yet;
2. waits until it's healthy: for the UI, 200 on `/healthz` (answered once
   the database does, without a login) and, if `MORCA_WORKER_ADDR` is set in
   `settings.env`, an answer on the worker API's port; for an app, 200 on
   its check path, `/` unless `morca-stack app NAME PORT CHECK` says
   otherwise (the census console answers 503 while it warms up, so 200 on
   `/` means it has read the lake);
3. gives it the alias `ui` (a reconnect to the network, as Docker only
   gives aliases on connecting) and checks it again; Docker's DNS now
   answers `ui` with both containers;
4. stops the old one with `docker stop -t 10` (ten seconds for the requests
   in flight; the UI's `/healthz` answers 503 `draining` from the
   moment it gets the signal, docs/ui.md#stopping), removes it, and renames
   `ui-next` to `ui`.

cloudflared resolves the name for each new connection, so traffic moves
over without it restarting, and the worker API's listener, in the same
container, moves with the UI. The check is made inside the container with
busybox's `nc` (the runtime image has no curl), or bash's `/dev/tcp` in
an image from before the distroless runtime (#337). A new container
that isn't healthy within `HEALTH_TIMEOUT` seconds (`morca-stack configure
HEALTH_TIMEOUT=600`; default 300; `apply --health-timeout` for one apply),
or that exits, is removed and the old one keeps serving; `apply` goes on
with the other containers, then exits non-zero saying which one and why,
with the end of its log, and an `apply` again tries only that one. A
container that isn't running is simply started. The scheduler is not
replaced this way: it's the single writer of scheduling decisions and its
runs are its children, so two at once would start runs twice ([#232](https://github.com/morca-dev/morca/issues/232)). The
sampler and cloudflared are stopped and started as before.

Checked against real Docker (colima): with a loop of requests to `ui` and
`console` from a container on the network, a new connection each 50 ms,
an apply that replaced both (the console warming up for 8 s) and one whose
new containers never became healthy saw no failed request.

Runs on remote workers ([docs/workers.md](workers.md)) talk only to the
UI's API, through the tunnel, so the UI's swap is what they see of a
deploy: its polls and its runs' store calls and heartbeats go on to the
old UI, then to the new one. A request cut as the old one stops (after
its 10 s for requests in flight) is retried: the worker polls again, and a
run's store calls retry for `MORCA_DB_RETRY_SECONDS`. What would hurt is
the UI unreachable for longer than half the stale limit (15 s by
default): the scheduler then takes the worker for lost and queues its
runs again. A UI that's down for minutes does that, which is why
`rescale.sh` waits for the workers' runs too (below).

**The scheduler.** Restarting it kills the runs its processes hold, so
`apply` refuses, while any of those is running, only when the scheduler is
to be replaced (`--force` kills them). Runs on remote workers (placement
`worker:<pool>`) don't count: they're the worker's processes, which talk to
the UI and run on through the scheduler's restart. `deploy.sh` asks for the plan first, and does the safe
sequence itself, logging each step:

1. copies this checkout's `morca-stack` to the server, and prints `morca-stack
   plan`'s lines;
2. if the plan replaces the scheduler, `morca-stack quiesce`: pauses every
   pipeline that isn't paused, then waits for the scheduler's running runs
   to end, listing them each minute (`--timeout SECONDS`, default 3600). It
   doesn't wait for runs on remote workers: it lists those as `left running
   on workers`, so you know they go on. If the plan doesn't replace the
   scheduler, nothing is paused and running runs go on;
3. if the plan replaces anything, `morca-stack backup-now`: a `pg_dump` to
   the bucket, as the nightly one (below), and says where: `previous tag
   ac0c766, new tag b2b9558; backup
   s3://<bucket>/backups/pg/20261108T101500Z.dump`. Beside the dump it
   writes `<time>.paused`, which pipelines were paused by hand (or the
   watchdog) and which by this deploy, and prints both. If the backup fails
   it unpauses what it paused and stops without deploying; `--no-backup`
   deploys without one;
4. `morca-stack apply --tag <tag>`: pulls, replaces what changed, and keeps
   the tags it replaced (see [Rolling back](#rolling-back));
5. if the scheduler was replaced, `morca-stack register`: registers the
   pipelines from the new image (`docker exec scheduler morca register`, its
   `morca.toml`), so queued runs move to the new code before any starts.
   The pipelines are in the scheduler's image, so when it wasn't replaced
   there is nothing new to register;
6. if it paused them, `morca-stack resume`: unpauses the pipelines it
   paused, and only those (not ones the watchdog or you paused).

So a deploy of a new morca tag pauses, waits, backs up, replaces the
scheduler, UI, sampler and the apps that follow the morca tag, registers and
unpauses. A census-only deploy (`./deploy.sh <the morca tag that runs>
console=<sha>`) backs up and replaces the console, and nothing is paused,
killed or registered. A deploy of what already runs does nothing: no
backup, and every container is kept.

If only a new UI or app isn't healthy, the apply fails after the rest is
applied, and the deploy finishes all the same: a scheduler it replaced is
registered, the pipelines it paused are unpaused, and it prints `morca-stack
status`, then exits non-zero naming the containers that weren't replaced
(the old ones keep serving). Once the cause is fixed, `ssh root@<ip>
morca-stack apply` replaces only those. A rollback does the same. On a
timeout, a scheduler that didn't start, a failed registration or a failed
apply otherwise, it stops with the pipelines still paused if it paused
them, and says so (after a failed registration: fix it, then `morca-stack
register` and `morca-stack resume`, or `./deploy.sh --rollback`); `ssh
root@<ip> morca-stack resume` undoes the pause. `--force` skips the pause and the wait and kills the running runs if
the scheduler is replaced. `morca-stack status` shows the running runs (the
scheduler's and those on remote workers) and what quiesce paused.

**Overlapping schedulers** (on by default since #390;
[docs/overlap.md](overlap.md)). The containers get `MORCA_OVERLAP=on` and
`MORCA_DRAIN_SECONDS` (the [drain limit](#the-drain-limit)), and a deploy
that replaces the scheduler doesn't have to pause. `OVERLAP=0` in
`hetzner.env` turns it off: every such deploy then pauses and waits as
above. A `stack.conf` without `OVERLAP` (a server set up before #390)
overlaps too. Step 2
first asks `morca-stack can-overlap --tag <tag>`, which runs the new
image's `morca scheduler can-overlap`. It says yes when the running
scheduler leads with overlap on and the new binary's migrations don't
raise the schema's floor past it. On yes, nothing is paused or killed:

- the apply starts the new scheduler as `scheduler-next` beside the old
  one, sets the old one's restart policy to `no` (once it has drained it
  must not come back as the newest instance), renames it
  `scheduler-old-<UTC time>` (say `scheduler-old-20261112T101500Z`) and the
  new one `scheduler`, and waits until the new one leads (`morca scheduler
  wait-lead`, `HEALTH_TIMEOUT`). The old one drains as soon as it sees the
  new one: it starts nothing, and its runs go on, under its image;
- the pipelines are registered from the new scheduler, which now alone
  starts runs;
- `morca-stack drain-old` asks the old one to drain and returns: the deploy
  doesn't wait for its runs. A run sees that it's outdated
  (`morca.outdated()`, [docs/overlap.md](overlap.md#outdated-runs)) and
  ends when its code decides, up to the drain limit. Once its last run has
  ended, or the limit has run out, the old scheduler exits, and a reaper
  `drain-old` left in the background (`morca-stack reap-old`, its log in
  `/var/lib/orca/reap-<name>.log`) removes its container.

While an old scheduler drains, `morca-stack status` and the check say so,
as `scheduler-old-<time>: draining 2 run(s) (outdated)`, which isn't a
failure, and the run pages and `morca status <pipeline>` mark its runs
`outdated (newer version <commit> is leading)`. The next deploy overlaps
again: the scheduler it replaces drains under a name of its own beside the
first, so several can drain at once and none is renamed over another, and
`drain-old` asks each to drain. `can-overlap` still checks the new binary's
floor against every live instance, the draining ones included: a
migration that raises the floor past an old one pauses and waits for its
runs too.

To wait for the old schedulers anyway, `ssh root@<ip> morca-stack drain-old
--wait`: one still running after the drain limit (or `--timeout
<seconds>`) is stopped, its runs killed and queued again by the new
scheduler.

An old scheduler or a `scheduler-next` that a deploy before left behind
and that isn't running any more (its reaper gone, say after a reboot)
holds no runs: every `morca-stack apply` first removes it, with a line
naming its image and how long ago it exited. A `scheduler-old` from before
this release (no time in its name) is treated as one of them.

On no (`OVERLAP=0`, a migration that raises the floor, no scheduler
going), the deploy pauses and waits as above, and says why. So does the
deploy that turns overlap on (the first after upgrading to #390, on a
stack that had it off): the scheduler it replaces has overlap off.
A rollback, `--force` and a dry run don't overlap. That path still waits
for the running runs, the old schedulers' included: it replaces the
scheduler by stopping it, and every local run is a child process of its
container, so not waiting would kill them; and a migration that raises the
floor can't run while an older binary's runs go on over the schema. Only
overlapping avoids the wait. `morca-stack status` lists the scheduler
instances (`morca scheduler status`) unless `OVERLAP=0`.

#### The drain limit

`DRAIN_SECONDS` in `hetzner.env` is required: how long, in seconds, an old
scheduler may keep draining its runs after an overlapping deploy before it
is stopped. There is no default, because only you know how long your runs
may go on under old code: a day (`86400`) or a week (`604800`), say.
`deploy.sh` and `up.sh` refuse a missing, 0 or negative value before they
change anything on the server, naming the setting; `morca-stack apply`
refuses too, and `morca scheduler` with overlap on doesn't start without
it (`MORCA_DRAIN_SECONDS`, which the containers get from it).

Nothing is killed before the limit. Once it has run out, the old
scheduler kills the runs it still has (each control run's process group
too), ends its instance and exits; the new scheduler queues those runs
again once their heartbeats are stale, and the reaper removes the
container. The reaper also stops an old scheduler that still runs a minute
past the limit (`MORCA_STACK_DRAIN_GRACE`, 60 seconds): one started before
the limit was set, which doesn't know it. A pipeline that hands over
between units of work (`morca.outdated()`) ends long before.

**Upgrading to #390.** Add `DRAIN_SECONDS=<seconds>` to `hetzner.env`
before the first deploy with these scripts: until you do, `deploy.sh`
stops with "DRAIN_SECONDS isn't set: set DRAIN_SECONDS in hetzner.env
...", having changed nothing. Overlap is then on unless you add
`OVERLAP=0`. A stack that had it off pauses and waits once more, on the
deploy that turns it on; one that had `OVERLAP=1` already overlaps, and
the old scheduler it replaces, started without the limit, is stopped by
its reaper once the limit has run out.

### The check after each deploy

Every `deploy.sh` (a rollback too) ends with `morca-stack check`, a smoke
check that prints a line per item, `ok` or `FAIL` with why, and fails the
deploy when one fails. It undoes nothing; `./deploy.sh --rollback` is the
way back. It checks:

- Postgres answers, and each container (scheduler, ui, sampler, the apps,
  cloudflared) is running the image `stack.conf` says, the UI and the apps
  healthy as apply probes them;
- one scheduler: no `scheduler-next` is left (an exited one the apply has
  removed), and unless `OVERLAP=0` exactly one instance leads. An old
  scheduler still draining is an `info` line, not a failure:
  `scheduler-old-<time>: draining N run(s) (outdated)`;
- the pipelines: at least one registered, and each one's binary is in the
  scheduler's image (`morca-stack register` fixes a stale one; for one the
  image no longer has, `docker exec scheduler morca retire <pipeline>`); the
  paused ones are listed, the retired ones left out;
- canary runs, if `hetzner.env` has `CANARY="PIPELINE=KEY ..."`: a run each
  (`morca start`), one at a time, waited for up to `CANARY_TIMEOUT` seconds
  (default 1800), each of which must succeed. For a dev stack, not
  production: they are real runs.

`up.sh` runs it too, but only reports: a new stack has nothing registered
yet. Run it by hand with `ssh root@<ip> morca-stack check [--canary
PIPELINE=KEY]...`; `morca-stack checked` prints the last result, `ok` or
`failed`, its time, `plain` or `canary`, and the tags it checked, which is
what [promote.sh](#a-dev-stack) reads.

### A release's upgrade steps

A release that needs something done around its deploy says so in its
image, at `/opt/morca/upgrade.toml` (`MORCA_UPGRADE`), and `deploy.sh` shows
or runs it. Examples are a backfill after the deploy, or a check before it
such as a new secret, outbound HTTPS to a new host, or a minimum morca:

```toml
[[version]]
version = "1.2.0"

[[version.step]]
id = "1.2.0-retool"     # unique and stable
when = "after"          # before | after (the default)
run = "morca backfill --rerun mojo_retool @all"   # a morca command

[[version.step]]
id = "1.2.0-egress"
when = "before"
manual = "The console downloads its model from huggingface.co: allow outbound HTTPS."
```

A re-run too big to queue at once goes as a fill request (#465): the
scheduler runs it within the pipeline's fill limits (`keys_per_run`,
`fill_max_runs`, `fill_window`), after its other runs, and goes on across
restarts and later deploys
([A backfill as a fill](morca-toml.md#a-backfill-as-a-fill)):

```toml
[[version.step]]
id = "1.3.0-repos"
run = "morca backfill --rerun --as-fill mojo_repos 2023-01-01..2026-11-13"
```

`morca status <pipeline>` shows its progress, and `morca backfill --cancel
<pipeline>` stops it.

`morca upgrade --from <deployed> --to <new>` prints the steps of every version
after `--from` up to `--to`, a line each:
`step<TAB><id><TAB><before|after><TAB><run|manual><TAB><command or text>`.
Only the new version's steps are printed when `--from` isn't a version, a
commit for example. A `run` is one `morca` command of letters, digits, spaces
and `._:/@=,+-`. It's checked when the file is read and again on the
server, and runs in the scheduler (`docker exec scheduler morca ...`).

When the morca tag changes (not for a rollback), `deploy.sh`:

- **First reads the `before` steps** from the new image, pulled for it
  (`morca-stack upgrade-steps`), before anything else. It lists them, and
  each must be done before it goes on:
  - It asks for a manual one (`[id] done? [y/N]`), unless `--confirmed
    id,...` names it. With `--yes`, an unconfirmed manual step stops the
    deploy, nothing changed: do it, then deploy with `--confirmed <id>`.
  - It asks before running a command, or runs it with `--yes`.
- **After registering the pipelines, before unpausing them, does the
  `after` steps:** it runs each command (asking, or with `--yes`), and
  prints each instruction, waiting for Enter without `--yes`. A failed
  command doesn't stop the rest. The deploy then fails at the end, saying
  which step failed, with everything else deployed and checked.

What makes a step run once is the range: a deploy from 1.1.0 to 1.2.0 takes
1.2.0's steps, the next one from 1.2.0 doesn't, and a deploy that skips a
version takes the skipped version's steps too. A command that several of
those versions ask for (the same `run` and `when`, after trimming spaces)
runs once, where its last version has it, for all their ids: `ran 'morca
backfill --rerun mojo_retool @all' for 1.2.0-retool, 1.3.0-retool`, and a
failure fails them all. A narrower command isn't merged into a wider one.
A `before` command named in `--confirmed` needs all its ids there.
`morca upgrade --from <deployed> --to <new>`, run in the new image, prints
that plan. Nothing is recorded in the
database, so a deploy of the same tag again (`--all`) runs none, and a
rollback and a deploy forward again run them again. A dry run prints the
`morca-stack upgrade-steps` commands but can't list the steps: it doesn't
reach the server. An image whose morca has no `morca upgrade` (before 0.23)
has no steps.

### The first deploy after the rename to morca

A server set up with orca-hetzner (0.24.x and before) has `ORCA_*` keys and
runs images whose scheduler is `/opt/orca/bin/orca`. With these scripts:

- `morca-stack plan` and `apply` refuse an image with no
  `/opt/morca/bin/morca` before anything changes, so deploy.sh stops before
  it pauses anything. Deploy such an image with orca-hetzner 0.24.x.
- The first `apply` of a morca image renames `stack.conf`'s and
  `settings.env`'s `ORCA_*` keys to `MORCA_*` (keeping each file as
  `NAME.orca`), and replaces the scheduler after a quiesce, without an
  overlap. Until then `configure` keeps writing orca's key names, and
  `status`, `plan` and `tags` change nothing.
- The orca deploy before can't be rolled back to: its images read `ORCA_*`.
  Its tags are in `/etc/orca/deployed.prev.orca`.
- `hetzner.env` needs `MORCA_*` names; deploy.sh refuses `ORCA_*` ones.

## Rolling back

**What is kept.** Each apply that changes a tag records the tags it
replaced on the server: `/etc/orca/deployed` has what runs now (the morca tag
and each app's), `/etc/orca/deployed.prev` what ran before, and
`MORCA_PREV_TAG` in `/etc/orca/stack.conf` that morca tag. Applying the same
tags again keeps the earlier ones. `ssh root@<ip> morca-stack status` shows
both (`deployed: b2b9558   before: ac0c766`), `morca-stack tags [--previous]`
prints one. `deploy.sh` also backs the database up just before each apply
and prints the dump's key, with a `<time>.paused` beside it saying which
pipelines were paused by hand and which by the deploy. The tags are kept from the first deploy with this
`morca-stack` on; before that, the stack's conf is taken as what ran.

**The whole stack.** From the laptop:

```sh
./deploy.sh --rollback                 # quiesce, backup, morca-stack rollback, resume
./deploy.sh --rollback --force         # without waiting: kills the running runs
```

It does what a deploy does (copies `morca-stack`, asks for the plan, pauses
and waits if the scheduler is replaced, backs up), then `morca-stack
rollback`: applies the previous morca tag and the previous app tags (an app
that ran the morca tag follows it again, and one no longer set up is left
out), replacing the containers whose tags differ, and, if it replaced the
scheduler, registers the pipelines again (`docker exec scheduler morca
register`, from the rolled-back image's `morca.toml`), before it unpauses
anything. The older binaries have other registry hashes and maybe
another `morca.toml`, so the registration is what makes the scheduler start
runs with the code that's deployed. On the server, `morca-stack rollback
[--force]` does the same without the pause and the backup. A second rollback
goes forward again: the tags it replaced are now the previous ones.

**Only an app.** The census console is an app with its own tag; rolling it
back leaves the scheduler alone, so no run is killed and nothing needs
registering, with runs running or not:

```sh
ssh root@<ip> morca-stack apply --app console=<sha>
```

The console is replaced without downtime (above), as on a deploy, so a
rollback of it is invisible to readers too. `./deploy.sh <the morca tag that
runs> console=<sha>` does the same with a backup first, and so does `./deploy.sh --rollback` when the deploy before
changed only the console: its plan keeps the scheduler, so nothing is
paused, and `morca-stack rollback` registers the pipelines only when it
replaced the scheduler.

**Running runs.** As on a deploy: when the scheduler is replaced, without
`--force` it pauses the pipelines and waits up to `--timeout` for the
scheduler's running runs to end, and `morca-stack rollback` itself refuses
while any of those is running (runs on remote workers go on). With `--force` the
scheduler's restart kills them. The registration then does what it does
after any new build: queued runs, and failed ones waiting for a retry with
no step done, move to the rolled-back code and start once the pipelines are
unpaused; a run with steps done by the newer code fails, saying how to
resume it (`--allow-new-code`, or Resume with the new code in the UI); and a
manual, UI or rerun run whose process died is failed with an error.

**The schema.** Postgres is not rolled back: the older morca runs on the
newer schema. That works while every migration it doesn't know is
additive (new tables, indexes, and columns that are nullable or have a
default); the scheduler and UI then log `morca: the database is at schema
version 41, ahead of this binary's 40; its migrations since are additive,
so running on it` and go on. A migration that renames, drops or retypes
something, or changes what a value means, raises the floor (AGENTS.md's
Migrations; the list is `_floor_raisers` in `src/morca/_internal/migrations.mojo`), and an
morca from before it refuses to start: `morca: the database is at schema
version N, newer than this binary's M, and a migration since needs a binary
that knows at least K`. This applies from morca 0.16.0 (the first that
records floors) on: a rollback to an image with an older morca still stops
at any newer schema, additive or not, and needs the restore below.

**Crossing a floor-raising migration.** Then the database has to go back
too, to the backup taken before the upgrade:

```sh
ssh root@<ip> morca-stack list-backups      # the dumps, by time
ssh root@<ip> morca-stack restore --force backups/pg/20261108T101500Z.dump
ssh root@<ip> morca-stack rollback --force  # the old images on it, registered again
```

`deploy.sh`'s line before the upgrade's apply named the dump (`backup
s3://<bucket>/backups/pg/...`). `morca-stack restore` stops the scheduler
and the UI first, and the rollback starts them again. If a `deploy.sh
--rollback` already stopped at registering, with the scheduler's log
refusing the schema, the old images are deployed already (and `rollback`
would now go forward): restore, then `morca-stack apply` and `morca-stack
register` instead of the last line.

That dump was taken while the deploy had the pipelines paused. `morca-stack
restore` reads the dump's `<time>.paused` and unpauses the pipelines the
deploy paused, so the stack comes back as it was before the deploy; the
ones paused by hand or by the watchdog stay paused, and it prints both.
`list-backups` says which dumps have one (`paused state recorded`). A dump
without one (taken before morca-stack wrote them) leaves every pipeline that
was paused in it paused, and says so: unpause the ones the deploy's log
lists (`morca-stack: paused <name>`) with `docker exec scheduler morca
unpause <name>`. What happened in morca's database since the
dump is lost: runs and their steps, attempts and logs' records, sensor
progress, registrations, users and tokens added, watchdog trips. The
warehouse isn't in the dump: snapshots committed since stay in the tables,
and the runs that made them are gone from morca's history, so a rebuild or
backfill of those keys runs them again. The new runs are given the lost
runs' numbers, and commit all the same: a snapshot carries its run's token
as well as its number. A lost run of a morca from before run tokens (#292)
left snapshots without one, which a new run with its number, pipeline, step
and partition still takes for its own commits and doesn't write again.

**Finding a sha.** Images are tagged by the project's short commit sha on
GHCR, never by version: `morca-stack tags --previous` has the one before,
the project's `git log --oneline` the others (an image exists for each
commit its image job pushed, from the census's `dev` branch; the log ends
with `<short-sha>: digest: sha256:...`), and the package's page on GitHub
lists them.

## Rescaling for an import

```sh
./rescale.sh up                        # CAX21 -> CAX41, keeping the disk
# register the census with DISTA_WORKER_SLOTS = "14" and GHARCHIVE_PARALLEL = "14" if you want the 16 vCPUs used
# ... the fill runs; watch the pipeline page's Fill line ...
./rescale.sh down                      # CAX41 -> CAX21
```

Each does: pause every pipeline and wait for the running runs to end,
those on remote workers too, since the UI they talk to goes down with the
server (`morca-stack quiesce --workers`; `--timeout SECONDS`, default 3600; on a timeout it stops and leaves them
paused: `ssh root@<ip> morca-stack resume` undoes it), a backup, shut the
server down, `hcloud server change-type --keep-disk`, power on, wait for the
scheduler, and unpause what it paused (not pipelines the watchdog paused). It
is down for a few minutes. `--keep-disk` keeps the 80 GB root disk of the
small type, which is what allows coming back down; the data is on the Volume
anyway. `rescale.sh down` waits for the fill to be over or paused: to stop
earlier, cancel the runs in the UI.

## A cgroup per run

Every run on the server shares one machine. Where morca can make cgroups, each
run gets one with a memory limit (`memory.high`) at its grant, and the kernel
kills only that run's processes if they go 25% past it
(`MORCA_RUN_MEMORY_MARGIN`), or morca does once it has been held, throttled, at
the limit for two minutes (`MORCA_RUN_MEMORY_HELD_SECONDS`); the attempt fails `out of memory at <limit>`, and
the retry and the pipeline's later runs ask for 1.5 times as much
(`MORCA_RUN_MEMORY_GROWTH`), up to `memory_gb`'s maximum. Without it, a run
that runs away can push the machine into the kernel's OOM killer, which picks
the run's processes first (`oom_score_adj`) but may take others too.

**On by default** (since #239). The scheduler runs in a container, whose
`/sys/fs/cgroup` docker mounts read-only, so `morca-stack apply` starts it
with the flags below unless `CGROUPS=0` (in `/etc/orca/stack.conf`, set with
`morca-stack configure`). To see that it took:

```sh
ssh root@<ip> docker logs scheduler 2>&1 | grep 'run cgroups'
# morca: run cgroups on: runs' cgroups go in /sys/fs/cgroup
```

What it changes in the scheduler's `docker run` (nothing else's):

- `--cgroupns=private`: the container sees its own cgroup as
  `/sys/fs/cgroup` (docker's default on cgroup v2, said explicitly).
- `--cap-add SYS_ADMIN --security-opt apparmor=unconfined` and an entrypoint
  of `mount -o remount,rw /sys/fs/cgroup; exec /usr/bin/setpriv --bounding-set
  -sys_admin --inh-caps -sys_admin morca scheduler`: the remount needs the
  capability and AppArmor's leave, and the capability is dropped from the
  bounding set before morca starts, so neither morca nor any run it starts has
  it. (`--privileged` would work too, and gives far more.) A remount that
  fails doesn't stop the scheduler: it says so on its log and starts with
  `/sys/fs/cgroup` read-only, where morca turns run cgroups off (below).

morca then moves itself into `/sys/fs/cgroup/morca` (a cgroup that gives its
children controllers can hold no processes), turns on the memory controller
for the container's cgroup's children, and makes `morca-run-<run>-<start>-<pid>`
beside it for each run. The container's own limits and the host's other
cgroups are out of its reach: under a private namespace with `nsdelegate`, the
container's root cgroup's `memory.max` isn't writable from inside, and nothing
above it is visible. `docker exec scheduler ...` (morca-stack's quiesce,
`morca pause`) still works: runc puts it in `morca`.

**CPU** (#229). Runs may use every idle core, but the scheduler wins when
the cores are busy: where the container's cgroup has the cpu controller,
morca turns it on for its children too, and each run's cgroup gets
`cpu.weight` `MORCA_RUN_CPU_WEIGHT` (20, against the 100 of the scheduler's
`morca` leaf) and, for a run granted `cpus`, `cpu.max` at that many cores, so
it can't exceed its grant either. Without run cgroups, or without the cpu
controller, a run starts at `nice` `MORCA_RUN_NICE` (10; 0: off) instead,
which everything it starts inherits, dista's local workers included.
Control-placed runs also keep `MORCA_CONTROL_NICE`. The UI and Postgres
are containers of their own, which the kernel already weighs against the
scheduler's container as a whole. The scheduler says which on its log:

```
morca: runs' CPU priority: cpu.weight 20 (MORCA_RUN_CPU_WEIGHT) in each run's cgroup, cpu.max at a CPU grant
```

`morca worker` does the same on its own host. Ops › Control's Runs card
shows each run's (CPU), and `morca status` the settings, as the UI's and the
command's own environment have them: set them in `settings.env`, which the
scheduler and the UI both read.

**A host that can't.** On a host without cgroup v2 (`/sys/fs/cgroup/cgroup.controllers`),
or whose cgroup v2 has no memory controller, `apply` and `plan` start the
scheduler without the flags, as with `CGROUPS=0`, and say why:

```
morca-stack: run cgroups off: this host has no cgroup v2 at /sys/fs/cgroup (cgroup v1?), so the scheduler runs as with CGROUPS=0
```

The servers `up.sh` makes (Ubuntu 24.04) have both.

**What changes for runs.** For the machine, it only adds a boundary; the
capability is gone before morca runs, so the one thing given up for good is
docker's AppArmor profile on the scheduler's container. What changes is what
runs may use: a run is throttled past its grant and killed 25% above it,
where without it, it may take what's free. With run cgroups on, `apply`
(and `plan`, on standard error) warns for each pipeline whose runs here
peak above the most a cgroup lets them have: the 95th percentile of the
peaks of its last 20 successful runs (at least 3) against its `memory_gb`'s
maximum, else what the host can grant (its memory less
`MORCA_RESERVE_MEMORY_MB`). It doesn't stop the apply:

```
morca-stack: warning: gharchive peaks at 9000 MB (95th percentile of its last 20 runs), over memory_gb's maximum, 8 GB: its runs will be throttled there and killed 25% above (raise memory_gb's maximum, or CGROUPS=0)
```

The pipeline's page shows the same peaks (Resources: the max of its peaks,
#203). Raise the maximum where they don't fit; a pipeline without a request
is limited only to what the host can grant.

**Turning it off.** For the stack:

```sh
ssh root@<ip> morca-stack configure CGROUPS=0
ssh root@<ip> morca-stack apply           # replaces the scheduler only; pause first, or --force
```

`CGROUPS=1` (or the line removed from `stack.conf`) turns it on again.
`MORCA_CGROUPS=0` in `settings.env` (a line of `EXTRA_ENV_FILE`) turns it
off from morca's side, leaving the flags. There is no switch for one
pipeline: give it room instead, a `memory_gb` whose maximum is over its
peaks, or none, so its runs may grow to what the host can grant.

Where morca can't make cgroups (`CGROUPS=0`, a host as above, macOS, cgroup
v1), the scheduler says why once (`morca: run cgroups off: ...`) and runs as
before: `first_to_go`, and control-placed runs killed over
`MORCA_CONTROL_MEMORY_MB`. Ops > Control lists each run going with its
memory against its limit.

## Worker pools that grow themselves

A `[pools.<name>]` table in morca.toml ([morca-toml.md](morca-toml.md#worker-pools))
has the scheduler make and remove Hetzner machines as runs wait. On this
stack it needs a Hetzner API token (read-write) for the project the
machines go in:

```sh
# SECRETS_FILE: a key secrets/orca/hcloud-token, or in hetzner.env:
HCLOUD_POOL_TOKEN_FILE=~/ops/mojourney/hcloud-token.sops
```

`deploy.sh` then sends it to `/etc/orca/secrets/orca/hcloud-token` and puts
in settings.env `MORCA_HCLOUD_TOKEN_SECRET`, the firewall
(`MORCA_HCLOUD_FIREWALL`, the stack's, ssh from `ADMIN_IP` only) and SSH key
(`MORCA_HCLOUD_SSH_KEYS`, the stack's) each machine gets (`POOL_FIREWALL`
and `POOL_SSH_KEYS` name others), and `MORCA_UI_URL` from `UI_URL`, where the
machines reach the UI. `morca-stack` gives the scheduler and the UI
`MORCA_WORKER_IMAGE`, the image it's running, which the machines run too,
and with `GHCR_USER` the registry login (`MORCA_REGISTRY_USER`,
`MORCA_REGISTRY_TOKEN_SECRET=orca/ghcr-token`) a booting machine pulls it
with. A machine's own startup script holds only a worker token of its own.

## Backups and restore

The server runs `morca-stack backup` every night at 02:30 UTC
(`orca-backup.timer`; `systemctl list-timers` and `journalctl -u
morca-backup` on the server). It writes `pg_dump -n orca -Fc` (the format
[replace-control.md](replace-control.md) uses), checks that it reads back,
uploads it to `s3://<bucket>/backups/pg/<time>.dump` (each upload tried
three times), and keeps the newest 14 (`BACKUP_KEEP`). Deleting the older
ones is best effort: a failed delete only warns, the backup still succeeds,
and the next backup deletes it.
Beside each dump is `<time>.paused`: the pipelines paused when it was taken,
as `paused_by_hand` and `paused_by_deploy` (the ones a deploy's quiesce
paused), which a restore uses to unpause the latter
([Rolling back](#rolling-back)).

```sh
./backup.sh            # now, e.g. before a risky step
./backup.sh list
```

To restore onto a new server and an empty Volume (after `down.sh --all`, or a
lost server):

```sh
./up.sh --restore latest                  # or --restore backups/pg/20261107T023000Z.dump
```

It starts Postgres, restores before the scheduler first starts, then starts
everything. On an existing database, `ssh root@<ip> morca-stack restore --force
<key>` drops the `morca` schema first, then `morca-stack apply`. The warehouse
is in the bucket and needs no restore; only morca's own state (runs, pipelines,
users) is in the dump. Test a restore before you need one.

## Alerts on your phone (ntfy)

The UI is where problems show, so morca can also push the important ones to
your phone through [ntfy](https://ntfy.sh): a watchdog trip, a run that
failed after its last retry, a fill that stalled, a failed nightly backup, the
disk over 85%, a lost worker, each with a link to the UI. Once:

1. Install the ntfy app (iOS, Android) and subscribe to a topic with a long
   random name, e.g. the output of `openssl rand -hex 16`. Anyone who knows
   the topic can read what is sent to it, so treat the name as a secret.
2. Put the topic in a file on the laptop (mode 600), and its path in
   `hetzner.env` as `NTFY_TOPIC_FILE`; `up.sh` writes it to
   `/etc/orca/secrets/orca/ntfy-topic` and sets `MORCA_NOTIFY_SECRET=orca/ntfy-topic`
   (read through `MORCA_SECRET_FETCH` like the other secrets, never logged).
   `NTFY_URL` is the server (default `https://ntfy.sh`; a self-hosted one
   works), `NTFY_TOKEN_FILE` an access token for a protected topic, and
   `UI_URL` (`https://orca.mojourney.dev`) is what the notifications link to
   (`MORCA_UI_URL`).
3. `./up.sh`, then `ssh root@<ip> docker exec scheduler morca notify test`:
   the phone should show "morca: test alert".

Ops > Control lists whether alerts are on and the last ones sent. The same
alert is sent at most once every 30 minutes (`MORCA_NOTIFY_MIN_SECONDS`), and
one that could not be sent (ntfy down) waits in Postgres and goes later. The
nightly backup runs `morca notify --kind backup-failed` on failure.

## Apps

An app beside the UI (the census console) is a binary of the image,
`/opt/morca/bin/<name>`, on the stack's network, served through the
tunnel. `APPS=console` in `hetzner.env` names the apps a stack runs, and
the image's `morca.toml` says what each one gets (#331):

```toml
[apps.console]
port = 8080                       # $PORT, where the tunnel's route points
check = "/healthz"                # answers 200 once it's ready (default /)
env = { CONSOLE_SEMANTIC = "1" }
lake = true                       # the warehouse settings and the stack's S3 keys
secrets = { POSTHOG_KEY = "orca/posthog-key" }
memory_gb = 1                     # docker --memory (no limit without it)
```

`morca-stack plan` and `apply` read it from the app's own image (`morca
config apps`, the [overlay](#a-stacks-overlay) laid on it) and write the
app's env file, `/etc/orca/app-<name>.env` (mode 600), from it: its `env`,
the lake with `lake = true` (`AWS_REGION`, `AWS_ENDPOINT_URL_S3`,
`MORCA_WAREHOUSE`, `MORCA_PUBLIC_WAREHOUSE` and `s3.env`; never morca's
database), each secret's value from `/etc/orca/secrets/<id>`, and `PORT`.
A secret is a key `secrets/orca/<id>` in `SECRETS_FILE`, sent as the
others are; one the server hasn't stops the deploy at the plan, before
anything is paused. Values are never printed, and a change to one replaces
the app (without downtime).

`APPS=console:8080` still works: the port is then the one for an app
whose `[apps.console]` gives none, and one that differs from it is
refused. An app the image's `morca.toml` doesn't declare, or an image
whose morca has no `config apps` (before 0.25), gets the fixed env of
before (the lake, and `MORCA_POSTHOG_KEY` as `POSTHOG_KEY`), and the plan
says so.

## Analytics (PostHog)

The UI and the census console can load PostHog the way the magmalake.org
website does: `array.js` and the events go through `/ph` on the page's own
origin, memory-only persistence (no cookies, no `localStorage`, so no consent
banner), and a `site` property on every event (`morca` or `mojourney`) so one
PostHog project can hold both. Once:

1. Optionally, a first-party proxy, so ad-blockers keep the events: the
   census's is `/ph`, a Cloudflare Worker on the mojourney.dev zone's
   `mojourney.dev/ph/*` and `orca.mojourney.dev/ph/*` routes. It lives in
   magmalake/magmalake.org: `npx wrangler deploy -c worker/mojourney-ph/wrangler.jsonc`.
   The tunnel serves everything else; nothing on the server serves `/ph`.
   Set `POSTHOG_HOST=/ph` in `hetzner.env` (`MORCA_POSTHOG_HOST`: a path on
   the UI's origin or an `https://` origin). Without it the UI talks to
   PostHog's own US hosts.
2. Put the project key (`phc_...`, public, the website's `POSTHOG_KEY` in its
   `src/data/site.ts`) in `hetzner.env` as `POSTHOG_KEY`. `up.sh` writes it
   to `settings.env` as `MORCA_POSTHOG_KEY`, which the UI reads. On a
   server set up before, the next `./deploy.sh` (the tag that runs will do)
   writes it and replaces the UI ([Settings](#settings-from-hetznerenv)).
3. An app gets the key only if it asks: `secrets = { POSTHOG_KEY =
   "orca/posthog-key" }` in its `[apps.<name>]` ([Apps](#apps)), and the
   key in `SECRETS_FILE` as `secrets/orca/posthog-key`. (An app morca.toml
   doesn't declare still gets `MORCA_POSTHOG_KEY` as `POSTHOG_KEY`, as
   before.)
4. Open https://orca.mojourney.dev and https://mojourney.dev: each page's
   head has `/ph/static/array.js`, and PostHog's Activity shows `$pageview`
   events with `site` set.

Leave `POSTHOG_KEY` empty and nothing is added to the UI's pages.

## Teardown

```sh
./down.sh          # deletes the server; the Volume and the bucket stay; up.sh brings it back
./down.sh --all    # also the Volume (the database), firewall and ssh key; asks for the Volume's name
```

Both ask first (`--yes` to skip). The bucket is never touched: delete it in the
Hetzner console. The Volume has delete protection, which `--all` lifts.

## Images

The scripts pull `<MORCA_IMAGE>:<tag>`, the project's image (`MORCA_IMAGE` in
`hetzner.env`, `ghcr.io/morca-dev/census` unless it says otherwise). Name a
project's image after the project, `ghcr.io/mojourney/census` rather
than `ghcr.io/morca-dev/census`: it's the project's code, versioned by the
project. The census's is still `ghcr.io/morca-dev/census`.

**The runtime image.** Each morca release has
`ghcr.io/morca-dev/morca-runtime:<version>` (`0.24.0`, for linux/arm64 and
linux/amd64; [`deploy/runtime.Dockerfile`](../deploy/runtime.Dockerfile)):
morca's own `morca` and `morca_maintain`, git, libcurl, the CA bundles where
libcurl, OpenSSL and flare look for them, llvm-symbolizer, and the
`/opt/morca` layout and environment, installed from a committed lock
(`deploy/runtime/pixi.lock`). It's built on distroless
(`gcr.io/distroless/cc-debian12`: glibc, libstdc++, CA certificates and
tzdata) with a static busybox for `sh` and the usual tools (`cat`, `test`,
`mount`, `nc`, ...), util-linux's `setpriv`, and an `ldd`: no bash and no
apt. morca's CI builds and tests it on every pull
request, and on main pushes it as `morca-runtime:<sha>`; a release tags its
commit's image `<version>` once main has pushed it, rebuilding nothing. A
project's image builds `FROM` it and adds only its own programs:
[`deploy/project.Dockerfile`](../deploy/project.Dockerfile), the image
`morca aws push` builds, compiles the project's `bin/*.mojo` and
`pipelines/*.mojo` into `/opt/morca/bin` and `/opt/morca/pipelines`, with the
libraries they link, and copies the project's `morca.toml` to
`/opt/morca/morca.toml` with `MORCA_CONFIG` naming it, so `morca-stack
register` (a bare `morca register`) reads it. `MORCA_VERSION` picks the runtime: the morca-mojo
version the project pins (`morca aws push` reads it from `pixi.lock`), so
the runtime and the pipelines are the same morca. Moving the project to a
new morca moves its image to that release's runtime. A
`bin/scheduler.mojo` or `bin/morca_maintain.mojo` of the project's own
replaces the runtime's; without them the image runs the runtime's.

A project with a `Dockerfile.morca` of its own (the census) can start it the
same way:

```dockerfile
ARG MORCA_VERSION
FROM ghcr.io/morca-dev/morca-runtime:${MORCA_VERSION}
COPY --from=build /out/bin /opt/morca/bin
```

and build it with `--build-arg MORCA_VERSION=<the morca it pins>`. A
`RUN` in a stage `FROM` the runtime runs busybox `sh`: there is no bash or
apt-get there, so install packages in a build stage and copy them in. A
`Dockerfile.morca` that builds everything itself, like the census's today,
keeps working as before.

A project publishes its image to GHCR from its own CI, tagged `<short-sha>`
of the commit (and its own version, for a release of the project); morca's
versions name only the runtime (`MORCA_TAG=0.10.0` is not a project image). The census builds and pushes only from
its `dev` branch (also tagged `dev`; main builds no image, and `latest` is
no longer moved), so a release reaches `dev` first, then the dev stack, then
production. To find a sha, read the `dev` branch's image job in the
project's Actions: its log ends with `<short-sha>: digest: sha256:...` for
the push. `MORCA_TAG` in `hetzner.env` is the tag the first `up.sh` starts
(`dev` will do; `deploy.sh <short-sha>` moves it afterwards).

The tunnel runs `cloudflare/cloudflared` at a release tag
(`CLOUDFLARED_IMAGE`, `2026.10.7` unless `hetzner.env` says otherwise), not
`latest`: `morca-stack apply` pulls the image every time, so with `latest` an
upstream release would change the tunnel's version, and restart it, on
whichever deploy came next. To bump it, pick a release (`gh release list -R
cloudflare/cloudflared`; the image has the same tag), set
`CLOUDFLARED_IMAGE=cloudflare/cloudflared:<tag>` in `hetzner.env` and
deploy (the next `deploy.sh` sets it on the server and replaces the
tunnel). A `morca-stack configure CLOUDFLARED_IMAGE=...` on the server by
hand lasts only until the next deploy, which sets `hetzner.env`'s again.
The tunnel restarts once, which drops traffic for a few seconds. The
defaults in `lib.sh` and `morca-stack` only apply when `hetzner.env` doesn't
set it; bump them along with the example's.

morca's reusable workflows build, check, test and push it for both
architectures, and make a tag's release: see [A project's CI](project-ci.md).
By hand, for example:

```yaml
permissions: { contents: read, packages: write }
steps:
  - uses: docker/login-action@v3
    with: { registry: ghcr.io, username: "${{ github.actor }}", password: "${{ secrets.GITHUB_TOKEN }}" }
  - run: docker buildx build --platform linux/arm64 -f Dockerfile.morca --build-arg MORCA_VERSION=0.24.0 -t ghcr.io/mojourney/census:${{ github.ref_name }} --push .
```

The workflow's `GITHUB_TOKEN` can push to a package only if the package lets
the repository write to it (the package's settings > Manage Actions access).
The runtime package, `morca-runtime`, must be public for a project's build
to pull it without a login (or the build logs in to GHCR first).
The server needs ARM images (`linux/arm64`). A new GHCR package is private,
and an organization may forbid public packages, so the private route is the
default: set `GHCR_USER` and `GHCR_TOKEN_FILE` in `hetzner.env` (a token with
`read:packages`, in a file of its own). Making the package public is the
alternative only where the organization allows it. ECR stays as it is for
AWS.

**Build for the server's CPU.** The server is Neoverse N1 (Ampere Altra);
GitHub's arm64 runners are Neoverse N2, with SVE2. `mojo build` targets the
CPU it runs on, so a binary built on a runner dies on the server with
SIGILL (exit 132). The image `morca aws push` builds from
[`deploy/project.Dockerfile`](../deploy/project.Dockerfile) passes
`--target-cpu "$MOJO_TARGET_CPU"` (default `neoverse-n1`; N1 code runs on
N2, V1, V2 and Graviton), and the runtime image's arm64 binaries are built
for N1 too. A project with its own `Dockerfile.morca` must do the same in
every `mojo build` of it:

```dockerfile
ARG MOJO_TARGET_CPU=neoverse-n1
RUN pixi run sh -c 'for f in bin/*.mojo; do mojo build --target-cpu "$MOJO_TARGET_CPU" "$f" -o "/out/bin/$(basename "$f" .mojo)" || exit 1; done'
```

## S3-compatible storage

morca and the census read `AWS_ENDPOINT_URL_S3` (else `AWS_ENDPOINT_URL`),
`AWS_REGION` and `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
(objectstore.mojo). With an endpoint set it uses path-style addressing
(`AWS_S3_FORCE_PATH_STYLE=1` forces it otherwise) and never asks for an
instance role. For Hetzner: `AWS_ENDPOINT_URL_S3=https://<location>.your-objectstorage.com`
and `AWS_REGION=<location>`. The same settings were tried locally against
MinIO.

## Costs

Prices change; check hetzner.com for the current ones before you start.
Roughly, at the time of writing: the CAX21 (4 ARM vCPU, 8 GB, 80 GB) is a
few euros a month, the CAX41 (16 vCPU, 32 GB) about four times that; both are
billed by the hour up to the monthly price, so a few days of CAX41 for the
import cost about five euros and the rest of the month is the small
server's price. Add the Volume (per GB-month, 50 GB by default) and Object
Storage (a base monthly price covering some storage and traffic, more beyond
that). Cloudflare Tunnel is free. A stopped server is still billed; delete it
(`down.sh`) to stop the charge. Nothing here launches instances, so the bill
cannot grow by itself except for storage and traffic.

## A stack's overlay

A project ships one `morca.toml`; what one stack runs differently (no
fills on a dev stack, one pipeline on a lab stack) goes in that stack's
overlay, a file kept beside its `hetzner.env`, as in a secrets
repository's `dev/morca.overlay.toml`
([morca-toml.md](morca-toml.md#a-stacks-overlay) has the format and how
it's merged). In `hetzner.env`:

```sh
CONFIG_OVERLAY_FILE=morca.overlay.toml    # relative to this file's folder
```

Each `up.sh` and `deploy.sh` then:

- sends it to the server as `/etc/orca/overlay/morca.overlay.toml` (`morca-stack
  sync`, saying `new`, `changed` or nothing), and `settings.env` gets
  `MORCA_CONFIG_OVERLAY=/etc/orca/overlay/morca.overlay.toml`; taken out of
  `hetzner.env`, both are removed;
- has the new image's morca check `morca.toml` with it (`morca config
  check`, in `morca-stack plan` and `apply`) before anything is paused or
  replaced. A bad overlay, or an image whose morca doesn't read overlays
  (before 0.25, which would register without it), stops the deploy there;
- mounts `/etc/orca/overlay` in the scheduler only. The overlay is one of
  the scheduler's files: a change to it replaces the scheduler (`scheduler
  replace settings: its env file or the overlay changed`), so the deploy
  quiesces and registers again, now with it.

To see what a stack registers, before a deploy:

```sh
docker run --rm -v "$PWD/dev:/o" --entrypoint /opt/morca/bin/morca \
    ghcr.io/morca-dev/census:<tag> config show --file --overlay /o/morca.overlay.toml
```

## A dev stack

A second, smaller stack to try a release, a deploy or a deploy-script change
before production sees it (#250). It is a second settings file: `NAME`
prefixes every Hetzner resource (server, firewall, Volume `NAME-data`, ssh
key) and the scripts look them up by that name, so `NAME=orca-dev` never
touches `morca`'s. Everything else is on the server itself (`/etc/orca`,
Postgres on its own Volume) or names its own bucket and tunnel. Every script
starts by saying which stack it acts on (`deploy.sh: stack morca-dev,
settings ...`). The two stacks share `known_hosts`
(`~/.local/state/morca-hetzner/known_hosts`), which is keyed by address.

It can be in the production project or a Hetzner project of its own. Its
own project keeps its API token and Object Storage keys apart from
production's (Object Storage keys reach every bucket of their project); set
`HCLOUD_CONTEXT` in its settings file to that project's hcloud context. In
the same project, Hetzner takes a public key only once, so `up.sh` uses the
existing key with the same public key (production's `morca`) instead of
making `morca-dev`; `down.sh --all` then leaves that key alone.

**Settings**, e.g. `~/.config/morca-hetzner/dev.env` (from
`hetzner.env.example`; what's not listed is as there or empty):

```sh
NAME=orca-dev
#HCLOUD_CONTEXT=morca-dev                # if it's in a project of its own
LOCATION=fsn1
SERVER_TYPE_SMALL=cax11                 # 2 vCPU, 4 GB: enough without the backfill
VOLUME_SIZE_GB=10                       # the smallest
SSH_PUBLIC_KEY_FILE=$HOME/.ssh/id_ed25519.pub
ADMIN_IP=203.0.113.7/32
BUCKET=morca-dev-warehouse               # its own bucket
S3_ENDPOINT=https://fsn1.your-objectstorage.com
S3_REGION=fsn1
S3_CREDENTIALS_FILE=$HOME/.config/morca-hetzner/dev-s3.env
TUNNEL_TOKEN_FILE=$HOME/.config/morca-hetzner/dev-tunnel.env   # its own tunnel
MORCA_TAG=<short sha>                    # the tag the first up.sh starts
GHCR_USER=...                           # as production's, for the private package
GHCR_TOKEN_FILE=...
GITHUB_TOKEN_FILE=$HOME/.config/morca-hetzner/github-token     # or mojo_repos's and mojo_stats's runs fail
CONFIG_OVERLAY_FILE=$HOME/.config/morca-hetzner/dev.overlay.toml
DRAIN_SECONDS=3600                      # required: an old scheduler drains for an hour at most
# No NTFY_TOPIC_FILE: no alerts. Or a topic of its own, never production's.
# No POSTHOG_KEY: the dev pages stay out of the analytics.
```

with `dev.overlay.toml` the [stack's overlay](#a-stacks-overlay) on the
census's `morca.toml`: no fills and no worker pool's placement, so a dev
stack never backfills from 2023, and the pipelines only it runs enabled:

```toml
[pipelines.gharchive]
fills = "since_registration"

[pipelines.ballast]
enabled = true
```

morca has no "fill the last N days" setting. For some history, backfill a
recent range by hand once, e.g. `docker exec scheduler morca backfill
gharchive 2026-10-09..2026-11-07`.

Before overlays (morca 0.25), a stack chose a whole file of the image's
instead, with `MORCA_CONFIG=/opt/morca/morca.dev.toml` in its
`EXTRA_ENV_FILE`. That still works (`settings.env`, then `morca.env`, ahead
of the image's own `MORCA_CONFIG`), and an overlay is laid on whichever
file that names.

The tunnel's public hostnames, Proxied as for production: the census's dev
stack has `orca-beta.mojourney.dev` to `http://ui:8270` and
`beta.mojourney.dev` to `http://console:8080`, with `UI_URL` set to the
first. One level below the zone, because Cloudflare's free Universal SSL
certificate covers `mojourney.dev` and `*.mojourney.dev` only:
`orca.beta.mojourney.dev` would need an Advanced Certificate.

**Images.** The census's CI pushes `ghcr.io/morca-dev/census:<short sha>` from
its `dev` branch (and `dev`); main builds none, so both stacks deploy dev's
images. To try a morca main commit, pin it on the census's `dev` branch
(`morca-mojo = { git = ..., rev = "<sha>" }` in `pixi.toml`, then `pixi lock`),
push, and deploy the short sha of that census commit.

**Making it and deploying**, from `deploy/hetzner`:

```sh
export HETZNER_ENV=~/.config/morca-hetzner/dev.env   # in this shell only
./up.sh --dry-run                       # every command names morca-dev
./up.sh
ssh root@<ip> docker exec -it scheduler morca user add <you>
ssh root@<ip> morca-stack register       # morca.toml's, with the overlay
./deploy.sh <tag>                       # later deploys
./down.sh                               # when it's not needed: the Volume stays, up.sh brings it back
```

**Release check list on dev**, before the same tag goes to production.
Set `CANARY` in the dev stack's settings (e.g. `CANARY="mojo_repos=2026-11-01
gharchive=2026-11-08"`) and steps 2, 3 and 5, and step 4 inside the server (not the public URLs), are
[the check deploy.sh ends with](#the-check-after-each-deploy):

1. `./deploy.sh <tag>`: it ends with `check: all ok` and `done`, and says
   what it replaced.
2. `ssh root@<ip> morca-stack status`: every container up, `deployed: <tag>`
   and `before:` the tag before.
3. The pipelines registered: `docker exec scheduler morca status` lists
   each the overlay leaves enabled, from `<tag>`, and the ones paused before are
   still paused.
4. `curl -s -o /dev/null -w '%{http_code}\n' https://orca-beta.mojourney.dev/healthz`
   says 200, and the console (`https://beta.mojourney.dev`) answers.
5. One manual run per pipeline (`morca start <pipeline> <partition>`, or the
   UI's run button), each succeeding.
6. A deploy with a run in flight: start a long run, `./deploy.sh <tag>
   --all`, and see it pause, wait and resume (with `OVERLAP=0` in the dev
   stack's `hetzner.env`). Then with overlapping schedulers, the default:
   take `OVERLAP=0` out, deploy once to turn it on, start a run, deploy
   again: nothing paused, the deploy
   returns while the run goes on under `scheduler-old-<time>` (the check
   says it's draining, its page says it's outdated), and once it ends the
   old scheduler is removed.
7. `./deploy.sh --rollback` (back to the tag before, registered again), then
   `./deploy.sh --rollback` again to go forward; `morca-stack status` shows
   `<tag>` deployed.

Then promote what dev checked, from production's settings:

```sh
export HETZNER_ENV=~/.config/morca-hetzner/hetzner.env   # production's
./promote.sh --from ~/.config/morca-hetzner/dev.env      # --dry-run first, if you like
```

`promote.sh` asks the dev stack for its last check (`morca-stack checked`)
and refuses unless it passed on the tags dev runs now, so the tags that
ship are the ones that were tested, never rebuilt. It then runs
`deploy.sh` with them (`<tag>`, plus `console=<tag>` for an app on its own
tag) and any of deploy.sh's flags given (`--no-backup`, `--timeout S`,
`--yes`, ...). It warns when dev's check ran no canary.

**Cost**: a CAX11, its IPv4 address, a 10 GB Volume and its bucket's
storage: a few euros a month (see [Costs](#costs)). In a project of its own,
Object Storage's base monthly price is charged again. `down.sh` stops the
server's charge between releases.

## Not verified

This was written without a Hetzner account: no server was created, and the
scripts were checked with `shellcheck`, `--dry-run`, cloud-init's schema
checker, and the container set against MinIO on a workstation. First real
run: do `up.sh --dry-run`, then `up.sh`, and read its output. Unverified
against the real service: Object Storage's endpoint name and path-style
addressing, the Volume's `/dev/disk/by-id/scsi-0HC_Volume_<id>` name in
`cloud-init.yaml`, and the `hcloud ... -o json` field names the scripts read
with `jq` (`.id`, `.status`, `.server_type.name`, `.applied_to`).
