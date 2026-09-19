import Core
import Foundation

/// A question the planner needs answered before it can produce dates.
public struct PlanClarification: Error, Sendable, Equatable {
    public let reason: ClarificationReason
    public let question: String
    public let missingArgument: String?

    public init(reason: ClarificationReason, question: String, missingArgument: String?) {
        self.reason = reason
        self.question = question
        self.missingArgument = missingArgument
    }
}

/// Deterministic calendar arithmetic for `create_calendar_event` and `update_calendar_event`.
///
/// Swift, not the model, turns the user's date phrases into instants: a date-only start makes an
/// all-day event, a time-only end or new start keeps the relevant day, and moving an event keeps
/// its duration.
public struct CalendarPlanner: Sendable {
    public static let durationRange = 5...1440
    public static let defaultDurationMinutes = 60

    public let parser: any DateParsing
    public let calendar: Calendar

    public init(parser: any DateParsing, calendar: Calendar) {
        self.parser = parser
        self.calendar = calendar
    }

    public struct NewEventTimes: Sendable, Equatable {
        public let start: Date
        public let end: Date
        public let isAllDay: Bool
    }

    // MARK: Helpers

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// `day`'s date with `time`'s clock time, in the planner's calendar.
    public func combine(day: Date, timeOf time: Date) -> Date {
        let dayParts = calendar.dateComponents([.year, .month, .day], from: day)
        let timeParts = calendar.dateComponents([.hour, .minute, .second], from: time)
        var components = DateComponents()
        components.year = dayParts.year
        components.month = dayParts.month
        components.day = dayParts.day
        components.hour = timeParts.hour
        components.minute = timeParts.minute
        components.second = timeParts.second ?? 0
        return calendar.date(from: components) ?? time
    }

    private func nextDay(after day: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
            ?? calendar.startOfDay(for: day).addingTimeInterval(86_400)
    }

