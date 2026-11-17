//! Defining a pipeline: its name, steps in order, partitions, schedule and
//! retries, built at start-up and checked when built.
//!
//! The builder is typed: each step takes what the step before it makes, so
//! a step whose input doesn't fit the step before it doesn't compile. A
//! first `mapped` step takes the partition key, a `gather` after a mapped
//! step takes a `Vec` of its outputs in key order, and a `gather` after a
//! gather takes its output. Step names, datasets and settings are checked
//! by [`Pipeline::build`], which a binary calls before any command.
//!
//! Across builds, an edge is checked at run time: a step's output is kept
//! as `{"type": <Rust type name>, "value": <JSON>}`, and a resume decodes
//! the outputs an earlier build stored only into the same type name.

use std::any::type_name;
use std::marker::PhantomData;
use std::sync::Arc;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::ctx::Ctx;
use crate::partition::Partition;

/// A step's failure, from `?` on any error or from [`fail`], or a request
/// to try later, from [`defer`].
#[derive(Debug)]
pub enum StepError {
    /// The attempt failed with this message; the step's retries try again.
    Failed(String),
    /// The step can't do its work yet: the attempt ends `deferred` and the
    /// run starts again in `seconds`, spending no retries.
    Defer { seconds: u64, why: String },
}

impl<E: std::fmt::Display> From<E> for StepError {
    fn from(e: E) -> Self {
        StepError::Failed(e.to_string())
    }
}

impl StepError {
    pub(crate) fn message(&self) -> String {
        match self {
            StepError::Failed(m) => m.clone(),
            StepError::Defer { seconds, why } => format!("defer {seconds}: {why}"),
        }
    }
}

/// What a step returns.
pub type StepResult<T> = Result<T, StepError>;

/// Fails the attempt with `msg`.
pub fn fail(msg: impl Into<String>) -> StepError {
    StepError::Failed(msg.into())
}

/// Ends the attempt `deferred`: the run starts again in `seconds` (at least
/// 1), and neither the step's retries nor the run's are spent.
pub fn defer(seconds: u64, why: impl Into<String>) -> StepError {
    StepError::Defer {
        seconds: seconds.max(1),
        why: why.into(),
    }
}

/// A step's name and settings. A `&str` converts to one with the defaults.
#[derive(Clone, Debug, Default)]
pub struct StepSpec {
    pub(crate) name: String,
    pub(crate) retries: u32,
    pub(crate) backoff_seconds: u64,
    pub(crate) timeout_seconds: u64,
    pub(crate) version: u64,
    pub(crate) reads: Vec<String>,
    pub(crate) writes: Vec<String>,
}

/// A step named `name`, to set more on.
pub fn step(name: &str) -> StepSpec {
    StepSpec {
        name: name.to_string(),
        ..Default::default()
    }
}

impl From<&str> for StepSpec {
    fn from(name: &str) -> Self {
        step(name)
    }
}

impl StepSpec {
    /// Tries again up to `n` times in the same run when an attempt fails.
    pub fn retries(mut self, n: u32) -> Self {
        self.retries = n;
        self
    }
    /// Waits this long before the first retry, doubling each time.
    pub fn backoff_seconds(mut self, s: u64) -> Self {
        self.backoff_seconds = s;
        self
    }
    /// Stops the process if an attempt is still running after `s` seconds
    /// (the heartbeat's watchdog), failing the attempt and the run.
    pub fn timeout_seconds(mut self, s: u64) -> Self {
        self.timeout_seconds = s;
        self
    }
    /// The step's data version: a new one makes keys done at another
    /// version not done for a fill.
    pub fn version(mut self, v: u64) -> Self {
        self.version = v;
        self
    }
    /// The warehouse datasets (`ns.table`) the step reads.
    pub fn reads<I: IntoIterator<Item = S>, S: Into<String>>(mut self, ds: I) -> Self {
        self.reads = ds.into_iter().map(Into::into).collect();
        self
    }
    /// The warehouse datasets (`ns.table`) the step commits to.
    pub fn writes<I: IntoIterator<Item = S>, S: Into<String>>(mut self, ds: I) -> Self {
        self.writes = ds.into_iter().map(Into::into).collect();
        self
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
    Mapped,
    Gather,
}

impl Kind {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Kind::Mapped => "mapped",
            Kind::Gather => "gather",
        }
    }
}

