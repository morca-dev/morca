//! The run store in a SQLite file (`MORCA_DATABASE_URL=sqlite:<path>`),
//! with the schema of src/morca/_internal/db/sqlite_schema.mojo and the
//! statements of db/sqlite_runs.mojo: Postgres's tables without the `orca.`
//! prefix, times as Unix seconds, a step's bytes as lower-case hex. WAL mode,
//! one writer at a time (`BEGIN IMMEDIATE`), a second's `busy_timeout`.
//!
//! Unlike Postgres, the binary makes the file's schema itself: `migrate`
//! applies the migrations the file hasn't had, recorded in
//! `schema_version` as the Mojo binary records them, so either binary can
//! use a file the other made.

use std::collections::HashMap;

use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};

use super::{
    Attempt, DbError, Fence, INTERRUPTED, Res, RunInfo, RunStore, cancelled, from_hex, lost, to_hex,
};
use crate::heartbeat::{self, Beater};

/// Unix seconds, to the millisecond, in SQL.
const NOW: &str = "((julianday('now') - 2440587.5) * 86400.0)";

/// The file of `sqlite:<path>` or `sqlite://<path>`.
pub(crate) fn path_of(url: &str) -> Option<String> {
    let rest = url.strip_prefix("sqlite:")?;
    Some(rest.strip_prefix("//").unwrap_or(rest).to_string())
}

fn open(path: &str) -> Res<Connection> {
    if path.is_empty() {
        return Err(DbError::Final("morca: no file in the SQLite URL".into()));
    }
    let c = Connection::open(path)?;
    c.busy_timeout(std::time::Duration::from_millis(1000))?;
    c.query_row("PRAGMA journal_mode = WAL", [], |_| Ok(()))?;
    c.execute_batch("PRAGMA synchronous = FULL; PRAGMA foreign_keys = ON;")?;
    Ok(c)
}

/// src/morca/_internal/db/sqlite_schema.mojo's migrations; a migration's
/// version is its index + 1.
const MIGRATIONS: &[&[&str]] = &[
    &[
        "CREATE TABLE pipelines (
            name TEXT PRIMARY KEY,
            registry_hash TEXT NOT NULL,
            describe TEXT NOT NULL,
            binary_path TEXT,
            version INTEGER,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL)",
        "CREATE TABLE pipeline_versions (
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
                image))",
        "CREATE TABLE runs (
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
            error TEXT)",
        "CREATE TABLE steps (
            id INTEGER PRIMARY KEY,
            run INTEGER NOT NULL REFERENCES runs (id),
            step TEXT NOT NULL,
            partition TEXT NOT NULL,
            ord INTEGER NOT NULL,
            status TEXT NOT NULL,
            input TEXT,
            output TEXT,
            error TEXT,
            UNIQUE (run, step, partition))",
        "CREATE TABLE attempts (
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
            UNIQUE (step, attempt))",
        "CREATE TABLE reads (
            attempt INTEGER NOT NULL REFERENCES attempts (id),
            table_name TEXT NOT NULL,
            snapshot_id INTEGER NOT NULL,
            dataset TEXT)",
        "CREATE TABLE commits (
            attempt INTEGER NOT NULL REFERENCES attempts (id),
            table_name TEXT NOT NULL,
            snapshot_id INTEGER NOT NULL,
            dataset TEXT)",
        "CREATE INDEX reads_attempt ON reads (attempt)",
        "CREATE INDEX commits_attempt ON commits (attempt)",
        "CREATE INDEX steps_run ON steps (run, ord)",
    ],
    &[
        "ALTER TABLE runs ADD COLUMN retry_at INTEGER",
        "ALTER TABLE runs ADD COLUMN deferrals INTEGER NOT NULL DEFAULT 0",
    ],
    &[
        "ALTER TABLE attempts ADD COLUMN peak_rss_bytes INTEGER",
        "ALTER TABLE attempts ADD COLUMN cpu_seconds REAL",
        "ALTER TABLE attempts ADD COLUMN peak_cpus REAL",
    ],
    &["ALTER TABLE runs ADD COLUMN token TEXT"],
];

