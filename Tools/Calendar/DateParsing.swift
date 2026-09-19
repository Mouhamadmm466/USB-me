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
    /// True when the phrase fixes a clock time and/or part of day but names no day ("4pm",
    /// "at 3:30", "midday", "in the morning"). The resolver then keeps the relevant day (the
    /// event's date for `new_start`, the start's date for an end time) instead of whichever day
    /// the parser anchored the bare time to. Relative moments ("in 2 hours") are not time-only.
    func isTimeOfDayOnly(_ phrase: String) -> Bool
}

extension DateExpressionParser: DateParsing {
    /// Read from the parser's own interpretation of the phrase, so "names a day?" can never
    /// disagree with how `parseDateTime` understood it.
    public func isTimeOfDayOnly(_ phrase: String) -> Bool {
        if case .timeOfDay? = Interpretation(phrase) { return true }
        return false
    }
}

/// Builds the parser for one resolution, anchored to that turn's clock.
public typealias DateParserFactory = @Sendable (AgentClock) -> any DateParsing

public enum DateParsers {
    /// The production parser.
    public static let standard: DateParserFactory = { clock in DateExpressionParser(clock: clock) }
}
