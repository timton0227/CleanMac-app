import Foundation

/// A single entry in the append-only deletion manifest (FR-SAFE-3). Written as
/// `.pending` *before* any mutation and updated to a terminal state after, so a
/// crash mid-batch is fully reconstructible (FR-SAFE-4). Restore reads these
/// records, never folder contents.
public struct ActionRecord: Sendable, Codable, Hashable, Identifiable {
    public enum State: String, Sendable, Codable {
        case pending      // written before mutation; recovery target
        case completed    // moved to Trash successfully
        case refused      // blocked by protected-path check (FR-SAFE-1)
        case skipped      // changed-since-scan (FR-SAFE-7) or absent
        case restored     // moved back to originalPath
        case purged       // permanently removed after restore window
        case failed       // I/O error during move
    }

    public var id: UUID { actionId }
    public let actionId: UUID
    /// Groups every item of one clean, enabling batch "undo last clean"
    /// (FR-SAFE-2 amend).
    public let batchId: UUID
    public let originalPath: URL
    /// Where the item now lives in the app-managed Trash (nil until moved).
    public var trashPath: URL?
    public let bytes: Int64
    public let category: Category
    public let timestamp: Date
    public var state: State
    /// Human-readable reason for non-`completed` terminal states.
    public var reason: String?

    public init(
        actionId: UUID = UUID(),
        batchId: UUID,
        originalPath: URL,
        trashPath: URL? = nil,
        bytes: Int64,
        category: Category,
        timestamp: Date = Date(),
        state: State = .pending,
        reason: String? = nil
    ) {
        self.actionId = actionId
        self.batchId = batchId
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.bytes = bytes
        self.category = category
        self.timestamp = timestamp
        self.state = state
        self.reason = reason
    }
}
