import Foundation
import Testing
@testable import CleanCore

/// A disposable on-disk sandbox so tests never touch real system paths.
struct Sandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// Create a file with `bytes` of content, return its URL.
    @discardableResult
    func makeFile(_ name: String, bytes: Int = 1024, in subdir: String? = nil) throws -> URL {
        let dir = subdir.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    var trashURL: URL { root.appendingPathComponent("Trash", isDirectory: true) }
    var auditURL: URL { root.appendingPathComponent("audit.log") }

    func makeEngine(protected: ProtectedPaths = ProtectedPaths()) throws -> (ActionEngine, AuditLog, TrashStore) {
        let log = try AuditLog(fileURL: auditURL)
        // Hermetic: move into the sandbox, never the developer's real ~/.Trash.
        let trash = try TrashStore(baseURL: trashURL, useSystemTrash: false)
        let engine = ActionEngine(protectedPaths: protected, auditLog: log, trash: trash)
        return (engine, log, trash)
    }

    /// Build a Finding for a real file in the sandbox with a validation snapshot.
    func finding(for url: URL, category: CleanCore.Category = .userCache,
                 confidence: Confidence = .high, isProtected: Bool = false) -> Finding {
        Finding(
            path: url,
            realOnDiskBytes: SizeAccounting.realOnDiskBytes(of: url),
            logicalBytes: SizeAccounting.logicalBytes(of: url),
            category: category, confidence: confidence,
            safeToRemove: !isProtected, isProtected: isProtected,
            isCloudPlaceholder: false,
            validation: SizeAccounting.validation(of: url)
        )
    }
}
