import Core
import Foundation

/// Result of validating a user-content text field (message body, title, query).
public enum SanitizedText: Sendable, Equatable {
    case valid(String)
    /// Nothing left after trimming and removing invisible characters.
    case empty
    /// Longer than the allowed number of characters (grapheme clusters).
    case tooLong
}

/// Length and charset validation for user-authored content that ends up in a `ResolvedAction`.
///
/// Removes C0/C1 control characters, bidirectional overrides and zero-width characters (which can
/// hide or reorder what the user sees on the confirmation card), normalizes line breaks, collapses
/// runs of horizontal whitespace and trims. Emoji joiners (U+200D) and variation selectors are kept.
public enum TextSanitizer {
    /// Format characters that are removed because they can visually hide or reorder text.
    private static let strippedFormatScalars: Set<UInt32> = [
        0x061C, // Arabic letter mark
        0x200B, // zero width space
        0x200E, 0x200F, // LRM, RLM
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, // LRE, RLE, PDF, LRO, RLO
        0x2060, // word joiner
        0x2066, 0x2067, 0x2068, 0x2069, // LRI, RLI, FSI, PDI
        0xFEFF, // byte order mark
    ]

    /// Cleans `raw`. When `allowNewlines` is false every line break becomes a single space.
    public static func clean(_ raw: String, allowNewlines: Bool) -> String {
        var output = String.UnicodeScalarView()
        var pendingSpace = false
        var pendingNewlines = 0

        func flushSeparators(into view: inout String.UnicodeScalarView) {
            if pendingNewlines > 0 {
                if !view.isEmpty {
                    for _ in 0..<min(pendingNewlines, 2) { view.append("\n") }
                }
            } else if pendingSpace, !view.isEmpty {
                view.append(" ")
            }
            pendingSpace = false
            pendingNewlines = 0
        }

        var previousWasCarriageReturn = false
        for scalar in raw.unicodeScalars {
            let isCarriageReturn = scalar == "\r"
            defer { previousWasCarriageReturn = isCarriageReturn }

            let isLineBreak = scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}"
                || scalar == "\u{0B}" || scalar == "\u{0C}" || scalar == "\u{85}"
            if isLineBreak {
                if scalar == "\n", previousWasCarriageReturn { continue }
                if allowNewlines { pendingNewlines += 1 } else { pendingSpace = true }
                continue
            }
            if scalar == "\t" || scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .surrogate, .unassigned, .privateUse:
                continue
            case .format where strippedFormatScalars.contains(scalar.value):
                continue
            default:
                break
            }
            flushSeparators(into: &output)
            output.append(scalar)
        }
        return String(output)
    }

    /// Validates a single-line field (titles, queries, locations).
    public static func singleLine(_ raw: String?, maxLength: Int) -> SanitizedText {
        validate(raw, maxLength: maxLength, allowNewlines: false)
    }

    /// Validates a multi-line field (message bodies).
    public static func multiLine(_ raw: String?, maxLength: Int) -> SanitizedText {
        validate(raw, maxLength: maxLength, allowNewlines: true)
    }

    private static func validate(_ raw: String?, maxLength: Int, allowNewlines: Bool) -> SanitizedText {
        guard let raw else { return .empty }
        let cleaned = clean(raw, allowNewlines: allowNewlines)
        if cleaned.isEmpty { return .empty }
        if cleaned.count > maxLength { return .tooLong }
        return .valid(cleaned)
    }

    /// The catalog's maximum length for a text argument (falls back to `fallback`).
    static func maxLength(of argument: String, in tool: ToolID, fallback: Int) -> Int {
        if case let .text(maxLength)? = ToolCatalog.spec(for: tool).argument(named: argument)?.kind {
            return maxLength
        }
        return fallback
    }
}
