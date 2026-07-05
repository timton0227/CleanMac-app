import Foundation
import AppKit
import CleanCore

/// UI-side orchestrator: runs the scanner, holds findings + selection, drives the
/// ActionEngine, and implements the optimistic live-total update (FR-UX-LIVE).
/// All UI state is MainActor-isolated; the engine is a separate actor.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case idle, scanning, review, acting, report }

    var phase: Phase = .idle
    /// Which scanner the current phase/findings belong to (§2 — one pipeline,
    /// interchangeable front-ends). Views showing another module render idle.
    var activeModuleId: String = ""
    var scanProgress: Double = 0
    var findings: [Finding] = []
    var selected: Set<UUID> = []
    var lastReport: ActionEngine.Report?
    var trashRecords: [ActionRecord] = []
    var statusMessage: String = ""

    // FR-UX-LIVE: optimistic totals updated within one frame on delete, then
    // reconciled in the background against the authoritative free-space read.
    var reclaimableBytes: Int64 = 0
    var displayedFreeBytes: Int64 = 0
    var volumeTotalBytes: Int64 = 0

    let restoreWindowDays = 30

    private let engine: ActionEngine
    private let scanner: SystemJunkScanner
    private let freeSpace = FreeSpaceProbe()
    private let homeVolume = FileManager.default.homeDirectoryForCurrentUser

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("CleanMac", isDirectory: true)

        // Owned exclusively by the engine actor — never retained on the MainActor.
        let auditLog = try AuditLog(fileURL: support.appendingPathComponent("audit.log"))
        let trash = try TrashStore(baseURL: support.appendingPathComponent("Trash", isDirectory: true))
        self.engine = ActionEngine(auditLog: auditLog, trash: trash)
        self.scanner = SystemJunkScanner()

        refreshFreeSpace()
    }

    var selectedFindings: [Finding] { findings.filter { selected.contains($0.id) } }

    // MARK: - Scan

    /// Minimum size for the Large & Old Files scan (user-adjustable).
    var largeFileMinBytes: Int64 = 100 * 1024 * 1024

    func scanSystemJunk() async {
        await run(scanner)
    }

    func scanLargeFiles() async {
        await run(LargeOldFilesScanner(minBytes: largeFileMinBytes))
    }

    func scanSnapshots() async {
        await run(SnapshotScanner())
    }

    // MARK: - Uninstaller (§4.4)

    var installedApps: [InstalledApp] = []
    var selectedApps: Set<URL> = []
    /// Set by the /Applications watcher when an app is added/removed outside
    /// the app (drag-to-Trash detection, §4.4) — the UI offers a leftovers sweep.
    var applicationsChangedExternally = false
    private var appsWatcher: DispatchSourceFileSystemObject?

    func loadInstalledApps() {
        installedApps = AppInventory.installedApps()
        selectedApps = selectedApps.intersection(Set(installedApps.map(\.url)))
        watchApplicationsFolderIfNeeded()
    }

    private var runningBundleIDs: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        app.bundleID.map { runningBundleIDs.contains($0) } ?? false
    }

    func scanUninstall() async {
        let targets = installedApps.filter { selectedApps.contains($0.url) }
        guard !targets.isEmpty else { return }
        await run(UninstallScanner(targets: targets, runningBundleIDs: runningBundleIDs))
    }

    func scanLeftovers() async {
        applicationsChangedExternally = false
        await run(LeftoversScanner())
    }

    func scanIOSBackups() async {
        await run(IOSBackupScanner())
    }

    // MARK: - Duplicates (§4.3)

    /// nil = default locations; otherwise the user-picked folder(s) to scan
    /// exclusively ("scan in that folder only").
    var duplicateScanRoots: [URL]? = nil

    func scanDuplicates(roots: [URL]? = nil) async {
        if let roots { duplicateScanRoots = roots }
        await run(DuplicateScanner(roots: duplicateScanRoots))
    }

    /// Reset back to the default-locations mode.
    func clearDuplicateScope() {
        duplicateScanRoots = nil
    }

    // MARK: - Space Lens (§4.9)

    var spaceTree: SpaceNode?
    var spaceScanning = false
    var spaceProgress: Double = 0
    /// Selected map nodes with their real bytes (drives the live totals).
    var spaceSelection: [URL: Int64] = [:]
    var spaceRootURL = FileManager.default.homeDirectoryForCurrentUser

    var spaceSelectedBytes: Int64 { spaceSelection.values.reduce(0, +) }

    func scanSpaceLens(root: URL? = nil) async {
        if let root { spaceRootURL = root }
        spaceScanning = true
        spaceProgress = 0
        spaceSelection = [:]
        let target = spaceRootURL
        // The full-tree walk is heavy — never on the main actor (FR-PERF).
        let tree = await Task.detached(priority: .userInitiated) { [weak self] in
            try? SpaceLens.build(root: target) { p in
                Task { @MainActor in self?.spaceProgress = p }
            }
        }.value
        spaceTree = tree
        spaceScanning = false
        statusMessage = tree.map {
            "Mapped \(Self.format($0.realBytes)) under \(target.lastPathComponent)."
        } ?? "Space Lens scan failed."
    }

    func toggleSpaceSelection(_ node: SpaceNode) {
        if spaceSelection[node.path] != nil {
            spaceSelection.removeValue(forKey: node.path)
        } else {
            spaceSelection[node.path] = node.realBytes
        }
    }

    /// Delete straight from the map — same engine, same Trash, same audit log
    /// (§4.9: a visual Review front-end, not a private delete path). The map
    /// updates in place without a rescan (FR-UX-LIVE).
    func deleteSpaceSelection() async {
        let items = spaceSelection
        guard !items.isEmpty else { return }
        let findings = items.map { url, bytes in
            Finding(
                path: url, realOnDiskBytes: bytes, logicalBytes: bytes,
                category: .storageItem, confidence: .high,
                safeToRemove: true, isProtected: false, isCloudPlaceholder: false,
                validation: SizeAccounting.validation(of: url)
            )
        }
        let report = await engine.perform(findings)

        let removed = Set(report.completed.map(\.originalPath))
        spaceTree = spaceTree?.removing(removed)             // FR-UX-LIVE
        spaceSelection = spaceSelection.filter { !removed.contains($0.key) }
        statusMessage = summary(for: report)
        lastReport = report
        await loadTrash()
        refreshFreeSpace()
    }

    // MARK: - Dashboard + Smart Scan (§4.8)

    var disk: DiskBreakdown?
    var memory: MemorySnapshot?
    var cpu: CPULoad?
    var battery: BatteryInfo?

    var smartScanResults: [SmartScan.ModuleResult] = []
    var smartScanning = false
    var smartScanProgress: Double = 0

    /// Full Disk Access state (FR-PERM) — drives the dashboard guidance card.
    var fullDiskAccess: FullDiskAccess.Status = .undetermined

    /// Privileged helper lifecycle (Infra A) — registration, approval state,
    /// and the FR-SEC-1-pinned XPC transport for root-scope operations.
    let helper = HelperClient()

    /// Bytes sitting in the app's own Trash — "reclaimable after purge"
    /// (FR-SAFE-6), surfaced on the dashboard so the retained space is visible.
    var trashRetainedBytes: Int64 {
        trashRecords.reduce(0) { $0 + $1.bytes }
    }

    /// The honest headline: sum of what each module would pre-select (§7 —
    /// conservative), not the sum of everything found.
    var smartPreselectedBytes: Int64 {
        smartScanResults.reduce(0) { $0 + $1.preselectedBytes }
    }
    var smartTotalBytes: Int64 {
        smartScanResults.reduce(0) { $0 + $1.totalBytes }
    }

    func refreshDashboard() async {
        disk = DiskBreakdown.probe(volumeContaining: homeVolume)
        memory = MemorySnapshot.sample()
        cpu = CPULoad.sample()
        battery = BatteryInfo.probe()
        fullDiskAccess = FullDiskAccess.status()
        helper.refresh()
        await loadTrash()
        refreshFreeSpace()
    }

    /// Open System Settings → Privacy & Security → Full Disk Access (FR-PERM).
    func openFullDiskAccessSettings() {
        if let url = URL(string: FullDiskAccess.settingsURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reveal the app bundle in Finder so the user can drag it into the FDA
    /// list. Only meaningful when running as a packaged .app (Infra B).
    var isRunningAsBundledApp: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// One click, curated scanners, sequential, per-module status (§4.8).
    /// Failures (e.g. iOS backups without Full Disk Access) stay isolated to
    /// their row — the run always completes.
    func runSmartScan() async {
        smartScanning = true
        smartScanProgress = 0
        let scanners = SmartScan.curatedScanners()
        smartScanResults = scanners.map {
            SmartScan.ModuleResult(id: $0.id, displayName: $0.displayName)
        }
        _ = try? await engine.reconcilePending() // FR-SAFE-4, same as run()

        let results = await SmartScan.run(scanners) { [weak self] p in
            Task { @MainActor in self?.smartScanProgress = p }
        } onUpdate: { [weak self] result in
            Task { @MainActor in
                guard let self,
                      let i = self.smartScanResults.firstIndex(where: { $0.id == result.id })
                else { return }
                self.smartScanResults[i] = result
            }
        }
        smartScanResults = results
        smartScanning = false
        statusMessage = "Smart Scan: \(Self.format(smartPreselectedBytes)) safely reclaimable across \(results.count) categories."
    }

    /// Hand a Smart Scan category to its module's normal Review — same
    /// findings, same selection rules, same engine. Smart Scan never grows a
    /// private delete path.
    func reviewSmartResult(_ result: SmartScan.ModuleResult) {
        activeModuleId = result.id
        findings = result.findings
        selected = Set(findings.filter(\.defaultSelected).map(\.id))
        recomputeReclaimable()
        phase = .review
        statusMessage = "\(findings.count) items found."
    }

    // MARK: - Privacy (§4.6)

    func scanPrivacy() async {
        await run(PrivacyScanner(runningBundleIDs: runningBundleIDs))
    }

    /// Purge the selected privacy artifacts — permanently (§4.6: these are not
    /// Trash-recoverable). Items whose owning app is running are skipped, not
    /// purged, to avoid corrupting live databases (FR-SAFE-1 amend).
    func purgeSelectedPrivacy() async {
        phase = .acting
        let toPurge = selectedFindings.filter { !$0.ownedByRunningProcess }
        let skippedRunning = selectedFindings.count - toPurge.count

        let report = await engine.performNonReversible(toPurge) { finding in
            try FileManager.default.removeItem(at: finding.path)
        }

        let completedPaths = Set(report.completed.map(\.originalPath))
        findings.removeAll { completedPaths.contains($0.path) }
        selected = selected.intersection(Set(findings.map(\.id)))
        recomputeReclaimable()

        var msg = summary(for: report)
        if skippedRunning > 0 {
            msg += " · \(skippedRunning) skipped (app is running — quit it first)"
        }
        statusMessage = msg
        lastReport = report
        phase = .report
        refreshFreeSpace()
    }

    // MARK: - Startup items (§4.5)

    var startupItems: [StartupItem] = []
    var startupItemsLoading = false

    /// Signature checks shell out to codesign per item, so listing runs off the
    /// main actor (FR-PERF: never block the UI).
    func loadStartupItems() async {
        startupItemsLoading = true
        let items = await Task.detached(priority: .utility) {
            StartupInventory.list()
        }.value
        startupItems = items
        startupItemsLoading = false
    }

    /// Whether this build can toggle the item: user agents directly (§4.5),
    /// system agents/daemons only through the approved privileged helper.
    func canToggle(_ item: StartupItem) -> Bool {
        item.isToggleable || helper.isEnabled
    }

    /// Toggle through the engine so it is audit-logged and serialized
    /// (FR-SAFE-3/5). Reversibility here is the re-toggle, not Trash (§4.5).
    /// System-domain items route through the root helper's enumerated
    /// `toggleDaemon` command (Infra A) — the helper re-checks the path and
    /// keeps its own manifest, so app-side state never has to be trusted.
    func toggleStartupItem(_ item: StartupItem) async {
        let xpc = helper.xpc
        let viaHelper = !item.isToggleable && helper.isEnabled
        let report = await engine.performNonReversible([item.asFinding()]) { _ in
            if viaHelper {
                let response = await xpc.send(.toggleDaemon(
                    plistPath: item.plistURL.path, enable: !item.isEnabled))
                guard response.ok else {
                    throw HelperCommandHandler.RemoteError(response.message)
                }
            } else {
                try StartupOps.setEnabled(item, enabled: !item.isEnabled)
            }
        }
        if let failure = report.failed.first {
            statusMessage = "Toggle failed: \(failure.reason ?? "unknown")"
        } else {
            statusMessage = "\(item.label) \(item.isEnabled ? "disabled" : "enabled")."
        }
        await loadStartupItems()
    }

    /// FSEvents-lite watch on /Applications: any external change (e.g. the user
    /// dragging an app to the Trash) raises the sweep-offer flag (§4.4).
    private func watchApplicationsFolderIfNeeded() {
        guard appsWatcher == nil else { return }
        let fd = open("/Applications", O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.applicationsChangedExternally = true
                self?.loadInstalledApps()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        appsWatcher = source
    }

    /// Rescan whatever module currently owns the pipeline.
    func rescan() async {
        switch activeModuleId {
        case "large-old-files": await scanLargeFiles()
        case "local-snapshots": await scanSnapshots()
        case "app-uninstall": await scanUninstall()
        case "app-leftovers": await scanLeftovers()
        case "ios-backups": await scanIOSBackups()
        case "duplicates": await scanDuplicates()
        case "privacy": await scanPrivacy()
        default: await scanSystemJunk()
        }
    }

    private func run(_ activeScanner: any CleanCore.Scanner) async {
        phase = .scanning
        activeModuleId = activeScanner.id
        scanProgress = 0
        findings = []
        selected = []
        statusMessage = "Scanning \(activeScanner.displayName)…"

        // Recover any state left by a crash mid-batch before a new run (FR-SAFE-4).
        _ = try? await engine.reconcilePending()

        do {
            let results = try await activeScanner.scan { [weak self] p in
                Task { @MainActor in self?.scanProgress = p }
            }
            findings = results.sorted { $0.realOnDiskBytes > $1.realOnDiskBytes }
            selected = Set(findings.filter(\.defaultSelected).map(\.id))
            recomputeReclaimable()
            phase = .review
            statusMessage = "\(findings.count) items found."
        } catch let error as IOSBackupScanner.ScanError {
            // FR-PERM: explain why the permission matters and what degrades.
            if case .accessDenied = error {
                statusMessage = "macOS blocks access to iOS backups without Full Disk Access. Grant it in System Settings → Privacy & Security → Full Disk Access, then rescan."
            }
            phase = .idle
        } catch {
            statusMessage = "Scan failed: \(error.localizedDescription)"
            phase = .idle
        }
    }

    // MARK: - Selection

    func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        recomputeReclaimable()
    }

    /// Select/deselect a batch (whole category or the entire list) in one
    /// click. Protected items are never selectable (FR-SAFE-1 stays visible).
    func setSelection(_ items: [Finding], to on: Bool) {
        let ids = items.filter { !$0.isProtected }.map(\.id)
        if on { selected.formUnion(ids) } else { selected.subtract(ids) }
        recomputeReclaimable()
    }

    func selectAll() { setSelection(findings, to: true) }
    func deselectAll() { setSelection(findings, to: false) }

    func recomputeReclaimable() {
        reclaimableBytes = selectedFindings.reduce(0) { $0 + $1.realOnDiskBytes }
    }

    // MARK: - Clean

    /// - Parameter permanent: skip Trash and free space now (FR-SAFE-6).
    func clean(permanent: Bool) async {
        phase = .acting
        let batch = UUID()
        let toRemove = selectedFindings
        let report = await engine.perform(
            toRemove,
            options: .init(permanentToReclaimNow: permanent, permanentWhenCrossVolume: permanent),
            batchId: batch
        )

        // FR-UX-LIVE: apply the optimistic adjustment immediately (this frame).
        let completedPaths = Set(report.completed.map(\.originalPath))
        findings.removeAll { completedPaths.contains($0.path) }
        selected = selected.intersection(Set(findings.map(\.id)))
        recomputeReclaimable()
        displayedFreeBytes += report.freedNowBytes // only permanent removals free now

        lastReport = report
        await loadTrash()
        phase = .report
        statusMessage = summary(for: report)

        // Background reconciliation of the authoritative figure (FR-VERIFY/FR-UX-LIVE).
        Task { @MainActor in self.refreshFreeSpace() }
    }

    /// Delete the selected snapshots — non-reversible (§4.7), so this runs the
    /// engine's non-Trash path and reports *measured* freed space (FR-VERIFY).
    func deleteSelectedSnapshots() async {
        phase = .acting
        let toDelete = selectedFindings
        let report = await engine.performNonReversible(toDelete) { finding in
            try SnapshotOps.deleteLocalSnapshot(for: finding)
        }

        var parts = ["\(report.completed.count) snapshot(s) deleted"]
        if let measured = report.verification?.measuredBytes, measured > 0 {
            parts.append("measured freed \(Self.format(measured))")
        }
        if let firstFailure = report.failed.first {
            parts.append("\(report.failed.count) failed — \(firstFailure.reason ?? "unknown")")
        }
        statusMessage = parts.joined(separator: " · ")
        refreshFreeSpace()
        // Re-list so the UI reflects what actually remains.
        await scanSnapshots()
    }

    private func summary(for report: ActionEngine.Report) -> String {
        var parts: [String] = []
        parts.append("\(report.completed.count) removed")
        if report.freedNowBytes > 0 {
            parts.append("freed now \(Self.format(report.freedNowBytes))")
        }
        if report.reclaimableAfterPurgeBytes > 0 {
            parts.append("reclaimable after purge \(Self.format(report.reclaimableAfterPurgeBytes))")
        }
        if !report.refused.isEmpty { parts.append("\(report.refused.count) refused") }
        if !report.skipped.isEmpty { parts.append("\(report.skipped.count) skipped") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Trash / restore (FR-SAFE-2)

    func loadTrash() async {
        trashRecords = await engine.listTrash()
    }

    func restore(_ actionId: UUID) async {
        do {
            let ok = try await engine.restore(actionId: actionId)
            statusMessage = ok ? "Restored." : "Nothing to restore."
            await loadTrash()
            refreshFreeSpace()
        } catch {
            statusMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    func undoLast() async {
        guard let batch = lastReport?.batchId else { return }
        let n = (try? await engine.undoBatch(batch)) ?? 0
        statusMessage = "Undid last clean (\(n) restored)."
        await loadTrash()
        refreshFreeSpace()
    }

    // MARK: - Free space

    func refreshFreeSpace() {
        if let free = freeSpace.availableBytes(forVolumeContaining: homeVolume) {
            displayedFreeBytes = free
        }
        if let total = try? homeVolume.resourceValues(forKeys: [.volumeTotalCapacityKey])
            .volumeTotalCapacity {
            volumeTotalBytes = Int64(total)
        }
    }

    // MARK: - Formatting

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
