import Core
import Foundation

/// A point in time parsed from a spoken phrase.
public struct ParsedDateTime: Sendable, Equatable {
    public let date: Date
    /// False when the phrase named only a day ("tomorrow", "next friday"): callers decide the time
    /// (all-day event, date-only reminder) or ask.
    public let hasTime: Bool
    /// True when an hour without am/pm was disambiguated heuristically ("at 3" -> 3 PM).
    public let meridiemInferred: Bool

    public init(date: Date, hasTime: Bool, meridiemInferred: Bool) {
        self.date = date
        self.hasTime = hasTime
        self.meridiemInferred = meridiemInferred
    }
}

/// Deterministic English date/time/duration parser used for tool arguments.
///
/// The model copies date phrases from the user's words ("tomorrow at 3pm", "next friday");
/// Swift — not the model — does the calendar arithmetic, relative to an injected clock and
/// time zone, so results are reproducible and testable.
///
/// Implemented in full by the date-parsing work package; see Tests/Unit/Dates.
public struct DateExpressionParser: Sendable {
    public let clock: AgentClock

    public init(clock: AgentClock) {
        self.clock = clock
    }

    /// Parses a date and/or time phrase into a single instant in the clock's time zone.
    /// Returns nil when the phrase cannot be interpreted unambiguously enough to act on.
    public func parseDateTime(_ phrase: String) -> ParsedDateTime? {
        nil
    }

    /// Parses a day or range phrase ("today", "this week", "next monday", "this weekend") into
    /// a half-open local range [start, end).
    public func parseRange(_ phrase: String) -> DateRange? {
        nil
    }

    /// Parses a duration phrase ("30 minutes", "an hour and a half", "90 min") into minutes.
    public func parseDurationMinutes(_ phrase: String) -> Int? {
        nil
    }
}
