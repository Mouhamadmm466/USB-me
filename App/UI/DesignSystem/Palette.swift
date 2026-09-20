import SwiftUI
import UIKit

/// Semantic colours. The rule of the palette: colour belongs to the assistant (its state),
/// ink belongs to the person (their controls). Every value adapts to light, dark and
/// Increase Contrast.
///
/// The whole palette is warm. Paper, not screen: a cream canvas, warm greys for text, and one
/// accent — clay — that the assistant uses for everything it does. A neutral-grey app reads as
/// software; a warm one reads as something that belongs to you.
enum Palette {
    // MARK: Surfaces

    /// Screen background. Paper, not white.
    static let canvas = dynamic(light: 0xFAF9F5, dark: 0x1B1B19, darkElevated: 0x232321,
                                highContrastLight: 0xFFFFFF, highContrastDark: 0x121211)
    /// Background behind grouped lists (Settings): one step deeper than the cards on it.
    static let groupedCanvas = dynamic(light: 0xF0EEE6, dark: 0x141413, darkElevated: 0x1B1B19)
    /// Cards placed on `canvas`. In dark mode sheets raise `canvas`, so the surface steps up too.
    static let surface = dynamic(light: 0xF0EEE6, dark: 0x262624, darkElevated: 0x30302D)
    /// Content wells inside a card (for example the body of a message).
    static let well = dynamic(light: 0xFFFFFF, dark: 0x30302D, darkElevated: 0x3A3A36)
    /// Neutral control fill (secondary buttons, chips, tracks). Warm, so it sits on cream.
    static let fill = dynamic(light: 0x8A8578, dark: 0xA8A396, lightAlpha: 0.14, darkAlpha: 0.20)
    /// Hairline separators and card outlines.
    static let hairline = Color(uiColor: UIColor { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: high ? 0.32 : 0.10)
            : UIColor(hex: 0x3D3A32, alpha: high ? 0.32 : 0.12)
    })

    // MARK: Ink (the person's)

    static let ink = dynamic(light: 0x1F1E1D, dark: 0xF2F0E9, highContrastLight: 0x000000, highContrastDark: 0xFFFFFF)
    static let inkSecondary = dynamic(light: 0x6E6B62, dark: 0xB4B1A6,
                                      highContrastLight: 0x4A483F, highContrastDark: 0xD4D1C6)
    static let inkTertiary = dynamic(light: 0x96938A, dark: 0x85827A,
                                     highContrastLight: 0x6B685F, highContrastDark: 0xA5A29A)
    /// Text and glyphs drawn on an ink fill.
    static let inkInverse = dynamic(light: 0xFAF9F5, dark: 0x1B1B19)

    // MARK: State colours (the assistant's)

    /// The assistant's presence: listening, understanding, speaking, working, success. Graphics
    /// only — for text on a light surface use `clayText`.
    static let clay = dynamic(light: 0xD97757, dark: 0xE08A6B,
                              highContrastLight: 0xB8522F, highContrastDark: 0xF0A98D)
    /// Clay that meets 4.5:1 as text on `canvas` and `surface`.
    static let clayText = dynamic(light: 0xA6472A, dark: 0xEDA98E,
                                  highContrastLight: 0x86351D, highContrastDark: 0xF7C9B5)
    /// Waiting for your confirmation of a consequential action. Graphics only; use
    /// `amberText` for text.
    static let amber = dynamic(light: 0xC08A2B, dark: 0xE3B45C, highContrastLight: 0x9A6C15, highContrastDark: 0xF0CC85)
    /// Amber that meets 4.5:1 as text on `canvas` and `surface`.
    static let amberText = dynamic(light: 0x8A6018, dark: 0xEDCB86, highContrastLight: 0x6B4A0F, highContrastDark: 0xF6E0B4)
    /// The assistant asked you a question. The one cool colour, so a question never reads as
    /// the assistant working.
    static let sky = dynamic(light: 0x4A6FA5, dark: 0x93B6E5, highContrastLight: 0x33547F, highContrastDark: 0xB6CFF0)
    /// Errors and destructive actions.
    static let danger = dynamic(light: 0xBE3B30, dark: 0xF0837A, highContrastLight: 0x96251C, highContrastDark: 0xF7A8A1)
    /// Blocked or unavailable (permission needed).
    static let mist = dynamic(light: 0x857F74, dark: 0x9B968B, highContrastLight: 0x615C53, highContrastDark: 0xB8B3A8)

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
    case clay, amber, sky, danger, neutral

    var color: Color {
        switch self {
        case .clay: Palette.clay
        case .amber: Palette.amber
        case .sky: Palette.sky
        case .danger: Palette.danger
        case .neutral: Palette.mist
        }
    }

    /// Foreground for text in this tone (clay and amber need darker values to stay legible).
    var textColor: Color {
        switch self {
        case .clay: Palette.clayText
        case .amber: Palette.amberText
        case .neutral: Palette.inkSecondary
        default: color
        }
    }

    /// Soft background tint for this tone.
    var fill: Color {
        switch self {
        case .neutral: Palette.fill
        default: color.opacity(0.15)
        }
    }
}
