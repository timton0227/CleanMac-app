import Foundation
import Testing
@testable import CleanCore

/// Smart Scan orchestration (§4.8): per-module aggregation, failure isolation
/// (one module's error never aborts the run), honest reclaimable math, and the
/// live per-category status stream. Plus the DiskBreakdown purgeable math that
/// backs the Storage-panel reconciliation note.
struct SmartScanTests {

    private struct StubScanner: CleanCore.Scanner {
        let id: String
        let category = Category.userCache
        var displayName: String { id }
        let findings: [Finding]

        func scan(progress: @Sendable @escaping (Double) -> Void) async throws -> [Finding] {
            progress(1)
            return findings
        }
    }

    private struct FailingScanner: CleanCore.Scanner {
        let id: String
        let category = Category.iosBackup
        var displayName: String { id }
        let error: any Error

        func scan(progress: @Sendable @escaping (Double) -> Void) async throws -> [Finding] {
            throw error
        }
    }

    private func finding(_ path: String, bytes: Int64,
                         confidence: Confidence = .high) -> Finding {
        Finding(path: URL(fileURLWithPath: path), realOnDiskBytes: bytes,
                logicalBytes: bytes, category: .userCache, confidence: confidence,
                safeToRemove: true, isProtected: false, isCloudPlaceholder: false)
    }

    @Test("Aggregates per module; preselected excludes low-confidence items")
    func aggregation() async throws {
        let a = StubScanner(id: "a", findings: [
            finding("/x/big", bytes: 1000),
            finding("/x/risky", bytes: 500, confidence: .low), // never pre-selected (§7)
        ])
        let b = StubScanner(id: "b", findings: [finding("/y/one", bytes: 42)])

        let results = await SmartScan.run([a, b])
        #expect(results.map(\.id) == ["a", "b"]) // order preserved
        #expect(results.allSatisfy { $0.status == .done })
        #expect(results[0].totalBytes == 1500)
        #expect(results[0].preselectedBytes == 1000) // low-confidence excluded
        #expect(results[1].totalBytes == 42)
    }

    @Test("A failing module is isolated — the rest still run")
    func failureIsolation() async throws {
        struct Boom: Error {}
        let scanners: [any CleanCore.Scanner] = [
            StubScanner(id: "first", findings: [finding("/a", bytes: 1)]),
            FailingScanner(id: "broken", error: Boom()),
            StubScanner(id: "last", findings: [finding("/b", bytes: 2)]),
        ]

        let results = await SmartScan.run(scanners)
        #expect(results.count == 3)
        #expect(results[0].status == .done)
        if case .failed = results[1].status {} else {
            Issue.record("expected the middle module to fail")
        }
        #expect(results[2].status == .done) // ran despite the failure before it
    }

    @Test("FDA denial surfaces as a named permission failure (FR-PERM)")
    func fullDiskAccessDenial() async throws {
        let denied = FailingScanner(
            id: "ios-backups",
            error: IOSBackupScanner.ScanError.accessDenied(path: "/x"))

        let results = await SmartScan.run([denied])
        #expect(results[0].status == .failed("Needs Full Disk Access"))
    }

    @Test("Status stream: each module reports scanning then a final state")
    func statusStream() async throws {
        let scanners: [any CleanCore.Scanner] = [
            StubScanner(id: "a", findings: []),
            StubScanner(id: "b", findings: [finding("/b", bytes: 9)]),
        ]

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var updates: [SmartScan.ModuleResult] = []
            func append(_ r: SmartScan.ModuleResult) {
                lock.lock(); defer { lock.unlock() }
                updates.append(r)
            }
        }
        let box = Box()
        _ = await SmartScan.run(scanners, onUpdate: { box.append($0) })
        #expect(box.updates.map(\.id) == ["a", "a", "b", "b"])
        #expect(box.updates[0].status == .scanning)
        #expect(box.updates[1].status == .done)
        #expect(box.updates[3].findings.count == 1)
    }

    @Test("DiskBreakdown: purgeable is the Storage-panel gap; used excludes it")
    func diskBreakdownMath() async throws {
        // 1 TB volume: 200 GB truly free, Storage panel says 300 GB available
        // → 100 GB purgeable, 700 GB genuinely used.
        let d = DiskBreakdown(totalBytes: 1_000, freeBytes: 200,
                              availableIncludingPurgeableBytes: 300)
        #expect(d.purgeableBytes == 100)
        #expect(d.usedBytes == 700)
        // Degenerate probe (no purgeable key): never negative.
        let flat = DiskBreakdown(totalBytes: 1_000, freeBytes: 300,
                                 availableIncludingPurgeableBytes: 300)
        #expect(flat.purgeableBytes == 0)
    }

    @Test("Live vitals probes return sane values on this machine")
    func liveProbes() async throws {
        let disk = try #require(DiskBreakdown.probe(
            volumeContaining: FileManager.default.homeDirectoryForCurrentUser))
        #expect(disk.totalBytes > 0)
        #expect(disk.freeBytes > 0 && disk.freeBytes <= disk.totalBytes)

        let mem = try #require(MemorySnapshot.sample())
        #expect(mem.totalBytes > 0)
        #expect(mem.usedBytes > 0)

        let cpu = try #require(CPULoad.sample())
        #expect(cpu.coreCount > 0)
        #expect(cpu.oneMinute >= 0)
        // BatteryInfo.probe() is nil on desktops — presence not asserted.
    }
}
