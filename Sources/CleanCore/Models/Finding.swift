import Foundation

/// The common, normalized result model every scanner emits (§2 "Findings").
///
/// A `Finding` is a *proposal* only — nothing here mutates the filesystem. The
/// shared `ActionEngine` is the sole component that acts on findings.
public struct Finding: Sendable, Identifiable, Codable, Hashable {
    public let id: UUID
    /// Absolute path to the candidate item.
    public let path: URL
    /// Real space reclaimable on disk (§4.2 cloud-awareness): allocated blocks,
    /// which is ~0 for iCloud-evicted "dataless" files and what actually gets
    /// freed. This — not `logicalBytes` — drives totals and Space Lens sizing.
    public let realOnDiskBytes: Int64
    /// Apparent/logical size. Shown for context but never used for reclaim math.
    public let logicalBytes: Int64
    public let category: Category
    public let confidence: Confidence
    /// Scanner's judgment that removal is safe. Distinct from `isProtected`,
    /// which is the engine's hard denylist verdict (FR-SAFE-1).
    public let safeToRemove: Bool
    /// True if this path is on the never-touch denylist. Shown disabled in
    /// Review; the engine refuses it regardless of UI state.
    public let isProtected: Bool
    /// iCloud-evicted placeholder — contributes 0 real bytes (§4.2).
    public let isCloudPlaceholder: Bool
    /// Owned by a currently-running process (FR-SAFE-1 amend) — deselect by
    /// default; removing a live app's cache can crash it.
    public let ownedByRunningProcess: Bool

    /// Identity captured at scan time, re-checked before mutation (FR-SAFE-7).
    public let validation: FileValidation?

    /// Last-modified / last-accessed dates, where the scanner captured them —
    /// drive the "old files" filter/sort in Review (§4.2).
    public let modifiedAt: Date?
    public let lastAccessedAt: Date?

    /// Human-readable label when the path itself is opaque (e.g. an iOS backup
    /// directory named by device UDID shows "Thien's iPhone — May 2026").
    public let displayLabel: String?

    public init(
        id: UUID = UUID(),
        path: URL,
        realOnDiskBytes: Int64,
        logicalBytes: Int64,
        category: Category,
        confidence: Confidence,
        safeToRemove: Bool,
        isProtected: Bool,
        isCloudPlaceholder: Bool,
        ownedByRunningProcess: Bool = false,
        validation: FileValidation? = nil,
        modifiedAt: Date? = nil,
        lastAccessedAt: Date? = nil,
        displayLabel: String? = nil
    ) {
        self.id = id
        self.path = path
        self.realOnDiskBytes = realOnDiskBytes
        self.logicalBytes = logicalBytes
        self.category = category
        self.confidence = confidence
        self.safeToRemove = safeToRemove
        self.isProtected = isProtected
        self.isCloudPlaceholder = isCloudPlaceholder
        self.ownedByRunningProcess = ownedByRunningProcess
        self.validation = validation
        self.modifiedAt = modifiedAt
        self.lastAccessedAt = lastAccessedAt
        self.displayLabel = displayLabel
    }

    /// Whether Review should pre-select this item. Conservative by default (§7):
    /// only high-confidence, safe, unprotected, not-in-use items are pre-checked.
    public var defaultSelected: Bool {
        safeToRemove
            && !isProtected
            && !ownedByRunningProcess
            && confidence >= .medium
            && realOnDiskBytes > 0
    }
}

/// Snapshot of a file's identity, used to detect change-between-scan-and-action
/// (FR-SAFE-7, TOCTOU protection).
public struct FileValidation: Sendable, Codable, Hashable {
    public let inode: UInt64
    public let sizeBytes: Int64
    public let modifiedAt: Date

    public init(inode: UInt64, sizeBytes: Int64, modifiedAt: Date) {
        self.inode = inode
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}
