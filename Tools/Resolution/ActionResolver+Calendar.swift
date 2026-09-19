import Core
import Foundation

extension ActionResolver {
    // MARK: get_calendar_events

    func resolveGetCalendarEvents(_ call: ProposedToolCall, context: ResolutionContext) async -> ResolutionOutcome {
        let tool = ToolID.getCalendarEvents
        if let blocked = await permissionBlock(.calendar, for: tool) { return blocked }
        guard let when = Self.nonEmpty(call.string("when")) else {
            return clarify(.missingField, ClarificationText.whichDayToCheck, missingArgument: "when", call: call, context: context)
        }
        let parser = parser(for: context)
        if let range = parser.parseRange(when), range.end > range.start {
            return .resolved(.getCalendarEvents(range))
        }
        // A single instant ("friday at 3") reads that whole day.
        if let instant = parser.parseDateTime(when) {
            let calendar = context.clock.calendar
            let start = calendar.startOfDay(for: instant.date)
            if let end = calendar.date(byAdding: .day, value: 1, to: start) {
                return .resolved(.getCalendarEvents(DateRange(start: start, end: end, spokenDescription: ClarificationText.echo(when))))
            }
        }
        return clarify(.dateUnclear, ClarificationText.whichDayToCheck, missingArgument: "when", call: call, context: context)
    }

    // MARK: create_calendar_event

    func resolveCreateCalendarEvent(_ call: ProposedToolCall, context: ResolutionContext) async -> ResolutionOutcome {
        let tool = ToolID.createCalendarEvent
        if let blocked = await permissionBlock(.calendar, for: tool) { return blocked }

        let title: String
        switch TextSanitizer.singleLine(call.string("title"), maxLength: TextSanitizer.maxLength(of: "title", in: tool, fallback: 100)) {
        case let .valid(value): title = value
        case .empty: return clarify(.missingField, ClarificationText.eventTitleMissing, missingArgument: "title", call: call, context: context)
        case .tooLong: return clarify(.missingField, ClarificationText.eventTitleTooLong, missingArgument: "title", call: call, context: context)
        }

        let parser = parser(for: context)
        let planner = CalendarPlanner(parser: parser, calendar: context.clock.calendar)
        let times: CalendarPlanner.NewEventTimes
        switch planner.planNewEvent(
            start: call.string("start"),
            end: call.string("end"),
            durationMinutes: Self.integerArgument(call, "duration_minutes", parser: parser)
        ) {
        case let .success(value): times = value
        case let .failure(clarification): return clarify(clarification, call: call, context: context)
        }

        let location: String?
        switch TextSanitizer.singleLine(call.string("location"), maxLength: TextSanitizer.maxLength(of: "location", in: tool, fallback: 100)) {
        case let .valid(value): location = value
        case .empty: location = nil
        case .tooLong: return clarify(.missingField, ClarificationText.locationTooLong, missingArgument: "location", call: call, context: context)
        }

        return .resolved(.createCalendarEvent(EventDraft(
            title: title,
            startDate: times.start,
            endDate: times.end,
            isAllDay: times.isAllDay,
            location: location
        )))
    }

    // MARK: update_calendar_event

    func resolveUpdateCalendarEvent(_ call: ProposedToolCall, context: ResolutionContext) async -> ResolutionOutcome {
        let tool = ToolID.updateCalendarEvent
        if let blocked = await permissionBlock(.calendar, for: tool) { return blocked }
        let parser = parser(for: context)

        let resolver = EventResolver(store: environment.calendar, parser: parser, calendar: context.clock.calendar)
        let event: EventReference
        switch await resolver.resolve(
            query: Self.nonEmpty(call.string("event_query")),
            pinned: context.pinnedSelections["event_query"],
            session: context.session,
            now: context.clock.now()
        ) {
        case let .event(found): event = found
        case let .clarification(reason, question, candidates):
            return clarify(reason, question, candidates: candidates, missingArgument: "event_query", call: call, context: context)
        case let .failure(code): return failed(tool, code)
        }

        let newTitle: String?
        switch TextSanitizer.singleLine(call.string("new_title"), maxLength: TextSanitizer.maxLength(of: "new_title", in: tool, fallback: 100)) {
        case let .valid(value): newTitle = value
        case .empty: newTitle = nil
        case .tooLong: return clarify(.missingField, ClarificationText.eventTitleTooLong, missingArgument: "new_title", call: call, context: context)
        }
        let newLocation: String?
        switch TextSanitizer.singleLine(call.string("new_location"), maxLength: TextSanitizer.maxLength(of: "new_location", in: tool, fallback: 100)) {
        case let .valid(value): newLocation = value
        case .empty: newLocation = nil
        case .tooLong: return clarify(.missingField, ClarificationText.locationTooLong, missingArgument: "new_location", call: call, context: context)
        }

        let planner = CalendarPlanner(parser: parser, calendar: context.clock.calendar)
        switch planner.planChanges(
            for: event,
            newStart: call.string("new_start"),
            newEnd: call.string("new_end"),
            newDurationMinutes: Self.integerArgument(call, "new_duration_minutes", parser: parser),
            newTitle: newTitle,
            newLocation: newLocation
        ) {
        case let .success(changes): return .resolved(.updateCalendarEvent(event, changes))
        case let .failure(clarification): return clarify(clarification, call: call, context: context)
        }
    }

    // MARK: create_reminder

    func resolveCreateReminder(_ call: ProposedToolCall, context: ResolutionContext) async -> ResolutionOutcome {
        let tool = ToolID.createReminder
        if let blocked = await permissionBlock(.reminders, for: tool) { return blocked }

        let title: String
        switch TextSanitizer.singleLine(call.string("title"), maxLength: TextSanitizer.maxLength(of: "title", in: tool, fallback: 120)) {
        case let .valid(value): title = value
        case .empty: return clarify(.missingField, ClarificationText.reminderTitleMissing, missingArgument: "title", call: call, context: context)
        case .tooLong: return clarify(.missingField, ClarificationText.reminderTitleTooLong, missingArgument: "title", call: call, context: context)
        }

        guard let duePhrase = Self.nonEmpty(call.string("due")) else {
            return .resolved(.createReminder(ReminderDraft(title: title, dueDate: nil, dueHasTime: false)))
        }
        guard let due = parser(for: context).parseDateTime(duePhrase) else {
            return clarify(.dateUnclear, ClarificationText.reminderWhenUnclear, missingArgument: "due", call: call, context: context)
        }
        let dueDate = due.hasTime ? due.date : context.clock.calendar.startOfDay(for: due.date)
        return .resolved(.createReminder(ReminderDraft(title: title, dueDate: dueDate, dueHasTime: due.hasTime)))
    }
}
