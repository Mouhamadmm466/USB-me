import Foundation

extension DateExpressionParser {
    enum Meridiem: Equatable, Sendable {
        case am, pm
    }

    enum DayPart: Equatable, Sendable {
        case morning, afternoon, evening, night

        init?(word: String?) {
            switch word {
            case "morning"?: self = .morning
            case "afternoon"?: self = .afternoon
            case "evening"?: self = .evening
            case "night"?: self = .night
            default: return nil
            }
        }
    }

    /// Which occurrence of a named weekday a phrase means.
    enum WeekdayModifier: Equatable, Sendable {
        /// "friday", "on friday", "this coming friday": the next occurrence strictly after today.
        case upcoming
        /// "this friday": today when today is Friday, otherwise `upcoming`.
        case this
        /// "next friday": `upcoming`, moved a week later when it falls in the current Mon–Sun week.
        case next
        /// "this past friday": the most recent occurrence strictly before today.
        case previous
        /// "last friday": `previous`, moved a week earlier when it falls in the current Mon–Sun week.
        case last
    }

    enum PeriodKind: Equatable, Sendable {
        case week, weekend, month

        init?(word: String?) {
            switch word {
            case "week"?: self = .week
            case "weekend"?: self = .weekend
            case "month"?: self = .month
            default: return nil
            }
        }
    }

    /// A clock time as said, before am/pm inference and part-of-day disambiguation.
    struct SpokenTime: Equatable, Sendable {
        enum Anchor: Equatable, Sendable {
            /// An hour as said. `twentyFourHour` marks "15:00", "09:00" and "1500 hours": no inference.
            case hour(Int, meridiem: Meridiem?, twentyFourHour: Bool)
            case noon
            /// Midnight at the end of the day it is attached to.
            case midnight
        }

        let anchor: Anchor
        /// Minutes after the anchor ("3:30" → 30), or before it ("quarter to 5" → -15).
        let minuteOffset: Int
    }

    /// A written date. `month` is nil for "the 25th"; `year` is nil unless it was said.
    struct CalendarDate: Equatable, Sendable {
        let year: Int?
        let month: Int?
        let day: Int
    }

    /// One meaningful piece of a phrase. A phrase is a sequence of components and filler words.
    enum Component: Equatable, Sendable {
        /// today 0, tomorrow 1, day after tomorrow 2, yesterday -1, day before yesterday -2.
        case relativeDay(Int)
        /// A Gregorian weekday, 1 (Sunday) … 7 (Saturday).
        case weekday(Int, WeekdayModifier)
        case date(CalendarDate)
        /// "september", "in october", "may 2027": a whole month.
        case namedMonth(month: Int, year: Int?)
        /// "this week" 0, "next weekend" 1, "last month" -1.
        case period(PeriodKind, offset: Int)
        /// "the next 3 days": today and the following days.
        case upcomingDays(Int, spoken: String)
        /// "in 3 days", "a week from today".
        case dayOffset(Int)
        /// "in 2 months".
        case monthOffset(Int)
        /// "in 20 minutes", "an hour from now".
        case elapsed(minutes: Int)
        case time(SpokenTime)
        case dayPart(DayPart)
        case now
    }

    /// Splits a phrase into components. Each rule tries to read one component at a position and
    /// reports where it stopped; the phrase parses only when rules and fillers cover every token.
    struct Grammar {
        let tokens: Tokens

        private var numbers: NumberReader { NumberReader(tokens: tokens) }

        func components() -> [Component]? {
            let rules: [(Int) -> Match<[Component]>?] = [
                relativeOffset(at:), upcomingDays(at:), dayKeyword(at:), period(at:),
                weekday(at:), calendarDate(at:), dayPart(at:), time(at:),
            ]
            var components: [Component] = []
            var i = 0
            scan: while i < tokens.count {
                if tokens.isWord(in: Lexicon.fillers, i) {
                    i += 1
                    continue
                }
                for rule in rules {
                    if let match = rule(i), match.next > i {
                        components += match.value
                        i = match.next
                        continue scan
                    }
                }
                return nil
            }
            return components
        }

