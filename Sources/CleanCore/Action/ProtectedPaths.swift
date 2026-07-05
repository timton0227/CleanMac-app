import Foundation

/// The never-touch denylist (FR-SAFE-1) and bundle-interior guard (FR-BUNDLE).
///
/// This is the single most safety-critical component: it is consulted by the
/// `ActionEngine` before *every* removal, so a mistake here can delete the wrong
/// thing for every scanner at once (§2). In the shipping app this logic lives in
/// the privileged helper (§3) so a compromised UI cannot bypass it; the engine
/// is the enforcement boundary until then.
public struct ProtectedPaths: Sendable {
    public struct Verdict: Sendable, Equatable {
        public let isProtected: Bool
        public let reason: String?
        public static let allowed = Verdict(isProtected: false, reason: nil)
        public static func refused(_ reason: String) -> Verdict {
            Verdict(isProtected: true, reason: reason)
        }
    }

    /// Absolute path prefixes that may never be removed (SIP + system-critical).
    public let protectedPrefixes: [String]
    /// Directories that must never themselves be deleted (roots), even though
    /// items *within* some of them are fair game.
    public let protectedExactPaths: [String]
    /// Extensions that mark a file-system package/bundle (FR-BUNDLE). Deleting a
    /// file *inside* one of these is refused; the package as a whole may be a
    /// valid target (e.g. uninstalling an `.app`).
    public let packageExtensions: Set<String>

    public init(
        protectedPrefixes: [String]? = nil,
        protectedExactPaths: [String]? = nil,
        packageExtensions: Set<String>? = nil
    ) {
        self.protectedPrefixes = protectedPrefixes ?? Self.defaultPrefixes
        self.protectedExactPaths = protectedExactPaths ?? Self.defaultExactPaths
        self.packageExtensions = packageExtensions ?? Self.defaultPackageExtensions
    }

    /// SIP-protected / system-critical locations (§3, FR-SAFE-1).
    public static let defaultPrefixes: [String] = [
        "/System",
        "/bin",
        "/sbin",
        "/usr",            // note: /usr/local is carved back out below
        "/Library/Apple",
        "/private/var/db",
        "/private/var/protected",
        "/Applications/Utilities",
        "/cores",
        "/.vol",
    ]

    /// Prefixes explicitly re-allowed even though a broader prefix covers them.
    public static let allowedExceptions: [String] = [
        "/usr/local",
    ]

    public static let defaultExactPaths: [String] = [
        "/",
        "/System",
        "/Library",
        "/Applications",
        "/Users",
        "/private",
        "/private/var",
        "/Volumes",
    ]

    public static let defaultPackageExtensions: Set<String> = [
        "app", "photoslibrary", "rtfd", "pkg", "mpkg", "bundle",
        "plugin", "kext", "framework", "appex", "xpc", "aplibrary",
        "tvlibrary", "theatre", "musiclibrary", "photoslibrary",
    ]

    /// The engine's gate. Returns `.refused` with a reason for anything on the
    /// denylist, a volume/home root, or a file inside a package.
    public func verdict(for url: URL) -> Verdict {
        let std = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = std.path

        if path.isEmpty || path == "/" {
            return .refused("refuses to act on filesystem root")
        }

        // Home directory root itself is never a delete target.
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.resolvingSymlinksInPath().path
        if caseInsensitiveEquals(path, home) {
            return .refused("refuses to remove the home directory root")
        }

        for exact in protectedExactPaths where caseInsensitiveEquals(path, exact) {
            return .refused("system-critical directory: \(exact)")
        }

        // Re-allow explicit exceptions before the broad prefix test.
        let isExcepted = Self.allowedExceptions.contains { hasPathPrefix(path, $0) }
        if !isExcepted {
            for prefix in protectedPrefixes where hasPathPrefix(path, prefix) {
                return .refused("protected system location: \(prefix)")
            }
        }

        // FR-BUNDLE: refuse deleting a file *inside* a recognized package.
        if let pkg = enclosingPackage(of: std) {
            return .refused("inside package bundle (would corrupt it): \(pkg.lastPathComponent)")
        }

        return .allowed
    }

    public func isProtected(_ url: URL) -> Bool {
        verdict(for: url).isProtected
    }

    // MARK: - Path helpers

    /// Whether `path` equals or is nested under `prefix`, boundary-aware so that
    /// `/usr` does not match `/usration`. Case-insensitive to over-refuse on the
    /// safe side (APFS default is case-insensitive; §4.3).
    private func hasPathPrefix(_ path: String, _ prefix: String) -> Bool {
        if caseInsensitiveEquals(path, prefix) { return true }
        let boundedPrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
        return path.lowercased().hasPrefix(boundedPrefix.lowercased())
    }

    private func caseInsensitiveEquals(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .caseInsensitive) == .orderedSame
    }

    /// Nearest ancestor (excluding `url` itself) that is a package. Returns nil
    /// if the item is not inside any package.
    private func enclosingPackage(of url: URL) -> URL? {
        var current = url.deletingLastPathComponent()
        let root = URL(fileURLWithPath: "/")
        while current.path != root.path && current.path != "" {
            if packageExtensions.contains(current.pathExtension.lowercased()) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }
}