type RunFn = dyn Fn(&mut Ctx, &[u8]) -> StepResult<Vec<u8>> + Send + Sync;

pub(crate) struct StepDef {
    pub(crate) spec: StepSpec,
    pub(crate) kind: Kind,
    pub(crate) after: Option<String>,
    pub(crate) function: String,
    pub(crate) input: String,
    pub(crate) output: String,
    pub(crate) run: Arc<RunFn>,
}

/// A value as a step's output or input row keeps it.
pub(crate) fn encode<T: Serialize>(v: &T) -> Result<Vec<u8>, String> {
    serde_json::to_vec(&json!({"type": type_name::<T>(), "value": v}))
        .map_err(|e| format!("morca: can't encode a {}: {e}", type_name::<T>()))
}

/// The `value` of an encoded `type`; an error if it was encoded as another.
pub(crate) fn decode_value(bytes: &[u8], want: &str) -> Result<Value, String> {
    let v: Value = serde_json::from_slice(bytes)
        .map_err(|e| format!("morca: a stored value isn't morca-sdk's encoding: {e}"))?;
    let got = v.get("type").and_then(Value::as_str).unwrap_or("");
    if got != want {
        return Err(format!(
            "morca: a stored value is a {}, the step takes a {want}",
            if got.is_empty() {
                "value of another encoding"
            } else {
                got
            }
        ));
    }
    Ok(v.get("value").cloned().unwrap_or(Value::Null))
}

fn decode<T: DeserializeOwned>(bytes: &[u8]) -> StepResult<T> {
    let v = decode_value(bytes, type_name::<T>()).map_err(StepError::Failed)?;
    serde_json::from_value(v)
        .map_err(|e| fail(format!("morca: can't decode a {}: {e}", type_name::<T>())))
}

fn wrap<A, R, F>(f: F) -> Arc<RunFn>
where
    A: DeserializeOwned + 'static,
    R: Serialize + 'static,
    F: Fn(&mut Ctx, A) -> StepResult<R> + Send + Sync + 'static,
{
    Arc::new(move |ctx: &mut Ctx, input: &[u8]| {
        let a: A = decode(input)?;
        let r = f(ctx, a)?;
        encode(&r).map_err(StepError::Failed)
    })
}

/// A cron schedule: five fields, in a zone (UTC unless set).
#[derive(Clone, Debug)]
pub struct Cron {
    pub(crate) expr: String,
    pub(crate) tz: String,
    pub(crate) fire: String,
    pub(crate) catchup: bool,
}

impl Cron {
    /// Fires at `expr` (`minute hour day month weekday`), in UTC, each fire
    /// running the partition before it, catching up on missed fires.
    pub fn new(expr: &str) -> Self {
        Cron {
            expr: expr.to_string(),
            tz: "UTC".into(),
            fire: "previous".into(),
            catchup: true,
        }
    }
    /// The IANA zone the expression is in.
    pub fn tz(mut self, tz: &str) -> Self {
        self.tz = tz.to_string();
        self
    }
    /// Each fire runs the partition it's in, not the one before.
    pub fn fire_current(mut self) -> Self {
        self.fire = "current".into();
        self
    }
    /// `fire_current`'s old name (#370).
    #[deprecated(note = "use `fire_current`")]
    pub fn fills_current(self) -> Self {
        self.fire_current()
    }
    /// Missed fires are skipped instead of run late.
    pub fn no_catchup(mut self) -> Self {
        self.catchup = false;
        self
    }
}

/// describe's `source`: the repository and commit a binary was built from.
#[derive(Clone, Debug, Default)]
pub struct Source {
    pub repo: String,
    pub commit: String,
    pub dirty: bool,
}

