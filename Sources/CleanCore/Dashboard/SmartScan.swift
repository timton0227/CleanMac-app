import Foundation

/// One-click Smart Scan (§4.8): runs a **curated subset** of the module
/// scanners over the one shared pipeline and reports per-category status —
/// deliberately *not* a 0–100 "system score" (§6: unfalsifiable numbers are
/// out; transparent per-category findings are in).
///
/// Smart Scan only *scans*. Acting on a category hands its findings to the
/// module's normal Review, so every removal still flows through the same
/// hardened engine with the same confirmation UX.
public enum SmartScan {
    /// Per-module outcome. A failure in one module (e.g. iOS backups without
    /// Full Disk Access, FR-PERM) never aborts the others.
    public struct ModuleResult: Sendable, Identifiable, Equatable {
        public enum Status: Sendable, Equatable {
            case pending, scanning, done
            case failed(String)
        }

        public let id: String
        public let displayName: String
        public var status: Status
        public var findings: [Finding]

        public init(id: String, displayName: String,
                    status: Status = .pending, findings: [Finding] = []) {
            self.id = id
            self.displayName = displayName
            self.status = status
            self.findings = findings
        }

        /// Everything the module found (real bytes — cloud placeholders ≈ 0).
        public var totalBytes: Int64 {
            findings.reduce(0) { $0 + $1.realOnDiskBytes }
        }
        /// The conservative pre-selected subset — the headline "reclaimable
        /// now" number Smart Scan may honestly promise (§7).
        public var preselectedBytes: Int64 {
            findings.filter(\.defaultSelected).reduce(0) { $0 + $1.realOnDiskBytes }
        }
    }

    /// The curated set: safe, fast, high-yield modules. Deliberately excludes
    /// the heavy full-tree walks (Large Files, Duplicates, Space Lens) — those
    /// stay explicit user actions with their own scoping UI.
    public static func curatedScanners() -> [any Scanner] {
        [
            SystemJunkScanner(),
            LeftoversScanner(),
            SnapshotScanner(),
            IOSBackupScanner(),
        ]
    }

    /// Runs the scanners sequentially (one disk walk at a time, FR-PERF),
    /// isolating failures per module. `onUpdate` fires when a module starts
    /// and again when it finishes, so a UI can show live per-category status.
    public static func run(
        _ scanners: [any Scanner],
        progress: (@Sendable (Double) -> Void)? = nil,
        onUpdate: (@Sendable (ModuleResult) -> Void)? = nil
    ) async -> [ModuleResult] {
        var results: [ModuleResult] = []
        let count = Double(max(scanners.count, 1))

        for (index, scanner) in scanners.enumerated() {
            var result = ModuleResult(id: scanner.id, displayName: scanner.displayName,
                                      status: .scanning)
            onUpdate?(result)

            let base = Double(index) / count
            do {
                let findings = try await scanner.scan { p in
                    progress?(base + p / count)
                }
                result.findings = findings.sorted { $0.realOnDiskBytes > $1.realOnDiskBytes }
                result.status = .done
            } catch is CancellationError {
                result.status = .failed("Cancelled")
                onUpdate?(result)
                results.append(result)
                return results
            } catch let error as IOSBackupScanner.ScanError {
                // FR-PERM: name the permission, don't report a fake "0 items".
                if case .accessDenied = error {
                    result.status = .failed("Needs Full Disk Access")
                }
            } catch {
                result.status = .failed(error.localizedDescription)
            }

            onUpdate?(result)
            results.append(result)
            progress?(Double(index + 1) / count)
        }
        return results
    }
}
