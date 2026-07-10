import SwiftUI
import CleanCore

// MARK: - Palette

/// The Clean Mac design system: the visual style guide's palette plus the
/// reusable interactive chrome (cards, tags, banners, the pipeline step bar,
/// and the aperture-ring progress indicator). Every view draws from here so
/// the brand reads the same everywhere. Colors adapt to dark mode; the light
/// values are the guide's exact tokens.
enum Brand {
    // The app runs dark-first (CleanMyMac-style immersive canvas); the dark
    // values are plum-tinted to sit on the space gradient. Light values remain
    // the guide's exact tokens.
    static let ink     = Color(light: 0x1C1C1E, dark: 0xF5F5F7)
    static let paper   = Color(light: 0xFFFFFF, dark: 0x2A2440)
    static let mist    = Color(light: 0xF5F5F4, dark: 0x201A32)
    static let border  = Color(light: 0xE4E4E2, dark: 0x3E3756)
    static let fog     = Color(light: 0x8E8E93, dark: 0xA5A1B8)
    static let indigo  = Color(light: 0x5E5CE6, dark: 0x7674FF)
    static let danger  = Color(light: 0xE24B4A, dark: 0xE2504F)

    /// Space Grotesk isn't a system font; `.rounded` carries the same
    /// geometric, technical character (matches `BrandMark`).
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Exact per-module hex accents from the design mock — used by the
    /// sidebar dots, hero illustrations, and badge pills so every module
    /// reads with its own identity instead of a handful of system colors.
    static let systemJunk  = Color(hex: 0xF5A623)
    static let largeFiles  = Color(hex: 0x60A5FA)
    static let snapshots   = Color(hex: 0xA78BFA)
    static let iosBackups  = Color(hex: 0x22D3EE)
    static let duplicates  = Color(hex: 0x34D399)
    static let privacy     = Color(hex: 0xF472B6)
    static let startup     = Color(hex: 0xFBBF24)
    static let uninstaller = Color(hex: 0xFB7185)
    static let spaceLens   = Color(hex: 0x2DD4BF)
    static let trash       = Color(hex: 0x9AA0AC)
    static let keeper      = Color(hex: 0x34D399)
    static let cloud       = Color(hex: 0x60A5FA)
    static let lowConfidence = Color(hex: 0xFBBF24)
}

extension Color {
    /// A single fixed hex value — for the design mock's exact per-module
    /// accents, which don't adapt between light/dark (the app is dark-first).
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }

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
            // Tinted to the plum canvas rather than pure black, so the lift reads
            // as depth on the space gradient instead of a grey smudge.
            .shadow(color: Color(red: 0.05, green: 0.03, blue: 0.10)
                        .opacity(hovering ? 0.45 : 0.18),
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

// MARK: - Space background

/// The immersive canvas behind every screen: a deep plum gradient with a
/// faint, static starfield (seeded, so it never twinkles distractingly).
struct SpaceBackground: View {
    /// The hero bloom belongs behind the detail pane's illustration; the sidebar
    /// shares the same gradient + starfield but skips the bloom so the palette
    /// reads as one continuous canvas without a second glow floating in the rail.
    var showBloom = true

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.20, green: 0.15, blue: 0.29), location: 0),
                    .init(color: Color(red: 0.14, green: 0.11, blue: 0.21), location: 0.55),
                    .init(color: Color(red: 0.09, green: 0.07, blue: 0.14), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
            // A soft magenta bloom behind the hero illustration area.
            if showBloom {
                RadialGradient(
                    colors: [Color(red: 0.85, green: 0.30, blue: 0.55).opacity(0.14), .clear],
                    center: .init(x: 0.5, y: 0.30), startRadius: 0, endRadius: 420)
            }
            Canvas { context, size in
                var rng = SeededRandom(seed: 7)
                for _ in 0..<70 {
                    let x = rng.next() * size.width
                    let y = rng.next() * size.height
                    let r = 0.5 + rng.next() * 1.3
                    let opacity = 0.05 + rng.next() * 0.28
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                        with: .color(.white.opacity(opacity)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Deterministic LCG so the starfield is stable frame to frame.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}

// MARK: - Conic progress ring (dashboard)

/// A hard-edged pie sweep behind a punched-out center — the dashboard's
/// `conic-gradient` disc from the mock: not a stroked ring like `RingMark`,
/// but a filled wedge that grows clockwise from noon as progress advances.
struct ConicProgressRing: View {
    var progress: Double
    var accent: Color
    var innerFill: Color = Color(hex: 0x1C1730)
    var diameter: CGFloat = 108
    var innerDiameter: CGFloat = 86

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.10))
            PieSlice(fraction: max(0, min(1, progress))).fill(accent)
            Circle().fill(innerFill).frame(width: innerDiameter, height: innerDiameter)
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.3), value: progress)
    }
}

private struct PieSlice: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.move(to: center)
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * fraction),
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - Circular scan button

/// The signature control: a big round button with a glowing ring, pinned at
/// the bottom-center of every hero screen. The mock draws this as a flat
/// 2px accent-color ring (88px on module heroes, 80px on the dashboard) —
/// not a rotating multi-color gradient.
struct CircularScanButton: View {
    var title = "Scan"
    var diameter: CGFloat = 88
    var accent: Color = Brand.indigo
    var disabled = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Brand.display(14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(.black.opacity(0.35)))
                .overlay(Circle().strokeBorder(accent, lineWidth: 2))
                .shadow(color: accent.opacity(disabled ? 0.15 : hovering ? 0.75 : 0.4),
                        radius: hovering ? 18 : 10)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .scaleEffect(hovering && !disabled ? 1.06 : 1)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.25), value: hovering)
    }
}

// MARK: - Module hero (idle state)

/// The hero idle state every module opens with: the aperture ring as the
/// central illustration, a friendly headline, one honest line of description,
/// and the big circular action button at the bottom.
struct ModuleHero<Secondary: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    var primaryLabel: String?
    var primaryAction: (() -> Void)?
    @ViewBuilder var secondary: Secondary

    init(icon: String, tint: Color, title: String, message: String,
         primaryLabel: String? = nil, primaryAction: (() -> Void)? = nil,
         @ViewBuilder secondary: () -> Secondary = { EmptyView() }) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.message = message
        self.primaryLabel = primaryLabel
        self.primaryAction = primaryAction
        self.secondary = secondary()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            // The mock's `heroBlock`: a 128px tinted glow with a flat 3px
            // border, holding just a small colored dot — no icon, no ring.
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.25), .clear],
                                          center: .center, startRadius: 0, endRadius: 64))
                    .overlay(Circle().strokeBorder(tint.opacity(0.55), lineWidth: 3))
                    .frame(width: 128, height: 128)
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint)
                    .frame(width: 14, height: 14)
            }
            .padding(.bottom, 26)
            Text(title)
                .font(Brand.display(26))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(Brand.fog)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Spacer()
            if let primaryLabel, let primaryAction {
                CircularScanButton(title: primaryLabel, action: primaryAction)
            }
            HStack(spacing: 12) { secondary }
                .padding(.top, 12)
            Spacer().frame(height: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

// MARK: - Empty good state

/// "Nothing left to do" — the mock's `emptyGoodState`: a small tinted
/// checkmark circle instead of the hero's Scan button, shown once a module
/// has been fully cleaned and there's nothing left to review.
struct EmptyGoodState: View {
    var tint: Color = Brand.indigo
    var title: String = "All clear!"
    var message: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(tint.opacity(0.13)).frame(width: 80, height: 80)
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(Brand.display(22))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Brand.fog)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
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
        .background(.black.opacity(0.18))
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