/// The source from `MORCA_SOURCE`, `MORCA_COMMIT` and `MORCA_DIRTY` in the
/// build's environment (`cargo build`), as `mojo build -D` sets them for a
/// Mojo pipeline.
#[macro_export]
macro_rules! source_from_build_env {
    () => {
        $crate::Source {
            repo: option_env!("MORCA_SOURCE").unwrap_or("").to_string(),
            commit: option_env!("MORCA_COMMIT").unwrap_or("").to_string(),
            dirty: matches!(option_env!("MORCA_DIRTY"), Some("1") | Some("true")),
        }
    };
}

#[derive(Clone, Debug)]
pub(crate) struct Config {
    pub(crate) name: String,
    pub(crate) kind: &'static str,
    pub(crate) start: Option<String>,
    pub(crate) keys_dataset: Option<(String, String)>,
    pub(crate) schedule: Option<Cron>,
    pub(crate) max_runs: u32,
    pub(crate) run_retries: u32,
    pub(crate) retry_seconds: u64,
    pub(crate) max_retry_seconds: u64,
    pub(crate) sensor: bool,
    pub(crate) keys_per_run: u32,
    pub(crate) source: Source,
}

/// Typestate: no step yet.
pub struct Start;
/// Typestate: the last step is mapped.
pub struct AfterMapped;
/// Typestate: the last step is a gather.
pub struct AfterGather;

/// A pipeline being defined, over keys `K`, whose last step makes `Out`.
pub struct Pipeline<K: Partition, Out = K, S = Start> {
    cfg: Config,
    steps: Vec<StepDef>,
    key_check: fn(&str) -> Result<String, String>,
    _p: Marker<K, Out, S>,
}

type Marker<K, Out, S> = PhantomData<fn() -> (K, Out, S)>;

fn key_check<K: Partition>(s: &str) -> Result<String, String> {
    K::parse(s).map(|k| k.to_string())
}

fn key_input<K: Partition>(s: &str) -> Result<Vec<u8>, String> {
    encode(&K::parse(s)?)
}

fn keys_input<K: Partition>(keys: &[String]) -> Result<Vec<u8>, String> {
    let ks: Result<Vec<K>, String> = keys.iter().map(|k| K::parse(k)).collect();
    encode(&ks?)
}

impl<K: Partition> Pipeline<K, K, Start> {
    /// A pipeline named `name` over keys of type `K`.
    pub fn new(name: &str) -> Self {
        Pipeline {
            cfg: Config {
                name: name.to_string(),
                kind: K::KIND,
                start: None,
                keys_dataset: None,
                schedule: None,
                max_runs: 1,
                run_retries: 3,
                retry_seconds: 0,
                max_retry_seconds: 0,
                sensor: false,
                keys_per_run: 1,
                source: Source::default(),
            },
            steps: vec![],
            key_check: key_check::<K>,
            _p: PhantomData,
        }
    }

    /// The first step, once per key: takes the key.
    pub fn mapped<U, F>(self, spec: impl Into<StepSpec>, f: F) -> Pipeline<K, U, AfterMapped>
    where
        U: Serialize + DeserializeOwned + 'static,
        F: Fn(&mut Ctx, K) -> StepResult<U> + Send + Sync + 'static,
    {
        self.push::<K, U, F, AfterMapped>(spec.into(), Kind::Mapped, f)
    }

    /// The first step, once per run: takes the run's keys.
    pub fn gather<U, F>(self, spec: impl Into<StepSpec>, f: F) -> Pipeline<K, U, AfterGather>
    where
        U: Serialize + DeserializeOwned + 'static,
        F: Fn(&mut Ctx, Vec<K>) -> StepResult<U> + Send + Sync + 'static,
    {
        self.push::<Vec<K>, U, F, AfterGather>(spec.into(), Kind::Gather, f)
    }
}

