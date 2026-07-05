import SwiftUI
import CleanCore

/// FR-REPORT: post-action summary — freed (measured), reclaimable-after-purge
/// (FR-SAFE-6), items removed, and anything refused/skipped and why. Offers
/// "undo last clean" (FR-SAFE-2 batch undo). The brand ring animates closed:
/// the open gap is the space you got back.
struct ReportView: View {
    @Environment(AppModel.self) private var model
    @State private var ringVisible = false

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
        .onAppear {
            withAnimation(.spring(duration: 0.9)) { ringVisible = true }
        }
    }

    private func hero(_ report: ActionEngine.Report) -> some View {
        HStack(spacing: 28) {
            ZStack {
                RingMark(fraction: ringVisible ? 160.0 / 213.63 : 0.001)
                    .frame(width: 110, height: 110)
                VStack(spacing: 0) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Brand.indigo)
                    Text("\(report.completed.count)")
                        .font(Brand.display(20))
                        .monospacedDigit()
                    Text("items")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(headline(report))
                    .font(Brand.display(26))
                    .foregroundStyle(Brand.ink)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        Text("Freed now").foregroundStyle(.secondary)
                        Text(AppModel.format(report.freedNowBytes)).monospacedDigit()
                    }
                    GridRow {
                        Text("Reclaimable after purge").foregroundStyle(.secondary)
                        Text(AppModel.format(report.reclaimableAfterPurgeBytes)).monospacedDigit()
                    }
                }
                .font(.callout)

                if report.reclaimableAfterPurgeBytes > 0 {
                    Text("Items moved to Trash still occupy disk until the \(model.restoreWindowDays)-day restore window ends. Use “Delete permanently” to reclaim immediately.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    // Undo only exists when the batch put something in the Trash;
                    // purges (privacy, snapshots) are gone for good (§4.6).
                    if report.completed.contains(where: { $0.trashPath != nil }) {
                        Button("Undo last clean") { Task { await model.undoLast() } }
                    }
                    Button("Done") { Task { await model.rescan() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
        }
        .brandCard(padding: 20)
    }

    private func headline(_ report: ActionEngine.Report) -> String {
        let bytes = max(report.freedNowBytes, report.reclaimableAfterPurgeBytes)
        return bytes > 0 ? "\(AppModel.format(bytes)) reclaimed" : "All done"
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
