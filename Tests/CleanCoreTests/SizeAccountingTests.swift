import Foundation
import Testing
@testable import CleanCore

struct SizeAccountingTests {

    @Test("Regular file reports non-zero real bytes and is not a cloud placeholder")
    func regularFile() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let file = try box.makeFile("x.bin", bytes: 10_000)
        #expect(SizeAccounting.realOnDiskBytes(of: file) > 0)
        #expect(SizeAccounting.logicalBytes(of: file) == 10_000)
        #expect(!SizeAccounting.isCloudPlaceholder(of: file))
    }

    @Test("Directory real bytes sum the contained files")
    func directorySum() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.makeFile("a", bytes: 4096, in: "dir")
        try box.makeFile("b", bytes: 4096, in: "dir/nested")
        let dir = box.root.appendingPathComponent("dir", isDirectory: true)
        #expect(SizeAccounting.totalRealOnDiskBytes(of: dir) >= 8192)
    }

    @Test("Validation snapshot matches unchanged file, fails after change (FR-SAFE-7)")
    func validation() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let file = try box.makeFile("v.bin", bytes: 1024)
        let snap = try #require(SizeAccounting.validation(of: file))
        #expect(SizeAccounting.matchesValidation(file, snap))

        try Data(repeating: 0x42, count: 2048).write(to: file)
        #expect(!SizeAccounting.matchesValidation(file, snap))
    }
}

struct VerifierTests {
    @Test("Within tolerance when measured ≈ estimated")
    func withinTolerance() {
        let v = Verifier(tolerance: 0.15)
        let r = v.reconcile(estimatedBytes: 1000, freeBefore: 0, freeAfter: 1050)
        #expect(r.withinTolerance)
    }

    @Test("Out of tolerance when measured diverges")
    func outOfTolerance() {
        let v = Verifier(tolerance: 0.15)
        let r = v.reconcile(estimatedBytes: 1000, freeBefore: 0, freeAfter: 200)
        #expect(!r.withinTolerance)
    }

    @Test("Zero-estimate (all moved to Trash) tolerates ~no free-space change")
    func zeroEstimate() {
        let v = Verifier()
        let r = v.reconcile(estimatedBytes: 0, freeBefore: 500, freeAfter: 500)
        #expect(r.withinTolerance)
    }
}
