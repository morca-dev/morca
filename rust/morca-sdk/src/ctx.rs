//! A step's context: who it is (pipeline, run, step, partition, attempt),
//! its log, progress and metrics, its secrets, the stop flag, and with the
//! `tables` feature its tables (`crate::tables`). morca-worker's
//! `RunContext` has the same calls for a worker step.

use std::collections::HashMap;
use std::sync::atomic::Ordering;

use crate::heartbeat;
use crate::logs;
use crate::store::{DbError, Owned};

/// What a step gets beside its input.
pub struct Ctx<'a> {
    pub(crate) pipeline: String,
    pub(crate) run: i64,
    pub(crate) step: String,
    pub(crate) partition: String,
    /// The keys this step's commits hold: its partition, or the run's keys
    /// for a gather step, comma-joined.
    pub(crate) partitions: String,
    pub(crate) attempt: i64,
    pub(crate) code: String,
    pub(crate) token: String,
    /// The snapshot each table (by location) was first read at in this
    /// step and partition, by an earlier attempt.
    pub(crate) pinned: HashMap<String, i64>,
    /// (location, snapshot) of each table this attempt read, in order.
    pub(crate) reads: Vec<(String, i64)>,
    /// The location of each commit this attempt made, in order.
    pub(crate) commits: Vec<String>,
    pub(crate) declared_reads: Vec<String>,
    pub(crate) declared_writes: Vec<String>,
    pub(crate) log_path: Option<String>,
    pub(crate) store: &'a mut Owned,
}

impl Ctx<'_> {
    pub fn pipeline(&self) -> &str {
        &self.pipeline
    }
    pub fn run(&self) -> i64 {
        self.run
    }
    pub fn step(&self) -> &str {
        &self.step
    }
    /// The step's partition key; empty for a gather step.
    pub fn partition(&self) -> &str {
        &self.partition
    }
    /// 1 for the first attempt of this step and partition in this run.
    pub fn attempt(&self) -> i64 {
        self.attempt
    }
    /// The registry hash of the code running.
    pub fn code(&self) -> &str {
        &self.code
    }

    fn tag(&self) -> String {
        if self.partition.is_empty() {
            format!("[{}] ", self.step)
        } else {
            format!("[{} {}] ", self.step, self.partition)
        }
    }

    /// Writes a line tagged with the step and partition to stdout, and with
    /// a timestamp to the attempt's log file; secrets masked.
    pub fn log(&self, msg: impl AsRef<str>) {
        let line = logs::mask(msg.as_ref());
        println!("{}{line}", self.tag());
        self.log_to_file(&line);
    }

    pub(crate) fn log_to_file(&self, msg: &str) {
        if let Some(p) = &self.log_path {
            logs::append_line(
                p,
                &format!("{} {}{}", logs::utc_now(), self.tag(), logs::mask(msg)),
            );
        }
    }

    /// Reports progress as a log line: `done` of `total` units.
    pub fn progress(&self, done: u64, total: u64) {
        self.log(format!("progress {done}/{total}"));
    }

    /// Reports a metric as a log line.
    pub fn metric(&self, name: &str, value: f64) {
        self.log(format!("metric {name}={value}"));
    }

    /// A secret the run was given (`MORCA_SECRETS` names it), or None.
    pub fn secret(&self, name: &str) -> Option<String> {
        if logs::secret_names().iter().any(|n| n == name) {
            std::env::var(name).ok()
        } else {
            None
        }
    }

    /// Whether the run should end early: it's outdated, since newer code is
    /// registered or its scheduler instance drains (Postgres only). Poll it
    /// between units of work, from any thread; what to do is up to the step.
    pub fn stopping(&self) -> bool {
        heartbeat::outdated().flag.load(Ordering::SeqCst)
    }

    /// Why [`Ctx::stopping`] is true.
    pub fn stopping_why(&self) -> String {
        heartbeat::outdated()
            .why
            .lock()
            .map(|w| w.clone())
            .unwrap_or_default()
    }

    /// The `orca.*` snapshot summary of this step's next commit to the
    /// table at `location` (`Ctx.summary` in src/morca/ctx.mojo).
    pub fn summary(&self, location: &str) -> HashMap<String, String> {
        let reads = self
            .reads
            .iter()
            .map(|(t, id)| format!("{t}@{id}"))
            .collect::<Vec<_>>()
            .join(",");
        let mut s = HashMap::from([
            ("orca.pipeline".to_string(), self.pipeline.clone()),
            ("orca.run".to_string(), self.run.to_string()),
            ("orca.step".to_string(), self.step.clone()),
            ("orca.partition".to_string(), self.partition.clone()),
            ("orca.partitions".to_string(), self.partitions.clone()),
            ("orca.attempt".to_string(), self.attempt.to_string()),
            (
                "orca.commit".to_string(),
                self.commits_to(location).to_string(),
            ),
            ("orca.code".to_string(), self.code.clone()),
            ("orca.reads".to_string(), reads),
        ]);
        if !self.token.is_empty() {
            s.insert("orca.run-token".to_string(), self.token.clone());
        }
        s
    }

    pub(crate) fn commits_to(&self, location: &str) -> usize {
        self.commits.iter().filter(|t| *t == location).count()
    }

    /// `Ctx.made`: whether a snapshot with `summary` is this step's next
    /// commit to the table at `location`, by any attempt of this run. Every
    /// key must be there; a run token, when both have one, must agree.
    pub fn made(&self, location: &str, summary: &HashMap<String, String>) -> bool {
        if self.run <= 0 {
            return false;
        }
        let has = |k: &str, v: &str| summary.get(k).is_some_and(|x| x == v);
        let token_fits = self.token.is_empty()
            || summary
                .get("orca.run-token")
                .is_none_or(|t| t.is_empty() || *t == self.token);
        has("orca.pipeline", &self.pipeline)
            && has("orca.run", &self.run.to_string())
            && has("orca.step", &self.step)
            && has("orca.partition", &self.partition)
            && has("orca.commit", &self.commits_to(location).to_string())
            && token_fits
    }

    /// The snapshot to read the table at `location` at: the one this
    /// attempt already read, else the one an earlier attempt read, else
    /// `current` (-1 for an empty table).
    pub(crate) fn pin(&self, location: &str, current: i64) -> i64 {
        if let Some((_, s)) = self.reads.iter().find(|(t, _)| t == location) {
            return *s;
        }
        self.pinned.get(location).copied().unwrap_or(current)
    }

    /// Records a read of `location` at `snapshot`, once per attempt.
    pub(crate) fn record_read(
        &mut self,
        location: &str,
        snapshot: i64,
        dataset: &str,
    ) -> Result<(), DbError> {
        if self.reads.iter().any(|(t, _)| t == location) {
            return Ok(());
        }
        self.store.record(false, location, snapshot, dataset)?;
        self.reads.push((location.to_string(), snapshot));
        Ok(())
    }

    /// Records this attempt's commit of `snapshot` to `location`.
    pub(crate) fn record_commit(
        &mut self,
        location: &str,
        snapshot: i64,
        dataset: &str,
    ) -> Result<(), DbError> {
        self.store.record(true, location, snapshot, dataset)?;
        self.commits.push(location.to_string());
        Ok(())
    }

    /// The commit fence: whether this process may still commit.
    pub(crate) fn fence(&mut self) -> Result<(), DbError> {
        self.store.fence()
    }
}
