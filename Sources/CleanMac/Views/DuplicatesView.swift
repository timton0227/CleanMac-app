import SwiftUI
import CleanCore

/// Duplicate Finder (§4.3). Two scan modes:
/// - **Default locations** — Downloads, Desktop, Documents, Pictures.
/// - **Chosen folder** — the user picks any folder and only that folder is
///   scanned.
///
/// Groups always keep their newest copy: the keeper is never even offered, so
/// no selection can delete every copy. Duplicates ship pre-selected (exact
/// content match, keep-newest suggestion) but pass through Review as always.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var showingFolderPicker = false

    private var ownsPipeline: Bool { model.activeModuleId == "duplicates" }
    private var phase: AppModel.Phase { ownsPipeline ? model.phase : .idle }

    var body: some View {
        VStack(spacing: 0) {
            StorageHeader()
            PhaseBar(phase: phase)
            Divider()
            if let roots = model.duplicateScanRoots {
                InfoBanner(icon: "folder.badge.gearshape", tint: .blue,
                           text: "Scanning only: \(roots.map(\.path).joined(separator: ", "))") {
                    Button("Use Default Locations") {
                        model.clearDuplicateScope()
                        Task { await model.scanDuplicates() }
                    }
                    .font(.callout)
                }
            }
            body(for: phase)
        }
        .navigationTitle("Duplicate Finder")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Choose Folder…") { showingFolderPicker = true }
            }
            if ownsPipeline && (model.phase == .review || model.phase == .report) {
                ToolbarItem(placement: .automatic) {
                    Button("Rescan") { Task { await model.scanDuplicates() } }
                }
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                Task { await model.scanDuplicates(roots: [url]) }
            }
        }
    }

    @ViewBuilder
    private func body(for phase: AppModel.Phase) -> some View {
        switch phase {
        case .idle:
            ModuleHero(
                icon: SidebarItem.duplicates.systemImage,
                tint: SidebarItem.duplicates.tint,
                title: "Duplicate Finder",
                message: "Finds files with identical content (SHA-256, not just name or size) in Downloads, Desktop, Documents, and Pictures — or pick a specific folder to scan only there. The newest copy of each group is always kept; hardlinked copies share storage and are never offered.",
                primaryLabel: "Scan",
                primaryAction: { Task { await model.scanDuplicates() } }
            ) {
                Button("Choose Folder…") { showingFolderPicker = true }
            }
        case .scanning:
            ScanRing(progress: model.scanProgress, label: "Comparing file contents…")
        case .review:
            if model.findings.isEmpty {
                ContentUnavailableView("No duplicates found",
                                       systemImage: "checkmark.circle",
                                       description: Text("Every file in the scanned scope has unique content."))
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
