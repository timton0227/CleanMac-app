import Foundation
import Testing
@testable import CleanCore

/// FDA detection (FR-PERM): the status must come from real read attempts on
/// sentinel paths, and the three-way outcome must be honest — readable proves
/// the grant, existing-but-unreadable proves the denial, absence proves nothing.
struct FullDiskAccessTests {

    @Test("A readable sentinel yields .granted")
    func granted() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let ok = try box.makeFile("sentinel.db", bytes: 16, in: "tcc")
        #expect(FullDiskAccess.status(sentinels: [ok]) == .granted)
    }

    @Test("Existing-but-unreadable sentinels yield .denied (TCC-style refusal)")
    func denied() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let locked = try box.makeFile("locked.db", bytes: 16, in: "tcc")
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: locked.path)
        }
        #expect(FullDiskAccess.status(sentinels: [locked]) == .denied)
    }

    @Test("Missing sentinels yield .undetermined, never a fake verdict")
    func undetermined() async throws {
        let ghost = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/tcc.db")
        #expect(FullDiskAccess.status(sentinels: [ghost]) == .undetermined)
        #expect(FullDiskAccess.status(sentinels: []) == .undetermined)
    }

    @Test("One readable sentinel wins over blocked ones (any grant proves FDA)")
    func grantWins() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let locked = try box.makeFile("locked.db", bytes: 16, in: "tcc")
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: locked.path)
        }
        let open = try box.makeFile("open.db", bytes: 16, in: "tcc")
        #expect(FullDiskAccess.status(sentinels: [locked, open]) == .granted)
    }

    @Test("Directory sentinels are probed by listing, not stat")
    func directorySentinel() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        _ = try box.makeFile("Info.plist", bytes: 8, in: "Backup/b")
        let dir = box.root.appendingPathComponent("Backup", isDirectory: true)
        #expect(FullDiskAccess.status(sentinels: [dir]) == .granted)
    }
}
