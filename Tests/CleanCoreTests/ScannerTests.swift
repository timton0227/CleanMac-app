import Foundation
import Testing
@testable import CleanCore

/// SystemJunkScanner (§4.1): finds top-level junk entries, never follows
/// symlinks (§4.3), honors the age gate and blacklist, and drives everything
/// off the FR-DEFS ruleset (no hard-coded paths).
struct ScannerTests {

    /// Write a rules file pointing at a sandbox directory (absolute root passes
    /// through `expandedRoot` unchanged).
    private func writeRules(root: URL, in box: Sandbox,
                            minAgeDays: Int = 0, exclude: [String] = []) throws -> URL {
        let payload: [String: Any] = [
            "version": 1,
            "rules": [[
                "id": "test-cache",
                "category": "userCache",
                "confidence": "high",
                "root": root.path,
                "minAgeDays": minAgeDays,
                "excludeContains": exclude,
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let url = box.root.appendingPathComponent("rules.json")
        try data.write(to: url)
        return url
    }

    @Test("Scans top-level entries and skips symlinks")
    func scansAndSkipsSymlinks() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let cacheRoot = box.root.appendingPathComponent("Caches", isDirectory: true)
        try box.makeFile("keep", bytes: 2048, in: "Caches/appA")
        try box.makeFile("keep", bytes: 2048, in: "Caches/appB")

        // A symlink that must not be followed or reported.
        let target = box.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: cacheRoot.appendingPathComponent("link"), withDestinationURL: target)

        let rules = try writeRules(root: cacheRoot, in: box)
        let scanner = SystemJunkScanner(rulesURL: rules)
        let findings = try await scanner.scan { _ in }

        let names = Set(findings.map { $0.path.lastPathComponent })
        #expect(names == ["appA", "appB"])
        #expect(!names.contains("link"))
        #expect(findings.allSatisfy { $0.category == .userCache })
        #expect(findings.allSatisfy { $0.realOnDiskBytes > 0 })
    }

    @Test("Blacklist excludes matching entries")
    func blacklist() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let cacheRoot = box.root.appendingPathComponent("Caches", isDirectory: true)
        try box.makeFile("f", in: "Caches/com.apple.keepme")
        try box.makeFile("f", in: "Caches/com.other.app")

        let rules = try writeRules(root: cacheRoot, in: box, exclude: ["com.apple"])
        let scanner = SystemJunkScanner(rulesURL: rules)
        let findings = try await scanner.scan { _ in }

        let names = Set(findings.map { $0.path.lastPathComponent })
        #expect(names == ["com.other.app"])
    }

    @Test("Bundled ruleset decodes (FR-DEFS)")
    func bundledRulesDecode() throws {
        let set = try JunkRuleSet.load()
        #expect(set.version >= 1)
        #expect(!set.rules.isEmpty)
    }
}
