import SwiftUI

/// 4-point spacing scale.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
    static let huge: CGFloat = 48

    /// Side margin of full-width content on the assistant and onboarding screens.
    static let screenMargin: CGFloat = 20
}

/// Corner radii by level of hierarchy (always drawn with `.continuous` corners).
enum Radius {
    /// Icon tiles and small wells.
    static let small: CGFloat = 10
    /// Wells inside cards, text fields.
    static let medium: CGFloat = 14
    /// Choice chips and list-like cards.
    static let large: CGFloat = 18
    /// Primary cards (action card, permission card).
    static let card: CGFloat = 26
}

/// Readable-width limits.
enum Measure {
    /// Maximum width of running text (about 60–70 characters of body text).
    static let text: CGFloat = 520
    /// Maximum width of cards and control rows.
    static let content: CGFloat = 560
}

extension Shape where Self == RoundedRectangle {
    /// A continuous-corner rounded rectangle.
    static func rounded(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// A one-pixel separator that stays one physical pixel at every display scale.
struct Hairline: View {
    enum Axis { case horizontal, vertical }

    var axis: Axis = .horizontal
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let thickness = 1 / max(displayScale, 1)
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: axis == .vertical ? thickness : nil, height: axis == .horizontal ? thickness : nil)
            .accessibilityHidden(true)
    }
}
