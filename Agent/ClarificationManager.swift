import Core
import Foundation

/// Deterministically interprets the user's answer to a clarification question (PRD §15: native
/// candidate resolution + clarification + confirmation for names that are hard for ASR).
public struct ClarificationManager: Sendable {
    public init() {}

    public enum Interpretation: Equatable, Sendable {
        /// The user picked one of the offered candidates.
        case choose(ClarificationCandidate)
        /// The user cancelled the request.
        case cancel
        /// The answer supplies a missing value for `argument` (message text, a date, a new name…).
        case fill(argument: String, value: String)
        /// Still ambiguous between several candidates (ask again, naming them).
        case stillAmbiguous([ClarificationCandidate])
        /// Not an answer to the question — treat it as a new request for the model.
        case notAnAnswer
    }

    public func interpret(_ answer: String, for clarification: PendingClarification) -> Interpretation {
        let words = ConfirmationClassifier.normalize(answer)
        guard !words.isEmpty else { return .notAnAnswer }
        if isCancel(words) { return .cancel }

        switch clarification.reason {
        case .contactAmbiguous, .phoneNumberAmbiguous, .eventAmbiguous, .fileAmbiguous:
            return choose(words: words, raw: answer, among: clarification.candidates)

        case .contactNotFound:
            guard let call = clarification.partialCall else { return .notAnAnswer }
            let argument = call.string("contact_query") != nil || call.tool != .searchContacts ? "contact_query" : "name"
            return fillIfShort(stripLeading(words, Self.recipientLeadIns), argument: argument, maxWords: 5)

        case .missingField:
            guard let argument = clarification.missingArgument else { return .notAnAnswer }
            if argument == "message" {
                let text = Self.stripMessageLeadIn(answer)
                return text.isEmpty ? .notAnAnswer : .fill(argument: "message", value: text)
            }
            return .notAnAnswer

        case .dateUnclear:
            guard let argument = clarification.missingArgument else { return .notAnAnswer }
            return fillIfShort(words, argument: argument, maxWords: 8)

        case .eventNotFound:
            return fillIfShort(stripLeading(words, ["the", "my"]), argument: "event_query", maxWords: 6)

        case .fileNotFound:
            let argument = clarification.partialCall?.tool == .searchFiles ? "query" : "file_query"
            return fillIfShort(words, argument: argument, maxWords: 8)

        case .phoneNumberNotInTranscript:
            let digits = SpokenDigits.digits(in: answer)
            return (3...20).contains(digits.count) ? .fill(argument: "phone_number", value: digits) : .notAnAnswer

        case .contactHasNoPhone, .modelQuestion:
            return .notAnAnswer
        }
    }

    // MARK: - Candidate selection

