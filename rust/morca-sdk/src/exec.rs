//! Executing a claimed run (docs/pipeline-protocol.md, "Executing"): each
//! step in describe order, each key for a mapped step or once for a gather
//! step, skipping what succeeded before, skipping what follows a step that
//! didn't succeed, and trying each attempt up to the step's retries.

use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::time::Duration;

use serde_json::{Value, json};

use crate::ctx::Ctx;
use crate::logs;
use crate::pipeline::{Built, Kind, StepDef, StepError, decode_value};
use crate::store::{DEFERRED, FAILED, Owned, Res, SKIPPED, SUCCEEDED};

/// One step and partition's outcome in this run.
pub(crate) struct Done {
    pub status: &'static str,
    pub output: Vec<u8>,
    pub error: String,
    /// When a deferred step may run again (Unix seconds).
    pub until: i64,
}

pub(crate) struct Results {
    /// (step, partition) in the order they were settled.
    pub order: Vec<(String, String)>,
    pub by: HashMap<(String, String), Done>,
}

impl Results {
    fn ok(&self, step: &str, partition: &str) -> Option<&Vec<u8>> {
        self.by
            .get(&(step.to_string(), partition.to_string()))
            .filter(|d| d.status == SUCCEEDED)
            .map(|d| &d.output)
    }

    fn put(&mut self, step: &str, partition: &str, d: Done) {
        let k = (step.to_string(), partition.to_string());
        if !self.by.contains_key(&k) {
            self.order.push(k.clone());
        }
        self.by.insert(k, d);
    }

    /// `succeeded` if every step did, else `deferred` if one deferred and
    /// none failed, else `failed`.
    pub fn outcome(&self) -> &'static str {
        let all: Vec<&Done> = self.by.values().collect();
        if all.iter().all(|d| d.status == SUCCEEDED) {
            SUCCEEDED
        } else if all.iter().any(|d| d.status == DEFERRED)
            && !all.iter().any(|d| d.status == FAILED)
        {
            DEFERRED
        } else {
            FAILED
        }
    }

    pub fn deferred_until(&self) -> i64 {
        self.by.values().map(|d| d.until).max().unwrap_or(0)
    }
}

fn panic_text(p: Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = p.downcast_ref::<&str>() {
        s.to_string()
    } else if let Some(s) = p.downcast_ref::<String>() {
        s.clone()
    } else {
        "a panic".to_string()
    }
}

/// Runs what's left of the run over `keys`. A store error is returned: the
/// run stops where it is and can be resumed.
pub(crate) fn execute(
    p: &Built,
    store: &mut Owned,
    keys: &[String],
    prior: HashMap<(String, String), Vec<u8>>,
) -> Res<Results> {
    let mut res = Results {
        order: vec![],
        by: HashMap::new(),
    };
    for ((s, part), out) in prior {
        res.put(
            &s,
            &part,
            Done {
                status: SUCCEEDED,
                output: out,
                error: String::new(),
                until: 0,
            },
        );
    }
    let all_keys = keys.join(",");
    for (i, st) in p.steps.iter().enumerate() {
        let name = st.spec.name.as_str();
        let up = st.after.as_deref();
        let up_kind = i.checked_sub(1).map(|j| p.steps[j].kind);
        match st.kind {
            Kind::Mapped => {
                for key in keys {
                    if res.ok(name, key).is_some() {
                        continue;
                    }
                    let (input, blocked) = match up {
                        None => (
                            (p.key_input)(key).map_err(crate::store::DbError::Retry)?,
                            None,
                        ),
                        Some(u) => match res.ok(u, key) {
                            Some(o) => (o.clone(), None),
                            None => (vec![], Some(format!("{u} {key}"))),
                        },
                    };
                    run_step(p, st, i, store, &mut res, key, input, blocked, key)?;
                }
            }
            Kind::Gather => {
                if res.ok(name, "").is_some() {
                    continue;
                }
                let (input, blocked) = match (up, up_kind) {
                    (None, _) => (
                        (p.keys_input)(keys).map_err(crate::store::DbError::Retry)?,
                        None,
                    ),
                    (Some(u), Some(Kind::Gather)) => match res.ok(u, "") {
                        Some(o) => (o.clone(), None),
                        None => (vec![], Some(u.to_string())),
                    },
                    (Some(u), _) => gather_input(p, st, i, &res, u, keys),
                };
                run_step(p, st, i, store, &mut res, "", input, blocked, &all_keys)?;
            }
        }
    }
    Ok(res)
}

