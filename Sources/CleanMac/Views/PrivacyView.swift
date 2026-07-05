import SwiftUI
import CleanCore

/// Privacy Cleaner (§4.6). Deliberately different from the standard Review:
/// privacy artifacts are **purged, not moved to Trash** — there is no undo —
/// so this view carries its own warning banner and a single destructive
/// action, and nothing is ever pre-selected (user-selectable granularity,
/// never silent).
struct PrivacyView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingPurge = false

    private var ownsPipeline: Bool { model.activeModuleId == "privacy" }
    private var phase: AppModel.Phase { ownsPipeline ? model.phase : .idle }

    var body: some View {
        VStack(spacing: 0) {
            StorageHeader()
            PhaseBar(phase: phase, actLabel: "Clear")
            Divider()
            body(for: phase)
        }
        .navigationTitle("Privacy")
        .toolbar {
            if ownsPipeline && (model.phase == .review || model.phase == .report) {
                ToolbarItem(placement: .automatic) {
                    Button("Rescan") { Task { await model.scanPrivacy() } }
                }
            }
        }
    }

    @ViewBuilder
    private func body(for phase: AppModel.Phase) -> some View {
        switch phase {
        case .idle:
            ModuleHero(
                icon: SidebarItem.privacy.systemImage,
                tint: SidebarItem.privacy.tint,
                title: "Privacy Cleaner",
                message: "Clears browsing history, cookies, and download records (Safari, Chrome, Firefox), shell and tool histories, and the system recent-items lists. Nothing is selected by default, and clearing is permanent — these records are purged, not moved to the Trash.\n\nSafari data requires Full Disk Access to appear. Quit a browser before clearing its data."
            ) {
                Button("Scan") { Task { await model.scanPrivacy() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .scanning:
            ScanRing(progress: model.scanProgress, label: "Scanning privacy traces…")
        case .review:
            if model.findings.isEmpty {
                ContentUnavailableView("No privacy artifacts found",
                                       systemImage: "checkmark.circle",
                                       description: Text("Nothing from the catalog exists on this Mac (or it needs Full Disk Access to be visible)."))
            } else {
                reviewList
            }
        case .acting:
            ScanRing(label: "Clearing…", indeterminate: true)
        case .report:
            ReportView()
        }
    }

    private var reviewList: some View {
        VStack(spacing: 0) {
            InfoBanner(icon: "exclamationmark.triangle.fill", tint: .orange,
                       text: "Clearing is permanent — privacy records are purged, not moved to the Trash, and cannot be restored. Items marked “In use” need their app quit first.")
            List {
                ForEach(grouped, id: \.0) { owner, items in
                    Section(owner) {
                        ForEach(items) { FindingRow(finding: $0) }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            actionBar
        }
    }

    /// Group rows by owning app ("Safari", "Terminal", …) from the label.
    private var grouped: [(String, [Finding])] {
        Dictionary(grouping: model.findings) { finding in
            finding.displayLabel?.components(separatedBy: " — ").first ?? "Other"
        }
        .map { ($0.key, $0.value) }
        .sorted { $0.0 < $1.0 }
    }

    private var actionBar: some View {
        HStack {
            Text("\(model.selected.count) selected · \(AppModel.format(model.reclaimableBytes))")
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.default, value: model.selected.count)
            Spacer()
            Button("Clear \(model.selected.count) Item(s) Permanently…", role: .destructive) {
                confirmingPurge = true
            }
            .disabled(model.selected.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Brand.paper)
        .confirmationDialog(
            "Permanently clear \(model.selected.count) privacy item(s)? This cannot be undone.",
            isPresented: $confirmingPurge, titleVisibility: .visible
        ) {
            Button("Clear Permanently", role: .destructive) {
                Task { await model.purgeSelectedPrivacy() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
