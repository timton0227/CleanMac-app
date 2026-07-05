import Foundation
import Testing
@testable import CleanCore

/// PrivacyScanner (§4.6): never pre-selected, running-owner flagging, glob
/// expansion, and permanent purge through the engine's non-reversible path.
struct PrivacyScannerTests {

    private func artifact(_ id: String, owner: String = "TestApp",
                          bundleIDs: [String] = [], paths: [String]) -> PrivacyArtifact {
        PrivacyArtifact(id: id, title: id, ownerName: owner,
                        ownerBundleIDs: bundleIDs, paths: paths)
    }

    @Test("Privacy findings are never pre-selected, whatever the match certainty")
    func neverPreselected() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let history = try box.makeFile("History.db", bytes: 2048)

        let scanner = PrivacyScanner(
            artifacts: [artifact("hist", paths: [history.path])])
        let findings = try await scanner.scan { _ in }

        #expect(findings.count == 1)
        #expect(findings.allSatisfy { $0.confidence == .low && !$0.defaultSelected })
        #expect(findings.first?.displayLabel?.contains("TestApp") == true)
    }

    @Test("Missing artifacts are simply absent; present ones carry real sizes")
    func onlyExisting() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let real = try box.makeFile("Cookies", bytes: 4096)
        let missing = box.root.appendingPathComponent("NotThere.db").path

        let scanner = PrivacyScanner(artifacts: [
            artifact("real", paths: [real.path]),
            artifact("gone", paths: [missing]),
        ])
        let findings = try await scanner.scan { _ in }

        #expect(findings.count == 1)
        #expect(findings.first?.realOnDiskBytes ?? 0 >= 4096)
    }

    @Test("A running owner marks its artifacts as in-use")
    func runningOwnerFlagged() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let db = try box.makeFile("places.sqlite", bytes: 1024)

        let scanner = PrivacyScanner(
            artifacts: [artifact("ff", bundleIDs: ["org.mozilla.firefox"],
                                 paths: [db.path])],
            runningBundleIDs: ["org.mozilla.firefox"])
        let findings = try await scanner.scan { _ in }

        #expect(findings.first?.ownedByRunningProcess == true)
    }

    @Test("A single * component expands across profile directories")
    func globExpansion() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        _ = try box.makeFile("places.sqlite", bytes: 512, in: "Profiles/abc.default")
        _ = try box.makeFile("places.sqlite", bytes: 512, in: "Profiles/xyz.dev-edition")
        _ = try box.makeFile("other.txt", bytes: 512, in: "Profiles/abc.default")

        let pattern = box.root.appendingPathComponent("Profiles").path + "/*/places.sqlite"
        let scanner = PrivacyScanner(artifacts: [artifact("ff", paths: [pattern])])
        let findings = try await scanner.scan { _ in }

        #expect(findings.count == 2)
        #expect(findings.allSatisfy { $0.path.lastPathComponent == "places.sqlite" })
    }

    @Test("Purge removes permanently through the engine, audit-logged, no Trash")
    func purgeIsPermanentAndLogged() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let (engine, log, _) = try box.makeEngine()
        let history = try box.makeFile("History.db", bytes: 2048)

        let scanner = PrivacyScanner(artifacts: [artifact("hist", paths: [history.path])])
        let findings = try await scanner.scan { _ in }

        let report = await engine.performNonReversible(findings) { finding in
            try FileManager.default.removeItem(at: finding.path)
        }

        #expect(report.completed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: history.path))
        // Gone for good: no trashPath anywhere, but the audit trail exists.
        let record = try #require(try log.currentRecords().first)
        #expect(record.state == .completed)
        #expect(record.trashPath == nil)
        #expect(record.category == .privacyArtifact)
    }
}
