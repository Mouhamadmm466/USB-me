import Core
import EventKit
import Foundation

/// Calendar access. Event references use half-open intervals: an all-day event on Sep 21 is
/// [Sep 21 00:00, Sep 22 00:00) in the store's calendar.
public protocol CalendarStore: Sendable {
    /// Events overlapping `interval`, in any order.
    func events(in interval: DateInterval) async throws -> [EventReference]
    func event(identifier: String) async throws -> EventReference?
    /// Creates the event in the default calendar for new events.
    func createEvent(_ draft: EventDraft) async throws -> EventReference
    /// Applies `changes` to this occurrence only (span `.thisEvent`).
    func updateEvent(identifier: String, changes: EventChanges) async throws -> EventReference
}

/// Reminders access.
public protocol ReminderStore: Sendable {
    /// Creates the reminder in the default list and returns its identifier.
    func createReminder(_ draft: ReminderDraft) async throws -> String
    /// Reminders the user has, for reading rather than writing: everything still open, plus
    /// anything completed since `completedSince` so a sync can mark them done.
    func reminders(completedSince: Date?) async throws -> [ReminderReference]
}

public extension ReminderStore {
    func reminders(completedSince: Date?) async throws -> [ReminderReference] { [] }
}

/// One of the user's reminders, as read.
public struct ReminderReference: Codable, Sendable, Hashable {
    public let identifier: String
    public let title: String
    public let dueDate: Date?
    public let isCompleted: Bool
    /// The list it lives in ("Groceries", "Work"), which is often the only context a reminder has.
    public let listName: String?

    public init(identifier: String, title: String, dueDate: Date?, isCompleted: Bool, listName: String? = nil) {
        self.identifier = identifier
        self.title = title
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.listName = listName
    }
}

/// Identifiers for EventKit occurrences. A recurring event's occurrences share one
/// `eventIdentifier`, so occurrences are addressed as "<eventIdentifier>#occurrence=<epoch seconds>".
public enum EventIdentifierCodec {
    static let marker = "#occurrence="

    public static func encode(eventIdentifier: String, occurrence: Date?) -> String {
        guard let occurrence else { return eventIdentifier }
        return eventIdentifier + marker + String(Int64(occurrence.timeIntervalSince1970.rounded()))
    }

