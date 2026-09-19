import Foundation

/// Deterministic normalization and tokenization shared by contact, event and file matching.
///
/// Folding is locale-independent (`en_US_POSIX`), case-insensitive, diacritic-insensitive and
/// width-insensitive, so "José" == "jose" and "Ｋｉｍ" == "kim".
public enum TextTokens {
    private static let posix = Locale(identifier: "en_US_POSIX")

    public static func fold(_ text: String) -> String {
        // Fast path: ASCII only needs lowercasing (diacritic and width folding are no-ops).
        var isASCII = true
        var hasUppercase = false
        for byte in text.utf8 {
            if byte >= 0x80 { isASCII = false; break }
            if byte >= 0x41, byte <= 0x5A { hasUppercase = true }
        }
        if isASCII {
            guard hasUppercase else { return text }
            return String(decoding: text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)
        }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: posix)
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}" || character == "\u{2018}" || character == "\u{02BC}" || character == "`"
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Folded word tokens. Inner apostrophes are dropped ("O'Brien" -> "obrien"), a trailing
    /// possessive is removed ("Alex's" -> "alex"), and every other non-alphanumeric character
    /// separates tokens ("Mary-Jane" -> "mary", "jane").
    public static func words(_ text: String) -> [String] {
        let folded = fold(text)
        if folded.utf8.allSatisfy({ $0 < 0x80 }) { return asciiWords(folded) }
        let characters = Array(folded)
        var tokens: [String] = []
        var current = ""
        var index = 0
        func flush() {
            if !current.isEmpty { tokens.append(current) }
            current = ""
        }
        while index < characters.count {
            let character = characters[index]
            if isWordCharacter(character) {
                current.append(character)
            } else if isApostrophe(character), !current.isEmpty {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let afterNext = index + 2 < characters.count ? characters[index + 2] : nil
                if next == "s", afterNext.map({ !isWordCharacter($0) }) ?? true {
                    // Possessive "'s": drop it and end the word.
                    index += 2
                    flush()
                    continue
                }
                // Inner apostrophe: keep joining ("o'brien").
            } else {
                flush()
            }
            index += 1
        }
        flush()
        return tokens
    }

    /// `words` for already-folded ASCII text, scanning bytes instead of grapheme clusters.
    private static func asciiWords(_ folded: String) -> [String] {
        let bytes = Array(folded.utf8)
        var tokens: [String] = []
        var current: [UInt8] = []
        func isWordByte(_ byte: UInt8) -> Bool {
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
        }
        func flush() {
            if !current.isEmpty { tokens.append(String(decoding: current, as: UTF8.self)) }
            current.removeAll(keepingCapacity: true)
        }
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if isWordByte(byte) {
                current.append(byte)
            } else if (byte == 0x27 || byte == 0x60), !current.isEmpty { // ' or `
                let next = index + 1 < bytes.count ? bytes[index + 1] : nil
                let afterNext = index + 2 < bytes.count ? bytes[index + 2] : nil
                if next == 0x73, afterNext.map({ !isWordByte($0) }) ?? true { // possessive 's
                    index += 2
                    flush()
                    continue
                }
            } else {
                flush()
            }
            index += 1
        }
        flush()
        return tokens
    }

    /// Normalized phrase used for whole-phrase comparisons ("That meeting!" -> "that meeting").
    public static func phrase(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

    /// Light English plural stemming for title/file matching ("meetings" -> "meeting").
    public static func stem(_ token: String) -> String {
        guard token.count > 3, token.hasSuffix("s"), !token.hasSuffix("ss") else { return token }
        if token.hasSuffix("ies"), token.count > 4 { return String(token.dropLast(3)) + "y" }
        return String(token.dropLast())
    }

    /// Splits a file name into folded tokens, also breaking camelCase and letter/digit boundaries
    /// ("QuarterlyReport2026" -> "quarterly", "report", "2026").
    public static func fileNameWords(_ name: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            if character.isLetter || character.isNumber {
                if let previous, !current.isEmpty {
                    let caseBoundary = previous.isLowercase && character.isUppercase
                    let digitBoundary = previous.isNumber != character.isNumber
                    if caseBoundary || digitBoundary {
                        pieces.append(current)
                        current = ""
                    }
                }
                current.append(character)
            } else if !isApostrophe(character) {
                if !current.isEmpty { pieces.append(current) }
                current = ""
            }
            previous = character
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.map(fold).filter { !$0.isEmpty }
    }
}
