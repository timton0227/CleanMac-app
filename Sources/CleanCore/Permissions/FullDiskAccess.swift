import Foundation

/// Full Disk Access detection (FR-PERM, Infra B). macOS gates several scan
/// roots behind TCC — without the grant, directories like MobileSync read as
/// permission errors. The app must *degrade gracefully and explain*: detect
/// the state honestly, say exactly what is invisible without it, and deep-link
/// the user to the right Settings pane. Never fake an empty result.
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        /// A TCC-protected sentinel was readable — FDA (or an equivalent
        /// grant to the hosting process) is in effect.
        case granted
        /// Sentinels exist but reads are refused — the classic TCC denial.
        case denied
        /// No sentinel could prove either way (unusual installs).
        case undetermined
    }

    /// Deep link to System Settings → Privacy & Security → Full Disk Access.
    public static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// TCC-protected paths that exist on effectively every install, so
    /// "unreadable" means *denied*, not *absent*. The TCC databases themselves
    /// are the canonical probes: always present, only readable with FDA.
    public static func defaultSentinels(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"),
            home.appendingPathComponent("Library/Application Support/MobileSync/Backup",
                                        isDirectory: true),
        ]
    }

    /// One readable sentinel proves the grant; existing-but-unreadable ones
    /// prove the denial; only if nothing exists do we admit `undetermined`.
    public static func status(sentinels: [URL] = defaultSentinels()) -> Status {
        var sawBlocked = false
        for url in sentinels {
            switch probe(url) {
            case .readable: return .granted
            case .blocked: sawBlocked = true
            case .missing: continue
            }
        }
        return sawBlocked ? .denied : .undetermined
    }

    enum ProbeResult { case readable, blocked, missing }

    /// An *actual read attempt* — `access(2)`-style checks can lie under TCC;
    /// only `open`/`readdir` hit the real policy decision.
    static func probe(_ url: URL) -> ProbeResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return .missing
        }
        if isDir.boolValue {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
                return .readable
            } catch {
                return .blocked
            }
        }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return .blocked
        }
        try? handle.close()
        return .readable
    }
}
