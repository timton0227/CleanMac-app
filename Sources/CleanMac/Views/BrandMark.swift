import SwiftUI

/// The aperture-ring mark from the Clean Mac visual style guide: a progress
/// ring whose open gap represents space reclaimed. Reusable so it renders
/// identically wherever the brand appears in-app.
struct RingMark: View {
    var ringColor = Brand.indigo
    var trackColor = Brand.border
    /// Matches the style guide's own dasharray (160 of a 213.63 circumference).
    var fraction: CGFloat = 160.0 / 213.63

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let lineWidth = size * (7.0 / 44.0) // guide ratio: 22pt ring, 7pt stroke
            ZStack {
                Circle().stroke(trackColor, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(lineWidth / 2)
            .frame(width: size, height: size)
        }
    }
}

/// The primary lockup — ring + wordmark — per §02 of the style guide.
struct BrandMark: View {
    enum Tone { case full, dark, onColor }
    var tone: Tone = .full
    var ringDiameter: CGFloat = 22
    var wordmarkSize: CGFloat = 17

    var body: some View {
        HStack(spacing: 10) {
            RingMark(ringColor: ringColor, trackColor: trackColor)
                .frame(width: ringDiameter, height: ringDiameter)
            Text("Clean Mac")
                // Space Grotesk isn't a system font; `.rounded` keeps the same
                // geometric, technical character without bundling a webfont.
                .font(.system(size: wordmarkSize, weight: .bold, design: .rounded))
                .foregroundStyle(textColor)
        }
    }

    private var ringColor: Color {
        tone == .full ? Brand.indigo : .white
    }
    private var trackColor: Color {
        tone == .full ? Brand.border : .white.opacity(0.3)
    }
    private var textColor: Color {
        tone == .full ? Brand.ink : .white
    }
}

#Preview {
    VStack(spacing: 20) {
        BrandMark().padding().background(.white)
        BrandMark(tone: .dark).padding().background(Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255))
    }
}
