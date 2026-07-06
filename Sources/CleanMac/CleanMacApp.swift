import SwiftUI
import AppKit

@main
struct CleanMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = makeModel()

    var body: some Scene {
        WindowGroup("CleanMac") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 720)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1160, height: 800)
    }

    private static func makeModel() -> AppModel {
        do { return try AppModel() }
        catch { fatalError("Failed to initialize CleanMac: \(error)") }
    }
}

/// Enforces the main window's size directly through AppKit. SwiftUI's window
/// sizing (and any stale restored frame) can bring the window up too short to
/// show the whole sidebar; this resizes it once the window exists.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The WindowGroup window may not exist yet at launch, so retry a couple
        // of runloop turns to pin the minimum size.
        for delay in [0.0, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.enforceMinSize() }
        }
    }

    private func enforceMinSize() {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.canBecomeMain })
        else { return }
        window.minSize = NSSize(width: 1000, height: 720)
        // Immersive canvas: run the space gradient under a transparent titlebar
        // so the toolbar reads as part of the plum background instead of macOS's
        // grey toolbar material. The window background matches the gradient's
        // darkest stop so no grey shows during resize.
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = NSColor(srgbRed: 0.09, green: 0.07, blue: 0.14, alpha: 1)
    }
}

/// Sidebar + detail. All ten §4 modules are live — interchangeable scanner
/// front-ends on one pipeline (§2). Dashboard is the landing view (§4.8).
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem = .dashboard

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            // Pin the detail content to exactly the available size and clip any
            // overflow, so a greedy module view can't dictate the split view's
            // height and push the sidebar's rows out of view.
            GeometryReader { geo in
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
                .id(selection)
                .transition(.opacity)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
            .background(SpaceBackground())
        }
        .animation(.easeInOut(duration: 0.15), value: selection)
        // Drop macOS's grey toolbar material so the transparent titlebar shows
        // the space gradient behind the window title.
        .toolbarBackground(.hidden, for: .windowToolbar)
        // Brand accent everywhere: buttons, toggles, progress, selection.
        .tint(Brand.indigo)
        // The layout is designed dark (immersive gradient canvas).
        .preferredColorScheme(.dark)
    }
}