pub(crate) struct SqliteStore {
    path: String,
    db: Connection,
}

impl SqliteStore {
    pub fn open(path: &str) -> Res<SqliteStore> {
        Ok(SqliteStore {
            path: path.to_string(),
            db: open(path)?,
        })
    }
}

fn now_sql(s: &str) -> String {
    s.replace("{NOW}", NOW)
}

fn still_owner(tx: &rusqlite::Transaction, run: i64, owner: &str) -> Res<Option<bool>> {
    Ok(tx
        .query_row(
            &now_sql(
                "UPDATE runs SET heartbeat = {NOW} WHERE id = ?1 AND owner = ?2 AND status = \
                 'running' RETURNING cancel_requested",
            ),
            params![run, owner],
            |r| r.get::<_, i64>(0),
        )
        .optional()?
        .map(|c| c != 0))
}

fn fail_running(tx: &rusqlite::Transaction, run: i64, why_a: &str, why_s: &str) -> Res<u64> {
    let n = tx.execute(
        &now_sql(
            "UPDATE attempts SET status = 'failed', ended = {NOW}, error = ?2 WHERE status = \
             'running' AND step IN (SELECT id FROM steps WHERE run = ?1)",
        ),
        params![run, why_a],
    )?;
    tx.execute(
        "UPDATE steps SET status = 'failed', error = ?2 WHERE run = ?1 AND status = 'running'",
        params![run, why_s],
    )?;
    Ok(n as u64)
}