    private func minutesLater(_ minutes: Int, from date: Date) -> Date {
        date.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    /// Resolves an end phrase for a timed event starting at `start`.
    private func timedEnd(_ phrase: String, start: Date, argument: String) -> Result<Date, PlanClarification> {
        if let parsed = parser.parseDateTime(phrase) {
            guard parsed.hasTime else {
                return .failure(PlanClarification(reason: .dateUnclear, question: ClarificationText.endTimeNeeded, missingArgument: argument))
            }
            var end = parsed.date
            if parser.isTimeOfDayOnly(phrase) {
                end = combine(day: start, timeOf: parsed.date)
                if end <= start {
                    let hour = calendar.component(.hour, from: end)
                    let startHour = calendar.component(.hour, from: start)
                    let afternoon = end.addingTimeInterval(12 * 3600)
                    if parsed.meridiemInferred, afternoon > start, calendar.isDate(afternoon, inSameDayAs: start) {
                        // "from 3 to 5" where "5" was read as 5 AM.
                        end = afternoon
                    } else if hour < 6, startHour >= 18 {
                        // "from 11 pm to 1 am" ends the next morning.
                        end = calendar.date(byAdding: .day, value: 1, to: end) ?? end
                    }
                }
            }
            guard end > start else {
                return .failure(PlanClarification(reason: .dateUnclear, question: ClarificationText.endBeforeStart, missingArgument: argument))
            }
            return .success(end)
        }
        if let minutes = parser.parseDurationMinutes(phrase), Self.durationRange.contains(minutes) {
            // The model sometimes puts "2 hours" in the end slot.
            return .success(minutesLater(minutes, from: start))
        }
        return .failure(PlanClarification(reason: .dateUnclear, question: ClarificationText.endUnclear, missingArgument: argument))
    }

    /// Resolves an end phrase for an all-day event starting on `startDay`: a (last) day.
    private func allDayEnd(_ phrase: String, startDay: Date, startArgument: String, endArgument: String) -> Result<Date, PlanClarification> {
        guard let parsed = parser.parseDateTime(phrase) else {
            return .failure(PlanClarification(reason: .dateUnclear, question: ClarificationText.endUnclear, missingArgument: endArgument))
        }
        guard !parsed.hasTime else {
            // An end time needs a start time.
            return .failure(PlanClarification(reason: .dateUnclear, question: ClarificationText.startTimeNeeded, missingArgument: startArgument))
        }
        let lastDay = calendar.startOfDay(for: parsed.date)
        guard lastDay >= calendar.startOfDay(for: startDay) else {
            return .failure(PlanClarification(reason: .dateUnclear, question: ClarificationText.endBeforeStart, missingArgument: endArgument))
        }
        return .success(nextDay(after: lastDay))
    }

    // MARK: Create

    /// Start: required; date-only ⇒ all-day. End: `end`, else `duration_minutes`, else 60 minutes.
    public func planNewEvent(start startPhrase: String?, end endPhrase: String?, durationMinutes: Int?) -> Result<NewEventTimes, PlanClarification> {
        guard let startPhrase = Self.nonEmpty(startPhrase) else {
            return .failure(PlanClarification(reason: .missingField, question: ClarificationText.whenToSchedule, missingArgument: "start"))
        }
        guard let parsedStart = parser.parseDateTime(startPhrase) else {
            return .failure(PlanClarification(reason: .dateUnclear, question: ClarificationText.whenToScheduleUnclear, missingArgument: "start"))
        }
        let endPhrase = Self.nonEmpty(endPhrase)

        if !parsedStart.hasTime {
            let day = calendar.startOfDay(for: parsedStart.date)
            if let endPhrase {
                return allDayEnd(endPhrase, startDay: day, startArgument: "start", endArgument: "end")
                    .map { NewEventTimes(start: day, end: $0, isAllDay: true) }
            }
            if durationMinutes != nil {
                return .failure(PlanClarification(reason: .dateUnclear, question: ClarificationText.startTimeNeeded, missingArgument: "start"))
            }
            return .success(NewEventTimes(start: day, end: nextDay(after: day), isAllDay: true))
        }

        let start = parsedStart.date
        if let endPhrase {
            return timedEnd(endPhrase, start: start, argument: "end").map { NewEventTimes(start: start, end: $0, isAllDay: false) }
        }
        if let durationMinutes {
            guard Self.durationRange.contains(durationMinutes) else {
                return .failure(PlanClarification(reason: .missingField, question: ClarificationText.howLong, missingArgument: "duration_minutes"))
            }
            return .success(NewEventTimes(start: start, end: minutesLater(durationMinutes, from: start), isAllDay: false))
        }
        return .success(NewEventTimes(start: start, end: minutesLater(Self.defaultDurationMinutes, from: start), isAllDay: false))
    }

    // MARK: Update

    /// Computes the effective changes to `event`. Only fields that actually change are set; when
    /// nothing changes the planner asks what to change.
    ///
    /// - `new_start` with only a time keeps the event's date; with only a date keeps its time.
    /// - Moving the start without a new end keeps the original duration (an all-day event given a
    ///   clock time becomes a one-hour timed event).
    /// - `new_end` (or `new_duration_minutes`) sets the end relative to the (new) start.
    public func planChanges(
        for event: EventReference,
        newStart newStartPhrase: String?,
        newEnd newEndPhrase: String?,
        newDurationMinutes: Int?,
        newTitle: String?,
        newLocation: String?
    ) -> Result<EventChanges, PlanClarification> {
        var start: Date?
        var isAllDay = event.isAllDay

        if let phrase = Self.nonEmpty(newStartPhrase) {
            guard let parsed = parser.parseDateTime(phrase) else {
                return .failure(PlanClarification(reason: .dateUnclear, question: ClarificationText.whenToMove, missingArgument: "new_start"))
            }
            if !parsed.hasTime {
                let day = calendar.startOfDay(for: parsed.date)
                start = event.isAllDay ? day : combine(day: day, timeOf: event.startDate)
            } else if parser.isTimeOfDayOnly(phrase) {
                start = combine(day: event.startDate, timeOf: parsed.date)
                isAllDay = false
            } else {
                start = parsed.date
                isAllDay = false
            }
        }

        let effectiveStart = start ?? event.startDate
        var end: Date?
        if let phrase = Self.nonEmpty(newEndPhrase) {
            let resolved = isAllDay
                ? allDayEnd(phrase, startDay: effectiveStart, startArgument: "new_start", endArgument: "new_end")
                : timedEnd(phrase, start: effectiveStart, argument: "new_end")
            switch resolved {
            case let .success(value): end = value
            case let .failure(clarification): return .failure(clarification)
            }
        } else if let newDurationMinutes {
            guard Self.durationRange.contains(newDurationMinutes) else {
                return .failure(PlanClarification(reason: .missingField, question: ClarificationText.howLong, missingArgument: "new_duration_minutes"))
            }
            guard !isAllDay else {
                return .failure(PlanClarification(reason: .dateUnclear, question: ClarificationText.startTimeNeeded, missingArgument: "new_start"))
            }
            end = minutesLater(newDurationMinutes, from: effectiveStart)
        } else if let start {
            if event.isAllDay, !isAllDay {
                end = minutesLater(Self.defaultDurationMinutes, from: start)
            } else {
                end = start.addingTimeInterval(event.endDate.timeIntervalSince(event.startDate))
            }
        }

        if let end, end <= effectiveStart {
            return .failure(PlanClarification(reason: .dateUnclear, question: ClarificationText.endBeforeStart, missingArgument: "new_end"))
        }

        let changes = EventChanges(
            newTitle: newTitle.flatMap { $0 == event.title ? nil : $0 },
            newStartDate: start.flatMap { $0 == event.startDate ? nil : $0 },
            newEndDate: end.flatMap { $0 == event.endDate ? nil : $0 },
            newLocation: newLocation.flatMap { $0 == (event.location ?? "") ? nil : $0 }
        )
        if changes.isEmpty {
            return .failure(PlanClarification(reason: .missingField, question: ClarificationText.whatToChange, missingArgument: nil))
        }
        return .success(changes)
    }
}
