import Foundation
import Testing
@testable import CleanCore

/// IOSBackupScanner (§4.10): metadata parsing, keep-most-recent-per-device
/// policy, damaged-backup visibility, and FR-PERM access-denied signaling.
struct IOSBackupTests {

    /// Create a fixture backup dir with an Info.plist.
    private func makeBackup(
        _ dirName: String, device: String, udid: String, date: Date,
        bytes: Int, in box: Sandbox
    ) throws {
        let dir = "Backups/\(dirName)"
        try box.makeFile("payload.db", bytes: bytes, in: dir)
        let plist: [String: Any] = [
            "Device Name": device,
            "Target Identifier": udid,
            "Product Type": "iPhone16,1",
            "Last Backup Date": date,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: box.root.appendingPathComponent("\(dir)/Info.plist"))
    }

    @Test("Most recent backup per device is kept by default; older are offered")
    func keepMostRecent() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let now = Date()
        try makeBackup("AAAA-1", device: "Thien's iPhone", udid: "UDID-A",
                       date: now, bytes: 4096, in: box)
        try makeBackup("AAAA-1-20250101", device: "Thien's iPhone", udid: "UDID-A",
                       date: now.addingTimeInterval(-90 * 86_400), bytes: 4096, in: box)
        try makeBackup("BBBB-2", device: "Old iPad", udid: "UDID-B",
                       date: now.addingTimeInterval(-400 * 86_400), bytes: 4096, in: box)

        let scanner = IOSBackupScanner(backupRoot: box.root.appendingPathComponent("Backups"))
        let findings = try await scanner.scan { _ in }

        #expect(findings.count == 3)
        // Newest per device (iPhone's `now`, iPad's only backup) → .low, unselected.
        let keepers = findings.filter { $0.confidence == .low }
        #expect(keepers.count == 2)
        #expect(keepers.allSatisfy { !$0.defaultSelected })
        #expect(keepers.allSatisfy { $0.displayLabel?.contains("most recent") == true })
        // The stale iPhone backup is offered (.medium → pre-selected).
        let offered = findings.filter { $0.confidence == .medium }
        #expect(offered.count == 1)
        #expect(offered.allSatisfy { $0.defaultSelected })
        #expect(offered.first?.displayLabel?.contains("Thien's iPhone") == true)
        // Sizes are real.
        #expect(findings.allSatisfy { $0.realOnDiskBytes >= 4096 })
    }

    @Test("A backup without Info.plist is still listed, by directory name")
    func damagedBackupVisible() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.makeFile("blob.bin", bytes: 2048, in: "Backups/0000-DAMAGED")

        let scanner = IOSBackupScanner(backupRoot: box.root.appendingPathComponent("Backups"))
        let findings = try await scanner.scan { _ in }

        #expect(findings.count == 1)
        #expect(findings.first?.displayLabel?.contains("0000-DAMAGED") == true)
        #expect(findings.first?.confidence == .low) // no date → treated as keeper
    }

    @Test("Missing backups folder means no findings, not an error")
    func missingFolder() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let scanner = IOSBackupScanner(backupRoot: box.root.appendingPathComponent("Nope"))
        let findings = try await scanner.scan { _ in }
        #expect(findings.isEmpty)
    }

    @Test("Unreadable backups folder raises accessDenied (FR-PERM)")
    func accessDenied() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let root = box.root.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Remove all permissions to simulate TCC denial.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        let scanner = IOSBackupScanner(backupRoot: root)
        do {
            _ = try await scanner.scan { _ in }
            Issue.record("expected accessDenied to be thrown")
        } catch let error as IOSBackupScanner.ScanError {
            #expect(error == .accessDenied(path: root.path))
        }
    }
}
