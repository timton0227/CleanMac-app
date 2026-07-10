import SwiftUI
import CleanCore

/// The app-managed Trash (FR-SAFE-2): every removed item, restorable to its
/// original path within the restore window.
struct TrashView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingEmpty = false

    var body: some View {
        Group {
            if model.trashRecords.isEmpty {
                EmptyGoodState(
                    tint: SidebarItem.trash.tint,
                    title: "Trash is empty",
                    message: "Removed items appear here and can be restored to their original location for \(model.restoreWindowDays) days.")
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    List(model.trashRecords) { rec in
                        TrashRow(record: rec)
                    }
                }
            }
        }
        .navigationTitle("Trash / Restore")
        .task { await model.loadTrash() }
    }

    private var header: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Items held").font(.caption).foregroundStyle(Brand.fog)
                Text("\(model.trashRecords.count)")
                    .font(Brand.display(17, weight: .semibold)).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Space retained").font(.caption).foregroundStyle(Brand.fog)
                Text(AppModel.format(model.trashRetainedBytes))
                    .font(Brand.display(17, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Brand.indigo)
            }
            Spacer()
            Text("Everything here restores to its original path for \(model.restoreWindowDays) days.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Empty Trash Now") {
                confirmingEmpty = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(hex: 0xF0A3A2))
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0xE2504F, opacity: 0.5)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.18))
        .confirmationDialog(
            "Permanently delete all \(model.trashRecords.count) item(s) now? This reclaims \(AppModel.format(model.trashRetainedBytes)) and can't be undone.",
            isPresented: $confirmingEmpty, titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                Task { await model.emptyTrashNow() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct TrashRow: View {
    @Environment(AppModel.self) private var model
    let record: ActionRecord
    @State private var hovering = false

    var body: some View {
        HStack {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(Brand.fog)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.originalPath.lastPathComponent).lineLimit(1)
                Text("\(record.originalPath.deletingLastPathComponent().path)  ·  \(record.category.displayName)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(AppModel.format(record.bytes)).monospacedDigit().foregroundStyle(.secondary)
            Button("Restore") { Task { await model.restore(record.actionId) } }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(hovering ? Brand.indigo.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}