impl RunStore for SqliteStore {
    fn migrate(&mut self) -> Res<()> {
        // BEGIN IMMEDIATE takes the write lock: two processes starting at
        // once don't both apply a migration.
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)",
            [],
        )?;
        let have: i64 = tx.query_row(
            "SELECT coalesce(max(version), 0) FROM schema_version",
            [],
            |r| r.get(0),
        )?;
        for (i, m) in MIGRATIONS.iter().enumerate() {
            let v = i as i64 + 1;
            if v <= have {
                continue;
            }
            for s in *m {
                tx.execute(s, [])?;
            }
            tx.execute("INSERT INTO schema_version VALUES (?1)", params![v])?;
        }
        tx.commit()?;
        Ok(())
    }

    fn reconnect(&mut self) -> Res<()> {
        self.db = open(&self.path)?;
        Ok(())
    }

    fn run_info(&mut self, run: i64) -> Res<Option<RunInfo>> {
        Ok(self
            .db
            .query_row(
                "SELECT pipeline, registry_hash, partitions, status, coalesce(owner, '') FROM \
                 runs WHERE id = ?1",
                params![run],
                |r| {
                    Ok(RunInfo {
                        pipeline: r.get(0)?,
                        registry_hash: r.get(1)?,
                        partitions: r.get(2)?,
                        status: r.get(3)?,
                        owner: r.get(4)?,
                    })
                },
            )
            .optional()?)
    }

    fn claim(&mut self, run: i64, owner: &str, stale: f64) -> Res<bool> {
        let got = self
            .db
            .query_row(
                &now_sql(
                    "UPDATE runs SET status = 'running', owner = ?2, heartbeat = {NOW}, ended = \
                     NULL, error = NULL WHERE id = ?1 AND status IN ('queued', 'running', \
                     'failed', 'deferred') AND (heartbeat IS NULL OR heartbeat < {NOW} - ?3) \
                     RETURNING id",
                ),
                params![run, owner, stale],
                |r| r.get::<_, i64>(0),
            )
            .optional()?;
        Ok(got.is_some())
    }

    fn version(&mut self, pipeline: &str, hash: &str, describe: &str, image: &str) -> Res<i64> {
        Ok(self.db.query_row(
            &now_sql(
                "INSERT INTO pipeline_versions (pipeline, registry_hash, source, commit_sha, \
                 dirty, image, first_seen, last_seen) VALUES (?1, ?2, \
                 coalesce(json_extract(?3, '$.source.repo'), ''), coalesce(json_extract(?3, \
                 '$.source.commit'), ''), coalesce(json_extract(?3, '$.source.dirty'), 0), ?4, \
                 {NOW}, {NOW}) ON CONFLICT (pipeline, registry_hash, source, commit_sha, dirty, \
                 image) DO UPDATE SET last_seen = excluded.last_seen RETURNING id",
            ),
            params![pipeline, hash, describe, image],
            |r| r.get(0),
        )?)
    }

    fn ran_version(&mut self, run: i64, version: i64) -> Res<()> {
        self.db.execute(
            "UPDATE runs SET version = ?2 WHERE id = ?1",
            params![run, version],
        )?;
        Ok(())
    }

    fn interrupt(&mut self, run: i64, why: &str) -> Res<u64> {
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let n = fail_running(
            &tx,
            run,
            if why.is_empty() { INTERRUPTED } else { why },
            if why.is_empty() { "interrupted" } else { why },
        )?;
        tx.commit()?;
        Ok(n)
    }

    fn prior(&mut self, run: i64) -> Res<HashMap<(String, String), Vec<u8>>> {
        let mut st = self.db.prepare(
            "SELECT step, partition, coalesce(output, '') FROM steps WHERE run = ?1 AND status = \
             'succeeded' ORDER BY id",
        )?;
        let rows: Vec<(String, String, String)> = st
            .query_map(params![run], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<Result<_, _>>()?;
        let mut out = HashMap::new();
        for (s, p, o) in rows {
            out.insert((s, p), from_hex(&o)?);
        }
        Ok(out)
    }

    fn run_token(&mut self, run: i64) -> Res<String> {
        Ok(self
            .db
            .query_row(
                "SELECT coalesce(token, '') FROM runs WHERE id = ?1",
                params![run],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or_default())
    }

    fn start_attempt(
        &mut self,
        run: i64,
        owner: &str,
        hash: &str,
        step: &str,
        partition: &str,
        ord: i32,
        input: &[u8],
    ) -> Res<Attempt> {
        let input = to_hex(input);
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        match still_owner(&tx, run, owner)? {
            None => return Err(lost(run)),
            Some(true) => return Err(cancelled(run)),
            Some(false) => {}
        }
        let step_id: i64 = tx.query_row(
            "INSERT INTO steps (run, step, partition, ord, status, input) VALUES (?1, ?2, ?3, \
             ?4, 'running', ?5) ON CONFLICT (run, step, partition) DO UPDATE SET status = \
             'running', input = excluded.input, error = NULL RETURNING id",
            params![run, step, partition, ord, input],
            |r| r.get(0),
        )?;
        let number: i64 = tx.query_row(
            "SELECT coalesce(max(attempt), 0) + 1 FROM attempts WHERE step = ?1",
            params![step_id],
            |r| r.get(0),
        )?;
        let id: i64 = tx.query_row(
            &now_sql(
                "INSERT INTO attempts (step, attempt, status, host, registry_hash, started) \
                 VALUES (?1, ?2, 'running', ?3, ?4, {NOW}) RETURNING id",
            ),
            params![step_id, number, owner, hash],
            |r| r.get(0),
        )?;
        tx.commit()?;
        Ok(Attempt { number, id })
    }

    fn finish_attempt(
        &mut self,
        run: i64,
        owner: &str,
        step: &str,
        partition: &str,
        attempt: i64,
        status: &str,
        output: &[u8],
        error: &str,
    ) -> Res<()> {
        let output = to_hex(output);
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        if still_owner(&tx, run, owner)?.is_none() {
            return Err(lost(run));
        }
        let step_id: i64 = tx.query_row(
            "SELECT id FROM steps WHERE run = ?1 AND step = ?2 AND partition = ?3",
            params![run, step, partition],
            |r| r.get(0),
        )?;
        tx.execute(
            &now_sql(
                "UPDATE attempts SET status = ?3, ended = {NOW}, error = nullif(?4, '') WHERE \
                 step = ?1 AND attempt = ?2",
            ),
            params![step_id, attempt, status, error],
        )?;
        let out: Option<&str> = if status == super::SUCCEEDED {
            Some(&output)
        } else {
            None
        };
        tx.execute(
            "UPDATE steps SET status = ?2, output = ?3, error = nullif(?4, '') WHERE id = ?1",
            params![step_id, status, out, error],
        )?;
        tx.commit()?;
        Ok(())
    }

    fn skip(
        &mut self,
        run: i64,
        owner: &str,
        step: &str,
        partition: &str,
        ord: i32,
        reason: &str,
    ) -> Res<()> {
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        match still_owner(&tx, run, owner)? {
            None => return Err(lost(run)),
            Some(true) => return Err(cancelled(run)),
            Some(false) => {}
        }
        tx.execute(
            "INSERT INTO steps (run, step, partition, ord, status, error) VALUES (?1, ?2, ?3, \
             ?4, 'skipped', ?5) ON CONFLICT (run, step, partition) DO UPDATE SET status = \
             'skipped', error = excluded.error, output = NULL",
            params![run, step, partition, ord, reason],
        )?;
        tx.commit()?;
        Ok(())
    }

    fn set_log(&mut self, attempt_id: i64, location: &str) -> Res<()> {
        self.db.execute(
            "UPDATE attempts SET log = ?2 WHERE id = ?1",
            params![attempt_id, location],
        )?;
        Ok(())
    }

    fn pinned_reads(&mut self, run: i64, step: &str, partition: &str) -> Res<HashMap<String, i64>> {
        let mut st = self.db.prepare(
            "SELECT r.table_name, r.snapshot_id FROM reads r JOIN attempts a ON a.id = r.attempt \
             JOIN steps s ON s.id = a.step WHERE s.run = ?1 AND s.step = ?2 AND s.partition = ?3 \
             ORDER BY a.attempt DESC",
        )?;
        let rows: Vec<(String, i64)> = st
            .query_map(params![run, step, partition], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })?
            .collect::<Result<_, _>>()?;
        Ok(rows.into_iter().collect())
    }

    fn record(
        &mut self,
        commit: bool,
        attempt_id: i64,
        table: &str,
        snapshot: i64,
        dataset: &str,
    ) -> Res<()> {
        let sql = format!(
            "INSERT INTO {} (attempt, table_name, snapshot_id, dataset) VALUES (?1, ?2, ?3, \
             nullif(?4, ''))",
            if commit { "commits" } else { "reads" }
        );
        self.db
            .execute(&sql, params![attempt_id, table, snapshot, dataset])?;
        Ok(())
    }

    fn fence(&mut self, run: i64, fresh_seconds: f64) -> Res<Option<Fence>> {
        Ok(self
            .db
            .query_row(
                &now_sql(
                    "SELECT coalesce(owner, ''), status, coalesce(heartbeat > {NOW} - ?2, 0) \
                     FROM runs WHERE id = ?1",
                ),
                params![run, fresh_seconds],
                |r| {
                    Ok(Fence {
                        owner: r.get(0)?,
                        status: r.get(1)?,
                        fresh: r.get::<_, i64>(2)? != 0,
                    })
                },
            )
            .optional()?)
    }

    fn cancel_requested(&mut self, run: i64) -> Res<bool> {
        Ok(self
            .db
            .query_row(
                "SELECT cancel_requested FROM runs WHERE id = ?1",
                params![run],
                |r| r.get::<_, i64>(0),
            )
            .optional()?
            .is_some_and(|c| c != 0))
    }

    fn finish_run(&mut self, run: i64, owner: &str, status: &str) -> Res<()> {
        self.db.execute(
            &now_sql(
                "UPDATE runs SET status = ?2, ended = {NOW}, heartbeat = NULL WHERE id = ?1 AND \
                 owner = ?3",
            ),
            params![run, status, owner],
        )?;
        Ok(())
    }

    fn defer_run(&mut self, run: i64, owner: &str, until: i64) -> Res<()> {
        self.db.execute(
            &now_sql(
                "UPDATE runs SET status = 'deferred', ended = {NOW}, heartbeat = NULL, retry_at = \
                 ?3, deferrals = deferrals + 1 WHERE id = ?1 AND owner = ?2",
            ),
            params![run, owner, until],
        )?;
        Ok(())
    }

    fn beater(&self, run: i64, owner: &str, timeouts: &str) -> Box<dyn Beater> {
        Box::new(SqliteBeat {
            path: self.path.clone(),
            run,
            owner: owner.to_string(),
            timeouts: timeouts.to_string(),
            db: None,
        })
    }
}

