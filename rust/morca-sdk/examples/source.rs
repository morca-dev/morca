//! Commits three rows to raw.events as a program that isn't a morca
//! pipeline would, its summary saying which partitions it holds only when
//! given some (the Rust twin of tests/sensors/source.mojo).
//!
//!     MORCA_WAREHOUSE=<dir> source <warehouse> [<partitions>]

use std::collections::HashMap;

use morca_sdk::tables::{append_as_other, id_name_rows, id_name_schema};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let Some(wh) = args.get(1) else {
        eprintln!("usage: source <warehouse> [<partitions>]");
        std::process::exit(2);
    };
    // SAFETY: single-threaded, before anything reads the environment.
    unsafe { std::env::set_var("MORCA_WAREHOUSE", wh) };
    let mut summary = HashMap::new();
    if let Some(p) = args.get(2) {
        summary.insert("orca.partitions".to_string(), p.clone());
    }
    let rows = id_name_rows("source", 3).unwrap_or_else(|e| panic!("{e}"));
    match append_as_other("raw.events", id_name_schema(), vec![rows], summary) {
        Ok(snap) => println!("{snap}"),
        Err(e) => {
            eprintln!("source: {e}");
            std::process::exit(1);
        }
    }
}
