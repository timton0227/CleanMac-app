import Foundation

/// Large & Old Files finder (§4.2). Recursively walks user-facing locations for
/// files at or above a size threshold, capturing modified/accessed dates for the
/// "old files" sort. Safety rules inherited from the pipeline:
///
/// - symlinks are never followed (§4.3),
/// - packages/bundles are treated as single opaque nodes (FR-BUNDLE) — a large
///   `.photoslibrary` is reported whole, its internals never enumerated,
/// - sizes are *real on-disk* bytes, so an iCloud-evicted file shows its logical
///   size for context but contributes 0 reclaimable and is never pre-selected
///   (§4.2 cloud awareness).
///
/// Large files are user data, not junk: every finding is `.low` confidence and
/// therefore default-unselected in Review (§7 — conservative over aggressive).
public struct LargeOldFilesScanner: Scanner {
    public let id = "large-old-files"
    public let category = Category.largeFile
    public let displayName = "Large & Old Files"

    /// Locations to walk. Defaults to the user-facing folders from §4.2.
    public let roots: [URL]
    /// Report files whose size (real, or logical for cloud placeholders) is at
    /// least this many bytes.
    public let minBytes: Int64

    private let protectedPaths: ProtectedPaths

    public init(
        roots: [URL]? = nil,
        minBytes: Int64 = 100 * 1024 * 1024,
        protectedPaths: ProtectedPaths = ProtectedPaths()
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? [
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Movies"),
            home.appendingPathComponent("Music"),
            home.appendingPathComponent("Pictures"),
        ]
        self.minBytes = minBytes
        self.protectedPaths = protectedPaths
    }

    public func scan(progress: @Sendable @escaping (Double) -> Void) async throws -> [Finding] {
        var findings: [Finding] = []

        for (index, root) in roots.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(max(roots.count, 1)))

            let keys: [URLResourceKey] = [
                .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .isPackageKey,
                .contentModificationDateKey, .contentAccessDateKey,
            ]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                // FR-BUNDLE: never look inside packages. Also skip hidden files.
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

                // §4.3 safety: never follow (or report) symlinks.
                if values.isSymbolicLink == true {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }

                let isPackage = values.isPackage == true
                // Plain directories are traversal structure, not findings; a
                // package is a single opaque candidate (FR-BUNDLE).
                if values.isDirectory == true && !isPackage { continue }

                if let finding = evaluate(url, values: values, isPackage: isPackage) {
                    findings.append(finding)
                }
            }
        }

        progress(1.0)
        return findings
    }

    private func evaluate(_ url: URL, values: URLResourceValues, isPackage: Bool) -> Finding? {
        let realBytes = isPackage
            ? SizeAccounting.totalRealOnDiskBytes(of: url)
            : SizeAccounting.realOnDiskBytes(of: url)
        let logical = isPackage ? realBytes : SizeAccounting.logicalBytes(of: url)
        let isCloud = SizeAccounting.isCloudPlaceholder(of: url)

        // Threshold on the larger of the two so an evicted 5 GB cloud file is
        // still *visible* (flagged, contributing 0 reclaimable) rather than
        // silently missing — the §10 ambiguity resolved toward transparency.
        guard max(realBytes, logical) >= minBytes else { return nil }

        let verdict = protectedPaths.verdict(for: url)
        // Splits into the mock's two categories: recently-touched files are
        // "Large Files", anything untouched a year-plus is "Old Files" — same
        // walk and size gate, just grouped by how stale it is.
        let staleCutoff = Date(timeIntervalSinceNow: -365 * 24 * 60 * 60)
        let lastTouched = max(values.contentModificationDate ?? .distantPast,
                               values.contentAccessDate ?? .distantPast)
        let category: Category = lastTouched < staleCutoff ? .oldFile : .largeFile
        return Finding(
            path: url,
            realOnDiskBytes: realBytes,
            logicalBytes: logical,
            category: category,
            confidence: .low, // user data — never pre-selected (§7)
            safeToRemove: !verdict.isProtected,
            isProtected: verdict.isProtected,
            isCloudPlaceholder: isCloud,
            validation: SizeAccounting.validation(of: url),
            modifiedAt: values.contentModificationDate,
            lastAccessedAt: values.contentAccessDate
        )
    }
}
