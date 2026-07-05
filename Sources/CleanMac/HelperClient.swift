import Foundation
import ServiceManagement
import CleanCore

/// Stateless XPC transport to the privileged daemon. A value type with no
/// mutable state so engine executors (which are `@Sendable`) can capture and
/// call it directly. Each send opens a fresh connection, pins the daemon's
/// code signature (FR-SEC-1, app→helper direction), and tears down after the
/// reply.
struct HelperXPC: Sendable {
    func send(_ command: HelperCommand) async -> HelperResponse {
        guard let payload = try? JSONEncoder().encode(command) else {
            return .failure("could not encode command")
        }
        return await withCheckedContinuation { continuation in
            let session = Session(continuation: continuation)
            session.start(payload: payload)
        }
    }

    /// Owns the NSXPCConnection (documented thread-safe) and guarantees the
    /// continuation resumes exactly once across reply/error/invalidation.
    private final class Session: @unchecked Sendable {
        private let connection: NSXPCConnection
        private var continuation: CheckedContinuation<HelperResponse, Never>?
        private let lock = NSLock()

        init(continuation: CheckedContinuation<HelperResponse, Never>) {
            self.continuation = continuation
            self.connection = NSXPCConnection(
                machServiceName: HelperIPC.machServiceName, options: .privileged)
        }

        func start(payload: Data) {
            connection.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
            // FR-SEC-1: refuse to talk to anything that isn't our helper.
            connection.setCodeSigningRequirement(HelperSecurity.helperRequirement())
            connection.invalidationHandler = { [weak self] in
                self?.finish(.failure("helper connection invalidated — is the helper registered and approved?"))
            }
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                self?.finish(.failure("XPC error: \(error.localizedDescription)"))
            }
            guard let helper = proxy as? HelperXPCProtocol else {
                finish(.failure("helper proxy unavailable"))
                return
            }
            helper.execute(payload) { [weak self] replyData in
                let response = (try? JSONDecoder().decode(HelperResponse.self, from: replyData))
                    ?? .failure("undecodable helper reply")
                self?.finish(response)
            }
        }

        private func finish(_ response: HelperResponse) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            guard let continuation else { return }
            continuation.resume(returning: response)
            connection.invalidate()
        }
    }
}

/// UI-side lifecycle of the privileged helper (Infra A): SMAppService
/// registration state, register/unregister, and the version handshake.
/// Registration requires the packaged .app and explicit user approval in
/// System Settings (FR-MULTI — root scope is never silent).
@MainActor
@Observable
final class HelperClient {
    enum HelperState: Equatable {
        /// Running via `swift run` — SMAppService needs the bundled app.
        case notPackaged
        case notRegistered
        /// Registered; the user must approve it in System Settings → Login Items.
        case requiresApproval
        case enabled
        /// The bundle carries no helper (packaging problem).
        case notFound
    }

    var state: HelperState = .notRegistered
    var lastMessage: String?
    /// Set after a successful `.version` handshake with the live daemon.
    var connectedVersion: Int?

    let xpc = HelperXPC()

    private var service: SMAppService {
        SMAppService.daemon(plistName: HelperIPC.daemonPlistName)
    }

    var isEnabled: Bool { state == .enabled }

    func refresh() {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            state = .notPackaged
            return
        }
        switch service.status {
        case .enabled: state = .enabled
        case .requiresApproval: state = .requiresApproval
        case .notFound: state = .notFound
        case .notRegistered: state = .notRegistered
        @unknown default: state = .notRegistered
        }
    }

    func register() {
        do {
            try service.register()
            lastMessage = nil
        } catch {
            lastMessage = "Registration: \(error.localizedDescription)"
        }
        refresh()
        if state == .requiresApproval {
            // Land the user on the exact pane where approval happens.
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func unregister() {
        do {
            try service.unregister()
            lastMessage = nil
        } catch {
            lastMessage = "Unregister: \(error.localizedDescription)"
        }
        connectedVersion = nil
        refresh()
    }

    /// `.version` round-trip: proves launchd can spawn the daemon and both
    /// FR-SEC-1 pins hold. Detects a stale helper after an app update.
    func handshake() async {
        let response = await xpc.send(.version)
        if response.ok {
            connectedVersion = response.version
            lastMessage = response.version == HelperIPC.version
                ? nil
                : "Helper is version \(response.version.map(String.init) ?? "?"), app expects \(HelperIPC.version) — re-register to update."
        } else {
            connectedVersion = nil
            lastMessage = response.message
        }
    }
}
