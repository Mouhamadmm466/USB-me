import SwiftUI
import UIKit

/// Semantic colours. The rule of the palette: colour belongs to the assistant (its state),
/// ink belongs to the person (their controls). Every value adapts to light, dark and
/// Increase Contrast.
enum Palette {
    // MARK: Surfaces

    /// Screen background.
    static let canvas = Color(uiColor: .systemBackground)
    /// Background behind grouped lists (Settings).
    static let groupedCanvas = Color(uiColor: .systemGroupedBackground)
    /// Cards placed on `canvas`. In dark mode sheets raise `canvas` to #1C1C1E, so the
    /// surface steps up with them.
    static let surface = dynamic(light: 0xF3F4F4, dark: 0x1C1C1E, darkElevated: 0x2C2C2E)
    /// Content wells inside a card (for example the body of a message).
    static let well = dynamic(light: 0xFFFFFF, dark: 0x2A2A2D, darkElevated: 0x3A3A3C)
    /// Neutral control fill (secondary buttons, chips, tracks).
    static let fill = dynamic(light: 0x767680, dark: 0x767680, lightAlpha: 0.10, darkAlpha: 0.22)
    /// Hairline separators and card outlines.
    static let hairline = Color(uiColor: UIColor { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: high ? 0.32 : 0.11)
            : UIColor(white: 0, alpha: high ? 0.30 : 0.09)
    })

    // MARK: Ink (the person's)

    static let ink = Color(uiColor: .label)
    static let inkSecondary = Color(uiColor: .secondaryLabel)
    static let inkTertiary = Color(uiColor: .tertiaryLabel)
    /// Text and glyphs drawn on an ink fill.
    static let inkInverse = Color(uiColor: .systemBackground)

    // MARK: State colours (the assistant's)

    /// The assistant's presence: listening, understanding, speaking, working, success.
    static let jade = dynamic(light: 0x0B7F68, dark: 0x3FD1AE, highContrastLight: 0x05634F, highContrastDark: 0x74EBCC)
    /// Waiting for your confirmation of a consequential action. Graphics only; use
    /// `amberText` for text.
    static let amber = dynamic(light: 0xE08A00, dark: 0xFFB340, highContrastLight: 0xB86B00, highContrastDark: 0xFFC96B)
    /// Amber that meets 4.5:1 as text on `canvas` and `surface`.
    static let amberText = dynamic(light: 0x9A5700, dark: 0xFFC266, highContrastLight: 0x7A4500, highContrastDark: 0xFFD699)
    /// The assistant asked you a question.
    static let sky = dynamic(light: 0x2F6FD0, dark: 0x82B5FF, highContrastLight: 0x1F55A8, highContrastDark: 0xA9CCFF)
    /// Errors and destructive actions.
    static let danger = dynamic(light: 0xD4281C, dark: 0xFF6B61, highContrastLight: 0xA8190F, highContrastDark: 0xFF948C)
    /// Blocked or unavailable (permission needed).
    static let mist = dynamic(light: 0x7E858A, dark: 0x8F959A, highContrastLight: 0x5B6166, highContrastDark: 0xB4B9BD)

    // MARK: Helpers

    static func dynamic(
        light: UInt32, dark: UInt32,
        darkElevated: UInt32? = nil,
        highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil,
        lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            if traits.userInterfaceStyle == .dark {
                let base = traits.userInterfaceLevel == .elevated ? (darkElevated ?? dark) : dark
                return UIColor(hex: high ? (highContrastDark ?? base) : base, alpha: darkAlpha)
            }
            return UIColor(hex: high ? (highContrastLight ?? light) : light, alpha: lightAlpha)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Tones shared by pills, icon tiles and banners.
enum Tone: Sendable, CaseIterable {
    case jade, amber, sky, danger, neutral

    var color: Color {
        switch self {
        case .jade: Palette.jade
        case .amber: Palette.amber
        case .sky: Palette.sky
        case .danger: Palette.danger
        case .neutral: Palette.mist
        }
    }

    /// Foreground for text in this tone (amber needs a darker value to stay legible).
    var textColor: Color {
        switch self {
        case .amber: Palette.amberText
        case .neutral: Palette.inkSecondary
        default: color
        }
    }

    /// Soft background tint for this tone.
    var fill: Color {
        switch self {
        case .neutral: Palette.fill
        default: color.opacity(0.13)
        }
    }
}