/// A gather's input over a mapped step: the upstream outputs in key order,
/// each checked to be the upstream's output type; or what blocks it.
fn gather_input(
    p: &Built,
    st: &StepDef,
    i: usize,
    res: &Results,
    up: &str,
    keys: &[String],
) -> (Vec<u8>, Option<String>) {
    let want = &p.steps[i - 1].output;
    let mut blocked = vec![];
    let mut values = vec![];
    for k in keys {
        match res.ok(up, k) {
            None => blocked.push(format!("{up} {k}")),
            Some(o) => match decode_value(o, want) {
                Ok(v) => values.push(v),
                // An output an older build stored as another type: the
                // step's decode then fails, naming it.
                Err(e) => {
                    let bad = json!({"type": format!("{up} [{k}]'s output ({e})"), "value": null});
                    return (serde_json::to_vec(&bad).unwrap(), None);
                }
            },
        }
    }
    if !blocked.is_empty() {
        return (vec![], Some(blocked.join(", ")));
    }
    let input = json!({"type": st.input, "value": Value::Array(values)});
    (serde_json::to_vec(&input).unwrap(), None)
}

#[allow(clippy::too_many_arguments)]
fn run_step(
    p: &Built,
    st: &StepDef,
    ord: usize,
    store: &mut Owned,
    res: &mut Results,
    partition: &str,
    input: Vec<u8>,
    blocked: Option<String>,
    holds: &str,
) -> Res<()> {
    let name = st.spec.name.as_str();
    if let Some(b) = blocked {
        let reason = format!("not run: {b} didn't succeed");
        store.skip(name, partition, ord as i32, &reason)?;
        res.put(
            name,
            partition,
            Done {
                status: SKIPPED,
                output: vec![],
                error: reason,
                until: 0,
            },
        );
        return Ok(());
    }
    // Every attempt reads the snapshots the first one read.
    let mut pinned = store.pinned_reads(name, partition)?;
    let token = store.run_token()?;
    let code = p.registry_hash();
    let mut wait = st.spec.backoff_seconds as f64;
    let mut outcome = Done {
        status: FAILED,
        output: vec![],
        error: String::new(),
        until: 0,
    };
    for k in 0..=st.spec.retries {
        if k > 0 && wait > 0.0 {
            println!("[{name} {partition}] retrying in {} s", wait as i64);
            std::thread::sleep(Duration::from_secs_f64(wait));
            wait *= 2.0;
        }
        let attempt = store.start_attempt(name, partition, ord as i32, &input)?;
        let log = logs::attempt_log(p.name(), store.run, name, partition, attempt);
        if let Some(l) = &log {
            store.set_log(l)?;
        }
        let mut ctx = Ctx {
            pipeline: p.name().to_string(),
            run: store.run,
            step: name.to_string(),
            partition: partition.to_string(),
            partitions: holds.to_string(),
            attempt,
            code: code.clone(),
            token: token.clone(),
            pinned: pinned.clone(),
            reads: vec![],
            commits: vec![],
            declared_reads: st.spec.reads.clone(),
            declared_writes: st.spec.writes.clone(),
            log_path: log,
            store,
        };
        ctx.log_to_file(&format!("attempt {attempt} started"));
        let got = match catch_unwind(AssertUnwindSafe(|| (st.run)(&mut ctx, &input))) {
            Ok(r) => r,
            Err(panic) => Err(StepError::Failed(format!(
                "panicked: {}",
                panic_text(panic)
            ))),
        };
        match &got {
            Ok(_) => ctx.log_to_file(&format!("attempt {attempt} succeeded")),
            Err(e) => ctx.log(format!("attempt {attempt} failed: {}", e.message())),
        }
        for (t, s) in &ctx.reads {
            pinned.entry(t.clone()).or_insert(*s);
        }
        drop(ctx);
        match got {
            Ok(out) => {
                store.finish_attempt(name, partition, attempt, SUCCEEDED, &out, "")?;
                outcome = Done {
                    status: SUCCEEDED,
                    output: out,
                    error: String::new(),
                    until: 0,
                };
                break;
            }
            Err(StepError::Defer { seconds, why }) => {
                let until = logs::unix_now() + seconds as i64;
                let why = format!("deferred until {}Z: {why}", logs::civil(until));
                store.finish_attempt(name, partition, attempt, DEFERRED, &[], &why)?;
                outcome = Done {
                    status: DEFERRED,
                    output: vec![],
                    error: why,
                    until,
                };
                break;
            }
            Err(StepError::Failed(e)) => {
                let e = logs::mask(&e);
                store.finish_attempt(name, partition, attempt, FAILED, &[], &e)?;
                outcome.error = e;
            }
        }
    }
    res.put(name, partition, outcome);
    Ok(())
}
