//! The run store (docs/pipeline-protocol.md, "The run store"): the
//! `RunStore` contract on Postgres (`MORCA_DATABASE_URL=postgres://...`) and
//! on a SQLite file (`sqlite:<path>`), each statement written as morca's own
//! (`src/morca/_internal/db/runs.mojo`, `steps.mojo`, `sqlite_runs.mojo`).
//!
//! [`Owned`] is the store as a run's owner: the calls for the run (attempts,
//! skips, reads and commits, its end) retried for `MORCA_DB_RETRY_SECONDS`
//! on a new connection, except a lost or cancelled run, which is final.

pub(crate) mod pg;
pub(crate) mod sqlite;

use std::collections::HashMap;
use std::fmt;
use std::time::{Duration, Instant};

/// A store error: `Final` (the run was lost or cancelled, or the commit
/// fence said no) isn't retried; `Retry` (the database) is.
#[derive(Debug, Clone)]
pub(crate) enum DbError {
    Final(String),
    Retry(String),
}

impl fmt::Display for DbError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DbError::Final(m) | DbError::Retry(m) => f.write_str(m),
        }
    }
}

impl From<postgres::Error> for DbError {
    fn from(e: postgres::Error) -> Self {
        DbError::Retry(format!("Postgres: {e}"))
    }
}

impl From<rusqlite::Error> for DbError {
    fn from(e: rusqlite::Error) -> Self {
        DbError::Retry(format!("SQLite: {e}"))
    }
}

pub(crate) type Res<T> = Result<T, DbError>;

pub(crate) const RUNNING: &str = "running";
pub(crate) const SUCCEEDED: &str = "succeeded";
pub(crate) const FAILED: &str = "failed";
pub(crate) const SKIPPED: &str = "skipped";
pub(crate) const DEFERRED: &str = "deferred";
pub(crate) const CANCELLED: &str = "cancelled";
/// An attempt a process left running, when no crash says why.
pub(crate) const INTERRUPTED: &str = "interrupted: the process running it stopped";

pub(crate) fn lost(run: i64) -> DbError {
    DbError::Final(format!(
        "morca: lost run {run} to another process; stopping"
    ))
}

pub(crate) fn cancelled(run: i64) -> DbError {
    DbError::Final(format!("morca: run {run} was cancelled; stopping"))
}

#[derive(Debug, Clone)]
pub(crate) struct RunInfo {
    pub pipeline: String,
    pub registry_hash: String,
    pub partitions: String,
    pub status: String,
    pub owner: String,
}

/// The fence's look at a run before a commit.
pub(crate) struct Fence {
    pub owner: String,
    pub status: String,
    pub fresh: bool,
}

/// An attempt as `start_attempt` made it.
#[derive(Clone, Copy)]
pub(crate) struct Attempt {
    /// 1, 2, ... for the step row.
    pub number: i64,
    /// The `attempts` row.
    pub id: i64,
}

/// One store: a Postgres connection or a SQLite file.
pub(crate) trait RunStore: Send {
    /// Postgres: checks the schema has what this binary uses (the scheduler
    /// migrates it). SQLite: makes or brings up the file's schema.
    fn migrate(&mut self) -> Res<()>;
    fn reconnect(&mut self) -> Res<()>;
    fn run_info(&mut self, run: i64) -> Res<Option<RunInfo>>;
    fn claim(&mut self, run: i64, owner: &str, stale: f64) -> Res<bool>;
    fn version(&mut self, pipeline: &str, hash: &str, describe: &str, image: &str) -> Res<i64>;
    fn ran_version(&mut self, run: i64, version: i64) -> Res<()>;
    /// Fails the run's running attempts and steps with `why`; how many
    /// attempts.
    fn interrupt(&mut self, run: i64, why: &str) -> Res<u64>;
    /// The run's succeeded steps: (step, partition) to output.
    fn prior(&mut self, run: i64) -> Res<HashMap<(String, String), Vec<u8>>>;
    fn run_token(&mut self, run: i64) -> Res<String>;
    #[allow(clippy::too_many_arguments)]
    fn start_attempt(
        &mut self,
        run: i64,
        owner: &str,
        hash: &str,
        step: &str,
        partition: &str,
        ord: i32,
        input: &[u8],
    ) -> Res<Attempt>;
    #[allow(clippy::too_many_arguments)]
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
    ) -> Res<()>;
    fn skip(
        &mut self,
        run: i64,
        owner: &str,
        step: &str,
        partition: &str,
        ord: i32,
        reason: &str,
    ) -> Res<()>;
    fn set_log(&mut self, attempt_id: i64, location: &str) -> Res<()>;
    fn pinned_reads(&mut self, run: i64, step: &str, partition: &str) -> Res<HashMap<String, i64>>;
    fn record(
        &mut self,
        commit: bool,
        attempt_id: i64,
        table: &str,
        snapshot: i64,
        dataset: &str,
    ) -> Res<()>;
    fn fence(&mut self, run: i64, fresh_seconds: f64) -> Res<Option<Fence>>;
    fn cancel_requested(&mut self, run: i64) -> Res<bool>;
    fn finish_run(&mut self, run: i64, owner: &str, status: &str) -> Res<()>;
    fn defer_run(&mut self, run: i64, owner: &str, until: i64) -> Res<()>;
    /// The heartbeat's own connection.
    fn beater(&self, run: i64, owner: &str, timeouts: &str) -> Box<dyn crate::heartbeat::Beater>;
}

