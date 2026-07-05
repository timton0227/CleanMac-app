import Foundation

/// Measures actual volume free space so "space freed" is a *measurement*, not
/// the pre-scan estimate (FR-VERIFY). Also backs the background reconciliation
/// of the optimistic live total (FR-UX-LIVE).
public struct FreeSpaceProbe: Sendable {
    public init() {}

    /// Available capacity for the volume containing `url`, in bytes. Uses the
    /// "important usage" key which reflects what the user can actually reclaim
    /// (accounts for purgeable space) and falls back to the plain available key.
    public func availableBytes(forVolumeContaining url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage {
            return Int64(important)
        }
        if let available = values.volumeAvailableCapacity {
            return Int64(available)
        }
        return nil
    }
}

/// Reconciles the estimate (summed real bytes) against a measured free-space
/// delta and reports whether they agree within tolerance (FR-VERIFY).
public struct Verifier: Sendable {
    /// Fraction the measured value may diverge from the estimate before we flag
    /// it (background writes by other processes make an exact match impossible).
    public let tolerance: Double

    public init(tolerance: Double = 0.15) {
        self.tolerance = tolerance
    }

    public struct Result: Sendable, Equatable {
        public let estimatedBytes: Int64
        public let measuredBytes: Int64
        public let withinTolerance: Bool
    }

    /// - Parameters:
    ///   - estimatedBytes: summed `realOnDiskBytes` of items actually removed.
    ///   - freeBefore/freeAfter: volume free space around the operation.
    public func reconcile(estimatedBytes: Int64, freeBefore: Int64, freeAfter: Int64) -> Result {
        let measured = freeAfter - freeBefore
        let within: Bool
        if estimatedBytes == 0 {
            within = measured >= 0
        } else {
            let ratio = Double(measured) / Double(estimatedBytes)
            within = ratio >= (1 - tolerance) && ratio <= (1 + tolerance)
        }
        return Result(estimatedBytes: estimatedBytes, measuredBytes: measured, withinTolerance: within)
    }
}
