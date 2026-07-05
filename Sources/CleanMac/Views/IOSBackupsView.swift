import SwiftUI
import CleanCore

/// Old iOS Device Backups (§4.10). Standard pipeline + shared ReviewList: rows
/// show device name and backup date via `displayLabel`, the most recent backup
/// per device is never pre-selected, and removal is reversible via the Trash.
struct IOSBackupsView: View {
    @Environment(AppModel.self) private var model

    private var ownsPipeline: Bool { model.activeModuleId == "ios-backups" }
    private var phase: AppModel.Phase { ownsPipeline ? model.phase : .idle }

    var body: some View {
        VStack(spacing: 0) {
            StorageHeader()
            PhaseBar(phase: phase)
            Divider()
            body(for: phase)
        }
        .navigationTitle("iOS Backups")
        .toolbar {
            if ownsPipeline && (model.phase == .review || model.phase == .report) {
                ToolbarItem(placement: .automatic) {
                    Button("Rescan") { Task { await model.scanIOSBackups() } }
                }
            }
        }
    }

    @ViewBuilder
    private func body(for phase: AppModel.Phase) -> some View {
        switch phase {
        case .idle:
            ModuleHero(
                icon: SidebarItem.iosBackups.systemImage,
                tint: SidebarItem.iosBackups.tint,
                title: "Old iOS Device Backups",
                message: "Finds local iPhone/iPad backups stored on this Mac — often large and stale. The most recent backup of each device is kept by default. Removal goes to the app Trash and can be undone. This never touches the device itself.\n\nNote: macOS requires Full Disk Access to read the backups folder."
            ) {
                Button("Scan") { Task { await model.scanIOSBackups() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .scanning:
            ScanRing(progress: model.scanProgress, label: "Reading backups…")
        case .review:
            if model.findings.isEmpty {
                ContentUnavailableView("No local iOS backups",
                                       systemImage: "checkmark.circle",
                                       description: Text("This Mac stores no device backups."))
            } else {
                ReviewList()
            }
        case .acting:
            ScanRing(label: "Cleaning…", indeterminate: true)
        case .report:
            ReportView()
        }
    }
}
