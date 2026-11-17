//! The heartbeat (docs/pipeline-protocol.md, "Heartbeat"): while a run's
//! steps run, a thread of its own, on a connection of its own, refreshes the
//! run's heartbeat every `MORCA_STALE_SECONDS / 5`, runs the watchdog (a
//! step past its `timeout_seconds`, a cancel whose `cancel_at` has passed)
//! and asks whether the run is outdated. A failed beat drops the connection
//! and tries again on the next one.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// One beat on the heartbeat's connection.
pub(crate) trait Beater: Send {
    /// Refreshes the heartbeat and runs the watchdog: why the process must
    /// stop now, already recorded, or None.
    fn beat(&mut self) -> Result<Option<String>, String>;
    /// Drops the connection, for the next beat to open another.
    fn reset(&mut self);
}

/// Whether the run is outdated, and why: the stop flag steps read.
#[derive(Default)]
pub(crate) struct Outdated {
    pub flag: AtomicBool,
    pub why: Mutex<String>,
}

pub(crate) fn outdated() -> &'static Outdated {
    static O: OnceLock<Outdated> = OnceLock::new();
    O.get_or_init(Outdated::default)
}

pub(crate) fn set_outdated(o: bool, why: String) {
    let st = outdated();
    st.flag.store(o, Ordering::SeqCst);
    if let Ok(mut w) = st.why.lock() {
        *w = why;
    }
}

/// Ends the process at once, as the Mojo binary's `_exit(1)`: no
/// destructors, no other thread finishing what it was doing.
pub(crate) fn exit_now(code: i32) -> ! {
    unsafe extern "C" {
        fn _exit(code: std::ffi::c_int) -> !;
    }
    use std::io::Write;
    let _ = std::io::stdout().flush();
    let _ = std::io::stderr().flush();
    unsafe { _exit(code) }
}

pub(crate) struct Heartbeat {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Heartbeat {
    pub fn start(mut beater: Box<dyn Beater>, run: i64, interval: f64) -> Heartbeat {
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        let every = Duration::from_secs_f64(interval.max(0.05));
        let thread = std::thread::Builder::new()
            .name("morca-heartbeat".into())
            .spawn(move || {
                let mut next = Instant::now();
                while !flag.load(Ordering::SeqCst) {
                    if Instant::now() >= next {
                        next = Instant::now() + every;
                        match beater.beat() {
                            Ok(Some(why)) => {
                                println!("run {run} {why}");
                                exit_now(1);
                            }
                            Ok(None) => {}
                            Err(e) => {
                                eprintln!("morca: heartbeat: {e}");
                                beater.reset();
                            }
                        }
                    }
                    std::thread::sleep(Duration::from_millis(20).min(every));
                }
            })
            .expect("morca: can't start the heartbeat thread");
        Heartbeat {
            stop,
            thread: Some(thread),
        }
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for Heartbeat {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The interval: five beats per stale limit.
pub(crate) fn interval(stale: f64) -> f64 {
    stale / 5.0
}

/// The watchdog's error for an attempt past its step's timeout.
pub(crate) fn timed_out_why(secs: f64) -> String {
    format!(
        "timed out after {} s (timeout_seconds), so its process was stopped",
        secs as i64
    )
}

pub(crate) const CANCEL_WHY: &str = "cancelled: its step hadn't finished when the cancel's \
MORCA_CANCEL_KILL_SECONDS ran out, so its process was stopped";
