import Foundation

/// Guesses the next few characters of a JSON string value by copying from the request text
/// ("prompt lookup" drafting).
///
/// Argument values are mostly the user's own words ("buy milk", "tomorrow at 5pm", "I'll be 20
/// minutes late"). Once the model has started a value, the drafter finds where the value so far
/// occurs in the utterance (or the turn context) and proposes what follows there. The runtime
/// evaluates the guess in the same GPU pass as the current token and keeps only the tokens that
/// match the model's own greedy choice, so a draft can make decoding faster but never changes
/// the output.
///
/// Pure text in, text out: deterministic and unit-testable without a model.
public struct PromptLookupDrafter: Sendable, Equatable {
    /// Searched in order; the first source containing a match wins (put the utterance first).
    public let sources: [String]
    /// Longest suffix of the value so far that is looked up.
    public var maximumKeyCharacters = 24
    /// Shortest suffix looked up when it starts mid-value (e.g. "ll" of "I'll" → "will").
    public var minimumKeyCharacters = 2
    /// Upper bound on the returned continuation (the runtime also caps the token count).
    public var maximumDraftCharacters = 48

    public init(sources: [String]) {
        self.sources = sources.filter { !$0.isEmpty }
    }

    /// The draft continuation for `output` (the model's output so far), or nil when the output is
    /// not inside a string value or nothing in the sources matches.
    ///
    /// The longest suffix of the value that occurs in a source decides. If it only occurs where the
    /// copied span ends (end of the utterance, a closing quote), the value is probably complete and
    /// no draft is returned: shorter keys would only find unrelated text.
    public func continuation(after output: String) -> String? {
        guard !sources.isEmpty, let value = Self.openStringValue(in: output), !value.isEmpty else { return nil }
        let characters = Array(value)
        let longest = min(characters.count, maximumKeyCharacters)
        for length in stride(from: longest, through: 1, by: -1) {
            let start = characters.count - length
            let startsWord = start == 0 || !Self.isWordCharacter(characters[start - 1])
            // A key that starts mid-word ("ll" of "I'll", found in "will") needs two characters;
            // a one-character key only counts as a whole word ("I" → "I'll be …").
            if length < minimumKeyCharacters, !startsWord { continue }
            let key = String(characters[start...])
            var occurs = false
            for source in sources {
                switch lookup(key, in: source, requireWordStart: startsWord) {
                case let .continuation(text): return text
                case .endOfSpan: occurs = true
                case .absent: break
                }
            }
            if occurs { return nil }
        }
        return nil
    }

    private enum Lookup {
        case continuation(String)
        case endOfSpan
        case absent
    }

    private func lookup(_ key: String, in source: String, requireWordStart: Bool) -> Lookup {
        var result = Lookup.absent
        var searchRange = source.startIndex..<source.endIndex
        while let match = source.range(of: key, options: [.caseInsensitive], range: searchRange) {
            searchRange = match.upperBound..<source.endIndex
            if requireWordStart, match.lowerBound > source.startIndex,
               Self.isWordCharacter(source[source.index(before: match.lowerBound)]) {
                continue
            }
            if let text = trimmedContinuation(source[match.upperBound...]) { return .continuation(text) }
            result = .endOfSpan
        }
        return result
    }

    /// Stops where a JSON string would need escaping or the source line ends, and cuts at a word
    /// boundary when truncating so the last drafted token is a whole word.
    private func trimmedContinuation(_ rest: Substring) -> String? {
        var text = ""
        for character in rest {
            if character == "\"" || character == "\\" || character.isNewline { break }
            if let ascii = character.asciiValue, ascii < 0x20 { break }
            text.append(character)
            if text.count >= maximumDraftCharacters { break }
        }
        if text.count >= maximumDraftCharacters, let lastSpace = text.lastIndex(of: " "), lastSpace > text.startIndex {
            text = String(text[..<lastSpace])
        }
        return text.isEmpty ? nil : text
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "\u{2019}"
    }

    /// The raw contents of the JSON string still open at the end of `output`, or nil when the
    /// output is not inside a string or the value so far contains an escape sequence.
    static func openStringValue(in output: String) -> String? {
        var inString = false
        var escaped = false
        var start = output.startIndex
        var sawEscape = false
        var index = output.startIndex
        while index < output.endIndex {
            let character = output[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                    sawEscape = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
                sawEscape = false
                start = output.index(after: index)
            }
            index = output.index(after: index)
        }
        guard inString, !escaped, !sawEscape else { return nil }
        return String(output[start...])
    }
}
