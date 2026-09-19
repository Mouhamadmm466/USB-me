import Core
import Foundation

/// The date/time/duration parsing the resolver needs. `DateExpressionParser` is the production
/// conformance; tests and the harness can inject a scripted parser.
public protocol DateParsing: Sendable {
    /// A single instant; `hasTime == false` when the phrase named only a day.
    func parseDateTime(_ phrase: String) -> ParsedDateTime?
    /// A half-open local range [start, end) for a day or range phrase.
    func parseRange(_ phrase: String) -> DateRange?
    /// A duration phrase in minutes.
    func parseDurationMinutes(_ phrase: String) -> Int?
}

extension DateExpressionParser: DateParsing {}

/// Builds the parser for one resolution, anchored to that turn's clock.
public typealias DateParserFactory = @Sendable (AgentClock) -> any DateParsing

public enum DateParsers {
    /// The production parser.
    public static let standard: DateParserFactory = { clock in DateExpressionParser(clock: clock) }
}

/// Classifies date phrases the model copied from the user's words.
///
/// Used to decide whether a phrase named only a clock time ("at 4", "3:30 pm", "noon"), so the
/// resolver can keep the relevant day (the event's date for `new_start`, the start's date for an
/// end time) instead of whatever day the parser anchored a bare time to.
public enum DatePhraseClassifier {
    private static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon", "tue", "tues", "wed", "weds", "thu", "thur", "thurs", "fri", "sat", "sun",
        "mondays", "tuesdays", "wednesdays", "thursdays", "fridays", "saturdays", "sundays",
    ]
    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep",
        "sept", "oct", "nov", "dec",
    ]
    private static let dayWords: Set<String> = [
        "today", "tonight", "tonite", "tomorrow", "tmrw", "tomorow", "yesterday", "weekend", "week", "weeks",
        "month", "months", "year", "years", "day", "days", "fortnight", "next", "last", "this", "coming",
        "following", "christmas", "thanksgiving", "easter", "halloween", "eve",
    ]
    private static let relativeWords: Set<String> = [
        "in", "hour", "hours", "hr", "hrs", "minute", "minutes", "min", "mins", "later", "ago", "from", "now",
        "after", "before", "earlier", "sooner", "second", "seconds",
    ]
    private static let timeWords: Set<String> = [
        "am", "pm", "a", "p", "m", "oclock", "noon", "midnight", "morning", "afternoon", "evening", "night",
        "half", "quarter", "past", "till", "til", "to", "at", "one", "two", "three", "four", "five", "six",
        "seven", "eight", "nine", "ten", "eleven", "twelve", "fifteen", "thirty", "forty", "fortyfive", "fifty",
        "twenty", "oh", "the", "around", "about", "by", "until", "ish", "o", "clock", "and", "sharp",
    ]

    /// True when the phrase names a clock time and nothing that anchors a day ("4pm", "at 3:30",
    /// "noon"). Relative phrases ("in 2 hours") and anything with a day word are not time-only.
    public static func isTimeOnly(_ phrase: String) -> Bool {
        let raw = TextTokens.fold(phrase)
        // Numeric dates: "9/21", "2026-09-21", "21.09".
        if raw.range(of: #"\d+\s*[/\-.]\s*\d+"#, options: .regularExpression) != nil,
           raw.range(of: #"\d{1,2}[:.]\d{2}\s*(a|p)?"#, options: .regularExpression) == nil {
            return false
        }
        // "9 in the morning" / "8 at night" name a time of day, not a relative offset. ("this
        // morning" still anchors today: "this" is a day word below.)
        let normalized = raw
            .replacingOccurrences(of: "o'clock", with: "oclock")
            .replacingOccurrences(of: "o\u{2019}clock", with: "oclock")
            .replacingOccurrences(
                of: #"\b(in the|at)\s+(morning|afternoon|evening|night)\b"#,
                with: "$2",
                options: .regularExpression
            )
        let tokens = TextTokens.words(normalized)
        guard !tokens.isEmpty else { return false }
        var sawTime = false
        for token in tokens {
            if weekdays.contains(token) || months.contains(token) || dayWords.contains(token) { return false }
            if relativeWords.contains(token) { return false }
            if token.range(of: #"^\d+(st|nd|rd|th)$"#, options: .regularExpression) != nil { return false }
            if token.allSatisfy(\.isNumber) {
                // A four-digit number is a year unless it looks like a 24-hour time ("1530").
                if token.count == 4, let value = Int(token), !(value % 100 < 60 && value / 100 < 24) { return false }
                if token.count > 4 { return false }
                sawTime = true
                continue
            }
            if token.range(of: #"^\d{1,2}(am|pm|a|p)$"#, options: .regularExpression) != nil {
                sawTime = true
                continue
            }
            if timeWords.contains(token) {
                if !["the", "at", "by", "around", "about", "until", "and", "to"].contains(token) { sawTime = true }
                continue
            }
            // Unknown word: be conservative and let the parser's date stand.
            return false
        }
        return sawTime
    }
}
