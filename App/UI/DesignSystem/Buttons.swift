import SwiftUI

/// Capsule buttons. `.prominent` is ink (the person's decision), `.secondary` a neutral fill,
/// `.destructive` a red tint, `.tinted` a soft state colour for inline row actions.
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind {
        case prominent
        case secondary
        case destructive
        case tinted(Color)
    }

    enum Size {
        /// Full-height call to action (52 pt at the default text size).
        case large
        /// 44 pt: inline actions in cards.
        case medium
        /// Compact row actions ("Retry", "Download").
        case small
    }

    var kind: Kind = .prominent
    var size: Size = .large
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButtonBody(configuration: configuration, kind: kind, size: size, fullWidth: fullWidth)
    }
}

private struct CapsuleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: CapsuleButtonStyle.Kind
    let size: CapsuleButtonStyle.Size
    let fullWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .textStyle(textStyle, weight: .semibold)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: minHeight)
            .background(Capsule(style: .continuous).fill(background).opacity(pressed ? 0.78 : 1))
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(Motion.snappy, value: pressed)
    }

    private var textStyle: TypeStyle {
        switch size {
        case .large: .headline
        case .medium: .callout
        case .small: .subheadline
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .large: 15
        case .medium: 11
        case .small: 7
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .large: 24
        case .medium: 18
        case .small: 14
        }
    }

    private var minHeight: CGFloat {
        switch size {
        case .large: 52
        case .medium: 44
        case .small: 32
        }
    }

    private var background: Color {
        guard isEnabled else { return Palette.fill }
        switch kind {
        case .prominent: return Palette.ink
        case .secondary: return Palette.fill
        case .destructive: return Palette.danger.opacity(0.13)
        case let .tinted(color): return color.opacity(0.14)
        }
    }

    private var foreground: Color {
        guard isEnabled else { return Palette.inkTertiary }
        switch kind {
        case .prominent: return Palette.inkInverse
        case .secondary: return Palette.ink
        case .destructive: return Palette.danger
        case let .tinted(color): return color
        }
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    /// Ink capsule for the primary action on a surface.
    static var prominent: CapsuleButtonStyle { CapsuleButtonStyle(kind: .prominent) }
    /// Neutral capsule for the alternative action.
    static var secondary: CapsuleButtonStyle { CapsuleButtonStyle(kind: .secondary) }
    /// Red-tinted capsule for actions that remove something.
    static var destructive: CapsuleButtonStyle { CapsuleButtonStyle(kind: .destructive) }

    static func capsule(
        _ kind: CapsuleButtonStyle.Kind = .prominent,
        size: CapsuleButtonStyle.Size = .large,
        fullWidth: Bool = true
    ) -> CapsuleButtonStyle {
        CapsuleButtonStyle(kind: kind, size: size, fullWidth: fullWidth)
    }
}

/// Round glass button for toolbar-like icon actions (settings, keyboard, history).
struct GlassCircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        GlassCircleBody(configuration: configuration, diameter: diameter)
    }
}

private struct GlassCircleBody: View {
    let configuration: ButtonStyleConfiguration
    let diameter: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.system(size: diameter * 0.38, weight: .medium))
            .foregroundStyle(isEnabled ? Palette.ink : Palette.inkTertiary)
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .glassSurface(Circle(), interactive: true)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassCircleButtonStyle {
    static var glassCircle: GlassCircleButtonStyle { GlassCircleButtonStyle() }
    static func glassCircle(diameter: CGFloat) -> GlassCircleButtonStyle { GlassCircleButtonStyle(diameter: diameter) }
}

/// Text-only button for low-emphasis actions ("Not now").
struct QuietButtonStyle: ButtonStyle {
    var tone: Color = Palette.inkSecondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.callout, weight: .medium)
            .foregroundStyle(tone)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}
