import SwiftUI
import CleanCore

/// Large & Old Files front-end (§4.2). Same shared pipeline and Review UI as
/// System Junk; adds a minimum-size control. Findings are user data, so nothing
/// is ever pre-selected (low confidence, §7) and Quick Look is available in the
/// Review list for per-item inspection (FR-PREVIEW).
struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var viewMode: ReviewMode = .bubbles

    enum ReviewMode: String, CaseIterable { case bubbles = "Bubbles", list = "List" }

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
            if model.hasNothingLeftToShow(for: "large-old-files") {
                EmptyGoodState(tint: SidebarItem.largeFiles.tint,
                               message: "Nothing large or old enough to flag.")
            } else {
                ModuleHero(
                    icon: SidebarItem.largeFiles.systemImage,
                    tint: SidebarItem.largeFiles.tint,
                    title: "Large & Old Files",
                    message: "Recursively scans Downloads, Desktop, Documents, Movies, Music, and Pictures for files above the size threshold. These are your files — nothing is pre-selected, and iCloud-only files are flagged as freeing no local space.",
                    primaryLabel: "Scan",
                    primaryAction: { Task { await model.scanLargeFiles() } }
                )
            }
        case .scanning:
            ScanRing(progress: model.scanProgress, label: "Measuring files…")
        case .review:
            VStack(spacing: 0) {
                modeSwitch
                if viewMode == .bubbles {
                    LargeFilesBubbleReview()
                } else {
                    ReviewList()
                }
            }
        case .acting:
            ScanRing(label: "Cleaning…", indeterminate: true)
        case .report:
            ReportView()
        }
    }

    /// Same inline pill switch as the Uninstaller's Applications/Leftovers
    /// toggle — Bubbles is the default: the same "visualize every file as a
    /// sized, clickable bubble" idea as Space Lens, just over a flat file list
    /// instead of a folder tree. List stays available for category grouping,
    /// badges, and Quick Look.
    private var modeSwitch: some View {
        HStack(spacing: 2) {
            ForEach(ReviewMode.allCases, id: \.self) { m in
                Button(m.rawValue) { viewMode = m }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(viewMode == m ? .white : Brand.fog)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(viewMode == m ? Brand.indigo : .clear, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(3)
        .frame(width: 160)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.09)))
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

// MARK: - Bubble review (same visual system as Space Lens)

private struct LargeFilesBubbleReview: View {
    @Environment(AppModel.self) private var model
    @State private var hoverID: UUID?
    @State private var confirmingPermanent = false

    private var focus: Finding? {
        guard let hoverID else { return nil }
        return model.findings.first { $0.id == hoverID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                BubbleMap(findings: model.findings, selection: model.selected, hoverID: $hoverID,
                          onToggle: { if !$0.isProtected { model.toggle($0.id) } })
                    .frame(minWidth: 320, minHeight: 320)
                DetailsPanel(focus: focus, selectedCount: model.selected.count,
                             selectedBytes: model.reclaimableBytes, totalCount: model.findings.count)
                    .frame(width: 280)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            Divider()
            actionBar
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
                Label("Clean \(AppModel.format(model.reclaimableBytes))", systemImage: "sparkles")
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

private struct BubbleMap: View {
    let findings: [Finding]
    let selection: Set<UUID>
    @Binding var hoverID: UUID?
    let onToggle: (Finding) -> Void

    var body: some View {
        GeometryReader { geo in
            let ids = findings.map(\.id.uuidString)
            let laid = packCircles(ids: ids, bytes: findings.map(\.realOnDiskBytes), size: geo.size)
            ZStack {
                ForEach(Array(zip(findings.enumerated(), laid)), id: \.0.element.id) { pair, circle in
                    let (index, finding) = pair
                    BubbleCircleView(
                        label: finding.displayLabel ?? finding.path.lastPathComponent,
                        sizeLabel: AppModel.format(finding.realOnDiskBytes),
                        color: BubbleColors.palette[index % BubbleColors.palette.count],
                        radius: circle.r,
                        isSelectable: !finding.isProtected,
                        isSelected: selection.contains(finding.id),
                        isHovering: hoverID == finding.id,
                        onEnter: { hoverID = finding.id },
                        onExit: { if hoverID == finding.id { hoverID = nil } },
                        onTap: { onToggle(finding) })
                    .frame(width: circle.r * 2, height: circle.r * 2)
                    .position(x: circle.cx, y: circle.cy)
                }
            }
            .animation(.spring(duration: 0.34), value: findings.map(\.id))
        }
    }
}

private struct DetailsPanel: View {
    let focus: Finding?
    let selectedCount: Int
    let selectedBytes: Int64
    let totalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let focus {
                header(focus)
            } else {
                summary
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.black.opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOVER A BUBBLE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color(hex: 0x6F6A86))
            Text("\(selectedCount) of \(totalCount) selected")
                .font(Brand.display(18))
                .foregroundStyle(.white)
            if selectedCount > 0 {
                Text(AppModel.format(selectedBytes))
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.fog)
            }
        }
        .padding(16)
    }

    private func header(_ finding: Finding) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HOVERING")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color(hex: 0x6F6A86))
            Text(finding.displayLabel ?? finding.path.lastPathComponent)
                .font(Brand.display(16))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.top, 3)
            Text(AppModel.format(finding.realOnDiskBytes))
                .font(Brand.display(20))
                .foregroundStyle(.white)
                .padding(.top, 8)
            Text(finding.path.deletingLastPathComponent().path)
                .font(.system(size: 11))
                .foregroundStyle(Brand.fog)
                .lineLimit(2)
                .padding(.top, 3)
            if let modified = finding.modifiedAt {
                Text(modified, format: .dateTime.year().month().day())
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.fog)
                    .padding(.top, 2)
            }
            HStack(spacing: 6) {
                if finding.isProtected {
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
            .padding(.top, 10)
        }
        .padding(16)
    }
}
