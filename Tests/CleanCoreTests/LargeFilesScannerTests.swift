import Foundation
import Testing
@testable import CleanCore

/// LargeOldFilesScanner (§4.2): size threshold, symlink safety, package
/// atomicity (FR-BUNDLE), low-confidence default-unselected, and date capture.
struct LargeFilesScannerTests {

    private func scanner(root: URL, minBytes: Int64) -> LargeOldFilesScanner {
        LargeOldFilesScanner(roots: [root], minBytes: minBytes)
    }

    @Test("Only files at or above the threshold are reported, with dates")
    func threshold() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.makeFile("big.bin", bytes: 20_000, in: "scan")
        try box.makeFile("small.bin", bytes: 1_000, in: "scan")
        try box.makeFile("nested-big.bin", bytes: 30_000, in: "scan/sub/deeper")

        let root = box.root.appendingPathComponent("scan")
        let findings = try await scanner(root: root, minBytes: 10_000).scan { _ in }

        let names = Set(findings.map { $0.path.lastPathComponent })
        #expect(names == ["big.bin", "nested-big.bin"])
        #expect(findings.allSatisfy { $0.category == .largeFile })
        #expect(findings.allSatisfy { $0.modifiedAt != nil })
    }

    @Test("Large files are never pre-selected (user data, low confidence)")
    func neverPreselected() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.makeFile("huge.bin", bytes: 50_000, in: "scan")

        let root = box.root.appendingPathComponent("scan")
        let findings = try await scanner(root: root, minBytes: 10_000).scan { _ in }

        #expect(findings.count == 1)
        #expect(findings.allSatisfy { $0.confidence == .low })
        #expect(findings.allSatisfy { !$0.defaultSelected })
    }

    @Test("Symlinks are not followed or reported")
    func symlinks() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.makeFile("real.bin", bytes: 20_000, in: "scan")
        // Big file outside the scan root, reachable only via symlink.
        let outside = try box.makeFile("outside.bin", bytes: 20_000, in: "elsewhere")
        try FileManager.default.createSymbolicLink(
            at: box.root.appendingPathComponent("scan/link.bin"),
            withDestinationURL: outside)

        let root = box.root.appendingPathComponent("scan")
        let findings = try await scanner(root: root, minBytes: 10_000).scan { _ in }

        let names = Set(findings.map { $0.path.lastPathComponent })
        #expect(names == ["real.bin"])
    }

    @Test("A package is reported whole; its internals are never enumerated (FR-BUNDLE)")
    func packageAtomicity() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        // .app is a package extension recognized by LaunchServices everywhere.
        try box.makeFile("payload1.bin", bytes: 20_000, in: "scan/Fake.app/Contents")
        try box.makeFile("payload2.bin", bytes: 20_000, in: "scan/Fake.app/Contents/MacOS")

        let root = box.root.appendingPathComponent("scan")
        let findings = try await scanner(root: root, minBytes: 10_000).scan { _ in }

        // Exactly one finding: the package itself, sized as the sum of contents.
        #expect(findings.count == 1)
        let pkg = try #require(findings.first)
        #expect(pkg.path.lastPathComponent == "Fake.app")
        #expect(pkg.realOnDiskBytes >= 40_000)
        // Its interior is protected from partial deletion by the engine too.
        #expect(ProtectedPaths().isProtected(
            pkg.path.appendingPathComponent("Contents/payload1.bin")))
    }
}
