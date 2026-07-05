import Foundation
import Testing
@testable import CleanCore

/// SnapshotScanner (§4.7) parsing + the engine's non-reversible path.
struct SnapshotScannerTests {

    @Test("Time Machine snapshot names parse to date-stamped findings")
    func parseNames() async throws {
        let scanner = SnapshotScanner(listNames: {
            [
                "com.apple.TimeMachine.2026-06-29-223406.local",
                "com.apple.TimeMachine.2026-07-01-090000.local",
            ]
        })
        let findings = try await scanner.scan { _ in }

        #expect(findings.count == 2)
        #expect(findings.allSatisfy { $0.category == .snapshot })
        #expect(findings.allSatisfy { $0.modifiedAt != nil })
        // Size unknown until deletion → 0 real bytes → never pre-selected.
        #expect(findings.allSatisfy { $0.realOnDiskBytes == 0 && !$0.defaultSelected })

        let stamp = SnapshotScanner.dateStamp(
            fromName: "com.apple.TimeMachine.2026-06-29-223406.local")
        #expect(stamp == "2026-06-29-223406")
    }

    @Test("Non-TimeMachine snapshot names are excluded (not deletable via tmutil)")
    func excludesNonTM() async throws {
        let scanner = SnapshotScanner(listNames: {
            [
                "com.apple.os.update-0BAE677BB05A455C2ADFFE03F0AC17A07B.local",
                "com.apple.TimeMachine.2026-06-29-223406.local",
                "not-a-snapshot",
            ]
        })
        let findings = try await scanner.scan { _ in }
        #expect(findings.count == 1)
        #expect(findings.first?.path.lastPathComponent
                == "com.apple.TimeMachine.2026-06-29-223406.local")
    }

    @Test("Malformed date stamps are rejected")
    func malformedStamps() {
        #expect(SnapshotScanner.dateStamp(fromName: "com.apple.TimeMachine.junk.local") == nil)
        #expect(SnapshotScanner.dateStamp(fromName: "com.apple.TimeMachine..local") == nil)
        #expect(SnapshotScanner.snapshotDate(fromName: "com.apple.TimeMachine.2026-13-99-999999.local") == nil)
    }
}

struct NonReversibleEngineTests {

    private func snapshotFinding(_ name: String) -> Finding {
        SnapshotScanner.finding(fromName: name)!
    }

    // FR-SAFE-3/4: executor runs per item, manifest records completed states,
    // and a re-run of the same batch skips already-completed items.
    @Test("performNonReversible executes, audit-logs, and resumes idempotently")
    func executesAndResumes() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let (engine, log, _) = try box.makeEngine()
        let batch = UUID()
        let items = [
            snapshotFinding("com.apple.TimeMachine.2026-06-29-223406.local"),
            snapshotFinding("com.apple.TimeMachine.2026-07-01-090000.local"),
        ]

        // Pre-seed item 0 as completed (simulates crash-after-first-item).
        try log.append(ActionRecord(batchId: batch, originalPath: items[0].path,
                                    bytes: 0, category: .snapshot, state: .completed))

        // Track invocations via file side effects (executor is @Sendable).
        let markerDir = box.root.appendingPathComponent("markers", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        let report = await engine.performNonReversible(items, batchId: batch) { finding in
            let marker = markerDir.appendingPathComponent(finding.path.lastPathComponent)
            try Data().write(to: marker)
        }

        // Only item 1 executed; item 0 skipped as already done.
        let markers = try FileManager.default.contentsOfDirectory(atPath: markerDir.path)
        #expect(markers == ["com.apple.TimeMachine.2026-07-01-090000.local"])
        #expect(report.completed.count == 1)

        let states = try log.currentRecords().filter { $0.batchId == batch }
        #expect(states.allSatisfy { $0.state == .completed })
    }

    @Test("Executor failure is recorded as .failed with the reason")
    func failureRecorded() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let (engine, log, _) = try box.makeEngine()

        struct Boom: Error {}
        let report = await engine.performNonReversible(
            [snapshotFinding("com.apple.TimeMachine.2026-06-29-223406.local")]
        ) { _ in throw Boom() }

        #expect(report.completed.isEmpty)
        #expect(report.failed.count == 1)
        let rec = try log.currentRecords().first
        #expect(rec?.state == .failed)
        #expect(rec?.reason?.isEmpty == false)
    }

    // FR-SAFE-1 still applies to file-URL findings on the non-reversible path.
    @Test("Protected file-URL findings are refused even on the non-reversible path")
    func protectedStillRefused() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let (engine, _, _) = try box.makeEngine()

        let f = Finding(
            path: URL(fileURLWithPath: "/System/Library/Caches/x"),
            realOnDiskBytes: 10, logicalBytes: 10, category: .userCache,
            confidence: .high, safeToRemove: true, isProtected: false,
            isCloudPlaceholder: false
        )
        let report = await engine.performNonReversible([f]) { _ in
            Issue.record("executor must not run for a protected path")
        }
        #expect(report.refused.count == 1)
        #expect(report.completed.isEmpty)
    }
}
