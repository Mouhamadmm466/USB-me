import Foundation

/// Text similarity used to tell the assistant's own echo from a user who talks over it.
///
/// Normalisation makes an ASR transcript and the assistant's TTS text comparable: lower-case,
/// apostrophes dropped ("what's" = "whats"), other punctuation and hyphens split words, digits,
/// times and ordinals spelled out ("9:30" → "nine thirty", "21st" → "twenty first"), "a.m."/"p.m."
/// → "am"/"pm".
public enum TranscriptSimilarity {
    /// Normalised word sequence.
    public static func normalizedWords(_ text: String) -> [String] {
        var lowered = text.lowercased()
        for (pattern, replacement) in [("a.m.", " am "), ("p.m.", " pm "), ("%", " percent "), ("&", " and ")] {
            lowered = lowered.replacingOccurrences(of: pattern, with: replacement)
        }
        var words: [String] = []
        var token = ""
        func flush() {
            if !token.isEmpty { words.append(contentsOf: expand(token)) }
            token = ""
        }
        for character in lowered {
            if character.isLetter || character.isNumber || character == ":" {
                token.append(character)
            } else if character == "'" || character == "\u{2019}" {
                continue
            } else {
                flush()
            }
        }
        flush()
        return words
    }

    /// Echo similarity in 0…1: how much of `candidate` is contained in `reference`.
    ///
    /// Mean of two containment ratios (`|C ∩ R| / |C|`, multiset):
    /// - **unigram**: words of the candidate found in the reference; words of four or more
    ///   letters also match at edit distance 1, which absorbs ASR slips on echo ("tree"/"three",
    ///   "event"/"events");
    /// - **bigram**: adjacent word pairs of the candidate (after mapping fuzzy matches onto the
    ///   reference word) found in the reference — an echo is a contiguous stretch of what the
    ///   assistant said, while a user who re-uses its words ("what about the one at five")
    ///   rarely repeats them in the same order.
    /// A one-word candidate uses unigram containment only. Empty candidate → 0.
    public static func echoSimilarity(candidate: String, reference: String) -> Double {
        echoSimilarity(candidateWords: normalizedWords(candidate), referenceWords: normalizedWords(reference))
    }

    public static func echoSimilarity(candidateWords: [String], referenceWords: [String]) -> Double {
        guard !candidateWords.isEmpty, !referenceWords.isEmpty else { return 0 }
        let (matches, canonical) = align(candidateWords, to: referenceWords)
        let unigram = Double(matches) / Double(candidateWords.count)
        guard candidateWords.count >= 2 else { return unigram }
        return (unigram + bigramContainment(canonical, in: referenceWords)) / 2
    }

    /// Fraction of candidate words (multiset, fuzzy) contained in the reference.
    public static func unigramContainment(candidate: String, reference: String) -> Double {
        let words = normalizedWords(candidate)
        guard !words.isEmpty else { return 0 }
        return Double(align(words, to: normalizedWords(reference)).matches) / Double(words.count)
    }

    /// Levenshtein distance, early exit once it exceeds `limit` (returns `limit + 1`).
    public static func editDistance(_ lhs: String, _ rhs: String, limit: Int = .max) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0 ... b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1 ... a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1 ... b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - Internals

    /// Greedy multiset alignment: exact matches first, then fuzzy ones. Returns the number of
    /// matched candidate words and the candidate with fuzzy matches replaced by the reference word.
    static func align(_ candidate: [String], to reference: [String]) -> (matches: Int, canonical: [String]) {
        var available: [String: Int] = [:]
        for word in reference { available[word, default: 0] += 1 }
        var canonical = candidate
        var matched = Array(repeating: false, count: candidate.count)
        var matches = 0
        for (index, word) in candidate.enumerated() where (available[word] ?? 0) > 0 {
            available[word]! -= 1
            matched[index] = true
            matches += 1
        }
        // Fuzzy pass searches the reference in order (dictionary order is randomised per process,
        // and the result must be deterministic).
        for (index, word) in candidate.enumerated() where !matched[index] && word.count >= 4 {
            let match = reference.first { referenceWord in
                referenceWord.count >= 4 && (available[referenceWord] ?? 0) > 0
                    && editDistance(referenceWord, word, limit: 1) <= 1
            }
            if let match {
                available[match, default: 0] -= 1
                canonical[index] = match
                matches += 1
            }
        }
        return (matches, canonical)
    }

    static func bigramContainment(_ candidate: [String], in reference: [String]) -> Double {
        guard candidate.count >= 2 else { return 0 }
        var available: [String: Int] = [:]
        if reference.count >= 2 {
            for index in 0 ..< reference.count - 1 {
                available[reference[index] + " " + reference[index + 1], default: 0] += 1
            }
        }
        var matches = 0
        for index in 0 ..< candidate.count - 1 {
            let pair = candidate[index] + " " + candidate[index + 1]
            if let remaining = available[pair], remaining > 0 {
                available[pair] = remaining - 1
                matches += 1
            }
        }
        return Double(matches) / Double(candidate.count - 1)
    }

    private static let units = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let ordinalUnits = [
        "zeroth", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth",
        "nineteenth",
    ]
    private static let ordinalTens = ["", "", "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth"]

    /// Spells out digit-bearing tokens; plain words pass through.
    static func expand(_ token: String) -> [String] {
        guard token.contains(where: \.isNumber) else {
            return token.split(separator: ":").map(String.init)
        }
        // Clock time "h:mm".
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), parts[1].count == 2, minute < 60 {
            var words = numberWords(hour)
            if minute > 0 {
                if minute < 10 { words.append("oh") }
                words += numberWords(minute)
            }
            return words
        }
        // Ordinals "1st", "22nd", "3rd", "4th".
        for suffix in ["st", "nd", "rd", "th"] where token.hasSuffix(suffix) {
            if let value = Int(token.dropLast(2)), value < 100 {
                return ordinalWords(value)
            }
        }
        // Digit runs mixed with letters ("9am", "4pm"): split and expand each run.
        var words: [String] = []
        var run = ""
        var runIsNumber = false
        func emit() {
            guard !run.isEmpty else { return }
            if runIsNumber {
                words += digitsWords(run)
            } else {
                words += run.split(separator: ":").map(String.init)
            }
            run = ""
        }
        for character in token {
            let isNumber = character.isNumber
            if !run.isEmpty, isNumber != runIsNumber { emit() }
            runIsNumber = isNumber
            run.append(character)
        }
        emit()
        return words
    }

    private static func digitsWords(_ digits: String) -> [String] {
        if digits.count <= 3, let value = Int(digits) { return numberWords(value) }
        // Long numbers (phone numbers, years) read digit by digit.
        return digits.compactMap { $0.wholeNumberValue }.map { units[$0] }
    }

    static func numberWords(_ value: Int) -> [String] {
        switch value {
        case ..<0: return ["minus"] + numberWords(-value)
        case 0 ..< 20: return [units[value]]
        case 20 ..< 100: return [tens[value / 10]] + (value % 10 == 0 ? [] : [units[value % 10]])
        case 100 ..< 1000: return [units[value / 100], "hundred"] + (value % 100 == 0 ? [] : numberWords(value % 100))
        default: return String(value).compactMap { $0.wholeNumberValue }.map { units[$0] }
        }
    }

    static func ordinalWords(_ value: Int) -> [String] {
        switch value {
        case 0 ..< 20: return [ordinalUnits[value]]
        case 20 ..< 100 where value % 10 == 0: return [ordinalTens[value / 10]]
        case 20 ..< 100: return [tens[value / 10], ordinalUnits[value % 10]]
        default: return numberWords(value)
        }
    }
}
