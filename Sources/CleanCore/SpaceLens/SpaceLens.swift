import Foundation

/// One node of the Space Lens storage map (§4.9): a file, directory, or opaque
/// package with its aggregated **real on-disk** size — the whole point of the
/// map is that bubble area equals reclaimable bytes, so cloud-only files and
/// hardlinked twins must not inflate it (§4.2/§4.3).
public struct SpaceNode: Sendable, Identifiable, Hashable {
    public let path: URL
    public let name: String
    public let isDirectory: Bool
    /// Packages (`.app`, `.photoslibrary`…) are leaf nodes: sized whole, never
    /// drillable, never partially deletable (FR-BUNDLE).
    public let isPackage: Bool
    public let realBytes: Int64
    /// Sorted descending; only directories (non-package) have children.
    public let children: [SpaceNode]
    /// Aggregate of children too small to display individually.
    public let prunedBytes: Int64

    public var id: URL { path }
    /// Drill-in target: a plain directory. Files and packages are selectable units.
    public var isDrillable: Bool { isDirectory && !isPackage }

    public init(path: URL, name: String, isDirectory: Bool, isPackage: Bool,
                realBytes: Int64, children: [SpaceNode], prunedBytes: Int64) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.realBytes = realBytes
        self.children = children
        self.prunedBytes = prunedBytes
    }

    /// FR-UX-LIVE: after the engine removes items, the map updates *in place* —
    /// removed nodes disappear and every ancestor's size drops by the removed
    /// bytes, no rescan. Returns nil if this node itself was removed.
    public func removing(_ removed: Set<URL>) -> SpaceNode? {
        if removed.contains(path) { return nil }
        guard isDirectory, !children.isEmpty else { return self }

        // Rebuild unconditionally: a removal anywhere below changes this
        // node's size even when its direct child count is unchanged.
        let newChildren = children.compactMap { $0.removing(removed) }
        let newBytes = newChildren.reduce(prunedBytes) { $0 + $1.realBytes }
        return SpaceNode(path: path, name: name, isDirectory: isDirectory,
                         isPackage: isPackage, realBytes: newBytes,
                         children: newChildren, prunedBytes: prunedBytes)
    }
}

/// Builds the §4.9 storage tree. Hidden files are included (surfacing hidden
/// space hogs is the feature); symlinks are never followed (§4.3); hardlinked
/// storage is counted once across the whole tree.
public enum SpaceLens {
    /// - Parameter minNodeBytes: children below this size are aggregated into
    ///   their parent's `prunedBytes` instead of appearing individually —
    ///   totals stay exact while the tree stays displayable.
    public static func build(
        root: URL,
        minNodeBytes: Int64 = 1_048_576,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> SpaceNode {
        var seenHardlinks = Set<UInt64>()
        let node = try buildNode(root, depth: 0, minNodeBytes: minNodeBytes,
                                 seenHardlinks: &seenHardlinks, progress: progress)
        progress?(1.0)
        return node
    }

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .linkCountKey,
    ]

    private static func buildNode(
        _ url: URL, depth: Int, minNodeBytes: Int64,
        seenHardlinks: inout Set<UInt64>,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> SpaceNode {
        let values = try? url.resourceValues(forKeys: keys)
        let isDir = values?.isDirectory == true
        let isPackage = values?.isPackage == true
        let name = url.lastPathComponent

        // Leaves: files, and packages as opaque units (FR-BUNDLE).
        if !isDir || isPackage {
            let bytes = isPackage
                ? SizeAccounting.totalRealOnDiskBytes(of: url)
                : fileBytes(url, linkCount: values?.linkCount ?? 1,
                            seenHardlinks: &seenHardlinks)
            return SpaceNode(path: url, name: name, isDirectory: isDir,
                             isPackage: isPackage, realBytes: bytes,
                             children: [], prunedBytes: 0)
        }

        // Directory: recurse (hidden files included, symlinks skipped).
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: []
        )) ?? []

        var built: [SpaceNode] = []
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            if depth == 0 {
                progress?(Double(index) / Double(max(entries.count, 1)))
            }
            let v = try? entry.resourceValues(forKeys: keys)
            if v?.isSymbolicLink == true { continue }
            built.append(try buildNode(entry, depth: depth + 1,
                                       minNodeBytes: minNodeBytes,
                                       seenHardlinks: &seenHardlinks,
                                       progress: progress))
        }

        built.sort { $0.realBytes > $1.realBytes }
        let kept = built.filter { $0.realBytes >= minNodeBytes }
        let pruned = built.filter { $0.realBytes < minNodeBytes }
        let prunedBytes = pruned.reduce(Int64(0)) { $0 + $1.realBytes }
        let total = kept.reduce(prunedBytes) { $0 + $1.realBytes }

        return SpaceNode(path: url, name: name, isDirectory: true,
                         isPackage: false, realBytes: total,
                         children: kept, prunedBytes: prunedBytes)
    }

    /// A file's real bytes, counting hardlinked storage only once tree-wide
    /// (§4.3: deleting one hardlink frees nothing).
    private static func fileBytes(_ url: URL, linkCount: Int,
                                  seenHardlinks: inout Set<UInt64>) -> Int64 {
        if linkCount > 1 {
            var st = stat()
            let ok = url.withUnsafeFileSystemRepresentation { rep -> Bool in
                guard let rep else { return false }
                return stat(rep, &st) == 0
            }
            if ok {
                // Fold dev+ino into one key; collisions across devices are
                // vanishingly unlikely within one scan root.
                let key = UInt64(bitPattern: Int64(st.st_dev)) &* 0x1_0000_0001 &+ UInt64(st.st_ino)
                if seenHardlinks.contains(key) { return 0 }
                seenHardlinks.insert(key)
            }
        }
        return SizeAccounting.realOnDiskBytes(of: url)
    }
}
