import Foundation

/// One launchd item (§4.5): a LaunchAgent or LaunchDaemon plist.
public struct StartupItem: Sendable, Identifiable, Hashable {
    public enum Domain: String, Sendable {
        case userAgent      // ~/Library/LaunchAgents — toggleable at user privilege
        case systemAgent    // /Library/LaunchAgents — needs admin (Infra A)
        case systemDaemon   // /Library/LaunchDaemons — needs admin (Infra A)

        public var displayName: String {
            switch self {
            case .userAgent: return "Your Launch Agents"
            case .systemAgent: return "System-wide Launch Agents"
            case .systemDaemon: return "System-wide Launch Daemons"
            }
        }
    }

    /// Signature status of the item's executable (§4.5 "flag unsigned items").
    public enum SignatureStatus: String, Sendable {
        case signed
        case unsigned        // suspicious: unsigned code launching at login
        case binaryMissing   // suspicious: orphaned agent, program gone
        case unknown         // no program key / not checkable
    }

    public var id: URL { plistURL }
    /// Current on-disk location (has a `.disabled` suffix when disabled).
    public let plistURL: URL
    public let label: String
    public let programPath: String?
    public let domain: Domain
    public let isEnabled: Bool
    /// Honest impact indicators (§6 forbids fake "startup ms" numbers):
    public let runAtLoad: Bool     // launches at login
    public let keepAlive: Bool     // relaunched whenever it exits
    public let signature: SignatureStatus

    /// Whether this build can toggle it (user domain only until Infra A).
    public var isToggleable: Bool { domain == .userAgent }
    public var isSuspicious: Bool { signature == .unsigned || signature == .binaryMissing }

    /// Bridge into the shared pipeline for engine-audited toggling.
    public func asFinding() -> Finding {
        Finding(
            path: plistURL, realOnDiskBytes: 0, logicalBytes: 0,
            category: .startupItem, confidence: .high,
            safeToRemove: isToggleable, isProtected: false,
            isCloudPlaceholder: false, displayLabel: label
        )
    }
}

/// Lists launchd items across domains (§4.5). Like the login-item surface in
/// System Settings, but including what Settings hides: raw agents/daemons with
/// their signature state. Listing is read-only; toggling goes through
/// `StartupOps` + the engine.
public enum StartupInventory {
    public static func defaultRoots() -> [(URL, StartupItem.Domain)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon),
        ]
    }

    /// `checkSignatures: false` skips the (subprocess-based) codesign check —
    /// used by tests and fast refreshes.
    public static func list(
        roots: [(URL, StartupItem.Domain)]? = nil,
        checkSignatures: Bool = true
    ) -> [StartupItem] {
        var items: [StartupItem] = []
        for (root, domain) in roots ?? defaultRoots() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                    .isSymbolicLink == true { continue }
                let name = entry.lastPathComponent
                let isDisabled = name.hasSuffix(".plist.disabled")
                guard name.hasSuffix(".plist") || isDisabled else { continue }
                guard let item = parse(entry, domain: domain, isEnabled: !isDisabled,
                                       checkSignature: checkSignatures) else { continue }
                items.append(item)
            }
        }
        return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    static func parse(_ plistURL: URL, domain: StartupItem.Domain,
                      isEnabled: Bool, checkSignature: Bool) -> StartupItem? {
        guard
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = plist as? [String: Any]
        else { return nil }

        let label = dict["Label"] as? String
            ?? plistURL.deletingPathExtension().lastPathComponent
        let program = dict["Program"] as? String
            ?? (dict["ProgramArguments"] as? [Any])?.first as? String
        let runAtLoad = dict["RunAtLoad"] as? Bool ?? false
        // KeepAlive can be Bool or a condition dictionary — both mean "kept alive".
        let keepAlive: Bool = {
            if let b = dict["KeepAlive"] as? Bool { return b }
            return dict["KeepAlive"] is [String: Any]
        }()

        return StartupItem(
            plistURL: plistURL, label: label, programPath: program,
            domain: domain, isEnabled: isEnabled,
            runAtLoad: runAtLoad, keepAlive: keepAlive,
            signature: signatureStatus(of: program, check: checkSignature)
        )
    }

    static func signatureStatus(of programPath: String?,
                                check: Bool) -> StartupItem.SignatureStatus {
        guard let programPath, !programPath.isEmpty else { return .unknown }
        guard FileManager.default.fileExists(atPath: programPath) else { return .binaryMissing }
        guard check else { return .unknown }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", programPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return .unknown }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? .signed : .unsigned
    }
}

/// The toggle mutation (§4.5): reversible by construction — disable renames the
/// plist to `.plist.disabled` (and boots the job out of launchd), enable renames
/// it back (and bootstraps it). Always invoked through the engine's audited
/// path, never directly by the UI.
public enum StartupOps {
    public enum ToggleError: Error, Equatable {
        case needsAdmin          // system domain — Infra A required
        case alreadyInState
        case fileMissing
    }

    public static let disabledSuffix = ".disabled"

    /// Returns the item's new plist URL after the toggle.
    @discardableResult
    public static func setEnabled(
        _ item: StartupItem, enabled: Bool,
        manageLaunchd: Bool = true
    ) throws -> URL {
        guard item.isToggleable else { throw ToggleError.needsAdmin }
        guard item.isEnabled != enabled else { throw ToggleError.alreadyInState }
        let fm = FileManager.default
        guard fm.fileExists(atPath: item.plistURL.path) else { throw ToggleError.fileMissing }

        if enabled {
            // foo.plist.disabled → foo.plist, then bootstrap.
            let target = URL(fileURLWithPath: String(
                item.plistURL.path.dropLast(Self.disabledSuffix.count)))
            try fm.moveItem(at: item.plistURL, to: target)
            if manageLaunchd { runLaunchctl(["bootstrap", "gui/\(getuid())", target.path]) }
            return target
        } else {
            // Boot out first (best-effort), then foo.plist → foo.plist.disabled.
            if manageLaunchd { runLaunchctl(["bootout", "gui/\(getuid())/\(item.label)"]) }
            let target = URL(fileURLWithPath: item.plistURL.path + Self.disabledSuffix)
            try fm.moveItem(at: item.plistURL, to: target)
            return target
        }
    }

    /// Best-effort: launchd state converges at next login even if this fails
    /// (e.g. the job wasn't loaded); the on-disk rename is the source of truth.
    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
