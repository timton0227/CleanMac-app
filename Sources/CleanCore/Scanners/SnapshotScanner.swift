import Foundation

/// Local APFS snapshot management (§4.7). Surfaces Time Machine local snapshots
/// via `tmutil listlocalsnapshots` — invisible in Finder yet able to hold tens
/// of GB, and frequently the real answer to "my disk is full."
///
/// Findings use a `snapshot://` pseudo-URL (snapshots aren't files). Per-snapshot
/// size is not exposed by macOS, so `realOnDiskBytes` is 0 — which also means
/// nothing is ever pre-selected — and the space actually freed is *measured*
/// after deletion (FR-VERIFY), never estimated. Deletion is NOT Trash-recoverable:
/// it runs through `ActionEngine.performNonReversible` and Review must say so.
public struct SnapshotScanner: Scanner {
    public let id = "local-snapshots"
    public let category = Category.snapshot
    public let displayName = "Local Snapshots"

    /// Injectable for tests; defaults to running `tmutil listlocalsnapshots /`.
    private let listNames: @Sendable () throws -> [String]

    public init(listNames: (@Sendable () throws -> [String])? = nil) {
        self.listNames = listNames ?? { try SnapshotOps.listLocalSnapshotNames() }
    }

    public func scan(progress: @Sendable @escaping (Double) -> Void) async throws -> [Finding] {
        progress(0)
        let names = try listNames()
        let findings = names.compactMap { Self.finding(fromName: $0) }
        progress(1.0)
        return findings
    }

    /// Parse one `tmutil` snapshot name into a finding. Only Time Machine local
    /// snapshots (`com.apple.TimeMachine.<date>.local`) are offered — OS-update
    /// snapshots are not deletable via `tmutil` and are excluded.
    static func finding(fromName name: String) -> Finding? {
        guard let date = snapshotDate(fromName: name) else { return nil }
        guard let url = URL(string: "snapshot:///\(name)") else { return nil }
        return Finding(
            path: url,
            realOnDiskBytes: 0,   // size unknown until deleted; measured after
            logicalBytes: 0,
            category: .snapshot,
            confidence: .medium,
            safeToRemove: true,
            isProtected: false,
            isCloudPlaceholder: false,
            modifiedAt: date
        )
    }

    /// `com.apple.TimeMachine.2026-06-29-223406.local` → its creation date.
    static func snapshotDate(fromName name: String) -> Date? {
        guard let stamp = dateStamp(fromName: name) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        fmt.timeZone = .current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: stamp)
    }

    /// The `YYYY-MM-DD-HHMMSS` portion `tmutil deletelocalsnapshots` expects.
    static func dateStamp(fromName name: String) -> String? {
        let prefix = "com.apple.TimeMachine."
        let suffix = ".local"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let stamp = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        // Sanity: 2026-06-29-223406
        guard stamp.count == 17, stamp.filter({ $0 == "-" }).count == 3 else { return nil }
        return stamp
    }
}

/// Thin wrappers over `tmutil` (§4.7). Kept separate from the scanner so the
/// deletion side runs only through the engine's non-reversible path.
public enum SnapshotOps {
    public struct CommandError: Error, CustomStringConvertible {
        public let command: String
        public let exitCode: Int32
        public let stderr: String
        public var description: String {
            "\(command) failed (\(exitCode)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    public static func listLocalSnapshotNames(volume: String = "/") throws -> [String] {
        let output = try run("/usr/bin/tmutil", ["listlocalsnapshots", volume])
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
    }

    /// Delete one Time Machine local snapshot by its finding. May require
    /// elevated rights on some macOS versions — a failure surfaces as a thrown
    /// error and lands in the report as `.failed` (graceful degrade until the
    /// privileged helper, Infra A).
    public static func deleteLocalSnapshot(for finding: Finding) throws {
        let name = finding.path.lastPathComponent
        guard let stamp = SnapshotScanner.dateStamp(fromName: name) else {
            throw CommandError(command: "tmutil deletelocalsnapshots",
                               exitCode: -1, stderr: "unrecognized snapshot name: \(name)")
        }
        _ = try run("/usr/bin/tmutil", ["deletelocalsnapshots", stamp])
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            throw CommandError(command: "\(tool) \(arguments.joined(separator: " "))",
                               exitCode: process.terminationStatus, stderr: stderr)
        }
        return stdout
    }
}
