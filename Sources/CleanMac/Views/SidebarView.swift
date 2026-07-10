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
    /// category rows. Exact hex values from the design mock.
    var tint: Color {
        switch self {
        case .dashboard: return Brand.indigo
        case .systemJunk: return Brand.systemJunk
        case .largeFiles: return Brand.largeFiles
        case .snapshots: return Brand.snapshots
        case .uninstaller: return Brand.uninstaller
        case .iosBackups: return Brand.iosBackups
        case .duplicates: return Brand.duplicates
        case .startup: return Brand.startup
        case .privacy: return Brand.privacy
        case .spaceLens: return Brand.spaceLens
        case .trash: return Brand.trash
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

/// The sidebar's own gradient — a plain 2-stop wash, distinct from (and a
/// touch darker than) the 3-stop gradient behind the main content, matching
/// the design mock's separate sidebar/content panes. No starfield here: the
/// mock only scatters stars behind the main pane.
private struct SidebarBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(hex: 0x241C35), Color(hex: 0x15101F)],
            startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BrandMark(ringDiameter: 22, wordmarkSize: 16)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 10)

                ForEach(Array(SidebarItem.sections.enumerated()), id: \.offset) { _, section in
                    if let title = section.title {
                        sectionHeader(title)
                    }
                    ForEach(section.items) { item in
                        row(item)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .background(SidebarBackground())
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Color(hex: 0x6F6A86))
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 5)
    }

    private func row(_ item: SidebarItem) -> some View {
        let active = model.selection == item
        let badgeCount = item == .trash ? model.trashRecords.count : 0

        return Button {
            model.selection = item
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(item.tint)
                    .frame(width: 9, height: 9)
                Text(item.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? Brand.ink : Brand.fog)
                Spacer(minLength: 0)
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color(hex: 0x5C5670), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Brand.indigo.opacity(0.18) : .clear))
            .overlay(alignment: .leading) {
                if active {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Brand.indigo)
                        .frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 0.5)
    }
}
