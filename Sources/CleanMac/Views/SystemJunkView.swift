import SwiftUI
import CleanCore

/// The System Junk front-end: storage header (live totals, FR-UX-LIVE) + the
/// phase-driven body (scan → review → report). Review groups by category, shows
/// sizes, pre-selects only high-confidence safe items, and disables protected
/// ones (FR-PREVIEW, §7).
struct SystemJunkView: View {
    @Environment(AppModel.self) private var model

    /// The pipeline is shared (§2); this view only renders its own module's run.
    private var ownsPipeline: Bool { model.activeModuleId == "system-junk" }
    private var phase: AppModel.Phase { ownsPipeline ? model.phase : .idle }

    var body: some View {
        VStack(spacing: 0) {
            StorageHeader()
            PhaseBar(phase: phase)
            Divider()
            body(for: phase)
        }
        .navigationTitle("System Junk")
        .toolbar {
            if ownsPipeline && (model.phase == .review || model.phase == .report) {
                ToolbarItem(placement: .automatic) {
                    Button("Rescan") { Task { await model.scanSystemJunk() } }
                }
            }
        }
    }

    @ViewBuilder
    private func body(for phase: AppModel.Phase) -> some View {
        switch phase {
        case .idle:
            ModuleHero(
                icon: SidebarItem.systemJunk.systemImage,
                tint: SidebarItem.systemJunk.tint,
                title: "System Junk",
                message: "Finds user-level caches, logs, crash reports, developer junk, and broken downloads that are safe to remove. Nothing is deleted without your review."
            ) {
                Button("Scan") { Task { await model.scanSystemJunk() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .scanning:
            ScanRing(progress: model.scanProgress, label: "Scanning for junk…")
        case .review:
            ReviewList()
        case .acting:
            ScanRing(label: "Cleaning…", indeterminate: true)
        case .report:
            ReportView()
        }
    }
}
