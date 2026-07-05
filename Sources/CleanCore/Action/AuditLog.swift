import Foundation

/// Append-only, crash-safe deletion manifest (FR-SAFE-3).
///
/// Each state transition is a *new* JSON line — the file is never rewritten in
/// place, so a crash can never corrupt existing records. Current state is the
/// last line per `actionId` (fold-by-id). Every append is flushed with `fsync`
/// **before** the caller performs the mutation, so a `.pending` record always
/// survives a crash and reconstruction (FR-SAFE-4) is exact.
///
/// Thread-safe: an internal lock serializes file access so the engine actor and
/// the UI (and tests) can share one instance without racing.
public final class AuditLog: @unchecked Sendable {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }
    }

    /// Append one record as a JSON line and durably flush before returning
    /// (FR-SAFE-3: fsync before the mutation the caller is about to perform).
    public func append(_ record: ActionRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        var line = try encoder.encode(record)
        line.append(0x0A) // newline

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        // Durability: flush the file's buffers to disk before we mutate anything.
        fsync(handle.fileDescriptor)
    }

    /// Latest state of every action, folded by `actionId` (last write wins).
    public func currentRecords() throws -> [ActionRecord] {
        lock.lock()
        defer { lock.unlock() }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }

        var folded: [UUID: ActionRecord] = [:]
        for lineData in data.split(separator: 0x0A) where !lineData.isEmpty {
            guard let record = try? decoder.decode(ActionRecord.self, from: Data(lineData)) else {
                continue // tolerate a torn final line from a crash mid-write
            }
            folded[record.actionId] = record
        }
        return folded.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// Records in a terminal-or-pending state, filtered by predicate.
    public func records(where predicate: (ActionRecord) -> Bool) throws -> [ActionRecord] {
        try currentRecords().filter(predicate)
    }
}