/// The store for `MORCA_DATABASE_URL`.
pub(crate) fn open(url: &str) -> Res<Box<dyn RunStore>> {
    if let Some(path) = sqlite::path_of(url) {
        return Ok(Box::new(sqlite::SqliteStore::open(&path)?));
    }
    Ok(Box::new(pg::PgStore::connect(url)?))
}

/// `MORCA_STALE_SECONDS` (default 30): the scheduler's stale limit.
pub(crate) fn stale_seconds() -> f64 {
    std::env::var("MORCA_STALE_SECONDS")
        .ok()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|v| *v > 0.0)
        .unwrap_or(30.0)
}

/// `MORCA_DB_RETRY_SECONDS`, default the stale limit.
fn retry_budget() -> f64 {
    std::env::var("MORCA_DB_RETRY_SECONDS")
        .ok()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|v| *v >= 0.0)
        .unwrap_or_else(stale_seconds)
}

/// The store as the owner of one run.
pub(crate) struct Owned {
    pub store: Box<dyn RunStore>,
    pub run: i64,
    pub owner: String,
    pub hash: String,
    /// The `attempts` row of the attempt last started.
    pub attempt_id: i64,
}

impl Owned {
    /// Runs `f`, retrying a database error on a new connection for
    /// `budget` seconds: waits 0.25 s, doubling up to 4 s.
    fn retry<T>(&mut self, budget: f64, mut f: impl FnMut(&mut dyn RunStore) -> Res<T>) -> Res<T> {
        let end = Instant::now() + Duration::from_secs_f64(budget);
        let mut wait = 0.25;
        loop {
            match f(self.store.as_mut()) {
                Ok(v) => return Ok(v),
                Err(DbError::Final(m)) => return Err(DbError::Final(m)),
                Err(DbError::Retry(m)) => {
                    if Instant::now() + Duration::from_secs_f64(wait) > end {
                        return Err(DbError::Retry(m));
                    }
                    eprintln!("morca: {m}; retrying in {wait} s");
                    std::thread::sleep(Duration::from_secs_f64(wait));
                    wait = (wait * 2.0_f64).min(4.0);
                    let _ = self.store.reconnect();
                }
            }
        }
    }

    pub fn start_attempt(
        &mut self,
        step: &str,
        partition: &str,
        ord: i32,
        input: &[u8],
    ) -> Res<i64> {
        let (run, owner, hash) = (self.run, self.owner.clone(), self.hash.clone());
        let a = self.retry(retry_budget(), |s| {
            s.start_attempt(run, &owner, &hash, step, partition, ord, input)
        })?;
        self.attempt_id = a.id;
        Ok(a.number)
    }

    pub fn finish_attempt(
        &mut self,
        step: &str,
        partition: &str,
        attempt: i64,
        status: &str,
        output: &[u8],
        error: &str,
    ) -> Res<()> {
        let (run, owner) = (self.run, self.owner.clone());
        self.retry(retry_budget(), |s| {
            s.finish_attempt(run, &owner, step, partition, attempt, status, output, error)
        })
    }

    pub fn skip(&mut self, step: &str, partition: &str, ord: i32, reason: &str) -> Res<()> {
        let (run, owner) = (self.run, self.owner.clone());
        self.retry(retry_budget(), |s| {
            s.skip(run, &owner, step, partition, ord, reason)
        })
    }

