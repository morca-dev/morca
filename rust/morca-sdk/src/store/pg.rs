//! The run store in Postgres (`orca.*`), with the statements of
//! src/morca/_internal/db/runs.mojo and steps.mojo. Every parameter is cast
//! in the SQL, so the Rust types bound are the ones named here whatever the
//! column's type.

use std::collections::HashMap;

use postgres::{Client, NoTls, Transaction};

use super::{Attempt, DbError, Fence, INTERRUPTED, Res, RunInfo, RunStore, cancelled, lost};
use crate::heartbeat::{self, Beater};

pub(crate) struct PgStore {
    url: String,
    client: Client,
}

fn connect(url: &str) -> Res<Client> {
    Client::connect(url, NoTls).map_err(|e| DbError::Retry(format!("Postgres: can't connect: {e}")))
}

impl PgStore {
    pub fn connect(url: &str) -> Res<PgStore> {
        Ok(PgStore {
            url: url.to_string(),
            client: connect(url)?,
        })
    }
}

/// The columns this binary reads or writes, by table: the schema must have
/// them all (the scheduler migrates it; a pipeline binary doesn't).
const COLUMNS: &[(&str, &[&str])] = &[
    (
        "pipelines",
        &[
            "name",
            "registry_hash",
            "describe",
            "binary_path",
            "version",
        ],
    ),
    (
        "pipeline_versions",
        &[
            "id",
            "pipeline",
            "registry_hash",
            "source",
            "commit_sha",
            "dirty",
            "image",
            "data_version",
            "last_seen",
        ],
    ),
    (
        "runs",
        &[
            "id",
            "pipeline",
            "registry_hash",
            "partitions",
            "status",
            "owner",
            "heartbeat",
            "ended",
            "error",
            "version",
            "retry_at",
            "deferrals",
            "cancel_requested",
            "cancel_at",
            "token",
            "instance",
        ],
    ),
    (
        "steps",
        &[
            "id",
            "run",
            "step",
            "partition",
            "ord",
            "status",
            "input",
            "output",
            "error",
        ],
    ),
    (
        "attempts",
        &[
            "id",
            "step",
            "attempt",
            "status",
            "host",
            "registry_hash",
            "started",
            "ended",
            "error",
            "log",
        ],
    ),
    (
        "reads",
        &["attempt", "table_name", "snapshot_id", "dataset"],
    ),
    (
        "commits",
        &["attempt", "table_name", "snapshot_id", "dataset"],
    ),
    ("audit", &["username", "action", "run", "detail"]),
    (
        "schedulers",
        &["id", "ended", "draining_since", "drain_asked", "running"],
    ),
];

/// Ownership at every step: refreshes the heartbeat if `owner` still holds
/// the run running; None if it doesn't, else whether a cancel was asked.
fn still_owner(tx: &mut Transaction, run: i64, owner: &str) -> Res<Option<bool>> {
    let rows = tx.query(
        "UPDATE orca.runs SET heartbeat = now() WHERE id = $1::bigint AND owner = $2::text \
         AND status = 'running' RETURNING cancel_requested",
        &[&run, &owner],
    )?;
    Ok(rows.first().map(|r| r.get::<_, bool>(0)))
}

fn fail_running(tx: &mut Transaction, run: i64, why_attempts: &str, why_steps: &str) -> Res<u64> {
    let n = tx.execute(
        "UPDATE orca.attempts a SET status = 'failed', ended = now(), error = $2::text \
         FROM orca.steps s WHERE a.step = s.id AND s.run = $1::bigint AND a.status = 'running'",
        &[&run, &why_attempts],
    )?;
    tx.execute(
        "UPDATE orca.steps SET status = 'failed', error = $2::text WHERE run = $1::bigint \
         AND status = 'running'",
        &[&run, &why_steps],
    )?;
    Ok(n)
}

/// `data_version_sql` (src/morca/_internal/migrations.mojo): the steps'
/// `version=` as `<step>=<version>`, by step name.
const DATA_VERSION: &str = "coalesce((SELECT string_agg((x->>'name') || '=' || (x->>'version'), \
',' ORDER BY x->>'name') FROM jsonb_array_elements((d)->'steps') AS x WHERE x->>'version' IS NOT \
NULL), '')";