        // MARK: Relative offsets

        /// "in 20 minutes", "in an hour and a half", "in 3 days", "20 minutes from now",
        /// "a week from today", "2 weeks from tomorrow".
        private func relativeOffset(at i: Int) -> Match<[Component]>? {
            if tokens.isWord("in", i) {
                guard let duration = numbers.duration(at: i + 1),
                      let component = offset(duration.value, fromDay: 0, allowsClockUnits: true) else { return nil }
                // Tolerate the redundant "in 3 days from now".
                let fromNow = tokens.isWord("from", duration.next) && tokens.isWord("now", duration.next + 1)
                return Match(value: [component], next: duration.next + (fromNow ? 2 : 0))
            }
            guard let duration = numbers.duration(at: i), tokens.isWord("from", duration.next) else { return nil }
            let component: Component?
            switch tokens.word(duration.next + 1) {
            case "now"?: component = offset(duration.value, fromDay: 0, allowsClockUnits: true)
            case "today"?: component = offset(duration.value, fromDay: 0, allowsClockUnits: false)
            case "tomorrow"?: component = offset(duration.value, fromDay: 1, allowsClockUnits: false)
            default: component = nil
            }
            return component.map { Match(value: [$0], next: duration.next + 2) }
        }

        /// Minutes and hours are elapsed time; days, weeks and months are calendar steps and must be
        /// a single whole count ("in 3 days", not "in 1.5 days" or "in 1 day 3 hours").
        private func offset(_ duration: SpokenDuration, fromDay base: Int, allowsClockUnits: Bool) -> Component? {
            if duration.isClockDuration {
                guard allowsClockUnits, let minutes = duration.totalMinutes,
                      minutes >= 0.5, minutes <= Limits.maxElapsedMinutes else { return nil }
                return .elapsed(minutes: Int(minutes.rounded()))
            }
            guard duration.terms.count == 1, let term = duration.terms.first,
                  term.amount >= 1, term.amount <= Limits.maxRelativeUnits, term.amount == term.amount.rounded()
            else { return nil }
            let count = Int(term.amount)
            switch term.unit {
            case .day: return .dayOffset(count + base)
            case .week: return .dayOffset(7 * count + base)
            case .month: return base == 0 ? .monthOffset(count) : nil
            case .minute, .hour: return nil
            }
        }

        /// "the next 3 days", "next two weeks", "the next couple of days".
        private func upcomingDays(at i: Int) -> Match<[Component]>? {
            let j = tokens.isWord("the", i) ? i + 1 : i
            guard tokens.isWord("next", j), let count = numbers.quantity(at: j + 1),
                  let unit = numbers.unit(at: count.next), unit.value == .day || unit.value == .week,
                  count.value >= 1, count.value <= Double(Limits.maxUpcomingDays), count.value == count.value.rounded()
            else { return nil }
            let n = Int(count.value)
            let days = unit.value == .week ? 7 * n : n
            guard days <= Limits.maxUpcomingDays else { return nil }
            let noun = unit.value == .week ? "week" : "day"
            let spoken = n == 1 ? "the next \(noun)" : "the next \(n) \(noun)s"
            return Match(value: [.upcomingDays(days, spoken: spoken)], next: unit.next)
        }

        // MARK: Days

