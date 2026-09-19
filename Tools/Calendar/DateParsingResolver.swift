import Core
import Foundation

extension DateExpressionParser {
    /// Where a spoken time lands on the clock of the day it is attached to.
    enum TimeResolution: Equatable, Sendable {
        /// Neither a time nor a part of day was said.
        case unspecified
        /// The time contradicts the part of day ("this morning at 3pm") or is impossible.
        case contradictory
        /// Minutes after the day's start; 1,440 or more lands on a following day
        /// ("friday at midnight", "tonight at 1").
        case resolved(minutes: Int, meridiemInferred: Bool)
    }

    /// Calendar arithmetic for one parse, pinned to a single reading of the injected clock.
    ///
    /// Everything goes through a Gregorian `Calendar` in the clock's time zone: days are added as
    /// calendar days and times are set from date components, never as multiples of 86,400 seconds,
    /// so results stay on the intended local day and clock time across DST changes.
    struct Resolver {
        let calendar: Calendar
        let now: Date
        let today: Date

        init(clock: AgentClock) {
            // Spoken month and weekday names are Gregorian whatever calendar the device displays.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = clock.timeZone
            calendar.locale = Locale(identifier: "en_US_POSIX")
            self.calendar = calendar
            now = clock.now()
            today = calendar.startOfDay(for: now)
        }

        // MARK: Results

        func dateTime(for interpretation: Interpretation) -> ParsedDateTime? {
            switch interpretation {
            case .now:
                return ParsedDateTime(date: currentMinute, hasTime: true, meridiemInferred: false)
            case .elapsed(let minutes):
                // Elapsed time, not wall-clock time: "in 2 hours" is two real hours even across a DST change.
                let date = currentMinute.addingTimeInterval(TimeInterval(minutes) * 60)
                return ParsedDateTime(date: date, hasTime: true, meridiemInferred: false)
            case .span:
                return nil // "next week" is not a moment; the caller asks which day.
            case .day(let anchor, let time, let part):
                guard !anchor.isPastOnly, let day = resolve(anchor) else { return nil }
                switch Self.resolve(time, part: part) {
                case .unspecified:
                    return ParsedDateTime(date: day, hasTime: false, meridiemInferred: false)
                case .contradictory:
                    return nil
                case .resolved(let minutes, let inferred):
                    return instant(on: day, minutes: minutes)
                        .map { ParsedDateTime(date: $0, hasTime: true, meridiemInferred: inferred) }
                }
            case .timeOfDay(let time, let part):
                guard case .resolved(let minutes, let inferred) = Self.resolve(time, part: part),
                      let date = nextOccurrence(minuteOfDay: minutes % 1_440) else { return nil }
                return ParsedDateTime(date: date, hasTime: true, meridiemInferred: inferred)
            }
        }

        func range(for interpretation: Interpretation) -> DateRange? {
            switch interpretation {
            case .now, .elapsed:
                return nil
            case .span(let span):
                return range(for: span)
            case .day(let anchor, let time, let part):
                guard let day = resolve(anchor) else { return nil }
                if time != nil {
                    // A moment ("tomorrow at 3pm"): the whole day that contains it.
                    guard case .resolved(let minutes, _) = Self.resolve(time, part: part),
                          let moment = instant(on: day, minutes: minutes) else { return nil }
                    return wholeDay(calendar.startOfDay(for: moment), relativeWords: anchor.isRelativeWord)
                }
                if let part {
                    return window(part, on: day, relativeWords: anchor.isRelativeWord)
                }
                return wholeDay(day, relativeWords: anchor.isRelativeWord)
            case .timeOfDay(let time, let part):
                if time == nil, let part {
                    // "in the morning": today's window unless it is over, then tomorrow's.
                    if let todays = window(part, on: today, relativeWords: true), todays.end > now {
                        return todays
                    }
                    return day(1, after: today).flatMap { window(part, on: $0, relativeWords: true) }
                }
                guard case .resolved(let minutes, _) = Self.resolve(time, part: part),
                      let moment = nextOccurrence(minuteOfDay: minutes % 1_440) else { return nil }
                return wholeDay(calendar.startOfDay(for: moment), relativeWords: true)
            }
        }

        // MARK: Days

        /// Start of the day `days` calendar days after `day`.
        func day(_ days: Int, after day: Date) -> Date? {
            calendar.date(byAdding: .day, value: days, to: day).map { calendar.startOfDay(for: $0) }
        }

