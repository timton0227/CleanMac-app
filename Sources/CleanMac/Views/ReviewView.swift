import SwiftUI
import QuickLook
import CleanCore

/// FR-PREVIEW: grouped, sized, per-item inspectable review with Quick Look
/// (§4.2). Protected items are shown disabled; low-confidence items are present
/// but unchecked (§7). Whole categories toggle in one click, and the action bar
/// keeps a live, animated total of what's selected.
struct ReviewList: View {
    @Environment(AppModel.self) private var model
    /// The module's verb for its destructive action — "Clean"/"Delete"/"Clear"
    /// — matching the mock's per-module `actLabel` instead of a hardcoded
    /// "Clean" everywhere.
    var actLabel = "Clean"
    @State private var confirmingPermanent = false
    @State private var quickLookURL: URL?

    /// Grouped by display name (not the raw `Category` case) so categories
    /// that share a label in the mock — e.g. app logs and crash reports both
    /// under "System Logs & Crash Reports" — merge into one section.
    private var grouped: [(String, [Finding])] {
        Dictionary(grouping: model.findings, by: \.category.displayName)
            .map { ($0.key, $0.value.sorted { $0.realOnDiskBytes > $1.realOnDiskBytes }) }
            .sorted { lhs, rhs in
                lhs.1.reduce(0) { $0 + $1.realOnDiskBytes } >
                rhs.1.reduce(0) { $0 + $1.realOnDiskBytes }
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(grouped, id: \.0) { name, items in
                    Section {
                        ForEach(items) { finding in
                            FindingRow(finding: finding)
                                .contextMenu {
                                    Button("Quick Look") { quickLookURL = finding.path }
                                    Button("Reveal in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([finding.path])
                                    }
                                }
                        }
                    } header: {
                        sectionHeader(name, items)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .quickLookPreview($quickLookURL)

            Divider()
            actionBar
        }
    }

    /// Category header: name, count, size — and a one-click whole-category
    /// toggle (protected items stay out, always).
    private func sectionHeader(_ name: String, _ items: [Finding]) -> some View {
        let selectable = items.filter { !$0.isProtected }
        let allOn = !selectable.isEmpty && selectable.allSatisfy { model.selected.contains($0.id) }
        return HStack {
            Text(name)
            Text("\(items.count)")
                .font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Brand.border.opacity(0.6), in: Capsule())
            Spacer()
            Text(AppModel.format(items.reduce(0) { $0 + $1.realOnDiskBytes }))
                .foregroundStyle(.secondary)
            if !selectable.isEmpty {
                Button(allOn ? "None" : "All") {
                    model.setSelection(items, to: !allOn)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Brand.indigo)
                .help(allOn ? "Deselect this whole category"
                            : "Select this whole category")
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Text("\(model.selected.count) of \(model.findings.count) selected")
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.default, value: model.selected.count)
            Button("Select All") { model.selectAll() }
                .controlSize(.small)
            Button("Deselect All") { model.deselectAll() }
                .controlSize(.small)
                .disabled(model.selected.isEmpty)
            Spacer()
            Menu {
                Button("Move to Trash (reversible)") {
                    Task { await model.clean(permanent: false) }
                }
                Button("Delete permanently (frees space now)", role: .destructive) {
                    confirmingPermanent = true
                }
            } label: {
                Label("\(actLabel) \(AppModel.format(model.reclaimableBytes))",
                      systemImage: "sparkles")
                    .contentTransition(.numericText())
                    .animation(.default, value: model.reclaimableBytes)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.selected.isEmpty)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .confirmationDialog(
            "Permanently delete the selected items? This frees space immediately but cannot be undone.",
            isPresented: $confirmingPermanent, titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) {
                Task { await model.clean(permanent: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct FindingRow: View {
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
            .disabled(finding.isProtected)

            VStack(alignment: .leading, spacing: 2) {
                Text(finding.displayLabel ?? finding.path.lastPathComponent)
                    .lineLimit(1)
                revealButton
            }
            Spacer()
            badges
            if let modified = finding.modifiedAt {
                Text(modified, format: .dateTime.year().month().day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
            }
            Text(AppModel.format(finding.realOnDiskBytes))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(hovering ? Brand.indigo.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .help(helpText)
    }

    /// The folder path, clickable to reveal the item in Finder — no right-click
    /// needed. A folder glyph appears on hover to signal it's interactive.
    @State private var pathHovering = false
    private var revealButton: some View {
        let path = finding.displayLabel != nil
            ? finding.path.path
            : finding.path.deletingLastPathComponent().path
        return Button {
            NSWorkspace.shared.activateFileViewerSelecting([finding.path])
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .opacity(pathHovering ? 1 : 0)
                Text(path)
                    .font(.caption)
                    .lineLimit(1)
                    .underline(pathHovering)
            }
            .foregroundStyle(pathHovering ? Brand.indigo : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { pathHovering = $0 }
        .help("Reveal in Finder")
    }

    @ViewBuilder
    private var badges: some View {
        if finding.isKeeper {
            BrandTag(text: "Keeper", color: Brand.keeper)
        } else if finding.isProtected {
            BrandTag(text: "Protected", color: Brand.danger)
        } else if finding.confidence == .low {
            BrandTag(text: "Low confidence", color: Brand.lowConfidence)
        }
        if finding.ownedByRunningProcess {
            BrandTag(text: "In use", color: Brand.danger)
        }
        if finding.isCloudPlaceholder {
            BrandTag(text: "Cloud", color: Brand.cloud)
        }
    }

    private var helpText: String {
        if finding.isProtected { return "On the protected-path denylist — cannot be removed." }
        if finding.isCloudPlaceholder { return "iCloud-only file: frees ~0 bytes locally." }
        return "Confidence: \(finding.confidence). Logical size \(AppModel.format(finding.logicalBytes))."
    }
}