        /// "today", "tonight", "tomorrow", "yesterday", "the day after tomorrow",
        /// "this morning", "last night", "now", "right now".
        private func dayKeyword(at i: Int) -> Match<[Component]>? {
            guard let word = tokens.word(i) else { return nil }
            switch word {
            case "today": return Match(value: [.relativeDay(0)], next: i + 1)
            case "tonight": return Match(value: [.relativeDay(0), .dayPart(.night)], next: i + 1)
            case "tomorrow": return Match(value: [.relativeDay(1)], next: i + 1)
            case "yesterday": return Match(value: [.relativeDay(-1)], next: i + 1)
            case "now": return Match(value: [.now], next: i + 1)
            case "right" where tokens.isWord("now", i + 1):
                return Match(value: [.now], next: i + 2)
            case "this":
                // "this morning" / "this afternoon" / "this evening" ("tonight" covers the night).
                guard let part = DayPart(word: tokens.word(i + 1)), part != .night else { return nil }
                return Match(value: [.relativeDay(0), .dayPart(part)], next: i + 2)
            case "last" where tokens.isWord("night", i + 1):
                return Match(value: [.relativeDay(-1), .dayPart(.night)], next: i + 2)
            case "the", "day":
                let j = word == "the" ? i + 1 : i
                guard tokens.isWord("day", j) else { return nil }
                if tokens.isWord("after", j + 1), tokens.isWord("tomorrow", j + 2) {
                    return Match(value: [.relativeDay(2)], next: j + 3)
                }
                if tokens.isWord("before", j + 1), tokens.isWord("yesterday", j + 2) {
                    return Match(value: [.relativeDay(-2)], next: j + 3)
                }
                return nil
            default:
                return nil
            }
        }

        /// "this week", "next weekend", "last month", "the weekend", "weekend".
        private func period(at i: Int) -> Match<[Component]>? {
            let offsets = ["this": 0, "next": 1, "last": -1]
            if let offset = tokens.word(i).flatMap({ offsets[$0] }), let kind = PeriodKind(word: tokens.word(i + 1)) {
                return Match(value: [.period(kind, offset: offset)], next: i + 2)
            }
            let j = tokens.isWord("the", i) ? i + 1 : i
            guard tokens.isWord("weekend", j) else { return nil }
            return Match(value: [.period(.weekend, offset: 0)], next: j + 1)
        }

        /// "friday", "this friday", "next fri", "this coming friday", "last friday", "this past friday".
        private func weekday(at i: Int) -> Match<[Component]>? {
            var modifier = WeekdayModifier.upcoming
            var j = i
            switch tokens.word(i) {
            case "this"?:
                if tokens.isWord("coming", i + 1) {
                    j = i + 2
                } else if tokens.isWord("past", i + 1) {
                    modifier = .previous
                    j = i + 2
                } else {
                    modifier = .this
                    j = i + 1
                }
            case "next"?:
                modifier = .next
                j = i + 1
            case "coming"?, "upcoming"?:
                j = i + 1
            case "last"?:
                modifier = .last
                j = i + 1
            default:
                break
            }
            guard let weekday = tokens.word(j).flatMap({ Lexicon.weekdays[$0] }) else { return nil }
            return Match(value: [.weekday(weekday, modifier)], next: j + 1)
        }

        // MARK: Dates

        /// "2026-09-25", "9/25", "9/25/2026", "september 25", "25th of september", "the 25th", "september".
        private func calendarDate(at i: Int) -> Match<[Component]>? {
            switch tokens[i] {
            case .isoDate(let year, let month, let day)?:
                return Match(value: [.date(CalendarDate(year: year, month: month, day: day))], next: i + 1)
            case .slashDate(let groups)?:
                return CalendarDate(slashGroups: groups).map { Match(value: [.date($0)], next: i + 1) }
            default:
                return monthFirstDate(at: i) ?? dayFirstDate(at: i)
            }
        }

        /// "september 25", "sept 25th", "september the 25th", "september twenty fifth", "september 25 2027";
        /// a month without a day ("september", "in october", "may 2027") names the whole month.
        private func monthFirstDate(at i: Int) -> Match<[Component]>? {
            let saidIn = tokens.isWord("in", i)
            let monthIndex = saidIn ? i + 1 : i
            guard let month = month(at: monthIndex) else { return nil }
            let afterMonth = monthIndex + 1
            if !saidIn, let day = dayOfMonth(at: tokens.isWord("the", afterMonth) ? afterMonth + 1 : afterMonth) {
                let year = self.year(at: day.next)
                let date = CalendarDate(year: year?.value, month: month, day: day.value.day)
                return Match(value: [.date(date)], next: year?.next ?? day.next)
            }
            let year = self.year(at: afterMonth)
            return Match(value: [.namedMonth(month: month, year: year?.value)], next: year?.next ?? afterMonth)
        }

