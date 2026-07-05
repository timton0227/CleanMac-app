import SwiftUI

@main
struct CleanMacApp: App {
    @State private var model = makeModel()

    var body: some Scene {
        WindowGroup("CleanMac") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
        }
        // Open roomy enough for sidebar + hero; user-resizable from there.
        .defaultSize(width: 1080, height: 700)
    }

    private static func makeModel() -> AppModel {
        do { return try AppModel() }
        catch { fatalError("Failed to initialize CleanMac: \(error)") }
    }
}

/// Sidebar + detail. All ten §4 modules are live — interchangeable scanner
/// front-ends on one pipeline (§2). Dashboard is the landing view (§4.8).
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem = .dashboard
    // Pin the sidebar open — .automatic can launch with the column collapsed
    // or half-shown.
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            ZStack {
                // The immersive canvas sits behind every module screen.
                SpaceBackground()
                Group {
                    switch selection {
                    case .dashboard: DashboardView(selection: $selection)
                    case .systemJunk: SystemJunkView()
                    case .largeFiles: LargeFilesView()
                    case .snapshots: SnapshotsView()
                    case .uninstaller: UninstallerView()
                    case .iosBackups: IOSBackupsView()
                    case .duplicates: DuplicatesView()
                    case .startup: StartupView()
                    case .privacy: PrivacyView()
                    case .spaceLens: SpaceLensView()
                    case .trash: TrashView()
                    }
                }
                // Cross-fade between modules instead of a hard cut.
                .id(selection)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: selection)
        // Brand accent everywhere: buttons, toggles, progress, selection.
        .tint(Brand.indigo)
        // The layout is designed dark (immersive gradient canvas).
        .preferredColorScheme(.dark)
    }
}