impl RunStore for PgStore {
    fn migrate(&mut self) -> Res<()> {
        let rows = self.client.query(
            "SELECT table_name::text, column_name::text FROM information_schema.columns \
             WHERE table_schema = 'orca'",
            &[],
        )?;
        let have: std::collections::HashSet<(String, String)> =
            rows.iter().map(|r| (r.get(0), r.get(1))).collect();
        if !have.iter().any(|(t, _)| t == "runs") {
            return Err(DbError::Final(
                "morca: the database has no morca schema: start the scheduler or run \
                 `morca register` first"
                    .into(),
            ));
        }
        let mut missing = vec![];
        for (t, cols) in COLUMNS {
            for c in *cols {
                if !have.contains(&(t.to_string(), c.to_string())) {
                    missing.push(format!("orca.{t}.{c}"));
                }
            }
        }
        if !missing.is_empty() {
            return Err(DbError::Final(format!(
                "morca: the database's schema is older than this binary (no {}): upgrade the scheduler",
                missing.join(", ")
            )));
        }
        Ok(())
    }

    fn reconnect(&mut self) -> Res<()> {
        self.client = connect(&self.url)?;
        Ok(())
    }

    fn run_info(&mut self, run: i64) -> Res<Option<RunInfo>> {
        let rows = self.client.query(
            "SELECT pipeline, registry_hash, partitions, status, coalesce(owner, '') \
             FROM orca.runs WHERE id = $1::bigint",
            &[&run],
        )?;
        Ok(rows.first().map(|r| RunInfo {
            pipeline: r.get(0),
            registry_hash: r.get(1),
            partitions: r.get(2),
            status: r.get(3),
            owner: r.get(4),
        }))
    }

    fn claim(&mut self, run: i64, owner: &str, stale: f64) -> Res<bool> {
        let rows = self.client.query(
            "UPDATE orca.runs SET status = 'running', owner = $2::text, heartbeat = now(), \
             ended = NULL, error = NULL WHERE id = $1::bigint AND status IN ('queued', \
             'running', 'failed', 'deferred') AND (heartbeat IS NULL OR heartbeat < now() - \
             make_interval(secs => $3::float8)) RETURNING id",
            &[&run, &owner, &stale],
        )?;
        Ok(rows.len() == 1)
    }

    fn version(&mut self, pipeline: &str, hash: &str, describe: &str, image: &str) -> Res<i64> {
        let sql = format!(
            "INSERT INTO orca.pipeline_versions (pipeline, registry_hash, source, commit_sha, \
             dirty, image, data_version) SELECT $1::text, $2::text, coalesce(d->'source'->>'repo', \
             ''), coalesce(d->'source'->>'commit', ''), coalesce((d->'source'->>'dirty')::boolean, \
             false), $4::text, {DATA_VERSION} FROM (SELECT $3::text::jsonb AS d) AS x ON CONFLICT \
             (pipeline, registry_hash, source, commit_sha, dirty, image) DO UPDATE SET last_seen = \
             now(), data_version = excluded.data_version RETURNING id::bigint"
        );
        let row = self
            .client
            .query_one(&sql, &[&pipeline, &hash, &describe, &image])?;
        Ok(row.get(0))
    }

    fn ran_version(&mut self, run: i64, version: i64) -> Res<()> {
        self.client.execute(
            "UPDATE orca.runs SET version = $2::bigint WHERE id = $1::bigint",
            &[&run, &version],
        )?;
        Ok(())
    }

    fn interrupt(&mut self, run: i64, why: &str) -> Res<u64> {
        let mut tx = self.client.transaction()?;
        let n = fail_running(
            &mut tx,
            run,
            if why.is_empty() { INTERRUPTED } else { why },
            if why.is_empty() { "interrupted" } else { why },
        )?;
        tx.commit()?;
        Ok(n)
    }

    fn prior(&mut self, run: i64) -> Res<HashMap<(String, String), Vec<u8>>> {
        let rows = self.client.query(
            "SELECT step, partition, coalesce(output, ''::bytea) FROM orca.steps WHERE run = \
             $1::bigint AND status = 'succeeded'",
            &[&run],
        )?;
        Ok(rows
            .iter()
            .map(|r| ((r.get(0), r.get(1)), r.get::<_, Vec<u8>>(2)))
            .collect())
    }