        /// "25 september", "25th of september 2027", "the twenty fifth of may", "the 25th", "25th".
        private func dayFirstDate(at i: Int) -> Match<[Component]>? {
            let saidThe = tokens.isWord("the", i)
            guard let day = dayOfMonth(at: saidThe ? i + 1 : i) else { return nil }
            let monthIndex = tokens.isWord("of", day.next) ? day.next + 1 : day.next
            if let month = month(at: monthIndex) {
                let year = self.year(at: monthIndex + 1)
                let date = CalendarDate(year: year?.value, month: month, day: day.value.day)
                return Match(value: [.date(date)], next: year?.next ?? monthIndex + 1)
            }
            // Without a month the number must read as a date ("the 25th", "the 3", "25th"), not a bare "25".
            guard saidThe || day.value.isOrdinalToken else { return nil }
            return Match(value: [.date(CalendarDate(year: nil, month: nil, day: day.value.day))], next: day.next)
        }

        private func dayOfMonth(at i: Int) -> Match<(day: Int, isOrdinalToken: Bool)>? {
            let read: Match<Int>?
            var isOrdinalToken = false
            switch tokens[i] {
            case .ordinal(let value)?:
                read = Match(value: value, next: i + 1)
                isOrdinalToken = true
            case .number(let value, let text)?:
                read = text.count <= 2 ? Match(value: value, next: i + 1) : nil
            default:
                read = numbers.ordinalWords(at: i) ?? numbers.cardinalWords(at: i)
            }
            guard let read, (1...31).contains(read.value) else { return nil }
            return Match(value: (read.value, isOrdinalToken), next: read.next)
        }

        private func month(at i: Int) -> Int? {
            tokens.word(i).flatMap { Lexicon.months[$0] }
        }

        private func year(at i: Int) -> Match<Int>? {
            guard case .number(let value, let text)? = tokens[i], text.count == 4, (1900...2199).contains(value) else {
                return nil
            }
            return Match(value: value, next: i + 1)
        }

        // MARK: Parts of day and clock times

        /// "morning", "in the afternoon", "evening", "night" (as in "at night").
        private func dayPart(at i: Int) -> Match<[Component]>? {
            if let part = DayPart(word: tokens.word(i)) {
                return Match(value: [.dayPart(part)], next: i + 1)
            }
            guard tokens.isWord("in", i), tokens.isWord("the", i + 1), let part = DayPart(word: tokens.word(i + 2)) else {
                return nil
            }
            return Match(value: [.dayPart(part)], next: i + 3)
        }

        private func time(at i: Int) -> Match<[Component]>? {
            guard let time = namedTime(at: i) ?? clockFaceTime(at: i) ?? clockTime(at: i) else { return nil }
            return Match(value: [.time(time.value)], next: time.next)
        }

        /// "noon", "midday", "12 noon", "midnight", "twelve midnight".
        private func namedTime(at i: Int) -> Match<SpokenTime>? {
            var j = i
            if let twelve = numbers.hour(at: i), twelve.value == 12, tokens.isWord(in: ["noon", "midnight"], twelve.next) {
                j = twelve.next
            }
            switch tokens.word(j) {
            case "noon"?: return Match(value: SpokenTime(anchor: .noon, minuteOffset: 0), next: j + 1)
            case "midnight"?: return Match(value: SpokenTime(anchor: .midnight, minuteOffset: 0), next: j + 1)
            default: return nil
            }
        }

