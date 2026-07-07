import Foundation

/// Reversible removals (FR-SAFE-2) with a restore window before purge, volume-type
/// aware (FR-VOL).
///
/// In production this uses the **macOS system Trash** (`FileManager.trashItem`):
/// removed items land in `~/.Trash` (or the item's volume `.Trashes`), show up in
/// Finder, and can be restored with "Put Back" — not squirreled away in a private
/// app cache. `store` returns the item's resulting Trash URL for the manifest, so
/// the app's own restore/undo keeps working on top of the system Trash.
///
/// Because a Trash move is same-volume, the space isn't truly freed until the Trash
/// is emptied (or the app purges it) — the reclaim-vs-retain distinction the engine
/// reports (FR-SAFE-6). If a volume can't hold a Trash (read-only), reversible
/// removal is impossible and the engine surfaces a "permanent" confirmation instead
/// of silently hard-deleting (FR-VOL).
///
/// Tests construct the store with `useSystemTrash: false` so they move items into
/// `baseURL` and never touch the developer's real `~/.Trash`.
public struct TrashStore: Sendable {
    public enum TrashError: Error, Equatable {
        case crossVolume          // FR-VOL: volume can't hold a Trash → permanent path
        case restoreDestinationExists
        case sourceMissing
    }

    /// Base directory of the fallback Trash (typically Application Support/CleanMac/
    /// Trash). Only used when `useSystemTrash` is false.
    public let baseURL: URL

    /// When true (production default), removals go to the macOS system Trash.
    /// When false, they move into `baseURL` — used by tests to stay hermetic.
    public let useSystemTrash: Bool

    public init(baseURL: URL, useSystemTrash: Bool = true) throws {
        self.baseURL = baseURL
        self.useSystemTrash = useSystemTrash
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    /// Whether a reversible removal is possible for `url`. With the system Trash
    /// that's any writable volume (each volume trashes to its own `.Trashes`); in
    /// the fallback mode the item must be on the store's own volume. When false,
    /// the engine must take the permanent path (FR-VOL).
    public func supportsReversibleRemoval(of url: URL) -> Bool {
        guard let itemVolume = volumeURL(of: url) else { return false }
        if useSystemTrash {
            let readOnly = (try? itemVolume.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
                .volumeIsReadOnly ?? false
            return !readOnly
        }
        guard let storeVolume = volumeURL(of: baseURL) else { return false }
        return itemVolume.path == storeVolume.path
    }

    /// Move an item into the Trash. Returns its new location for the manifest.
    public func store(_ url: URL, actionId: UUID) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw TrashError.sourceMissing }
        guard supportsReversibleRemoval(of: url) else { throw TrashError.crossVolume }

        if useSystemTrash {
            var resulting: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &resulting)
            guard let dest = resulting as URL? else { throw TrashError.sourceMissing }
            return dest
        }

        let destDir = baseURL.appendingPathComponent(actionId.uuidString, isDirectory: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(url.lastPathComponent)
        try fm.moveItem(at: url, to: dest) // atomic rename on same volume
        return dest
    }

    /// Best-effort destination recorded in the manifest *before* the move so a
    /// crash mid-store can still be reconciled (FR-SAFE-3). The real URL returned
    /// by `store` may differ — Finder disambiguates name collisions in the Trash.
    public func plannedTrashURL(for url: URL, actionId: UUID) -> URL? {
        if useSystemTrash {
            let trashDir = try? FileManager.default.url(
                for: .trashDirectory, in: .userDomainMask,
                appropriateFor: url, create: false)
            return trashDir?.appendingPathComponent(url.lastPathComponent)
        }
        return baseURL.appendingPathComponent(actionId.uuidString, isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
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
    /// on explicit purge). With the system Trash this deletes the item at its
    /// recorded `trashPath`; in fallback mode it removes the action's subdirectory.
    public func purge(actionId: UUID, trashPath: URL?) throws {
        let fm = FileManager.default
        if useSystemTrash {
            if let trashPath, fm.fileExists(atPath: trashPath.path) {
                try fm.removeItem(at: trashPath)
            }
            return
        }
        let dir = baseURL.appendingPathComponent(actionId.uuidString, isDirectory: true)
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
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
