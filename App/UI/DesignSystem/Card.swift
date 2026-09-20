import SwiftUI

/// The card container: a quiet surface with a hairline edge and continuous corners.
/// A `tone` outlines the card in a state colour (the action card uses amber).
struct Card<Content: View>: View {
    var tone: Tone?
    var padding: CGFloat
    var radius: CGFloat
    var background: Color
    private let content: Content

    init(
        tone: Tone? = nil,
        padding: CGFloat = Spacing.xl,
        radius: CGFloat = Radius.card,
        background: Color = Palette.surface,
        @ViewBuilder content: () -> Content
    ) {
        self.tone = tone
        self.padding = padding
        self.radius = radius
        self.background = background
        self.content = content()
    }

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: shape)
            .overlay {
                if let tone {
                    shape.strokeBorder(tone.color.opacity(0.6), lineWidth: 1.5)
                } else {
                    shape.strokeBorder(Palette.hairline, lineWidth: 1 / max(displayScale, 1))
                }
            }
    }
}

/// A rounded-square tile holding an SF Symbol, used at the head of cards and rows.
struct IconTile: View {
    enum Style { case soft, solid }

    let systemImage: String
    var tone: Tone = .neutral
    var style: Style = .soft
    @ScaledMetric private var side: CGFloat

    init(systemImage: String, tone: Tone = .neutral, style: Style = .soft, size: CGFloat = 36) {
        self.systemImage = systemImage
        self.tone = tone
        self.style = style
        _side = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        let clamped = min(side, 64)
        Image(systemName: systemImage)
            .font(.system(size: clamped * 0.46, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(style == .solid ? Color.white : tone.color)
            .frame(width: clamped, height: clamped)
            .background(
                RoundedRectangle(cornerRadius: clamped * 0.3, style: .continuous)
                    .fill(style == .solid ? tone.color : tone.fill)
            )
            .accessibilityHidden(true)
    }
}

/// A slim capsule progress bar.
struct ProgressBar: View {
    var value: Double
    var tint: Color = Palette.clay
    var height: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Palette.fill)
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: clamped > 0 ? max(height, proxy.size.width * clamped) : 0)
            }
        }
        .frame(height: height)
        .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: value)
        .accessibilityHidden(true)
    }
}