    fn run_token(&mut self, run: i64) -> Res<String> {
        let rows = self.client.query(
            "SELECT coalesce(token::text, '') FROM orca.runs WHERE id = $1::bigint",
            &[&run],
        )?;
        Ok(rows.first().map(|r| r.get(0)).unwrap_or_default())
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
        let mut tx = self.client.transaction()?;
        match still_owner(&mut tx, run, owner)? {
            None => return Err(lost(run)),
            Some(true) => return Err(cancelled(run)),
            Some(false) => {}
        }
        let step_id: i64 = tx
            .query_one(
                "INSERT INTO orca.steps (run, step, partition, ord, status, input) VALUES \
                 ($1::bigint, $2::text, $3::text, $4::int, 'running', $5::bytea) ON CONFLICT \
                 (run, step, partition) DO UPDATE SET status = 'running', input = \
                 EXCLUDED.input, error = NULL RETURNING id::bigint",
                &[&run, &step, &partition, &ord, &input],
            )?
            .get(0);
        let number: i64 = tx
            .query_one(
                "SELECT (coalesce(max(attempt), 0) + 1)::bigint FROM orca.attempts WHERE step = \
                 $1::bigint",
                &[&step_id],
            )?
            .get(0);
        let id: i64 = tx
            .query_one(
                "INSERT INTO orca.attempts (step, attempt, status, host, registry_hash) VALUES \
                 ($1::bigint, $2::bigint, 'running', $3::text, $4::text) RETURNING id::bigint",
                &[&step_id, &number, &owner, &hash],
            )?
            .get(0);
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
        let mut tx = self.client.transaction()?;
        if still_owner(&mut tx, run, owner)?.is_none() {
            return Err(lost(run));
        }
        let step_id: i64 = tx
            .query_one(
                "SELECT id::bigint FROM orca.steps WHERE run = $1::bigint AND step = $2::text AND \
                 partition = $3::text",
                &[&run, &step, &partition],
            )?
            .get(0);
        let err: Option<&str> = if error.is_empty() { None } else { Some(error) };
        tx.execute(
            "UPDATE orca.attempts SET status = $3::text, ended = now(), error = $4::text WHERE \
             step = $1::bigint AND attempt = $2::bigint",
            &[&step_id, &attempt, &status, &err],
        )?;
        let out: Option<&[u8]> = if status == super::SUCCEEDED {
            Some(output)
        } else {
            None
        };
        tx.execute(
            "UPDATE orca.steps SET status = $2::text, output = $3::bytea, error = $4::text WHERE \
             id = $1::bigint",
            &[&step_id, &status, &out, &err],
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
        let mut tx = self.client.transaction()?;
        match still_owner(&mut tx, run, owner)? {
            None => return Err(lost(run)),
            Some(true) => return Err(cancelled(run)),
            Some(false) => {}
        }
        tx.execute(
            "INSERT INTO orca.steps (run, step, partition, ord, status, error) VALUES \
             ($1::bigint, $2::text, $3::text, $4::int, 'skipped', $5::text) ON CONFLICT (run, \
             step, partition) DO UPDATE SET status = 'skipped', error = EXCLUDED.error, output = \
             NULL",
            &[&run, &step, &partition, &ord, &reason],
        )?;
        tx.commit()?;
        Ok(())
    }

    fn set_log(&mut self, attempt_id: i64, location: &str) -> Res<()> {
        self.client.execute(
            "UPDATE orca.attempts SET log = $2::text WHERE id = $1::bigint",
            &[&attempt_id, &location],
        )?;
        Ok(())
    }

    fn pinned_reads(&mut self, run: i64, step: &str, partition: &str) -> Res<HashMap<String, i64>> {
        let rows = self.client.query(
            "SELECT r.table_name, r.snapshot_id::bigint FROM orca.reads r JOIN orca.attempts a ON \
             a.id = r.attempt JOIN orca.steps s ON s.id = a.step WHERE s.run = $1::bigint AND \
             s.step = $2::text AND s.partition = $3::text ORDER BY a.attempt DESC",
            &[&run, &step, &partition],
        )?;
        // Newest first, so the first attempt's snapshot is the one left.
        let mut out = HashMap::new();
        for r in rows {
            out.insert(r.get::<_, String>(0), r.get::<_, i64>(1));
        }
        Ok(out)
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
            "INSERT INTO orca.{} (attempt, table_name, snapshot_id, dataset) VALUES ($1::bigint, \
             $2::text, $3::bigint, nullif($4::text, ''))",
            if commit { "commits" } else { "reads" }
        );
        self.client
            .execute(&sql, &[&attempt_id, &table, &snapshot, &dataset])?;
        Ok(())
    }

