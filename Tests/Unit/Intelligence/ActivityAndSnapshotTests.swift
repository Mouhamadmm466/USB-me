import Foundation
import Testing
@testable import Intelligence

/// Activity is the promise that nothing changes silently: everything the system learned is listed
/// in the user's own words, and everything listed can be taken back.
@Suite struct ActivityTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func learningWritesTheFeedAndUndoTakesItBack() async throws {
        let store = try IntelligenceStore()
        let pipeline = MemoryPipeline(store: store, validator: MemoryValidator(dates: FixedDateResolver()))
        let report = try await pipeline.apply(MemoryProposalSet(memories: [
            MemoryProposal(subject: ProposedEntity(kind: .person, name: "Sarah"), predicate: .role, text: "design lead"),
        ]), origin: .conversation(turnID: "turn-1"), now: now)

        let entries = try await store.record(report.all.map { $0.activityEntry(at: now) })
        #expect(entries.map(\.headline) == ["Sarah is responsible for design lead"])
        #expect(entries.first?.kind == .learned)
        #expect(entries.first?.canUndo == true)
        #expect(try await store.resolve(title: "Sarah")?.subtitle == "design lead")

        let undone = try await store.undo(entries[0].id, at: now.addingTimeInterval(60))
        #expect(undone?.isUndone == true)
        // The statement is gone, and so is the person it invented.
        #expect(try await store.resolve(title: "Sarah") == nil)
        // An entry cannot be undone twice.
        #expect(try await store.undo(entries[0].id, at: now.addingTimeInterval(120)) == nil)
    }

    @Test func undoingAnEndingBringsTheStatementBack() async throws {
        let store = try IntelligenceStore()
        let sarah = try await store.create(kind: .person, title: "Sarah")
        let project = try await store.create(kind: .project, title: "Beta launch")
        let recorded = try await store.record(
            subject: sarah.id, .worksOn, object: project.id, provenance: Provenance(sourceType: .conversation), at: now
        )
        try await store.end(recorded.assertion.id, at: now.addingTimeInterval(60))

        let entry = try await store.record(ActivityEntry(
            kind: .ended, headline: "Sarah works on Beta launch — no longer true",
            entityID: sarah.id, assertionID: recorded.assertion.id,
            undo: .restore(recorded.assertion.id), createdAt: now.addingTimeInterval(60)
        ))
        try await store.undo(entry.id, at: now.addingTimeInterval(120))
        #expect(try await store.assertions(about: sarah.id, includeIncoming: false).count == 1)
        #expect(try await store.assertion(recorded.assertion.id)?.state == .active)
    }

    @Test func undoWillNotOverwriteSomethingNewer() async throws {
        let store = try IntelligenceStore()
        let task = try await store.create(kind: .task, title: "Send the deck")
        let friday = now.addingTimeInterval(4 * 86_400)
        let first = try await store.record(subject: task.id, .deadline, value: .date(friday, phrase: "Friday"),
                                           provenance: Provenance(sourceType: .conversation), at: now)
        try await store.end(first.assertion.id, at: now.addingTimeInterval(60))
        let entry = try await store.record(ActivityEntry(
            kind: .ended, headline: "Send the deck is due Friday — no longer true", assertionID: first.assertion.id,
            undo: .restore(first.assertion.id), createdAt: now.addingTimeInterval(60)
        ))

        // The user set a new deadline in the meantime; undo must not silently replace it.
        let monday = now.addingTimeInterval(7 * 86_400)
        try await store.record(subject: task.id, .deadline, value: .date(monday, phrase: "Monday"),
                               provenance: Provenance(sourceType: .conversation), at: now.addingTimeInterval(120))
        try await store.undo(entry.id, at: now.addingTimeInterval(180))
        #expect(try await store.entity(task.id)?.dueAt == monday)
    }

    @Test func theFeedIsNewestFirstAndFiltersByKind() async throws {
        let store = try IntelligenceStore()
        for (index, kind) in [ActivityKind.learned, .asked, .acted].enumerated() {
            try await store.record(ActivityEntry(
                kind: kind, headline: "entry \(index)", createdAt: now.addingTimeInterval(Double(index) * 60)
            ))
        }
        #expect(try await store.activity().map(\.headline) == ["entry 2", "entry 1", "entry 0"])
        #expect(try await store.activity(kinds: [.asked]).map(\.headline) == ["entry 1"])
        #expect(try await store.activity(since: now.addingTimeInterval(90)).map(\.headline) == ["entry 2"])
    }
}

