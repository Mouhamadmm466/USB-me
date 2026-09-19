import SwiftUI
import UIKit

/// The DM Sans faces bundled in `Resources/Fonts` (registered through `UIAppFonts`).
/// The raw value is the PostScript name.
enum DMSans: String, CaseIterable, Sendable {
    case regular = "DMSans-Regular"
    case medium = "DMSans-Medium"
    case semibold = "DMSans-SemiBold"
    case bold = "DMSans-Bold"
}

/// The app's type scale. Every step is DM Sans, anchored to an iOS text style so it follows
/// Dynamic Type exactly like the system font would.
enum TypeStyle: CaseIterable, Sendable {
    /// Onboarding headlines.
    case display
    case largeTitle
    case title
    case title2
    case title3
    case headline
    case body
    case callout
    case subheadline
    case footnote
    case caption
    case caption2

    /// Point size at the default (Large) Dynamic Type setting.
    var size: CGFloat {
        switch self {
        case .display: 36
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        }
    }

    var defaultWeight: DMSans {
        switch self {
        case .display, .largeTitle: .bold
        case .title, .title2, .title3, .headline: .semibold
        case .caption2: .medium
        default: .regular
        }
    }

    /// Letter spacing in points. DM Sans is a geometric face: display sizes are tightened,
    /// small sizes opened slightly for legibility.
    var tracking: CGFloat {
        switch self {
        case .display: -0.9
        case .largeTitle: -0.7
        case .title: -0.45
        case .title2: -0.25
        case .title3: -0.15
        case .headline, .body, .callout: -0.1
        case .subheadline: -0.05
        case .footnote: 0
        case .caption, .caption2: 0.1
        }
    }

    var textStyle: Font.TextStyle {
        switch self {
        case .display, .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        }
    }

    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .display, .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        }
    }
}

extension Font {
    /// DM Sans at a step of the type scale, scaled with Dynamic Type.
    ///
    ///     Text("Listening").font(.dm(.title3))
    ///     Text("Send").font(.dm(.body, weight: .semibold))
    static func dm(_ style: TypeStyle, weight: DMSans? = nil) -> Font {
        .custom((weight ?? style.defaultWeight).rawValue, size: style.size, relativeTo: style.textStyle)
    }

    /// DM Sans at an arbitrary size, still scaled relative to a text style.
    static func dm(size: CGFloat, weight: DMSans = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .custom(weight.rawValue, size: size, relativeTo: textStyle)
    }
}

extension UIFont {
    /// DM Sans for UIKit chrome (navigation bars), scaled with Dynamic Type.
    static func dm(_ style: TypeStyle, weight: DMSans? = nil) -> UIFont {
        let base = UIFont(name: (weight ?? style.defaultWeight).rawValue, size: style.size)
            ?? .systemFont(ofSize: style.size)
        return UIFontMetrics(forTextStyle: style.uiTextStyle).scaledFont(for: base)
    }
}

extension View {
    /// Applies a step of the type scale: DM Sans, Dynamic Type scaling and the step's tracking.
    func textStyle(_ style: TypeStyle, weight: DMSans? = nil) -> some View {
        font(.dm(style, weight: weight)).tracking(style.tracking)
    }
}
