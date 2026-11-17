//! Logs (docs/pipeline-protocol.md, "Logs" and "keep-log"): each attempt's
//! log at `<MORCA_LOGS>/<pipeline>/<run>/<step>/<partition or _run>/<attempt>.log`,
//! secrets masked, and what `keep-log` finds in a driver's output when it
//! crashed.
//!
//! Locations are on this machine: a directory or `file://`. A `MORCA_LOGS`
//! in object storage isn't supported yet; attempts then keep no log file.

use std::io::Write;
use std::path::Path;

use crate::partition::path_segment;

const MASK: &str = "***";

/// The values of the variables `MORCA_SECRETS` names; short ones are left
/// out, since masking them would hide ordinary text.
pub(crate) fn secret_values() -> Vec<String> {
    secret_names()
        .iter()
        .filter_map(|n| std::env::var(n).ok())
        .filter(|v| v.len() >= 4)
        .collect()
}

pub(crate) fn secret_names() -> Vec<String> {
    std::env::var("MORCA_SECRETS")
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// `text` with every secret's value replaced by `***`.
pub(crate) fn mask(text: &str) -> String {
    let mut out = text.to_string();
    for v in secret_values() {
        out = out.replace(&v, MASK);
    }
    out
}

pub(crate) fn is_remote(location: &str) -> bool {
    location.contains("://") && !location.starts_with("file://")
}

pub(crate) fn local_path(location: &str) -> &str {
    location.strip_prefix("file://").unwrap_or(location)
}

/// The run's directory under `MORCA_LOGS`, or None without it (or in
/// object storage, not supported yet).
pub(crate) fn run_dir(pipeline: &str, run: i64) -> Option<String> {
    let root = std::env::var("MORCA_LOGS").ok().filter(|s| !s.is_empty())?;
    if is_remote(&root) {
        eprintln!(
            "morca: MORCA_LOGS in object storage isn't supported by morca-sdk yet: no attempt logs"
        );
        return None;
    }
    Some(format!("{}/{pipeline}/{run}", root.trim_end_matches('/')))
}

/// Where the attempt's log goes, its directory made; None without
/// `MORCA_LOGS`.
pub(crate) fn attempt_log(
    pipeline: &str,
    run: i64,
    step: &str,
    partition: &str,
    attempt: i64,
) -> Option<String> {
    let dir = format!(
        "{}/{step}/{}",
        run_dir(pipeline, run)?,
        if partition.is_empty() {
            "_run".to_string()
        } else {
            path_segment(partition)
        }
    );
    if let Err(e) = std::fs::create_dir_all(local_path(&dir)) {
        eprintln!("morca: can't make {dir}: {e}");
        return None;
    }
    Some(format!("{dir}/{attempt}.log"))
}

/// Appends `line` to the file at `location`.
pub(crate) fn append_line(location: &str, line: &str) {
    let r = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(local_path(location))
        .and_then(|mut f| writeln!(f, "{line}"));
    if let Err(e) = r {
        eprintln!("morca: can't write {location}: {e}");
    }
}

/// Civil time of Unix seconds, `YYYY-MM-DDTHH:MM:SS`.
pub(crate) fn civil(secs: i64) -> String {
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    // Howard Hinnant's civil_from_days.
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

pub(crate) fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// The time now, to the second, as `YYYY-MM-DDTHH:MM:SSZ`.
pub(crate) fn utc_now() -> String {
    format!("{}Z", civil(unix_now()))
}

fn read_location(location: &str) -> std::io::Result<Vec<u8>> {
    if is_remote(location) {
        return Err(std::io::Error::other(format!(
            "{location}: object storage isn't supported by morca-sdk yet"
        )));
    }
    std::fs::read(local_path(location))
}

/// `keep-log`'s copy: appends `--- start <start>` and the stage file to
/// `location`, masked; returns the stage file's text.
pub(crate) fn keep_log(stage: &str, location: &str, start: &str) -> std::io::Result<String> {
    let data = read_location(stage)?;
    if is_remote(location) {
        return Err(std::io::Error::other(format!(
            "{location}: object storage isn't supported by morca-sdk yet"
        )));
    }
    let text = String::from_utf8_lossy(&data).into_owned();
    let path = local_path(location);
    if let Some(dir) = Path::new(path).parent()
        && !dir.as_os_str().is_empty()
    {
        std::fs::create_dir_all(dir)?;
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    write!(f, "--- start {start}\n{}", mask(&text))?;
    Ok(text)
}

/// `put-log`: copies a local file to `location`, replacing it.
pub(crate) fn put_log(local: &str, location: &str) -> std::io::Result<()> {
    let data = std::fs::read(local)?;
    if is_remote(location) {
        return Err(std::io::Error::other(format!(
            "{location}: object storage isn't supported by morca-sdk yet"
        )));
    }
    let path = local_path(location);
    let tmp = format!("{path}.tmp-{}", std::process::id());
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path)
}

const FRAMES: usize = 4;
const LIMIT: usize = 300;

fn clip(s: &str) -> String {
    if s.len() <= LIMIT {
        return s.to_string();
    }
    let mut n = LIMIT;
    while !s.is_char_boundary(n) {
        n -= 1;
    }
    format!("{}...", &s[..n])
}

/// `crashed: <message>; at <function> <file:line>, ...` for the last crash
/// in `output` after its last `--- start` line, or None: a Mojo stack dump
/// (src/morca/_internal/crash.mojo), which a Mojo pipeline's driver output
/// holds, or a Rust panic that ended the process (`panic = "abort"`, or a
/// panic outside a step).
pub(crate) fn crash_summary(output: &str) -> Option<String> {
    let lines: Vec<&str> = output.lines().collect();
    let mut first = 0;
    for (i, l) in lines.iter().enumerate() {
        if l.starts_with("--- start ") {
            first = i + 1;
        }
    }
    let mut dump: Option<(usize, bool)> = None;
    let mut panic: Option<usize> = None;
    for (i, l) in lines.iter().enumerate().skip(first) {
        let l = l.trim();
        if l.starts_with("#0 0x") {
            dump = Some((i, true));
        } else if l.starts_with("Stack dump without symbol names") {
            dump = Some((i, false));
        } else if l.starts_with("thread '") && l.contains("' panicked at ") {
            panic = Some(i);
        }
    }
    if let Some((at, symbols)) = dump
        && panic.is_none_or(|p| p < at)
    {
        let mut out = "crashed".to_string();
        if at > first {
            let said = lines[at - 1].trim();
            let cut = said
                .strip_prefix("ABORT: ")
                .or_else(|| said.strip_prefix("At: "));
            if let Some(c) = cut {
                out.push_str(&format!(": {}", clip(c)));
            }
        }
        if !symbols {
            out.push_str(
                "; its stack dump has no symbol names (no llvm-symbolizer: set LLVM_SYMBOLIZER_PATH)",
            );
            return Some(out);
        }
        let mut named = vec![];
        for l in &lines[at..] {
            let l = l.trim();
            if !l.starts_with('#') {
                break;
            }
            let parts: Vec<&str> = l.splitn(3, ' ').collect();
            if parts.len() < 3 {
                continue;
            }
            let rest = parts[2];
            let Some(sp) = rest.rfind(' ') else { continue };
            if rest.starts_with('(') {
                continue;
            }
            let at = &rest[sp + 1..];
            if at.ends_with(')') || at.starts_with("Mojo/stdlib/") {
                continue;
            }
            let mut end = sp;
            for c in ['[', '('] {
                if let Some(k) = rest.find(c)
                    && k > 0
                    && k < end
                {
                    end = k;
                }
            }
            named.push(format!("{} {at}", &rest[..end]));
            if named.len() == FRAMES {
                break;
            }
        }
        if named.is_empty() {
            out.push_str("; its stack dump has no line numbers (build with mojo build -g1)");
        } else {
            out.push_str(&format!("; at {}", named.join(", ")));
        }
        return Some(out);
    }
    let p = panic?;
    // `thread 'main' panicked at src/main.rs:9:5:` then the message.
    let head = lines[p].trim();
    let at = head
        .split("' panicked at ")
        .nth(1)
        .unwrap_or("")
        .trim_end_matches(':');
    let msg = lines.get(p + 1).map(|s| s.trim()).unwrap_or("");
    Some(format!("crashed: {}; at {at}", clip(msg)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mojo_dump() {
        let out = "--- start 1\nABORT: /p/c2.mojo:6:14: the input is bad\n #0 0x0000000102be67b8 (/x/lib/libKGEN.dylib+0xba7b8)\n #2 0x000000010286863c _abort_base Mojo/stdlib/std/os/os.mojo:242:31\n #4 0x000000010286863c main /p/c2.mojo:6:14\n";
        assert_eq!(
            crash_summary(out).unwrap(),
            "crashed: /p/c2.mojo:6:14: the input is bad; at main /p/c2.mojo:6:14"
        );
    }

    #[test]
    fn rust_panic() {
        let out =
            "thread 'main' panicked at src/main.rs:9:5:\nboom\nnote: run with RUST_BACKTRACE=1\n";
        assert_eq!(
            crash_summary(out).unwrap(),
            "crashed: boom; at src/main.rs:9:5"
        );
        assert!(crash_summary("all fine\n").is_none());
        assert!(
            crash_summary("thread 'main' panicked at x:1:1:\nboom\n--- start 2\nok\n").is_none()
        );
    }

    #[test]
    fn civil_time() {
        assert_eq!(civil(0), "1970-01-01T00:00:00");
        assert_eq!(civil(1709251200), "2024-03-01T00:00:00");
    }
}
