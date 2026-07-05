import SwiftUI

/// Sidebar entries mirror the §4 module list — all ten modules are live, each
/// one a scanner front-end on the same pipeline (§2). Smart Scan leads,
/// standalone and pre-selected: it is the overview + one-click entry point
/// (§4.8).
enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Smart Scan"
    case systemJunk = "System Junk"
    case largeFiles = "Large & Old Files"
    case duplicates = "Duplicate Finder"
    case snapshots = "Local Snapshots"
    case iosBackups = "iOS Backups"
    case uninstaller = "Uninstaller"
    case startup = "Startup Items"
    case privacy = "Privacy"
    case spaceLens = "Space Lens"
    case trash = "Trash / Restore"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dashboard: return "wand.and.stars"
        case .systemJunk: return "trash.circle"
        case .largeFiles: return "doc.on.doc"
        case .snapshots: return "clock.arrow.circlepath"
        case .uninstaller: return "xmark.bin"
        case .iosBackups: return "iphone"
        case .duplicates: return "square.on.square"
        case .startup: return "power"
        case .privacy: return "hand.raised"
        case .spaceLens: return "circle.grid.3x3"
        case .trash: return "arrow.uturn.backward.circle"
        }
    }

    /// Accent hue per module — used by hero illustrations and the dashboard
    /// category rows.
    var tint: Color {
        switch self {
        case .dashboard: return Brand.indigo
        case .systemJunk: return .orange
        case .largeFiles: return .blue
        case .snapshots: return .purple
        case .uninstaller: return Brand.danger
        case .iosBackups: return .cyan
        case .duplicates: return .green
        case .startup: return .yellow
        case .privacy: return .pink
        case .spaceLens: return .teal
        case .trash: return .gray
        }
    }

    /// One-line pitch shown under module titles where a hint is useful.
    var blurb: String {
        switch self {
        case .dashboard: return "Give your Mac a nice and thorough scan"
        case .systemJunk: return "Caches, logs, and leftovers safe to clear"
        case .largeFiles: return "Hunt down the biggest space hogs"
        case .snapshots: return "Time Machine snapshots hiding gigabytes"
        case .uninstaller: return "Remove apps and every trace they leave"
        case .iosBackups: return "Stale iPhone and iPad backups"
        case .duplicates: return "Identical files, matched by content"
        case .startup: return "Control what launches at login"
        case .privacy: return "Clear histories, cookies, and traces"
        case .spaceLens: return "Your disk as an interactive map"
        case .trash: return "Restore anything for 30 days"
        }
    }

    /// CleanMyMac-style grouping: Smart Scan standalone on top, then themed
    /// sections.
    static let sections: [(title: String?, items: [SidebarItem])] = [
        (nil, [.dashboard]),
        ("Cleanup", [.systemJunk, .snapshots, .iosBackups, .duplicates]),
        ("Protection", [.privacy]),
        ("Speedup", [.startup]),
        ("Applications", [.uninstaller]),
        ("Files", [.largeFiles, .spaceLens]),
        ("Restore", [.trash]),
    ]
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem

    var body: some View {
        List(selection: $selection) {
            // Brand lockup as the sidebar masthead, like the reference's
            // title row.
            BrandMark(ringDiameter: 18, wordmarkSize: 14)
                .padding(.vertical, 6)
                .listRowSeparator(.hidden)

            ForEach(Array(SidebarItem.sections.enumerated()), id: \.offset) { _, section in
                if let title = section.title {
                    Section(title) {
                        ForEach(section.items) { item in
                            row(item).tag(item)
                        }
                    }
                } else {
                    ForEach(section.items) { item in
                        row(item).tag(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("CleanMac")
        .frame(minWidth: 220)
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        Label {
            Text(item.rawValue)
        } icon: {
            // Flat monochrome line icons, per the reference layout.
            Image(systemName: item.systemImage)
                .foregroundStyle(selection == item ? Brand.ink : Brand.fog)
        }
        .badge(item == .trash && !model.trashRecords.isEmpty
               ? model.trashRecords.count : 0)
    }
}
