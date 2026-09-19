import Foundation
import Telemetry

/// The one door the rest of the app uses into the user's personal intelligence.
///
/// Two jobs, and they run at different times: `context(for:)` before a turn (fast, deterministic,
/// usually empty), and `observe(turn:)` after it (background, may call the model). Keeping them
/// behind one actor means the coordinator never has to know about stores, linkers, validators or
/// policies — and that the learning switch can only be honoured in one place.
public actor PersonalIntelligence {
    public let store: IntelligenceStore
    public private(set) var settings: MemoryPolicySettings

    private let builder: ContextBuilder
    private let pipeline: MemoryPipeline
    private let extractor: any MemoryExtracting
    private let logger: PrivacySafeLogger?

    private let calendar: Calendar
    private var knownNames: Set<String> = []
    private var knownNamesLoadedAt: Date = .distantPast
    private static let knownNamesLifetime: TimeInterval = 120

    public init(
        store: IntelligenceStore,
        dates: any DatePhraseResolving,
        extractor: any MemoryExtracting = NoMemoryExtractor(),
        settings: MemoryPolicySettings = .default,
        budgetTokens: Int = 600,
        calendar: Calendar = .current,
        logger: PrivacySafeLogger? = nil
    ) {
        self.store = store
        self.settings = settings
        self.extractor = extractor
        self.logger = logger
        self.calendar = calendar
        let linker = EntityLinker(store: store, dates: dates)
        builder = ContextBuilder(
            store: store, linker: linker, budgetTokens: budgetTokens, calendar: calendar, logger: logger
        )
        pipeline = MemoryPipeline(
            store: store, validator: MemoryValidator(dates: dates),
            policy: MemoryPolicy(settings: settings), logger: logger
        )
    }

    /// Convenience for the app: the store at its default on-device location.
    public static func onDevice(
        dates: any DatePhraseResolving,
        extractor: any MemoryExtracting = NoMemoryExtractor(),
        settings: MemoryPolicySettings = .default,
        logger: PrivacySafeLogger? = nil
    ) throws -> PersonalIntelligence {
        PersonalIntelligence(
            store: try IntelligenceStore(url: try IntelligenceStore.defaultURL(), logger: logger),
            dates: dates, extractor: extractor, settings: settings, logger: logger
        )
    }

    public func update(settings: MemoryPolicySettings) {
        self.settings = settings
    }

    // MARK: - Before the turn

    /// What the model should know about the user's world for this utterance. Empty for anything
    /// that names nothing known, so the ordinary command path costs exactly what it did in V1.
    public func context(
        for utterance: String, now: Date = Date(), activity: [String] = []
    ) async throws -> PersonalContext {
        try await builder.build(utterance: utterance, now: now, activity: activity)
    }

    // MARK: - After the turn

    /// Decides whether the turn is worth extraction, runs it, and applies what survives.
    /// Returns an empty report when nothing was learned — the common case.
    @discardableResult
    public func observe(turn: MemoryTurn) async -> MemoryReport {
        guard settings.learningEnabled else { return MemoryReport() }
        let candidate = await filter().evaluate(userText: turn.userText, assistantText: turn.assistantText)
        guard candidate.isWorthwhile else {
            logger?.log(.counter(name: "intelligence.turn.skipped", value: 1))
            return MemoryReport()
        }
        do {
            let known = try await relevantEntities(for: turn)
            let proposals = try await extractor.propose(from: turn, known: known)
            guard !proposals.isEmpty else { return MemoryReport() }
            var pipeline = pipeline
            pipeline.policy = MemoryPolicy(settings: settings)
            let report = try await pipeline.apply(
                proposals,
                origin: .conversation(turnID: turn.turnID, excerpt: MemoryOrigin.excerpt(turn.userText)),
                now: turn.now
            )
            if !report.isEmpty {
                knownNamesLoadedAt = .distantPast
                // Everything learned shows up in Activity with its undo, so nothing changes silently.
                try? await store.record(report.all.map { $0.activityEntry(at: turn.now) })
            }
            return report
        } catch {
            logger?.log(.error(domain: "intelligence", code: "memory_extract"))
            return MemoryReport()
        }
    }

    /// Statements waiting on the user, rendered as questions for the Intelligence tab and for the
    /// "one question at a time" prompt after a turn.
    public func questions(limit: Int = 20, now: Date = Date()) async throws -> [PendingQuestion] {
        var questions: [PendingQuestion] = []
        for assertion in try await store.pendingAssertions(limit: limit) {
            guard let subject = try await store.entity(assertion.subjectID) else { continue }
            let object: IntelligenceEntity? = if let objectID = assertion.objectID { try await store.entity(objectID) } else { nil }
            let existing = try await store.activeAssertions(subjectID: assertion.subjectID, predicate: assertion.predicate)
                .first
            questions.append(PendingQuestion(
                assertion: assertion,
                sentence: StatementText.question(assertion, subject: subject, object: object, now: now, calendar: calendar),
                explanation: assertion.explanation(now: now, calendar: calendar),
                conflictsWith: existing.map {
                    StatementText.sentence($0, subject: subject, object: object, now: now, calendar: calendar)
                }
            ))
        }
        return questions
    }

    /// The user says yes to a question. Confirming an end applies the end; confirming a statement
    /// makes it count, with correction authority.
    public func confirm(_ assertionID: UUID, now: Date = Date()) async throws {
        guard let assertion = try await store.assertion(assertionID) else { return }
        let sentence = try await self.sentence(for: assertion, now: now)
        if assertion.state == .proposed {
            _ = try await store.confirm(assertionID, at: now)
        }
        try await store.record(ActivityEntry(
            kind: .confirmed, headline: sentence, detail: "You confirmed it.",
            entityID: assertion.subjectID, assertionID: assertionID, undo: .reject(assertionID, forgetting: []), createdAt: now
        ))
    }

    /// The user says no. The refusal is kept so the same guess is not made twice.
    public func reject(_ assertionID: UUID, now: Date = Date()) async throws {
        guard let assertion = try await store.assertion(assertionID) else { return }
        let sentence = try await self.sentence(for: assertion, now: now)
        try await store.reject(assertionID, at: now)
        try await store.record(ActivityEntry(
            kind: .corrected, headline: sentence, detail: "You said that isn't right.",
            entityID: assertion.subjectID, assertionID: assertionID, createdAt: now
        ))
    }

    /// Takes back something from the activity feed.
    @discardableResult
    public func undo(_ activityID: UUID, now: Date = Date()) async throws -> ActivityEntry? {
        let entry = try await store.undo(activityID, at: now)
        if entry != nil { knownNamesLoadedAt = .distantPast }
        return entry
    }

    private func sentence(for assertion: Assertion, now: Date) async throws -> String {
        guard let subject = try await store.entity(assertion.subjectID) else { return "" }
        let object: IntelligenceEntity? = if let objectID = assertion.objectID { try await store.entity(objectID) } else { nil }
        return StatementText.sentence(assertion, subject: subject, object: object, now: now, calendar: calendar)
    }

    // MARK: - Snapshots for the UI

    /// Everything Home shows, in one read.
    public func snapshot(now: Date = Date(), horizonDays: Int = 7) async throws -> IntelligenceSnapshot {
        var snapshot = IntelligenceSnapshot()
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now
        let horizon = calendar.date(byAdding: .day, value: horizonDays, to: startOfDay) ?? now

        snapshot.overdue = try await store.entities(between: .distantPast, and: startOfDay, limit: 20)
            .filter(\.status.isOutstanding)
        snapshot.today = try await store.entities(between: startOfDay, and: endOfDay, limit: 20)
            .filter(\.status.isOutstanding)
        snapshot.soon = try await store.entities(between: endOfDay, and: horizon, limit: 20)
            .filter(\.status.isOutstanding)
        snapshot.projects = try await projects(now: now)
        snapshot.questions = try await questions(limit: 5, now: now)
        snapshot.activity = try await store.activity(limit: 12)
        snapshot.counts = try await store.counts()
        return snapshot
    }

    /// The Projects tab: every live project with the few numbers that say how it is going.
    public func projects(now: Date = Date()) async throws -> [ProjectSummary] {
        var summaries: [ProjectSummary] = []
        for project in try await store.entities(kind: .project, limit: 50) {
            let work = try await store.entities(
                statuses: EntityStatus.allCases.filter(\.isOutstanding), projectID: project.id, limit: 100
            )
            let next = work.filter { $0.dueAt != nil }.min { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            let incoming = try await store.assertions(about: project.id, limit: 60)
            let neighbours = try await store.entities(Array(Set(incoming.map(\.subjectID)).prefix(40)))
            summaries.append(ProjectSummary(
                project: project,
                openWork: work.count { $0.kind == .task || $0.kind == .goal },
                nextDue: next?.dueAt,
                nextDueTitle: next?.title,
                people: neighbours.filter { $0.kind == .person && $0.id != IntelligenceIdentity.userEntityID },
                openCommitments: neighbours.count { $0.kind == .commitment && $0.status.isOutstanding }
            ))
        }
        return summaries.sorted { lhs, rhs in
            switch (lhs.nextDue, rhs.nextDue) {
            case let (left?, right?): left < right
            case (nil, _?): false
            case (_?, nil): true
            default: lhs.project.updatedAt > rhs.project.updatedAt
            }
        }
    }

    // MARK: - Private

    private func filter() async -> MemoryFilter {
        if Date().timeIntervalSince(knownNamesLoadedAt) > Self.knownNamesLifetime {
            knownNames = Set((try? await store.entities(limit: 400))?.flatMap(\.searchNames) ?? [])
            knownNamesLoadedAt = Date()
        }
        return MemoryFilter(knownNames: knownNames)
    }

    /// The entities the turn is about, so the extractor reuses the names already in the store
    /// instead of inventing a second spelling of the same person.
    private func relevantEntities(for turn: MemoryTurn) async throws -> [IntelligenceEntity] {
        let context = try await builder.build(utterance: turn.userText, now: turn.now)
        return try await store.entities(context.entityIDs)
    }
}

extension MemoryOrigin {
    /// The short quote kept with a memory: enough to recognize, never the whole turn.
    static func excerpt(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\n", with: " ").prefix(160))
    }
}
