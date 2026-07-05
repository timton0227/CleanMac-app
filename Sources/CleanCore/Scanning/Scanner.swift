import Foundation

/// The interchangeable scanner front-end from §2. Every functional module
/// (§4.1–§4.10) is one conformance to this protocol; they all feed the same
/// Findings model and the same Action engine. A scanner only *proposes* — it
/// never mutates the filesystem.
public protocol Scanner: Sendable {
    /// Stable identifier (used in logs / UI selection).
    var id: String { get }
    /// Primary category this scanner emits (a scanner may still tag individual
    /// findings with more specific categories).
    var category: Category { get }
    /// Human-readable name for the sidebar.
    var displayName: String { get }

    /// Enumerate candidate items. Must be cancellable via `Task` cancellation
    /// and report coarse progress in `0...1` (FR-PERF). Must not follow symlinks
    /// and must treat bundles/packages as opaque (FR-BUNDLE).
    func scan(progress: @Sendable @escaping (Double) -> Void) async throws -> [Finding]
}

public extension Scanner {
    var displayName: String { id }
}