        /// "half past 3", "quarter to 5", "a quarter after 2", "ten past four", "20 minutes to 6".
        /// A plain number before past/to must be a clock-face amount (5, 10, 20, 25) or say
        /// "minutes", so a range such as "3 to 4pm" is not read as 3:57.
        private func clockFaceTime(at i: Int) -> Match<SpokenTime>? {
            var j = i
            let amount: Int
            if tokens.isWord("half", j) {
                amount = 30
                j += 1
            } else if tokens.isWord("quarter", j) {
                amount = 15
                j += 1
            } else if tokens.isWord("a", j), tokens.isWord("quarter", j + 1) {
                amount = 15
                j += 2
            } else if let count = numbers.cardinal(at: j) {
                j = count.next
                let saidMinutes = tokens.isWord(in: ["minute", "minutes"], j)
                if saidMinutes { j += 1 }
                guard (1...59).contains(count.value), saidMinutes || [5, 10, 20, 25].contains(count.value) else {
                    return nil
                }
                amount = count.value
            } else {
                return nil
            }
            let sign: Int
            switch tokens.word(j) {
            case "past"?, "after"?: sign = 1
            case "to"?, "till"?, "of"?: sign = -1
            default: return nil
            }
            guard !(amount == 30 && sign < 0), let hour = clockFaceHour(at: j + 1) else { return nil }
            return Match(value: SpokenTime(anchor: hour.value, minuteOffset: sign * amount), next: hour.next)
        }

        /// The hour a clock-face phrase counts from: "3", "three", "3pm", "5 o'clock", "noon", "midnight".
        private func clockFaceHour(at i: Int) -> Match<SpokenTime.Anchor>? {
            switch tokens.word(i) {
            case "noon"?: return Match(value: .noon, next: i + 1)
            case "midnight"?: return Match(value: .midnight, next: i + 1)
            default: break
            }
            guard let hour = numbers.hour(at: i), (1...12).contains(hour.value), !hasLeadingZero(at: i) else { return nil }
            var j = hour.next
            if tokens.isWord("oclock", j) { j += 1 }
            let meridiem = meridiem(at: j)
            return Match(
                value: .hour(hour.value, meridiem: meridiem, twentyFourHour: false),
                next: meridiem == nil ? j : j + 1
            )
        }

        private static let militaryHourWords: Set<String> = ["hours", "hour", "h"]

        /// "3:30", "15:00", "3.30pm", "930am", "1500 hours", "at 1530", or a spoken hour.
        private func clockTime(at i: Int) -> Match<SpokenTime>? {
            switch tokens[i] {
            case .clock(let hour, let minute, let hourText)?:
                return writtenTime(hour: hour, minute: minute, hourText: hourText, next: i + 1)
            case .decimal(let hour, let fraction)? where fraction.count == 2:
                // "3.30pm", "at 9.15": clock times written with a dot.
                return writtenTime(hour: hour, minute: Int(fraction) ?? 60, hourText: String(hour), next: i + 1)
            case .number(let value, let text)? where text.count == 3 || text.count == 4:
                // "930am", "1500 hours", "at 1530": hours and minutes run together. Needs a marker,
                // otherwise "2027" would read as 20:27.
                let marked = meridiem(at: i + 1) != nil || tokens.isWord(in: Self.militaryHourWords, i + 1)
                    || tokens.isWord("at", i - 1)
                guard marked else { return nil }
                return writtenTime(hour: value / 100, minute: value % 100, hourText: String(text.dropLast(2)), next: i + 1)
            default:
                return spokenHour(at: i)
            }
        }

        /// A time with separate hour and minute fields, followed by an optional am/pm or "hours".
        /// Hours 0 and 13–23, a leading zero ("09:00") or "hours" make it a 24-hour time.
        private func writtenTime(hour: Int, minute: Int, hourText: String, next: Int) -> Match<SpokenTime>? {
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            if let meridiem = meridiem(at: next) {
                guard (1...12).contains(hour) else { return nil } // "15:00 pm", "0:30 am"
                let anchor = SpokenTime.Anchor.hour(hour, meridiem: meridiem, twentyFourHour: false)
                return Match(value: SpokenTime(anchor: anchor, minuteOffset: minute), next: next + 1)
            }
            let military = tokens.isWord(in: Self.militaryHourWords, next)
            let twentyFourHour = military || hour == 0 || hour > 12 || hourText.hasPrefix("0")
            let anchor = SpokenTime.Anchor.hour(hour, meridiem: nil, twentyFourHour: twentyFourHour)
            return Match(value: SpokenTime(anchor: anchor, minuteOffset: minute), next: military ? next + 1 : next)
        }

