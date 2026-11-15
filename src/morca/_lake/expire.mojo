"""Snapshot expiry as it crosses liblake (#471): what `morca_maintain expire`
asks for (`ExpireAsk`) and what the expiry did (`Expiry`), each encoded in
`morca._lake.abi`'s way. No iceberg here: `morca_maintain` builds this, and
the library's `morca._lake.expire_impl` does the expiry.
"""

from std.memory import bitcast

from morca._lake.abi import Dec, Enc, RawDec


@fieldwise_init
struct ExpireAsk(Copyable, Movable):
    """One dataset's expiry, as `morca_maintain expire` was asked for it."""

    var dataset: String
    var older_than_ms: Int64
    """Expire what is older than this many ms; -1 for the table's policy."""
    var keep: Int
    """Snapshots kept at least; -1 for the table's policy."""
    var retain: List[Int64]
    """Snapshots kept whatever their age."""
    var if_policy: Bool
    var dry_run: Bool
    var report: Bool

    def encode(self) -> Enc:
        var e = Enc()
        e.str(self.dataset)
        e.int(self.older_than_ms)
        e.int(Int64(self.keep))
        e.int(Int64(len(self.retain)))
        for id in self.retain:
            e.int(id)
        e.bool(self.if_policy)
        e.bool(self.dry_run)
        e.bool(self.report)
        return e^

    @staticmethod
    def decode(addr: Int, n: Int) raises -> Self:
        var d = RawDec(addr, n)
        var dataset = d.str()
        var older = d.int()
        var keep = Int(d.int())
        var retain = List[Int64]()
        for _ in range(Int(d.int())):
            retain.append(d.int())
        var if_policy = d.bool()
        var dry_run = d.bool()
        var report = d.bool()
        return Self(dataset^, older, keep, retain^, if_policy, dry_run, report)


@fieldwise_init
struct Expiry(Copyable, Movable, Writable):
    """What one dataset's expiry did, for the line `morca_maintain` prints."""

    var dataset: String
    var skipped: String
    """Why nothing was decided (no policy), or empty."""
    var dry_run: Bool
    var expired: List[Int64]
    """Snapshot ids removed from the metadata (or that would be)."""
    var removed_refs: List[String]
    """Branches and tags dropped for `max-ref-age-ms`."""
    var deleted_files: Int
    """Data and delete files deleted (or that would be)."""
    var deleted_manifests: Int
    """Manifests and manifest lists, likewise."""
    var deleted_statistics: Int
    var manifest_lists_read: Int
    var manifests_read: Int
    var reachable: Bool
    """Whether every retained manifest had to be read (branches or tags)."""
    var snapshots_before: Int
    var snapshots_after: Int
    var metadata_files_before: Int
    """-1 when not counted (no `--report`)."""
    var metadata_files_after: Int
    var log_after: Int
    var seconds: Float64

    @staticmethod
    def skip(
        dataset: String,
        why: String,
        snapshots: Int,
        metadata_files: Int,
        log: Int,
    ) -> Self:
        """An expiry that decided nothing, for `why`."""
        return Self(
            dataset,
            why,
            False,
            List[Int64](),
            List[String](),
            0,
            0,
            0,
            0,
            0,
            False,
            snapshots,
            snapshots,
            metadata_files,
            metadata_files,
            log,
            0.0,
        )

    def encode(self) -> Enc:
        var e = Enc()
        e.str(self.dataset)
        e.str(self.skipped)
        e.bool(self.dry_run)
        e.int(Int64(len(self.expired)))
        for id in self.expired:
            e.int(id)
        e.strs(self.removed_refs)
        e.int(Int64(self.deleted_files))
        e.int(Int64(self.deleted_manifests))
        e.int(Int64(self.deleted_statistics))
        e.int(Int64(self.manifest_lists_read))
        e.int(Int64(self.manifests_read))
        e.bool(self.reachable)
        e.int(Int64(self.snapshots_before))
        e.int(Int64(self.snapshots_after))
        e.int(Int64(self.metadata_files_before))
        e.int(Int64(self.metadata_files_after))
        e.int(Int64(self.log_after))
        e.int(bitcast[DType.int64](self.seconds))
        return e^

    @staticmethod
    def decode(b: Span[UInt8, _]) raises -> Self:
        var d = Dec(b)
        var dataset = d.str()
        var skipped = d.str()
        var dry_run = d.bool()
        var expired = List[Int64]()
        for _ in range(Int(d.int())):
            expired.append(d.int())
        var refs = d.strs()
        var files = Int(d.int())
        var manifests = Int(d.int())
        var statistics = Int(d.int())
        var lists_read = Int(d.int())
        var manifests_read = Int(d.int())
        var reachable = d.bool()
        var before = Int(d.int())
        var after = Int(d.int())
        var meta_before = Int(d.int())
        var meta_after = Int(d.int())
        var log_after = Int(d.int())
        var seconds = bitcast[DType.float64](d.int())
        return Self(
            dataset^,
            skipped^,
            dry_run,
            expired^,
            refs^,
            files,
            manifests,
            statistics,
            lists_read,
            manifests_read,
            reachable,
            before,
            after,
            meta_before,
            meta_after,
            log_after,
            seconds,
        )

    def write_to(self, mut w: Some[Writer]):
        if self.skipped:
            w.write("kept ", self.dataset, ": ", self.skipped)
            return
        w.write(
            "dry run " if self.dry_run else "expired ",
            self.dataset,
            ": snapshots ",
            self.snapshots_before,
            " -> ",
            self.snapshots_after,
            " (",
            len(self.expired),
            " expired",
        )
        if len(self.removed_refs) > 0:
            w.write(", refs removed:")
            for n in self.removed_refs:
                w.write(" ", n)
        w.write(
            "); would delete " if self.dry_run else "); deleted ",
            self.deleted_files,
            " data/delete files, ",
            self.deleted_manifests,
            " manifests and lists, ",
            self.deleted_statistics,
            " statistics; read ",
            self.manifest_lists_read,
            " manifest lists and ",
            self.manifests_read,
            " manifests",
        )
        if self.reachable:
            w.write(" (branches or tags: every retained manifest read)")
        w.write("; metadata-log ", self.log_after)
        if self.metadata_files_before >= 0:
            w.write(
                ", metadata files ",
                self.metadata_files_before,
                " -> ",
                self.metadata_files_after,
            )
        w.write("; ", self.seconds, " s")
