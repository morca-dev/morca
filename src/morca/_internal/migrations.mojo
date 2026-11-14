"""The schema's migrations (`State.migrate` applies them): each version's
statements, which versions raise the floor an older binary needs, and the
check that an older binary may run on a newer schema. AGENTS.md says how to
keep a migration additive."""

from std.os import getenv


def data_version_sql(describe: String) -> String:
    """SQL for the data version of the `describe` JSON `describe` (a jsonb
    expression): its steps' `version=` as `<step>=<version>`, by step
    name, comma-separated; empty when no step sets one (#297). The fill
    takes a partition done under another code as done only when this
    matches (`morca._internal.fill`)."""
    return String(
        (
            "coalesce((SELECT string_agg((x->>'name') || '=' ||"
            " (x->>'version'), ',' ORDER BY x->>'name') FROM"
            " jsonb_array_elements(("
        ),
        describe,
        ")->'steps') AS x WHERE x->>'version' IS NOT NULL), '')",
    )


def _migrations() -> List[List[String]]:
    """Each migration is a list of statements; its version is its index + 1.

    **Rollbacks.** A binary older than the database runs on it if every
    migration it doesn't know is additive, so a migration must leave the
    schema working for the binaries before it, or be listed in
    `_floor_raisers` (see there, and AGENTS.md's "Migrations"):

    - add a column only nullable or with a default; never NOT NULL without
      one, which an older binary's INSERTs (which name their columns) don't
      fill;
    - add tables, indexes and nullable foreign keys freely, but a foreign
      key onto a table an older binary deletes from (users, sessions,
      api_tokens, notifications, fleet, system and watchdog rows) must be
      `ON DELETE CASCADE` or `SET NULL`, or its delete fails;
    - don't rename, drop or retype a column or table, tighten a constraint
      or change a key an `ON CONFLICT` names, and don't write a value an
      older binary reads and acts on (a new run or step status) or store a
      different meaning in an old column: each of those raises the floor.

    The queries keep this possible: they name the columns they insert and
    select (`SELECT *` only over a subquery that names them), and read rows
    by column name, never by position.
    """
    return [
        [
            """CREATE TABLE orca.pipelines (
            name text PRIMARY KEY,
            registry_hash text NOT NULL,
            describe jsonb NOT NULL,
            first_seen timestamptz NOT NULL DEFAULT now(),
            last_seen timestamptz NOT NULL DEFAULT now())""",
            """CREATE TABLE orca.runs (
            id bigserial PRIMARY KEY,
            pipeline text NOT NULL REFERENCES orca.pipelines (name),
            registry_hash text NOT NULL,
            partitions text NOT NULL,
            trigger text NOT NULL,
            status text NOT NULL,
            owner text,
            heartbeat timestamptz,
            created timestamptz NOT NULL DEFAULT now(),
            started timestamptz,
            ended timestamptz)""",
            """CREATE TABLE orca.steps (
            id bigserial PRIMARY KEY,
            run bigint NOT NULL REFERENCES orca.runs (id),
            step text NOT NULL,
            partition text NOT NULL,
            ord int NOT NULL,
            status text NOT NULL,
            input bytea,
            output bytea,
            error text,
            UNIQUE (run, step, partition))""",
            """CREATE TABLE orca.attempts (
            id bigserial PRIMARY KEY,
            step bigint NOT NULL REFERENCES orca.steps (id),
            attempt int NOT NULL,
            status text NOT NULL,
            host text NOT NULL,
            registry_hash text NOT NULL,
            started timestamptz NOT NULL DEFAULT now(),
            ended timestamptz,
            error text,
            log text,
            UNIQUE (step, attempt))""",
            """CREATE TABLE orca.reads (
            attempt bigint NOT NULL REFERENCES orca.attempts (id),
            table_name text NOT NULL,
            snapshot_id bigint NOT NULL)""",
            """CREATE TABLE orca.commits (
            attempt bigint NOT NULL REFERENCES orca.attempts (id),
            table_name text NOT NULL,
            snapshot_id bigint NOT NULL)""",
        ],
        # The scheduler: a pipeline's binary and since when it's scheduled
        # (both on the scheduler's clock, which MORCA_NOW can fix), how often
        # the scheduler started a run and when it retries it, and fires.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN binary_path text",
            "ALTER TABLE orca.pipelines ADD COLUMN since bigint",
            "ALTER TABLE orca.runs ADD COLUMN starts int NOT NULL DEFAULT 0",
            "ALTER TABLE orca.runs ADD COLUMN retry_at bigint",
            "CREATE INDEX runs_pipeline_status ON orca.runs (pipeline, status)",
            """CREATE TABLE orca.fires (
            pipeline text NOT NULL REFERENCES orca.pipelines (name),
            fire_at bigint NOT NULL,
            partition text NOT NULL,
            run bigint REFERENCES orca.runs (id),
            created timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (pipeline, fire_at))""",
        ],
        # The UI's actions: a cancel asked for, a resume that may run new
        # code, and the steps a rerun copied from the run it reruns.
        [
            (
                "ALTER TABLE orca.runs ADD COLUMN cancel_requested boolean NOT"
                " NULL DEFAULT false"
            ),
            (
                "ALTER TABLE orca.runs ADD COLUMN allow_new_code boolean NOT"
                " NULL DEFAULT false"
            ),
            (
                "ALTER TABLE orca.steps ADD COLUMN copied_from bigint"
                " REFERENCES orca.steps (id)"
            ),
        ],
        # Datasets: the warehouse name of a table read or committed, null
        # for a table outside the warehouse.
        [
            "ALTER TABLE orca.reads ADD COLUMN dataset text",
            "ALTER TABLE orca.commits ADD COLUMN dataset text",
        ],
        # Lineage walks: a snapshot to the attempts that read or made it,
        # and an attempt to what it read and made.
        [
            "CREATE INDEX reads_snapshot ON orca.reads (dataset, snapshot_id)",
            (
                "CREATE INDEX commits_snapshot ON orca.commits (dataset,"
                " snapshot_id)"
            ),
            "CREATE INDEX reads_attempt ON orca.reads (attempt)",
            "CREATE INDEX commits_attempt ON orca.commits (attempt)",
        ],
        # Sensors and rebuilds (morca.sensors): since when a pipeline is a
        # sensor, the snapshots each sensor has seen and the run each
        # started, and rebuilds with their plans and runs.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN sensing_since timestamptz",
            """CREATE TABLE orca.sensed (
            pipeline text NOT NULL REFERENCES orca.pipelines (name),
            dataset text NOT NULL,
            snapshot_id bigint NOT NULL,
            run bigint REFERENCES orca.runs (id),
            created timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (pipeline, dataset, snapshot_id))""",
            "CREATE INDEX sensed_run ON orca.sensed (run)",
            """CREATE TABLE orca.rebuilds (
            id bigserial PRIMARY KEY,
            dataset text NOT NULL,
            partitions text NOT NULL,
            status text NOT NULL,
            created timestamptz NOT NULL DEFAULT now(),
            ended timestamptz)""",
            """CREATE TABLE orca.rebuild_pipelines (
            rebuild bigint NOT NULL REFERENCES orca.rebuilds (id),
            pipeline text NOT NULL REFERENCES orca.pipelines (name),
            level int NOT NULL,
            partitions text NOT NULL,
            run bigint REFERENCES orca.runs (id),
            PRIMARY KEY (rebuild, pipeline))""",
            (
                "ALTER TABLE orca.runs ADD COLUMN rebuild bigint REFERENCES"
                " orca.rebuilds (id)"
            ),
        ],
        # Keys: what's done is a step's status by its partition key.
        ["CREATE INDEX steps_partition ON orca.steps (partition, step)"],
        # Runs on Kubernetes (morca.kube): the image a pipeline's pods run,
        # and the CPU a run's pods asked for, in thousandths of a vCPU.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN image text",
            "ALTER TABLE orca.runs ADD COLUMN cpu_millis int",
        ],
        # Login to morca ui (morca.auth): users, their sessions, and what each
        # did. pgcrypto, a trusted extension, hashes the passwords.
        [
            "CREATE EXTENSION IF NOT EXISTS pgcrypto",
            """CREATE TABLE orca.users (
            name text PRIMARY KEY,
            password_hash text NOT NULL,
            created timestamptz NOT NULL DEFAULT now())""",
            """CREATE TABLE orca.sessions (
            token_hash bytea PRIMARY KEY,
            username text NOT NULL REFERENCES orca.users (name) ON DELETE
                CASCADE,
            created timestamptz NOT NULL DEFAULT now(),
            expires timestamptz NOT NULL)""",
            """CREATE TABLE orca.audit (
            id bigserial PRIMARY KEY,
            at timestamptz NOT NULL DEFAULT now(),
            username text NOT NULL,
            action text NOT NULL,
            run bigint,
            detail text NOT NULL)""",
            "CREATE INDEX audit_run ON orca.audit (run)",
        ],
        # The ec2 runner (morca.ec2): a pipeline's instance types, its
        # workers' count and whether they're Spot, as registered.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN head_type text",
            "ALTER TABLE orca.pipelines ADD COLUMN worker_type text",
            "ALTER TABLE orca.pipelines ADD COLUMN ec2_workers int",
            "ALTER TABLE orca.pipelines ADD COLUMN spot boolean",
        ],
        # Versions (morca.source): each registry hash, source commit and
        # image a pipeline was registered or run with, the pipeline's
        # latest, and the one each run ran.
        [
            """CREATE TABLE orca.pipeline_versions (
            id bigserial PRIMARY KEY,
            pipeline text NOT NULL REFERENCES orca.pipelines (name),
            registry_hash text NOT NULL,
            source text NOT NULL,
            commit_sha text NOT NULL,
            dirty boolean NOT NULL,
            image text NOT NULL,
            first_seen timestamptz NOT NULL DEFAULT now(),
            last_seen timestamptz NOT NULL DEFAULT now(),
            UNIQUE (pipeline, registry_hash, source, commit_sha, dirty,
                image))""",
            (
                "ALTER TABLE orca.pipelines ADD COLUMN version bigint"
                " REFERENCES orca.pipeline_versions (id)"
            ),
            (
                "ALTER TABLE orca.runs ADD COLUMN version bigint REFERENCES"
                " orca.pipeline_versions (id)"
            ),
        ],
        # The instances a run ran on (morca.ec2): what each was, when it
        # started and ended, and why it ended.
        [
            """CREATE TABLE orca.instances (
            id text PRIMARY KEY,
            run bigint NOT NULL REFERENCES orca.runs (id),
            start int NOT NULL,
            role text NOT NULL,
            instance_type text NOT NULL,
            market text NOT NULL,
            launched timestamptz NOT NULL DEFAULT now(),
            ended timestamptz,
            why text)""",
            "CREATE INDEX instances_run ON orca.instances (run)",
            (
                "CREATE INDEX instances_live ON orca.instances (run) WHERE"
                " ended IS NULL"
            ),
            # Where its functions are in its source (morca.locate), as
            # registration found them beside the binary.
            "ALTER TABLE orca.pipeline_versions ADD COLUMN locations jsonb",
        ],
        # Autoscaling on EC2: a pipeline's fewest workers (`--workers
        # A..B`; null, a fixed count), each instance's private address, and
        # when the scheduler drained a worker.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN ec2_min_workers int",
            "ALTER TABLE orca.instances ADD COLUMN address text",
            "ALTER TABLE orca.instances ADD COLUMN drained timestamptz",
        ],
        # Secrets a pipeline's runs get (`--secret NAME=ID`): environment
        # variable to Secrets Manager secret ID.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN secrets jsonb",
        ],
        # Why a run ended without running, or stopped where no step could
        # say: code its binary refuses, a process that exited before it
        # claimed the run, a cluster that couldn't start.
        [
            "ALTER TABLE orca.runs ADD COLUMN error text",
        ],
        # `morca pause`: the scheduler starts none of a paused pipeline's
        # runs, which stay queued (or due to retry) until `morca unpause`.
        [
            (
                "ALTER TABLE orca.pipelines ADD COLUMN paused boolean NOT NULL"
                " DEFAULT false"
            ),
        ],
        # Sensing that went wrong: why a snapshot was recorded as seen
        # without a run (its keys aren't partitions), and the error of a
        # sensor's last pass that failed, cleared by one that doesn't.
        [
            "ALTER TABLE orca.sensed ADD COLUMN error text",
            "ALTER TABLE orca.pipelines ADD COLUMN sense_error text",
            "ALTER TABLE orca.pipelines ADD COLUMN sense_error_at timestamptz",
        ],
        # Deferred runs (morca.step.defer): how many of a run's starts were
        # after it deferred, which its retry budget doesn't count.
        [
            "ALTER TABLE orca.runs ADD COLUMN deferrals int NOT NULL DEFAULT 0",
        ],
        # Stopping a step (morca.heartbeat): when a running run asked to
        # cancel is stopped if its step hasn't finished by then.
        [
            "ALTER TABLE orca.runs ADD COLUMN cancel_at timestamptz",
        ],
        # A keyed pipeline's keys as `<binary> keys` last printed them, with
        # their snapshot, so the UI shows them without running the binary.
        [
            """CREATE TABLE orca.keys (
            pipeline text PRIMARY KEY REFERENCES orca.pipelines (name),
            snapshot_id bigint NOT NULL,
            keys text NOT NULL,
            read_at timestamptz NOT NULL DEFAULT now())""",
        ],
        # The fleet page (morca.fleet): each live host's last half hour of
        # samples, an hour-by-hour total for the 7-day charts, and indexes
        # for the runs and failed attempts per hour.
        [
            """CREATE TABLE orca.fleet_samples (
            host text NOT NULL,
            t timestamptz NOT NULL,
            cores int NOT NULL,
            cpu float8 NOT NULL,
            busiest float8 NOT NULL,
            mem float8 NOT NULL,
            disk float8 NOT NULL,
            net_in float8 NOT NULL,
            net_out float8 NOT NULL,
            PRIMARY KEY (host, t))""",
            "CREATE INDEX fleet_samples_t ON orca.fleet_samples (t)",
            """CREATE TABLE orca.fleet_hourly (
            hour timestamptz NOT NULL,
            role text NOT NULL,
            seconds float8 NOT NULL,
            core_seconds float8 NOT NULL,
            busy_seconds float8 NOT NULL,
            net_in_bytes float8 NOT NULL,
            net_out_bytes float8 NOT NULL,
            PRIMARY KEY (hour, role))""",
            "CREATE INDEX runs_started ON orca.runs (started)",
            "CREATE INDEX runs_ended ON orca.runs (ended)",
            (
                "CREATE INDEX attempts_failed ON orca.attempts (ended) WHERE"
                " status = 'failed'"
            ),
        ],
        # API tokens for `morca login` (morca.tokens), kept as their SHA-256,
        # and where each audited action came from: `ui` (a session) or `cli`
        # (a token).
        [
            """CREATE TABLE orca.api_tokens (
            id bigserial PRIMARY KEY,
            token_hash text NOT NULL UNIQUE,
            username text NOT NULL REFERENCES orca.users (name) ON DELETE
                CASCADE,
            label text NOT NULL,
            created timestamptz NOT NULL DEFAULT now(),
            last_used timestamptz,
            expires timestamptz NOT NULL)""",
            "CREATE INDEX api_tokens_user ON orca.api_tokens (username)",
            "ALTER TABLE orca.audit ADD COLUMN source text",
        ],
        # Several dista worker processes per EC2 worker instance
        # (`morca register --worker-procs`): the count registered (0 is one
        # per vCPU), and for each instance the processes it was started with
        # and how many of them have been drained.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN worker_procs int",
            "ALTER TABLE orca.instances ADD COLUMN procs int",
            (
                "ALTER TABLE orca.instances ADD COLUMN procs_drained int NOT"
                " NULL DEFAULT 0"
            ),
        ],
        # A warm pool on EC2 (morca.ec2, `MORCA_EC2_POOL_SECONDS`): an
        # instance serves one run after another, a row for each, so an ID
        # is unique among the live rows only. Each row has what the
        # instance was started as (`pool_key`), its vCPUs, when it went
        # idle after its run and last asked for another (`<binary>
        # pool-next`), whether the pool handed it to this run, and when it
        # took that run up.
        [
            "ALTER TABLE orca.instances DROP CONSTRAINT instances_pkey",
            "ALTER TABLE orca.instances ADD PRIMARY KEY (id, run, start)",
            (
                "CREATE UNIQUE INDEX instances_one_live ON orca.instances (id)"
                " WHERE ended IS NULL"
            ),
            "ALTER TABLE orca.instances ADD COLUMN pool_key text",
            "ALTER TABLE orca.instances ADD COLUMN cpu_millis int",
            "ALTER TABLE orca.instances ADD COLUMN idle timestamptz",
            "ALTER TABLE orca.instances ADD COLUMN polled timestamptz",
            (
                "ALTER TABLE orca.instances ADD COLUMN pooled boolean NOT NULL"
                " DEFAULT false"
            ),
            "ALTER TABLE orca.instances ADD COLUMN joined timestamptz",
            (
                "CREATE INDEX instances_pool ON orca.instances (pool_key) WHERE"
                " ended IS NULL AND idle IS NOT NULL"
            ),
        ],
        # The control instance's own health (morca.system): a row a minute of
        # its CPU, memory, fullest disk and network, and one a minute for
        # each container's memory, kept 14 days.
        [
            """CREATE TABLE orca.system_minutes (
            minute timestamptz PRIMARY KEY,
            n int NOT NULL,
            last_t timestamptz NOT NULL,
            cpu_sum float8 NOT NULL,
            cpu_max float8 NOT NULL,
            mem_sum float8 NOT NULL,
            mem_max float8 NOT NULL,
            mem_used int8 NOT NULL,
            mem_total int8 NOT NULL,
            disk_max float8 NOT NULL,
            disk_used int8 NOT NULL,
            disk_total int8 NOT NULL,
            disk_path text NOT NULL,
            net_in_sum float8 NOT NULL,
            net_out_sum float8 NOT NULL)""",
            """CREATE TABLE orca.system_containers (
            minute timestamptz NOT NULL,
            name text NOT NULL,
            mem int8 NOT NULL,
            PRIMARY KEY (minute, name))""",
        ],
        # A run's EC2 registration as its start was given it (so a later
        # `morca register` doesn't change how a live run's workers start),
        # and since when its head has had tasks and no worker.
        [
            "ALTER TABLE orca.runs ADD COLUMN spec jsonb",
            "ALTER TABLE orca.runs ADD COLUMN waiting_since timestamptz",
        ],
        # The watchdog (morca.watchdog): each rule's last reading and the
        # snooze it may have, and the trips: when a rule paused which
        # pipelines, and the numbers it paused them for.
        [
            """CREATE TABLE orca.watchdog_rules (
            rule text PRIMARY KEY,
            value float8,
            threshold float8,
            detail text,
            checked timestamptz,
            snoozed_until timestamptz,
            snoozed_by text)""",
            """CREATE TABLE orca.watchdog_trips (
            id bigserial PRIMARY KEY,
            rule text NOT NULL,
            at timestamptz NOT NULL DEFAULT now(),
            value float8 NOT NULL,
            threshold float8 NOT NULL,
            detail text NOT NULL,
            pipelines text NOT NULL)""",
        ],
        # Where a pipeline's runs run (`morca register --placement`): null
        # for the scheduler's runner, `control` for the scheduler's own host
        # (morca.control), `ec2` for instances of their own. Each run keeps
        # where its latest start was placed, and why a queued one is held.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN placement text",
            "ALTER TABLE orca.runs ADD COLUMN placement text",
            "ALTER TABLE orca.runs ADD COLUMN held text",
        ],
        # morca.toml (morca.config): a pipeline's own environment for its
        # runs, its max_runs over the code's, and what it was registered
        # from: the file's hash and commit, where each value came from, and
        # the flags that overrode the file.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN env jsonb",
            "ALTER TABLE orca.pipelines ADD COLUMN max_runs int",
            "ALTER TABLE orca.pipelines ADD COLUMN config jsonb",
        ],
        # Fills (morca.fill): whether a pipeline fills its whole range by
        # itself (`fills`; null, since registration), in which order, with
        # how many fill runs at once, a budget a UTC day in US dollars and
        # the UTC hours fill runs start in. Its fill runs are runs with
        # trigger `fill`.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN fills text",
            "ALTER TABLE orca.pipelines ADD COLUMN fill_order text",
            "ALTER TABLE orca.pipelines ADD COLUMN fill_max_runs int",
            "ALTER TABLE orca.pipelines ADD COLUMN fill_budget_per_day float8",
            "ALTER TABLE orca.pipelines ADD COLUMN fill_window text",
            (
                "CREATE INDEX runs_fill ON orca.runs (pipeline) WHERE trigger ="
                " 'fill'"
            ),
        ],
        # A watchdog trip can be acknowledged ("Keep paused"): its pipelines
        # stay paused, and the banner stops showing it.
        [
            (
                "ALTER TABLE orca.watchdog_trips ADD COLUMN acknowledged_at"
                " timestamptz"
            ),
            "ALTER TABLE orca.watchdog_trips ADD COLUMN acknowledged_by text",
        ],
        # Remote workers (orca.workers): a row per worker token, scoped to
        # a pool, with what its worker last said of itself, and on each run
        # the worker its latest start was claimed by.
        [
            """CREATE TABLE orca.workers (
            id bigserial PRIMARY KEY,
            token_hash text NOT NULL UNIQUE,
            pool text NOT NULL,
            label text NOT NULL,
            created timestamptz NOT NULL DEFAULT now(),
            created_by text NOT NULL,
            expires timestamptz NOT NULL,
            revoked timestamptz,
            name text,
            image text,
            last_seen timestamptz,
            cpus int,
            memory_mb bigint,
            running text)""",
            "ALTER TABLE orca.runs ADD COLUMN worker bigint",
        ],
        # Alerts to a person (morca.notify): a row per kind and subject, so a
        # restart doesn't send an alert again, and one that couldn't be sent
        # waits there for its retry.
        [
            """CREATE TABLE orca.notifications (
            kind text NOT NULL,
            subject text NOT NULL,
            state text NOT NULL,
            pending boolean NOT NULL DEFAULT false,
            title text NOT NULL,
            body text NOT NULL,
            priority text NOT NULL,
            tags text NOT NULL,
            click text NOT NULL,
            attempts int NOT NULL DEFAULT 0,
            next_try timestamptz NOT NULL DEFAULT now(),
            last_sent timestamptz,
            sent_at timestamptz,
            last_error text,
            PRIMARY KEY (kind, subject))""",
        ],
        # Every threshold a watchdog rule checks (morca.watchdog.limits), its
        # value and whether it was past it, on the rule's last reading and
        # on each trip: which of a rule's thresholds tripped it.
        [
            "ALTER TABLE orca.watchdog_rules ADD COLUMN checks jsonb",
            "ALTER TABLE orca.watchdog_trips ADD COLUMN checks jsonb",
        ],
        # What each attempt's processes used (morca.usage): the peak resident
        # bytes of its process tree, its CPU seconds and the most cores it
        # kept busy; null where it isn't known (EC2, Kubernetes, macOS's
        # peak cores).
        [
            "ALTER TABLE orca.attempts ADD COLUMN peak_rss_bytes bigint",
            "ALTER TABLE orca.attempts ADD COLUMN cpu_seconds double precision",
            "ALTER TABLE orca.attempts ADD COLUMN peak_cpus double precision",
        ],
        # Requests and grants (morca.resources): the CPUs and memory a
        # pipeline asks for, `N` or `MIN..MAX` (null for none), and on each
        # run the request its latest start had and what it was granted.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN cpus text",
            "ALTER TABLE orca.pipelines ADD COLUMN memory_gb text",
            "ALTER TABLE orca.runs ADD COLUMN request_cpus text",
            "ALTER TABLE orca.runs ADD COLUMN request_memory_gb text",
            "ALTER TABLE orca.runs ADD COLUMN grant_cpus int",
            "ALTER TABLE orca.runs ADD COLUMN grant_memory_mb bigint",
        ],
        # Pages of one pipeline's runs (`/runs?pipeline=`, its Runs tab),
        # newest first by id under a cursor: one range of this index, and
        # their count an index-only scan.
        ["CREATE INDEX runs_pipeline_id ON orca.runs (pipeline, id DESC)"],
        # A runs list filtered by when its runs were created (`?from=`,
        # `?to=`, `?since=`): one range of this index, for its page and its
        # counts, where without it each is a scan of every run.
        ["CREATE INDEX runs_created ON orca.runs (created)"],
        # Containment (morca.cgroup): what out-of-memory kills raised a
        # pipeline's memory to; on each run its latest start's cgroup limit
        # (memory.high), its memory.max and its memory now; on each attempt
        # the limit and memory grant of the start that made it.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN memory_raised_mb bigint",
            "ALTER TABLE orca.runs ADD COLUMN memory_limit_mb bigint",
            "ALTER TABLE orca.runs ADD COLUMN memory_max_mb bigint",
            "ALTER TABLE orca.runs ADD COLUMN memory_bytes bigint",
            "ALTER TABLE orca.attempts ADD COLUMN memory_limit_mb bigint",
            "ALTER TABLE orca.attempts ADD COLUMN grant_memory_mb bigint",
        ],
        # Each host's newest memory pressure reading (morca.admission, #202):
        # the scheduler's own and each worker's, with whether it holds new
        # runs and since when.
        [
            """CREATE TABLE orca.pressure (
            host text PRIMARY KEY,
            kind text NOT NULL,
            path text NOT NULL,
            some_avg10 double precision,
            some_avg60 double precision,
            some_avg300 double precision,
            full_avg10 double precision,
            full_avg60 double precision,
            full_avg300 double precision,
            limit_pct double precision NOT NULL,
            held text,
            held_since timestamptz,
            updated timestamptz NOT NULL DEFAULT now())""",
        ],
        # Every alert sent, a row each (morca.notify, Ops › Alerts):
        # `orca.notifications` keeps only the latest per kind and subject,
        # for dedup and retries; this keeps each one raised and each
        # 'resolved', with whether it was delivered and when its alert
        # resolved. Seeded with what `orca.notifications` still holds.
        [
            """CREATE TABLE orca.alerts (
            id bigserial PRIMARY KEY,
            kind text NOT NULL,
            subject text NOT NULL,
            event text NOT NULL,
            title text NOT NULL,
            body text NOT NULL,
            priority text NOT NULL,
            tags text NOT NULL DEFAULT '',
            url text NOT NULL DEFAULT '',
            pipelines text,
            run bigint,
            created timestamptz NOT NULL DEFAULT now(),
            delivery text NOT NULL DEFAULT 'pending',
            attempts int NOT NULL DEFAULT 0,
            sent_at timestamptz,
            error text,
            resolved_at timestamptz,
            resolved_by bigint)""",
            "CREATE INDEX alerts_kind_id ON orca.alerts (kind, id DESC)",
            (
                "CREATE INDEX alerts_open ON orca.alerts (kind, subject) WHERE"
                " resolved_at IS NULL"
            ),
            "CREATE INDEX alerts_created ON orca.alerts (created)",
            (
                "INSERT INTO orca.alerts (kind, subject, event, title, body,"
                " priority, tags, url, created, delivery, attempts, sent_at,"
                " error) SELECT kind, subject, CASE WHEN state = 'resolved'"
                " THEN 'resolved' ELSE 'raised' END, title, body, priority,"
                " tags, click, coalesce(sent_at, next_try), CASE WHEN pending"
                " THEN 'pending' ELSE 'sent' END, attempts, sent_at,"
                " last_error FROM orca.notifications WHERE sent_at IS NOT NULL"
                " OR pending ORDER BY coalesce(sent_at, next_try)"
            ),
        ],
        # Scheduler instances (docs/overlap.md): a row each `morca scheduler`
        # with MORCA_OVERLAP=on keeps fresh, with the migrations it knows,
        # whether it leads or drains, and the runs its processes are; and on
        # each local or control-placed run the instance that started it.
        [
            """CREATE TABLE orca.schedulers (
            id bigserial PRIMARY KEY,
            host text NOT NULL,
            pid int NOT NULL,
            image text NOT NULL DEFAULT '',
            known int NOT NULL,
            started timestamptz NOT NULL DEFAULT now(),
            last_seen timestamptz NOT NULL DEFAULT now(),
            role text NOT NULL DEFAULT 'waiting',
            lead_since timestamptz,
            drain_asked timestamptz,
            draining_since timestamptz,
            ended timestamptz,
            running text)""",
            "ALTER TABLE orca.runs ADD COLUMN instance bigint",
        ],
        # A fill's lag (morca.fill): how long after its end a partition of
        # the pipeline fills, as morca.toml's `fill_lag` gives it (`2h`);
        # null for none.
        ["ALTER TABLE orca.pipelines ADD COLUMN fill_lag text"],
        # Learned requests (morca.recommend, #269): a pipeline's `learn`
        # (morca.toml; null is on), and the request its runs suggest, cached
        # with what it was learned from (`learned`: key, runs, memory_mb,
        # cpus); on each run where its latest start's request came from
        # (`declared`, `learned` or `default`) and how many runs a learned
        # one is from. Additive: nothing before reads them.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN learn boolean",
            "ALTER TABLE orca.pipelines ADD COLUMN learned jsonb",
            "ALTER TABLE orca.runs ADD COLUMN request_source text",
            "ALTER TABLE orca.runs ADD COLUMN request_runs int",
        ],
        # The run whose out-of-memory kill last raised a pipeline's memory
        # (`memory_raised_mb`): the raise expires once LEARN_RUNS of its runs
        # after that one have succeeded (morca.recommend.expire_raised). A
        # raise from before it counts from the pipeline's latest run.
        # Additive: an older binary neither reads it nor expires anything.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN memory_raised_run bigint",
            (
                "UPDATE orca.pipelines p SET memory_raised_run = (SELECT"
                " max(r.id) FROM orca.runs r WHERE r.pipeline = p.name) WHERE"
                " memory_raised_mb IS NOT NULL"
            ),
        ],
        # How long an attempt's run waited on memory (morca.cgroup; #281):
        # its cgroup's memory.pressure totals at the reap, in ms, some tasks
        # and all of them; null where it had no cgroup or no PSI. Additive.
        [
            "ALTER TABLE orca.attempts ADD COLUMN memory_stall_ms bigint",
            "ALTER TABLE orca.attempts ADD COLUMN memory_stall_full_ms bigint",
        ],
        # A random token per run (#292): in the summaries of the snapshots
        # the run commits, beside its number, so a run that is given the
        # number of one a restore lost doesn't take that run's commits for
        # its own (`Ctx.made`). A UUID version 7: its first 48 bits are the
        # milliseconds since 1970 it was made at, the rest random.
        # Postgres has `uuidv7()` from 18 on and morca runs on 16 and 17 too
        # (its deployments are on 17), so `orca.uuidv7()` makes one from a
        # random UUID: the time over its first six bytes, and the version's
        # 4 turned into a 7. Additive: the default gives a token to the runs
        # an older binary creates, which neither reads nor writes it; the
        # runs there already are have none, and are told by their number.
        [
            (
                "CREATE OR REPLACE FUNCTION orca.uuidv7() RETURNS uuid"
                " LANGUAGE sql VOLATILE AS $$ SELECT"
                " encode(set_bit(set_bit(overlay(uuid_send(gen_random_uuid())"
                " placing substring(int8send(floor(extract(epoch FROM"
                " clock_timestamp()) * 1000)::bigint) from 3) from 1 for 6),"
                " 52, 1), 53, 1), 'hex')::uuid $$"
            ),
            "ALTER TABLE orca.runs ADD COLUMN token uuid",
            (
                "ALTER TABLE orca.runs ALTER COLUMN token SET DEFAULT"
                " orca.uuidv7()"
            ),
        ],
        # The start of a failed run whose failure isn't retried (#287: killed
        # for its memory at the most it may ask for): the scheduler doesn't
        # schedule a retry while `starts` is still that start, so a resume
        # (which starts it again) is retried as usual. Additive: an older
        # binary ignores it and retries, as it did.
        ["ALTER TABLE orca.runs ADD COLUMN unretried_start integer"],
        # max_runs = "auto" (#266): how many runs at once follows what this
        # host has free, with max_runs as the ceiling. Additive: an older
        # binary ignores it and runs up to the ceiling.
        ["ALTER TABLE orca.pipelines ADD COLUMN max_runs_auto boolean"],
        # Each version's data version (#297): its steps' `version=`, which
        # the fill compares so a raised one fills the partitions again.
        # Additive: older binaries neither read nor write it, and leave it
        # null on the versions they record, which reads as none. The
        # pipelines' current versions get theirs from their describe.
        [
            "ALTER TABLE orca.pipeline_versions ADD COLUMN data_version text",
            String(
                "UPDATE orca.pipeline_versions v SET data_version = ",
                data_version_sql("p.describe"),
                " FROM orca.pipelines p WHERE p.name = v.pipeline AND",
                " p.registry_hash = v.registry_hash",
            ),
        ],
        # Worker pools morca grows itself (#267, morca.pool_config): each
        # pool's settings from morca.toml, and the machines it made (with
        # the architecture the provider says their type has), kept after
        # they end for Ops. New tables: additive.
        [
            (
                "CREATE TABLE orca.pools (name text PRIMARY KEY, provider text"
                " NOT NULL, machines jsonb NOT NULL, locations jsonb NOT NULL"
                " DEFAULT '[]', max_machines integer NOT NULL DEFAULT 1,"
                " idle_seconds integer NOT NULL DEFAULT 900, updated"
                " timestamptz NOT NULL DEFAULT now())"
            ),
            (
                "CREATE TABLE orca.pool_machines (id bigserial PRIMARY KEY,"
                " pool text NOT NULL, provider text NOT NULL, name text NOT"
                " NULL, server_type text NOT NULL, arch text, location text NOT"
                " NULL DEFAULT '', provider_id text, address text, worker"
                " bigint REFERENCES orca.workers ON DELETE SET NULL, launched"
                " timestamptz NOT NULL DEFAULT now(), joined timestamptz,"
                " idle_since timestamptz, ended timestamptz, why text)"
            ),
            (
                "CREATE INDEX pool_machines_live ON orca.pool_machines (pool)"
                " WHERE ended IS NULL"
            ),
        ],
        # The pool autoscaler (#267, morca.pool_scale): which machine type a
        # pool is trying and since when, its last attempt and what that came
        # to; and this stack's id, the label that marks its machines.
        # Additive.
        [
            (
                "ALTER TABLE orca.pools ADD COLUMN trying integer NOT NULL"
                " DEFAULT 0"
            ),
            "ALTER TABLE orca.pools ADD COLUMN trying_since timestamptz",
            "ALTER TABLE orca.pools ADD COLUMN last_try timestamptz",
            "ALTER TABLE orca.pools ADD COLUMN status text",
            "CREATE TABLE orca.stack_identity (id text PRIMARY KEY)",
        ],
        # keys_per_run from morca.toml (#240), over the code's: how many keys
        # a backfill, a sensor's run or a fill run takes. Additive: an
        # older binary reads the code's from `describe`, as it did.
        ["ALTER TABLE orca.pipelines ADD COLUMN keys_per_run integer"],
        # One run over several workers of a pool (#268, morca.run_cluster):
        # its dista head's address and cluster token for the start it's in,
        # and the workers that joined it. Additive.
        [
            "ALTER TABLE orca.runs ADD COLUMN cluster_head text",
            "ALTER TABLE orca.runs ADD COLUMN cluster_token text",
            (
                "CREATE TABLE orca.run_members (id bigserial PRIMARY KEY, run"
                " bigint NOT NULL REFERENCES orca.runs ON DELETE CASCADE,"
                " start integer NOT NULL, worker bigint REFERENCES"
                " orca.workers ON DELETE SET NULL, grant_cpus integer,"
                " grant_memory_mb integer, joined timestamptz NOT NULL DEFAULT"
                " now(), ended timestamptz, why text)"
            ),
            (
                "CREATE INDEX run_members_live ON orca.run_members (run) WHERE"
                " ended IS NULL"
            ),
        ],
        # fill_max_runs = "auto" (#322): fill runs follow the host's room, as
        # max_runs = "auto" does. Additive: an older binary runs up to the
        # ceiling.
        ["ALTER TABLE orca.pipelines ADD COLUMN fill_max_runs_auto boolean"],
        # The batch a run was queued in (#354): one id, its first run's, for
        # the runs one backfill, fill pass or sensor pass queued, so the
        # home page shows them as one row. Additive: older binaries leave
        # it null, which reads as a run of its own.
        [
            "ALTER TABLE orca.runs ADD COLUMN batch bigint",
            (
                "CREATE INDEX runs_batch ON orca.runs (batch) WHERE batch IS"
                " NOT NULL"
            ),
        ],
        # Datasets' settings from morca.toml (#435,
        # morca._internal.dataset_config): whether visitors see a dataset's
        # data. A new table: additive.
        [
            (
                "CREATE TABLE orca.dataset_settings (name text PRIMARY KEY,"
                " public boolean NOT NULL DEFAULT true, updated timestamptz"
                " NOT NULL DEFAULT now())"
            ),
        ],
        # A pool machine's worker image, and when the autoscaler began
        # draining it for a newer one (#356). Additive: an older binary
        # leaves both null, and its machines are replaced once idle.
        [
            "ALTER TABLE orca.pool_machines ADD COLUMN image text",
            "ALTER TABLE orca.pool_machines ADD COLUMN draining timestamptz",
        ],
        # When a pipeline was retired (#427, `morca retire`): the scheduler
        # starts none of its runs, and lists skip it; `morca register`
        # clears it. Additive: an older binary neither reads nor writes it.
        ["ALTER TABLE orca.pipelines ADD COLUMN retired timestamptz"],
        # A pipeline's priority from morca.toml (#421): the scheduler's
        # pass goes highest first. Additive: an older binary's INSERTs
        # leave it 0, and it starts pipelines by name, as it did.
        [
            "ALTER TABLE orca.pipelines ADD COLUMN priority integer NOT"
            " NULL DEFAULT 0"
        ],
        # What each worker can grant a run (#462): a pool's learned
        # requests are capped at its largest worker's. Additive: an older
        # binary leaves them null, and its workers' rooms aren't weighed.
        [
            "ALTER TABLE orca.workers ADD COLUMN room_cpus integer",
            "ALTER TABLE orca.workers ADD COLUMN room_memory_mb bigint",
        ],
    ]


