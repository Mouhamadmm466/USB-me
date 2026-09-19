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
            if !report.isEmpty { knownNamesLoadedAt = .distantPast }
            return report
        } catch {
            logger?.log(.error(domain: "intelligence", code: "memory_extract"))
            return MemoryReport()
        }
    }

    /// Statements waiting on the user, for the Intelligence tab and the "one question at a time"
    /// prompt after a turn.
    public func pending(limit: Int = 20) async throws -> [Assertion] {
        try await store.pendingAssertions(limit: limit)
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
