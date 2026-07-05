import Foundation

/// The user-level `~/Library` locations where apps scatter their files (§4.4).
/// System-wide locations (LaunchDaemons, /Library, receipts in /var/db) need
/// the privileged helper (Infra A) and are deliberately absent here.
struct LibraryLocation: Sendable {
    let subpath: String
    /// Whether app-*name* (not just bundle-ID) matches are acceptable here.
    /// Name matches are inherently riskier ("Notes", "Books"…), so they are
    /// allowed only in low-stakes locations and always at `.low` confidence.
    let allowsNameMatch: Bool

    static let all: [LibraryLocation] = [
        .init(subpath: "Application Support", allowsNameMatch: true),
        .init(subpath: "Caches", allowsNameMatch: true),
        .init(subpath: "Logs", allowsNameMatch: true),
        .init(subpath: "Preferences", allowsNameMatch: false),
        .init(subpath: "Saved Application State", allowsNameMatch: false),
        .init(subpath: "WebKit", allowsNameMatch: false),
        .init(subpath: "HTTPStorages", allowsNameMatch: false),
        .init(subpath: "Containers", allowsNameMatch: false),
        .init(subpath: "Application Scripts", allowsNameMatch: false),
        .init(subpath: "LaunchAgents", allowsNameMatch: false),
    ]
}

/// Finds files associated with an app across the user Library (§4.4). Matching
/// is deliberately conservative — a false positive here deletes *another* app's
/// data, the worst failure mode (§7):
///
/// - exact bundle-ID match, or `bundleID.` prefix (plists, launch agents,
///   `.savedState`…) → `.high` confidence,
/// - exact app-name match → `.low` confidence, only in locations that allow it,
///   and therefore never pre-selected.
struct AssociatedFileLocator: Sendable {
    let libraryRoot: URL
    let protectedPaths: ProtectedPaths

    init(libraryRoot: URL? = nil, protectedPaths: ProtectedPaths = ProtectedPaths()) {
        self.libraryRoot = libraryRoot
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        self.protectedPaths = protectedPaths
    }

    func findings(bundleID: String?, appName: String, isRunning: Bool) -> [Finding] {
        var results: [Finding] = []
        for location in LibraryLocation.all {
            let dir = libraryRoot.appendingPathComponent(location.subpath)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                // Never follow symlinks (§4.3).
                if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                    .isSymbolicLink == true { continue }

                guard let confidence = match(
                    entryName: entry.lastPathComponent,
                    bundleID: bundleID, appName: appName,
                    allowsNameMatch: location.allowsNameMatch
                ) else { continue }

                results.append(makeFinding(
                    entry, category: .appLeftover,
                    confidence: confidence, isRunning: isRunning
                ))
            }
        }
        return results
    }

    /// The matching rule — the safety-critical part.
    func match(entryName: String, bundleID: String?, appName: String,
               allowsNameMatch: Bool) -> Confidence? {
        // Strip container suffixes so `com.foo.Bar.plist`, `.savedState`,
        // `.binarycookies` compare against the bare identifier.
        let stripped = Self.strippingKnownSuffixes(entryName)

        if let bundleID, !bundleID.isEmpty {
            if stripped == bundleID { return .high }
            if stripped.hasPrefix(bundleID + ".") { return .high }
        }
        if allowsNameMatch, entryName == appName, appName.count >= 3 {
            return .low // plausible but risky — never pre-selected
        }
        return nil
    }

    static func strippingKnownSuffixes(_ name: String) -> String {
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    func makeFinding(_ url: URL, category: Category,
                     confidence: Confidence, isRunning: Bool) -> Finding {
        let verdict = protectedPaths.verdict(for: url)
        return Finding(
            path: url,
            realOnDiskBytes: SizeAccounting.totalRealOnDiskBytes(of: url),
            logicalBytes: SizeAccounting.logicalBytes(of: url),
            category: category,
            confidence: confidence,
            safeToRemove: !verdict.isProtected,
            isProtected: verdict.isProtected,
            isCloudPlaceholder: SizeAccounting.isCloudPlaceholder(of: url),
            ownedByRunningProcess: isRunning,
            validation: SizeAccounting.validation(of: url),
            modifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        )
    }
}

