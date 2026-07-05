import Foundation

/// Old iOS device backups (§4.10): local iPhone/iPad backups under
/// `~/Library/Application Support/MobileSync/Backup/` — frequently tens of GB
/// and stale. Scope guard: this manages backup *files on the Mac* only; it
/// never connects to or cleans a device (§8).
///
/// Policy (§4.10): every backup shows device, date, and size; the **most recent
/// backup per device is kept by default** (low confidence → never pre-selected),
/// older ones are `.medium` (pre-selected but still reviewed + confirmed).
/// Removal is the standard reversible Trash path (FR-VOL applies).
///
/// FR-PERM note: this folder is TCC-protected — without Full Disk Access the
/// directory is unreadable and the scan returns a typed error the UI explains,
/// rather than silently reporting "no backups".
public struct IOSBackupScanner: Scanner {
    public let id = "ios-backups"
    public let category = Category.iosBackup
    public let displayName = "iOS Backups"

    public enum ScanError: Error, Equatable {
        /// Root exists but is unreadable → almost certainly missing Full Disk
        /// Access (FR-PERM). Distinct from "no backups on this Mac".
        case accessDenied(path: String)
    }

    public let backupRoot: URL
    private let protectedPaths: ProtectedPaths

    public init(backupRoot: URL? = nil, protectedPaths: ProtectedPaths = ProtectedPaths()) {
        self.backupRoot = backupRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MobileSync/Backup")
        self.protectedPaths = protectedPaths
    }

    public func scan(progress: @Sendable @escaping (Double) -> Void) async throws -> [Finding] {
        progress(0)
        let fm = FileManager.default

        guard fm.fileExists(atPath: backupRoot.path) else {
            progress(1.0)
            return [] // genuinely no backups
        }
        guard let entries = try? fm.contentsOfDirectory(
            at: backupRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            // Exists but unreadable → TCC / Full Disk Access (FR-PERM).
            throw ScanError.accessDenied(path: backupRoot.path)
        }

        // First pass: read metadata for every backup directory.
        var backups: [(url: URL, info: BackupInfo)] = []
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(max(entries.count, 1)) * 0.9)

            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            backups.append((entry, Self.readInfo(from: entry)))
        }

        // Newest backup per device is the keeper (§4.10).
        var newestPerDevice: [String: Date] = [:]
        for (_, info) in backups {
            guard let date = info.lastBackupDate else { continue }
            let key = info.deviceKey
            if let existing = newestPerDevice[key], existing >= date { continue }
            newestPerDevice[key] = date
        }

        var findings: [Finding] = []
        for (url, info) in backups {
            try Task.checkCancellation()
            let isNewestForDevice = info.lastBackupDate != nil
                && newestPerDevice[info.deviceKey] == info.lastBackupDate
            // Conservative (§7): the newest per device is kept, and so is any
            // backup we can't date (damaged Info.plist) — never offer what we
            // don't understand.
            let keepByDefault = isNewestForDevice || info.lastBackupDate == nil

            let verdict = protectedPaths.verdict(for: url)
            findings.append(Finding(
                path: url,
                realOnDiskBytes: SizeAccounting.totalRealOnDiskBytes(of: url),
                logicalBytes: 0,
                category: .iosBackup,
                confidence: keepByDefault ? .low : .medium,
                safeToRemove: !verdict.isProtected,
                isProtected: verdict.isProtected,
                isCloudPlaceholder: false,
                validation: SizeAccounting.validation(of: url),
                modifiedAt: info.lastBackupDate,
                displayLabel: info.label(isNewest: isNewestForDevice)
            ))
        }

        progress(1.0)
        return findings.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    // MARK: - Metadata

    struct BackupInfo {
        var deviceName: String?
        var productType: String?
        var targetIdentifier: String?
        var lastBackupDate: Date?
        var directoryName: String

        /// Stable per-device grouping key for the keep-most-recent rule.
        var deviceKey: String {
            targetIdentifier ?? deviceName ?? directoryName
        }

        func label(isNewest: Bool) -> String {
            var parts: [String] = []
            parts.append(deviceName ?? productType ?? directoryName)
            if isNewest { parts.append("(most recent — kept by default)") }
            return parts.joined(separator: " ")
        }
    }

    /// Read `Info.plist` inside a backup directory. A backup without one is
    /// still listed (by directory name) — it may be damaged, but hiding it
    /// would misreport disk usage.
    static func readInfo(from backupDir: URL) -> BackupInfo {
        var info = BackupInfo(directoryName: backupDir.lastPathComponent)
        let plistURL = backupDir.appendingPathComponent("Info.plist")
        guard
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = plist as? [String: Any]
        else { return info }

        info.deviceName = dict["Device Name"] as? String ?? dict["Display Name"] as? String
        info.productType = dict["Product Type"] as? String
        info.targetIdentifier = dict["Target Identifier"] as? String
        info.lastBackupDate = dict["Last Backup Date"] as? Date
        return info
    }
}
