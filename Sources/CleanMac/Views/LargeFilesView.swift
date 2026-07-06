import SwiftUI
import CleanCore

/// Large & Old Files front-end (§4.2). Same shared pipeline and Review UI as
/// System Junk; adds a minimum-size control. Findings are user data, so nothing
/// is ever pre-selected (low confidence, §7) and Quick Look is available in the
/// Review list for per-item inspection (FR-PREVIEW).
struct LargeFilesView: View {
    @Environment(AppModel.self) private var model

    private var ownsPipeline: Bool { model.activeModuleId == "large-old-files" }
    private var phase: AppModel.Phase { ownsPipeline ? model.phase : .idle }

    private static let thresholds: [(String, Int64)] = [
        ("50 MB", 50 * 1024 * 1024),
        ("100 MB", 100 * 1024 * 1024),
        ("500 MB", 500 * 1024 * 1024),
        ("1 GB", 1024 * 1024 * 1024),
    ]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // Idle opens with a full-bleed hero, consistent with Smart Scan;
            // the storage + phase chrome appears only once a run is underway.
            if phase != .idle {
                StorageHeader()
                PhaseBar(phase: phase)
                Divider()
            }
            body(for: phase)
        }
        .navigationTitle("Large & Old Files")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Larger than", selection: $model.largeFileMinBytes) {
                    ForEach(Self.thresholds, id: \.1) { label, bytes in
                        Text("≥ \(label)").tag(bytes)
                    }
                }
                .pickerStyle(.menu)
            }
            if ownsPipeline && (model.phase == .review || model.phase == .report) {
                ToolbarItem(placement: .automatic) {
                    Button("Rescan") { Task { await model.scanLargeFiles() } }
                }
            }
        }
    }

    @ViewBuilder
    private func body(for phase: AppModel.Phase) -> some View {
        switch phase {
        case .idle:
            ModuleHero(
                icon: SidebarItem.largeFiles.systemImage,
                tint: SidebarItem.largeFiles.tint,
                title: "Large & Old Files",
                message: "Recursively scans Downloads, Desktop, Documents, Movies, Music, and Pictures for files above the size threshold. These are your files — nothing is pre-selected, and iCloud-only files are flagged as freeing no local space.",
                primaryLabel: "Scan",
                primaryAction: { Task { await model.scanLargeFiles() } }
            )
        case .scanning:
            ScanRing(progress: model.scanProgress, label: "Measuring files…")
        case .review:
            ReviewList()
        case .acting:
            ScanRing(label: "Cleaning…", indeterminate: true)
        case .report:
            ReportView()
        }
    }
}
