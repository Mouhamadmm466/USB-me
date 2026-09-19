import Foundation

extension DateExpressionParser {
    /// How a phrase fixes its day.
    indirect enum DayAnchor: Equatable, Sendable {
        /// today 0, tomorrow 1, yesterday -1, ...
        case relative(days: Int)
        /// "in 3 days", "a week from today".
        case offset(days: Int)
        /// "in 2 months".
        case monthOffset(Int)
        case weekday(Int, WeekdayModifier)
        /// "friday next week", "next week on friday", "friday this week".
        case weekdayInWeek(Int, weekOffset: Int)
        /// "the 5th of next month", "this month on the 30th".
        case dayOfMonth(Int, monthOffset: Int)
        case date(CalendarDate)
        /// A day also named by its weekday ("friday, september 25"); the two must agree.
        case confirmed(DayAnchor, weekday: Int)

        /// Anchors that only ever name past days, which a date to act on cannot use.
        var isPastOnly: Bool {
            switch self {
            case .relative(let days): days < 0
            case .weekday(_, let modifier): modifier == .previous || modifier == .last
            case .dayOfMonth(_, let monthOffset): monthOffset < 0
            case .confirmed(let anchor, _): anchor.isPastOnly
            default: false
            }
        }

        /// "today", "tomorrow", "yesterday": described with that word rather than the date.
        var isRelativeWord: Bool {
            switch self {
            case .relative(let days): (-1...1).contains(days)
            case .confirmed(let anchor, _): anchor.isRelativeWord
            default: false
            }
        }
    }

    /// A multi-day stretch that is only meaningful as a range.
    enum Span: Equatable, Sendable {
        case period(PeriodKind, offset: Int)
        case month(Int, year: Int?)
        case upcomingDays(Int, spoken: String)
    }

    /// What a whole phrase means, before any calendar arithmetic.
    enum Interpretation: Equatable, Sendable {
        case now
        case elapsed(minutes: Int)
        case span(Span)
        case day(DayAnchor, time: SpokenTime?, part: DayPart?)
        /// A clock time and/or part of day with no day named: the next one to come.
        case timeOfDay(SpokenTime?, part: DayPart?)

        init?(_ phrase: String) {
            guard phrase.count <= Limits.maxPhraseLength,
                  let components = Grammar(tokens: Tokens(phrase)).components() else { return nil }
            self.init(components: components)
        }

        /// Combines components. Each slot (day, weekday, span, time, part of day, relative moment)
        /// takes at most one component — a second is a contradiction ("tomorrow yesterday",
        /// "3pm 4pm") — and some slots exclude others ("next week at 3pm", "in 20 minutes at 5").
        init?(components: [Component]) {
            var anchors: [DayAnchor] = []
            var weekday: (day: Int, modifier: WeekdayModifier)?
            var span: Span?
            var time: SpokenTime?
            var part: DayPart?
            var elapsed: Int?
            var saidNow = false

            for component in components {
                switch component {
                case .relativeDay(let days): anchors.append(.relative(days: days))
                case .date(let date): anchors.append(.date(date))
                case .dayOffset(let days): anchors.append(.offset(days: days))
                case .monthOffset(let months): anchors.append(.monthOffset(months))
                case .weekday(let day, let modifier):
                    guard weekday == nil else { return nil }
                    weekday = (day, modifier)
                case .period(let kind, let offset):
                    guard span == nil else { return nil }
                    span = .period(kind, offset: offset)
                case .namedMonth(let month, let year):
                    guard span == nil else { return nil }
                    span = .month(month, year: year)
                case .upcomingDays(let days, let spoken):
                    guard span == nil else { return nil }
                    span = .upcomingDays(days, spoken: spoken)
                case .time(let spoken):
                    guard time == nil else { return nil }
                    time = spoken
                case .dayPart(let spoken):
                    guard part == nil else { return nil }
                    part = spoken
                case .elapsed(let minutes):
                    guard elapsed == nil else { return nil }
                    elapsed = minutes
                case .now:
                    guard !saidNow else { return nil }
                    saidNow = true
                }
            }
            guard !components.isEmpty, anchors.count <= 1 else { return nil }

            // "now" and "in 20 minutes" are complete moments; nothing may qualify them.
            if saidNow || elapsed != nil {
                guard !(saidNow && elapsed != nil), anchors.isEmpty, weekday == nil, span == nil, time == nil, part == nil
                else { return nil }
                self = elapsed.map { .elapsed(minutes: $0) } ?? .now
                return
            }

            var anchor = anchors.first
            if case .period(.month, let monthOffset)? = span, case .date(let date)? = anchor, date.month == nil {
                anchor = .dayOfMonth(date.day, monthOffset: monthOffset) // "the 5th of next month"
                span = nil
            }
            if let weekday {
                if case .period(.week, let weekOffset)? = span, anchor == nil, weekday.modifier == .upcoming {
                    anchor = .weekdayInWeek(weekday.day, weekOffset: weekOffset) // "friday next week"
                    span = nil
                } else if let named = anchor, span == nil {
                    anchor = .confirmed(named, weekday: weekday.day) // "friday, september 25"
                } else if anchor == nil, span == nil {
                    anchor = .weekday(weekday.day, weekday.modifier)
                } else {
                    return nil
                }
            }

            if let span {
                guard anchor == nil, time == nil, part == nil else { return nil }
                self = .span(span)
            } else if let anchor {
                self = .day(anchor, time: time, part: part)
            } else if time != nil || part != nil {
                self = .timeOfDay(time, part: part)
            } else {
                return nil
            }
        }
    }
}
