import Foundation
import Security
import Testing
@testable import CleanCore

/// The privileged surface (Infra A). These tests exercise the exact code that
/// runs as root — `HelperCommandHandler` — headlessly against sandbox paths:
/// the closed command set, helper-side FR-SAFE-1 enforcement, the manifest
/// trail (FR-SAFE-3), and the FR-SEC-1 requirement strings.
struct HelperTests {

    /// Records subprocess invocations instead of running them.
    private final class ProcessRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(tool: String, args: [String])] = []
        var failNext = false

        var run: HelperCommandHandler.Subprocess {
            { [self] tool, args in
                lock.lock(); defer { lock.unlock() }
                calls.append((tool, args))
                if failNext { throw HelperCommandHandler.RemoteError("boom") }
            }
        }
    }

    private func makeHandler(_ box: Sandbox, recorder: ProcessRecorder) throws
        -> (HelperCommandHandler, AuditLog) {
        let log = try AuditLog(fileURL: box.auditURL)
        let handler = HelperCommandHandler(
            auditLog: log,
            allowedDaemonRoots: [box.root.appendingPathComponent("LaunchDaemons",
                                                                 isDirectory: true)],
            runProcess: recorder.run)
        return (handler, log)
    }

    // MARK: - Closed command set

    @Test("Undecodable input is refused, never interpreted")
    func closedCommandSet() async throws {
        let handler = HelperCommandHandler(runProcess: { _, _ in })
        let garbage = [
            Data("rm -rf /".utf8),
            Data(#"{"case":"runShell","cmd":"rm -rf /"}"#.utf8),
            Data(),
        ]
        for payload in garbage {
            let reply = try JSONDecoder().decode(HelperResponse.self,
                                                 from: handler.handle(payload))
            #expect(!reply.ok)
            #expect(reply.message.contains("refused"))
        }
    }

    @Test("Commands round-trip the wire codec; version handshakes")
    func codecAndVersion() async throws {
        let commands: [HelperCommand] = [
            .version,
            .deletePath(path: "/tmp/x"),
            .toggleDaemon(plistPath: "/Library/LaunchDaemons/a.plist", enable: false),
            .deleteSnapshot(dateStamp: "2026-07-03-231906"),
        ]
        for command in commands {
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(HelperCommand.self, from: data) == command)
        }

        let handler = HelperCommandHandler(runProcess: { _, _ in })
        let reply = try JSONDecoder().decode(
            HelperResponse.self,
            from: handler.handle(JSONEncoder().encode(HelperCommand.version)))
        #expect(reply.ok)
        #expect(reply.version == HelperIPC.version)
    }

    // MARK: - deletePath

    @Test("deletePath removes the file and manifests pending→completed")
    func deletePath() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let recorder = ProcessRecorder()
        let (handler, log) = try makeHandler(box, recorder: recorder)
        let victim = try box.makeFile("junk.bin", bytes: 4096, in: "cache")

        let reply = handler.handle(.deletePath(path: victim.path))
        #expect(reply.ok)
        #expect(!FileManager.default.fileExists(atPath: victim.path))
        let record = try #require(try log.currentRecords().first)
        #expect(record.state == .completed)
        #expect(record.bytes >= 4096)
    }

    @Test("deletePath refuses protected paths even as root (FR-SAFE-1 in helper)")
    func deletePathProtected() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let recorder = ProcessRecorder()
        let (handler, log) = try makeHandler(box, recorder: recorder)

        let reply = handler.handle(.deletePath(path: "/System/Library"))
        #expect(!reply.ok)
        #expect(reply.message.contains("refused"))
        #expect(FileManager.default.fileExists(atPath: "/System/Library"))
        let record = try #require(try log.currentRecords().first)
        #expect(record.state == .refused)
    }

    // MARK: - toggleDaemon

    @Test("toggleDaemon renames plist↔disabled and calls launchctl; audited")
    func toggleDaemon() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let recorder = ProcessRecorder()
        let (handler, log) = try makeHandler(box, recorder: recorder)
        let plist = try box.makeFile("com.acme.agent.plist", bytes: 64,
                                     in: "LaunchDaemons")

        let off = handler.handle(.toggleDaemon(plistPath: plist.path, enable: false))
        #expect(off.ok)
        let disabled = plist.path + ".disabled"
        #expect(FileManager.default.fileExists(atPath: disabled))
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        #expect(recorder.calls.last?.args.first == "bootout")

        let on = handler.handle(.toggleDaemon(plistPath: disabled, enable: true))
        #expect(on.ok)
        #expect(FileManager.default.fileExists(atPath: plist.path))
        #expect(recorder.calls.last?.args.first == "bootstrap")
        #expect(try log.currentRecords().allSatisfy { $0.state == .completed })
    }

    @Test("toggleDaemon refuses paths outside the allowed launchd roots")
    func toggleDaemonScope() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let recorder = ProcessRecorder()
        let (handler, _) = try makeHandler(box, recorder: recorder)
        let stray = try box.makeFile("evil.plist", bytes: 64, in: "elsewhere")

        let reply = handler.handle(.toggleDaemon(plistPath: stray.path, enable: false))
        #expect(!reply.ok)
        #expect(reply.message.contains("refused"))
        #expect(FileManager.default.fileExists(atPath: stray.path)) // untouched
        #expect(recorder.calls.isEmpty)

        // Direction/extension mismatches are refused too.
        let plist = try box.makeFile("a.plist", bytes: 8, in: "LaunchDaemons")
        let wrongWay = handler.handle(.toggleDaemon(plistPath: plist.path, enable: true))
        #expect(!wrongWay.ok)
    }

    // MARK: - deleteSnapshot

    @Test("deleteSnapshot passes only a validated stamp to tmutil")
    func deleteSnapshot() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let recorder = ProcessRecorder()
        let (handler, _) = try makeHandler(box, recorder: recorder)

        let ok = handler.handle(.deleteSnapshot(dateStamp: "2026-07-03-231906"))
        #expect(ok.ok)
        let call = try #require(recorder.calls.last)
        #expect(call.tool == "/usr/bin/tmutil")
        #expect(call.args == ["deletelocalsnapshots", "2026-07-03-231906"])

        // Anything that isn't a bare stamp never reaches tmutil.
        for bad in ["2026-07-03", "; rm -rf /", "2026-07-03-231906 /", ""] {
            let reply = handler.handle(.deleteSnapshot(dateStamp: bad))
            #expect(!reply.ok)
        }
        #expect(recorder.calls.count == 1)
    }

    // MARK: - FR-SEC-1 requirements

    @Test("Pinned code-signing requirements compile; team pin extends them")
    func requirementStrings() async throws {
        for req in [HelperSecurity.clientRequirement(),
                    HelperSecurity.helperRequirement(),
                    HelperSecurity.clientRequirement(teamID: "ABCDE12345")] {
            var compiled: SecRequirement?
            let status = SecRequirementCreateWithString(req as CFString, [], &compiled)
            #expect(status == errSecSuccess, "did not compile: \(req)")
            #expect(compiled != nil)
        }
        #expect(HelperSecurity.clientRequirement(teamID: "ABCDE12345")
            .contains("anchor apple generic"))
        // A mismatched identifier must not validate this test process.
        var wrong: SecRequirement?
        SecRequirementCreateWithString(
            #"identifier "com.cleanmac.CleanMac""# as CFString, [], &wrong)
        var selfCode: SecCode?
        SecCodeCopySelf([], &selfCode)
        if let selfCode, let wrong {
            #expect(SecCodeCheckValidity(selfCode, [], wrong) != errSecSuccess)
        }
    }
}
