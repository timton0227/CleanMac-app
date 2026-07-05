# CleanMac

A native macOS disk-cleanup utility built from `cleanmymac-functional-requirements.md`
(v1.5). This repository implements the staged roadmap: the shared
`Scan → Findings → Review → Reversible Action` pipeline (§2), the hardened safety
net, and **all ten §4 functional modules** — **System Junk / Cache (§4.1, Stage 1)**,
**Large & Old Files (§4.2, Stage 2)**, **Local Snapshots (§4.7, Stage 3)**,
the **Application Uninstaller + Leftovers (§4.4, Stage 4)**,
**Old iOS Device Backups (§4.10, Stage 5)**, the
**Duplicate Finder (§4.3, Stage 6)** with default-locations or pick-a-folder scope,
the **Startup Item Manager (§4.5, Stage 7)**, the
**Privacy Cleaner (§4.6, Stage 8)**, **Space Lens (§4.9, Stage 9)**, and the
**Dashboard + Smart Scan (§4.8, Stage 10)**.

## Why it's built this way

Per the spec's central finding (§2, §9), the ten "modules" are not ten features —
they are **one pipeline with interchangeable scanner front-ends**. Only one
component ever mutates the filesystem: the `ActionEngine`. Every scanner merely
*proposes*. So the engine and its safety net are built and hardened first, in
isolation, and covered by acceptance tests before any second scanner is added.

## Layout

```
Sources/
  CleanCore/            # the pipeline + safety net + scanners (no UI) — swift-testable
    Models/             # Finding, Category, SizeAccounting, ActionRecord
    Scanning/           # Scanner protocol
    Scanners/           # SystemJunk, LargeOldFiles, Snapshot, Uninstall/Leftovers (+ AppInventory), IOSBackup, Duplicate, StartupItems, Privacy
    SpaceLens/          # SpaceNode tree builder (real bytes, packages opaque, hardlinks once)
    Dashboard/          # SystemStats (disk/memory/CPU/battery probes), SmartScan orchestrator
    Helper/             # HelperCommand (closed set), HelperCommandHandler, FR-SEC-1 pins
    Permissions/        # FullDiskAccess probe (FR-PERM)
    Action/             # ProtectedPaths, AuditLog, TrashStore, ActionEngine, FreeSpaceProbe/Verifier
    Resources/          # junk-rules.json (FR-DEFS: remote-updatable, no hard-coded paths)
  CleanMac/             # SwiftUI app — Review / Report / Trash front-ends + HelperClient
  CleanHelper/          # privileged daemon: NSXPCListener + pinned client requirement
Packaging/              # Info.plist, entitlements, launchd plist, AppIcon.icns
Tests/CleanCoreTests/   # acceptance tests for the safety-critical requirements
```

## Requirements coverage (Stage 1)

| Requirement | Where |
|---|---|
| FR-SAFE-1 protected-path enforcement + FR-BUNDLE | `ProtectedPaths` |
| FR-SAFE-2 reversible + batch undo | `TrashStore`, `ActionEngine.restore/undoBatch` |
| FR-SAFE-3 audit log (fsync before mutation) | `AuditLog` |
| FR-SAFE-4 transactional / idempotent resume | `ActionEngine.perform/reconcilePending` |
| FR-SAFE-5 serialization | `ActionEngine` (actor) |
| FR-SAFE-6 reclaim-vs-retain | `ActionEngine.Report.freedNow / reclaimableAfterPurge` |
| FR-SAFE-7 re-validate before mutate (TOCTOU) | `SizeAccounting.validation` + engine check |
| FR-VOL volume awareness | `TrashStore.supportsReversibleRemoval` |
| FR-VERIFY measured freed bytes | `FreeSpaceProbe` + `Verifier` |
| FR-UX-LIVE optimistic live totals | `AppModel.clean` |
| FR-PREVIEW grouped/sized review + Quick Look | `ReviewView` |
| FR-DEFS updatable rules | `junk-rules.json` + `JunkRules` |
| §4.2 cloud-file awareness | `SizeAccounting.realOnDiskBytes` |
| §4.2 large/old finder (packages whole, symlinks skipped, never pre-selected) | `LargeOldFilesScanner` |
| §4.7 snapshots (non-reversible engine path, measured freed) | `SnapshotScanner` + `ActionEngine.performNonReversible` |
| §4.4 uninstall + leftovers (conservative ID matching, drag-to-Trash watch) | `UninstallScanner`, `LeftoversScanner`, `AppInventory` |
| §4.10 iOS backups (keep-most-recent, FR-PERM access-denied signaling) | `IOSBackupScanner` |
| §4.3 duplicates (3-stage hashing, hardlink/symlink correctness, keeper never offered, folder scope) | `DuplicateScanner` |
| §4.5 startup items (reversible toggles, unsigned/missing-binary flags, honest impact badges) | `StartupInventory`, `StartupOps` |
| §4.6 privacy (purge-not-Trash, never pre-selected, in-use blocking) | `PrivacyScanner` + `PrivacyArtifact.catalog` |
| §4.9 Space Lens (real-bytes treemap, drill-in, delete-from-map via engine, live update) | `SpaceLens`/`SpaceNode` + `SpaceLensView` |
| §4.8 Dashboard + Smart Scan (per-category status — no "system score"; Storage-panel reconciliation; failure-isolated curated scan) | `SmartScan`, `SystemStats` + `DashboardView` |
| FR-PERM Full Disk Access detect + guidance (real read probes, Settings deep link, honest degradation) | `FullDiskAccess` + dashboard permissions card |
| Infra B packaging (signed .app, hardened runtime, optional notarization) | `scripts/package.sh` + `Packaging/` |
| Infra A privileged helper (closed 4-command XPC surface, helper-side FR-SAFE-1 + manifest, SMAppService lifecycle) | `HelperCommand*`, `CleanHelper`, `HelperClient` |
| FR-SEC-1 XPC peer authentication (code-signature pins, both directions) | `HelperSecurity` + `setCodeSigningRequirement` |
| FR-MULTI admin-gated system scope (explicit register + System Settings approval) | Dashboard helper card + system startup toggles |

