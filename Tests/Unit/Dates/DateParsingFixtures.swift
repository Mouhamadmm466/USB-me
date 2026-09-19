import Core
import Foundation
import Testing
import Tools

/// A fixed "now" for the parser: a local wall-clock time in a named time zone.
struct Now: Sendable, CustomStringConvertible {
    let zone: String
    /// "yyyy-MM-dd'T'HH:mm" in `zone`.
    let local: String
    let label: String

    init(_ zone: String, _ local: String, _ label: String) {
        self.zone = zone
        self.local = local
        self.label = label
    }

    var description: String { label }

    var timeZone: TimeZone { TimeZone(identifier: zone)! }

    var date: Date { LocalTime.date(local, in: timeZone) }

    var clock: AgentClock { .fixed(date, timeZone: timeZone) }

    var parser: DateExpressionParser { DateExpressionParser(clock: clock) }

    /// `date` as "yyyy-MM-dd'T'HH:mm" in this fixture's time zone.
    func local(_ date: Date) -> String { LocalTime.string(date, in: timeZone) }

    /// `date` with its UTC offset, "yyyy-MM-dd'T'HH:mmxxx", to tell repeated DST hours apart.
    func localWithOffset(_ date: Date) -> String { LocalTime.string(date, in: timeZone, format: "yyyy-MM-dd'T'HH:mmxxx") }
}

extension Now {
    static let sep19 = Now("America/New_York", "2026-09-19T10:00", "Sat 2026-09-19 10:00 New York")
    static let sep20 = Now("America/New_York", "2026-09-20T21:00", "Sun 2026-09-20 21:00 New York")
    static let sep21 = Now("America/New_York", "2026-09-21T18:30", "Mon 2026-09-21 18:30 New York")
    static let sep25 = Now("America/New_York", "2026-09-25T10:00", "Fri 2026-09-25 10:00 New York")
    static let dec27 = Now("America/New_York", "2026-12-27T23:10", "Sun 2026-12-27 23:10 New York")
    static let dec31 = Now("America/New_York", "2026-12-31T20:00", "Thu 2026-12-31 20:00 New York")
    static let jan31 = Now("America/New_York", "2026-01-31T09:00", "Sat 2026-01-31 09:00 New York")
    /// US DST starts Sunday 2026-03-08 at 02:00 (clocks jump to 03:00).
    static let mar7 = Now("America/New_York", "2026-03-07T12:00", "Sat 2026-03-07 12:00 New York, eve of DST start")
    /// US DST ends Sunday 2026-11-01 at 02:00 (01:00–01:59 happens twice).
    static let oct31 = Now("America/New_York", "2026-10-31T12:00", "Sat 2026-10-31 12:00 New York, eve of DST end")
    /// UK summer time starts Sunday 2026-03-29 at 01:00 (clocks jump to 02:00).
    static let londonMar28 = Now("Europe/London", "2026-03-28T12:00", "Sat 2026-03-28 12:00 London, eve of BST start")
    /// UK summer time ends Sunday 2026-10-25 at 02:00 (01:00–01:59 happens twice).
    static let londonOct24 = Now("Europe/London", "2026-10-24T12:00", "Sat 2026-10-24 12:00 London, eve of BST end")
    /// Local Sunday morning while UTC is still Saturday.
    static let tokyoSep20 = Now("Asia/Tokyo", "2026-09-20T08:00", "Sun 2026-09-20 08:00 Tokyo")
    static let leapFeb28 = Now("America/New_York", "2028-02-28T09:00", "Mon 2028-02-28 09:00 New York, leap year")
    static let feb28 = Now("America/New_York", "2027-02-28T09:00", "Sun 2027-02-28 09:00 New York, common year")
}

enum LocalTime {
    static func date(_ text: String, in zone: TimeZone) -> Date {
        formatter(zone, "yyyy-MM-dd'T'HH:mm").date(from: text)!
    }

    static func string(_ date: Date, in zone: TimeZone, format: String = "yyyy-MM-dd'T'HH:mm") -> String {
        formatter(zone, format).string(from: date)
    }

    /// "2026-09-25" → "2026-09-25T00:00"; full date-times pass through.
    static func expand(_ text: String) -> String {
        text.contains("T") ? text : text + "T00:00"
    }

    private static func formatter(_ zone: TimeZone, _ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter
    }
}

/// The expected reading of a date/time phrase, compared as one value so a failure shows both sides.
enum Expected: Sendable, Equatable, CustomStringConvertible {
    /// A clock time whose am/pm was explicit or set by a part of day, "yyyy-MM-dd'T'HH:mm".
    case at(String)
    /// A clock time from a bare hour whose am/pm was inferred.
    case inferred(String)
    /// A day without a time, "yyyy-MM-dd" (the parsed instant is that day's local midnight).
    case day(String)

    init(_ parsed: ParsedDateTime, in now: Now) {
        let local = now.local(parsed.date)
        if !parsed.hasTime {
            self = .day(local.hasSuffix("T00:00") ? String(local.prefix(10)) : local)
        } else if parsed.meridiemInferred {
            self = .inferred(local)
        } else {
            self = .at(local)
        }
    }

    var description: String {
        switch self {
        case .at(let local): "at \(local)"
        case .inferred(let local): "at \(local) (am/pm inferred)"
        case .day(let day): "all of \(day)"
        }
    }
}

struct DateTimeCase: Sendable, CustomTestStringConvertible {
    let now: Now
    let phrase: String
    let expected: Expected

    var testDescription: String { "\"\(phrase)\" @ \(now.label) → \(expected)" }
}

struct RangeCase: Sendable, CustomTestStringConvertible {
    let now: Now
    let phrase: String
    /// "yyyy-MM-dd" (midnight) or "yyyy-MM-dd'T'HH:mm".
    let start: String
    let end: String
    let spoken: String

    var testDescription: String { "\"\(phrase)\" @ \(now.label) → \"\(spoken)\"" }
}

struct PhraseCase: Sendable, CustomTestStringConvertible {
    let now: Now
    let phrase: String

    var testDescription: String { "\"\(phrase)\" @ \(now.label)" }
}

extension Now {
    func cases(_ table: KeyValuePairs<String, Expected>) -> [DateTimeCase] {
        table.map { DateTimeCase(now: self, phrase: $0.key, expected: $0.value) }
    }

    func ranges(_ rows: [(phrase: String, start: String, end: String, spoken: String)]) -> [RangeCase] {
        rows.map { RangeCase(now: self, phrase: $0.phrase, start: $0.start, end: $0.end, spoken: $0.spoken) }
    }

    func phrases(_ phrases: [String]) -> [PhraseCase] {
        phrases.map { PhraseCase(now: self, phrase: $0) }
    }
}
