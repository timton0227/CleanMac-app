import SwiftUI

// MARK: - Circle packing (shared geometry, ported from the design mock's `packCircles`)

struct PackedCircle: Identifiable {
    let id: String
    let cx: CGFloat
    let cy: CGFloat
    let r: CGFloat
}

/// Golden-angle spiral seed positions + iterative pairwise repulsion, rescaled
/// to fit `size`. Area (not radius) is proportional to `bytes`, so bubble
/// sizes stay visually honest. Shared by every "visualize files as bubbles"
/// screen (Space Lens, Large & Old Files) so they read as one system rather
/// than two different implementations of the same idea.
func packCircles(ids: [String], bytes: [Int64], size: CGSize) -> [PackedCircle] {
    let n = ids.count
    guard n > 0, n == bytes.count, size.width > 0, size.height > 0 else { return [] }

    let rs = bytes.map { sqrt(Double($0)) }
    let maxr = max(rs.max() ?? 1, 1)
    let golden = Double.pi * (3 - sqrt(5.0))
    var xs = [Double](repeating: 0, count: n)
    var ys = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let a = Double(i) * golden
        let rad = sqrt(Double(i) + 0.35)
        xs[i] = cos(a) * rad * maxr * 2.1
        ys[i] = sin(a) * rad * maxr * 2.1
    }

    let pad = maxr * 0.05
    for _ in 0..<260 {
        for i in 0..<n {
            for j in (i + 1)..<n {
                var dx = xs[j] - xs[i], dy = ys[j] - ys[i]
                var d = (dx * dx + dy * dy).squareRoot()
                if d < 0.001 { d = 0.001 }
                let minDist = rs[i] + rs[j] + pad
                if d < minDist {
                    let p = (minDist - d) / 2
                    dx /= d; dy /= d
                    xs[i] -= dx * p; ys[i] -= dy * p
                    xs[j] += dx * p; ys[j] += dy * p
                }
            }
        }
        for i in 0..<n { xs[i] *= 0.992; ys[i] *= 0.992 }
    }

    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    for i in 0..<n {
        minX = min(minX, xs[i] - rs[i]); maxX = max(maxX, xs[i] + rs[i])
        minY = min(minY, ys[i] - rs[i]); maxY = max(maxY, ys[i] + rs[i])
    }
    let bw = max(maxX - minX, 1), bh = max(maxY - minY, 1)
    let m = 12.0
    let sc = min((Double(size.width) - 2 * m) / bw, (Double(size.height) - 2 * m) / bh)
    let ox = (Double(size.width) - bw * sc) / 2 - minX * sc
    let oy = (Double(size.height) - bh * sc) / 2 - minY * sc

    return (0..<n).map { i in
        PackedCircle(id: ids[i], cx: CGFloat(xs[i] * sc + ox), cy: CGFloat(ys[i] * sc + oy), r: CGFloat(rs[i] * sc))
    }
}

/// The 14-hue cycling palette from the design mock's `PAL` array.
enum BubbleColors {
    static let palette: [Color] = [
        0x7C7BFF, 0x38BDF8, 0x2DD4BF, 0xA78BFA, 0xF472B6, 0xFBBF24, 0x34D399,
        0x60A5FA, 0xFB7185, 0x22D3EE, 0xC084FC, 0x818CF8, 0x4ADE80, 0xF0ABFC,
    ].map { Color(hex: $0) }
    static let muted = Color(hex: 0x463F5C)
}

// MARK: - One bubble's chrome — fill, selection/hover stroke, name+size label

struct BubbleCircleView: View {
    let label: String
    let sizeLabel: String
    let color: Color
    let radius: CGFloat
    var fillOpacity: Double = 0.85
    var isSelectable: Bool = true
    var isSelected: Bool = false
    var isHovering: Bool = false
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var onTap: () -> Void = {}

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(fillOpacity))
            Circle().strokeBorder(
                isSelected ? Brand.indigo : isHovering ? .white : .white.opacity(0.16),
                lineWidth: isSelected ? 3 : isHovering ? 2 : 1)
            if radius > 24 {
                VStack(spacing: 1) {
                    Text(truncatedLabel)
                        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(sizeLabel)
                        .font(.system(size: max(8, fontSize - 3)))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .lineLimit(1)
                .padding(.horizontal, 4)
            }
        }
        .opacity(isSelectable ? 1 : 0.45)
        .contentShape(Circle())
        .scaleEffect(isHovering ? 1.05 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { $0 ? onEnter() : onExit() }
        .onTapGesture(perform: onTap)
        .help("\(label) — \(sizeLabel)")
    }

    private var fontSize: CGFloat { min(15, max(9, radius / 4.2)) }

    private var truncatedLabel: String {
        let maxChars = Int(radius / (fontSize * 0.30))
        guard maxChars > 0, label.count > maxChars else { return label }
        return String(label.prefix(max(1, maxChars - 1))) + "…"
    }
}