/// The heartbeat over the file. There's no cancel to time out here: a
/// cancel is the scheduler's, on Postgres.
struct SqliteBeat {
    path: String,
    run: i64,
    owner: String,
    timeouts: String,
    db: Option<Connection>,
}

impl SqliteBeat {
    fn timed_out(&mut self) -> Res<Option<String>> {
        if self.timeouts.is_empty() {
            return Ok(None);
        }
        let (run, owner) = (self.run, self.owner.clone());
        let pairs: Vec<(String, f64)> = self
            .timeouts
            .split(',')
            .filter_map(|p| {
                let (s, t) = p.split_once('=')?;
                Some((s.to_string(), t.parse().ok()?))
            })
            .collect();
        let db = self.db.as_mut().unwrap();
        for (step, secs) in pairs {
            let got: Option<(i64, String)> = db
                .query_row(
                    &now_sql(
                        "SELECT a.id, s.partition FROM attempts a JOIN steps s ON s.id = a.step \
                         JOIN runs r ON r.id = s.run WHERE s.run = ?1 AND s.step = ?2 AND \
                         r.owner = ?3 AND r.status = 'running' AND a.status = 'running' AND \
                         a.started <= {NOW} - ?4 LIMIT 1",
                    ),
                    params![run, step, owner, secs],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            let Some((attempt, partition)) = got else {
                continue;
            };
            let why = heartbeat::timed_out_why(secs);
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let n = tx.execute(
                &now_sql(
                    "UPDATE attempts SET status = 'failed', ended = {NOW}, error = ?2 WHERE id = \
                     ?1 AND status = 'running'",
                ),
                params![attempt, why],
            )?;
            if n != 1 {
                return Ok(None); // it ended as we looked
            }
            tx.execute(
                "UPDATE steps SET status = 'failed', error = ?2 WHERE id = (SELECT step FROM \
                 attempts WHERE id = ?1)",
                params![attempt, why],
            )?;
            let named = if partition.is_empty() {
                step
            } else {
                format!("{step} {partition}")
            };
            let run_why = format!("step {named} {why}");
            tx.execute(
                &now_sql(
                    "UPDATE runs SET status = 'failed', ended = {NOW}, heartbeat = NULL, error = \
                     ?3 WHERE id = ?1 AND owner = ?2",
                ),
                params![run, owner, run_why],
            )?;
            tx.commit()?;
            return Ok(Some(run_why));
        }
        Ok(None)
    }
}

impl Beater for SqliteBeat {
    fn beat(&mut self) -> Result<Option<String>, String> {
        if self.db.is_none() {
            self.db = Some(open(&self.path).map_err(|e| e.to_string())?);
        }
        let (run, owner) = (self.run, self.owner.clone());
        self.db
            .as_ref()
            .unwrap()
            .execute(
                &now_sql(
                    "UPDATE runs SET heartbeat = {NOW} WHERE id = ?1 AND owner = ?2 AND status = \
                     'running'",
                ),
                params![run, owner],
            )
            .map_err(|e| e.to_string())?;
        self.timed_out().map_err(|e| e.to_string())
    }

    fn reset(&mut self) {
        self.db = None;
    }
}
