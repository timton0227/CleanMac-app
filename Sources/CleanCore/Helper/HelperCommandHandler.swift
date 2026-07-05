import Foundation

/// Executes `HelperCommand`s. This is the code that runs **as root** inside
/// the daemon, so every safety property must hold *here*, not in the UI:
/// FR-SAFE-1 protected-path enforcement lives in this type (a spoofed or
/// compromised client cannot bypass it), every mutation is manifest-logged
/// pending-before-mutate (FR-SAFE-3), and the command surface is the closed
/// `HelperCommand` enum — undecodable input is refused, never interpreted.
///
/// Pure logic + injected subprocess runner, so the whole privileged surface is
/// testable headlessly as a normal user against sandbox paths.
public struct HelperCommandHandler: Sendable {
    /// Runs a tool to completion; throws on non-zero exit. Injectable so tests
    /// record invocations instead of touching `tmutil`/`launchctl`.
    public typealias Subprocess = @Sendable (_ tool: String, _ arguments: [String]) throws -> Void

    public struct RemoteError: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    let protectedPaths: ProtectedPaths
    let auditLog: AuditLog?
    /// The only directories `toggleDaemon` may touch — system-wide launchd
    /// locations that need root. User-domain agents stay app-side (§4.5).
    let allowedDaemonRoots: [URL]
    let runProcess: Subprocess

    public init(
        protectedPaths: ProtectedPaths = ProtectedPaths(),
        auditLog: AuditLog? = nil,
        allowedDaemonRoots: [URL] = [
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
        ],
        runProcess: @escaping Subprocess = HelperCommandHandler.spawn
    ) {
        self.protectedPaths = protectedPaths
        self.auditLog = auditLog
        self.allowedDaemonRoots = allowedDaemonRoots
        self.runProcess = runProcess
    }

    // MARK: - Entry points

