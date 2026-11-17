//! Tables (docs/pipeline-protocol.md, "Tables"), with the `tables` feature:
//! the warehouse `MORCA_WAREHOUSE` as morca's filesystem catalog (dataset
//! `ns.table` at `<warehouse>/ns/table`, a local directory or
//! `s3://bucket/prefix` with the `AWS_*` variables), read and committed with
//! iceberg-rust 0.11.0 on arrow-rs 58.
//!
//! - A read scans the snapshot this attempt already read, else the one the
//!   step's first attempt read (pinned), else the current one, and is
//!   recorded in `orca.reads`.
//! - A commit is fenced, carries the `orca.*` summary keys, and is recorded
//!   in `orca.commits`; before writing anything, `find_commit` looks for the
//!   commit an earlier attempt of the run already made, and records that
//!   instead.
//! - To a dataset the step declares in `replaces`, the run's first commit
//!   to each partition is an `overwrite` that removes what earlier runs left
//!   there (`replace`): iceberg-rust 0.11.0 has no overwrite transaction, so
//!   that snapshot is written from its parts.
//!
//! Without the feature a pipeline declares no datasets, `sense` prints
//! nothing and `keys` can't be asked for.

#[cfg(feature = "tables")]
mod catalog;
#[cfg(feature = "tables")]
mod imp;
#[cfg(feature = "tables")]
mod replace;

#[cfg(feature = "tables")]
pub use imp::*;

#[cfg(not(feature = "tables"))]
pub(crate) fn sense(_p: &crate::pipeline::Built) -> i32 {
    0
}

#[cfg(not(feature = "tables"))]
pub(crate) fn keys(_p: &crate::pipeline::Built) -> i32 {
    eprintln!("morca: keys needs morca-sdk's `tables` feature");
    3
}