impl<K: Partition, Out: Serialize + DeserializeOwned + 'static> Pipeline<K, Out, AfterMapped> {
    /// A step once per key, after a mapped step: takes its output.
    pub fn mapped<U, F>(self, spec: impl Into<StepSpec>, f: F) -> Pipeline<K, U, AfterMapped>
    where
        U: Serialize + DeserializeOwned + 'static,
        F: Fn(&mut Ctx, Out) -> StepResult<U> + Send + Sync + 'static,
    {
        self.push::<Out, U, F, AfterMapped>(spec.into(), Kind::Mapped, f)
    }

    /// A step once per run, after a mapped step: takes its outputs, in key
    /// order.
    pub fn gather<U, F>(self, spec: impl Into<StepSpec>, f: F) -> Pipeline<K, U, AfterGather>
    where
        U: Serialize + DeserializeOwned + 'static,
        F: Fn(&mut Ctx, Vec<Out>) -> StepResult<U> + Send + Sync + 'static,
    {
        self.push::<Vec<Out>, U, F, AfterGather>(spec.into(), Kind::Gather, f)
    }
}

impl<K: Partition, Out: Serialize + DeserializeOwned + 'static> Pipeline<K, Out, AfterGather> {
    /// A step once per run, after a gather: takes its output. (A mapped
    /// step can't follow a gather.)
    pub fn gather<U, F>(self, spec: impl Into<StepSpec>, f: F) -> Pipeline<K, U, AfterGather>
    where
        U: Serialize + DeserializeOwned + 'static,
        F: Fn(&mut Ctx, Out) -> StepResult<U> + Send + Sync + 'static,
    {
        self.push::<Out, U, F, AfterGather>(spec.into(), Kind::Gather, f)
    }
}

impl<K: Partition, Out, S> Pipeline<K, Out, S> {
    fn push<A, U, F, S2>(self, spec: StepSpec, kind: Kind, f: F) -> Pipeline<K, U, S2>
    where
        A: DeserializeOwned + 'static,
        U: Serialize + DeserializeOwned + 'static,
        F: Fn(&mut Ctx, A) -> StepResult<U> + Send + Sync + 'static,
    {
        let mut steps = self.steps;
        let after = steps.last().map(|s| s.spec.name.clone());
        steps.push(StepDef {
            spec,
            kind,
            after,
            function: type_name::<F>().to_string(),
            input: type_name::<A>().to_string(),
            output: type_name::<U>().to_string(),
            run: wrap::<A, U, F>(f),
        });
        Pipeline {
            cfg: self.cfg,
            steps,
            key_check: self.key_check,
            _p: PhantomData,
        }
    }

    /// The first key a fill covers, such as `2024-01`.
    pub fn start(mut self, key: &str) -> Self {
        self.cfg.start = Some(key.to_string());
        self
    }
    /// Runs on a cron schedule.
    pub fn schedule(mut self, cron: Cron) -> Self {
        self.cfg.schedule = Some(cron);
        self
    }
    /// At most this many runs at once (default 1).
    pub fn max_runs(mut self, n: u32) -> Self {
        self.cfg.max_runs = n;
        self
    }
    /// Starts of a run after a failure (default 3).
    pub fn run_retries(mut self, n: u32) -> Self {
        self.cfg.run_retries = n;
        self
    }
    /// The backoff between a run's retries, doubling up to `max` seconds.
    pub fn retry_seconds(mut self, first: u64, max: u64) -> Self {
        self.cfg.retry_seconds = first;
        self.cfg.max_retry_seconds = max;
        self
    }
    /// A sensor: the scheduler runs it when a dataset it reads, and no step
    /// writes, gets a snapshot another program committed.
    pub fn sensor(mut self) -> Self {
        self.cfg.sensor = true;
        self
    }
    /// How many keys a queued run covers (default 1).
    pub fn keys_per_run(mut self, n: u32) -> Self {
        self.cfg.keys_per_run = n;
        self
    }
    /// A keyed pipeline's keys: the distinct values of `column` in the
    /// warehouse dataset `dataset`.
    pub fn keys_from(mut self, dataset: &str, column: &str) -> Self {
        self.cfg.keys_dataset = Some((dataset.to_string(), column.to_string()));
        self
    }
    /// describe's `source` (see [`source_from_build_env!`]).
    pub fn source(mut self, source: Source) -> Self {
        self.cfg.source = source;
        self
    }

