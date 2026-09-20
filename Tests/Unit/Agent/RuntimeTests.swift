import AgentEval
import Core
import Foundation
import Intelligence
import LLM
import Telemetry
import Testing
@testable import Agent

/// The runtime is where a plan stops being a proposal, so these tests are about what it refuses to
/// do, what it writes down, and what happens when a job cannot finish.
@Suite struct AgentRuntimeTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private var clock: AgentClock { .fixed(now, timeZone: TimeZone(identifier: "UTC")!) }

    private func makeWorld() async throws -> (IntelligenceStore, PersonalIntelligence) {
        let store = try IntelligenceStore()
        let intelligence = PersonalIntelligence(store: store, dates: IntelligenceDateResolver())
        _ = try await intelligence.importDocument(
            data: Data("""
            # Midterm
            The midterm is on the fourth Friday and covers eigenvalues and diagonalization.
            """.utf8),
            fileName: "Syllabus.md", origin: .files, now: now
        )
        return (store, intelligence)
    }

    private func makeRuntime(
        _ store: IntelligenceStore,
        executors: [any StepExecuting],
        limits: RuntimeLimits = RuntimeLimits(),
        thermal: @escaping @Sendable () -> ThermalState = { .nominal }
    ) -> AgentRuntime {
        AgentRuntime(store: store, executors: executors, limits: limits, clock: clock, thermal: thermal)
    }

    private func plan(_ steps: [(String, [String: String])], id: UUID = UUID()) -> Plan {
        var previous: UUID?
        var planSteps: [PlanStep] = []
        for (index, step) in steps.enumerated() {
            let planStep = PlanStep(
                planID: id, ordinal: index, capability: step.0, summary: "step \(index)",
                arguments: step.1, dependsOn: previous.map { [$0] } ?? []
            )
            previous = planStep.id
            planSteps.append(planStep)
        }
        return Plan(
            id: id, request: "what does the syllabus say about the midterm", title: "Midterm",
            state: .approved, scope: steps.map(\.0), steps: planSteps, stepBudget: max(steps.count, 1),
            createdAt: now, updatedAt: now
        )
    }

    @Test func aJobRunsItsStepsInOrderAndWritesDownWhatItFound() async throws {
        let (store, intelligence) = try await makeWorld()
        let runtime = makeRuntime(store, executors: [IntelligenceStepExecutor(intelligence: intelligence)])
        let plan = plan([
            ("search_knowledge", ["query": "midterm"]),
            ("search_intelligence", ["query": "midterm"]),
        ])
        try await store.save(plan)

        let finished = await runtime.run(plan)
        #expect(finished.state == .completed)
        #expect(finished.steps.allSatisfy { $0.state == .completed })
        #expect(finished.steps[0].observation?.contains("eigenvalues") == true)
        #expect(finished.finishedAt != nil)

        // Every step was checkpointed, so the job is readable after the fact.
        let stored = try #require(try await store.plan(plan.id))
        #expect(stored.state == .completed)
        #expect(stored.steps.compactMap(\.observation).count == 2)
        #expect(try await store.activity().first?.kind == .acted)
    }

    @Test func aStepThatNeedsTheUserStopsTheJobRatherThanGuessing() async throws {
        let (store, intelligence) = try await makeWorld()
        let runtime = makeRuntime(store, executors: [IntelligenceStepExecutor(intelligence: intelligence)])
        let plan = plan([
            ("ask_user", ["question": "Which class is this for?"]),
            ("search_knowledge", ["query": "midterm"]),
        ])
        try await store.save(plan)

        let finished = await runtime.run(plan)
        #expect(finished.state == .blocked)
        #expect(finished.blocker == .needsAnswer)
        #expect(finished.summary == "Which class is this for?")
        // The step after the question never ran.
        #expect(finished.steps[1].state == .proposed)
        #expect(finished.blocker?.isWaitingOnUser == true)
    }

    @Test func aBlockedJobPicksUpWhereItStopped() async throws {
        let (store, intelligence) = try await makeWorld()
        let runtime = makeRuntime(store, executors: [IntelligenceStepExecutor(intelligence: intelligence)])
        var plan = plan([
            ("search_knowledge", ["query": "midterm"]),
            ("search_intelligence", ["query": "midterm"]),
        ])
        // The first step already ran before the app went away.
        plan.steps[0].state = .completed
        plan.steps[0].observation = "Syllabus: the midterm is on the fourth Friday."
        plan.state = .blocked
        plan.blocker = .thermal
        try await store.save(plan)

        let resumed = try #require(await runtime.resume(plan.id))
        #expect(resumed.state == .completed)
        // The finished step was not run again.
        #expect(resumed.steps[0].observation == "Syllabus: the midterm is on the fourth Friday.")
        #expect(resumed.steps[1].state == .completed)
    }

    @Test func aCapabilityWithNoExecutorFailsTheJobInsteadOfBeingSkipped() async throws {
        let (store, intelligence) = try await makeWorld()
        let runtime = makeRuntime(store, executors: [IntelligenceStepExecutor(intelligence: intelligence)])
        let plan = plan([("compose_message", ["contact_query": "Sarah", "message": "hi"])])
        try await store.save(plan)

        let finished = await runtime.run(plan)
        #expect(finished.state == .failed)
        #expect(finished.blocker == .failed)
        #expect(finished.steps[0].state == .failed)
    }

    @Test func limitsStopAJobBeforeItRunsAway() async throws {
        let (store, intelligence) = try await makeWorld()
        let runtime = makeRuntime(
            store,
            executors: [IntelligenceStepExecutor(intelligence: intelligence)],
            limits: RuntimeLimits(maximumSteps: 1, wallClock: 120)
        )
        let plan = plan([
            ("search_knowledge", ["query": "midterm"]),
            ("search_knowledge", ["query": "grading"]),
        ])
        try await store.save(plan)

        let finished = await runtime.run(plan)
        #expect(finished.state == .blocked)
        #expect(finished.blocker == .limitReached)
        #expect(finished.completedSteps == 1)
    }

    @Test func aHotPhonePausesTheJob() async throws {
        let (store, intelligence) = try await makeWorld()
        let runtime = makeRuntime(
            store, executors: [IntelligenceStepExecutor(intelligence: intelligence)], thermal: { .critical }
        )
        let plan = plan([("search_knowledge", ["query": "midterm"])])
        try await store.save(plan)

        let finished = await runtime.run(plan)
        #expect(finished.state == .blocked)
        #expect(finished.blocker == .thermal)
        #expect(finished.completedSteps == 0)
    }

    @Test func aFailingStepIsRetriedOnceAndThenTheJobStops() async throws {
        let (store, intelligence) = try await makeWorld()
        let executor = CountingExecutor(result: .failed("nope"))
        let runtime = makeRuntime(
            store, executors: [executor, IntelligenceStepExecutor(intelligence: intelligence)],
            limits: RuntimeLimits(maximumSteps: 8, maximumAttemptsPerStep: 2)
        )
        let plan = plan([("flaky", [:])])
        try await store.save(plan)

        let finished = await runtime.run(plan)
        #expect(finished.state == .failed)
        #expect(await executor.calls == 2)
        #expect(finished.steps[0].attempts == 2)
    }

    @Test func cancellingLeavesWhatWasDoneAndStartsNothingNew() async throws {
        let (store, intelligence) = try await makeWorld()
        let runtime = makeRuntime(store, executors: [IntelligenceStepExecutor(intelligence: intelligence)])
        let plan = plan([("search_knowledge", ["query": "midterm"])])
        try await store.save(plan)

        await runtime.cancel(plan.id)
        let stored = try #require(try await store.plan(plan.id))
        #expect(stored.state == .cancelled)
        #expect(stored.finishedAt != nil)
    }

    @Test func aJobReportsWhatItIsDoingAsItGoes() async throws {
        let (store, intelligence) = try await makeWorld()
        let runtime = makeRuntime(store, executors: [IntelligenceStepExecutor(intelligence: intelligence)])
        let events = EventLog()
        await runtime.observe { event in Task { await events.append(event) } }

        let plan = plan([("search_knowledge", ["query": "midterm"])])
        try await store.save(plan)
        _ = await runtime.run(plan)
        try await Task.sleep(nanoseconds: 50_000_000)

        let kinds = await events.kinds
        #expect(kinds.contains("started"))
        #expect(kinds.contains("stepStarted"))
        #expect(kinds.contains("finished"))
    }

    @Test func anArtifactIsWrittenInItsSkeletonAndKeepsItsSources() async throws {
        let (store, intelligence) = try await makeWorld()
        let model = ScriptedLanguageModel { _ in
            #"{"sections":["The midterm is on the fourth Friday.","Eigenvalues and diagonalization.","Start with the practice set."]}"#
        }
        let writer = LanguageModelArtifactWriter(model: model, store: store, calendar: {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }())
        let runtime = makeRuntime(
            store, executors: [IntelligenceStepExecutor(intelligence: intelligence, artifacts: writer)]
        )
        let plan = plan([
            ("search_knowledge", ["query": "midterm"]),
            ("write_artifact", ["title": "Midterm plan", "kind": "plan", "about": "what to study"]),
        ])
        try await store.save(plan)

        let finished = await runtime.run(plan)
        #expect(finished.state == .completed)

        let artifact = try #require(try await store.artifacts().first)
        #expect(artifact.title == "Midterm plan")
        #expect(artifact.kind == .plan)
        // Swift owns the shape: the title, the headings, the order, the date.
        #expect(artifact.markdown.hasPrefix("# Midterm plan"))
        for section in ArtifactKind.plan.sections {
            #expect(artifact.markdown.contains("## \(section)"))
        }
        #expect(artifact.markdown.contains("Written on this iPhone"))
        // The source is the document the job actually read.
        #expect(artifact.markdown.contains("## Sources"))
        #expect(artifact.sourceIDs.count == 1)
        #expect(finished.summary?.contains("Midterm plan") == true)
    }

    @Test func rewritingAnArtifactKeepsTheVersionTheUserAlreadyRead() async throws {
        let store = try IntelligenceStore()
        let first = try await store.save(Artifact(title: "Brief", kind: .brief, markdown: "# Brief\n\nfirst"))
        var second = first
        second.markdown = "# Brief\n\nsecond"
        let updated = try await store.save(second)

        #expect(updated.version == 2)
        #expect(try await store.artifact(first.id)?.markdown.contains("second") == true)
        let versions = try await store.versions(of: first.id)
        #expect(versions.map(\.version) == [1])
        #expect(versions[0].markdown.contains("first"))
    }
}

/// Counts how often it was asked to run, so retry behaviour can be asserted exactly.
actor CountingExecutor: StepExecuting {
    private let result: StepOutcome.Result
    private(set) var calls = 0

    init(result: StepOutcome.Result) { self.result = result }

    nonisolated func handles(_ capability: CapabilityID) -> Bool { capability.rawValue == "flaky" }

    func execute(_ step: PlanStep, plan: Plan, history: [String], now: Date) async -> StepOutcome {
        calls += 1
        return StepOutcome(result: result)
    }
}

actor EventLog {
    private(set) var kinds: [String] = []

    func append(_ event: RuntimeEvent) {
        switch event {
        case .started: kinds.append("started")
        case .stepStarted: kinds.append("stepStarted")
        case .stepFinished: kinds.append("stepFinished")
        case .blocked: kinds.append("blocked")
        case .finished: kinds.append("finished")
        case .failed: kinds.append("failed")
        case .cancelled: kinds.append("cancelled")
        }
    }
}