## Build / test / run

```sh
swift build          # compiles CleanCore + CleanMac
swift test           # runs the safety-net acceptance suite (headless)
swift run CleanMac    # launches the SwiftUI app (dev mode)
```

### Packaging (Infra B)

```sh
scripts/package.sh   # → dist/CleanMac.app (ad-hoc signed, hardened runtime)
scripts/make_dmg.sh  # → dist/CleanMac.dmg (drag-to-install, for sharing with testers)
```

`make_dmg.sh` runs `package.sh` first if needed, then wraps the app with an
`Applications` symlink so testers can drag-install it.

**Sharing with testers on other Macs — Gatekeeper:** the default ad-hoc
signature is only trusted on *this* Mac. A tester who downloads the DMG (via
Slack, AirDrop, a link, etc.) will see "Apple could not verify… is not
damaged" because macOS quarantines anything downloaded from the internet.
They can still run it:

- Right-click (or Control-click) `CleanMac.app` → **Open** → **Open** again in
  the dialog (bypasses Gatekeeper for that app only), or
- After copying to `/Applications`: `xattr -cr /Applications/CleanMac.app`

For a tester experience with no warning at all, sign and notarize both
artifacts with a real Developer ID:

```sh
CODESIGN_IDENTITY="Developer ID Application: You (TEAMID)" \
NOTARY_PROFILE="notarytool-keychain-profile" \
scripts/make_dmg.sh
```

Full Disk Access is granted per app bundle, so protected scans (iOS backups,
Mail, Safari data) need the packaged app: run it once, then enable CleanMac in
System Settings → Privacy & Security → Full Disk Access — the in-app Dashboard
card detects the state and deep-links the pane (FR-PERM). Under `swift run`,
macOS applies the hosting terminal's grant instead.

For distribution, sign with a real identity and (optionally) notarize:

```sh
CODESIGN_IDENTITY="Developer ID Application: You (TEAMID)" \
NOTARY_PROFILE="notarytool-keychain-profile" \
scripts/package.sh
```

## Scope of this build

- **User privilege only** — scans user-level junk (`~/Library/Caches`, `Logs`,
  crash reports, developer junk, broken downloads). No root helper yet.
- **Reversible by default** — removals move to an app-managed Trash with a 30-day
  restore window and audit log; a permanent "reclaim now" path is opt-in per action.
- **Privileged helper (Infra A)** — the packaged app embeds `CleanHelper`, an
  on-demand root daemon registered via `SMAppService` (Dashboard → Privileged
  Helper card; requires your approval in System Settings → Login Items,
  FR-MULTI). Its XPC surface is a closed four-command enum (version /
  deletePath / toggleDaemon / deleteSnapshot) — arbitrary commands are
  unrepresentable; both sides pin the peer's code signature (FR-SEC-1); and
  the helper re-enforces the protected-path denylist and writes its own
  append-only manifest at `/Library/Application Support/CleanMac/` (FR-SAFE-1/3
  hold even against a compromised client). Currently unlocked by it: system
  Launch Daemon/Agent toggles in Startup Items.
- **Brand identity** — the app icon (`Packaging/AppIcon.icns`, generated by
  `scripts/generate_app_icon.swift` from the visual style guide's aperture-ring
  spec: Ink tile, Indigo ring, ~75% closed) is wired into `Info.plist` and
  copied into the bundle by `scripts/package.sh`. The same ring + wordmark
  lockup is a reusable SwiftUI view (`BrandMark`/`RingMark`) shown in the
  sidebar header in-app.
- **Design system & interactive UI** — `Views/Theme.swift` carries the style
  guide's palette (Ink/Paper/Mist/Border/Fog/Indigo, dark-mode adaptive) and
  the shared chrome: grouped sidebar with per-module icon tiles and a live
  Trash badge; a dashboard hero (disk-usage brand ring + one-click Smart Scan)
  with an all-tools navigation grid; a `Scan → Review → Clean → Done` step bar
  in every pipeline module (renamed "Clear"/"Delete" where the action isn't a
  reversible clean); scan progress drawn as the closing aperture ring;
  whole-category and select-all/none toggles in Review (protected items stay
  unselectable); animated live totals; and hover states on rows, cards, and
  Space Lens tiles. View-layer only — the engine and scanners are untouched.
- Remaining roadmap: Developer ID signing + notarization credentials (the
  packaging script supports both via env vars), the conditional known-adware
  scanner (Stage 11), and FR-AUTO scheduled scans — all plug into this same
  engine without changing it.