    /// Wire-level entry: decode → handle → encode. Anything that is not a
    /// well-formed member of the enumerated command set is refused here.
    public func handle(_ commandData: Data) -> Data {
        let response: HelperResponse
        if let command = try? JSONDecoder().decode(HelperCommand.self, from: commandData) {
            response = handle(command)
        } else {
            response = .failure("unrecognized command — refused (enumerated command set)")
        }
        return (try? JSONEncoder().encode(response))
            ?? Data(#"{"ok":false,"message":"encoding failure"}"#.utf8)
    }

    public func handle(_ command: HelperCommand) -> HelperResponse {
        switch command {
        case .version:
            return HelperResponse(ok: true, message: "CleanHelper", version: HelperIPC.version)
        case .deletePath(let path):
            return deletePath(path)
        case .toggleDaemon(let plistPath, let enable):
            return toggleDaemon(plistPath: plistPath, enable: enable)
        case .deleteSnapshot(let dateStamp):
            return deleteSnapshot(dateStamp: dateStamp)
        }
    }

    // MARK: - deletePath

    private func deletePath(_ path: String) -> HelperResponse {
        let url = URL(fileURLWithPath: path)
        let verdict = protectedPaths.verdict(for: url)
        if verdict.isProtected {
            audit(url, bytes: 0, category: .storageItem, state: .refused,
                  reason: verdict.reason ?? "protected path")
            return .failure("refused: \(verdict.reason ?? "protected path")")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure("no such path: \(path)")
        }

        let bytes = SizeAccounting.totalRealOnDiskBytes(of: url)
        // FR-SAFE-3: pending is durable before the mutation.
        let actionId = audit(url, bytes: bytes, category: .storageItem, state: .pending)
        do {
            try FileManager.default.removeItem(at: url)
            audit(url, actionId: actionId, bytes: bytes, category: .storageItem,
                  state: .completed)
            return HelperResponse(ok: true, message: "deleted \(path) (\(bytes) bytes)")
        } catch {
            audit(url, actionId: actionId, bytes: bytes, category: .storageItem,
                  state: .failed, reason: error.localizedDescription)
            return .failure("delete failed: \(error.localizedDescription)")
        }
    }

    // MARK: - toggleDaemon

    private func toggleDaemon(plistPath: String, enable: Bool) -> HelperResponse {
        let url = URL(fileURLWithPath: plistPath)
        // Narrow surface: only plists directly inside the system launchd
        // folders, regardless of what the client asks for.
        let canonicalRoots = allowedDaemonRoots.map { $0.resolvingSymlinksInPath().path }
        let canonical = url.resolvingSymlinksInPath()
        guard canonicalRoots.contains(canonical.deletingLastPathComponent().path) else {
            return .failure("refused: \(plistPath) is not in \(canonicalRoots.joined(separator: " or "))")
        }

        let name = canonical.lastPathComponent
        let source: URL
        let target: URL
        if enable {
            guard name.hasSuffix(".plist.disabled") else {
                return .failure("refused: enable expects a .plist.disabled file")
            }
            source = canonical
            target = canonical.deletingPathExtension() // strips ".disabled"
        } else {
            guard name.hasSuffix(".plist") else {
                return .failure("refused: disable expects a .plist file")
            }
            source = canonical
            target = canonical.appendingPathExtension("disabled")
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .failure("no such daemon plist: \(source.path)")
        }

        let actionId = audit(source, bytes: 0, category: .startupItem, state: .pending)
        do {
            try FileManager.default.moveItem(at: source, to: target)
            // Best-effort load-state change; the rename is the durable truth
            // (same policy as the user-domain StartupOps toggle, §4.5).
            if enable {
                try? runProcess("/bin/launchctl", ["bootstrap", "system", target.path])
            } else {
                let label = name.replacingOccurrences(of: ".plist", with: "")
                try? runProcess("/bin/launchctl", ["bootout", "system/\(label)"])
            }
            audit(source, actionId: actionId, bytes: 0, category: .startupItem,
                  state: .completed, reason: enable ? "enabled" : "disabled")
            return HelperResponse(ok: true, message: "\(enable ? "enabled" : "disabled") \(name)")
        } catch {
            audit(source, actionId: actionId, bytes: 0, category: .startupItem,
                  state: .failed, reason: error.localizedDescription)
            return .failure("toggle failed: \(error.localizedDescription)")
        }
    }

    // MARK: - deleteSnapshot

    private func deleteSnapshot(dateStamp: String) -> HelperResponse {
        // Strict stamp shape (`2026-07-03-231906`) — the only thing ever passed
        // to tmutil, so no other argument can be smuggled through this verb.
        guard dateStamp.wholeMatch(of: /\d{4}-\d{2}-\d{2}-\d{6}/) != nil else {
            return .failure("refused: '\(dateStamp)' is not a snapshot date stamp")
        }
        let pseudoURL = URL(string: "snapshot:///\(dateStamp)")
            ?? URL(fileURLWithPath: "/snapshot/\(dateStamp)")
        let actionId = audit(pseudoURL, bytes: 0, category: .snapshot, state: .pending)
        do {
            try runProcess("/usr/bin/tmutil", ["deletelocalsnapshots", dateStamp])
            audit(pseudoURL, actionId: actionId, bytes: 0, category: .snapshot,
                  state: .completed)
            return HelperResponse(ok: true, message: "deleted snapshot \(dateStamp)")
        } catch {
            audit(pseudoURL, actionId: actionId, bytes: 0, category: .snapshot,
                  state: .failed, reason: error.localizedDescription)
            return .failure("snapshot delete failed: \(error)")
        }
    }

    // MARK: - Audit (FR-SAFE-3 in the helper)

    @discardableResult
    private func audit(_ url: URL, actionId: UUID = UUID(), bytes: Int64,
                       category: Category, state: ActionRecord.State,
                       reason: String? = nil) -> UUID {
        let record = ActionRecord(actionId: actionId, batchId: actionId,
                                  originalPath: url, bytes: bytes,
                                  category: category, state: state, reason: reason)
        try? auditLog?.append(record)
        return actionId
    }

    // MARK: - Default subprocess runner

    public static let spawn: Subprocess = { tool, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            throw RemoteError("\(tool) exited \(process.terminationStatus): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
