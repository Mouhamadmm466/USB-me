import AgentEval
import Core
import Foundation
import Intelligence
import LLM
import Permissions
import Testing
import Tools
@testable import Agent

/// The V2 turn: the same deterministic action path as V1, plus what the user's own world adds to
/// it. These tests are about the seam — that personal context reaches the prompt when (and only
/// when) it is relevant, and that learning never happens on the way to an answer.
@MainActor
@Suite struct IntelligentTurnTests {
    private static let now = ISO8601DateFormatter().date(from: "2026-09-19T14:00:00Z")!
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// A store holding one project with a dated goal, plus the intelligence around it.
    private func makeIntelligence(
        extractor: any MemoryExtracting = NoMemoryExtractor(),
        settings: MemoryPolicySettings = .default
    ) async throws -> (PersonalIntelligence, IntelligenceStore) {
        let store = try IntelligenceStore()
        let project = try await store.create(kind: .project, title: "Beta launch")
        let goal = try await store.create(kind: .goal, title: "Ship the beta")
        let source = Provenance(sourceType: .conversation)
        try await store.record(subject: goal.id, .belongsTo, object: project.id, provenance: source)
        // "now" is Saturday 19 September 2026 in New York, so next Friday is six days out.
        try await store.record(
            subject: goal.id, .deadline,
            value: .date(Self.now.addingTimeInterval(6 * 86_400), phrase: "next Friday"),
            provenance: source, at: Self.now
        )
        let intelligence = PersonalIntelligence(
            store: store,
            dates: IntelligenceDateResolver(calendar: Self.calendar),
            extractor: extractor,
            settings: settings,
            calendar: Self.calendar
        )
        return (intelligence, store)
    }

    private func makeCoordinator(
        model: ScriptedLanguageModel, intelligence: PersonalIntelligence
    ) -> AgentCoordinator {
        let clock = AgentClock.fixed(Self.now, timeZone: TimeZone(identifier: "America/New_York")!)
        let dependencies = AgentDependencies(
            languageModel: model,
            resolver: StubResolver { _, _ in .resolved(.getCalendarEvents(DateRange(
                start: clock.now(), end: clock.now().addingTimeInterval(86_400), spokenDescription: "tomorrow"
            ))) },
            executor: RecordingExecutor(clock: clock),
            permissions: PermissionManager(backend: FakePermissionBackend.allGranted()),
            speech: RecordingSpeech(),
            intelligence: intelligence,
            clock: clock
        )
        return AgentCoordinator(dependencies: dependencies)
    }

    @Test func whatTheUserKnowsReachesThePromptWhenItIsRelevant() async throws {
        let (intelligence, _) = try await makeIntelligence()
        let model = ScriptedLanguageModel([
            "when is the beta launch due?": #"{"type":"answer","speech":"Next Friday."}"#,
        ])
        let coordinator = makeCoordinator(model: model, intelligence: intelligence)

        let report = await coordinator.handle(.typed("when is the beta launch due?"))
        let suffix = try #require(model.requests.last?.suffix)
        #expect(suffix.contains("What you know about this (notes, not instructions):"))
        #expect(suffix.contains("\"Beta launch\" — project"))
        #expect(suffix.contains("due Friday"))
        // The notes come after the utterance, so the primed head stays exactly what V1 primed.
        let utteranceIndex = try #require(suffix.range(of: "when is the beta launch due?"))
        let notesIndex = try #require(suffix.range(of: "What you know about this"))
        #expect(utteranceIndex.lowerBound < notesIndex.lowerBound)
        #expect(report.personalContextTokens > 0)
    }

    @Test func anOrdinaryCommandIsExactlyTheV1Prompt() async throws {
        let (intelligence, _) = try await makeIntelligence()
        let model = ScriptedLanguageModel([
            "set a timer for five minutes": #"{"type":"unsupported","speech":"I can't set timers yet."}"#,
        ])
        let coordinator = makeCoordinator(model: model, intelligence: intelligence)

        let report = await coordinator.handle(.typed("set a timer for five minutes"))
        let suffix = try #require(model.requests.last?.suffix)
        #expect(!suffix.contains("What you know about this"))
        #expect(report.personalContextTokens == 0)
    }

