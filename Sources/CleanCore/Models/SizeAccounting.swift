import Foundation

/// Sizing + identity helpers shared by every scanner (§4.2 cloud awareness,
/// FR-SAFE-7 validation). Pure reads — never mutates.
public enum SizeAccounting {
    /// Real reclaimable bytes: allocated blocks on disk. iCloud-evicted files
    /// report ~0 here even though their logical size is large (§4.2), so they
    /// never inflate reclaim totals or Space Lens bubbles.
    public static func realOnDiskBytes(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }

        // A cloud placeholder that isn't materialized locally occupies ~0 bytes.
        if isCloudPlaceholder(values) { return 0 }

        if let total = values.totalFileAllocatedSize { return Int64(total) }
        if let alloc = values.fileAllocatedSize { return Int64(alloc) }
        return 0
    }

    /// Logical (apparent) size — for display context only, never reclaim math.
    public static func logicalBytes(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if let total = values.totalFileSize { return Int64(total) }
        if let size = values.fileSize { return Int64(size) }
        return 0
    }

    public static func isCloudPlaceholder(of url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return isCloudPlaceholder(values)
    }

    private static func isCloudPlaceholder(_ values: URLResourceValues) -> Bool {
        guard values.isUbiquitousItem == true else { return false }
        // "not downloaded" => the bytes live in iCloud, not on this disk.
        return values.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    /// Total real on-disk bytes of a file or directory subtree. For a directory
    /// it sums allocated blocks of all contained files. The enumerator does not
    /// resolve symlinks or mount points, satisfying the "never follow symlinks"
    /// safety rule (§4.3). Cloud placeholders inside contribute ~0 (§4.2).
    public static func totalRealOnDiskBytes(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return 0
        }
        if !isDir.boolValue { return realOnDiskBytes(of: url) }

        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .isRegularFileKey, .isUbiquitousItemKey,
                                      .ubiquitousItemDownloadingStatusKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys,
            options: [], errorHandler: { _, _ in true }
        ) else { return realOnDiskBytes(of: url) }

        for case let child as URL in enumerator {
            total += realOnDiskBytes(of: child)
        }
        return total
    }

    /// Identity snapshot for TOCTOU re-validation (FR-SAFE-7). Reads via `stat`
    /// directly rather than `URLResourceValues`, whose values are cached on the
    /// URL and would return stale size/mtime after the file changes.
    public static func validation(of url: URL) -> FileValidation? {
        guard let st = statOf(url) else { return nil }
        let modified = Date(timeIntervalSince1970:
            Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileValidation(inode: UInt64(st.st_ino), sizeBytes: Int64(st.st_size), modifiedAt: modified)
    }

    /// True if the file still matches the identity captured at scan time.
    public static func matchesValidation(_ url: URL, _ expected: FileValidation) -> Bool {
        guard let current = validation(of: url) else { return false }
        return current.inode == expected.inode
            && current.sizeBytes == expected.sizeBytes
            && current.modifiedAt == expected.modifiedAt
    }

    private static func statOf(_ url: URL) -> stat? {
        var st = stat()
        let ok = url.withUnsafeFileSystemRepresentation { rep -> Bool in
            guard let rep else { return false }
            return stat(rep, &st) == 0
        }
        return ok ? st : nil
    }
}