    /// Checks the definition and makes the pipeline a binary runs.
    pub fn build(self) -> Result<Built, String>
    where
        K: Partition,
    {
        let built = Built {
            cfg: self.cfg,
            steps: self.steps,
            key_check: self.key_check,
            key_input: key_input::<K>,
            keys_input: keys_input::<K>,
        };
        built.check()?;
        Ok(built)
    }
}

/// A pipeline, defined and checked: hand it to [`crate::main`].
pub struct Built {
    pub(crate) cfg: Config,
    pub(crate) steps: Vec<StepDef>,
    pub(crate) key_check: fn(&str) -> Result<String, String>,
    pub(crate) key_input: fn(&str) -> Result<Vec<u8>, String>,
    pub(crate) keys_input: fn(&[String]) -> Result<Vec<u8>, String>,
}

fn plain_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// `namespace.table`: a dot with a name either side, and nothing that would
/// leave the warehouse.
pub(crate) fn is_dataset(name: &str) -> bool {
    match name.rfind('.') {
        Some(dot) => {
            dot > 0
                && dot < name.len() - 1
                && !name.contains('/')
                && !name.contains("..")
                && !name.contains(char::is_whitespace)
        }
        None => false,
    }
}

impl Built {
    fn check(&self) -> Result<(), String> {
        let c = &self.cfg;
        let bad = |m: String| Err(format!("morca: pipeline {}: {m}", c.name));
        if !plain_name(&c.name) {
            return bad("a pipeline's name is 1 to 64 of A-Z a-z 0-9 _ -".into());
        }
        if self.steps.is_empty() {
            return bad("it has no steps".into());
        }
        let mut names: Vec<&str> = vec![];
        for s in &self.steps {
            let n = s.spec.name.as_str();
            if !plain_name(n) {
                return bad(format!(
                    "step '{n}': a step's name is 1 to 64 of A-Z a-z 0-9 _ -"
                ));
            }
            if names.contains(&n) {
                return bad(format!("two steps are named {n}"));
            }
            names.push(n);
            for d in s.spec.reads.iter().chain(&s.spec.writes) {
                if !is_dataset(d) {
                    return bad(format!("step {n}: '{d}' isn't a dataset (namespace.table)"));
                }
            }
            if s.spec.writes.iter().any(|d| s.spec.reads.contains(d)) {
                return bad(format!("step {n} reads a dataset it writes"));
            }
            if !cfg!(feature = "tables") && !(s.spec.reads.is_empty() && s.spec.writes.is_empty()) {
                return bad(format!(
                    "step {n} declares datasets: build morca-sdk with the `tables` feature"
                ));
            }
        }
        if let Some(k) = &c.start {
            (self.key_check)(k).map_err(|e| format!("morca: pipeline {}: start: {e}", c.name))?;
            if c.kind == "keyed" {
                return bad("a keyed pipeline has no start".into());
            }
        }
        match (&c.keys_dataset, c.kind == "keyed") {
            (None, true) => return bad("a keyed pipeline needs keys_from(dataset, column)".into()),
            (Some(_), false) => {
                return bad("keys_from is for a keyed pipeline (keys of Name)".into());
            }
            (Some((d, col)), true) => {
                if !is_dataset(d) || col.is_empty() {
                    return bad(format!("keys_from({d}, {col}): not a dataset and a column"));
                }
                if !cfg!(feature = "tables") {
                    return bad("a keyed pipeline needs the `tables` feature".into());
                }
            }
            _ => {}
        }
        if let Some(s) = &c.schedule
            && s.expr.split_whitespace().count() != 5
        {
            return bad(format!(
                "schedule '{}': a cron expression has five fields",
                s.expr
            ));
        }
        if c.sensor && self.sensed().is_empty() {
            return bad("a sensor reads a dataset no step writes".into());
        }
        if c.max_runs < 1 || c.keys_per_run < 1 {
            return bad("max_runs and keys_per_run are at least 1".into());
        }
        Ok(())
    }

    pub(crate) fn name(&self) -> &str {
        &self.cfg.name
    }

