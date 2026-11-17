//! The pipeline binary's command line (docs/pipeline-protocol.md,
//! "Subcommands"): what `default` (local) and `control` placement need.
//!
//! Exit codes: 0 done (for `resume`, the run succeeded); 1 the run failed,
//! deferred or was cancelled, or the heartbeat stopped the process; 2 a
//! usage error; 3 any other error.

use crate::exec;
use crate::heartbeat::{self, Heartbeat};
use crate::logs;
use crate::pipeline::Built;
use crate::store::{self, CANCELLED, DEFERRED, DbError, Owned, SUCCEEDED};

const USAGE: &str = "usage: <pipeline> describe
       <pipeline> resume <run> [--allow-new-code]
       <pipeline> sense            (a sensor)
       <pipeline> keys             (a keyed pipeline)
       <pipeline> keep-log <stage> <location> <start>
       <pipeline> put-log <local> <location>
       <pipeline> sample ...       (runs `morca sample`)
A morca-sdk pipeline binary: the morca scheduler runs it (docs/rust-pipelines.md).";

fn usage() -> i32 {
    eprintln!("{USAGE}");
    2
}

fn env(k: &str) -> String {
    std::env::var(k).unwrap_or_default()
}

pub(crate) fn run(p: &Built, args: &[String]) -> i32 {
    let cmd = args.get(1).map(String::as_str).unwrap_or("");
    if cmd == "sample" {
        return sample(&args[2..]);
    }
    let url = env("MORCA_DATABASE_URL");
    let state_url = env("MORCA_STATE_URL");
    if !url.is_empty() && !state_url.is_empty() {
        eprintln!("morca: set MORCA_DATABASE_URL or MORCA_STATE_URL, not both");
        return 2;
    }
    match (cmd, args.len()) {
        ("describe", 2) => {
            println!("{}", p.describe());
            0
        }
        ("resume", 3) | ("resume", 4) => {
            let allow = match args.get(3).map(String::as_str) {
                None => false,
                Some("--allow-new-code") => true,
                Some(_) => return usage(),
            };
            let Ok(run) = args[2].parse::<i64>() else {
                eprintln!("morca: not a run: {}", args[2]);
                return 2;
            };
            if !state_url.is_empty() {
                eprintln!(
                    "morca: MORCA_STATE_URL (a worker's run) isn't supported by morca-sdk yet; \
                     use default or control placement"
                );
                return 2;
            }
            if url.is_empty() {
                eprintln!("morca: resume needs MORCA_DATABASE_URL");
                return 2;
            }
            resume(p, &url, run, allow)
        }
        ("sense", 2) => crate::tables::sense(p),
        ("keys", 2) => {
            if p.cfg.kind != "keyed" {
                eprintln!("morca: {} isn't keyed", p.name());
                return 2;
            }
            crate::tables::keys(p)
        }
        ("keep-log", 5) => keep_log(&url, &args[2], &args[3], &args[4]),
        ("put-log", 4) => match logs::put_log(&args[2], &args[3]) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("morca: put-log: {e}");
                3
            }
        },
        _ => usage(),
    }
}

/// `sample` is `morca sample`'s: the runner starts it beside each run, and
/// only logs it when it can't. Runs the `morca` on the path.
fn sample(args: &[String]) -> i32 {
    match std::process::Command::new("morca")
        .arg("sample")
        .args(args)
        .status()
    {
        Ok(s) => s.code().unwrap_or(1),
        Err(e) => {
            eprintln!("morca: sample runs `morca sample`, and there's no morca on the path: {e}");
            2
        }
    }
}

fn keep_log(url: &str, stage: &str, location: &str, start: &str) -> i32 {
    let text = match logs::keep_log(stage, location, start) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("morca: keep-log: {e}");
            return 3;
        }
    };
    // A driver that crashed left its attempts running: they fail with the
    // crash's first frames while the run is running. Exits 0 even when it
    // can't record that.
    let run = env("MORCA_RUN");
    if let (Some(why), Ok(run), false) = (
        logs::crash_summary(&text),
        run.parse::<i64>(),
        url.is_empty(),
    ) {
        let r = store::open(url).and_then(|mut s| {
            match s.run_info(run)? {
                Some(i) if i.status == store::RUNNING => {
                    let n = s.interrupt(run, &why)?;
                    println!("run {run} crashed, {n} attempts failed: {why}");
                }
                _ => {}
            }
            Ok(())
        });
        if let Err(e) = r {
            println!("morca: can't record run {run} crashing: {e}");
        }
    }
    0
}

