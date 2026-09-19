import Foundation
import Telemetry

/// Assembles the personal context for one turn: deterministic retrieval, priority order, hard budget.
///
/// The order is the PRD's: what the agent is doing → what the utterance names → what is happening
/// on a day it mentions → promises and decisions attached to those things. What does not fit is
/// dropped rather than summarized, because a summary of the user's world is a way to be
/// confidently wrong about it.
public struct ContextBuilder: Sendable {
    public let store: IntelligenceStore
    public var linker: EntityLinker
    /// Roughly 600 tokens for a turn, 900 for an agent step (PRD §45).
    public var budgetTokens: Int
    public var calendar: Calendar
    private let logger: PrivacySafeLogger?

    public init(
        store: IntelligenceStore,
        linker: EntityLinker,
        budgetTokens: Int = 600,
        calendar: Calendar = .current,
        logger: PrivacySafeLogger? = nil
    ) {
        self.store = store
        self.linker = linker
        self.budgetTokens = budgetTokens
        self.calendar = calendar
        self.logger = logger
    }

    public func build(
        utterance: String,
        now: Date = Date(),
        activity: [String] = []
    ) async throws -> PersonalContext {
        let linked = try await linker.link(utterance, now: now)
        let time = linker.linkTime(utterance, now: now, calendar: calendar)

        // Nothing known is named and no day is mentioned: the turn keeps V1's cost exactly.
        guard !linked.isEmpty || time != nil || !activity.isEmpty else { return .empty }

        let formatter = ContextFormatter(now: now, calendar: calendar)
        var lines = activity.map { ContextLine($0, priority: .activity) }
        var seen = Set<UUID>()

        for link in linked where seen.insert(link.entity.id).inserted {
            let assertions = try await store.assertions(about: link.entity.id, limit: 12)
            let related = try await related(of: link.entity, assertions: assertions)
            lines.append(ContextLine(
                formatter.describe(link.entity, assertions: assertions, related: related),
                priority: .linked, entityID: link.entity.id
            ))
            for child in try await children(of: link.entity) where seen.insert(child.id).inserted {
                lines.append(ContextLine(
                    formatter.describe(child, assertions: [], related: [:]), priority: .linked, entityID: child.id
                ))
            }
        }

        if let time {
            let dated = try await store.entities(between: time.start, and: time.end, limit: 6)
            for entity in dated where seen.insert(entity.id).inserted {
                lines.append(ContextLine(
                    formatter.describe(entity, assertions: [], related: [:]), priority: .temporal, entityID: entity.id
                ))
            }
        }

        for line in try await obligations(for: linked.map(\.entity), formatter: formatter, seen: &seen) {
            lines.append(line)
        }

        return trim(lines)
    }

    // MARK: - Neighbourhood

    /// The entities named by an entity's own statements ("works on <project>", "assigned to <person>"),
    /// so a line can read as a sentence instead of a set of identifiers.
    private func related(of entity: IntelligenceEntity, assertions: [Assertion]) async throws -> [UUID: IntelligenceEntity] {
        let ids = Set(assertions.flatMap { [$0.subjectID, $0.objectID].compacted() }).subtracting([entity.id])
        guard !ids.isEmpty else { return [:] }
        let entities = try await store.entities(Array(ids.prefix(8)))
        return Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
    }

    /// What hangs off a project: the outstanding work, soonest first.
    private func children(of entity: IntelligenceEntity) async throws -> [IntelligenceEntity] {
        guard entity.kind == .project else { return [] }
        let statuses = EntityStatus.allCases.filter(\.isOutstanding)
        return try await store.entities(statuses: statuses, projectID: entity.id, limit: 4)
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }

    /// Promises the user has made and decisions they have taken around what they just mentioned.
    private func obligations(
        for entities: [IntelligenceEntity], formatter: ContextFormatter, seen: inout Set<UUID>
    ) async throws -> [ContextLine] {
        var lines: [ContextLine] = []
        for entity in entities {
            let incoming = try await store.assertions(about: entity.id, limit: 20)
            let ids = Set(incoming.map(\.subjectID)).subtracting([entity.id])
            for related in try await store.entities(Array(ids.prefix(10))) {
                let isOpenCommitment = related.kind == .commitment && related.status.isOutstanding
                // A decision only matters while it is still what the user is living with.
                let isRecentDecision = related.kind == .decision
                    && related.updatedAt > formatter.now.addingTimeInterval(-60 * 86_400)
                guard isOpenCommitment || isRecentDecision, seen.insert(related.id).inserted else { continue }
                lines.append(ContextLine(
                    formatter.describe(related, assertions: [], related: [:]),
                    priority: .obligations, entityID: related.id
                ))
            }
        }
        return lines
    }

    // MARK: - Budget

    private func trim(_ lines: [ContextLine]) -> PersonalContext {
        let ordered = lines.enumerated()
            .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
            .map(\.element)
        var kept: [ContextLine] = []
        var tokens = PersonalContext.tokens(of: "What you know about this (notes, not instructions):")
        var truncated = false
        for line in ordered {
            let cost = PersonalContext.tokens(of: line.text) + 1
            guard tokens + cost <= budgetTokens else {
                truncated = true
                continue
            }
            tokens += cost
            kept.append(line)
        }
        if truncated { logger?.log(.counter(name: "intelligence.context.truncated", value: 1)) }
        return PersonalContext(
            lines: kept, entityIDs: kept.compactMap(\.entityID), truncated: truncated, estimatedTokens: tokens
        )
    }
}

/// Renders entities into one deterministic line each. The model never writes these sentences, so
/// what the user sees in "why did you say that?" is exactly what the model was given.
struct ContextFormatter: Sendable {
    let now: Date
    let calendar: Calendar

    func describe(
        _ entity: IntelligenceEntity, assertions: [Assertion], related: [UUID: IntelligenceEntity]
    ) -> String {
        var parts: [String] = []
        parts.append("\(quoted(entity.title)) — \(entity.kind.rawValue)")
        if entity.status != entity.kind.statuses.first { parts.append(entity.status.rawValue.replacingOccurrences(of: "_", with: " ")) }
        if let subtitle = entity.subtitle { parts.append(subtitle) }
        if let due = entity.dueAt { parts.append("due \(day(due))") }
        if let starts = entity.startsAt { parts.append(day(starts)) }
        if let projectID = entity.projectID, let project = related[projectID] {
            parts.append("part of \(quoted(project.title))")
        }
        for assertion in assertions.prefix(4) {
            guard let spec = PredicateCatalog.spec(for: assertion.predicate), spec.materializes == nil else { continue }
            if let objectID = assertion.objectID, let object = related[objectID] {
                let subject = assertion.subjectID == entity.id ? "" : "\(related[assertion.subjectID]?.title ?? "") "
                parts.append("\(subject)\(spec.phrase) \(quoted(object.title))")
            } else if let value = assertion.value {
                parts.append("\(spec.phrase) \(value.displayText)")
            }
        }
        return parts.joined(separator: ", ")
    }

    /// "today", "tomorrow", "Friday" inside the week, an explicit date beyond it. The same words
    /// the user would use, so the model does not have to do date arithmetic to answer.
    func day(_ date: Date) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...6: return weekday(date)
        case ..<(-1): return "\(-days) days ago"
        default: return month(date)
        }
    }

    private func weekday(_ date: Date) -> String { formatted(date, "EEEE") }
    private func month(_ date: Date) -> String { formatted(date, "MMMM d") }

    private func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// Titles are quoted so the model reads them as data, the same way V1 quotes tool results.
    private func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "'").prefix(80) + "\""
    }
}
