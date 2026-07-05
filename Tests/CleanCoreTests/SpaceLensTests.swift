import Foundation
import Testing
@testable import CleanCore

/// SpaceLens tree builder (§4.9): real-bytes aggregation, hardlink/symlink/
/// package correctness, pruning that preserves totals, and the in-place
/// `removing` update behind FR-UX-LIVE.
struct SpaceLensTests {

    @Test("Directory sizes aggregate children; children sort descending")
    func aggregation() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.makeFile("big.bin", bytes: 8192, in: "root/sub")
        try box.makeFile("small.bin", bytes: 4096, in: "root/sub")
        try box.makeFile("top.bin", bytes: 4096, in: "root")

        let tree = try SpaceLens.build(root: box.root.appendingPathComponent("root"),
                                       minNodeBytes: 0)
        #expect(tree.realBytes >= 16384)
        #expect(tree.children.first?.name == "sub") // 12K > 4K
        let sub = try #require(tree.children.first)
        #expect(sub.isDrillable)
        #expect(sub.children.map(\.name) == ["big.bin", "small.bin"])
    }

    @Test("Hardlinked storage counts once; symlinks don't appear")
    func hardlinkAndSymlink() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let original = try box.makeFile("original.bin", bytes: 8192, in: "root")
        try FileManager.default.linkItem(
            at: original,
            to: box.root.appendingPathComponent("root/twin.bin"))
        try FileManager.default.createSymbolicLink(
            at: box.root.appendingPathComponent("root/link.bin"),
            withDestinationURL: original)

        let tree = try SpaceLens.build(root: box.root.appendingPathComponent("root"),
                                       minNodeBytes: 0)
        // Two names, one storage: total is one file's bytes, not two.
        #expect(tree.realBytes >= 8192 && tree.realBytes < 16384)
        #expect(!tree.children.contains { $0.name == "link.bin" })
        // Both hardlink names appear, but only one carries the bytes.
        let carriers = tree.children.filter { $0.realBytes > 0 }
        #expect(carriers.count == 1)
    }

    @Test("Packages are opaque leaves sized whole (FR-BUNDLE)")
    func packages() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.makeFile("exec", bytes: 8192, in: "root/Fake.app/Contents/MacOS")

        let tree = try SpaceLens.build(root: box.root.appendingPathComponent("root"),
                                       minNodeBytes: 0)
        let pkg = try #require(tree.children.first { $0.name == "Fake.app" })
        #expect(pkg.isPackage)
        #expect(!pkg.isDrillable)
        #expect(pkg.children.isEmpty)
        #expect(pkg.realBytes >= 8192)
    }

    @Test("Pruning hides small nodes but preserves exact totals")
    func pruning() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.makeFile("large.bin", bytes: 100_000, in: "root")
        try box.makeFile("tiny-1.bin", bytes: 512, in: "root")
        try box.makeFile("tiny-2.bin", bytes: 512, in: "root")

        let tree = try SpaceLens.build(root: box.root.appendingPathComponent("root"),
                                       minNodeBytes: 10_000)
        #expect(tree.children.count == 1) // only large.bin visible
        #expect(tree.prunedBytes >= 1024) // tinies aggregated, not lost
        let visible = tree.children.reduce(Int64(0)) { $0 + $1.realBytes }
        #expect(tree.realBytes == visible + tree.prunedBytes)
    }

    @Test("removing() drops nodes and decrements every ancestor (FR-UX-LIVE)")
    func removing() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let doomed = try box.makeFile("doomed.bin", bytes: 8192, in: "root/sub")
        try box.makeFile("stays.bin", bytes: 4096, in: "root/sub")

        let tree = try SpaceLens.build(root: box.root.appendingPathComponent("root"),
                                       minNodeBytes: 0)
        let before = tree.realBytes
        let sub = try #require(tree.children.first { $0.name == "sub" })
        let doomedNode = try #require(sub.children.first { $0.name == "doomed.bin" })

        let updated = try #require(tree.removing([doomedNode.path]))
        #expect(updated.realBytes == before - doomedNode.realBytes)
        let updatedSub = try #require(updated.children.first { $0.name == "sub" })
        #expect(!updatedSub.children.contains { $0.name == "doomed.bin" })
        #expect(updatedSub.children.contains { $0.name == "stays.bin" })
        // Removing the root yields nil.
        #expect(tree.removing([tree.path]) == nil)
        _ = doomed
    }
}
