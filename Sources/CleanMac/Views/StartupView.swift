import SwiftUI
import CleanCore

/// Startup & Login Item Manager (§4.5). Toggle list, not a delete pipeline:
/// user Launch Agents can be disabled/re-enabled (audit-logged through the
/// engine); system-wide agents/daemons are listed read-only until the
/// privileged helper (Infra A). Impact indicators are honest capabilities
/// ("launches at login", "always running") — no made-up startup-ms scores (§6).
struct StartupView: View {
    @Environment(AppModel.self) private var model

    private var grouped: [(StartupItem.Domain, [StartupItem])] {
        let order: [StartupItem.Domain] = [.userAgent, .systemAgent, .systemDaemon]
        let dict = Dictionary(grouping: model.startupItems, by: \.domain)
        return order.compactMap { domain in
            guard let items = dict[domain], !items.isEmpty else { return nil }
            return (domain, items)
        }
    }

    var body: some View {
        Group {
            if model.startupItemsLoading && model.startupItems.isEmpty {
                ScanRing(label: "Reading launch items…", indeterminate: true)
            } else if model.startupItems.isEmpty {
                ModuleHero(
                    icon: SidebarItem.startup.systemImage,
                    tint: SidebarItem.startup.tint,
                    title: "Startup Items",
                    message: "Lists Launch Agents and Daemons that run at login or in the background. Your own agents can be disabled and re-enabled; system-wide items become toggleable once the privileged helper is registered and approved (Dashboard → Privileged Helper). Login items managed by apps appear in System Settings → General → Login Items."
                ) {
                    Button("Scan") { Task { await model.loadStartupItems() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else {
                List {
                    ForEach(grouped, id: \.0) { domain, items in
                        Section {
                            ForEach(items) { StartupRow(item: $0) }
                        } header: {
                            HStack {
                                Text(domain.displayName)
                                if domain != .userAgent {
                                    Text(model.helper.isEnabled
                                         ? "· via privileged helper"
                                         : "· read-only (needs the privileged helper)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Startup Items")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Refresh") { Task { await model.loadStartupItems() } }
            }
        }
        .task { if model.startupItems.isEmpty { await model.loadStartupItems() } }
    }
}

private struct StartupRow: View {
    @Environment(AppModel.self) private var model
    let item: StartupItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { item.isEnabled },
                set: { _ in Task { await model.toggleStartupItem(item) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!model.canToggle(item))
            .help(model.canToggle(item)
                  ? (item.isEnabled ? "Disable (reversible)" : "Re-enable")
                  : "System-wide items need admin rights — register the privileged helper on the Dashboard.")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).lineLimit(1)
                if let program = item.programPath {
                    Text(program).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            badges
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(hovering ? Brand.indigo.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .opacity(item.isEnabled ? 1 : 0.55)
    }

    @ViewBuilder
    private var badges: some View {
        if item.signature == .unsigned {
            BrandTag(text: "Unsigned", color: Brand.danger)
                .help("The executable is not code-signed — verify you recognize this item.")
        }
        if item.signature == .binaryMissing {
            BrandTag(text: "Binary missing", color: .orange)
                .help("The program this item launches no longer exists — likely a leftover.")
        }
        if item.runAtLoad {
            BrandTag(text: "Launches at login", color: .blue)
        }
        if item.keepAlive {
            BrandTag(text: "Always running", color: .purple)
        }
        if !item.isEnabled {
            BrandTag(text: "Disabled", color: .gray)
        }
    }
}
