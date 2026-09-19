import AgentEval
import Core
import Foundation
import Intelligence
import LLM
import Permissions
import Testing
import Tools
@testable import Agent

/// The whole V2 path in one place: a request the model reads as a job, a plan the user sees before
/// anything happens, and only then a job that runs and produces something.
@MainActor
@Suite struct JobTurnTests {
    private static let now = ISO8601DateFormatter().date(from: "2026-09-19T14:00:00Z")!

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    /// The model answers three different contracts in this test: the turn, the plan and the
    /// artifact. Which one it is asked for is visible in the request itself.
    private func makeModel() -> ScriptedLanguageModel {
        ScriptedLanguageModel { request in
            if request.suffix.contains("Capabilities:") {
                return #"{"title":"Midterm study plan","steps":[{"do":"search_knowledge","why":"Find what the midterm covers","arguments":{"query":"midterm"}},{"do":"write_artifact","why":"Write the plan","arguments":{"title":"Midterm study plan","kind":"plan","about":"what to study before the midterm"}}]}"#
            }
            if request.suffix.contains("Document:") {
                return #"{"sections":["Be ready for eigenvalues and diagonalization.","Two hours a day until the fourth Friday.","Don't leave the practice set to the last night."]}"#
            }
            return #"{"type":"task","outcome":"a study plan for the midterm"}"#
        }
    }

    private func makeCoordinator(
        model: ScriptedLanguageModel
    ) async throws -> (AgentCoordinator, IntelligenceStore, PersonalIntelligence) {
        let store = try IntelligenceStore()
        let intelligence = PersonalIntelligence(
            store: store, dates: IntelligenceDateResolver(calendar: Self.calendar), calendar: Self.calendar
        )
        _ = try await intelligence.importDocument(
            data: Data("""
            # Midterm
            The midterm is on the fourth Friday and covers eigenvalues and diagonalization.
            """.utf8),
            fileName: "Syllabus.md", origin: .files, now: Self.now
        )

        let clock = AgentClock.fixed(Self.now, timeZone: TimeZone(identifier: "America/New_York")!)
        let writer = LanguageModelArtifactWriter(model: model, store: store, calendar: Self.calendar)
        let runtime = AgentRuntime(
            store: store,
            executors: [IntelligenceStepExecutor(intelligence: intelligence, artifacts: writer)],
            clock: clock,
            thermal: { .nominal }
        )
        let jobs = JobService(store: store, planner: Planner(model: model), runtime: runtime)
        let coordinator = AgentCoordinator(dependencies: AgentDependencies(
            languageModel: model,
            resolver: StubResolver { _, _ in .resolved(.getCalendarEvents(DateRange(
                start: clock.now(), end: clock.now().addingTimeInterval(86_400), spokenDescription: "tomorrow"
            ))) },
            executor: RecordingExecutor(clock: clock),
            permissions: PermissionManager(backend: FakePermissionBackend.allGranted()),
            speech: RecordingSpeech(),
            intelligence: intelligence,
            jobs: jobs,
            clock: clock
        ))
        return (coordinator, store, intelligence)
    }

    @Test func aJobIsPlannedAndShownBeforeAnythingHappens() async throws {
        let model = makeModel()
        let (coordinator, store, _) = try await makeCoordinator(model: model)

        let report = await coordinator.handle(.typed("what does the syllabus say about the midterm, and make me a study plan"))

        #expect(report.outcome == .confirmationRequested)
        let card = try #require(coordinator.presentation.jobCard)
        #expect(card.title == "Midterm study plan")
        #expect(card.isAwaitingApproval)
        #expect(card.steps.map(\.summary) == ["Find what the midterm covers", "Write the plan"])
        #expect(card.steps.allSatisfy { $0.state == .proposed })
        // The user was asked, not told.
        #expect(report.spokenText.contains("Want me to go ahead?"))
        // Nothing ran: no artifact, and the plan is stored as a proposal.
        #expect(try await store.artifacts().isEmpty)
        #expect(try await store.plan(card.id)?.state == .proposed)
    }

    @Test func approvingItRunsTheStepsAndProducesSomethingToRead() async throws {
        let model = makeModel()
        let (coordinator, store, _) = try await makeCoordinator(model: model)
        _ = await coordinator.handle(.typed("what does the syllabus say about the midterm, and make me a study plan"))
        let card = try #require(coordinator.presentation.jobCard)

        let report = await coordinator.approveJob(id: card.id)

        #expect(report.outcome == .executed)
        #expect(report.plan?.state == .completed)
        let finished = try #require(coordinator.presentation.jobCard)
        #expect(finished.state == .completed)
        #expect(finished.steps.allSatisfy { $0.state == .completed })

        let artifact = try #require(try await store.artifacts().first)
        #expect(artifact.title == "Midterm study plan")
        #expect(artifact.markdown.contains("eigenvalues"))
        #expect(artifact.markdown.contains("## Sources"))
        #expect(finished.artifactID == artifact.id)
        // What the user hears is built from what actually happened.
        #expect(report.spokenText.contains("Midterm study plan"))
    }

    @Test func decliningLeavesNothingBehind() async throws {
        let model = makeModel()
        let (coordinator, store, _) = try await makeCoordinator(model: model)
        _ = await coordinator.handle(.typed("make me a study plan for the midterm"))
        let card = try #require(coordinator.presentation.jobCard)

        let report = await coordinator.cancelJob(id: card.id)
        #expect(report.outcome == .cancelled)
        #expect(coordinator.presentation.jobCard == nil)
        #expect(try await store.artifacts().isEmpty)
        #expect(try await store.plan(card.id)?.state == .cancelled)
    }

    @Test func anOrdinaryCommandStillTakesTheV1PathWithNoJob() async throws {
        let model = ScriptedLanguageModel([
            "what's on my calendar tomorrow": #"{"type":"proposed_action","tool":"get_calendar_events","arguments":{"when":"tomorrow"},"requires_confirmation":false}"#,
        ])
        let (coordinator, store, _) = try await makeCoordinator(model: model)

        let report = await coordinator.handle(.typed("what's on my calendar tomorrow"))
        #expect(coordinator.presentation.jobCard == nil)
        #expect(report.plan == nil)
        #expect(try await store.plans().isEmpty)
        #expect(report.outcome != .confirmationRequested)
    }

    @Test func aJobCannotReachTheOutsideWorldUnlessItWasAskedFor() async throws {
        let model = makeModel()
        let (coordinator, _, _) = try await makeCoordinator(model: model)
        _ = await coordinator.handle(.typed("look up what the syllabus says about the midterm"))
        let card = try #require(coordinator.presentation.jobCard)

        // The prompt the planner saw offered no way to message or call anybody.
        let plannerRequest = try #require(model.requests.first { $0.suffix.contains("Capabilities:") })
        #expect(!plannerRequest.suffix.contains("compose_message"))
        #expect(!plannerRequest.suffix.contains("initiate_call"))
        #expect(!plannerRequest.grammar!.contains("compose_message"))
        #expect(card.steps.allSatisfy { !$0.needsConfirmation })
    }
}
