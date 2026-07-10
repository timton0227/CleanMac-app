import SwiftUI
import CleanCore

/// FR-REPORT: post-action summary. The mock's `reportEl` is a compact
/// "X freed" hero with Open Trash / Done — the freed-now number, an honest
/// one-liner, and the exits. Refused/skipped/failed detail and the
/// verification banner are real functionality the mock doesn't need to show,
/// kept below as secondary detail.
struct ReportView: View {
    @Environment(AppModel.self) private var model
    var tint: Color = Brand.indigo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let report = model.lastReport {
                    hero(report)
                    if !report.refused.isEmpty {
                        section("Refused (protected)", report.refused, color: Brand.danger)
                    }
                    if !report.skipped.isEmpty {
                        section("Skipped", report.skipped, color: .orange)
                    }
                    if !report.failed.isEmpty {
                        section("Failed", report.failed, color: Brand.danger)
                    }
                    verification(report)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hero(_ report: ActionEngine.Report) -> some View {
        let bytes = max(report.freedNowBytes, report.reclaimableAfterPurgeBytes)
        let reversible = report.completed.contains { $0.trashPath != nil }
        let count = report.completed.count

        return VStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 64, height: 64)
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(tint)
            }
            Text(bytes > 0 ? "\(AppModel.format(bytes)) freed" : "All done")
                .font(Brand.display(28))
                .foregroundStyle(.white)
            Text(count == 0 ? "Nothing to report."
                 : "\(count) \(count == 1 ? "item" : "items") "
                 + (reversible
                    ? "moved to the CleanMac Trash — restorable for \(model.restoreWindowDays) days."
                    : "removed. This can't be undone."))
                .font(.system(size: 13.5))
                .foregroundStyle(Brand.fog)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                // Reversible batches (the common case) offer both exits; purges
                // (privacy, snapshots) are gone for good (§4.6) — Done only.
                if reversible {
                    Button("Open Trash") { model.selection = .trash }
                    Button("Undo last clean") { Task { await model.undoLast() } }
                }
                Button("Done") { model.phase = .idle }
                    .buttonStyle(.borderedProminent)
            }

            if report.reclaimableAfterPurgeBytes > 0 {
                Text("Items moved to Trash still occupy disk until the \(model.restoreWindowDays)-day restore window ends. Use “Delete permanently” to reclaim immediately.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .brandCard(padding: 24)
    }

    private func section(_ title: String, _ records: [ActionRecord], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(color)
            ForEach(records) { rec in
                HStack {
                    Text(rec.originalPath.lastPathComponent).lineLimit(1)
                    Spacer()
                    Text(rec.reason ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .brandCard()
    }

    @ViewBuilder
    private func verification(_ report: ActionEngine.Report) -> some View {
        if let v = report.verification {
            HStack(spacing: 6) {
                Image(systemName: v.withinTolerance ? "checkmark.seal" : "exclamationmark.triangle")
                    .foregroundStyle(v.withinTolerance ? .green : .orange)
                Text(v.withinTolerance
                     ? "Verified: measured free-space change matches within tolerance."
                     : "Measured free-space change diverged from the estimate (expected when moving to Trash, which frees space only at purge).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
