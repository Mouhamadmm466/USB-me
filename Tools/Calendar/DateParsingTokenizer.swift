import Foundation

extension DateExpressionParser {
    /// One lexical unit of a normalized phrase.
    enum Token: Equatable, Sendable {
        case word(String)
        /// A run of at most nine digits; `text` keeps leading zeros ("0900") and the digit count.
        case number(Int, text: String)
        /// A number with an ordinal suffix: "25th", "1st".
        case ordinal(Int)
        /// "3:30", "15:00", "09:00". A ":00" seconds field is accepted and dropped.
        case clock(hour: Int, minute: Int, hourText: String)
        /// "1.5", "3.30". The fraction keeps its digits so "3.30" can be read as a clock time.
        case decimal(whole: Int, fraction: String)
        /// "9/25", "9/25/2026", "2026/09/25": digit groups in written order.
        case slashDate([String])
        /// "2026-09-25".
        case isoDate(year: Int, month: Int, day: Int)
        /// Malformed input ("9-25", "3pm-4pm", "1.2.3") that makes the whole phrase fail.
        case invalid
    }

    /// Turns raw text into tokens. Lowercases; treats whitespace and punctuation as separators;
    /// splits letters from digits ("3pm" → 3, pm; "25th" → ordinal 25); reads "9/25", "2026-09-25",
    /// "3:30" and "1.5" as single tokens; joins "a.m." into am, "o'clock" into oclock; drops a
    /// possessive "'s"; and rewrites spelling variants through `Lexicon.aliases`.
    enum Tokenizer {
        static func tokenize(_ phrase: String) -> [Token] {
            assemble(lex(normalize(phrase)))
        }

        private enum Lexeme: Equatable {
            case letters(String)
            case digits(String)
            /// ":", "/", "-" or "." written directly between two digit runs.
            case joiner(Character)
            case invalid
        }

        private static let typographicVariants: [(String, String)] = [
            ("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{02BC}", "'"), ("`", "'"),
            ("\u{2010}", "-"), ("\u{2011}", "-"), ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2212}", "-"),
        ]

        /// Pairs of words that are one word split by punctuation or ASR: "a.m.", "o' clock", "mid-day".
        private static let splitWords: [String: String] = [
            "a m": "am", "p m": "pm", "o clock": "oclock", "mid day": "noon",
        ]

        private static let ordinalSuffixes: Set<String> = ["st", "nd", "rd", "th"]

        private static func normalize(_ phrase: String) -> String {
            typographicVariants.reduce(phrase.lowercased()) { text, variant in
                text.replacingOccurrences(of: variant.0, with: variant.1)
            }
        }

        private static func isDigit(_ character: Character) -> Bool {
            character.isASCII && character.isNumber
        }

        private static func lex(_ text: String) -> [Lexeme] {
            let characters = Array(text)
            var lexemes: [Lexeme] = []
            var i = 0
            while i < characters.count {
                let character = characters[i]
                if isDigit(character) {
                    var digits = ""
                    while i < characters.count, isDigit(characters[i]) {
                        digits.append(characters[i])
                        i += 1
                    }
                    lexemes.append(.digits(digits))
                    if i + 1 < characters.count, ":/-.".contains(characters[i]), isDigit(characters[i + 1]) {
                        lexemes.append(.joiner(characters[i]))
                        i += 1
                    }
                } else if character.isLetter {
                    var letters = ""
                    while i < characters.count {
                        let current = characters[i]
                        if current.isLetter {
                            letters.append(current)
                            i += 1
                        } else if current == "'", i + 1 < characters.count, characters[i + 1].isLetter {
                            // "friday's" → friday (possessive dropped); "o'clock" → oclock.
                            let possessive = characters[i + 1] == "s"
                                && (i + 2 == characters.count || !characters[i + 2].isLetter)
                            i += possessive ? 2 : 1
                            if possessive { break }
                        } else {
                            break
                        }
                    }
                    lexemes.append(.letters(letters))
                } else if character == "-", i + 1 < characters.count, isDigit(characters[i + 1]) {
                    // A dash before a number but not between two numbers: "-30", "3pm-4pm".
                    lexemes.append(.invalid)
                    i += 1
                } else {
                    switch character {
                    case "&": lexemes.append(.letters("and"))
                    case "@": lexemes.append(.letters("at"))
                    default: break // whitespace and other punctuation only separate tokens
                    }
                    i += 1
                }
            }
            return lexemes
        }