    /// Each dataset a step reads and no step writes, once, in step order,
    /// then a keyed pipeline's keys dataset.
    pub(crate) fn sensed(&self) -> Vec<String> {
        let written: Vec<&String> = self.steps.iter().flat_map(|s| &s.spec.writes).collect();
        let mut out: Vec<String> = vec![];
        for s in &self.steps {
            for d in &s.spec.reads {
                if !written.contains(&d) && !out.contains(d) {
                    out.push(d.clone());
                }
            }
        }
        if let Some((d, _)) = &self.cfg.keys_dataset
            && !out.contains(d)
        {
            out.push(d.clone());
        }
        out
    }

    /// The registry hash: FNV-1a (64 bits) over the pipeline's name, its
    /// steps' names, kinds, edges, functions, datasets and versions, and its
    /// partitions, as the Mojo binary's text (src/morca/pipeline.mojo),
    /// printed `0x` and lower-case hex.
    pub fn registry_hash(&self) -> String {
        let mut all = format!("{}\n", self.cfg.name);
        for s in &self.steps {
            all.push_str(&format!(
                "{}\t{}\t{}\t{}",
                s.spec.name,
                s.kind.as_str(),
                s.after.as_deref().unwrap_or(""),
                s.function
            ));
            for d in &s.spec.reads {
                all.push_str(&format!("\treads {d}"));
            }
            for d in &s.spec.writes {
                all.push_str(&format!("\twrites {d}"));
            }
            if s.spec.version > 0 {
                all.push_str(&format!("\tversion {}", s.spec.version));
            }
            all.push('\n');
        }
        all.push_str(&format!("partitions\t{}\n", self.cfg.kind));
        if let Some((d, c)) = &self.cfg.keys_dataset {
            all.push_str(&format!("keys\t{d}\t{c}\n"));
        }
        format!("0x{:x}", fnv1a64(all.as_bytes()))
    }

    /// `step=seconds` for each step with a timeout, comma-separated.
    pub(crate) fn timeouts(&self) -> String {
        self.steps
            .iter()
            .filter(|s| s.spec.timeout_seconds > 0)
            .map(|s| format!("{}={}", s.spec.name, s.spec.timeout_seconds))
            .collect::<Vec<_>>()
            .join(",")
    }

    /// The DAG as one line of JSON (docs/pipeline-protocol.md, "describe"):
    /// `pipeline` first, `protocol` 1, and no `morca` key, since the binary
    /// isn't built with morca-mojo.
    pub fn describe(&self) -> String {
        let c = &self.cfg;
        let mut parts = vec![("kind", J::v(c.kind)), ("start", J::v(&c.start))];
        if let Some((d, col)) = &c.keys_dataset {
            parts.push(("dataset", J::v(d)));
            parts.push(("column", J::v(col)));
        }
        let schedule = match &c.schedule {
            Some(s) => {
                // `fills` repeats `fire` for one release, for older
                // schedulers (#370).
                J::V(
                    json!({"cron": s.expr, "tz": s.tz, "fire": s.fire, "fills": s.fire,
                            "catchup": s.catchup}),
                )
            }
            None => J::V(Value::Null),
        };
        let steps: Vec<J> = self
            .steps
            .iter()
            .map(|s| {
                let mut o = vec![
                    ("name", J::v(&s.spec.name)),
                    ("kind", J::v(s.kind.as_str())),
                    ("after", J::v(&s.after)),
                    ("function", J::v(&s.function)),
                    ("input", J::v(&s.input)),
                    ("output", J::v(&s.output)),
                ];
                if s.spec.timeout_seconds > 0 {
                    o.push(("timeout_seconds", J::v(s.spec.timeout_seconds)));
                }
                if s.spec.version > 0 {
                    o.push(("version", J::v(s.spec.version)));
                }
                o.push(("reads", J::v(&s.spec.reads)));
                o.push(("writes", J::v(&s.spec.writes)));
                J::Obj(o)
            })
            .collect();
        let mut top = vec![
            ("pipeline", J::v(&c.name)),
            ("registry_hash", J::v(self.registry_hash())),
            ("partitions", J::Obj(parts)),
            ("schedule", schedule),
            ("max_runs", J::v(c.max_runs)),
            ("run_retries", J::v(c.run_retries)),
        ];
        if c.retry_seconds > 0 {
            top.push(("retry_seconds", J::v(c.retry_seconds)));
        }
        if c.max_retry_seconds > 0 {
            top.push(("max_retry_seconds", J::v(c.max_retry_seconds)));
        }
        top.extend([
            ("sensor", J::v(c.sensor)),
            ("keys_per_run", J::v(c.keys_per_run)),
            ("workers", J::v(2)),
            ("steps", J::Arr(steps)),
            ("tasks", J::V(json!([]))),
            (
                "source",
                J::V(json!({"repo": c.source.repo, "commit": c.source.commit, "dirty": c.source.dirty})),
            ),
            ("protocol", J::v(crate::PROTOCOL_VERSION)),
        ]);
        J::Obj(top).text()
    }
}

