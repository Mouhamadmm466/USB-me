import Core
import Foundation

/// In-memory calendar that records writes into a `SideEffectRecorder`.
public actor FakeCalendarStore: CalendarStore {
    private var events: [EventReference]
    private let recorder: SideEffectRecorder
    private let calendar: Calendar
    private var readFailure: ToolAdapterError?
    private var writeFailure: ToolAdapterError?
    private var createdCount = 0

    /// - Parameter calendar: used, like the EventKit adapter, to decide whether an updated all-day
    ///   event still starts and ends at midnight.
    public init(events: [EventReference] = [], recorder: SideEffectRecorder, calendar: Calendar = .autoupdatingCurrent) {
        self.events = events
        self.recorder = recorder
        self.calendar = calendar
    }

    public var allEvents: [EventReference] { events }

    public func setEvents(_ events: [EventReference]) {
        self.events = events
    }

    /// Reads (`events(in:)`, `event(identifier:)`) throw `failure` (nil clears it).
    public func setReadFailure(_ failure: ToolAdapterError?) {
        readFailure = failure
    }

    /// Writes throw `failure` without recording anything (nil clears it).
    public func setWriteFailure(_ failure: ToolAdapterError?) {
        writeFailure = failure
    }

    public func events(in interval: DateInterval) async throws -> [EventReference] {
        if let readFailure { throw readFailure }
        return events
            .filter { event in
                if event.endDate > event.startDate {
                    return event.startDate < interval.end && event.endDate > interval.start
                }
                return event.startDate >= interval.start && event.startDate < interval.end
            }
            .sorted { ($0.startDate, $0.eventIdentifier) < ($1.startDate, $1.eventIdentifier) }
    }

    public func event(identifier: String) async throws -> EventReference? {
        if let readFailure { throw readFailure }
        return events.first { $0.eventIdentifier == identifier }
    }

    public func createEvent(_ draft: EventDraft) async throws -> EventReference {
        if let writeFailure { throw writeFailure }
        createdCount += 1
        let reference = EventReference(
            eventIdentifier: "fake-event-\(createdCount)",
            title: draft.title,
            startDate: draft.startDate,
            endDate: draft.endDate,
            isAllDay: draft.isAllDay,
            location: draft.location
        )
        events.append(reference)
        await recorder.record(.eventCreated(draft))
        return reference
    }

    public func updateEvent(identifier: String, changes: EventChanges) async throws -> EventReference {
        if let writeFailure { throw writeFailure }
        guard let index = events.firstIndex(where: { $0.eventIdentifier == identifier }) else {
            throw ToolAdapterError.notFound
        }
        let current = events[index]
        let start = changes.newStartDate ?? current.startDate
        let end = changes.newEndDate ?? current.endDate
        guard end >= start else { throw ToolAdapterError.invalidArgument }
        // Like the EventKit adapter: a clock time turns an all-day event into a timed one.
        let isAllDay = current.isAllDay && calendar.startOfDay(for: start) == start && calendar.startOfDay(for: end) == end
        let updated = EventReference(
            eventIdentifier: current.eventIdentifier,
            title: changes.newTitle ?? current.title,
            startDate: start,
            endDate: end,
            isAllDay: isAllDay,
            location: changes.newLocation ?? current.location
        )
        events[index] = updated
        await recorder.record(.eventUpdated(id: identifier, changes: changes))
        return updated
    }
}

/// In-memory reminders that records creations into a `SideEffectRecorder`.
public actor FakeReminderStore: ReminderStore {
    private let recorder: SideEffectRecorder
    private var failure: ToolAdapterError?
    public private(set) var reminders: [String: ReminderDraft] = [:]
    private var createdCount = 0

    public init(recorder: SideEffectRecorder) {
        self.recorder = recorder
    }

    /// Creation throws `failure` without recording anything (nil clears it).
    public func setFailure(_ failure: ToolAdapterError?) {
        self.failure = failure
    }

    public func createReminder(_ draft: ReminderDraft) async throws -> String {
        if let failure { throw failure }
        createdCount += 1
        let identifier = "fake-reminder-\(createdCount)"
        reminders[identifier] = draft
        await recorder.record(.reminderCreated(draft))
        return identifier
    }

    /// Reminders that already exist in this fake world, for reading paths (ingestion).
    public func seed(_ existing: [String: ReminderDraft]) {
        for (identifier, draft) in existing { reminders[identifier] = draft }
    }

    public func reminders(completedSince: Date?) async throws -> [ReminderReference] {
        if let failure { throw failure }
        return reminders.map { identifier, draft in
            ReminderReference(
                identifier: identifier, title: draft.title, dueDate: draft.dueDate,
                isCompleted: false, listName: nil
            )
        }
    }
}
