import Foundation
import CleanCore

/// CleanHelper — the privileged daemon (Infra A, §3). Registered from the app
/// via `SMAppService.daemon` (user approval + admin auth, FR-MULTI), launched
/// on demand by launchd for its mach service.
///
/// Security posture:
/// - FR-SEC-1: every connection must satisfy the pinned code-signing
///   requirement of the CleanMac app — enforced by `setCodeSigningRequirement`,
///   which the kernel verifies per message. A spoofed client never reaches
///   the exported object.
/// - The exported surface is one method carrying the closed `HelperCommand`
///   enum; `HelperCommandHandler` re-enforces FR-SAFE-1 protected paths and
///   writes its own append-only manifest (FR-SAFE-3) at root scope.

final class HelperService: NSObject, HelperXPCProtocol {
    private let handler: HelperCommandHandler

    init(handler: HelperCommandHandler) {
        self.handler = handler
    }

    func execute(_ commandData: Data, withReply reply: @escaping (Data) -> Void) {
        reply(handler.handle(commandData))
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let handler: HelperCommandHandler

    init(handler: HelperCommandHandler) {
        self.handler = handler
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // FR-SEC-1: pin the peer before exporting anything.
        connection.setCodeSigningRequirement(HelperSecurity.clientRequirement())
        connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedObject = HelperService(handler: handler)
        connection.resume()
        return true
    }
}

// Root-scope manifest, same append-only JSON-lines format as the app's
// (FR-SAFE-3); lives outside any user home because the daemon is system-wide.
let auditLog = try? AuditLog(fileURL: URL(
    fileURLWithPath: "/Library/Application Support/CleanMac/helper-audit.log"))
let handler = HelperCommandHandler(auditLog: auditLog)

let delegate = ListenerDelegate(handler: handler)
let listener = NSXPCListener(machServiceName: HelperIPC.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
