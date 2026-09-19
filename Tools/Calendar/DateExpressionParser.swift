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
/// Pipeline: `Tokenizer` (normalizes ASR spellings) → `Grammar` (reads components such as a day,
/// a clock time or a part of day, in any order, between filler words) → `Interpretation` (checks
/// the components combine without contradiction) → `Resolver` (Gregorian calendar arithmetic in
/// the clock's time zone). A phrase with any word the grammar does not understand returns nil.
///
/// Rules, relative to the clock's "now" (weeks run Monday–Sunday):
/// - "friday", "on friday", "this coming friday": the next Friday strictly after today.
///   "this friday" is today when today is Friday. "next friday" is that date moved one week
///   later when it falls in the current week; "friday next week" is the Friday of next week.
/// - "the 25th": this month unless already past, else the next month that has a 25th.
///   "september 25" and "9/25": this year unless already past (February 29 waits for a leap
///   year). "9/25" is month/day; "25/9" is accepted because 25 cannot be a month.
/// - A bare hour is read 1–7 → PM, 8–11 → AM, 12 → noon (`meridiemInferred`); a part of day
///   decides instead ("7 in the morning", "8 tonight"). "midnight" is the end of the day it is
///   attached to ("friday at midnight" → Saturday 00:00), whereas "12am" is that day's 00:00.
/// - A named day is taken literally even when already past ("today at 9am" said at 10:00,
///   "this morning"); only past-only phrases ("yesterday", "last friday") are refused, and only
///   by `parseDateTime`.
/// - Morning, afternoon, evening and night alone mean 09:00, 15:00, 18:00 and 20:00.
/// - A time with no day ("3pm", "at noon", "in the morning") is today if still ahead, else tomorrow.
/// - "in 20 minutes" / "an hour from now" add elapsed time to the current minute; "in 3 days",
///   "in a week" add calendar days and name a day only (`hasTime == false`) unless a time is given.
/// - Date-only results are the start of that local day.
/// - Times skipped by a DST jump move forward by the jump (2:30 → 3:30); repeated times resolve
///   to their first occurrence.
public struct DateExpressionParser: Sendable {
    public let clock: AgentClock

    public init(clock: AgentClock) {
        self.clock = clock
    }

    /// Parses a date and/or time phrase into a single instant in the clock's time zone.
    /// Returns nil when the phrase cannot be interpreted unambiguously enough to act on:
    /// vague ("later", "soon"), contradictory ("tomorrow yesterday", "this morning at 3pm"),
    /// past-only ("yesterday", "last friday") or not a single moment ("next week", "this weekend").
    public func parseDateTime(_ phrase: String) -> ParsedDateTime? {
        guard let interpretation = Interpretation(phrase) else { return nil }
        return Resolver(clock: clock).dateTime(for: interpretation)
    }

    /// Parses a day or range phrase ("today", "this week", "next monday", "this weekend") into
    /// a half-open local range [start, end).
    ///
    /// Days cover 00:00–24:00; parts of day are morning 06–12, afternoon 12–17, evening 17–21 and
    /// tonight/night 17–24. A phrase naming a clock time ("tomorrow at 3pm") yields the whole day
    /// that contains it. Relative moments ("in 20 minutes", "now") are not ranges and return nil.
    public func parseRange(_ phrase: String) -> DateRange? {
        guard let interpretation = Interpretation(phrase) else { return nil }
        return Resolver(clock: clock).range(for: interpretation)
    }

    /// Parses a duration phrase ("30 minutes", "an hour and a half", "90 min") into minutes.
    /// A bare one- or two-digit number is minutes ("30"); forms that read as clock times ("930",
    /// "15:00") are not durations. Returns nil outside 1...1440 minutes.
    public func parseDurationMinutes(_ phrase: String) -> Int? {
        NumberReader.durationMinutes(in: phrase)
    }
}
