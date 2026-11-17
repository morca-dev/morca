//! A step's view of its commits, as `morca.Ctx` has it (src/morca/ctx.mojo):
//! the `orca.*` snapshot summary of its next commit to a table, and
//! `find_commit`, which recognises a commit an earlier attempt of the step
//! made in this run. Stored names stay `orca` (#384).

use std::collections::HashMap;

use iceberg::spec::TableMetadata;

pub struct StepCtx {
    pub pipeline: String,
    pub run: i64,
    pub step: String,
    pub partition: String,
    pub partitions: String,
    pub attempt: i64,
    pub code: String,
    /// (table location, snapshot id) of what the step read, in order.
    pub reads: Vec<(String, i64)>,
    /// Commits this attempt made, by table location.
    pub commits: Vec<String>,
    pub token: String,
}

impl StepCtx {
    pub fn commits_to(&self, table: &str) -> usize {
        self.commits.iter().filter(|t| *t == table).count()
    }

    /// `Ctx.summary`: the properties of this step's next commit to `table`.
    pub fn summary(&self, table: &str) -> HashMap<String, String> {
        let reads = self
            .reads
            .iter()
            .map(|(t, id)| format!("{t}@{id}"))
            .collect::<Vec<_>>()
            .join(",");
        let mut s = HashMap::from([
            ("orca.pipeline".into(), self.pipeline.clone()),
            ("orca.run".into(), self.run.to_string()),
            ("orca.step".into(), self.step.clone()),
            ("orca.partition".into(), self.partition.clone()),
            ("orca.partitions".into(), self.partitions.clone()),
            ("orca.attempt".into(), self.attempt.to_string()),
            ("orca.commit".into(), self.commits_to(table).to_string()),
            ("orca.code".into(), self.code.clone()),
            ("orca.reads".into(), reads),
        ]);
        if !self.token.is_empty() {
            s.insert("orca.run-token".into(), self.token.clone());
        }
        s
    }

    /// `Ctx.made`: whether a snapshot with `summary` is this step's next
    /// commit to `table`, by any attempt of this run. Every key must be
    /// there; a run token, when both sides have one, must agree.
    pub fn made(&self, table: &str, summary: &HashMap<String, String>) -> bool {
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
            && has("orca.commit", &self.commits_to(table).to_string())
            && token_fits
    }

    /// `find_commit`: the snapshot this step already committed as its next
    /// commit to the table, or None. Walks the snapshots newest first.
    pub fn find_commit(&self, metadata: &TableMetadata) -> Option<i64> {
        let loc = metadata.location();
        let mut snaps: Vec<_> = metadata.snapshots().collect();
        snaps.sort_by_key(|s| std::cmp::Reverse(s.sequence_number()));
        snaps
            .into_iter()
            .find(|s| self.made(loc, &s.summary().additional_properties))
            .map(|s| s.snapshot_id())
    }
}
