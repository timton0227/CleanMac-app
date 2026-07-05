import Foundation

/// Shared contract between the app and the privileged `CleanHelper` daemon
/// (Infra A, §3). The command set is a **closed enum** — the helper can only
/// ever be asked to do these things; "run arbitrary shell as root" is
/// unrepresentable, and anything that fails to decode is refused.
public enum HelperIPC {
    /// Mach service the daemon listens on (must match the launchd plist).
    public static let machServiceName = "com.cleanmac.helper"
    /// The launchd plist name inside `Contents/Library/LaunchDaemons/`,
    /// as `SMAppService.daemon(plistName:)` expects.
    public static let daemonPlistName = "com.cleanmac.helper.plist"
    /// Bumped when the command set changes; the app checks it via `.version`
    /// so a stale installed helper is detected, not silently mis-spoken to.
    public static let version = 1
}

/// The entire privileged surface. Each case is one narrow, auditable verb.
public enum HelperCommand: Codable, Sendable, Equatable {
    /// Handshake: report the helper's protocol version.
    case version
    /// Remove a file/directory (root scope). Permanent — the helper has no
    /// Trash; the app must present this as non-reversible (FR-SAFE-6).
    case deletePath(path: String)
    /// Enable/disable a system LaunchDaemon by renaming its plist
    /// (`.plist` ↔ `.plist.disabled`) and bootstrapping/booting-out (§4.5).
    case toggleDaemon(plistPath: String, enable: Bool)
    /// Delete one APFS local snapshot by its `YYYY-MM-DD-HHMMSS` stamp (§4.7).
    case deleteSnapshot(dateStamp: String)
}

/// Uniform reply. `message` is human-readable and shown in the UI on failure.
public struct HelperResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var message: String
    public var version: Int?

    public init(ok: Bool, message: String, version: Int? = nil) {
        self.ok = ok
        self.message = message
        self.version = version
    }

    public static func failure(_ message: String) -> HelperResponse {
        HelperResponse(ok: false, message: message)
    }
}

/// The NSXPC surface: exactly one method, carrying an encoded `HelperCommand`.
/// Keeping the enumeration in the Codable layer (not in a wide @objc protocol)
/// means the whitelist lives in one reviewable place — the enum above.
@objc public protocol HelperXPCProtocol {
    func execute(_ commandData: Data, withReply reply: @escaping (Data) -> Void)
}

/// FR-SEC-1: both sides pin the peer's code signature. The helper only accepts
/// connections satisfying the app requirement; the app only talks to a helper
/// satisfying the helper requirement — a spoofed client or a swapped-in daemon
/// fails the kernel-verified signature check, not a UI-level one.
public enum HelperSecurity {
    public static let appIdentifier = "com.cleanmac.CleanMac"
    public static let helperIdentifier = "com.cleanmac.CleanHelper"

    /// Requirement the **helper** applies to incoming clients.
    public static func clientRequirement(teamID: String? = nil) -> String {
        requirement(identifier: appIdentifier, teamID: teamID)
    }

    /// Requirement the **app** applies to the daemon it connects to.
    public static func helperRequirement(teamID: String? = nil) -> String {
        requirement(identifier: helperIdentifier, teamID: teamID)
    }

    /// Dev/ad-hoc builds pin the code identifier; distribution builds must
    /// pass the Developer ID team so the anchor is pinned too.
    static func requirement(identifier: String, teamID: String?) -> String {
        var req = #"identifier "\#(identifier)""#
        if let teamID {
            req += #" and anchor apple generic and certificate leaf[subject.OU] = "\#(teamID)""#
        }
        return req
    }
}