        func addingMonths(_ months: Int, to day: Date) -> Date? {
            calendar.date(byAdding: .month, value: months, to: day).map { calendar.startOfDay(for: $0) }
        }

        func ymd(_ date: Date) -> (year: Int, month: Int, day: Int) {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return (parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }

        func weekday(of date: Date) -> Int {
            calendar.component(.weekday, from: date)
        }

        /// 0 for Monday … 6 for Sunday. Weeks run Monday to Sunday whatever the locale says.
        func daysSinceMonday(_ date: Date) -> Int {
            (weekday(of: date) + 5) % 7
        }

        /// Start of a valid Gregorian date; nil for dates such as February 30.
        func startOfDay(year: Int, month: Int, day: Int) -> Date? {
            guard (1...12).contains(month), (1...Self.daysIn(month: month, year: year)).contains(day) else { return nil }
            return calendar.date(from: DateComponents(year: year, month: month, day: day)).map { calendar.startOfDay(for: $0) }
        }

        static func daysIn(month: Int, year: Int) -> Int {
            switch month {
            case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
            case 4, 6, 9, 11: 30
            default: 31
            }
        }

        /// `minutes` after the start of `day` on the local clock (1,440 or more is a later day).
        /// Built from date components: a time skipped by a DST jump moves forward by the jump
        /// (2:30 → 3:30) and a repeated time resolves to its first occurrence.
        func instant(on day: Date, minutes: Int) -> Date? {
            guard minutes >= 0, let target = self.day(minutes / 1_440, after: day) else { return nil }
            let date = ymd(target)
            let minuteOfDay = minutes % 1_440
            return calendar.date(from: DateComponents(
                year: date.year, month: date.month, day: date.day, hour: minuteOfDay / 60, minute: minuteOfDay % 60
            ))
        }

        /// Today at `minuteOfDay` if that is still ahead, otherwise tomorrow at the same clock time.
        func nextOccurrence(minuteOfDay: Int) -> Date? {
            if let todayAt = instant(on: today, minutes: minuteOfDay), todayAt > now { return todayAt }
            return day(1, after: today).flatMap { instant(on: $0, minutes: minuteOfDay) }
        }

        /// Now, truncated to the minute, so relative times land on whole minutes.
        var currentMinute: Date {
            calendar.dateInterval(of: .minute, for: now)?.start ?? now
        }

        // MARK: Anchors

        func resolve(_ anchor: DayAnchor) -> Date? {
            switch anchor {
            case .relative(let days), .offset(let days):
                return day(days, after: today)
            case .monthOffset(let months):
                return addingMonths(months, to: today)
            case .weekday(let weekday, let modifier):
                return day(daysUntil(weekday, modifier), after: today)
            case .weekdayInWeek(let weekday, let weekOffset):
                return day(7 * weekOffset - daysSinceMonday(today) + (weekday + 5) % 7, after: today)
            case .dayOfMonth(let dayOfMonth, let monthOffset):
                let current = ymd(today)
                guard let month = startOfDay(year: current.year, month: current.month, day: 1)
                    .flatMap({ addingMonths(monthOffset, to: $0) }) else { return nil }
                let target = ymd(month)
                return startOfDay(year: target.year, month: target.month, day: dayOfMonth)
            case .date(let date):
                return resolve(date)
            case .confirmed(let anchor, let weekday):
                guard let day = resolve(anchor), self.weekday(of: day) == weekday else { return nil }
                return day
            }
        }

        /// Signed number of days from today to `target` (1 = Sunday … 7 = Saturday) under `modifier`.
        func daysUntil(_ target: Int, _ modifier: WeekdayModifier) -> Int {
            let ahead = (target - weekday(of: today) + 7) % 7 // 0 when today is `target`
            let behind = (weekday(of: today) - target + 7) % 7
            let upcoming = ahead == 0 ? 7 : ahead
            let previous = behind == 0 ? 7 : behind
            let sinceMonday = daysSinceMonday(today)
            switch modifier {
            case .this: return ahead
            case .upcoming: return upcoming
            case .next: return sinceMonday + upcoming <= 6 ? upcoming + 7 : upcoming
            case .previous: return -previous
            case .last: return sinceMonday - previous >= 0 ? -(previous + 7) : -previous
            }
        }

        /// A written date. Without a year, the first year from this one in which the date is today or
        /// later (February 29 waits for a leap year). Without a month ("the 25th"), this month unless
        /// already past, else the next month that has that day.
        func resolve(_ date: CalendarDate) -> Date? {
            let current = ymd(today)
            switch (date.year, date.month) {
            case (let year?, let month?):
                return startOfDay(year: year, month: month, day: date.day)
            case (nil, let month?):
                let firstYear = (month, date.day) < (current.month, current.day) ? current.year + 1 : current.year
                return (firstYear..<firstYear + 8).lazy.compactMap { startOfDay(year: $0, month: month, day: date.day) }.first
            case (_, nil):
                var (year, month) = (current.year, current.month)
                if date.day < current.day { (year, month) = Self.month(after: year, month) }
                for _ in 0..<12 {
                    if let day = startOfDay(year: year, month: month, day: date.day) { return day }
                    (year, month) = Self.month(after: year, month)
                }
                return nil
            }
        }

        static func month(after year: Int, _ month: Int) -> (Int, Int) {
            month == 12 ? (year + 1, 1) : (year, month + 1)
        }

        // MARK: Times

        /// Places a spoken time on a day's clock. A part of day disambiguates a bare hour ("7 in the
        /// morning", "8 tonight") and must agree with an explicit one; otherwise a bare hour is read
        /// 1–7 → PM, 8–11 → AM, 12 → noon and flagged as inferred. A part of day alone gives its
        /// default time.
        static func resolve(_ time: SpokenTime?, part: DayPart?) -> TimeResolution {
            guard let time else {
                guard let part else { return .unspecified }
                return .resolved(minutes: part.defaultHour * 60, meridiemInferred: false)
            }
            var inferred = false
            let hour: Int?
            switch time.anchor {
            case .noon:
                hour = part == nil || part == .afternoon ? 12 : nil
            case .midnight:
                hour = part == nil || part == .night ? 24 : nil
            case .hour(let value, let meridiem?, _):
                hour = place(hour24: value % 12 + (meridiem == .pm ? 12 : 0), in: part)
            case .hour(let value, nil, true):
                hour = place(hour24: value, in: part)
            case .hour(let value, nil, false):
                if let part {
                    hour = part.hour(forBareHour: value)
                } else {
                    hour = DayPart.inferredHour(value)
                    inferred = true
                }
            }
            guard let hour else { return .contradictory }
            let minutes = hour * 60 + time.minuteOffset
            guard minutes >= 0 else { return .contradictory }
            return .resolved(minutes: minutes, meridiemInferred: inferred)
        }

        private static func place(hour24: Int, in part: DayPart?) -> Int? {
            guard let part else { return hour24 }
            return part.hour(forHour24: hour24)
        }

        // MARK: Ranges

        func wholeDay(_ day: Date, relativeWords: Bool) -> DateRange? {
            guard let end = self.day(1, after: day) else { return nil }
            return DateRange(start: day, end: end, spokenDescription: describe(day, part: nil, relativeWords: relativeWords))
        }

        func window(_ part: DayPart, on day: Date, relativeWords: Bool) -> DateRange? {
            let hours = part.window
            guard let start = instant(on: day, minutes: hours.start * 60),
                  let end = instant(on: day, minutes: hours.end * 60) else { return nil }
            return DateRange(start: start, end: end, spokenDescription: describe(day, part: part, relativeWords: relativeWords))
        }

        func range(for span: Span) -> DateRange? {
            let current = ymd(today)
            switch span {
            case .period(let kind, let offset):
                let start: Date?, end: Date?
                switch kind {
                case .week, .weekend:
                    let firstDay = 7 * offset - daysSinceMonday(today) + (kind == .weekend ? 5 : 0)
                    start = day(firstDay, after: today)
                    end = start.flatMap { day(kind == .weekend ? 2 : 7, after: $0) }
                case .month:
                    start = startOfDay(year: current.year, month: current.month, day: 1).flatMap { addingMonths(offset, to: $0) }
                    end = start.flatMap { addingMonths(1, to: $0) }
                }
                guard let start, let end else { return nil }
                return DateRange(start: start, end: end, spokenDescription: Self.periodName(kind, offset: offset))
            case .month(let month, let year):
                let year = year ?? (month < current.month ? current.year + 1 : current.year)
                guard let start = startOfDay(year: year, month: month, day: 1), let end = addingMonths(1, to: start) else {
                    return nil
                }
                let name = Lexicon.monthNames[month - 1]
                return DateRange(start: start, end: end, spokenDescription: year == current.year ? name : "\(name) \(year)")
            case .upcomingDays(let days, let spoken):
                guard let end = day(days, after: today) else { return nil }
                return DateRange(start: today, end: end, spokenDescription: spoken)
            }
        }

        // MARK: Descriptions

        static func periodName(_ kind: PeriodKind, offset: Int) -> String {
            let noun = switch kind {
            case .week: "week"
            case .weekend: "weekend"
            case .month: "month"
            }
            return switch offset {
            case 0: "this \(noun)"
            case 1: "next \(noun)"
            default: "last \(noun)"
            }
        }

        /// "today", "tomorrow morning", "tonight", "last night" when `relativeWords` allows and the
        /// day is yesterday, today or tomorrow; otherwise "Friday, September 25" or
        /// "Friday morning, September 25", with ", 2027" when the year is not the current one.
        func describe(_ day: Date, part: DayPart?, relativeWords: Bool) -> String {
            if relativeWords, let relative = relativeName(day, part: part) { return relative }
            let date = ymd(day)
            let partName = part.map { " \($0.name)" } ?? ""
            var text = "\(Lexicon.weekdayNames[weekday(of: day) - 1])\(partName), \(Lexicon.monthNames[date.month - 1]) \(date.day)"
            if date.year != ymd(today).year { text += ", \(date.year)" }
            return text
        }

        private func relativeName(_ day: Date, part: DayPart?) -> String? {
            if day == today {
                guard let part else { return "today" }
                return part == .night ? "tonight" : "this \(part.name)"
            }
            if day == self.day(1, after: today) {
                return part.map { "tomorrow \($0.name)" } ?? "tomorrow"
            }
            if day == self.day(-1, after: today) {
                guard let part else { return "yesterday" }
                return part == .night ? "last night" : "yesterday \(part.name)"
            }
            return nil
        }
    }
}

extension DateExpressionParser.DayPart {
    var name: String {
        switch self {
        case .morning: "morning"
        case .afternoon: "afternoon"
        case .evening: "evening"
        case .night: "night"
        }
    }