    public static func decode(_ identifier: String) -> (eventIdentifier: String, occurrence: Date?) {
        guard let range = identifier.range(of: marker, options: .backwards),
              let seconds = Int64(identifier[range.upperBound...]) else {
            return (identifier, nil)
        }
        return (String(identifier[..<range.lowerBound]), Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}

/// `CalendarStore` + `ReminderStore` over one `EKEventStore`.
///
/// `@unchecked Sendable`: `store`, `lastAuthorization` and every EventKit object derived from the
/// store are only touched inside `queue` (serial), so there is no concurrent access; only value
/// types leave the queue.
public final class SystemEventKitStore: CalendarStore, ReminderStore, @unchecked Sendable {
    private let store: EKEventStore
    private let calendar: Calendar
    private let queue = DispatchQueue(label: "app.voiceagent.tools.eventkit", qos: .userInitiated)
    /// Authorization last seen by `store` (only read and written on `queue`).
    private var lastAuthorization: [EKAuthorizationStatus] = []

    /// - Parameter calendar: the user's calendar/time zone (all-day normalization, reminder dates).
    public init(calendar: Calendar = .autoupdatingCurrent) {
        store = EKEventStore()
        self.calendar = calendar
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable (EKEventStore, Calendar) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                // A store created before access was granted can keep serving stale (empty) data.
                let authorization = [EKEventStore.authorizationStatus(for: .event), EKEventStore.authorizationStatus(for: .reminder)]
                if authorization != self.lastAuthorization {
                    if !self.lastAuthorization.isEmpty { self.store.reset() }
                    self.lastAuthorization = authorization
                }
                do {
                    continuation.resume(returning: try work(self.store, self.calendar))
                } catch let error as ToolAdapterError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: Self.adapterError(error))
                }
            }
        }
    }

    static func adapterError(_ error: any Error) -> ToolAdapterError {
        guard let eventKitError = error as? EKError else { return .systemFailure }
        switch eventKitError.code {
        case .eventStoreNotAuthorized: return .permissionDenied
        case .calendarReadOnly, .calendarDoesNotAllowEvents, .calendarDoesNotAllowReminders, .calendarIsImmutable:
            return .readOnly
        case .noCalendar, .sourceDoesNotAllowCalendarAddDelete: return .noDefaultCalendar
        case .noStartDate, .noEndDate, .datesInverted, .durationGreaterThanRecurrence: return .invalidArgument
        case .objectBelongsToDifferentStore, .invalidEntityType, .eventNotMutable: return .readOnly
        default: return .systemFailure
        }
    }

    // MARK: Mapping

    static func reference(from event: EKEvent, calendar: Calendar) -> EventReference? {
        guard let baseIdentifier = event.eventIdentifier, let start = event.startDate, let end = event.endDate else {
            return nil
        }
        let identifier = EventIdentifierCodec.encode(
            eventIdentifier: baseIdentifier,
            occurrence: event.hasRecurrenceRules ? event.occurrenceDate : nil
        )
        var startDate = start
        var endDate = end
        if event.isAllDay {
            // EventKit reports all-day events as [00:00, 23:59:59]; normalize to half-open days.
            startDate = calendar.startOfDay(for: start)
            let lastDay = calendar.startOfDay(for: max(start, end.addingTimeInterval(-1)))
            endDate = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? startDate.addingTimeInterval(86_400)
        }
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EventReference(
            eventIdentifier: identifier,
            title: event.title ?? "",
            startDate: startDate,
            endDate: endDate,
            isAllDay: event.isAllDay,
            location: (location?.isEmpty ?? true) ? nil : location
        )
    }

    /// EventKit stores an all-day event's end as the last second of its last day.
    static func eventKitEnd(forAllDayEnd end: Date, start: Date) -> Date {
        max(start, end.addingTimeInterval(-1))
    }

    private static func isMidnight(_ date: Date, calendar: Calendar) -> Bool {
        calendar.startOfDay(for: date) == date
    }

    private static func findEvent(_ identifier: String, store: EKEventStore) -> EKEvent? {
        let (base, occurrence) = EventIdentifierCodec.decode(identifier)
        guard let occurrence else { return store.event(withIdentifier: base) }
        let window = store.predicateForEvents(
            withStart: occurrence.addingTimeInterval(-36 * 3600),
            end: occurrence.addingTimeInterval(36 * 3600),
            calendars: nil
        )
        return store.events(matching: window).first { event in
            guard event.eventIdentifier == base else { return false }
            let anchor = event.occurrenceDate ?? event.startDate ?? .distantPast
            return abs(anchor.timeIntervalSince(occurrence)) < 1
        }
    }

    // MARK: CalendarStore

    public func events(in interval: DateInterval) async throws -> [EventReference] {
        try await perform { store, calendar in
            let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
            return store.events(matching: predicate).compactMap { Self.reference(from: $0, calendar: calendar) }
        }
    }

    public func event(identifier: String) async throws -> EventReference? {
        try await perform { store, calendar in
            Self.findEvent(identifier, store: store).flatMap { Self.reference(from: $0, calendar: calendar) }
        }
    }

    public func createEvent(_ draft: EventDraft) async throws -> EventReference {
        try await perform { store, calendar in
            guard let target = store.defaultCalendarForNewEvents else { throw ToolAdapterError.noDefaultCalendar }
            let event = EKEvent(eventStore: store)
            event.calendar = target
            event.title = draft.title
            event.isAllDay = draft.isAllDay
            event.startDate = draft.startDate
            event.endDate = draft.isAllDay
                ? Self.eventKitEnd(forAllDayEnd: draft.endDate, start: draft.startDate)
                : draft.endDate
            event.location = draft.location
            try store.save(event, span: .thisEvent, commit: true)
            guard let reference = Self.reference(from: event, calendar: calendar) else {
                throw ToolAdapterError.systemFailure
            }
            return reference
        }
    }

    public func updateEvent(identifier: String, changes: EventChanges) async throws -> EventReference {
        try await perform { store, calendar in
            guard let event = Self.findEvent(identifier, store: store) else { throw ToolAdapterError.notFound }
            guard event.calendar?.allowsContentModifications ?? false else { throw ToolAdapterError.readOnly }
            if let title = changes.newTitle { event.title = title }
            if let location = changes.newLocation { event.location = location }
            // A clock time on an all-day event turns it into a timed event.
            if event.isAllDay {
                let timedStart = changes.newStartDate.map { !Self.isMidnight($0, calendar: calendar) } ?? false
                let timedEnd = changes.newEndDate.map { !Self.isMidnight($0, calendar: calendar) } ?? false
                if timedStart || timedEnd { event.isAllDay = false }
            }
            if let start = changes.newStartDate { event.startDate = start }
            if let end = changes.newEndDate {
                event.endDate = event.isAllDay
                    ? Self.eventKitEnd(forAllDayEnd: end, start: event.startDate ?? end)
                    : end
            }
            try store.save(event, span: .thisEvent, commit: true)
            guard let reference = Self.reference(from: event, calendar: calendar) else {
                throw ToolAdapterError.systemFailure
            }
            return reference
        }
    }

    // MARK: ReminderStore

    /// Date-only reminders get year/month/day components (floating, no alarm); timed reminders
    /// get hour/minute in the user's time zone plus an alarm at the due time.
    public func createReminder(_ draft: ReminderDraft) async throws -> String {
        try await perform { store, calendar in
            guard let list = store.defaultCalendarForNewReminders() else { throw ToolAdapterError.noDefaultCalendar }
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = list
            reminder.title = draft.title
            if let due = draft.dueDate {
                reminder.dueDateComponents = Self.dueComponents(for: due, hasTime: draft.dueHasTime, calendar: calendar)
                if draft.dueHasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
            }
            try store.save(reminder, commit: true)
            return reminder.calendarItemIdentifier
        }
    }

    /// Everything open, plus what was finished recently so a sync can mark it done.
    ///
    /// EventKit's predicate fetch is callback-based; it is bridged here the same way the rest of
    /// this adapter bridges the store, and only value types cross back.
    public func reminders(completedSince: Date?) async throws -> [ReminderReference] {
        let calendar = calendar
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let lists = self.store.calendars(for: .reminder)
                guard !lists.isEmpty else { return continuation.resume(returning: []) }
                let incomplete = self.store.predicateForIncompleteReminders(
                    withDueDateStarting: nil, ending: nil, calendars: lists
                )
                self.store.fetchReminders(matching: incomplete) { open in
                    let openReferences = (open ?? []).compactMap { Self.reference(from: $0, calendar: calendar) }
                    guard let completedSince else {
                        return continuation.resume(returning: openReferences)
                    }
                    let completed = self.store.predicateForCompletedReminders(
                        withCompletionDateStarting: completedSince, ending: nil, calendars: lists
                    )
                    self.store.fetchReminders(matching: completed) { done in
                        let doneReferences = (done ?? []).compactMap { Self.reference(from: $0, calendar: calendar) }
                        continuation.resume(returning: openReferences + doneReferences)
                    }
                }
            }
        }
    }

    static func reference(from reminder: EKReminder, calendar: Calendar) -> ReminderReference? {
        let title = reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        return ReminderReference(
            identifier: reminder.calendarItemIdentifier,
            title: title,
            dueDate: reminder.dueDateComponents.flatMap(calendar.date(from:)),
            isCompleted: reminder.isCompleted,
            listName: reminder.calendar?.title
        )
    }

    /// Due-date components: year/month/day only when `hasTime` is false.
    public static func dueComponents(for date: Date, hasTime: Bool, calendar: Calendar) -> DateComponents {
        if hasTime {
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            components.timeZone = calendar.timeZone
            return components
        }
        return calendar.dateComponents([.year, .month, .day], from: date)
    }
}
