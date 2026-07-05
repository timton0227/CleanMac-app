import Foundation
import Testing
@testable import CleanCore

/// §4.4 matching rules — conservative by design: a false positive here deletes
/// another app's data (the worst failure mode, §7).
struct AssociatedFileMatchingTests {
    let locator = AssociatedFileLocator()

    @Test("Exact bundle-ID and bundleID-prefixed entries match at high confidence")
    func bundleIDMatches() {
        #expect(locator.match(entryName: "com.foo.Bar", bundleID: "com.foo.Bar",
                              appName: "Bar", allowsNameMatch: true) == .high)
        #expect(locator.match(entryName: "com.foo.Bar.plist", bundleID: "com.foo.Bar",
                              appName: "Bar", allowsNameMatch: false) == .high)
        #expect(locator.match(entryName: "com.foo.Bar.savedState", bundleID: "com.foo.Bar",
                              appName: "Bar", allowsNameMatch: false) == .high)
        #expect(locator.match(entryName: "com.foo.Bar.helper.plist", bundleID: "com.foo.Bar",
                              appName: "Bar", allowsNameMatch: false) == .high)
    }

    @Test("A different app's ID never matches, even when similar")
    func noCrossAppMatches() {
        // Prefix similarity without a dot boundary must NOT match.
        #expect(locator.match(entryName: "com.foo.Barometer", bundleID: "com.foo.Bar",
                              appName: "Bar", allowsNameMatch: false) == nil)
        #expect(locator.match(entryName: "com.other.Bar", bundleID: "com.foo.Bar",
                              appName: "Bar", allowsNameMatch: false) == nil)
    }

    @Test("App-name matches are low confidence and only where allowed")
    func nameMatches() {
        #expect(locator.match(entryName: "Bar", bundleID: "com.foo.Bar",
                              appName: "Bar", allowsNameMatch: true) == .low)
        // Disallowed location (e.g. Preferences) → no name match at all.
        #expect(locator.match(entryName: "Bar", bundleID: "com.foo.Bar",
                              appName: "Bar", allowsNameMatch: false) == nil)
        // Too-short names are refused (collision risk).
        #expect(locator.match(entryName: "Go", bundleID: nil,
                              appName: "Go", allowsNameMatch: true) == nil)
    }
}

struct UninstallScannerTests {

    /// Build a fake ~/Library with entries for two apps.
    private func makeLibrary(in box: Sandbox) throws -> URL {
        try box.makeFile("data.bin", bytes: 2048, in: "Library/Application Support/com.test.gone")
        try box.makeFile("com.test.gone.plist", bytes: 128, in: "Library/Preferences")
        try box.makeFile("cache.bin", bytes: 512, in: "Library/Caches/com.test.gone")
        try box.makeFile("com.test.gone.agent.plist", bytes: 64, in: "Library/LaunchAgents")
        // Another app's data that must never be touched.
        try box.makeFile("other.bin", bytes: 512, in: "Library/Application Support/com.test.installed")
        // Apple state that must never be offered.
        try box.makeFile("apple.bin", bytes: 512, in: "Library/Caches/com.apple.something")
        return box.root.appendingPathComponent("Library")
    }

    @Test("Uninstall finds the bundle plus exactly its own associated files")
    func uninstallScan() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let library = try makeLibrary(in: box)
        // A fake .app bundle for the target.
        try box.makeFile("exec", bytes: 4096, in: "Apps/Gone.app/Contents/MacOS")

        let app = InstalledApp(
            url: box.root.appendingPathComponent("Apps/Gone.app"),
            name: "Gone", bundleID: "com.test.gone")
        let scanner = UninstallScanner(targets: [app], libraryRoot: library)
        let findings = try await scanner.scan { _ in }

        let names = Set(findings.map { $0.path.lastPathComponent })
        #expect(names == ["Gone.app", "com.test.gone", "com.test.gone.plist",
                          "com.test.gone", "com.test.gone.agent.plist"].reduce(into: Set()) { $0.insert($1) })
        // The other app's and Apple's files are untouched.
        #expect(!names.contains("com.test.installed"))
        #expect(!names.contains("com.apple.something"))
        // Bundle is one opaque finding sized from its contents.
        let bundle = try #require(findings.first { $0.category == .application })
        #expect(bundle.realOnDiskBytes >= 4096)
        // Bundle-ID matches are pre-selectable (high confidence).
        #expect(findings.filter { $0.confidence == .high }.count == findings.count)
    }

    @Test("Leftovers reports only orphaned reverse-DNS entries")
    func leftoversScan() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let library = try makeLibrary(in: box)
        // Non-reverse-DNS entries that must be ignored.
        try box.makeFile("x", in: "Library/Application Support/RandomFolder")

        let scanner = LeftoversScanner(
            installedBundleIDs: ["com.test.installed"], libraryRoot: library)
        let findings = try await scanner.scan { _ in }

        let names = Set(findings.map { $0.path.lastPathComponent })
        #expect(names == ["com.test.gone", "com.test.gone.plist",
                          "com.test.gone", "com.test.gone.agent.plist"].reduce(into: Set()) { $0.insert($1) })
        #expect(!names.contains("com.apple.something"))   // Apple excluded
        #expect(!names.contains("com.test.installed"))    // still installed
        #expect(!names.contains("RandomFolder"))          // not reverse-DNS
        // Leftovers are inferred → low confidence, never pre-selected (§7).
        #expect(findings.allSatisfy { $0.confidence == .low && !$0.defaultSelected })
    }

    @Test("Leftover rule: helpers of installed apps are not leftovers")
    func helperNotLeftover() {
        let scanner = LeftoversScanner(installedBundleIDs: ["com.foo.Bar"],
                                       libraryRoot: URL(fileURLWithPath: "/nonexistent"))
        #expect(!scanner.isLeftover(entryName: "com.foo.Bar.helper"))
        #expect(!scanner.isLeftover(entryName: "com.foo.Bar.plist"))
        // Parent of an installed helper ID is also protected.
        let scanner2 = LeftoversScanner(installedBundleIDs: ["com.foo.Bar.helper"],
                                        libraryRoot: URL(fileURLWithPath: "/nonexistent"))
        #expect(!scanner2.isLeftover(entryName: "com.foo.Bar"))
        // Genuinely orphaned entry is one.
        #expect(scanner.isLeftover(entryName: "com.gone.App"))
    }
}
