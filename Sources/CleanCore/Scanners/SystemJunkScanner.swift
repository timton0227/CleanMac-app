import Foundation

/// System Junk / Cache scanner (§4.1) — the MVP's one active scanner. Walks the
/// FR-DEFS ruleset's user-level roots, sizing each top-level entry with real
/// on-disk bytes (§4.2), never following symlinks (§4.3), treating packages as
/// opaque (FR-BUNDLE), and applying age + blacklist gates so in-use files are
/// left alone (§4.1). Emits proposals only — the `ActionEngine` does the rest.
public struct SystemJunkScanner: Scanner {
    public let id = "system-junk"
    public let category = Category.userCache
    public let displayName = "System Junk"

    private let rulesURL: URL?
    private let protectedPaths: ProtectedPaths

    public init(rulesURL: URL? = nil, protectedPaths: ProtectedPaths = ProtectedPaths()) {
        self.rulesURL = rulesURL
        self.protectedPaths = protectedPaths
    }

    public func scan(progress: @Sendable @escaping (Double) -> Void) async throws -> [Finding] {
        let ruleSet = try JunkRuleSet.load(from: rulesURL)
        var findings: [Finding] = []
        let now = Date()

        for (index, rule) in ruleSet.rules.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(max(ruleSet.rules.count, 1)))

            let root = rule.expandedRoot
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                try Task.checkCancellation()
                if let finding = evaluate(entry, rule: rule, now: now) {
                    findings.append(finding)
                }
            }
        }

        progress(1.0)
        return findings
    }

    private func evaluate(_ url: URL, rule: JunkRule, now: Date) -> Finding? {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }

        // §4.3 safety: never follow symlinks.
        if values.isSymbolicLink == true { return nil }

        // Extension filter (broken-downloads rule).
        if let exts = rule.matchExtensions,
           !exts.contains(url.pathExtension.lowercased()) {
            return nil
        }

        // Blacklist (§4.1 whitelist/blacklist).
        let path = url.path
        if rule.excludeContains.contains(where: { path.localizedCaseInsensitiveContains($0) }) {
            return nil
        }

        // Age gate — leave recently-touched (likely in-use) items alone.
        if rule.minAgeDays > 0, let modified = values.contentModificationDate {
            let ageDays = now.timeIntervalSince(modified) / 86_400
            if ageDays < Double(rule.minAgeDays) { return nil }
        }

        let realBytes = SizeAccounting.totalRealOnDiskBytes(of: url)
        let logical = SizeAccounting.logicalBytes(of: url)
        let isCloud = SizeAccounting.isCloudPlaceholder(of: url)
        let validation = SizeAccounting.validation(of: url)
        let protectedVerdict = protectedPaths.verdict(for: url)

        return Finding(
            path: url,
            realOnDiskBytes: realBytes,
            logicalBytes: logical,
            category: rule.category,
            confidence: rule.confidence,
            safeToRemove: !protectedVerdict.isProtected,
            isProtected: protectedVerdict.isProtected,
            isCloudPlaceholder: isCloud,
            ownedByRunningProcess: false,
            validation: validation
        )
    }
}
