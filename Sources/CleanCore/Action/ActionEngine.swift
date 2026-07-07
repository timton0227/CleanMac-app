import Foundation

/// The single hardened component that mutates the filesystem (§2). Every scanner
/// only proposes; this actor is the sole delete path, so all safety guarantees
/// live here in one place:
///
/// - FR-SAFE-1  protected-path enforcement (via `ProtectedPaths`)
/// - FR-SAFE-3  audit log written+fsync'd before every mutation (via `AuditLog`)
/// - FR-SAFE-4  transactional/idempotent — resume skips completed items
/// - FR-SAFE-5  serialization — actor runs one operation at a time
/// - FR-SAFE-6  reclaim-vs-retain — reports "freed now" vs "reclaimable after purge"
/// - FR-SAFE-7  re-validate identity immediately before removal (TOCTOU)
/// - FR-VOL     cross-volume items can't be reversibly trashed → permanent path
/// - FR-VERIFY  measured free-space delta reconciled against the estimate
public actor ActionEngine {
    public struct Options: Sendable {
        /// Skip the Trash entirely and permanently remove, to actually reclaim
        /// space now (FR-SAFE-6, "disk full"). Requires explicit user confirm.
        public var permanentToReclaimNow: Bool
        /// For items on volumes without reversible-Trash support, permanently
        /// remove instead of refusing (FR-VOL). Requires explicit confirm.
        public var permanentWhenCrossVolume: Bool

        public init(permanentToReclaimNow: Bool = false, permanentWhenCrossVolume: Bool = false) {
            self.permanentToReclaimNow = permanentToReclaimNow
            self.permanentWhenCrossVolume = permanentWhenCrossVolume
        }
    }

    public struct Report: Sendable, Equatable {
        public let batchId: UUID
        public var completed: [ActionRecord] = []
        public var refused: [ActionRecord] = []
        public var skipped: [ActionRecord] = []
        public var failed: [ActionRecord] = []
        /// Space actually returned to the volume now (permanent removals).
        public var freedNowBytes: Int64 = 0
        /// Bytes held in Trash, reclaimed only at purge (FR-SAFE-6).
        public var reclaimableAfterPurgeBytes: Int64 = 0
        public var verification: Verifier.Result?
    }

    private let protectedPaths: ProtectedPaths
    private let auditLog: AuditLog
    private let trash: TrashStore
    private let freeSpace: FreeSpaceProbe
    private let verifier: Verifier

    public init(
        protectedPaths: ProtectedPaths = ProtectedPaths(),
        auditLog: AuditLog,
        trash: TrashStore,
        freeSpace: FreeSpaceProbe = FreeSpaceProbe(),
        verifier: Verifier = Verifier()
    ) {
        self.protectedPaths = protectedPaths
        self.auditLog = auditLog
        self.trash = trash
        self.freeSpace = freeSpace
        self.verifier = verifier
    }

    /// Remove the given findings. Body performs only synchronous filesystem work,
    /// so the actor executes it as one uninterrupted operation (FR-SAFE-5).
    public func perform(
        _ findings: [Finding],
        options: Options = Options(),
        batchId: UUID = UUID()
    ) -> Report {
        var report = Report(batchId: batchId)

        // FR-SAFE-4: items already completed in a prior run of this batch are
        // skipped (idempotent resume). Keyed by original path within the batch.
        let priorCompleted: Set<URL> = (try? auditLog.currentRecords())
            .map { records in
                Set(records
                    .filter { $0.batchId == batchId && $0.state == .completed }
                    .map(\.originalPath))
            } ?? []

        let freeBefore = freeSpace.availableBytes(forVolumeContaining: trash.baseURL)

        for finding in findings {
            if priorCompleted.contains(finding.path) { continue } // already done

            // FR-SAFE-1: hard denylist. Scanner flag OR engine verdict refuses.
            let verdict = protectedPaths.verdict(for: finding.path)
            if finding.isProtected || verdict.isProtected {
                let rec = record(finding, batchId, .refused,
                                 reason: verdict.reason ?? "protected path")
                append(rec, into: &report.refused)
                continue
            }

            // Item must still exist.
            guard FileManager.default.fileExists(atPath: finding.path.path) else {
                let rec = record(finding, batchId, .skipped, reason: "no longer present")
                append(rec, into: &report.skipped)
                continue
            }

            // FR-SAFE-7: identity must match the scan-time snapshot.
            if let v = finding.validation, !SizeAccounting.matchesValidation(finding.path, v) {
                let rec = record(finding, batchId, .skipped, reason: "changed-since-scan")
                append(rec, into: &report.skipped)
                continue
            }

            let actionId = UUID()
            let reversible = trash.supportsReversibleRemoval(of: finding.path)
            let goPermanent = options.permanentToReclaimNow
                || (!reversible && options.permanentWhenCrossVolume)

            if !reversible && !goPermanent {
                // FR-VOL: can't reversibly trash and no permanent consent → refuse.
                let rec = record(finding, batchId, .refused, actionId: actionId,
                                 reason: "volume has no Trash; needs explicit permanent confirm")
                append(rec, into: &report.refused)
                continue
            }

            // FR-SAFE-3: write the manifest (with intended destination) and
            // fsync BEFORE mutating, so recovery is exact.
            let plannedTrash = goPermanent
                ? nil
                : trash.plannedTrashURL(for: finding.path, actionId: actionId)
            var pending = ActionRecord(
                actionId: actionId, batchId: batchId, originalPath: finding.path,
                trashPath: plannedTrash, bytes: finding.realOnDiskBytes,
                category: finding.category, state: .pending
            )
            do {
                try auditLog.append(pending)
            } catch {
                pending.state = .failed
                pending.reason = "manifest write failed: \(error)"
                append(pending, into: &report.failed)
                continue
            }

            // The mutation.
            do {
                if goPermanent {
                    try FileManager.default.removeItem(at: finding.path)
                    pending.state = .completed
                    pending.trashPath = nil
                    try? auditLog.append(pending)
                    report.completed.append(pending)
                    report.freedNowBytes += finding.realOnDiskBytes
                } else {
                    let dest = try trash.store(finding.path, actionId: actionId)
                    pending.state = .completed
                    pending.trashPath = dest
                    try? auditLog.append(pending)
                    report.completed.append(pending)
                    report.reclaimableAfterPurgeBytes += finding.realOnDiskBytes
                }
            } catch {
                pending.state = .failed
                pending.reason = "\(error)"
                try? auditLog.append(pending)
                report.failed.append(pending)
            }
        }

        // FR-VERIFY: only permanent removals free space now; reconcile those.
        if let before = freeBefore,
           let after = freeSpace.availableBytes(forVolumeContaining: trash.baseURL) {
            report.verification = verifier.reconcile(
                estimatedBytes: report.freedNowBytes, freeBefore: before, freeAfter: after
            )
        }
        return report
    }

    /// Perform actions that are inherently **not Trash-recoverable** — APFS
    /// snapshot deletion (§4.7), privacy purges (§4.6), item toggles. The module
    /// supplies the mutation; the engine still owns everything else: FR-SAFE-3
    /// manifest-before-mutation, FR-SAFE-4 idempotent resume, FR-SAFE-5
    /// serialization (actor), FR-SAFE-1 for any file-URL finding, and FR-VERIFY
    /// measurement. Review must have flagged these as non-reversible (§4.6 note).
    public func performNonReversible(
        _ findings: [Finding],
        batchId: UUID = UUID(),
        executor: @Sendable (Finding) async throws -> Void
    ) async -> Report {
        var report = Report(batchId: batchId)

        // FR-SAFE-4: skip items already completed in a prior run of this batch.
        let priorCompleted: Set<URL> = (try? auditLog.currentRecords())
            .map { records in
                Set(records
                    .filter { $0.batchId == batchId && $0.state == .completed }
                    .map(\.originalPath))
            } ?? []

        let freeBefore = freeSpace.availableBytes(forVolumeContaining: trash.baseURL)

        for finding in findings {
            if priorCompleted.contains(finding.path) { continue }

            // Non-file findings (snapshot:// …) have no path to check; file URLs
            // still go through the denylist (FR-SAFE-1).
            if finding.path.isFileURL {
                let verdict = protectedPaths.verdict(for: finding.path)
                if finding.isProtected || verdict.isProtected {
                    let rec = record(finding, batchId, .refused,
                                     reason: verdict.reason ?? "protected path")
                    append(rec, into: &report.refused)
                    continue
                }
            }

            var pending = ActionRecord(
                actionId: UUID(), batchId: batchId, originalPath: finding.path,
                trashPath: nil, bytes: finding.realOnDiskBytes,
                category: finding.category, state: .pending
            )
            do {
                try auditLog.append(pending) // fsync'd before the mutation
            } catch {
                pending.state = .failed
                pending.reason = "manifest write failed: \(error)"
                report.failed.append(pending)
                continue
            }

            do {
                try await executor(finding)
                pending.state = .completed
                try? auditLog.append(pending)
                report.completed.append(pending)
                report.freedNowBytes += finding.realOnDiskBytes
            } catch {
                pending.state = .failed
                pending.reason = "\(error)"
                try? auditLog.append(pending)
                report.failed.append(pending)
            }
        }

        if let before = freeBefore,
           let after = freeSpace.availableBytes(forVolumeContaining: trash.baseURL) {
            report.verification = verifier.reconcile(
                estimatedBytes: report.freedNowBytes, freeBefore: before, freeAfter: after
            )
        }
        return report
    }

    /// Completed, still-restorable items (for the Trash UI).
    public func listTrash() -> [ActionRecord] {
        ((try? auditLog.currentRecords()) ?? [])
            .filter { $0.state == .completed && $0.trashPath != nil }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Restore a single completed action to its original path (FR-SAFE-2).
    @discardableResult
    public func restore(actionId: UUID) throws -> Bool {
        guard let rec = try auditLog.currentRecords().first(where: { $0.actionId == actionId }),
              rec.state == .completed, let trashPath = rec.trashPath else {
            return false
        }
        try trash.restore(from: trashPath, to: rec.originalPath)
        var restored = rec
        restored.state = .restored
        try auditLog.append(restored)
        return true
    }

    /// Restore an entire clean in one step — "undo last clean" (FR-SAFE-2 amend).
    /// Returns the number of items restored.
    @discardableResult
    public func undoBatch(_ batchId: UUID) throws -> Int {
        let toRestore = try auditLog.currentRecords()
            .filter { $0.batchId == batchId && $0.state == .completed && $0.trashPath != nil }
        var count = 0
        for rec in toRestore where (try? restore(actionId: rec.actionId)) == true {
            count += 1
        }
        return count
    }

    /// Reconstruct exact state after a crash mid-batch (FR-SAFE-4). A `.pending`
    /// whose file already reached the Trash is promoted to `.completed`; one
    /// whose file is gone entirely is marked `.skipped`.
    @discardableResult
    public func reconcilePending() throws -> [ActionRecord] {
        let fm = FileManager.default
        var fixed: [ActionRecord] = []
        for var rec in try auditLog.currentRecords() where rec.state == .pending {
            let atOriginal = fm.fileExists(atPath: rec.originalPath.path)
            let atTrash = rec.trashPath.map { fm.fileExists(atPath: $0.path) } ?? false
            if atTrash && !atOriginal {
                rec.state = .completed          // move succeeded before crash
            } else if !atOriginal && !atTrash {
                rec.state = .skipped
                rec.reason = "lost during interruption"
            } else {
                continue                        // still at origin → safe to redo
            }
            try auditLog.append(rec)
            fixed.append(rec)
        }
        return fixed
    }

    /// Purge trashed items older than the restore window.
    public func purgeExpired(olderThan cutoff: Date) throws {
        for rec in try auditLog.currentRecords()
        where rec.state == .completed && rec.trashPath != nil && rec.timestamp < cutoff {
            try trash.purge(actionId: rec.actionId, trashPath: rec.trashPath)
            var purged = rec
            purged.state = .purged
            try auditLog.append(purged)
        }
    }

    // MARK: - Helpers

    private func record(
        _ finding: Finding, _ batchId: UUID, _ state: ActionRecord.State,
        actionId: UUID = UUID(), reason: String? = nil
    ) -> ActionRecord {
        ActionRecord(
            actionId: actionId, batchId: batchId, originalPath: finding.path,
            bytes: finding.realOnDiskBytes, category: finding.category,
            state: state, reason: reason
        )
    }

    private func append(_ rec: ActionRecord, into bucket: inout [ActionRecord]) {
        try? auditLog.append(rec)
        bucket.append(rec)
    }
}