        private static func assemble(_ lexemes: [Lexeme]) -> [Token] {
            var tokens: [Token] = []
            var i = 0
            while i < lexemes.count {
                switch lexemes[i] {
                case .digits:
                    let (token, next) = numericToken(lexemes, from: i)
                    tokens.append(token)
                    i = next
                    // ISO 8601 "2026-09-25T15:00": the "t" only separates the date from the time.
                    if case .isoDate = token, i + 1 < lexemes.count, lexemes[i] == .letters("t"),
                       case .digits = lexemes[i + 1] {
                        i += 1
                    }
                case .letters(let letters):
                    if i + 1 < lexemes.count, case .letters(let following) = lexemes[i + 1],
                       let joined = splitWords[letters + " " + following] {
                        tokens.append(.word(joined))
                        i += 2
                    } else {
                        tokens.append(.word(Lexicon.aliases[letters] ?? letters))
                        i += 1
                    }
                case .joiner, .invalid:
                    tokens.append(.invalid)
                    i += 1
                }
            }
            return tokens
        }

        /// Reads digit groups joined by a single kind of separator ("9/25/2026", "3:30", "1.5"),
        /// or one number with an optional ordinal suffix ("25th").
        private static func numericToken(_ lexemes: [Lexeme], from start: Int) -> (Token, next: Int) {
            var groups: [String] = []
            var separators: Set<Character> = []
            var i = start
            while i < lexemes.count, case .digits(let digits) = lexemes[i] {
                groups.append(digits)
                i += 1
                guard i + 1 < lexemes.count, case .joiner(let separator) = lexemes[i] else { break }
                separators.insert(separator)
                i += 1
            }
            guard !groups.isEmpty, separators.count <= 1, groups.allSatisfy({ $0.count <= 9 }) else {
                return (.invalid, max(i, start + 1))
            }
            let values = groups.map { Int($0) ?? 0 }
            switch separators.first {
            case nil:
                if i < lexemes.count, case .letters(let suffix) = lexemes[i], ordinalSuffixes.contains(suffix) {
                    return (.ordinal(values[0]), i + 1)
                }
                return (.number(values[0], text: groups[0]), i)
            case ":"?:
                let seconds = groups.count == 3 ? groups[2] : "00"
                guard groups.count <= 3, groups[0].count <= 2, groups[1].count == 2, seconds == "00" else {
                    return (.invalid, i)
                }
                return (.clock(hour: values[0], minute: values[1], hourText: groups[0]), i)
            case "/"?:
                return (groups.count <= 3 ? .slashDate(groups) : .invalid, i)
            case "-"?:
                guard groups.count == 3, groups[0].count == 4, groups[1].count <= 2, groups[2].count <= 2 else {
                    return (.invalid, i)
                }
                return (.isoDate(year: values[0], month: values[1], day: values[2]), i)
            default: // "."
                guard groups.count == 2 else { return (.invalid, i) }
                return (.decimal(whole: values[0], fraction: groups[1]), i)
            }
        }
    }

    /// Bounds-safe access to a phrase's tokens: reading before the start or past the end yields nil.
    struct Tokens {
        let all: [Token]

        init(_ phrase: String) {
            all = Tokenizer.tokenize(phrase)
        }

        var count: Int { all.count }

        subscript(_ index: Int) -> Token? {
            all.indices.contains(index) ? all[index] : nil
        }

        func word(_ index: Int) -> String? {
            guard case .word(let word)? = self[index] else { return nil }
            return word
        }

        func isWord(_ word: String, _ index: Int) -> Bool {
            self.word(index) == word
        }

        func isWord(in words: Set<String>, _ index: Int) -> Bool {
            guard let word = self.word(index) else { return false }
            return words.contains(word)
        }
    }

    /// What a grammar rule read and the index of the first token after it.
    struct Match<Value> {
        let value: Value
        let next: Int
    }
}
