import SwiftUI
import CleanCore

/// Application Uninstaller + leftovers (§4.4). Two modes on the same pipeline:
///
/// - **Applications**: pick installed apps → scan bundle + associated files →
///   standard Review → reversible removal to the app Trash. Deselecting the
///   `.app` bundle row in Review turns an uninstall into an *app reset*.
/// - **Leftovers**: files whose owning app is already gone — Finder-invisible,
///   never removed by drag-to-Trash. All low-confidence, never pre-selected.
///
/// A watcher on /Applications raises a banner offering a leftovers sweep when
/// an app is removed outside this app (drag-to-Trash detection).
struct UninstallerView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .applications

    enum Mode: String, CaseIterable {
        case applications = "Applications"
        case leftovers = "Leftovers"
    }

    private var moduleId: String {
        mode == .applications ? "app-uninstall" : "app-leftovers"
    }
    private var ownsPipeline: Bool { model.activeModuleId == moduleId }
    private var phase: AppModel.Phase { ownsPipeline ? model.phase : .idle }

    var body: some View {
        VStack(spacing: 0) {
            // Idle opens with a full-bleed hero, consistent with Smart Scan;
            // the storage + phase chrome appears only once a run is underway.
            if phase != .idle {
                StorageHeader()
                PhaseBar(phase: phase, actLabel: mode == .applications ? "Uninstall" : "Clean")
                Divider()
            }
            if model.applicationsChangedExternally {
                InfoBanner(icon: "info.circle.fill", tint: .blue,
                           text: "The Applications folder changed — an app may have been removed. Its support files are likely still on disk.") {
                    Button("Scan for Leftovers") {
                        mode = .leftovers
                        Task { await model.scanLeftovers() }
                    }
                }
            }
            modeSwitch
            content
        }
        .navigationTitle("Uninstaller")
        .task {
            model.loadInstalledApps()
            // Arriving from a Smart Scan leftovers review (§4.8): land on the
            // segment that owns the pipeline instead of hiding the findings.
            if model.activeModuleId == "app-leftovers" { mode = .leftovers }
        }
    }

    /// The mock's inline Applications/Leftovers switch — a 220px pill row atop
    /// the content column, not a window-toolbar segmented control.
    private var modeSwitch: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button(m.rawValue) { mode = m }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mode == m ? .white : Brand.fog)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(mode == m ? Brand.indigo : .clear, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(3)
        .frame(width: 220)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.09)))
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .applications:
            if ownsPipeline && model.phase != .idle {
                pipelineBody
            } else {
                appPicker
            }
        case .leftovers:
            if ownsPipeline && model.phase != .idle {
                pipelineBody
            } else {
                leftoversIdle
            }
        }
    }

    @ViewBuilder
    private var pipelineBody: some View {
        switch model.phase {
        case .scanning:
            ScanRing(progress: model.scanProgress, label: "Tracing app files…")
        case .review:
            if mode == .applications {
                reviewHint
            }
            ReviewList(actLabel: mode == .applications ? "Uninstall" : "Clean")
        case .acting:
            ScanRing(label: "Cleaning…", indeterminate: true)
        case .report:
            ReportView()
        case .idle:
            EmptyView()
        }
    }

    private var reviewHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb").foregroundStyle(.secondary)
            Text("Tip: deselect the .app bundle itself to *reset* the app (clear its data but keep it installed). Removal is reversible from the Trash tab.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Applications mode

    private var appPicker: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.installedApps) { app in
                    AppRow(app: app)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Text("\(model.selectedApps.count) app(s) selected")
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: model.selectedApps.count)
                Spacer()
                Button("Refresh") { model.loadInstalledApps() }
                // Straight to scan — Review right after already requires
                // explicit per-item confirmation, so a pre-scan dialog was
                // redundant friction the mock doesn't have either.
                Button("Uninstall…") { Task { await model.scanUninstall() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedApps.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Leftovers mode

    @ViewBuilder
    private var leftoversIdle: some View {
        if model.hasNothingLeftToShow(for: "app-leftovers") {
            EmptyGoodState(tint: SidebarItem.uninstaller.tint,
                           message: "No leftovers from deleted apps found.")
        } else {
            ModuleHero(
                icon: "puzzlepiece.extension",
                tint: SidebarItem.uninstaller.tint,
                title: "App Leftovers",
                message: "Finds support files, preferences, caches, and launch agents left behind by apps that were deleted — parts that dragging an app to the Trash never removes. Detection is conservative: nothing is pre-selected.",
                primaryLabel: "Scan",
                primaryAction: { Task { await model.scanLeftovers() } }
            )
        }
    }
}

private struct AppRow: View {
    @Environment(AppModel.self) private var model
    let app: InstalledApp
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.selectedApps.contains(app.url) },
                set: { on in
                    if on { model.selectedApps.insert(app.url) }
                    else { model.selectedApps.remove(app.url) }
                }
            ))
            .labelsHidden()

            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable().frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                Text(app.bundleID ?? app.url.path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.isRunning(app) {
                BrandTag(text: "Running", color: Brand.startup)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(hovering ? Brand.indigo.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}
