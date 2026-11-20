"""The SQLite file's schema (`morca._internal.sqlite_store`): its migrations and
`schema_version`, which `SqliteStore.migrate` applies and reads in one
`BEGIN IMMEDIATE` transaction of its own.

The tables are Postgres's (`morca._internal.migrations`), under the same names without
the `orca.` schema, holding what a pipeline binary writes: steps' inputs and
outputs are hex text, times are Unix seconds."""

from sqlite import Database


def migrations() -> List[List[String]]:
    """Each migration is a list of statements; its version is its index + 1."""
    return [
        [
            """CREATE TABLE pipelines (
            name TEXT PRIMARY KEY,
            registry_hash TEXT NOT NULL,
            describe TEXT NOT NULL,
            binary_path TEXT,
            version INTEGER,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL)""",
            """CREATE TABLE pipeline_versions (
            id INTEGER PRIMARY KEY,
            pipeline TEXT NOT NULL REFERENCES pipelines (name),
            registry_hash TEXT NOT NULL,
            source TEXT NOT NULL,
            commit_sha TEXT NOT NULL,
            dirty INTEGER NOT NULL,
            image TEXT NOT NULL,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL,
            UNIQUE (pipeline, registry_hash, source, commit_sha, dirty,
                image))""",
            # AUTOINCREMENT: a run's number is in the summaries of the
            # snapshots it commits, so it's never given out twice.
            """CREATE TABLE runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pipeline TEXT NOT NULL,
            registry_hash TEXT NOT NULL,
            partitions TEXT NOT NULL,
            trigger TEXT NOT NULL,
            status TEXT NOT NULL,
            owner TEXT,
            heartbeat REAL,
            created REAL NOT NULL,
            started REAL,
            ended REAL,
            cancel_requested INTEGER NOT NULL DEFAULT 0,
            version INTEGER REFERENCES pipeline_versions (id),
            error TEXT)""",
            """CREATE TABLE steps (
            id INTEGER PRIMARY KEY,
            run INTEGER NOT NULL REFERENCES runs (id),
            step TEXT NOT NULL,
            partition TEXT NOT NULL,
            ord INTEGER NOT NULL,
            status TEXT NOT NULL,
            input TEXT,
            output TEXT,
            error TEXT,
            UNIQUE (run, step, partition))""",
            """CREATE TABLE attempts (
            id INTEGER PRIMARY KEY,
            step INTEGER NOT NULL REFERENCES steps (id),
            attempt INTEGER NOT NULL,
            status TEXT NOT NULL,
            host TEXT NOT NULL,
            registry_hash TEXT NOT NULL,
            started REAL NOT NULL,
            ended REAL,
            error TEXT,
            log TEXT,
            UNIQUE (step, attempt))""",
            """CREATE TABLE reads (
            attempt INTEGER NOT NULL REFERENCES attempts (id),
            table_name TEXT NOT NULL,
            snapshot_id INTEGER NOT NULL,
            dataset TEXT)""",
            """CREATE TABLE commits (
            attempt INTEGER NOT NULL REFERENCES attempts (id),
            table_name TEXT NOT NULL,
            snapshot_id INTEGER NOT NULL,
            dataset TEXT)""",
            "CREATE INDEX reads_attempt ON reads (attempt)",
            "CREATE INDEX commits_attempt ON commits (attempt)",
            "CREATE INDEX steps_run ON steps (run, ord)",
        ],
        # A run a step deferred (#66): when it may go on, and how many
        # times it was, as Postgres's migration 18 keeps them.
        [
            "ALTER TABLE runs ADD COLUMN retry_at INTEGER",
            "ALTER TABLE runs ADD COLUMN deferrals INTEGER NOT NULL DEFAULT 0",
        ],
        # What each attempt's processes used, as Postgres's migration 35
        # keeps it (morca.usage); a run in a file has no scheduler or worker
        # to measure it, so they stay null unless copied in.
        [
            "ALTER TABLE attempts ADD COLUMN peak_rss_bytes INTEGER",
            "ALTER TABLE attempts ADD COLUMN cpu_seconds REAL",
            "ALTER TABLE attempts ADD COLUMN peak_cpus REAL",
        ],
        # A random token per run, as Postgres's migration 47 keeps it
        # (#292): a file that was deleted and made again gives out the same
        # run numbers. SQLite adds no column with a default that isn't
        # constant, so `morca._internal.db.sqlite_runs.create` sets it (`UUID7`), and
        # older runs have none.
        [
            "ALTER TABLE runs ADD COLUMN token TEXT",
        ],
        # When a running run asked to cancel is stopped if its step hasn't
        # finished, as Postgres's migration 19 keeps it (#527), in Unix
        # seconds; the heartbeat's watchdog reads it.
        [
            "ALTER TABLE runs ADD COLUMN cancel_at REAL",
        ],
    ]


def ensure(db: Database) raises:
    """Creates `schema_version` if there's none."""
    db.execute(
        "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)"
    )


def current(db: Database) raises -> Int:
    """The file's schema version, 0 for none."""
    return (
        db.prepare("SELECT coalesce(max(version), 0) FROM schema_version")
        .step()
        .value()
        .int_val(0)
    )


def applied(db: Database, version: Int) raises:
    """Records that `version` was applied."""
    db.execute(String("INSERT INTO schema_version VALUES (", version, ")"))