        /// An hour in one or two digits or in words, then optional minutes ("3 30", "three thirty",
        /// "nine oh five"), "o'clock" and am/pm: "3pm", "three thirty pm", "3 o'clock", "at 3".
        private func spokenHour(at i: Int) -> Match<SpokenTime>? {
            guard let hour = numbers.hour(at: i) else { return nil }
            var j = hour.next
            var minute = 0
            if let minutes = minutesAfterHour(at: j) {
                minute = minutes.value
                j = minutes.next
            }
            if minute == 0, tokens.isWord("oclock", j) { j += 1 }
            if let meridiem = meridiem(at: j) {
                guard (1...12).contains(hour.value) else { return nil }
                let anchor = SpokenTime.Anchor.hour(hour.value, meridiem: meridiem, twentyFourHour: false)
                return Match(value: SpokenTime(anchor: anchor, minuteOffset: minute), next: j + 1)
            }
            if (1...12).contains(hour.value), !hasLeadingZero(at: i) {
                let anchor = SpokenTime.Anchor.hour(hour.value, meridiem: nil, twentyFourHour: false)
                return Match(value: SpokenTime(anchor: anchor, minuteOffset: minute), next: j)
            }
            // "at 15", "at 07": a bare 24-hour value counts as a time only right after "at".
            guard tokens.isWord("at", i - 1), (0...23).contains(hour.value), hour.value > 12 || hasLeadingZero(at: i)
            else { return nil }
            let anchor = SpokenTime.Anchor.hour(hour.value, meridiem: nil, twentyFourHour: true)
            return Match(value: SpokenTime(anchor: anchor, minuteOffset: minute), next: j)
        }

        /// Minutes said right after an hour: two digits ("30", "05"), "thirty", "forty five", "oh five".
        private func minutesAfterHour(at i: Int) -> Match<Int>? {
            if case .number(let value, let text)? = tokens[i] {
                return text.count == 2 && value <= 59 ? Match(value: value, next: i + 1) : nil
            }
            if tokens.isWord(in: ["oh", "o", "zero"], i),
               let digit = tokens.word(i + 1).flatMap({ Lexicon.cardinalUnits[$0] }), digit > 0 {
                return Match(value: digit, next: i + 2)
            }
            guard let words = numbers.cardinalWords(at: i), (10...59).contains(words.value) else { return nil }
            return words
        }

        private func meridiem(at i: Int) -> Meridiem? {
            switch tokens.word(i) {
            case "am"?: .am
            case "pm"?: .pm
            default: nil
            }
        }

        private func hasLeadingZero(at i: Int) -> Bool {
            guard case .number(_, let text)? = tokens[i] else { return false }
            return text.count > 1 && text.hasPrefix("0")
        }
    }
}

extension DateExpressionParser.CalendarDate {
    /// "9/25" and "9/25/26" are month/day; "25/9" is accepted as day/month because 25 cannot be a
    /// month; "2026/09/25" is year/month/day. Two-digit years are 20xx.
    init?(slashGroups groups: [String]) {
        let values = groups.compactMap { Int($0) }
        guard values.count == groups.count, groups.count == 2 || groups.count == 3 else { return nil }
        if groups.count == 3, groups[0].count == 4 {
            self.init(year: values[0], month: values[1], day: values[2])
            return
        }
        let monthFirst = (1...12).contains(values[0]) && (1...31).contains(values[1])
        let dayFirst = (1...12).contains(values[1]) && (1...31).contains(values[0])
        guard monthFirst || dayFirst else { return nil }
        var year: Int?
        if groups.count == 3 {
            switch groups[2].count {
            case 2: year = 2000 + values[2]
            case 4: year = values[2]
            default: return nil
            }
        }
        self.init(year: year, month: monthFirst ? values[0] : values[1], day: monthFirst ? values[1] : values[0])
    }
}
