import Foundation
import Telemetry

/// Why something is being raised. Closed vocabulary: the reason is shown to the user, counted in
/// telemetry, and never invented by the model.
public enum AttentionKind: String, CaseIterable, Sendable, Codable, Hashable, SafeLabelConvertible {
    /// A promise or a piece of work whose date has passed.
    case overdue
    /// Due or starting today.
    case today
    /// A promise to someone else that has not moved.
    case promise
    /// A deadline coming up with nothing outstanding attached to it.
    case unstarted
    /// A goal or project with a date approaching.
    case approaching
    /// Something the system wants to keep but has not been told it may.
    case question
    /// Live work that nothing has touched in a while.
    case stale

    public var displayName: String {
        switch self {
        case .overdue: "Late"
        case .today: "Today"
        case .promise: "You promised"
        case .unstarted: "Not started"
        case .approaching: "Coming up"
        case .question: "Check with you"
        case .stale: "Gone quiet"
        }
    }
}

/// One thing worth the user's attention, with the reason it is being raised.
public struct AttentionItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var kind: AttentionKind
    public var title: String
    /// One deterministic sentence: "due yesterday", "you promised Sarah, nothing since Tuesday".
    public var reason: String
    /// 0…1. Used only for ordering; the reason is what the user reads.
    public var urgency: Double
    public var entityID: UUID?
    public var assertionID: UUID?
    public var when: Date?

    public init(
        id: UUID = UUID(),
        kind: AttentionKind,
        title: String,
        reason: String,
        urgency: Double,
        entityID: UUID? = nil,
        assertionID: UUID? = nil,
        when: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.reason = reason
        self.urgency = urgency
        self.entityID = entityID
        self.assertionID = assertionID
        self.when = when
    }

    /// The line the assistant would say about it: "Send Sarah the deck — due yesterday."
    public var spokenLine: String { "\(title) — \(reason)" }
}

/// Decides what needs the user's attention, from what is already known.
///
/// Entirely deterministic: dates, statuses and relationships, scored by rules that can be read and
/// argued with. Nothing here asks the model, because "what should I worry about?" is the last
/// question a 4B model should be answering on its own — and because the user deserves a reason
/// they can check rather than a ranking they cannot.
public struct AttentionEngine: Sendable {
    public let store: IntelligenceStore
    public var calendar: Calendar
    /// How far ahead to look for what is coming.
    public var horizonDays: Int
    /// Live work untouched for this long has gone quiet.
    public var staleDays: Int

    public init(
        store: IntelligenceStore,
        calendar: Calendar = .current,
        horizonDays: Int = 7,
        staleDays: Int = 14
    ) {
        self.store = store
        self.calendar = calendar
        self.horizonDays = horizonDays
        self.staleDays = staleDays
    }

