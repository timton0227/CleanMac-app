import Foundation
import Testing
@testable import CleanCore

struct ActionEngineTests {

    // FR-SAFE-1: protected items are refused and logged, never removed.
    @Test("Protected finding is refused and audit-logged, file survives")
    func protectedRefused() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let file = try box.makeFile("keepme.txt")
        let (engine, log, _) = try box.makeEngine()

        var f = box.finding(for: file)
        f = Finding(id: f.id, path: f.path, realOnDiskBytes: f.realOnDiskBytes,
                    logicalBytes: f.logicalBytes, category: f.category,
                    confidence: f.confidence, safeToRemove: false,
                    isProtected: true, isCloudPlaceholder: false, validation: f.validation)

        let report = await engine.perform([f])
        #expect(report.completed.isEmpty)
        #expect(report.refused.count == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let logged = try log.currentRecords()
        #expect(logged.contains { $0.state == .refused })
    }

    // FR-SAFE-2: move to Trash then restore reproduces path + byte-identical content.
    @Test("Trash + restore reproduces original path and contents")
    func restoreByteIdentical() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let file = try box.makeFile("cache.bin", bytes: 4096)
        let original = try Data(contentsOf: file)
        let (engine, _, _) = try box.makeEngine()

        let report = await engine.perform([box.finding(for: file)])
        #expect(report.completed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path)) // moved out

        let actionId = try #require(report.completed.first).actionId
        let restored = try await engine.restore(actionId: actionId)
        #expect(restored)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: file) == original)
    }

    // FR-SAFE-2 amend: batch undo restores an entire clean in one step.
    @Test("Undo last clean restores every item of the batch")
    func batchUndo() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let files = try (0..<3).map { try box.makeFile("f\($0).bin", bytes: 512) }
        let (engine, _, _) = try box.makeEngine()
        let batch = UUID()

        let report = await engine.perform(files.map { box.finding(for: $0) }, batchId: batch)
        #expect(report.completed.count == 3)
        for f in files { #expect(!FileManager.default.fileExists(atPath: f.path)) }

        let restored = try await engine.undoBatch(batch)
        #expect(restored == 3)
        for f in files { #expect(FileManager.default.fileExists(atPath: f.path)) }
    }

    // FR-SAFE-4: re-running a batch skips already-completed items (idempotent).
    @Test("Resume skips completed items, no double action")
    func idempotentResume() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let files = try (0..<3).map { try box.makeFile("g\($0).bin") }
        let (engine, log, _) = try box.makeEngine()
        let batch = UUID()
        let findings = files.map { box.finding(for: $0) }

        // Simulate a crash after item 0 completed: pre-seed its completed record.
        try log.append(ActionRecord(batchId: batch, originalPath: files[0],
                                    trashPath: box.trashURL.appendingPathComponent("x"),
                                    bytes: 1024, category: .userCache, state: .completed))

        let report = await engine.perform(findings, batchId: batch)
        // Only the two not-yet-done items should be acted on.
        #expect(report.completed.count == 2)
        #expect(!report.completed.contains { $0.originalPath == files[0] })
        // File 0 untouched by this run (still on disk).
        #expect(FileManager.default.fileExists(atPath: files[0].path))
    }

    // FR-SAFE-7: an item changed between scan and action is skipped, not deleted.
    @Test("Changed-since-scan item is skipped (TOCTOU)")
    func revalidateBeforeMutate() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let file = try box.makeFile("changing.bin", bytes: 1024)
        let (engine, _, _) = try box.makeEngine()
        let finding = box.finding(for: file)

        // Mutate the file after the finding's validation snapshot was captured.
        try Data(repeating: 0x42, count: 8192).write(to: file)

        let report = await engine.perform([finding])
        #expect(report.completed.isEmpty)
        #expect(report.skipped.count == 1)
        #expect(report.skipped.first?.reason == "changed-since-scan")
        #expect(FileManager.default.fileExists(atPath: file.path)) // not deleted
    }

    // FR-SAFE-6: permanent removal actually frees space and reports "freed now".
    @Test("Permanent delete frees now; trash delete is reclaimable-after-purge")
    func reclaimVsRetain() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let trashed = try box.makeFile("a.bin", bytes: 2048)
        let permanent = try box.makeFile("b.bin", bytes: 2048)
        let (engine, _, _) = try box.makeEngine()

        let r1 = await engine.perform([box.finding(for: trashed)])
        #expect(r1.reclaimableAfterPurgeBytes > 0)
        #expect(r1.freedNowBytes == 0)

        let r2 = await engine.perform([box.finding(for: permanent)],
                                      options: .init(permanentToReclaimNow: true))
        #expect(r2.freedNowBytes > 0)
        #expect(r2.reclaimableAfterPurgeBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: permanent.path))
    }

    // FR-SAFE-3 / FR-SAFE-4: reconstruct a crash where the move finished but the
    // completing record wasn't written — the pending item is promoted to completed.
    @Test("reconcilePending promotes a moved-but-uncommitted item")
    func crashReconstruction() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let file = try box.makeFile("half.bin", bytes: 1024)
        let (engine, log, _) = try box.makeEngine()

        // Hand-craft the mid-crash on-disk state: a .pending record whose file
        // has already been moved into the Trash but never marked completed.
        let actionId = UUID()
        let destDir = box.trashURL.appendingPathComponent(actionId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: dest)
        try log.append(ActionRecord(actionId: actionId, batchId: UUID(),
                                    originalPath: file, trashPath: dest,
                                    bytes: 1024, category: .userCache, state: .pending))

        let fixed = try await engine.reconcilePending()
        #expect(fixed.count == 1)
        #expect(fixed.first?.state == .completed)
        let final = try log.currentRecords().first { $0.actionId == actionId }
        #expect(final?.state == .completed)
    }

    // FR-VOL: same-volume items support reversible removal.
    @Test("Same-volume item supports reversible removal")
    func volumeAwareness() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let file = try box.makeFile("v.bin")
        let (_, _, trash) = try box.makeEngine()
        #expect(trash.supportsReversibleRemoval(of: file))
    }
}