    pub fn set_log(&mut self, location: &str) -> Res<()> {
        let id = self.attempt_id;
        self.retry(retry_budget(), |s| s.set_log(id, location))
    }

    pub fn pinned_reads(&mut self, step: &str, partition: &str) -> Res<HashMap<String, i64>> {
        let run = self.run;
        self.retry(retry_budget(), |s| s.pinned_reads(run, step, partition))
    }

    pub fn run_token(&mut self) -> Res<String> {
        let run = self.run;
        self.retry(retry_budget(), |s| s.run_token(run))
    }

    /// Records a read or a commit of the current attempt.
    pub fn record(&mut self, commit: bool, table: &str, snapshot: i64, dataset: &str) -> Res<()> {
        let id = self.attempt_id;
        self.retry(retry_budget(), |s| {
            s.record(commit, id, table, snapshot, dataset)
        })
    }

    /// Whether this process may still commit: it owns the run, running,
    /// with a heartbeat fresher than half the stale limit. A database it
    /// can't reach is retried for half the stale limit, then the commit is
    /// refused too.
    pub fn fence(&mut self) -> Res<()> {
        let half = stale_seconds() / 2.0;
        let run = self.run;
        let got = self
            .retry(half, |s| s.fence(run, half))
            .map_err(|e| match e {
                DbError::Retry(m) => DbError::Final(format!("morca: not committing: {m}")),
                f => f,
            })?;
        let Some(f) = got else {
            return Err(DbError::Final(format!(
                "morca: not committing: no run {run}"
            )));
        };
        if f.owner != self.owner {
            return Err(DbError::Final(format!(
                "morca: not committing: run {run} is held by {}",
                if f.owner.is_empty() {
                    "nobody"
                } else {
                    &f.owner
                }
            )));
        }
        if f.status != RUNNING {
            return Err(DbError::Final(format!(
                "morca: not committing: run {run} is {}",
                f.status
            )));
        }
        if !f.fresh {
            return Err(DbError::Final(format!(
                "morca: not committing: run {run}'s heartbeat is older than {half} s"
            )));
        }
        Ok(())
    }

    pub fn cancel_requested(&mut self) -> Res<bool> {
        let run = self.run;
        self.retry(retry_budget(), |s| s.cancel_requested(run))
    }

    pub fn finish_run(&mut self, status: &str) -> Res<()> {
        let (run, owner) = (self.run, self.owner.clone());
        self.retry(retry_budget(), |s| s.finish_run(run, &owner, status))
    }

    pub fn defer_run(&mut self, until: i64) -> Res<()> {
        let (run, owner) = (self.run, self.owner.clone());
        self.retry(retry_budget(), |s| s.defer_run(run, &owner, until))
    }
}

/// `<hostname>:<pid>`: unique per live process, and never `scheduler`.
pub(crate) fn process_owner() -> String {
    unsafe extern "C" {
        fn gethostname(name: *mut std::ffi::c_char, len: usize) -> std::ffi::c_int;
    }
    let mut buf = [0u8; 256];
    let host = if unsafe { gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0 {
        let n = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        String::from_utf8_lossy(&buf[..n]).into_owned()
    } else {
        String::new()
    };
    let host = if host.is_empty() {
        "localhost".to_string()
    } else {
        host
    };
    format!("{host}:{}", std::process::id())
}

/// `b` as lower-case hex: how the SQLite file keeps a step's bytes.
pub(crate) fn to_hex(b: &[u8]) -> String {
    const H: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push(H[(x >> 4) as usize] as char);
        s.push(H[(x & 15) as usize] as char);
    }
    s
}

pub(crate) fn from_hex(s: &str) -> Res<Vec<u8>> {
    let nib = |c: u8| match c {
        b'0'..=b'9' => Ok(c - b'0'),
        b'a'..=b'f' => Ok(c - b'a' + 10),
        b'A'..=b'F' => Ok(c - b'A' + 10),
        _ => Err(DbError::Retry("morca: not hex in the SQLite store".into())),
    };
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len() / 2);
    for i in (0..b.len().saturating_sub(1)).step_by(2) {
        out.push(nib(b[i])? << 4 | nib(b[i + 1])?);
    }
    Ok(out)
}