    fn fence(&mut self, run: i64, fresh_seconds: f64) -> Res<Option<Fence>> {
        let rows = self.client.query(
            "SELECT coalesce(owner, ''), status, coalesce(heartbeat > now() - make_interval(secs \
             => $2::float8), false) FROM orca.runs WHERE id = $1::bigint",
            &[&run, &fresh_seconds],
        )?;
        Ok(rows.first().map(|r| Fence {
            owner: r.get(0),
            status: r.get(1),
            fresh: r.get(2),
        }))
    }

    fn cancel_requested(&mut self, run: i64) -> Res<bool> {
        let rows = self.client.query(
            "SELECT cancel_requested FROM orca.runs WHERE id = $1::bigint",
            &[&run],
        )?;
        Ok(rows.first().is_some_and(|r| r.get::<_, bool>(0)))
    }

    fn finish_run(&mut self, run: i64, owner: &str, status: &str) -> Res<()> {
        self.client.execute(
            "UPDATE orca.runs SET status = $2::text, ended = now(), heartbeat = NULL WHERE id = \
             $1::bigint AND owner = $3::text",
            &[&run, &status, &owner],
        )?;
        Ok(())
    }

    fn defer_run(&mut self, run: i64, owner: &str, until: i64) -> Res<()> {
        self.client.execute(
            "UPDATE orca.runs SET status = 'deferred', ended = now(), heartbeat = NULL, retry_at \
             = $3::bigint, deferrals = deferrals + 1 WHERE id = $1::bigint AND owner = $2::text",
            &[&run, &owner, &until],
        )?;
        Ok(())
    }

    fn beater(&self, run: i64, owner: &str, timeouts: &str) -> Box<dyn Beater> {
        Box::new(PgBeat {
            url: self.url.clone(),
            run,
            owner: owner.to_string(),
            timeouts: timeouts.to_string(),
            client: None,
        })
    }
}

struct PgBeat {
    url: String,
    run: i64,
    owner: String,
    timeouts: String,
    client: Option<Client>,
}

/// The watchdog's query (`_WATCH_SQL` in src/morca/_internal/db/runs.mojo):
/// a cancel whose time has come, or a running attempt past its step's
/// timeout.
const WATCH_SQL: &str = "SELECT 'cancel' AS why, 0::bigint AS attempt, '' AS step, '' AS \
partition, 0::float8 AS secs FROM orca.runs WHERE id = $1::bigint AND owner = $2::text AND status \
= 'running' AND cancel_requested AND cancel_at <= now() UNION ALL SELECT 'timeout', a.id::bigint, \
s.step, s.partition, t.secs FROM orca.attempts a JOIN orca.steps s ON s.id = a.step JOIN \
orca.runs r ON r.id = s.run JOIN (SELECT split_part(x, '=', 1) AS step, split_part(x, '=', \
2)::float8 AS secs FROM unnest(string_to_array($3::text, ',')) AS x) AS t ON t.step = s.step \
WHERE s.run = $1::bigint AND r.owner = $2::text AND r.status = 'running' AND a.status = \
'running' AND a.started <= now() - make_interval(secs => t.secs) LIMIT 1";

/// `outdated_sql` (src/morca/_internal/db/handover.mojo): whether the run
/// is outdated, its version's label and the registered one's.
const OUTDATED_SQL: &str = "SELECT r.status = 'running' AND (coalesce(rv.registry_hash <> \
pv.registry_hash OR rv.commit_sha <> pv.commit_sha OR rv.dirty <> pv.dirty, false) OR \
coalesce((s.draining_since IS NOT NULL OR s.drain_asked IS NOT NULL) AND s.ended IS NULL AND \
r.id::text = ANY(string_to_array(s.running, ',')), false)) AS outdated, coalesce(rv.registry_hash \
<> pv.registry_hash OR rv.commit_sha <> pv.commit_sha OR rv.dirty <> pv.dirty, false) AS differs \
FROM orca.runs r JOIN orca.pipelines p ON p.name = r.pipeline LEFT JOIN orca.pipeline_versions rv \
ON rv.id = r.version LEFT JOIN orca.pipeline_versions pv ON pv.id = p.version LEFT JOIN \
orca.schedulers s ON s.id = r.instance WHERE r.id = $1::bigint";