def _floor_raisers() -> List[Int]:
    """The migrations a binary must know to run on a database that has had
    them: those that rename, drop or retype what older binaries use, or
    change what it means. Every other migration is additive (`_migrations`
    says what that allows), and a binary that doesn't know it runs on its
    schema anyway.

    - 1 creates the schema.
    - 24 (the EC2 warm pool) replaces `orca.instances`' primary key on `id`
      with one on `(id, run, start)`: an instance has a row per run it
      served, so the binaries before it, which update and end an instance
      by `id` alone, would touch its earlier rows too.

    41 (`orca.alerts`, Ops › Alerts) is additive: a new table, which the
    binaries before it neither read nor write; their alerts are only
    missing from it.

    42 (`orca.schedulers`, `runs.instance`: docs/overlap.md) is additive:
    the binaries before it don't write instance rows, and start runs with
    `instance` left as it was, which no live instance lists, so it holds
    nothing.

    44 (learned requests, `morca._internal.recommend`) is additive: new nullable
    columns the binaries before it neither read nor write. A start they make
    leaves `request_source` and `request_runs` as an earlier start set them.

    58 (`pool_machines.image`, `draining`, #356) is additive: nullable
    columns the binaries before it neither read nor write. A machine one of
    them makes has no image recorded, so a newer autoscaler replaces it
    once it's idle.
    59 (`pipelines.retired`, #427) is additive: a nullable column the
    binaries before it neither read nor write. While one overlaps a newer
    one it would still start a retired pipeline's runs, but only the
    instance that leads starts runs, and the newer one leads.
    60 (`pipelines.priority`, #421) is additive: a column with a default,
    which the binaries before it neither read nor write; they start the
    pipelines by name, as they did, and a registration they make leaves it
    as it was.
    61 (`workers.room_cpus`, `room_memory_mb`, #462) is additive: nullable
    columns the binaries before it neither read nor write.
    """
    return [1, 24]


