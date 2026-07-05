import Foundation
import Testing
@testable import CleanCore

/// StartupInventory + StartupOps (§4.5): parsing, disabled detection, the
/// missing-binary flag, and the reversible toggle round-trip.
struct StartupItemTests {

    private func writeAgent(
        _ name: String, label: String, program: String,
        runAtLoad: Bool = true, keepAlive: Any? = nil,
        in dir: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [program, "--daemon"],
            "RunAtLoad": runAtLoad,
        ]
        if let keepAlive { plist["KeepAlive"] = keepAlive }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test("Agents parse with label, program, flags; disabled suffix detected")
    func parsing() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let agents = box.root.appendingPathComponent("LaunchAgents")
        let program = try box.makeFile("helper", bytes: 64) // exists → not missing
        _ = try writeAgent("com.foo.helper.plist", label: "com.foo.helper",
                           program: program.path, keepAlive: true, in: agents)
        _ = try writeAgent("com.bar.off.plist.disabled", label: "com.bar.off",
                           program: program.path, runAtLoad: false, in: agents)

        let items = StartupInventory.list(roots: [(agents, .userAgent)],
                                          checkSignatures: false)
        #expect(items.count == 2)

        let on = try #require(items.first { $0.label == "com.foo.helper" })
        #expect(on.isEnabled && on.runAtLoad && on.keepAlive)
        #expect(on.programPath == program.path)
        #expect(on.isToggleable)

        let off = try #require(items.first { $0.label == "com.bar.off" })
        #expect(!off.isEnabled && !off.runAtLoad && !off.keepAlive)
    }

    @Test("A vanished program is flagged binaryMissing (suspicious)")
    func missingBinary() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let agents = box.root.appendingPathComponent("LaunchAgents")
        _ = try writeAgent("com.gone.plist", label: "com.gone",
                           program: box.root.appendingPathComponent("no-such-binary").path,
                           in: agents)

        let items = StartupInventory.list(roots: [(agents, .userAgent)],
                                          checkSignatures: false)
        #expect(items.first?.signature == .binaryMissing)
        #expect(items.first?.isSuspicious == true)
    }

    @Test("Disable/enable round-trip renames the plist both ways")
    func toggleRoundTrip() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let agents = box.root.appendingPathComponent("LaunchAgents")
        let program = try box.makeFile("helper", bytes: 64)
        let plist = try writeAgent("com.toggle.me.plist", label: "com.toggle.me",
                                   program: program.path, in: agents)

        // Disable: .plist → .plist.disabled
        let enabled = StartupInventory.list(roots: [(agents, .userAgent)],
                                            checkSignatures: false).first!
        let disabledURL = try StartupOps.setEnabled(enabled, enabled: false,
                                                    manageLaunchd: false)
        #expect(disabledURL.lastPathComponent == "com.toggle.me.plist.disabled")
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        #expect(FileManager.default.fileExists(atPath: disabledURL.path))

        // Re-enable: .plist.disabled → .plist (reversibility = re-toggle, §4.5).
        let disabled = StartupInventory.list(roots: [(agents, .userAgent)],
                                             checkSignatures: false).first!
        #expect(!disabled.isEnabled)
        let restoredURL = try StartupOps.setEnabled(disabled, enabled: true,
                                                    manageLaunchd: false)
        #expect(restoredURL.resolvingSymlinksInPath().path
                == plist.resolvingSymlinksInPath().path)
        #expect(FileManager.default.fileExists(atPath: plist.path))
    }

    @Test("System-domain items refuse to toggle (needs Infra A)")
    func systemRefused() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let daemons = box.root.appendingPathComponent("LaunchDaemons")
        let program = try box.makeFile("root-helper", bytes: 64)
        _ = try writeAgent("com.sys.thing.plist", label: "com.sys.thing",
                           program: program.path, in: daemons)

        let item = StartupInventory.list(roots: [(daemons, .systemDaemon)],
                                         checkSignatures: false).first!
        #expect(!item.isToggleable)
        do {
            try StartupOps.setEnabled(item, enabled: false, manageLaunchd: false)
            Issue.record("expected needsAdmin")
        } catch let error as StartupOps.ToggleError {
            #expect(error == .needsAdmin)
        }
    }
}
