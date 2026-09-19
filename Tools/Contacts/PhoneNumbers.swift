import Core
import Foundation

/// Phone number normalization shared by the resolver, the executor and the fakes.
public enum PhoneNumbers {
    public static let minimumDigits = 3
    public static let maximumDigits = 20

    /// ASCII digits of a stored or dictated number, stopping at an extension marker
    /// ("x", "ext", ",", ";", "#"). Other characters are ignored.
    public static func digits(in number: String) -> String {
        String(mainPart(of: number).compactMap(\.asciiDigit))
    }

    /// The number without its extension ("555-1234 ext. 12" -> "555-1234").
    private static func mainPart(of number: String) -> Substring {
        let characters = Array(number.lowercased())
        var sawDigit = false
        var end = characters.count
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.asciiDigit != nil {
                sawDigit = true
            } else if character == "," || character == ";" || character == "#" {
                end = index
                break
            } else if sawDigit, character == "x" || (character == "e" && index + 2 < characters.count
                                                       && characters[index + 1] == "x" && characters[index + 2] == "t") {
                end = index
                break
            }
            index += 1
        }
        return Substring(String(characters[0..<end]))
    }

    /// True when the number (before any extension) holds only digits and formatting characters, so
    /// the digits that get dialed are exactly what the user sees. Vanity numbers ("1-800-FLOWERS")
    /// and annotated numbers ("555-1234 (cell)") are not clean.
    public static func isClean(_ number: String) -> Bool {
        let main = mainPart(of: number)
        return !main.isEmpty && main.allSatisfy { character in
            character.asciiDigit != nil || character.isWhitespace || "+-().\u{2011}\u{2013}/".contains(character)
        }
    }

    /// Number suitable for `tel:` / MessageUI recipients: optional leading "+" then digits.
    /// Nil when it does not contain 3–20 digits.
    public static func dialable(_ number: String) -> String? {
        let digits = digits(in: number)
        guard (minimumDigits...maximumDigits).contains(digits.count) else { return nil }
        let hasPlus = number.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+")
        return (hasPlus ? "+" : "") + digits
    }

    /// Deterministic display form: "555-1212", "(555) 123-4567", "+1 (555) 123-4567", else digits.
    public static func formatted(digits: String, hasPlus: Bool) -> String {
        let chars = Array(digits)
        func group(_ range: Range<Int>) -> String { String(chars[range]) }
        switch (chars.count, hasPlus) {
        case (7, false):
            return "\(group(0..<3))-\(group(3..<7))"
        case (10, false):
            return "(\(group(0..<3))) \(group(3..<6))-\(group(6..<10))"
        case (11, _) where chars.first == "1":
            return "\(hasPlus ? "+" : "")1 (\(group(1..<4))) \(group(4..<7))-\(group(7..<11))"
        default:
            return (hasPlus ? "+" : "") + digits
        }
    }

    /// Last four digits, for telling numbers apart in a question ("ending in 1234").
    public static func lastFour(_ number: String) -> String {
        String(digits(in: number).suffix(4))
    }

    public static func sameNumber(_ lhs: String, _ rhs: String) -> Bool {
        let left = digits(in: lhs)
        return !left.isEmpty && left == digits(in: rhs)
    }
}

extension Character {
    /// The character itself when it is an ASCII digit 0–9.
    var asciiDigit: Character? {
        isASCII && isNumber ? self : nil
    }
}

// MARK: - Dictated numbers

/// A phone number the user dictated, verified to appear in their own words.
public struct DictatedPhoneNumber: Sendable, Equatable {
    public let digits: String
    public let hasPlus: Bool

    public var dialable: String { (hasPlus ? "+" : "") + digits }
    public var displayText: String { PhoneNumbers.formatted(digits: digits, hasPlus: hasPlus) }
}

public enum DictatedNumberCheck: Sendable, Equatable {
    case verified(DictatedPhoneNumber)
    /// Fewer than 3 or more than 20 digits.
    case invalid
    /// The digits do not appear in the transcript: the model may have invented them.
    case notInTranscript
}

