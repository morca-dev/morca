# The watchdog

The watchdog pauses pipelines when something leaves a sane range: a launch
storm, runaway cost, idle workers, failing attempts, stuck runs or a full
control host. It runs inside `morca scheduler`, every `MORCA_WATCHDOG_SECONDS`
(60; 0 turns it off), and reads Postgres only. It pauses and never resumes
anything: a person decides when a pipeline runs again. The code is
`src/morca/_internal/watchdog.mojo`.

```sh
morca watchdog status             # each rule, each threshold and value, and the trips
morca watchdog snooze launches 2h # silence a rule while you fix what trips it
morca unpause gharchive           # run again; this clears the trip
```

## Rules and thresholds

A rule checks one threshold or more. It trips when any of them is past its
limit. Each threshold has a default and an environment variable of the
scheduler that overrides it.

| Rule | Check | Trips when | Default | Variable | Pauses |
|---|---|---|---|---|---|
| `launches` | launches | instances launched in the last hour (warm-pool handovers aren't launches) are over | 200 | `MORCA_WATCHDOG_LAUNCHES` | all pipelines |
| `cost` | rate | the estimated cost of the instances up stays over this many dollars an hour... | $3 | `MORCA_WATCHDOG_COST_HOUR` | all pipelines |
| | | ...for this many minutes | 15 | `MORCA_WATCHDOG_COST_MINUTES` | |
| | day | the last 24 hours cost over | $25 | `MORCA_WATCHDOG_COST_DAY` | |
| `idle` | CPU | workers up for the window average under this CPU percent... | 15 | `MORCA_WATCHDOG_IDLE_CPU` | the pipelines owning those workers |
| | workers | ...and there are at least this many of them | 4 | `MORCA_WATCHDOG_IDLE_WORKERS` | |
| | | the window, in minutes (at most 30) | 10 | `MORCA_WATCHDOG_IDLE_MINUTES` | |
| `failing` | count | a pipeline's failed attempts in the last hour are over | 20 | `MORCA_WATCHDOG_FAILED` | each such pipeline |
| | share | the percent of its ended attempts that failed is over... | 50 | `MORCA_WATCHDOG_FAILED_PERCENT` | |
| | | ...once at least this many have ended | 10 | `MORCA_WATCHDOG_FAILED_MIN` | |
| `stuck` | stuck | a running run on sampled instances has no attempt start or end, no instance launched or ended, and no host over `MORCA_WATCHDOG_STUCK_CPU` (5) percent CPU, for this many minutes (at most 30) | 30 | `MORCA_WATCHDOG_STUCK_MINUTES` | that run's pipeline |
| `unmet` | waiting | a queued run has waited this many minutes for a request more than this host, or any worker of its pool, can grant at most ([requests and grants](morca-toml.md#requests-and-grants)): it would wait forever | 10 | `MORCA_WATCHDOG_UNMET_MINUTES` | that run's pipeline |
| `control` | memory | the control host's newest minute has memory over this percent | 90 | `MORCA_WATCHDOG_MEMORY` | all pipelines |
| | disk | or its fullest disk over this percent | 85 | `MORCA_WATCHDOG_DISK` | |

Pooled idle and draining workers don't count for `idle`. `idle` and `stuck`
look back at most 30 minutes, because fleet samples are kept that long. The
cost is an estimate from `morca._internal.fleet`'s on-demand price table, plus the
control instance's own price when `MORCA_CONTROL_TYPE` names its type.

**On the local runner** (`MORCA_RUNNER=local`, such as the
[Hetzner server](hetzner.md)) nothing is launched, so there is nothing to
price: the `cost` rule reads "fixed price" and never trips. The other rules
still apply. `MORCA_FIXED_COST` (free text, such as `€8.49/month`) is what
Ops › Pools' Cost tile (with EC2 in view) shows there.

## What a trip does

A rule past a limit, and not snoozed, trips:

- it pauses each pipeline in its scope that isn't paused yet, as the UI's
  Pause button does, with an `orca.audit` row per pipeline (user
  `watchdog`, the rule's numbers);
- it records a trip in `orca.watchdog_trips`, with every check's value and
  limit and which one tripped;
- it shows a red banner on `/`, Ops › Control and Ops › Pools;
- it sends a high-priority alert if [alerts](alerts.md) are set up, listed
  on Ops › Alerts with the pipelines it paused, open until it resolves.

Pipelines that were already paused are left alone, and a trip that pauses
nothing isn't recorded. Paused pipelines start no new runs, fills included.
Runs already going go on.

## After a trip

Find out why on `/watchdog` or with `morca watchdog status`:

```text
control   memory 98.30 % (trips over 90.00, past), disk 10.60 % (trips over 85.00)  TRIPPED on memory
```

Then one of:

- **Unpause** the pipelines (`morca unpause <pipeline>`, or Unpause on its
  page). A trip lasts while any of its pipelines is paused, so unpausing
  them clears it, and the alert is followed by a low-priority "resolved".
  A rule still past its limit trips again on the next pass, so fix the
  cause first, or snooze the rule.
- **Keep paused**: `morca watchdog ack [--all|<trip id>]`, or the banner's
  Keep paused button. The pipelines stay paused and the banner stops
  showing the trip; `morca watchdog status` still lists it, acknowledged by
  you. Audited.
- **Snooze** a rule: `morca watchdog snooze <rule> <duration>` (`90s`, `30m`,
  `2h`, `1d`, up to 30 days; `off` ends it), or the form on `/watchdog`.
  A snoozed rule is still read and shown but trips nothing. Audited.

The rules are `launches`, `cost`, `idle`, `failing`, `stuck` and `control`.
Each command also works from a laptop with `morca --remote <url> watchdog ...`
([morca login](../README.md)).

## Where it shows

| Where | What |
|---|---|
| `morca watchdog status [--json]` | each rule with each check, value and limit, snoozes, and the trips |
| `/watchdog` | the same, with a Checks column, what each trip tripped on, and the snooze form |
| `/api/watchdog` | the rules and trips as JSON, each with `checks` and `tripped_on` (and `value`, `threshold`) |
| `/metrics` | `morca_watchdog_tripped{rule}`, `morca_watchdog_value{rule}`, `morca_watchdog_threshold{rule}` |
| the banner | on `/`, `/ops/control` and `/ops/pools` while a trip isn't cleared or acknowledged |

Trips older than 30 days are deleted.
