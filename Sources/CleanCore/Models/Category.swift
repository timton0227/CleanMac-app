import Foundation

/// Broad grouping a finding belongs to. Drives Review grouping (§4.1) and the
/// per-category status shown instead of an opaque "system score" (§6).
public enum Category: String, Sendable, Codable, CaseIterable {
    case userCache
    case appLogs
    case crashReports
    case browserCache
    case tempFiles
    case trash
    case developerJunk
    case languagePacks
    case brokenDownloads
    case largeFile
    case oldFile
    case snapshot
    case application
    case appLeftover
    case iosBackup
    case duplicate
    case startupItem
    case privacyArtifact
    case storageItem

    /// Human-readable, localizable label. (Localization is an NFR, §7 — this is
    /// the English base table.)
    public var displayName: String {
        switch self {
        case .userCache: return "User Caches"
        case .appLogs: return "System Logs & Crash Reports"
        case .crashReports: return "System Logs & Crash Reports"
        case .browserCache: return "Browser Caches"
        case .tempFiles: return "Temporary Files"
        case .trash: return "Trash"
        case .developerJunk: return "Xcode Junk"
        case .languagePacks: return "Unused Language Packs"
        case .brokenDownloads: return "Broken Downloads"
        case .largeFile: return "Large Files"
        case .oldFile: return "Old Files"
        case .snapshot: return "Local Snapshots"
        case .application: return "Applications"
        case .appLeftover: return "App Leftovers"
        case .iosBackup: return "iOS Backups"
        case .duplicate: return "Duplicates"
        case .startupItem: return "Startup Items"
        case .privacyArtifact: return "Privacy Artifacts"
        case .storageItem: return "Storage Items"
        }
    }
}

/// How sure the scanner is that an item is safe to remove. Low-confidence items
/// are defaulted *unselected* in Review (§7, "Safety first").
public enum Confidence: Int, Sendable, Codable, Comparable {
    case low = 0
    case medium = 1
    case high = 2

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