@Suite struct SnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeIntelligence(_ store: IntelligenceStore) -> PersonalIntelligence {
        PersonalIntelligence(store: store, dates: FixedDateResolver(), calendar: {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }())
    }

    @Test func homeSeparatesOverdueTodayAndSoon() async throws {
        let store = try IntelligenceStore()
        let late = try await store.create(kind: .task, title: "Late thing", dueAt: now.addingTimeInterval(-2 * 86_400))
        let today = try await store.create(kind: .task, title: "Today thing", dueAt: now.addingTimeInterval(3_600))
        let soon = try await store.create(kind: .task, title: "Soon thing", dueAt: now.addingTimeInterval(3 * 86_400))
        _ = try await store.create(kind: .task, title: "Far thing", dueAt: now.addingTimeInterval(30 * 86_400))

        let snapshot = try await makeIntelligence(store).snapshot(now: now)
        #expect(snapshot.overdue.map(\.id) == [late.id])
        #expect(snapshot.today.map(\.id) == [today.id])
        #expect(snapshot.soon.map(\.id) == [soon.id])
    }

    @Test func aProjectSummaryCountsItsWorkAndItsPeople() async throws {
        let store = try IntelligenceStore()
        let project = try await store.create(kind: .project, title: "Beta launch")
        let goal = try await store.create(kind: .goal, title: "Ship the beta", projectID: project.id,
                                          dueAt: now.addingTimeInterval(2 * 86_400))
        _ = try await store.create(kind: .task, title: "Write notes", projectID: project.id)
        let sarah = try await store.create(kind: .person, title: "Sarah")
        let commitment = try await store.create(kind: .commitment, title: "Send Sarah the deck")
        let source = Provenance(sourceType: .conversation)
        try await store.record(subject: sarah.id, .worksOn, object: project.id, provenance: source)
        try await store.record(subject: commitment.id, .belongsTo, object: project.id, provenance: source)

        let summary = try #require(try await makeIntelligence(store).projects(now: now).first)
        #expect(summary.project.id == project.id)
        #expect(summary.openWork == 2)
        #expect(summary.nextDue == goal.dueAt)
        #expect(summary.nextDueTitle == "Ship the beta")
        #expect(summary.people.map(\.title) == ["Sarah"])
        #expect(summary.openCommitments == 1)
    }

    @Test func questionsReadAsQuestionsAndSayWhatTheyWouldReplace() async throws {
        let store = try IntelligenceStore()
        let intelligence = makeIntelligence(store)
        let sarah = try await store.create(kind: .person, title: "Sarah")
        try await store.record(subject: sarah.id, .role, value: .text("design"),
                               provenance: Provenance(sourceType: .conversation), at: now)
        let guess = try await store.record(
            subject: sarah.id, .role, value: .text("research"), type: .inferred,
            provenance: Provenance(sourceType: .conversation), at: now.addingTimeInterval(60)
        )

        let questions = try await intelligence.questions(now: now)
        #expect(questions.map(\.sentence) == ["Sarah is responsible for research?"])
        #expect(questions.first?.explanation.contains("worked it out") == true)
        #expect(questions.first?.conflictsWith == "Sarah is responsible for design")

        try await intelligence.confirm(guess.assertion.id, now: now.addingTimeInterval(120))
        #expect(try await store.entity(sarah.id)?.subtitle == "research")
        #expect(try await intelligence.questions(now: now).isEmpty)
        // Confirming is itself an event the user can see and take back.
        #expect(try await store.activity().first?.kind == .confirmed)
    }

    @Test func sayingNoIsRememberedSoTheSameGuessIsNotMadeTwice() async throws {
        let store = try IntelligenceStore()
        let intelligence = makeIntelligence(store)
        let sarah = try await store.create(kind: .person, title: "Sarah")
        let guess = try await store.record(
            subject: sarah.id, .role, value: .text("research"), type: .inferred,
            provenance: Provenance(sourceType: .conversation), at: now
        )

        try await intelligence.reject(guess.assertion.id, now: now.addingTimeInterval(60))
        #expect(try await store.assertion(guess.assertion.id)?.state == .rejected)
        #expect(try await intelligence.questions(now: now).isEmpty)
        #expect(try await store.activity().first?.detail == "You said that isn't right.")
    }

    @Test func anEmptyWorldLooksEmptyRatherThanBroken() async throws {
        let snapshot = try await makeIntelligence(try IntelligenceStore()).snapshot(now: now)
        #expect(snapshot.isEmpty)
        #expect(snapshot.counts.totalEntities == 1)  // just the user
    }
}
