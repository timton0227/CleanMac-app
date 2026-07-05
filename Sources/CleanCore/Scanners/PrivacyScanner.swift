import Foundation

/// One clearable privacy artifact (§4.6): a concrete file or directory holding
/// history/cookies/recents for a specific app.
public struct PrivacyArtifact: Sendable {
    public let id: String
    /// e.g. "History", "Cookies", "Shell history".
    public let title: String
    /// e.g. "Safari", "Google Chrome", "Terminal".
    public let ownerName: String
    /// Bundle IDs whose running state makes clearing unsafe (live SQLite etc.).
    public let ownerBundleIDs: [String]
    /// Absolute paths; `~` expands to home; one `*` path component expands by
    /// directory listing (e.g. Firefox `Profiles/*/places.sqlite`).
    public let paths: [String]

    public init(id: String, title: String, ownerName: String,
                ownerBundleIDs: [String], paths: [String]) {
        self.id = id
        self.title = title
        self.ownerName = ownerName
        self.ownerBundleIDs = ownerBundleIDs
        self.paths = paths
    }

    /// Built-in catalog. Like junk rules (FR-DEFS) this belongs in the signed
    /// remote ruleset eventually; the shape is already data, not code.
    public static let catalog: [PrivacyArtifact] = [
        // Safari (TCC-protected: invisible without Full Disk Access, FR-PERM).
        .init(id: "safari-history", title: "Browsing history", ownerName: "Safari",
              ownerBundleIDs: ["com.apple.Safari"],
              paths: ["~/Library/Safari/History.db",
                      "~/Library/Safari/History.db-wal",
                      "~/Library/Safari/History.db-shm"]),
        .init(id: "safari-downloads", title: "Download history", ownerName: "Safari",
              ownerBundleIDs: ["com.apple.Safari"],
              paths: ["~/Library/Safari/Downloads.plist"]),
        // Chrome.
        .init(id: "chrome-history", title: "Browsing history", ownerName: "Google Chrome",
              ownerBundleIDs: ["com.google.Chrome"],
              paths: ["~/Library/Application Support/Google/Chrome/Default/History",
                      "~/Library/Application Support/Google/Chrome/Default/History-journal",
                      "~/Library/Application Support/Google/Chrome/Default/Visited Links"]),
        .init(id: "chrome-cookies", title: "Cookies", ownerName: "Google Chrome",
              ownerBundleIDs: ["com.google.Chrome"],
              paths: ["~/Library/Application Support/Google/Chrome/Default/Cookies",
                      "~/Library/Application Support/Google/Chrome/Default/Cookies-journal"]),
        // Firefox (any profile).
        .init(id: "firefox-history", title: "Browsing history", ownerName: "Firefox",
              ownerBundleIDs: ["org.mozilla.firefox"],
              paths: ["~/Library/Application Support/Firefox/Profiles/*/places.sqlite"]),
        .init(id: "firefox-cookies", title: "Cookies", ownerName: "Firefox",
              ownerBundleIDs: ["org.mozilla.firefox"],
              paths: ["~/Library/Application Support/Firefox/Profiles/*/cookies.sqlite"]),
        // Shell / tool histories (§4.6 "Terminal history, etc.").
        .init(id: "shell-history", title: "Shell history", ownerName: "Terminal",
              ownerBundleIDs: [],
              paths: ["~/.zsh_history", "~/.bash_history", "~/.zsh_sessions"]),
        .init(id: "tool-history", title: "Tool histories", ownerName: "Terminal",
              ownerBundleIDs: [],
              paths: ["~/.python_history", "~/.lesshst", "~/.viminfo"]),
        // System-wide recent items.
        .init(id: "recent-items", title: "Recent documents & apps", ownerName: "macOS",
              ownerBundleIDs: [],
              paths: [
                "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl3",
                "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentApplications.sfl3",
                "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentServers.sfl3",
              ]),
    ]
}

/// Privacy Cleaner scanner (§4.6). Emits findings that are:
///
/// - **never pre-selected** — clearing history is never a default (§4.6
///   "user-selectable granularity, never clear silently"); every finding is
///   `.low` confidence regardless of how certain the match is,
/// - **not Trash-recoverable** — removal must run through the engine's
///   non-reversible path and Review must say so (§4.6 note, FR-SAFE-2
///   exception),
/// - flagged `ownedByRunningProcess` when the owning browser is open (clearing
///   a live SQLite store corrupts it — FR-SAFE-1 amend).
public struct PrivacyScanner: Scanner {
    public let id = "privacy"
    public let category = Category.privacyArtifact
    public let displayName = "Privacy"

    public let artifacts: [PrivacyArtifact]
    public let runningBundleIDs: Set<String>
    private let protectedPaths: ProtectedPaths

    public init(
        artifacts: [PrivacyArtifact] = PrivacyArtifact.catalog,
        runningBundleIDs: Set<String> = [],
        protectedPaths: ProtectedPaths = ProtectedPaths()
    ) {
        self.artifacts = artifacts
        self.runningBundleIDs = runningBundleIDs
        self.protectedPaths = protectedPaths
    }

    public func scan(progress: @Sendable @escaping (Double) -> Void) async throws -> [Finding] {
        var findings: [Finding] = []
        for (index, artifact) in artifacts.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(max(artifacts.count, 1)))

            let ownerRunning = artifact.ownerBundleIDs.contains { runningBundleIDs.contains($0) }
            for pattern in artifact.paths {
                for url in Self.expand(pattern) {
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    findings.append(makeFinding(url, artifact: artifact,
                                                ownerRunning: ownerRunning))
                }
            }
        }
        progress(1.0)
        return findings
    }

    /// Expand `~` and a single `*` path component by directory listing.
    static func expand(_ pattern: String) -> [URL] {
        let expanded: String
        if pattern == "~" || pattern.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            expanded = home + String(pattern.dropFirst(1))
        } else {
            expanded = pattern
        }

        guard let starRange = expanded.range(of: "*") else {
            return [URL(fileURLWithPath: expanded)]
        }
        // Split into prefix dir / suffix around the wildcard component.
        let prefix = String(expanded[..<starRange.lowerBound])
        let suffix = String(expanded[starRange.upperBound...])
        // The directory to list is everything before the wildcard component:
        // ".../Profiles/*/places.sqlite" → ".../Profiles".
        let baseDir = prefix.hasSuffix("/")
            ? URL(fileURLWithPath: String(prefix.dropLast()))
            : URL(fileURLWithPath: prefix).deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.map { URL(fileURLWithPath: $0.path + suffix) }
    }

    private func makeFinding(_ url: URL, artifact: PrivacyArtifact,
                             ownerRunning: Bool) -> Finding {
        let verdict = protectedPaths.verdict(for: url)
        return Finding(
            path: url,
            realOnDiskBytes: SizeAccounting.totalRealOnDiskBytes(of: url),
            logicalBytes: SizeAccounting.logicalBytes(of: url),
            category: .privacyArtifact,
            confidence: .low, // §4.6: never a default — user opts in per item
            safeToRemove: !verdict.isProtected,
            isProtected: verdict.isProtected,
            isCloudPlaceholder: false,
            ownedByRunningProcess: ownerRunning,
            validation: SizeAccounting.validation(of: url),
            modifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
            displayLabel: "\(artifact.ownerName) — \(artifact.title): \(url.lastPathComponent)"
        )
    }
}
