import Core
import Foundation

/// Local wall-clock strings used by cases and fixtures.
///
/// * date-time: `"YYYY-MM-DDTHH:MM"` (fixtures, expectations) or `"YYYY-MM-DDTHH:MM:SS"` (case `now`)
/// * date:      `"YYYY-MM-DD"` (date-only reminders, whole-day expectations)
///
/// All values are interpreted in the case's IANA time zone. Comparisons are done by rendering the
/// observed `Date` back into local components, which is exact across DST transitions (a repeated
/// local hour such as 01:30 on a fall-back night matches either occurrence).
public enum EvalTime {
    public enum Precision: String, Sendable, Codable {
        /// `"YYYY-MM-DD"`
        case day
        /// `"YYYY-MM-DDTHH:MM"` (seconds, when present, must be zero for expectations)
        case minute
    }

    /// A parsed local wall-clock value.
    public struct LocalValue: Sendable, Equatable {
        public let year: Int
        public let month: Int
        public let day: Int
        public let hour: Int
        public let minute: Int
        public let second: Int
        public let precision: Precision
    }

    /// Parses `"YYYY-MM-DD"`, `"YYYY-MM-DDTHH:MM"` or `"YYYY-MM-DDTHH:MM:SS"`; nil when malformed
    /// or not a real calendar date/time (e.g. February 30th, 24:10).
    public static func parse(_ string: String) -> LocalValue? {
        let parts = string.split(separator: "T", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let dateFields = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard dateFields.count == 3,
              dateFields[0].count == 4, dateFields[1].count == 2, dateFields[2].count == 2,
              let year = Int(dateFields[0]), let month = Int(dateFields[1]), let day = Int(dateFields[2]),
              dateFields.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return nil }
        var hour = 0, minute = 0, second = 0
        var precision = Precision.day
        if parts.count == 2 {
            let timeFields = parts[1].split(separator: ":", omittingEmptySubsequences: false)
            guard timeFields.count == 2 || timeFields.count == 3,
                  timeFields.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                  let h = Int(timeFields[0]), let m = Int(timeFields[1])
            else { return nil }
            hour = h
            minute = m
            second = timeFields.count == 3 ? Int(timeFields[2]) ?? -1 : 0
            precision = .minute
        }
        guard (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second),
              (1...daysInMonth(year: year, month: month)).contains(day)
        else { return nil }
        return LocalValue(year: year, month: month, day: day, hour: hour, minute: minute, second: second, precision: precision)
    }

    /// `"YYYY-MM-DDTHH:MM"` exactly (the expectation date-time format).
    public static func isDateTime(_ string: String) -> Bool {
        string.count == 16 && parse(string)?.precision == .minute
    }

    /// `"YYYY-MM-DD"` exactly.
    public static func isDate(_ string: String) -> Bool {
        string.count == 10 && parse(string)?.precision == .day
    }

    /// The instant of a local wall-clock string in `timeZone` (date-only values mean local midnight).
    public static func date(fromLocal string: String, in timeZone: TimeZone) -> Date? {
        guard let value = parse(string) else { return nil }
        var components = DateComponents()
        components.year = value.year
        components.month = value.month
        components.day = value.day
        components.hour = value.hour
        components.minute = value.minute
        components.second = value.second
        return calendar(in: timeZone).date(from: components)
    }

    /// `"YYYY-MM-DDTHH:MM"` for `date` in `timeZone` (seconds truncated).
    public static func localMinuteString(_ date: Date, in timeZone: TimeZone) -> String {
        let c = calendar(in: timeZone).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// `"YYYY-MM-DD"` for `date` in `timeZone`.
    public static func localDayString(_ date: Date, in timeZone: TimeZone) -> String {
        let c = calendar(in: timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Renders `date` at the precision of `expected` (day for `"YYYY-MM-DD"`, minute otherwise).
    public static func render(_ date: Date, like expected: String, in timeZone: TimeZone) -> String {
        isDate(expected) ? localDayString(date, in: timeZone) : localMinuteString(date, in: timeZone)
    }

    /// Whether `date` matches the expectation string in `timeZone` at the expectation's precision.
    public static func matches(_ date: Date, expected: String, in timeZone: TimeZone) -> Bool {
        render(date, like: expected, in: timeZone) == expected
    }

    /// Gregorian calendar pinned to `timeZone` and the POSIX locale (as `AgentClock.fixed` uses).
    public static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}

extension EvalCase {
    /// The case's IANA time zone, or nil when the identifier is unknown.
    public var timeZoneValue: TimeZone? { TimeZone(identifier: timezone) }

    /// The case's fixed "now" as an instant, or nil when `now`/`timezone` is malformed.
    public var nowDate: Date? {
        guard let timeZone = timeZoneValue else { return nil }
        return EvalTime.date(fromLocal: now, in: timeZone)
    }

    /// A deterministic clock pinned to the case's "now" and time zone, for the runner.
    public func makeClock() -> AgentClock? {
        guard let timeZone = timeZoneValue, let date = nowDate else { return nil }
        return AgentClock.fixed(date, timeZone: timeZone)
    }

    /// Whether the case is part of the release safety suite (zero false consequential executions).
    public var isReleaseSafety: Bool { tags.contains(EvalTag.releaseSafety) }
}

extension FixtureEvent {
    /// Start instant in the given (case) time zone.
    public func startDate(in timeZone: TimeZone) -> Date? { EvalTime.date(fromLocal: start, in: timeZone) }

    /// End instant in the given (case) time zone.
    public func endDate(in timeZone: TimeZone) -> Date? { EvalTime.date(fromLocal: end, in: timeZone) }
}

/// Well-known tag names used by the dataset and the report.
public enum EvalTag {
    public static let releaseSafety = "release_safety"
}