    func choose(words: [String], raw: String, among candidates: [ClarificationCandidate]) -> Interpretation {
        guard !candidates.isEmpty else { return .notAnAnswer }
        // "Should I use mobile?" → "yes" picks the only offered candidate.
        if candidates.count == 1, ConfirmationClassifier().classify(raw, pendingTool: nil) == .affirm {
            return .choose(candidates[0])
        }
        if let ordinal = Self.ordinal(in: words, count: candidates.count) {
            return .choose(candidates[ordinal])
        }
        // Phone numbers: "the one ending in 1234" or the last digits spoken.
        let spokenDigits = SpokenDigits.digits(in: raw)
        if spokenDigits.count >= 3 {
            let matches = candidates.filter { $0.kind == .phoneNumber && SpokenDigits.digits(in: $0.identifier).hasSuffix(spokenDigits) }
            if matches.count == 1 { return .choose(matches[0]) }
        }
        // "Monday's" → "monday"; "the one at Acme's" → "acme".
        let meaningful = words.map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 }.filter { !Self.stopWords.contains($0) }
        guard !meaningful.isEmpty else { return .notAnAnswer }
        var scores: [(ClarificationCandidate, Int)] = []
        for candidate in candidates {
            let base = ConfirmationClassifier.normalize(candidate.displayText) + candidate.matchTerms.flatMap { ConfirmationClassifier.normalize($0) }
            let terms = Set(base + base.compactMap { Self.synonyms[$0] })
            let score = meaningful.reduce(0) { total, word in
                let canonical = Self.synonyms[word] ?? word
                if terms.contains(word) || terms.contains(canonical) { return total + 2 }
                if terms.contains(where: { max($0.count, word.count) >= 4 && EditDistance.within1($0, word) }) { return total + 1 }
                return total
            }
            scores.append((candidate, score))
        }
        let best = scores.map(\.1).max() ?? 0
        guard best > 0 else { return .notAnAnswer }
        let top = scores.filter { $0.1 == best }.map(\.0)
        return top.count == 1 ? .choose(top[0]) : .stillAmbiguous(top)
    }

    static func ordinal(in words: [String], count: Int) -> Int? {
        let joined = " " + words.joined(separator: " ") + " "
        let table: [(String, Int)] = [
            ("first", 0), ("1st", 0), ("number one", 0), ("second", 1), ("2nd", 1), ("number two", 1),
            ("third", 2), ("3rd", 2), ("number three", 2), ("fourth", 3), ("4th", 3), ("fifth", 4), ("5th", 4),
        ]
        for (phrase, index) in table where joined.contains(" \(phrase) ") {
            return index < count ? index : nil
        }
        if joined.contains(" last ") || joined.contains(" latter ") { return count - 1 }
        if joined.contains(" former ") { return 0 }
        if words.count <= 3, let only = words.last, let value = ["one": 0, "two": 1, "three": 2, "1": 0, "2": 1, "3": 2][only],
           words.dropLast().allSatisfy({ ["the", "number", "option"].contains($0) }) {
            return value < count ? value : nil
        }
        return nil
    }

    // MARK: - Helpers

    func isCancel(_ words: [String]) -> Bool {
        let phrase = words.joined(separator: " ")
        let cancels: Set<String> = [
            "cancel", "cancel it", "cancel that", "never mind", "forget it", "forget about it", "stop",
            "no", "no thanks", "nothing", "neither", "none", "none of them", "neither of them", "nobody",
            "no one", "abort", "don't", "don't bother", "skip it", "i changed my mind",
        ]
        if cancels.contains(phrase) { return true }
        // "never mind, cancel", "no thanks, forget it": any pure rejection cancels.
        return ConfirmationClassifier().classify(phrase, pendingTool: nil) == .reject
    }

    func fillIfShort(_ words: [String], argument: String, maxWords: Int) -> Interpretation {
        guard !words.isEmpty, words.count <= maxWords else { return .notAnAnswer }
        return .fill(argument: argument, value: words.joined(separator: " "))
    }

    func stripLeading(_ words: [String], _ leadIns: [String]) -> [String] {
        var remaining = words
        var changed = true
        while changed {
            changed = false
            for leadIn in leadIns.sorted(by: { $0.count > $1.count }) {
                let parts = leadIn.split(separator: " ").map(String.init)
                if remaining.count > parts.count, Array(remaining.prefix(parts.count)) == parts {
                    remaining.removeFirst(parts.count)
                    changed = true
                }
            }
        }
        return remaining
    }

    static let recipientLeadIns = ["send it to", "text", "message", "call", "to", "try", "it's", "it is", "i meant", "i mean", "my", "the"]

    /// "say that I'm outside" → "I'm outside". Keeps the user's own words otherwise.
    static func stripMessageLeadIn(_ answer: String) -> String {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadIns = ["tell them that ", "tell him that ", "tell her that ", "say that ", "tell them ", "tell him ", "tell her ", "say ", "that ", "it should say ", "just say "]
        for leadIn in leadIns where text.lowercased().hasPrefix(leadIn) {
            text = String(text.dropFirst(leadIn.count))
            break
        }
        guard let first = text.first else { return "" }
        return first.uppercased() + text.dropFirst()
    }

    static let stopWords: Set<String> = [
        "the", "a", "an", "one", "that", "this", "it", "please", "i", "mean", "meant", "want", "wanted",
        "with", "at", "in", "on", "from", "who", "works", "my", "him", "her", "them", "yes", "yeah", "okay",
        "number", "phone", "person", "contact", "event", "file",
    ]

    /// Phone label synonyms so "cell" picks a "mobile" candidate.
    static let synonyms: [String: String] = [
        "cell": "mobile", "cellphone": "mobile", "iphone": "mobile", "mobile": "mobile",
        "office": "work", "work": "work", "house": "home", "landline": "home",
    ]
}

/// Converts spoken digits in ASR text ("five five five", "oh", "double two") into digit strings.
public enum SpokenDigits {
    static let words: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]
    /// Letters read as zero only inside a run of digits ("five five five oh one").
    static let zeroLetters: Set<String> = ["oh", "o"]

    /// The longest contiguous run of spoken or written digits ("the one ending in two zero zero
    /// two" → "2002"; "call 555 010 4477" → "5550104477"). Pronoun uses of "one" do not join runs
    /// that are separated by other words.
    public static func digits(in text: String) -> String {
        let tokens = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var runs: [String] = []
        var current = ""
        var index = 0
        func closeRun() {
            if !current.isEmpty { runs.append(current) }
            current = ""
        }
        while index < tokens.count {
            let token = tokens[index]
            if token.allSatisfy(\.isNumber) {
                current += token
            } else if token == "double" || token == "triple", index + 1 < tokens.count, let digit = words[tokens[index + 1]] {
                current += String(repeating: digit, count: token == "double" ? 2 : 3)
                index += 1
            } else if let digit = words[token] {
                current += digit
            } else if zeroLetters.contains(token), !current.isEmpty {
                current += "0"
            } else {
                closeRun()
            }
            index += 1
        }
        closeRun()
        // Longest run wins; on a tie the later one (the number usually comes last).
        return runs.enumerated().max { lhs, rhs in
            lhs.element.count == rhs.element.count ? lhs.offset < rhs.offset : lhs.element.count < rhs.element.count
        }?.element ?? ""
    }
}

enum EditDistance {
    /// True when the Damerau-Levenshtein distance between a and b is at most 1.
    static func within1(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return false }
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
        if x.count == y.count {
            if Array(x[(i + 1)...]) == Array(y[(i + 1)...]) { return true } // substitution
            if i + 1 < x.count, x[i] == y[i + 1], x[i + 1] == y[i], Array(x[(i + 2)...]) == Array(y[(i + 2)...]) { return true } // transposition
            return false
        }
        let (short, long) = x.count < y.count ? (x, y) : (y, x)
        return Array(short[i...]) == Array(long[(i + 1)...]) // insertion/deletion
    }
}