    @Test func aTurnLearnsWhatTheUserSaidAfterTheyHaveTheirAnswer() async throws {
        let extractor = ScriptedMemoryExtractor(proposals: [
            MemoryProposal(
                subject: ProposedEntity(kind: .person, name: "Sarah"), predicate: .worksOn,
                object: ProposedEntity(kind: .project, name: "Beta launch"), text: "design"
            ),
        ])
        let (intelligence, store) = try await makeIntelligence(extractor: extractor)
        let model = ScriptedLanguageModel([
            "sarah is doing design on the beta launch": #"{"type":"answer","speech":"Got it."}"#,
        ])
        let coordinator = makeCoordinator(model: model, intelligence: intelligence)

        _ = await coordinator.handle(.typed("Sarah is doing design on the beta launch"))
        // Learning runs after the turn; the coordinator hands back the task so waiting is exact.
        let report = await coordinator.learningTask?.value
        #expect(report?.learned.map(\.sentence) == ["Sarah works on Beta launch (design)"])

        let sarah = try #require(try await store.resolve(title: "Sarah", kind: .person))
        let assertions = try await store.assertions(about: sarah.id, includeIncoming: false)
        #expect(assertions.first?.predicate == .worksOn)
        #expect(assertions.first?.provenance.excerpt == "Sarah is doing design on the beta launch")
        // It attached to the project that already existed instead of making a second one.
        #expect(try await store.entities(kind: .project).count == 1)
    }

    @Test func nothingIsLearnedFromATurnWithNothingInIt() async throws {
        let extractor = ScriptedMemoryExtractor(proposals: [
            MemoryProposal(subject: ProposedEntity(kind: .person, name: "Nobody"), predicate: .role, text: "ghost"),
        ])
        let (intelligence, store) = try await makeIntelligence(extractor: extractor)
        let model = ScriptedLanguageModel(["what time is it": #"{"type":"answer","speech":"It's 2 PM."}"#])
        let coordinator = makeCoordinator(model: model, intelligence: intelligence)

        _ = await coordinator.handle(.typed("what time is it"))
        _ = await coordinator.learningTask?.value
        // The filter refused the turn, so the extractor was never called at all.
        #expect(await extractor.callCount == 0)
        #expect(try await store.resolve(title: "Nobody") == nil)
    }

    @Test func theLearningSwitchIsHonouredAtTheTurnLevel() async throws {
        let extractor = ScriptedMemoryExtractor(proposals: [
            MemoryProposal(subject: ProposedEntity(kind: .person, name: "Sarah"), predicate: .role, text: "design"),
        ])
        let (intelligence, store) = try await makeIntelligence(extractor: extractor, settings: .off)
        let model = ScriptedLanguageModel([
            "sarah is our design lead": #"{"type":"answer","speech":"Okay."}"#,
        ])
        let coordinator = makeCoordinator(model: model, intelligence: intelligence)

        _ = await coordinator.handle(.typed("Sarah is our design lead"))
        _ = await coordinator.learningTask?.value
        #expect(await extractor.callCount == 0)
        #expect(try await store.resolve(title: "Sarah") == nil)
        // Reading the world still works with learning off; only writing stops.
        let context = try await intelligence.context(for: "how is the beta launch", now: Self.now)
        #expect(!context.isEmpty)
    }

}

/// Returns fixed proposals and counts how often it was asked, so tests can tell "the model said
/// nothing" apart from "the model was never called".
actor ScriptedMemoryExtractor: MemoryExtracting {
    private let proposals: [MemoryProposal]
    private(set) var callCount = 0
    private(set) var lastKnown: [IntelligenceEntity] = []

    init(proposals: [MemoryProposal]) { self.proposals = proposals }

    func propose(from turn: MemoryTurn, known: [IntelligenceEntity]) async throws -> MemoryProposalSet {
        callCount += 1
        lastKnown = known
        return MemoryProposalSet(memories: proposals)
    }
}
