import SwiftUI
import QuickLook
import CleanCore

/// Space Lens (§4.9): the interactive storage map. The mock renders this as a
/// force-packed bubble map with a persistent details panel — not a treemap —
/// so this view reproduces that layout exactly (`packCircles`/`buildBubble`/
/// `buildDetails`) over the same real, live-updating tree (FR-UX-LIVE).
/// Bubbles are sized by **real on-disk bytes**; plain folders drill in on
/// click, files and packages toggle selection; selected items delete through
/// the shared engine (reversible, audit-logged, protected-path checked).
struct SpaceLensView: View {
    @Environment(AppModel.self) private var model
    @State private var drillPath: [URL] = []
    @State private var hoverNode: SpaceNode?
    @State private var showingFolderPicker = false
    @State private var confirmingDelete = false
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            // Idle (no map yet) opens with a full-bleed hero, consistent with
            // Smart Scan; the storage chrome appears once a map is loaded.
            if model.spaceScanning || model.spaceTree != nil {
                StorageHeader()
                Divider()
            }
            content
        }
        .navigationTitle("Space Lens")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Choose Folder…") { showingFolderPicker = true }
            }
            if model.spaceTree != nil {
                ToolbarItem(placement: .automatic) {
                    Button("Rescan") { rescan() }
                }
            }
        }
        .fileImporter(isPresented: $showingFolderPicker,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                drillPath = []
                Task { await model.scanSpaceLens(root: url) }
            }
        }
    }

    private func rescan() {
        drillPath = []
        hoverNode = nil
        Task { await model.scanSpaceLens() }
    }

    @ViewBuilder
    private var content: some View {
        if model.spaceScanning {
            ScanRing(progress: model.spaceProgress,
                     label: "Mapping \(model.spaceRootURL.lastPathComponent)…")
        } else if let tree = model.spaceTree {
            let current = resolve(tree)
            let items = Self.displayedItems(for: current)
            breadcrumbs(tree: tree, current: current)
            HStack(alignment: .top, spacing: 18) {
                BubbleMap(items: items, selection: model.spaceSelection, hoverNode: $hoverNode,
                          onDrill: drill, onToggle: { model.toggleSpaceSelection($0) })
                    .frame(minWidth: 320, minHeight: 320)
                DetailsPanel(
                    current: current, focus: hoverNode ?? current, hoverNode: hoverNode, items: items,
                    rootBytes: tree.realBytes, selection: model.spaceSelection,
                    onHover: { hoverNode = $0 },
                    onSelectToggle: { model.toggleSpaceSelection($0) },
                    onClickItem: click)
                .frame(width: 300)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .quickLookPreview($quickLookURL)
            Divider()
            actionBar
        } else {
            ModuleHero(
                icon: SidebarItem.spaceLens.systemImage,
                tint: SidebarItem.spaceLens.tint,
                title: "Space Lens",
                message: "Maps your storage as a bubble chart so the heaviest folders and files — including hidden ones — stand out at a glance. Click a folder to drill in; click a file to select it; remove selections straight from the map (reversible via the Trash tab). Bubble sizes are real on-disk bytes, so iCloud-only files and hardlinks aren't overstated.",
                primaryLabel: "Map",
                primaryAction: { Task { await model.scanSpaceLens() } }
            ) {
                Button("Choose Folder…") { showingFolderPicker = true }
            }
        }
    }

    /// Walk the drill path down the (possibly live-updated) tree; vanished
    /// segments (deleted mid-drill) are dropped gracefully.
    private func resolve(_ tree: SpaceNode) -> SpaceNode {
        var current = tree
        for url in drillPath {
            guard let next = current.children.first(where: { $0.path == url }) else { break }
            current = next
        }
        return current
    }

    private func drill(_ node: SpaceNode) {
        drillPath.append(node.path)
        hoverNode = nil
    }

    private func click(_ node: SpaceNode) {
        if node.isDrillable { drill(node) } else { model.toggleSpaceSelection(node) }
    }

    private func breadcrumbs(tree: SpaceNode, current: SpaceNode) -> some View {
        HStack(spacing: 5) {
            crumb(tree.name, active: drillPath.isEmpty) { drillPath = []; hoverNode = nil }
            ForEach(Array(drillPath.enumerated()), id: \.element) { index, url in
                Text("›").font(.system(size: 12)).foregroundStyle(Color(hex: 0x6F6A86))
                crumb(url.lastPathComponent, active: index == drillPath.count - 1) {
                    drillPath = Array(drillPath.prefix(index + 1)); hoverNode = nil
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
    }

    private func crumb(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? .white : Brand.fog)
    }

    private var actionBar: some View {
        HStack {
            Text(model.spaceSelection.isEmpty
                 ? "Click a folder to drill in · click a file or app to mark it for removal"
                 : "\(model.spaceSelection.count) selected · \(AppModel.format(model.spaceSelectedBytes))")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            if !model.spaceSelection.isEmpty {
                Button("Clear") { model.spaceSelection = [:] }
            }
            Spacer()
            Button(model.spaceSelection.isEmpty ? "Move to Trash"
                   : "Move \(AppModel.format(model.spaceSelectedBytes)) to Trash") {
                confirmingDelete = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.spaceSelection.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .confirmationDialog(
            "Move \(model.spaceSelection.count) item(s) to the app Trash? Restorable for 30 days from the Trash tab.",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Move to Trash") { Task { await model.deleteSpaceSelection() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Displayed items (mock's `displayed()`)

    /// Top ~20 children whose share is at least 0.8% of the parent, plus a
    /// "smaller items" bucket for everything else (below that share, past the
    /// cap, or already folded into `prunedBytes` at build time).
    static func displayedItems(for node: SpaceNode) -> [BubbleItem] {
        let total = max(node.realBytes, 1)
        var shown: [SpaceNode] = []
        var hiddenBytes = node.prunedBytes
        for child in node.children {
            if child.realBytes >= total / 125 && shown.count < 20 {
                shown.append(child)
            } else {
                hiddenBytes += child.realBytes
            }
        }
        var items = shown.enumerated().map { index, child in
            BubbleItem(id: child.path.path, node: child, bytes: child.realBytes,
                       color: BubbleColors.palette[index % BubbleColors.palette.count])
        }
        if hiddenBytes > total / 1000 {
            items.append(BubbleItem(id: node.path.path + "#others", node: nil,
                                    bytes: hiddenBytes, color: BubbleColors.muted))
        }
        return items
    }
}

/// One bubble (or the aggregated "smaller items" bubble, `node == nil`).
struct BubbleItem: Identifiable {
    let id: String
    let node: SpaceNode?
    let bytes: Int64
    let color: Color
}

// MARK: - Bubble map (circle packing via the shared `packCircles`/`BubbleCircleView`)

private struct BubbleMap: View {
    let items: [BubbleItem]
    let selection: [URL: Int64]
    @Binding var hoverNode: SpaceNode?
    let onDrill: (SpaceNode) -> Void
    let onToggle: (SpaceNode) -> Void

    var body: some View {
        GeometryReader { geo in
            let laid = packCircles(ids: items.map(\.id), bytes: items.map(\.bytes), size: geo.size)
            ZStack {
                ForEach(Array(zip(items, laid)), id: \.0.id) { item, circle in
                    let drillable = item.node?.isDrillable ?? false
                    BubbleCircleView(
                        label: item.node?.name ?? "smaller items",
                        sizeLabel: AppModel.format(item.bytes),
                        color: item.color,
                        radius: circle.r,
                        fillOpacity: item.node != nil ? (drillable ? 0.92 : 0.72) : 0.3,
                        isSelected: item.node.map { selection[$0.path] != nil } ?? false,
                        isHovering: item.node != nil && item.node?.path == hoverNode?.path,
                        onEnter: { hoverNode = item.node },
                        onExit: { if hoverNode?.path == item.node?.path { hoverNode = nil } },
                        onTap: {
                            guard let node = item.node else { return }
                            if node.isDrillable { onDrill(node) } else { onToggle(node) }
                        })
                    .frame(width: circle.r * 2, height: circle.r * 2)
                    .position(x: circle.cx, y: circle.cy)
                }
            }
            .animation(.spring(duration: 0.34), value: items.map(\.id))
        }
    }
}

// MARK: - Details panel (matching the mock's `buildDetails`)

private struct DetailsPanel: View {
    let current: SpaceNode
    let focus: SpaceNode
    let hoverNode: SpaceNode?
    let items: [BubbleItem]
    let rootBytes: Int64
    let selection: [URL: Int64]
    let onHover: (SpaceNode?) -> Void
    let onSelectToggle: (SpaceNode) -> Void
    let onClickItem: (SpaceNode) -> Void

    private var isCurrent: Bool { focus.path == current.path }
    private var isSelected: Bool { selection[focus.path] != nil }
    private var typeLabel: String {
        focus.isPackage ? "Package" : focus.isDirectory ? "Folder" : "File"
    }
    private var sharePercent: Double {
        rootBytes > 0 ? Double(focus.realBytes) / Double(rootBytes) * 100 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text("CONTENTS · LARGEST FIRST")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color(hex: 0x6F6A86))
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 0) {
                    if items.isEmpty {
                        Text(focus.isDrillable ? "Empty folder." : "This is a file — select it on the map to reclaim its space.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color(hex: 0x8F8BA6))
                            .padding(16)
                    } else {
                        ForEach(items.filter { $0.node != nil }.prefix(9)) { item in
                            contentsRow(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isCurrent ? "CURRENT FOLDER" : "HOVERING")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color(hex: 0x6F6A86))
            Text(focus.name)
                .font(Brand.display(18))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.top, 3)
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(AppModel.format(focus.realBytes))
                    .font(Brand.display(22))
                    .foregroundStyle(.white)
                Text("\(sharePercent >= 10 ? String(Int(sharePercent.rounded())) : String(format: "%.1f", sharePercent))% of disk")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.fog)
            }
            .padding(.top, 8)
            HStack(spacing: 6) {
                Text(typeLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Brand.indigo)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Brand.indigo.opacity(0.14), in: Capsule())
                if !focus.children.isEmpty {
                    Text("\(focus.children.count) items")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(hex: 0xB9B6CC))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.07), in: Capsule())
                }
                if !isCurrent, !focus.isDrillable {
                    Button {
                        onSelectToggle(focus)
                    } label: {
                        Text(isSelected ? "✓ Selected" : "Select")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(isSelected ? Brand.indigo : Color(hex: 0xB9B6CC))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.white.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 13)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
        }
    }

    private func contentsRow(_ item: BubbleItem) -> some View {
        guard let node = item.node else { return AnyView(EmptyView()) }
        let hovering = hoverNode?.path == node.path
        let selected = selection[node.path] != nil
        let pct = max(2, Double(item.bytes) / Double(max(current.realBytes, 1)) * 100)
        return AnyView(
            Button {
                onClickItem(node)
            } label: {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: node.isDrillable ? 3 : 5)
                        .fill(item.color)
                        .frame(width: 10, height: 10)
                        .overlay(
                            RoundedRectangle(cornerRadius: node.isDrillable ? 4 : 6)
                                .strokeBorder(Brand.indigo, lineWidth: selected ? 2 : 0)
                                .padding(-2))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(node.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(AppModel.format(item.bytes))
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.fog)
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.white.opacity(0.08))
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(item.color)
                                        .frame(width: geo.size.width * pct / 100)
                                }
                        }
                        .frame(height: 4)
                    }
                    Text(node.isDrillable ? "›" : selected ? "✓" : "")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(node.isDrillable ? Color(hex: 0x8F8BA6) : selected ? Brand.indigo : Color(hex: 0x6F6A86))
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(hovering ? .white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onHover { entering in onHover(entering ? node : nil) }
        )
    }
}
