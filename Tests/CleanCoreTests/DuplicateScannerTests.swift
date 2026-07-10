import Foundation
import Testing
@testable import CleanCore

/// DuplicateScanner (§4.3): content-hash grouping, keep-newest keeper policy,
/// hardlink/symlink correctness, and folder-scoped scanning.
struct DuplicateScannerTests {

    private func write(_ name: String, content: Data, in dir: URL,
                       modified: Date? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try content.write(to: url)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func scanner(_ roots: [URL], minBytes: Int64 = 1) -> DuplicateScanner {
        DuplicateScanner(roots: roots, minBytes: minBytes)
    }

    @Test("Identical content groups; newest copy is kept and never offered")
    func groupsAndKeeper() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let dir = box.root.appendingPathComponent("scope")
        let content = Data(repeating: 0x5A, count: 4096)
        let old = Date(timeIntervalSinceNow: -86_400 * 30)
        _ = try write("copy-old.bin", content: content, in: dir, modified: old)
        _ = try write("copy-older.bin", content: content, in: dir,
                      modified: old.addingTimeInterval(-86_400))
        let newest = try write("copy-new.bin", content: content, in: dir, modified: Date())
        // A unique file that must not appear.
        _ = try write("unique.bin", content: Data(repeating: 0x01, count: 4096), in: dir)

        let findings = try await scanner([dir]).scan { _ in }

        // 3 identical copies → 3 findings: the keeper (shown, never offered)
        // plus the 2 removable copies.
        let names = Set(findings.map { $0.path.lastPathComponent })
        #expect(names == ["copy-old.bin", "copy-older.bin", "copy-new.bin"])
        #expect(!names.contains("unique.bin"))

        let keeper = findings.first { $0.path.lastPathComponent == newest.lastPathComponent }
        #expect(keeper?.isKeeper == true)
        #expect(keeper?.isProtected == true)
        #expect(keeper?.defaultSelected == false)

        // The suggested removal set is pre-selected; label points at the keeper.
        let removable = findings.filter { !$0.isKeeper }
        #expect(removable.count == 2)
        #expect(removable.allSatisfy { $0.defaultSelected })
        #expect(removable.allSatisfy { $0.displayLabel?.contains("copy-new.bin") == true })
    }

    @Test("Same size but different content is not a duplicate")
    func sameSizeDifferentContent() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let dir = box.root.appendingPathComponent("scope")
        _ = try write("a.bin", content: Data(repeating: 0x01, count: 4096), in: dir)
        _ = try write("b.bin", content: Data(repeating: 0x02, count: 4096), in: dir)
        // Same partial prefix, divergent tail — must survive stage 2, fail stage 3.
        var c = Data(repeating: 0x03, count: 128 * 1024); c.append(0xAA)
        var d = Data(repeating: 0x03, count: 128 * 1024); d.append(0xBB)
        _ = try write("c.bin", content: c, in: dir)
        _ = try write("d.bin", content: d, in: dir)

        let findings = try await scanner([dir]).scan { _ in }
        #expect(findings.isEmpty)
    }

    @Test("Hardlinked copies share storage and are never offered (§4.3)")
    func hardlinks() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let dir = box.root.appendingPathComponent("scope")
        let original = try write("original.bin",
                                 content: Data(repeating: 0x7C, count: 4096), in: dir)
        let twin = dir.appendingPathComponent("hardlink-twin.bin")
        try FileManager.default.linkItem(at: original, to: twin)

        let findings = try await scanner([dir]).scan { _ in }
        // Two paths, one storage: deleting either frees nothing → no findings.
        #expect(findings.isEmpty)
    }

    @Test("Symlinks are not followed; package interiors are not hashed")
    func symlinkAndPackageSafety() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let dir = box.root.appendingPathComponent("scope")
        let content = Data(repeating: 0x11, count: 4096)
        let real = try write("real.bin", content: content, in: dir)
        // Symlink to an identical file — must not create a "duplicate pair".
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link.bin"), withDestinationURL: real)
        // Identical file inside a package — must stay invisible (FR-BUNDLE).
        _ = try write("inside.bin", content: content,
                      in: dir.appendingPathComponent("Fake.app/Contents"))

        let findings = try await scanner([dir]).scan { _ in }
        #expect(findings.isEmpty)
    }

    @Test("Folder-scoped scan sees only the chosen folder")
    func scopedScan() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let content = Data(repeating: 0x2F, count: 4096)
        let inside = box.root.appendingPathComponent("picked")
        let outside = box.root.appendingPathComponent("elsewhere")
        _ = try write("in-1.bin", content: content, in: inside)
        _ = try write("in-2.bin", content: content, in: inside)
        // A third identical copy outside the picked folder.
        _ = try write("out.bin", content: content, in: outside)

        let findings = try await scanner([inside]).scan { _ in }
        // Only the picked folder participates: one group of two → the keeper
        // plus one removable finding.
        #expect(findings.count == 2)
        #expect(findings.filter(\.isKeeper).count == 1)
        // Compare canonical paths (/var vs /private/var are the same location).
        let canonicalInside = inside.resolvingSymlinksInPath().path
        #expect(findings.allSatisfy {
            $0.path.resolvingSymlinksInPath().path.hasPrefix(canonicalInside)
        })
    }
}