/// Full uninstall (§4.4): the `.app` bundle plus its associated user-level
/// files. Removal runs through the standard reversible pipeline, so an
/// uninstall can be undone from the app Trash. Deselecting the bundle row in
/// Review turns an uninstall into an *app reset* (clear settings, keep app).
public struct UninstallScanner: Scanner {
    public let id = "app-uninstall"
    public let category = Category.application
    public let displayName = "Uninstaller"

    public let targets: [InstalledApp]
    /// Bundle IDs of currently-running apps (FR-SAFE-1 amend) — supplied by the
    /// UI layer (NSWorkspace); core stays AppKit-free.
    public let runningBundleIDs: Set<String>
    private let locator: AssociatedFileLocator

    public init(targets: [InstalledApp], runningBundleIDs: Set<String> = [],
                libraryRoot: URL? = nil) {
        self.targets = targets
        self.runningBundleIDs = runningBundleIDs
        self.locator = AssociatedFileLocator(libraryRoot: libraryRoot)
    }

    public func scan(progress: @Sendable @escaping (Double) -> Void) async throws -> [Finding] {
        var findings: [Finding] = []
        for (index, app) in targets.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(max(targets.count, 1)))

            let isRunning = app.bundleID.map { runningBundleIDs.contains($0) } ?? false

            // The bundle itself — one opaque package finding (FR-BUNDLE).
            findings.append(locator.makeFinding(
                app.url, category: .application,
                confidence: .high, isRunning: isRunning
            ))
            // Its scattered parts.
            findings.append(contentsOf: locator.findings(
                bundleID: app.bundleID, appName: app.name, isRunning: isRunning
            ))
        }
        progress(1.0)
        return findings
    }
}

/// Leftovers of already-deleted apps (§4.4): Finder-invisible support files,
/// preferences, caches, and launch agents whose owning app no longer exists.
/// Every finding is `.low` confidence — never pre-selected — because "the app
/// is gone" is inferred, not certain (CLI tools and agents have no `.app`).
public struct LeftoversScanner: Scanner {
    public let id = "app-leftovers"
    public let category = Category.appLeftover
    public let displayName = "App Leftovers"

    public let installedBundleIDs: Set<String>
    private let locator: AssociatedFileLocator

    public init(installedBundleIDs: Set<String>? = nil, libraryRoot: URL? = nil) {
        self.installedBundleIDs = installedBundleIDs ?? AppInventory.installedBundleIDs()
        self.locator = AssociatedFileLocator(libraryRoot: libraryRoot)
    }

    public func scan(progress: @Sendable @escaping (Double) -> Void) async throws -> [Finding] {
        var findings: [Finding] = []
        let locations = LibraryLocation.all

        for (index, location) in locations.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(max(locations.count, 1)))

            let dir = locator.libraryRoot.appendingPathComponent(location.subpath)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                    .isSymbolicLink == true { continue }
                guard isLeftover(entryName: entry.lastPathComponent) else { continue }
                findings.append(locator.makeFinding(
                    entry, category: .appLeftover, confidence: .low, isRunning: false
                ))
            }
        }
        progress(1.0)
        return findings
    }

    /// Leftover = a reverse-DNS-named entry that (a) is not Apple's, and (b) no
    /// installed app claims. Conservative on purpose: anything ambiguous is
    /// simply not reported.
    func isLeftover(entryName: String) -> Bool {
        let candidate = AssociatedFileLocator.strippingKnownSuffixes(entryName)

        // Must look like a reverse-DNS identifier (com.vendor.app…).
        let components = candidate.split(separator: ".")
        guard components.count >= 3,
              components.allSatisfy({ !$0.isEmpty }),
              candidate.rangeOfCharacter(from: .whitespaces) == nil
        else { return false }

        // Never touch Apple's own state.
        if candidate.hasPrefix("com.apple.") || candidate == "com.apple" { return false }

        // Claimed by an installed app (exact or as a service/extension of it)?
        for installed in installedBundleIDs {
            if candidate == installed { return false }
            if candidate.hasPrefix(installed + ".") { return false }
            // The entry may be the *parent* of an installed helper's ID too.
            if installed.hasPrefix(candidate + ".") { return false }
        }
        return true
    }
}