impl PgBeat {
    fn stop_reason(&mut self) -> Res<Option<String>> {
        let (run, owner) = (self.run, self.owner.clone());
        let c = self.client.as_mut().unwrap();
        let rows = c.query(WATCH_SQL, &[&run, &owner, &self.timeouts])?;
        let Some(r) = rows.first() else {
            return Ok(None);
        };
        let what: String = r.get(0);
        let attempt: i64 = r.get(1);
        let step: String = r.get(2);
        let partition: String = r.get(3);
        let secs: f64 = r.get(4);
        let mut tx = c.transaction()?;
        let why = if what == "timeout" {
            let mut why = heartbeat::timed_out_why(secs);
            let n = tx.execute(
                "UPDATE orca.attempts SET status = 'failed', ended = now(), error = $2::text WHERE \
                 id = $1::bigint AND status = 'running'",
                &[&attempt, &why],
            )?;
            if n != 1 {
                return Ok(None); // it ended as we looked
            }
            tx.execute(
                "UPDATE orca.steps SET status = 'failed', error = $2::text WHERE id = (SELECT \
                 step FROM orca.attempts WHERE id = $1::bigint)",
                &[&attempt, &why],
            )?;
            let named = if partition.is_empty() {
                step
            } else {
                format!("{step} {partition}")
            };
            why = format!("step {named} {why}");
            tx.execute(
                "UPDATE orca.runs SET status = 'failed', ended = now(), heartbeat = NULL, error = \
                 $3::text WHERE id = $1::bigint AND owner = $2::text",
                &[&run, &owner, &why],
            )?;
            why
        } else {
            let why = heartbeat::CANCEL_WHY.to_string();
            fail_running(&mut tx, run, &why, &why)?;
            tx.execute(
                "UPDATE orca.runs SET status = 'cancelled', ended = now(), heartbeat = NULL WHERE \
                 id = $1::bigint AND owner = $2::text",
                &[&run, &owner],
            )?;
            why
        };
        let detail = format!("{owner}: {why}");
        tx.execute(
            "INSERT INTO orca.audit (username, action, run, detail) VALUES ('orca', 'stop', \
             $1::bigint, $2::text)",
            &[&run, &detail],
        )?;
        tx.commit()?;
        Ok(Some(why))
    }
}

impl Beater for PgBeat {
    fn beat(&mut self) -> Result<Option<String>, String> {
        if self.client.is_none() {
            self.client = Some(connect(&self.url).map_err(|e| e.to_string())?);
        }
        let (run, owner) = (self.run, self.owner.clone());
        self.client
            .as_mut()
            .unwrap()
            .execute(
                "UPDATE orca.runs SET heartbeat = now() WHERE id = $1::bigint AND owner = \
                 $2::text AND status = 'running'",
                &[&run, &owner],
            )
            .map_err(|e| e.to_string())?;
        if let Some(why) = self.stop_reason().map_err(|e| e.to_string())? {
            return Ok(Some(why));
        }
        // Whether a newer version leads, for `Ctx::stopping`. Not knowing
        // keeps the last answer and never stops the beat.
        if let Ok(rows) = self.client.as_mut().unwrap().query(OUTDATED_SQL, &[&run])
            && let Some(r) = rows.first()
        {
            let o: Option<bool> = r.get(0);
            let differs: Option<bool> = r.get(1);
            let why = match (o, differs) {
                (Some(true), Some(true)) => {
                    "the pipeline is registered with newer code".to_string()
                }
                (Some(true), _) => {
                    "its scheduler instance is draining: a newer one leads".to_string()
                }
                _ => String::new(),
            };
            heartbeat::set_outdated(o.unwrap_or(false), why);
        }
        Ok(None)
    }

    fn reset(&mut self) {
        self.client = None;
    }
}
