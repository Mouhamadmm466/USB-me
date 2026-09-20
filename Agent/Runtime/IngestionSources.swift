import Core
import Foundation
import Intelligence
import Permissions
import Telemetry
import Tools

/// Reads one source the user has authorized and describes what it found.
public protocol IngestionSource: Sendable {
    var sourceType: SourceType { get }
    /// True when the user has both switched this on and granted the permission it needs.
    func isEnabled(policy: IngestionPolicy) -> Bool
    var permission: PermissionKind { get }
    func items(now: Date) async throws -> [IngestedItem]
    /// Whether a sync may remove what this source no longer has. True for a full window read,
    /// false for anything partial — pruning on a partial read would delete the user's week.
    var prunes: Bool { get }
}

/// The user's calendar, in a window around today.
public struct CalendarIngestionSource: IngestionSource {
    public let sourceType = SourceType.calendar
    public let permission = PermissionKind.calendar
    public let prunes = true

    private let store: any CalendarStore
    private let calendar: Calendar
    private let policy: IngestionPolicy

    public init(store: any CalendarStore, policy: IngestionPolicy, calendar: Calendar = .autoupdatingCurrent) {
        self.store = store
        self.policy = policy
        self.calendar = calendar
    }

    public func isEnabled(policy: IngestionPolicy) -> Bool { policy.calendar }

    public func items(now: Date) async throws -> [IngestedItem] {
        let start = calendar.date(byAdding: .day, value: -policy.daysBack, to: now) ?? now
        let end = calendar.date(byAdding: .day, value: policy.daysForward, to: now) ?? now
        let events = try await store.events(in: DateInterval(start: start, end: end))
        return events.map { event in
            IngestedItem(
                sourceType: .calendar,
                sourceID: event.eventIdentifier,
                kind: .event,
                title: event.title,
                startsAt: event.startDate,
                endsAt: event.endDate,
                // An event that has already finished is not something to be reminded about.
                status: event.endDate < now ? .completed : .scheduled,
                location: event.location,
                // The title is the only place a person's name reliably appears; attendee lists are
                // often addresses, and an address is not someone the user knows.
                mentions: Self.names(in: event.title)
            )
        }
    }

    /// Capitalised words in a title, as candidate names. They are only ever *matched* against
    /// people the user already has, so a false candidate costs nothing.
    static func names(in title: String) -> [String] {
        title
            .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
            .map(String.init)
            .filter { word in
                guard let first = word.first, first.isUppercase, word.count >= 3 else { return false }
                return !commonTitleWords.contains(word.lowercased())
            }
    }

    private static let commonTitleWords: Set<String> = [
        "meeting", "call", "sync", "review", "standup", "stand-up", "lunch", "dinner", "coffee",
        "appointment", "class", "lecture", "interview", "session", "check-in", "catch", "weekly",
        "monthly", "daily", "team", "project", "planning", "retro", "demo", "office", "hours",
    ]
}

/// The user's reminders: what is open, and what was finished recently.
public struct ReminderIngestionSource: IngestionSource {
    public let sourceType = SourceType.reminders
    public let permission = PermissionKind.reminders
    /// Completed reminders age out of the fetch window, so a missing one is not evidence it was
    /// deleted — pruning here would quietly remove the user's finished work.
    public let prunes = false

    private let store: any ReminderStore
    private let calendar: Calendar
    private let policy: IngestionPolicy

    public init(store: any ReminderStore, policy: IngestionPolicy, calendar: Calendar = .autoupdatingCurrent) {
        self.store = store
        self.policy = policy
        self.calendar = calendar
    }

    public func isEnabled(policy: IngestionPolicy) -> Bool { policy.reminders }

    public func items(now: Date) async throws -> [IngestedItem] {
        let since = calendar.date(byAdding: .day, value: -policy.daysBack, to: now)
        return try await store.reminders(completedSince: since).map { reminder in
            IngestedItem(
                sourceType: .reminders,
                sourceID: reminder.identifier,
                kind: .task,
                title: reminder.title,
                dueAt: reminder.dueDate,
                status: reminder.isCompleted ? .done : .open,
                mentions: CalendarIngestionSource.names(in: reminder.title)
            )
        }
    }
}

/// Runs the sources the user has switched on, and leaves one line in Activity per sync.
///
/// Called on launch and when the app comes forward — often enough that the user's week is current,
/// rarely enough that it costs nothing. Everything it writes is an observation, which is to say:
/// outranked by anything the user says themselves.
public struct IngestionRunner: Sendable {
    public let store: IntelligenceStore
    public let sources: [any IngestionSource]
    private let permissions: any PermissionProviding
    private let logger: PrivacySafeLogger?

    public init(
        store: IntelligenceStore,
        sources: [any IngestionSource],
        permissions: any PermissionProviding,
        logger: PrivacySafeLogger? = nil
    ) {
        self.store = store
        self.sources = sources
        self.permissions = permissions
        self.logger = logger
    }

    @discardableResult
    public func sync(policy: IngestionPolicy, now: Date = Date()) async -> [SourceType: IngestionReport] {
        var reports: [SourceType: IngestionReport] = [:]
        for source in sources where source.isEnabled(policy: policy) {
            // A source the user switched on but has not granted is simply not read; asking for a
            // permission in the background is how apps get denied for good.
            guard PermissionManager.isUsable(await permissions.status(for: source.permission), for: source.permission)
            else { continue }

            do {
                let items = try await source.items(now: now)
                let report = try await store.ingest(
                    items, source: source.sourceType, prune: source.prunes, now: now
                )
                reports[source.sourceType] = report
                if let line = report.line(for: source.sourceType) {
                    try? await store.record(ActivityEntry(
                        kind: .imported,
                        headline: line,
                        detail: source.sourceType == .calendar ? "from your calendar" : "from your reminders",
                        createdAt: now
                    ))
                }
            } catch {
                logger?.log(.error(domain: "ingestion", code: SafeLabel(source.sourceType)))
            }
        }
        return reports
    }
}
