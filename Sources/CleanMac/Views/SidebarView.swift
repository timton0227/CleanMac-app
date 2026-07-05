import SwiftUI

/// Sidebar entries mirror the §4 module list — all ten modules are live, each
/// one a scanner front-end on the same pipeline (§2). Dashboard leads: it is
/// the overview + one-click Smart Scan entry point (§4.8).
enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
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
        case .dashboard: return "gauge"
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

    /// Icon-tile tint — one hue per module so the sidebar and the dashboard
    /// grid are scannable at a glance.
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

    /// One-line pitch shown on the dashboard's module grid.
    var blurb: String {
        switch self {
        case .dashboard: return "Overview and one-click Smart Scan"
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

    /// Grouped navigation — related modules sit together instead of one flat
    /// eleven-row list.
    static let sections: [(title: String, items: [SidebarItem])] = [
        ("Overview", [.dashboard]),
        ("Cleanup", [.systemJunk, .largeFiles, .duplicates, .snapshots, .iosBackups]),
        ("Applications", [.uninstaller, .startup]),
        ("Privacy & Explore", [.privacy, .spaceLens]),
        ("Restore", [.trash]),
    ]
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarItem.sections, id: \.title) { section in
                Section {
                    ForEach(section.items) { item in
                        row(item).tag(item)
                    }
                } header: {
                    if section.title == "Overview" {
                        BrandMark(ringDiameter: 18, wordmarkSize: 14)
                            .padding(.bottom, 4)
                            .textCase(nil)
                    } else {
                        Text(section.title)
                    }
                }
            }
        }
        .navigationTitle("CleanMac")
        .frame(minWidth: 230)
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        Label {
            Text(item.rawValue)
        } icon: {
            Image(systemName: item.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
        }
        .badge(item == .trash && !model.trashRecords.isEmpty
               ? model.trashRecords.count : 0)
    }
}
