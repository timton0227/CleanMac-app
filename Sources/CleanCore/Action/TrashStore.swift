import Foundation

/// The app-managed Trash that makes removals reversible (FR-SAFE-2) with a
/// restore window before purge, and that is volume-type aware (FR-VOL).
///
/// Items are moved with an atomic same-volume rename. If the item is on a
/// different volume than the store (external/network), an atomic move is
/// impossible and reversibility can't be guaranteed — the store refuses and the
/// engine surfaces a "permanent" confirmation instead of silently hard-deleting
/// (FR-VOL). Same-volume moves also mean the space isn't truly freed until purge
/// — the reclaim-vs-retain distinction the engine reports (FR-SAFE-6).
public struct TrashStore: Sendable {
    public enum TrashError: Error, Equatable {
        case crossVolume          // FR-VOL: atomic move impossible → permanent path
        case restoreDestinationExists
        case sourceMissing
    }

    /// Base directory of the Trash (typically Application Support/CleanMac/Trash).
    public let baseURL: URL

    public init(baseURL: URL) throws {
        self.baseURL = baseURL
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    /// Whether an atomic, reversible move is possible for `url` (same volume as
    /// the store). When false, the engine must take the permanent path (FR-VOL).
    public func supportsReversibleRemoval(of url: URL) -> Bool {
        guard
            let itemVolume = volumeURL(of: url),
            let storeVolume = volumeURL(of: baseURL)
        else { return false }
        return itemVolume.path == storeVolume.path
    }

    /// Move an item into the Trash. Returns its new location for the manifest.
    public func store(_ url: URL, actionId: UUID) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw TrashError.sourceMissing }
        guard supportsReversibleRemoval(of: url) else { throw TrashError.crossVolume }

        let destDir = baseURL.appendingPathComponent(actionId.uuidString, isDirectory: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(url.lastPathComponent)
        try fm.moveItem(at: url, to: dest) // atomic rename on same volume
        return dest
    }

    /// Move an item back to its original path (FR-SAFE-2 restore). Refuses to
    /// clobber anything that now occupies the original path.
    public func restore(from trashPath: URL, to originalPath: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashPath.path) else { throw TrashError.sourceMissing }
        guard !fm.fileExists(atPath: originalPath.path) else {
            throw TrashError.restoreDestinationExists
        }
        try fm.createDirectory(
            at: originalPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.moveItem(at: trashPath, to: originalPath)
    }

    /// Permanently remove a trashed item's storage (after the restore window, or
    /// on explicit purge).
    public func purge(actionId: UUID) throws {
        let dir = baseURL.appendingPathComponent(actionId.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Volume helpers

    private func volumeURL(of url: URL) -> URL? {
        // Walk up to an existing ancestor first (the item may already be gone).
        var probe = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { return nil }
            probe = parent
        }
        return (try? probe.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }
}
