import SwiftUI
import CleanCore

// MARK: - Palette

/// The Clean Mac design system: the visual style guide's palette plus the
/// reusable interactive chrome (cards, tags, banners, the pipeline step bar,
/// and the aperture-ring progress indicator). Every view draws from here so
/// the brand reads the same everywhere. Colors adapt to dark mode; the light
/// values are the guide's exact tokens.
enum Brand {
    static let ink     = Color(light: 0x1C1C1E, dark: 0xF5F5F4)
    static let paper   = Color(light: 0xFFFFFF, dark: 0x232326)
    static let mist    = Color(light: 0xF5F5F4, dark: 0x1A1A1C)
    static let border  = Color(light: 0xE4E4E2, dark: 0x3A3A3C)
    static let fog     = Color(light: 0x8E8E93, dark: 0x98989D)
    static let indigo  = Color(light: 0x5E5CE6, dark: 0x7674FF)
    static let danger  = Color(light: 0xE24B4A, dark: 0xE2504F)

    /// Space Grotesk isn't a system font; `.rounded` carries the same
    /// geometric, technical character (matches `BrandMark`).
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        })
    }
}

// MARK: - Card chrome

extension View {
    /// Standard content card: paper surface, hairline border, rounded corners.
    func brandCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.paper, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.border))
    }

    /// Hover affordance for clickable cards: a gentle lift + shadow.
    func hoverLift() -> some View {
        modifier(HoverLift())
    }
}

private struct HoverLift: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.02 : 1)
            .shadow(color: .black.opacity(hovering ? 0.10 : 0.03),
                    radius: hovering ? 9 : 3, y: hovering ? 4 : 1)
            .onHover { hovering = $0 }
            .animation(.spring(duration: 0.25), value: hovering)
    }
}

// MARK: - Tags & banners

/// The little capsule badge used on rows everywhere ("Protected", "In use",
/// "Launches at login", …).
struct BrandTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Full-width contextual strip under the header (warnings, scope notes,
/// sweep offers). One shape for every banner in the app.
struct InfoBanner<Trailing: View>: View {
    let icon: String
    let tint: Color
    let text: String
    @ViewBuilder var trailing: Trailing

    init(icon: String, tint: Color, text: String,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.icon = icon
        self.tint = tint
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08))
    }
}

// MARK: - Pipeline step bar

/// The always-visible answer to "where am I in the flow?" — every pipeline
/// module shows Scan → Review → Clean → Done, with the current step lit.
struct PhaseBar: View {
    let phase: AppModel.Phase
    /// Modules whose third step isn't a reversible clean rename it honestly
    /// ("Clear" for privacy purges, "Delete" for snapshots).
    var actLabel = "Clean"

    private var steps: [String] { ["Scan", "Review", actLabel, "Done"] }

    private var current: Int {
        switch phase {
        case .idle, .scanning: 0
        case .review: 1
        case .acting: 2
        case .report: 3
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, name in
                if index > 0 {
                    Rectangle()
                        .fill(index <= current ? Brand.indigo : Brand.border)
                        .frame(width: 28, height: 2)
                        .padding(.horizontal, 6)
                }
                HStack(spacing: 6) {
                    ZStack {
                        if index < current {
                            Circle().fill(Brand.indigo)
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        } else if index == current {
                            Circle().fill(Brand.indigo)
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Circle().strokeBorder(Brand.border, lineWidth: 1.5)
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Brand.fog)
                        }
                    }
                    .frame(width: 17, height: 17)
                    Text(name)
                        .font(.system(size: 12, weight: index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? Brand.ink : Brand.fog)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.25), value: current)
    }
}

// MARK: - Scan progress ring

/// Scan progress rendered as the brand's aperture ring — the arc closes as
/// the scan completes. Indeterminate work spins the ~75% brand ring instead.
struct ScanRing: View {
    var progress: Double = 0
    var label: String
    var indeterminate = false

    @State private var spinning = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RingMark(fraction: indeterminate ? 160.0 / 213.63 : max(0.02, progress))
                    .frame(width: 96, height: 96)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                if !indeterminate {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(Brand.display(20, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.3), value: progress)
        .onAppear {
            guard indeterminate else { return }
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }
}

// MARK: - Module hero (idle state)

/// The branded idle state every module opens with: icon tile, title, honest
/// description, and the primary action front and center.
struct ModuleHero<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(tint.opacity(0.13))
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(Brand.display(24))
                .foregroundStyle(Brand.ink)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) { actions }
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Storage header

/// Live storage + reclaimable totals shown atop every module. Updates
/// optimistically on delete without a rescan (FR-UX-LIVE), reconciled in the
/// background.
struct StorageHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 28) {
            metric("Free on disk", model.displayedFreeBytes)
            if model.volumeTotalBytes > 0 {
                metric("Volume", model.volumeTotalBytes)
            }
            metric("Selected to reclaim", model.reclaimableBytes, tint: Brand.indigo)
            Spacer()
            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Brand.mist.opacity(0.6))
    }

    private func metric(_ label: String, _ bytes: Int64, tint: Color = Brand.ink) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Brand.fog)
            Text(AppModel.format(bytes))
                .font(Brand.display(17, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .animation(.default, value: bytes)
        }
    }
}
