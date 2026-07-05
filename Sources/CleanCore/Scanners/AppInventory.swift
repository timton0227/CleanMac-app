import Foundation

/// An installed application, as discovered on disk.
public struct InstalledApp: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let bundleID: String?

    public init(url: URL, name: String, bundleID: String?) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
    }
}

/// Enumerates installed applications (§4.4). Used both to list uninstall
/// targets and — inverted — to decide what counts as a *leftover*: a Library
/// entry whose owning app no longer exists anywhere in the inventory.
public enum AppInventory {
    /// Default search roots: system-wide and per-user Applications folders.
    public static func defaultRoots() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    /// All `.app` bundles in the given roots (one level of subfolders deep,
    /// matching how /Applications is organized). Bundles are never entered
    /// beyond reading their Info.plist (FR-BUNDLE).
    public static func installedApps(in roots: [URL]? = nil) -> [InstalledApp] {
        let fm = FileManager.default
        var apps: [InstalledApp] = []

        for root in roots ?? defaultRoots() {
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                if entry.pathExtension == "app" {
                    apps.append(app(at: entry))
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                            .isDirectory == true {
                    // One level of subfolders (e.g. /Applications/Utilities).
                    let nested = (try? fm.contentsOfDirectory(
                        at: entry, includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles])) ?? []
                    for sub in nested where sub.pathExtension == "app" {
                        apps.append(app(at: sub))
                    }
                }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The set of bundle identifiers currently installed — the "still exists"
    /// test for the leftovers scan.
    public static func installedBundleIDs(in roots: [URL]? = nil) -> Set<String> {
        Set(installedApps(in: roots).compactMap(\.bundleID))
    }

    private static func app(at url: URL) -> InstalledApp {
        let name = url.deletingPathExtension().lastPathComponent
        let bundleID = Bundle(url: url)?.bundleIdentifier
        return InstalledApp(url: url, name: name, bundleID: bundleID)
    }
}