def migration_floor(version: Int) -> Int:
    """The fewest migrations a binary must know to run on a database at
    schema version `version`: the newest floor-raising migration up to it."""
    var floor = 0
    for v in _floor_raisers():
        if v <= version and v > floor:
            floor = v
    return floor


def known_migrations() raises -> Int:
    """How many migrations this binary knows: all of `_migrations`, or fewer
    under `MORCA_TEST_MIGRATIONS=N`, which the tests use to act as an older
    binary on a database a newer one migrated."""
    var n = len(_migrations())
    var test = getenv("MORCA_TEST_MIGRATIONS")
    if test:
        var t = Int(test)
        if 0 <= t < n:
            return t
    return n


def schema_ahead(have: Int, floor: Int, known: Int) raises -> Bool:
    """Whether a binary that knows `known` migrations runs on a database at
    schema version `have` without migrating it: False when the database
    isn't ahead (the binary applies what it lacks), True when it's ahead
    with only additive migrations since (`floor`, the fewest migrations the
    database says a binary must know, is at most `known`). Raises when the
    database needs a newer binary, or doesn't say (`floor` < 0)."""
    if have <= known:
        return False
    if floor < 0 or floor > known:
        var why = String(
            "a migration since needs a binary that knows at least ",
            floor,
        ) if floor >= 0 else String(
            "it doesn't record which binaries can run on it"
        )
        raise Error(
            "morca: the database is at schema version ",
            have,
            ", newer than this binary's ",
            known,
            ", and ",
            why,
            "; deploy a newer binary, or restore a backup taken before the",
            " upgrade (docs/hetzner.md#rolling-back)",
        )
    return True