    /// Time used when only the part of day is named ("tomorrow morning" → 09:00).
    var defaultHour: Int {
        switch self {
        case .morning: 9
        case .afternoon: 15
        case .evening: 18
        case .night: 20
        }
    }

    /// Hours covered by a range query ("this afternoon" → 12:00–17:00; "tonight" → 17:00–24:00).
    var window: (start: Int, end: Int) {
        switch self {
        case .morning: (6, 12)
        case .afternoon: (12, 17)
        case .evening: (17, 21)
        case .night: (17, 24)
        }
    }

    /// The hour a bare "1"–"12" means in this part of day ("7 in the morning" → 7, "8 tonight" → 20,
    /// "tonight at 1" → 25, i.e. 1 AM the next day), or nil when that reading is implausible.
    func hour(forBareHour hour: Int) -> Int? {
        switch self {
        case .morning: hour == 12 ? nil : hour
        case .afternoon: hour == 12 ? 12 : (1...7).contains(hour) ? hour + 12 : nil
        case .evening: (4...11).contains(hour) ? hour + 12 : nil
        case .night: hour == 12 ? 24 : hour <= 4 ? hour + 24 : hour + 12
        }
    }

    /// Checks an explicit 24-hour value against this part of day; night hours before 5 AM belong
    /// to the following morning (returned as 24+). Nil when they contradict ("tonight at 9am").
    func hour(forHour24 hour: Int) -> Int? {
        switch self {
        case .morning: hour < 12 ? hour : nil
        case .afternoon: (12...19).contains(hour) ? hour : nil
        case .evening: (16...23).contains(hour) ? hour : nil
        case .night: (17...23).contains(hour) ? hour : hour < 5 ? hour + 24 : nil
        }
    }

    /// An hour said without am/pm or a part of day: 1–7 → PM, 8–11 → AM, 12 → noon.
    static func inferredHour(_ hour: Int) -> Int {
        (1...7).contains(hour) ? hour + 12 : hour
    }
}