/// JSON whose objects keep their keys in order, so describe starts with
/// `pipeline` (serde_json's own map sorts its keys).
enum J {
    V(Value),
    Obj(Vec<(&'static str, J)>),
    Arr(Vec<J>),
}

impl J {
    fn v<T: Serialize>(x: T) -> J {
        J::V(serde_json::to_value(x).unwrap_or(Value::Null))
    }
    fn text(&self) -> String {
        match self {
            J::V(v) => v.to_string(),
            J::Arr(a) => format!("[{}]", a.iter().map(J::text).collect::<Vec<_>>().join(",")),
            J::Obj(o) => format!(
                "{{{}}}",
                o.iter()
                    .map(|(k, v)| format!("{}:{}", Value::String(k.to_string()), v.text()))
                    .collect::<Vec<_>>()
                    .join(",")
            ),
        }
    }
}

/// The 64-bit FNV-1a hash.
pub(crate) fn fnv1a64(b: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &x in b {
        h ^= x as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::partition::Month;

    fn days(_: &mut Ctx, m: Month) -> StepResult<u32> {
        Ok(m.days())
    }
    fn total(_: &mut Ctx, ds: Vec<u32>) -> StepResult<u64> {
        Ok(ds.iter().map(|d| *d as u64).sum())
    }

    fn toy() -> Pipeline<Month, u64, AfterGather> {
        Pipeline::<Month>::new("t")
            .start("2024-01")
            .mapped("days", days)
            .gather(step("total").timeout_seconds(5), total)
    }

    #[test]
    fn describe_and_hash() {
        let p = toy().build().unwrap();
        let d: Value = serde_json::from_str(&p.describe()).unwrap();
        assert!(p.describe().starts_with("{\"pipeline\":\"t\","));
        assert_eq!(d["protocol"], 1);
        assert!(d.get("morca").is_none());
        assert_eq!(d["steps"][1]["after"], "days");
        assert_eq!(d["steps"][1]["timeout_seconds"], 5);
        assert_eq!(d["registry_hash"], p.registry_hash());
        assert_eq!(p.registry_hash(), toy().build().unwrap().registry_hash());
        assert_eq!(p.timeouts(), "total=5");
        // Another DAG, another hash.
        let q = Pipeline::<Month>::new("t")
            .mapped("days", days)
            .build()
            .unwrap();
        assert_ne!(p.registry_hash(), q.registry_hash());
    }

    #[test]
    fn checked_when_built() {
        let dup = Pipeline::<Month>::new("t")
            .mapped("a", days)
            .gather("a", total)
            .build();
        assert!(dup.err().unwrap().contains("two steps are named a"));
        let bad = Pipeline::<Month>::new("t")
            .start("2024-13")
            .mapped("a", days)
            .build();
        assert!(bad.is_err());
        let sensor = Pipeline::<Month>::new("t")
            .sensor()
            .mapped("a", days)
            .build();
        assert!(sensor.is_err());
        let empty = Pipeline::<Month>::new("t").build();
        assert!(empty.is_err());
    }

    #[test]
    fn edges_checked_at_run_time() {
        let out = encode(&7u32).unwrap();
        assert!(decode_value(&out, type_name::<u32>()).is_ok());
        let e = decode_value(&out, type_name::<String>()).unwrap_err();
        assert!(e.contains("is a u32"), "{e}");
    }
}
