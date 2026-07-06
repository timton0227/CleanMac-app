import SwiftUI
import CleanCore

/// Local Snapshot management (§4.7). Deliberately does not reuse the shared
/// ReviewList: snapshot deletion is NOT Trash-recoverable, sizes are unknown
/// until deletion (measured after, FR-VERIFY), and Review must say both things
/// plainly (FR-SAFE-2 exception flagging).
struct SnapshotsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDelete = false

    private var ownsPipeline: Bool { model.activeModuleId == "local-snapshots" }
    private var phase: AppModel.Phase { ownsPipeline ? model.phase : .idle }

    var body: some View {
        VStack(spacing: 0) {
            // Idle opens with a full-bleed hero, consistent with Smart Scan;
            // the storage + phase chrome appears only once a run is underway.
            if phase != .idle {
                StorageHeader()
                PhaseBar(phase: phase, actLabel: "Delete")
                Divider()
            }
            body(for: phase)
        }
        .navigationTitle("Local Snapshots")
        .toolbar {
            if ownsPipeline && model.phase == .review {
                ToolbarItem(placement: .automatic) {
                    Button("Rescan") { Task { await model.scanSnapshots() } }
                }
            }
        }
    }

    @ViewBuilder
    private func body(for phase: AppModel.Phase) -> some View {
        switch phase {
        case .idle:
            ModuleHero(
                icon: SidebarItem.snapshots.systemImage,
                tint: SidebarItem.snapshots.tint,
                title: "Local APFS Snapshots",
                message: "Time Machine keeps local snapshots that are invisible in the Finder yet can hold many GB — often the real reason a disk looks full. Deleting a snapshot removes restore points, not your files, and cannot be undone. Freed space is measured after deletion.",
                primaryLabel: "Scan",
                primaryAction: { Task { await model.scanSnapshots() } }
            )
        case .scanning:
            ScanRing(label: "Listing snapshots…", indeterminate: true)
        case .acting:
            ScanRing(label: "Deleting…", indeterminate: true)
        case .review, .report:
            reviewList
        }
    }

    @ViewBuilder
    private var reviewList: some View {
        if model.findings.isEmpty {
            ContentUnavailableView("No local snapshots",
                                   systemImage: "checkmark.circle",
                                   description: Text("This volume has no Time Machine local snapshots."))
        } else {
            VStack(spacing: 0) {
                InfoBanner(icon: "exclamationmark.triangle.fill", tint: .orange,
                           text: "Snapshot deletion is permanent — it cannot be restored from the app's Trash. Your current files are unaffected; only Time Machine restore points are removed.")
                List {
                    ForEach(model.findings) { finding in
                        SnapshotRow(finding: finding)
                    }
                }
                .listStyle(.inset)
            .scrollContentBackground(.hidden)
                Divider()
                actionBar
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Text("\(model.selected.count) of \(model.findings.count) selected · freed space is measured after deletion")
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
            Button("Delete \(model.selected.count) Snapshot(s)…", role: .destructive) {
                confirmingDelete = true
            }
            .disabled(model.selected.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .confirmationDialog(
            "Permanently delete \(model.selected.count) snapshot(s)? This removes Time Machine restore points and cannot be undone.",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                Task { await model.deleteSelectedSnapshots() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct SnapshotRow: View {
    @Environment(AppModel.self) private var model
    let finding: Finding
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.selected.contains(finding.id) },
                set: { _ in model.toggle(finding.id) }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                if let date = finding.modifiedAt {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                    Text(finding.path.lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(finding.path.lastPathComponent).lineLimit(1)
                }
            }
            Spacer()
            if let date = finding.modifiedAt {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(hovering ? Brand.indigo.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}