public enum DictatedNumberVerifier {
    /// Verifies a model-proposed `phone_number` against the user's transcript.
    ///
    /// The digit sequence must appear inside one contiguous spoken number in the transcript
    /// (numerals and spelled digits such as "five five five one two one two", "oh" = 0, "double
    /// five", "twelve", "eight hundred" are understood). A leading "+" is kept only when the user
    /// said "+" or "plus" right before that number.
    public static func verify(_ proposed: String, transcript: String) -> DictatedNumberCheck {
        let digits = PhoneNumbers.digits(in: proposed)
        guard (PhoneNumbers.minimumDigits...PhoneNumbers.maximumDigits).contains(digits.count) else {
            return .invalid
        }
        let wantsPlus = proposed.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+")
        for run in SpokenNumberScanner.runs(in: transcript) where run.digits.contains(digits) {
            let keepsPlus = wantsPlus && run.hasLeadingPlus && run.digits.hasPrefix(digits)
            return .verified(DictatedPhoneNumber(digits: digits, hasPlus: keepsPlus))
        }
        return .notInTranscript
    }
}

/// Extracts contiguous spoken or written numbers from a transcript.
public enum SpokenNumberScanner {
    public struct Run: Sendable, Equatable {
        public let digits: String
        public let hasLeadingPlus: Bool
    }

    private static let units: [String: String] = [
        "zero": "0", "oh": "0", "o": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "niner": "9",
    ]
    private static let teens: [String: String] = [
        "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
        "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19",
    ]
    private static let tens: [String: String] = [
        "twenty": "2", "thirty": "3", "forty": "4", "fourty": "4", "fifty": "5",
        "sixty": "6", "seventy": "7", "eighty": "8", "ninety": "9",
    ]
    /// Words that may sit inside a spoken number without ending it.
    private static let connectors: Set<String> = ["dash", "hyphen", "dot", "space", "um", "uh", "er", "erm"]

    private enum Token: Equatable {
        case numeral(String)
        case word(String)
        case plus
        case separator
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var numeral = ""
        var word = ""
        func flush() {
            if !numeral.isEmpty { tokens.append(.numeral(numeral)); numeral = "" }
            if !word.isEmpty { tokens.append(.word(word)); word = "" }
        }
        for character in TextTokens.fold(text) {
            if let digit = character.asciiDigit {
                if !word.isEmpty { flush() }
                numeral.append(digit)
            } else if character.isLetter {
                if !numeral.isEmpty { flush() }
                word.append(character)
            } else if character == "'" || character == "\u{2019}" {
                continue
            } else {
                flush()
                if character == "+" {
                    tokens.append(.plus)
                } else if "-.()/,".contains(character) || character.isWhitespace {
                    tokens.append(.separator)
                } else {
                    tokens.append(.word(String(character)))
                }
            }
        }
        flush()
        return tokens
    }

    public static func runs(in transcript: String) -> [Run] {
        let tokens = tokenize(transcript)
        var runs: [Run] = []
        var current = ""
        var currentHasPlus = false
        var plusPending = false
        var multiplier = 1

        func finish() {
            if !current.isEmpty { runs.append(Run(digits: current, hasLeadingPlus: currentHasPlus)) }
            current = ""
            currentHasPlus = false
            multiplier = 1
        }
        func appendDigits(_ digits: String) {
            if current.isEmpty {
                currentHasPlus = plusPending
            }
            plusPending = false
            current += String(repeating: digits, count: multiplier)
            multiplier = 1
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case .separator:
                break
            case .plus:
                finish()
                plusPending = true
            case let .numeral(digits):
                appendDigits(digits)
            case let .word(word):
                if word == "plus" {
                    finish()
                    plusPending = true
                } else if let digit = units[word] {
                    appendDigits(digit)
                } else if let teen = teens[word] {
                    appendDigits(teen)
                } else if let ten = tens[word] {
                    // "twenty one" -> 21, "twenty" -> 20.
                    var lookahead = index + 1
                    while lookahead < tokens.count, tokens[lookahead] == .separator { lookahead += 1 }
                    if lookahead < tokens.count, case let .word(next) = tokens[lookahead],
                       let unit = units[next], next != "o", next != "oh", next != "zero" {
                        appendDigits(ten + unit)
                        index = lookahead
                    } else {
                        appendDigits(ten + "0")
                    }
                } else if word == "hundred", !current.isEmpty {
                    current += "00"
                } else if word == "thousand", !current.isEmpty {
                    current += "000"
                } else if word == "double" {
                    multiplier = 2
                } else if word == "triple" {
                    multiplier = 3
                } else if connectors.contains(word), !current.isEmpty {
                    break
                } else {
                    finish()
                    plusPending = false
                }
            }
            index += 1
        }
        finish()
        return runs
    }
}
