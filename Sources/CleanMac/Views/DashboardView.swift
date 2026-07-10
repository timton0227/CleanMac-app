import SwiftUI
import CleanCore

/// Smart Scan landing (§4.8), laid out CleanMyMac-style: a full-height hero —
/// aperture-ring illustration, "Let's get started!", and the glowing circular
/// Scan button — with the honest operational cards (storage breakdown +
/// Storage-panel reconciliation, vitals, privileged helper) below the fold.
///
/// §6 cuts hold: transparent per-category status instead of a 0–100 "system
/// score", no "purge RAM" button, and every category number links to the
/// module's normal Review — Smart Scan never grows a private delete path.
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 14) {
                    hero
                        .frame(minHeight: max(geo.size.height, 420))
                    storageCard
                    vitalsRow
                    if model.fullDiskAccess != .granted {
                        permissionsCard
                    }
                    helperCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.fullDiskAccess != .granted {
                InfoBanner(icon: "lock.shield", tint: .orange,
                           text: "Full Disk Access is off. iOS backups, Mail, and Safari data are invisible to scans. Details below.") {
                    Button("Open Settings") { model.openFullDiskAccessSettings() }
                    Button("Re-check") { Task { await model.refreshDashboard() } }
                }
                .background(.black.opacity(0.35))
            }
        }
        .task {
            await model.refreshDashboard()
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 20)
            illustration(progress: model.smartScanning ? model.smartScanProgress : nil)
            headline
            resultsCard
                .frame(maxWidth: 620)
            Spacer(minLength: 8)
            CircularScanButton(
                title: model.smartScanning ? "…"
                     : model.smartScanResults.isEmpty ? "Scan" : "Rescan",
                diameter: 80,
                disabled: model.smartScanning
            ) {
                Task { await model.runSmartScan() }
            }
            Spacer(minLength: 26)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var headline: some View {
        if model.smartScanning {
            Text("Scanning your Mac…")
                .font(Brand.display(25))
                .foregroundStyle(.white)
            Text("Give your Mac a nice and thorough scan.")
                .font(.callout)
                .foregroundStyle(Brand.fog)
        } else if !model.smartScanResults.isEmpty {
            Text("\(AppModel.format(model.smartPreselectedBytes)) safely reclaimable")
                .font(Brand.display(25))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text("Found across \(model.smartScanResults.count) categories. Nothing is removed without your review.")
                .font(.callout)
                .foregroundStyle(Brand.fog)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Let's get started!")
                .font(Brand.display(25))
                .foregroundStyle(.white)
            Text("Give your Mac a nice and thorough scan.")
                .font(.callout)
                .foregroundStyle(Brand.fog)
        }
    }

    /// The central illustration: a conic-fill disc, matching the mock's
    /// `screenDashboard` — a hard-edged pie sweep instead of a stroked ring.
    /// Percent while scanning; a sparkle glyph idle or once done.
    private func illustration(progress: Double?) -> some View {
        ZStack {
            ConicProgressRing(progress: progress ?? 0, accent: Brand.indigo)
            if let progress {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(Brand.display(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } else {
                Text("✦")
                    .font(Brand.display(20, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .animation(.easeOut(duration: 0.3), value: progress)
    }

    // MARK: - Per-category results

    /// Always visible — waiting, scanning, or done — matching the mock's
    /// always-rendered "Per-category status" card. Before a scan ever runs,
    /// placeholder rows list Smart Scan's curated modules as "Waiting…".
    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-category status").font(.system(size: 13, weight: .semibold))
            ForEach(displayedResults) { result in
                smartRow(result)
            }
        }
        .brandCard()
    }

    private var displayedResults: [SmartScan.ModuleResult] {
        model.smartScanResults.isEmpty
            ? SmartScan.curatedScanners().map { SmartScan.ModuleResult(id: $0.id, displayName: $0.displayName) }
            : model.smartScanResults
    }

    @ViewBuilder
    private func smartRow(_ result: SmartScan.ModuleResult) -> some View {
        HStack(spacing: 10) {
            statusIcon(result.status)
            Text(result.displayName)
                .frame(width: 140, alignment: .leading)

            switch result.status {
            case .pending:
                Text("Waiting…").font(.caption).foregroundStyle(.secondary)
            case .scanning:
                Text("Scanning…").font(.caption).foregroundStyle(.secondary)
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(.orange)
            case .done:
                if result.findings.isEmpty {
                    Text("Nothing to clean").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(result.findings.count) items · \(AppModel.format(result.totalBytes)) found · \(AppModel.format(result.preselectedBytes)) pre-selected")
                        .font(.caption)
                }
            }
            Spacer()
            if case .done = result.status, !result.findings.isEmpty,
               let destination = destination(for: result.id) {
                Button("Review") {
                    model.reviewSmartResult(result)
                    model.selection = destination
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(_ status: SmartScan.ModuleResult.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .scanning:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    /// Where "Review" lands for each curated module — the module's own view,
    /// which renders the standard Review because `reviewSmartResult` hands it
    /// the pipeline (§2: one pipeline, interchangeable front-ends).
    private func destination(for moduleId: String) -> SidebarItem? {
        switch moduleId {
        case "system-junk": return .systemJunk
        case "app-leftovers": return .uninstaller
        case "local-snapshots": return .snapshots
        case "ios-backups": return .iosBackups
        default: return nil
        }
    }

    // MARK: - Storage (below the fold)

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Startup Disk", systemImage: "internaldrive")
                .font(.headline)
            if let disk = model.disk {
                capacityBar(disk)
                HStack(spacing: 16) {
                    legend(color: Brand.indigo, label: "Used", bytes: disk.usedBytes)
                    legend(color: Brand.startup, label: "Purgeable", bytes: disk.purgeableBytes)
                    legend(color: Brand.duplicates, label: "Free", bytes: disk.freeBytes)
                }
                if model.trashRetainedBytes > 0 {
                    Text("CleanMac Trash holds \(AppModel.format(model.trashRetainedBytes)), freed when you purge it (30-day window)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // §4.8 reconciliation: explain the Storage-panel mismatch
                // instead of leaving the user to distrust one of the numbers.
                DisclosureGroup {
                    Text("macOS counts purgeable space (local snapshots, evicted iCloud files, and caches it can drop on demand) as \"available\", reporting \(AppModel.format(disk.availableIncludingPurgeableBytes)). The free space actually on disk right now is \(AppModel.format(disk.freeBytes)). Both numbers are correct; they answer different questions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } label: {
                    Text("Why Apple's Storage panel shows a different number")
                        .font(.caption)
                        .foregroundStyle(Brand.indigo)
                }
            } else {
                Text("Reading volume…").foregroundStyle(.secondary)
            }
        }
        .brandCard()
    }

    private func capacityBar(_ disk: DiskBreakdown) -> some View {
        GeometryReader { geo in
            let total = max(Double(disk.totalBytes), 1)
            HStack(spacing: 2) {
                segment(Brand.indigo, fraction: Double(disk.usedBytes) / total, width: geo.size.width)
                segment(Brand.startup, fraction: Double(disk.purgeableBytes) / total, width: geo.size.width)
                segment(Brand.duplicates, fraction: Double(disk.freeBytes) / total, width: geo.size.width)
            }
            .animation(.easeOut(duration: 0.6), value: disk.freeBytes)
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func segment(_ color: Color, fraction: Double, width: CGFloat) -> some View {
        Rectangle()
            .fill(color.opacity(0.85))
            .frame(width: max(0, width * fraction))
    }

    private func legend(color: Color, label: String, bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color.opacity(0.85)).frame(width: 8, height: 8)
            Text("\(label) \(AppModel.format(bytes))")
                .font(.caption)
        }
    }

    // MARK: - Vitals

    private var vitalsRow: some View {
        HStack(alignment: .top, spacing: 14) {
            vitalCard("Memory", systemImage: "memorychip") {
                if let mem = model.memory {
                    Gauge(value: mem.usedFraction) {
                        EmptyView()
                    } currentValueLabel: {
                        Text("\(Int((mem.usedFraction * 100).rounded()))%")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    Text("\(AppModel.format(mem.usedBytes)) of \(AppModel.format(mem.totalBytes))")
                        .font(.caption)
                    Text("App \(AppModel.format(mem.appBytes)) · Wired \(AppModel.format(mem.wiredBytes)) · Compressed \(AppModel.format(mem.compressedBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            vitalCard("CPU", systemImage: "cpu") {
                if let cpu = model.cpu {
                    Text(String(format: "%.2f", cpu.oneMinute))
                        .font(Brand.display(28, weight: .semibold))
                    Text("load average (1 min) · \(cpu.coreCount) cores")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "5 min %.2f · 15 min %.2f",
                                cpu.fiveMinutes, cpu.fifteenMinutes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            if let battery = model.battery {
                vitalCard("Battery", systemImage: "battery.75percent") {
                    Text("\(battery.percentage)%\(battery.isCharging ? " ⚡" : "")")
                        .font(Brand.display(28, weight: .semibold))
                    if let health = battery.healthPercent {
                        Text("Health \(health)% of design capacity")
                            .font(.caption)
                    }
                    HStack(spacing: 6) {
                        if let condition = battery.condition {
                            Text("Condition: \(condition)").font(.caption2)
                        }
                        if let cycles = battery.cycleCount {
                            Text("\(cycles) cycles").font(.caption2)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func vitalCard(_ title: String, systemImage: String,
                           @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .brandCard(padding: 14)
    }

    // MARK: - Full Disk Access (FR-PERM)

    /// Graceful degradation UX: name what is invisible without the grant,
    /// deep-link the exact Settings pane, and re-check on demand. The app
    /// keeps working without FDA — this explains what it can't see, honestly.
    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Full Disk Access", systemImage: "lock.shield")
                .font(.headline)
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(model.fullDiskAccess == .denied
                     ? "macOS is blocking parts of your Library. Without Full Disk Access, iOS backups, Mail, Safari data, and some app caches are invisible to scans. They'll show as errors or missing, never as fake \"nothing found\"."
                     : "Full Disk Access could not be verified. Some protected locations may be invisible to scans.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Open System Settings") {
                    model.openFullDiskAccessSettings()
                }
                if model.isRunningAsBundledApp {
                    Button("Reveal CleanMac in Finder") {
                        model.revealAppInFinder()
                    }
                }
                Button("Re-check") {
                    Task { await model.refreshDashboard() }
                }
            }
            Text(model.isRunningAsBundledApp
                 ? "In Settings, enable CleanMac under Privacy & Security → Full Disk Access (drag it in from Finder if it's not listed), then re-check."
                 : "Running unbundled (swift run): macOS applies the grant of the hosting terminal, not CleanMac. Package the app (scripts/package.sh) and grant the .app itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .brandCard()
    }

    // MARK: - Privileged helper (Infra A)

    /// Root-scope lifecycle, honestly gated (FR-MULTI): registration is
    /// explicit, approval happens in System Settings, and what it unlocks
    /// (system startup-item toggles) is named. Never registered silently.
    private var helperCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Privileged Helper", systemImage: "lock.open.laptopcomputer")
                .font(.headline)
            switch model.helper.state {
            case .notPackaged:
                Text("Root-scope operations (system Launch Daemons, root-owned files) need the helper daemon, which macOS only accepts from the packaged app. Build it with scripts/package.sh and run dist/CleanMac.app.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .notRegistered, .notFound:
                Text(model.helper.state == .notFound
                     ? "The app bundle carries no helper. Rebuild with scripts/package.sh."
                     : "Not registered. Registering installs a background daemon that only accepts four signed, audited commands from this app (FR-SEC-1), and it unlocks system startup-item toggles.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Register Helper…") { model.helper.register() }
            case .requiresApproval:
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Text("Registered. Approve CleanMac under System Settings → General → Login Items & Extensions, then re-check.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button("Open Login Items Settings") { model.helper.register() }
                    Button("Re-check") { model.helper.refresh() }
                }
            case .enabled:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(model.helper.connectedVersion != nil
                         ? "Active. Helper v\(model.helper.connectedVersion!) responding, code-signature pins verified both ways."
                         : "Approved. System startup-item toggles are unlocked.")
                        .font(.callout)
                }
                HStack(spacing: 10) {
                    Button("Test Connection") {
                        Task { await model.helper.handshake() }
                    }
                    Button("Unregister") { model.helper.unregister() }
                }
            }
            if let message = model.helper.lastMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .brandCard()
    }
}