fn resume(p: &Built, url: &str, run: i64, allow_new_code: bool) -> i32 {
    match resume_inner(p, url, run, allow_new_code) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("{}", e.to_string().trim_start_matches('\x1f'));
            3
        }
    }
}

fn resume_inner(p: &Built, url: &str, run: i64, allow_new_code: bool) -> Result<i32, DbError> {
    let mut s = store::open(url)?;
    s.migrate()?;
    let hash = p.registry_hash();
    let Some(info) = s.run_info(run)? else {
        return Err(DbError::Final(format!("morca: no run {run}")));
    };
    if info.pipeline != p.name() {
        return Err(DbError::Final(format!(
            "morca: run {run} is pipeline {}'s, not {}'s",
            info.pipeline,
            p.name()
        )));
    }
    if info.registry_hash != hash && !allow_new_code {
        return Err(DbError::Final(format!(
            "morca: run {run} ran code {}, this binary is {hash}: resume it with \
             --allow-new-code to run it with this code",
            info.registry_hash
        )));
    }
    let mut keys = vec![];
    for k in info.partitions.split(',').filter(|k| !k.is_empty()) {
        match (p.key_check)(k) {
            Ok(k) => keys.push(k),
            Err(e) => {
                eprintln!("morca: run {run}: {e}");
                return Ok(2);
            }
        }
    }
    let owner = store::process_owner();
    let stale = store::stale_seconds();
    if !s.claim(run, &owner, stale)? {
        let i = s.run_info(run)?.unwrap_or(info);
        if !["running", "failed", "queued", "deferred"].contains(&i.status.as_str()) {
            return Err(DbError::Final(format!("morca: run {run} is {}", i.status)));
        }
        return Err(DbError::Final(format!(
            "morca: run {run} is held by {}, whose heartbeat is fresher than {stale} s",
            i.owner
        )));
    }
    let image = env("MORCA_IMAGE");
    let v = s.version(p.name(), &hash, &p.describe(), &image)?;
    s.ran_version(run, v)?;
    let interrupted = s.interrupt(run, "")?;
    let prior = s.prior(run)?;
    println!(
        "resuming run {run} with {} steps done and {interrupted} interrupted",
        prior.len()
    );
    let beater = s.beater(run, &owner, &p.timeouts());
    let mut owned = Owned {
        store: s,
        run,
        owner,
        hash,
        attempt_id: 0,
    };
    let mut hb = Heartbeat::start(beater, run, heartbeat::interval(stale));
    let res = exec::execute(p, &mut owned, &keys, prior);
    hb.stop();
    let res = match res {
        Ok(r) => r,
        Err(e) => {
            // A cancel stops the run before its next attempt.
            if owned.cancel_requested().unwrap_or(false) {
                owned.finish_run(CANCELLED)?;
                println!("run {CANCELLED}");
                return Ok(1);
            }
            return Err(e);
        }
    };
    let outcome = res.outcome();
    if outcome == DEFERRED {
        owned.defer_run(res.deferred_until())?;
    } else {
        owned.finish_run(outcome)?;
    }
    for (step, part) in &res.order {
        let d = &res.by[&(step.clone(), part.clone())];
        let at = if part.is_empty() {
            String::new()
        } else {
            format!(" {part}")
        };
        let err = if d.error.is_empty() {
            String::new()
        } else {
            format!(": {}", d.error)
        };
        println!("{step}{at} {}{err}", d.status);
    }
    if outcome == DEFERRED {
        println!("run deferred until {}Z", logs::civil(res.deferred_until()));
    } else {
        println!("run {outcome}");
    }
    Ok(if outcome == SUCCEEDED { 0 } else { 1 })
}
