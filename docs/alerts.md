# Alerts to your phone

Problems otherwise show only in the UI. With an [ntfy](https://ntfy.sh)
topic set, the scheduler pushes the important ones to the ntfy phone app,
each with a link into the UI. The code is `src/morca/_internal/notify.mojo` (sending)
and `src/morca/_internal/alerts.mojo` (what is sent).

```sh
export MORCA_NOTIFY_URL=https://ntfy.sh/$(openssl rand -hex 16)   # subscribe to this topic in the app
export MORCA_UI_URL=https://morca.example.com                      # where the notifications link to
morca notify test                                                 # the phone shows "morca: test alert"
```

Anyone who knows the topic can read what is sent to it, so treat its name
as a secret. On the Hetzner server, `NTFY_TOPIC_FILE` in `hetzner.env` does
this for you: see [hetzner.md](hetzner.md#alerts-on-your-phone-ntfy).

## What is sent

| Kind | When | Priority |
|---|---|---|
| `watchdog` | a [watchdog](watchdog.md) rule tripped and paused pipelines | high; a low "resolved" once it is acknowledged or its pipelines are unpaused |
| `run-failed` | a run failed after its last retry | default |
| `fill-stalled` | a [fill](morca-toml.md#fills) has had no fill run finish in `MORCA_NOTIFY_FILL_STALL_HOURS` (2) | high; "moving again" once it is |
| `disk` | the control host's fullest disk is over `MORCA_NOTIFY_DISK_PERCENT` (85) | high; "fine again" once it is under |
| `worker-lost` | a [remote worker](workers.md) holding runs has been quiet for `MORCA_NOTIFY_WORKER_SECONDS` (300) | default |
| `pod-stuck` | a [Kubernetes](morca-toml.md#stuck-pods) run's pod has been unable to start (no node it may go on, or an image it can't pull) since before the start grace, `MORCA_START_SECONDS` (300); once per run and start | high |
| `memory-pressure` | the scheduler's host, or a worker's, has held new runs for [memory pressure](morca-toml.md#memory-pressure) for `MORCA_ADMIT_PRESSURE_GRACE_SECONDS` (600) with none of morca's runs going there; runs then start one at a time | high; "has eased" once it doesn't hold |
| anything | a script ran `morca notify --kind <kind> ...` | as given |

Each is one POST of plain text with ntfy's `Title`, `Priority`, `Tags` and
`Click` (the run's page or Ops › Control on `MORCA_UI_URL`) headers.

The same alert, by kind and subject, is sent at most once per
`MORCA_NOTIFY_MIN_SECONDS` (1800). What was sent is kept in Postgres
(`orca.notifications`), so a restart doesn't send it again. A send that
fails (ntfy down, a timeout) is logged without the URL and tried again on a
later tick, after a wait that doubles from 30 seconds to 15 minutes. It
never blocks or fails the scheduler.

## Settings

The scheduler reads these. None is logged or put in a message.

| Variable | Default | |
|---|---|---|
| `MORCA_NOTIFY_URL` | unset: no alerts | a topic URL, or just a server (`https://ntfy.example.com`) when the topic comes from the secret |
| `MORCA_NOTIFY_SECRET` | unset | the id of a secret holding the topic (a name, or a whole URL), read with `MORCA_SECRET_FETCH` |
| `MORCA_NOTIFY_TOKEN`, `MORCA_NOTIFY_TOKEN_SECRET` | unset | an ntfy access token for a protected topic, as a value or a secret's id |
| `MORCA_UI_URL` | unset: no link | the UI's public address |
| `MORCA_NOTIFY_MIN_SECONDS` | 1800 | how long the same alert is held back |
| `MORCA_NOTIFY_TIMEOUT_MS` | 5000 | how long one send may take |
| `MORCA_NOTIFY_CHECK_SECONDS` | 10 | how often the scheduler checks disk, workers, fills and ended trips |
| `MORCA_NOTIFY_FILL_STALL_HOURS` | 2 | see `fill-stalled` |
| `MORCA_NOTIFY_DISK_PERCENT` | 85 | see `disk` |
| `MORCA_NOTIFY_WORKER_SECONDS` | 300 | see `worker-lost` |

With only `MORCA_NOTIFY_SECRET` set, a topic name is sent to
`https://ntfy.sh`.

## From a script

```sh
morca notify --kind backup-failed --subject nightly --priority high "pg_dump failed: $err"
```

`morca notify --kind K [--subject S] [--title T] [--priority high|default|low]
[--tags a,b] [--click URL] [--resolved] [message ...]` sends an alert held
back like the scheduler's. The Hetzner server's nightly `morca-stack backup`
calls it when the backup fails.

## Where it shows

Ops › Alerts (`/ops/alerts`, `/api/alerts`, `morca alerts`) lists every
alert sent, newest first: its kind, title and message, links to the run,
pipeline or watchdog rule, whether ntfy took it, and whether an alert that
ends (a watchdog trip, a stalled fill, the disk, memory pressure) is still
open. Each is a row of `orca.alerts`, kept 90 days; see
[the UI](ui.md#alerts). Ops › Control and `/api/system` (`notify`) say
whether alerts are on and list the last few.
