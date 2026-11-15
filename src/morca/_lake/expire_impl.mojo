"""Snapshot expiry inside liblake (#471): `lake_expire`'s work, over
iceberg's `Table.expire`. `morca_maintain expire` asks for it through the
library (`morca._internal.maintain`), so it compiles no iceberg; the
module doc there says what each option does.
"""

from std.time import perf_counter_ns

from iceberg.catalog.filesystem import Table
from iceberg.io import dirname
from iceberg.maintain import MAX_SNAPSHOT_AGE_MS, ExpirePolicy

from morca._lake.expire import ExpireAsk, Expiry
from morca._lake.impl import load_dataset
from morca._lake.names import table_defaults


def _metadata_files(table: Table) raises -> Int:
    var names = table.io.list_names(dirname(table.metadata_location))
    var n = 0
    for k in range(len(names)):
        if names[k].endswith(".metadata.json"):
            n += 1
    return n


def expire_dataset(ask: ExpireAsk) raises -> Expiry:
    """Expires `ask.dataset`'s snapshots: older than `ask.older_than_ms` ago
    (or by the table's properties when that is -1), keeping at least
    `ask.keep` (or the table's `history.expire.min-snapshots-to-keep`) and
    every snapshot in `ask.retain`. The metadata is committed first, then
    the files nothing retained points at are deleted."""
    var t0 = perf_counter_ns()
    var table = load_dataset(ask.dataset)
    var before = len(table.metadata.snapshots)
    var files_before = _metadata_files(table) if ask.report else -1
    if (
        ask.if_policy
        and ask.older_than_ms < 0
        and table.metadata.property_(MAX_SNAPSHOT_AGE_MS, "") == ""
    ):
        return Expiry.skip(
            ask.dataset,
            String("no ", MAX_SNAPSHOT_AGE_MS, " property"),
            before,
            files_before,
            len(table.metadata.metadata_log),
        )
    # The expiry's commit trims the metadata log like any other; with the
    # files that fall off it deleted only under delete-after-commit, a table
    # without morca's metadata defaults would leave them unreferenced for
    # good. So it gets them in the same commit.
    var defaults = table_defaults()
    for key in [
        String("write.metadata.delete-after-commit.enabled"),
        String("write.metadata.previous-versions-max"),
    ]:
        if key not in table.metadata.properties:
            table.metadata.properties[key] = defaults[key]
    var policy = ExpirePolicy.from_properties(table.metadata)
    if ask.older_than_ms >= 0:
        policy.older_than_ms = policy.now_ms - ask.older_than_ms
    if ask.keep >= 0:
        policy.keep_last = ask.keep
    for id in ask.retain:
        policy.retain.append(id)
    var r = table.expire(policy, ask.dry_run)
    if not ask.dry_run:
        table.refresh()
    return Expiry(
        ask.dataset,
        String(),
        r.dry_run,
        r.expired.copy(),
        r.removed_refs.copy(),
        len(r.deleted_files),
        len(r.deleted_manifests),
        len(r.deleted_statistics),
        r.manifest_lists_read,
        r.manifests_read,
        r.reachable,
        before,
        len(table.metadata.snapshots) if not ask.dry_run else before
        - len(r.expired),
        files_before,
        _metadata_files(table) if ask.report else -1,
        len(table.metadata.metadata_log),
        Float64(perf_counter_ns() - t0) / 1e9,
    )
