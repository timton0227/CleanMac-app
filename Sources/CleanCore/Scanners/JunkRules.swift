import Foundation

/// A single junk-path definition from the signed, remote-updatable ruleset
/// (FR-DEFS). Never hard-coded in the binary — decoded from `junk-rules.json`.
public struct JunkRule: Decodable, Sendable {
    public let id: String
    public let category: Category
    public let confidence: Confidence
    /// Root directory whose *top-level* entries are candidate junk. A leading
    /// `~` expands to the current user's home.
    public let root: String
    /// Skip entries modified within this many days (avoids in-use files).
    public let minAgeDays: Int
    /// Skip entries whose path contains any of these substrings (blacklist).
    public let excludeContains: [String]
    /// If present, only entries with one of these extensions match (e.g. the
    /// broken-downloads rule matching `.download`/`.crdownload`/`.part`).
    public let matchExtensions: [String]?

    private enum CodingKeys: String, CodingKey {
        case id, category, confidence, root, minAgeDays, excludeContains, matchExtensions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decode(Category.self, forKey: .category)
        confidence = Confidence(name: try c.decode(String.self, forKey: .confidence))
        root = try c.decode(String.self, forKey: .root)
        minAgeDays = try c.decodeIfPresent(Int.self, forKey: .minAgeDays) ?? 0
        excludeContains = try c.decodeIfPresent([String].self, forKey: .excludeContains) ?? []
        matchExtensions = try c.decodeIfPresent([String].self, forKey: .matchExtensions)
    }

    /// Absolute root with `~` expanded.
    public var expandedRoot: URL {
        if root == "~" || root.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let rest = root == "~" ? "" : String(root.dropFirst(2))
            return home.appendingPathComponent(rest)
        }
        return URL(fileURLWithPath: root)
    }
}

public struct JunkRuleSet: Decodable, Sendable {
    public let version: Int
    public let rules: [JunkRule]

    /// Load the bundled ruleset, or a caller-supplied URL (for a remote-updated
    /// or test ruleset).
    public static func load(from url: URL? = nil) throws -> JunkRuleSet {
        let resolved = try url ?? bundledURL()
        let data = try Data(contentsOf: resolved)
        return try JSONDecoder().decode(JunkRuleSet.self, from: data)
    }

    private static func bundledURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "junk-rules", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}

extension Confidence {
    init(name: String) {
        switch name.lowercased() {
        case "high": self = .high
        case "medium": self = .medium
        default: self = .low
        }
    }
}
