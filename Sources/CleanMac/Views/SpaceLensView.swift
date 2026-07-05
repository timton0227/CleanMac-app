import SwiftUI
import QuickLook
import CleanCore

/// Space Lens (§4.9): the interactive storage map. Tiles are sized by **real
/// on-disk bytes**; plain folders drill in on click, files and packages toggle
/// selection; selected tiles delete through the shared engine (reversible,
/// audit-logged, protected-path checked) and the map shrinks in place without
/// a rescan (FR-UX-LIVE).
struct SpaceLensView: View {
    @Environment(AppModel.self) private var model
    @State private var drillPath: [URL] = []
    @State private var showingFolderPicker = false
    @State private var confirmingDelete = false
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            StorageHeader()
            Divider()
            content
        }
        .navigationTitle("Space Lens")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Choose Folder…") { showingFolderPicker = true }
            }
            if model.spaceTree != nil {
                ToolbarItem(placement: .automatic) {
                    Button("Rescan") {
                        drillPath = []
                        Task { await model.scanSpaceLens() }
                    }
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

    @ViewBuilder
    private var content: some View {
        if model.spaceScanning {
            ScanRing(progress: model.spaceProgress,
                     label: "Mapping \(model.spaceRootURL.lastPathComponent)…")
        } else if let tree = model.spaceTree {
            let current = resolve(tree)
            breadcrumbs(tree: tree, current: current)
            TreemapView(node: current,
                        selection: model.spaceSelection,
                        onDrill: { drillPath.append($0.path) },
                        onToggle: { model.toggleSpaceSelection($0) },
                        onQuickLook: { quickLookURL = $0.path })
                .padding(8)
                .quickLookPreview($quickLookURL)
            Divider()
            actionBar
        } else {
            ModuleHero(
                icon: SidebarItem.spaceLens.systemImage,
                tint: SidebarItem.spaceLens.tint,
                title: "Space Lens",
                message: "Maps your storage as sized tiles so the heaviest folders and files — including hidden ones — stand out at a glance. Click a folder to drill in; click a file to select it; remove selections straight from the map (reversible via the Trash tab). Tile sizes are real on-disk bytes, so iCloud-only files and hardlinks aren't overstated.",
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

    private func breadcrumbs(tree: SpaceNode, current: SpaceNode) -> some View {
        HStack(spacing: 4) {
            Button(tree.name) { drillPath = [] }
                .buttonStyle(.link)
            ForEach(Array(drillPath.enumerated()), id: \.element) { index, url in
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.secondary)
                Button(url.lastPathComponent) {
                    drillPath = Array(drillPath.prefix(index + 1))
                }
                .buttonStyle(.link)
            }
            Spacer()
            Text(AppModel.format(current.realBytes)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var actionBar: some View {
        HStack {
            Text("\(model.spaceSelection.count) selected · \(AppModel.format(model.spaceSelectedBytes))")
                .foregroundStyle(.secondary)
            if !model.spaceSelection.isEmpty {
                Button("Clear") { model.spaceSelection = [:] }
            }
            Spacer()
            Button("Move \(AppModel.format(model.spaceSelectedBytes)) to Trash") {
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
}

// MARK: - Treemap

private struct TreemapView: View {
    let node: SpaceNode
    let selection: [URL: Int64]
    let onDrill: (SpaceNode) -> Void
    let onToggle: (SpaceNode) -> Void
    let onQuickLook: (SpaceNode) -> Void

    var body: some View {
        GeometryReader { geo in
            let tiles = layout(in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    TreemapTile(tile: tile,
                                isSelected: tile.node.map { selection[$0.path] != nil } ?? false,
                                onDrill: onDrill, onToggle: onToggle,
                                onQuickLook: onQuickLook)
                        .frame(width: tile.rect.width, height: tile.rect.height)
                        .offset(x: tile.rect.minX, y: tile.rect.minY)
                }
            }
        }
    }

    struct Tile: Identifiable {
        let id: Int
        let node: SpaceNode?   // nil = the aggregated "smaller items" tile
        let bytes: Int64
        let rect: CGRect
    }

    private func layout(in size: CGSize) -> [Tile] {
        var entries: [(SpaceNode?, Int64)] = node.children.map { ($0, $0.realBytes) }
        if node.prunedBytes > 0 { entries.append((nil, node.prunedBytes)) }
        entries = entries.filter { $0.1 > 0 }
        guard !entries.isEmpty else { return [] }

        let rects = squarify(values: entries.map { Double($0.1) },
                             in: CGRect(origin: .zero, size: size))
        return zip(entries, rects).enumerated().map { index, pair in
            Tile(id: index, node: pair.0.0, bytes: pair.0.1, rect: pair.1.insetBy(dx: 1, dy: 1))
        }
    }
}

private struct TreemapTile: View {
    let tile: TreemapView.Tile
    let isSelected: Bool
    let onDrill: (SpaceNode) -> Void
    let onToggle: (SpaceNode) -> Void
    let onQuickLook: (SpaceNode) -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(fillColor)
                .brightness(hovering ? 0.06 : 0)
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(isSelected ? Brand.indigo
                              : hovering ? Brand.indigo.opacity(0.6)
                              : .black.opacity(0.15),
                              lineWidth: isSelected ? 2 : hovering ? 1.5 : 0.5)
            if tile.rect.width > 56, tile.rect.height > 26 {
                VStack(alignment: .leading, spacing: 0) {
                    Text(label).font(.caption).bold().lineLimit(1)
                    Text(AppModel.format(tile.bytes)).font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }
        }
        .help("\(label) — \(AppModel.format(tile.bytes))")
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture {
            guard let node = tile.node else { return }
            if node.isDrillable { onDrill(node) } else { onToggle(node) }
        }
        .contextMenu {
            if let node = tile.node {
                Button(isSelected ? "Deselect" : "Select for removal") { onToggle(node) }
                if !node.isDirectory {
                    Button("Quick Look") { onQuickLook(node) }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.path])
                }
            }
        }
    }

    private var label: String {
        tile.node?.name ?? "smaller items"
    }

    private var fillColor: Color {
        guard let node = tile.node else { return .gray.opacity(0.25) }
        if isSelected { return Brand.indigo.opacity(0.45) }
        if node.isPackage { return .purple.opacity(0.35) }
        if node.isDirectory { return Brand.indigo.opacity(0.25) }
        return .teal.opacity(0.35)
    }
}

// MARK: - Squarified layout (Bruls, Huizing & van Wijk)

/// Lays out `values` (sorted descending, positive) inside `rect`, keeping tile
/// aspect ratios near 1 so sizes are visually comparable.
private func squarify(values: [Double], in rect: CGRect) -> [CGRect] {
    var results = [CGRect](repeating: .zero, count: values.count)
    let total = values.reduce(0, +)
    guard total > 0, rect.width > 0, rect.height > 0 else { return results }

    let scale = Double(rect.width * rect.height) / total
    let areas = values.map { $0 * scale }
    var remaining = rect
    var index = 0

    while index < areas.count {
        let shortSide = Double(min(remaining.width, remaining.height))
        guard shortSide > 0 else { break }

        // Grow the row while it improves the worst aspect ratio.
        var count = 1
        var rowSum = areas[index]
        var worst = worstRatio(areas[index..<index + 1], rowSum, shortSide)
        while index + count < areas.count {
            let nextSum = rowSum + areas[index + count]
            let nextWorst = worstRatio(areas[index..<index + count + 1], nextSum, shortSide)
            if nextWorst > worst { break }
            count += 1
            rowSum = nextSum
            worst = nextWorst
        }

        // Place the row along the short side.
        let thickness = rowSum / shortSide
        var offset = 0.0
        if remaining.width >= remaining.height {
            for i in 0..<count {
                let h = areas[index + i] / thickness
                results[index + i] = CGRect(x: remaining.minX, y: remaining.minY + offset,
                                            width: thickness, height: h)
                offset += h
            }
            remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                               width: remaining.width - thickness, height: remaining.height)
        } else {
            for i in 0..<count {
                let w = areas[index + i] / thickness
                results[index + i] = CGRect(x: remaining.minX + offset, y: remaining.minY,
                                            width: w, height: thickness)
                offset += w
            }
            remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                               width: remaining.width, height: remaining.height - thickness)
        }
        index += count
    }
    return results
}

private func worstRatio(_ row: ArraySlice<Double>, _ sum: Double, _ side: Double) -> Double {
    guard let maxArea = row.max(), let minArea = row.min(), sum > 0, minArea > 0 else {
        return .infinity
    }
    let s2 = sum * sum
    let side2 = side * side
    return max(side2 * maxArea / s2, s2 / (side2 * minArea))
}
