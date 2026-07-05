import Foundation
import CryptoKit

/// Duplicate File Finder (§4.3) — content-hash based, never filename/size-only.
///
/// Three-stage funnel so almost nothing gets fully hashed:
///   1. size bucket (unique sizes can't have duplicates),
///   2. partial hash (first 64 KB) of same-size files,
///   3. full streaming SHA-256 only for survivors.
///
/// Correctness catches from the audit (§4.3):
/// - **Hardlinks**: paths sharing one (device, inode) share storage — deleting
///   one frees nothing. Candidates are deduplicated by inode *before* hashing,
///   so hardlinked twins are never offered and never counted as reclaimable.
/// - **Symlinks**: never followed or reported (escaping the scan tree is a
///   safety bug, not just an accounting one).
/// - **Packages** are opaque (FR-BUNDLE): their contents are never enumerated.
///
/// **Always leaves at least one copy — structurally.** Per duplicate group the
/// keeper (newest by modification date, the §4.3 "keep newest" rule) is *not
/// emitted as a finding at all*, so no combination of Review selections can
/// delete every copy.
///
/// Scoping: `roots` defaults to the user-facing folders; the UI's
/// "pick a folder" mode passes exactly one user-chosen root instead.
public struct DuplicateScanner: Scanner {
    public let id = "duplicates"
    public let category = Category.duplicate
    public let displayName = "Duplicate Finder"

    public let roots: [URL]
    /// Files below this size are ignored (tiny duplicates are noise).
    public let minBytes: Int64

    private let protectedPaths: ProtectedPaths
    private static let partialHashBytes = 64 * 1024
    private static let streamChunkBytes = 1024 * 1024

    public init(
        roots: [URL]? = nil,
        minBytes: Int64 = 1024 * 1024,
        protectedPaths: ProtectedPaths = ProtectedPaths()
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? [
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Pictures"),
        ]
        self.minBytes = minBytes
        self.protectedPaths = protectedPaths
    }

    // MARK: - Scan

    public func scan(progress: @Sendable @escaping (Double) -> Void) async throws -> [Finding] {
        // Stage 0: enumerate candidates (deduplicated by inode — hardlink rule).
        progress(0.05)
        let candidates = try collectCandidates()

        // Stage 1: size buckets. Unique size ⇒ no duplicate possible.
        let sizeBuckets = Dictionary(grouping: candidates, by: \.sizeBytes)
            .values.filter { $0.count > 1 }
        progress(0.15)

        // Stage 2: partial hash inside each size bucket.
        var partialBuckets: [[Candidate]] = []
        let sizeBucketCount = max(sizeBuckets.count, 1)
        for (index, bucket) in sizeBuckets.enumerated() {
            try Task.checkCancellation()
            progress(0.15 + 0.35 * Double(index) / Double(sizeBucketCount))
            var byPartial: [Data: [Candidate]] = [:]
            for candidate in bucket {
                guard let digest = try? hash(candidate.url, limit: Self.partialHashBytes) else { continue }
                byPartial[digest, default: []].append(candidate)
            }
            partialBuckets.append(contentsOf: byPartial.values.filter { $0.count > 1 })
        }

        // Stage 3: full hash for survivors; group by digest.
        var groups: [[Candidate]] = []
        let partialCount = max(partialBuckets.count, 1)
        for (index, bucket) in partialBuckets.enumerated() {
            try Task.checkCancellation()
            progress(0.5 + 0.45 * Double(index) / Double(partialCount))
            var byFull: [Data: [Candidate]] = [:]
            for candidate in bucket {
                guard let digest = try? hash(candidate.url, limit: nil) else { continue }
                byFull[digest, default: []].append(candidate)
            }
            groups.append(contentsOf: byFull.values.filter { $0.count > 1 })
        }

        // Emit findings: everything in a group except the keeper (keep newest).
        var findings: [Finding] = []
        for group in groups {
            let sorted = group.sorted {
                ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
            guard let keeper = sorted.first else { continue }
            for extra in sorted.dropFirst() {
                findings.append(makeFinding(extra, keeper: keeper))
            }
        }
        progress(1.0)
        return findings.sorted { $0.realOnDiskBytes > $1.realOnDiskBytes }
    }

    // MARK: - Candidate collection

    struct Candidate: Sendable {
        let url: URL
        let sizeBytes: Int64
        let modifiedAt: Date?
        let device: Int32
        let inode: UInt64
    }

    private func collectCandidates() throws -> [Candidate] {
        var seenStorage = Set<String>() // "(dev,ino)" — hardlink dedupe
        var candidates: [Candidate] = []

        for root in roots {
            let keys: [URLResourceKey] = [
                .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .isPackageKey,
                .contentModificationDateKey,
            ]
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

                if values.isSymbolicLink == true {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                // Only plain regular files participate; packages are opaque and
                // not hashable as units (FR-BUNDLE).
                guard values.isRegularFile == true, values.isPackage != true else { continue }

                guard let (device, inode, size) = statIdentity(url), size >= minBytes else { continue }

                // §4.3 hardlink rule: same storage counted once, offered never.
                let storageKey = "\(device):\(inode)"
                guard !seenStorage.contains(storageKey) else { continue }
                seenStorage.insert(storageKey)

                candidates.append(Candidate(
                    url: url, sizeBytes: size,
                    modifiedAt: values.contentModificationDate,
                    device: device, inode: inode
                ))
            }
        }
        return candidates
    }

    private func statIdentity(_ url: URL) -> (device: Int32, inode: UInt64, size: Int64)? {
        var st = stat()
        let ok = url.withUnsafeFileSystemRepresentation { rep -> Bool in
            guard let rep else { return false }
            return stat(rep, &st) == 0
        }
        guard ok else { return nil }
        return (Int32(st.st_dev), UInt64(st.st_ino), Int64(st.st_size))
    }

    // MARK: - Hashing

    /// Streaming SHA-256 of up to `limit` bytes (nil = whole file).
    private func hash(_ url: URL, limit: Int?) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunkSize = min(Self.streamChunkBytes, remaining)
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return Data(hasher.finalize())
    }

    // MARK: - Findings

    private func makeFinding(_ candidate: Candidate, keeper: Candidate) -> Finding {
        let verdict = protectedPaths.verdict(for: candidate.url)
        return Finding(
            path: candidate.url,
            realOnDiskBytes: SizeAccounting.realOnDiskBytes(of: candidate.url),
            logicalBytes: candidate.sizeBytes,
            category: .duplicate,
            // Exact content match is certain; the *suggested* removal set is
            // everything but the newest copy (§4.3 keep-newest rule).
            confidence: .medium,
            safeToRemove: !verdict.isProtected,
            isProtected: verdict.isProtected,
            isCloudPlaceholder: SizeAccounting.isCloudPlaceholder(of: candidate.url),
            validation: SizeAccounting.validation(of: candidate.url),
            modifiedAt: candidate.modifiedAt,
            displayLabel: "\(candidate.url.lastPathComponent) — duplicate of \(keeper.url.path)"
        )
    }
}