    public func items(now: Date = Date(), limit: Int = 8) async throws -> [AttentionItem] {
        let formatter = ContextFormatter(now: now, calendar: calendar)
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now
        let horizon = calendar.date(byAdding: .day, value: horizonDays, to: startOfDay) ?? now
        let stale = calendar.date(byAdding: .day, value: -staleDays, to: now) ?? now

        var items: [AttentionItem] = []
        var seen = Set<UUID>()

        // 1. Late. Nothing outranks something the user has already missed.
        for entity in try await store.entities(between: .distantPast, and: startOfDay, limit: 20)
        where entity.status.isOutstanding && seen.insert(entity.id).inserted {
            let days = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: entity.dueAt ?? entity.startsAt ?? now), to: startOfDay
            ).day ?? 0
            items.append(AttentionItem(
                id: entity.id, kind: entity.kind == .commitment ? .promise : .overdue,
                title: entity.title,
                reason: entity.kind == .commitment
                    ? "you promised this, \(formatter.day(entity.dueAt ?? now))"
                    : "due \(formatter.day(entity.dueAt ?? entity.startsAt ?? now))",
                urgency: min(1, 0.8 + Double(days) * 0.02),
                entityID: entity.id, when: entity.dueAt ?? entity.startsAt
            ))
        }

        // 2. Today.
        for entity in try await store.entities(between: startOfDay, and: endOfDay, limit: 20)
        where entity.status.isOutstanding && seen.insert(entity.id).inserted {
            let time = entity.startsAt.map { formatter.day($0) } ?? "today"
            items.append(AttentionItem(
                id: entity.id, kind: .today, title: entity.title,
                reason: entity.dueAt != nil ? "due today" : "starts \(time)",
                urgency: 0.7, entityID: entity.id, when: entity.dueAt ?? entity.startsAt
            ))
        }

        // 3. Coming up, and whether anything is actually happening about it.
        for entity in try await store.entities(between: endOfDay, and: horizon, limit: 20)
        where entity.status.isOutstanding && seen.insert(entity.id).inserted {
            let hasWork = try await hasOutstandingWork(entity)
            let day = formatter.day(entity.dueAt ?? entity.startsAt ?? now)
            items.append(AttentionItem(
                id: entity.id,
                kind: hasWork ? .approaching : .unstarted,
                title: entity.title,
                reason: hasWork ? "due \(day)" : "due \(day), nothing started",
                urgency: hasWork ? 0.45 : 0.6,
                entityID: entity.id, when: entity.dueAt ?? entity.startsAt
            ))
        }

        // 4. Promises with no date at all: they are the easiest thing to lose.
        for entity in try await store.entities(kind: .commitment, limit: 20)
        where entity.status.isOutstanding && entity.dueAt == nil && seen.insert(entity.id).inserted {
            let owed = try await owedTo(entity)
            items.append(AttentionItem(
                id: entity.id, kind: .promise, title: entity.title,
                reason: owed.map { "you promised \($0), no date on it" } ?? "you promised this, no date on it",
                urgency: 0.5, entityID: entity.id
            ))
        }

        // 5. Questions the system is holding. One is a nudge; five is a pile.
        for question in try await store.pendingAssertions(limit: 3) {
            guard let subject = try await store.entity(question.subjectID) else { continue }
            let object: IntelligenceEntity? = if let objectID = question.objectID {
                try await store.entity(objectID)
            } else { nil }
            items.append(AttentionItem(
                id: question.id, kind: .question,
                title: StatementText.question(question, subject: subject, object: object, now: now, calendar: calendar),
                reason: question.explanation(now: now, calendar: calendar),
                urgency: 0.35, entityID: subject.id, assertionID: question.id
            ))
        }

        // 6. Live work nothing has touched.
        for entity in try await store.entities(kind: .project, limit: 30)
        where entity.status.isOutstanding && entity.updatedAt < stale && seen.insert(entity.id).inserted {
            let days = calendar.dateComponents([.day], from: entity.updatedAt, to: now).day ?? staleDays
            items.append(AttentionItem(
                id: entity.id, kind: .stale, title: entity.title,
                reason: "nothing on this for \(days) days",
                urgency: 0.25, entityID: entity.id
            ))
        }

        return Array(
            items.sorted {
                $0.urgency != $1.urgency
                    ? $0.urgency > $1.urgency
                    : ($0.when ?? .distantFuture) < ($1.when ?? .distantFuture)
            }.prefix(limit)
        )
    }

    /// One sentence for "what needs my attention?", built from the items themselves.
    public func summary(_ items: [AttentionItem]) -> String {
        guard let first = items.first else { return "Nothing needs you right now." }
        let late = items.count { $0.kind == .overdue || $0.kind == .promise && $0.urgency >= 0.8 }
        var sentence = first.spokenLine + "."
        if items.count > 1 {
            let rest = items.count - 1
            sentence += late > 1
                ? " \(late - 1) other late \(late - 1 == 1 ? "thing" : "things"), and \(rest - (late - 1)) more."
                : " And \(rest) more."
        }
        return sentence
    }

    // MARK: Rules

    private func hasOutstandingWork(_ entity: IntelligenceEntity) async throws -> Bool {
        guard entity.kind == .project || entity.kind == .goal else { return true }
        let children = try await store.entities(
            statuses: EntityStatus.allCases.filter(\.isOutstanding), projectID: entity.id, limit: 5
        )
        if !children.isEmpty { return true }
        // A goal with tasks hanging off it counts as started, whichever way they are linked.
        let incoming = try await store.assertions(about: entity.id, limit: 20)
        let related = try await store.entities(Array(Set(incoming.map(\.subjectID)).prefix(10)))
        return related.contains { [EntityKind.task, .commitment].contains($0.kind) && $0.status.isOutstanding }
    }

    private func owedTo(_ commitment: IntelligenceEntity) async throws -> String? {
        let assertions = try await store.activeAssertions(subjectID: commitment.id, predicate: .owedTo)
        guard let objectID = assertions.first?.objectID else { return nil }
        return try await store.entity(objectID)?.title
    }
}
