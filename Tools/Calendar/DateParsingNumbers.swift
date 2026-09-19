import Foundation

extension DateExpressionParser {
    /// Units a duration or a relative offset is counted in, smallest first.
    enum DurationUnit: Int, Comparable, Sendable {
        case minute, hour, day, week, month

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Length in minutes; nil for months, whose length depends on the calendar.
        var minutes: Double? {
            switch self {
            case .minute: 1
            case .hour: 60
            case .day: 1_440
            case .week: 10_080
            case .month: nil
            }
        }
    }

    /// One amount-and-unit part of a duration: "1.5 hours", "an hour and a half", "30 minutes".
    struct DurationTerm: Equatable, Sendable {
        let amount: Double
        let unit: DurationUnit
    }

    /// A spoken length of time made of terms in strictly decreasing units ("1 hour 30 minutes").
    struct SpokenDuration: Equatable, Sendable {
        let terms: [DurationTerm]

        /// Total length in minutes; nil when a term is in months.
        var totalMinutes: Double? {
            var total = 0.0
            for term in terms {
                guard let unitMinutes = term.unit.minutes else { return nil }
                total += term.amount * unitMinutes
            }
            return total
        }

        /// Only minutes and hours: elapsed time rather than a count of calendar days.
        var isClockDuration: Bool { terms.allSatisfy { $0.unit <= .hour } }
    }

    /// Reads numbers written as digits or English words, counts ("a couple of"), and durations.
    struct NumberReader {
        let tokens: Tokens

        // MARK: Numbers

        /// "25", "twenty five", "forty-five" (the tokenizer splits hyphens), "nine".
        func cardinal(at i: Int) -> Match<Int>? {
            if case .number(let value, _)? = tokens[i] { return Match(value: value, next: i + 1) }
            return cardinalWords(at: i)
        }

        /// Zero to ninety-nine in words.
        func cardinalWords(at i: Int) -> Match<Int>? {
            guard let word = tokens.word(i) else { return nil }
            if let value = Lexicon.cardinalUnits[word] ?? Lexicon.cardinalTeens[word] {
                return Match(value: value, next: i + 1)
            }
            guard let tens = Lexicon.cardinalTens[word] else { return nil }
            if let unit = tokens.word(i + 1).flatMap({ Lexicon.cardinalUnits[$0] }), unit > 0 {
                return Match(value: tens + unit, next: i + 2)
            }
            return Match(value: tens, next: i + 1)
        }

        /// "fifth", "twenty fifth", "thirtieth". (Digit ordinals such as "25th" are `.ordinal` tokens.)
        func ordinalWords(at i: Int) -> Match<Int>? {
            guard let word = tokens.word(i) else { return nil }
            if let value = Lexicon.ordinalWords[word] { return Match(value: value, next: i + 1) }
            guard let tens = Lexicon.cardinalTens[word],
                  let unit = tokens.word(i + 1).flatMap({ Lexicon.ordinalWords[$0] }), (1...9).contains(unit)
            else { return nil }
            return Match(value: tens + unit, next: i + 2)
        }

        /// An hour of the day as one or two digits or in words: "3", "07", "three", "twelve".
        func hour(at i: Int) -> Match<Int>? {
            if case .number(let value, let text)? = tokens[i] {
                return text.count <= 2 ? Match(value: value, next: i + 1) : nil
            }
            guard let words = cardinalWords(at: i), (1...12).contains(words.value) else { return nil }
            return words
        }

        /// A count: "3", "1.5", "two", "a"/"an" (one), "a couple (of)" (two). Vague counts such as
        /// "a few" or "several" are deliberately not numbers.
        func quantity(at i: Int) -> Match<Double>? {
            switch tokens[i] {
            case .number(let value, _)?:
                return Match(value: Double(value), next: i + 1)
            case .decimal(let whole, let fraction)?:
                return Double("\(whole).\(fraction)").map { Match(value: $0, next: i + 1) }
            case .word("a")?, .word("an")?:
                return tokens.isWord("couple", i + 1) ? couple(at: i + 1) : Match(value: 1, next: i + 1)
            case .word("couple")?:
                return couple(at: i)
            default:
                return cardinalWords(at: i).map { Match(value: Double($0.value), next: $0.next) }
            }
        }

        private func couple(at i: Int) -> Match<Double> {
            Match(value: 2, next: tokens.isWord("of", i + 1) ? i + 2 : i + 1)
        }

        // MARK: Durations

        func unit(at i: Int) -> Match<DurationUnit>? {
            let unit: DurationUnit
            switch tokens.word(i) {
            case "minute"?, "minutes"?, "m"?: unit = .minute
            case "hour"?, "hours"?, "h"?: unit = .hour
            case "day"?, "days"?: unit = .day
            case "week"?, "weeks"?: unit = .week
            case "month"?, "months"?: unit = .month
            default: return nil
            }
            return Match(value: unit, next: i + 1)
        }

        /// One or more terms in strictly decreasing units, optionally joined by "and":
        /// "1 hour 30 minutes", "an hour and 15 minutes", and "1h30" (bare minutes after hours).
        func duration(at start: Int) -> Match<SpokenDuration>? {
            guard let first = term(at: start) else { return nil }
            var terms = [first.value]
            var i = first.next
            while true {
                let smallest = terms[terms.count - 1].unit
                let j = tokens.isWord("and", i) ? i + 1 : i
                if let next = term(at: j) {
                    guard next.value.unit < smallest else { return nil } // "2 hours 3 hours"
                    terms.append(next.value)
                    i = next.next
                } else if j == i, smallest == .hour, case .number(let minutes, let text)? = tokens[i],
                          text.count <= 2, (1...59).contains(minutes) {
                    terms.append(DurationTerm(amount: Double(minutes), unit: .minute))
                    i += 1
                    break
                } else {
                    break
                }
            }
            return Match(value: SpokenDuration(terms: terms), next: i)
        }

        /// "30 minutes", "1.5 hours", "two and a half hours", "an hour and a half",
        /// "half an hour", "a quarter of an hour", "three quarters of an hour".
        private func term(at i: Int) -> Match<DurationTerm>? {
            if let half = halfUnit(at: i) { return half }
            if let quarters = quartersOfAnHour(at: i) { return quarters }
            guard let count = quantity(at: i) else { return nil }
            var amount = count.value
            var j = count.next
            let fractionBeforeUnit = andAFraction(at: j) // "two and a half hours"
            if let fractionBeforeUnit {
                amount += fractionBeforeUnit.value
                j = fractionBeforeUnit.next
            }
            guard let unit = unit(at: j) else { return nil }
            j = unit.next
            if fractionBeforeUnit == nil, let fraction = andAFraction(at: j) { // "an hour and a half"
                amount += fraction.value
                j = fraction.next
            }
            return Match(value: DurationTerm(amount: amount, unit: unit.value), next: j)
        }

        /// "half an hour", "half hour", "a half hour", "half a day".
        private func halfUnit(at i: Int) -> Match<DurationTerm>? {
            var j = i
            if tokens.isWord("a", j), tokens.isWord("half", j + 1) { j += 1 }
            guard tokens.isWord("half", j) else { return nil }
            j += 1
            if tokens.isWord(in: ["a", "an"], j) { j += 1 }
            guard let unit = unit(at: j) else { return nil }
            return Match(value: DurationTerm(amount: 0.5, unit: unit.value), next: unit.next)
        }

        /// "a quarter of an hour", "quarter hour", "three quarters of an hour".
        private func quartersOfAnHour(at i: Int) -> Match<DurationTerm>? {
            var j = i
            var quarters = 1.0
            if tokens.isWord("a", j), tokens.isWord("quarter", j + 1) {
                j += 1
            } else if !tokens.isWord("quarter", j), let count = quantity(at: j), tokens.isWord("quarters", count.next) {
                quarters = count.value
                j = count.next
            }
            guard tokens.isWord(in: ["quarter", "quarters"], j) else { return nil }
            j += 1
            if tokens.isWord("of", j) { j += 1 }
            if tokens.isWord(in: ["a", "an"], j) { j += 1 }
            guard let unit = unit(at: j), unit.value == .hour else { return nil }
            return Match(value: DurationTerm(amount: quarters / 4, unit: .hour), next: unit.next)
        }

        /// "and a half" (0.5) or "and a quarter" (0.25).
        private func andAFraction(at i: Int) -> Match<Double>? {
            guard tokens.isWord("and", i), tokens.isWord("a", i + 1) else { return nil }
            switch tokens.word(i + 2) {
            case "half"?: return Match(value: 0.5, next: i + 3)
            case "quarter"?: return Match(value: 0.25, next: i + 3)
            default: return nil
            }
        }

        // MARK: Duration phrases

        /// The whole phrase as a duration: "30 minutes", "an hour and a half", "1h30", "1:30",
        /// or a bare number of minutes ("30", "forty five"). Leading "for"/"about" are ignored.
        /// Fractional totals round to the nearest minute; nil outside 1...1440 minutes.
        ///
        /// Forms that read as clock times are not durations: a bare number of three or more digits
        /// ("930" — the planner falls back to this parser for end phrases such as "until 930") and
        /// h:mm with a two-digit hour ("15:00").
        static func durationMinutes(in phrase: String) -> Int? {
            guard phrase.count <= Limits.maxPhraseLength else { return nil }
            let tokens = Tokens(phrase)
            let reader = NumberReader(tokens: tokens)
            var start = 0
            while tokens.isWord(in: ["for", "about"], start) { start += 1 }
            let minutes: Double
            if case .clock(let hours, let mins, let hourText)? = tokens[start], start + 1 == tokens.count {
                guard hourText.count == 1, mins < 60 else { return nil }
                minutes = Double(hours * 60 + mins) // "1:30"
            } else if case .number(_, let text)? = tokens[start], start + 1 == tokens.count {
                guard text.count <= 2, let count = reader.cardinal(at: start) else { return nil }
                minutes = Double(count.value) // "30"
            } else if let count = reader.cardinalWords(at: start), count.next == tokens.count {
                minutes = Double(count.value) // "forty five"
            } else if let duration = reader.duration(at: start), duration.next == tokens.count,
                      let total = duration.value.totalMinutes {
                minutes = total
            } else {
                return nil
            }
            guard minutes.isFinite, minutes >= 0.5, minutes <= 1_440 else { return nil }
            return Int(minutes.rounded())
        }
    }

    /// Bounds that keep arithmetic on user-supplied numbers sane.
    enum Limits {
        /// Longer input is not a date phrase copied from speech.
        static let maxPhraseLength = 200
        /// "in N minutes/hours" beyond a year is treated as a misparse.
        static let maxElapsedMinutes = 366.0 * 1_440
        /// "in N days/weeks/months" beyond this many units is treated as a misparse.
        static let maxRelativeUnits = 1_000.0
        /// "the next N days" beyond a year is not a calendar query.
        static let maxUpcomingDays = 366
    }
}
