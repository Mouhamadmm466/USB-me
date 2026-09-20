import Foundation
import Testing
@testable import Intelligence

/// "What needs my attention?" is the question where being wrong is most expensive, so the rules are
/// pinned here: what gets raised, in what order, and with which reason.
@Suite struct AttentionTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func makeEngine(_ store: IntelligenceStore) -> AttentionEngine {
        AttentionEngine(store: store, calendar: calendar)
    }

    private func makeIntelligence(_ store: IntelligenceStore) -> PersonalIntelligence {
        PersonalIntelligence(store: store, dates: FixedDateResolver(), calendar: calendar)
    }

    @Test func lateThingsComeFirstAndSayHowLate() async throws {
        let store = try IntelligenceStore()
        let late = try await store.create(kind: .task, title: "Write the brief",
                                          dueAt: now.addingTimeInterval(-3 * 86_400))
        _ = try await store.create(kind: .task, title: "Later thing", dueAt: now.addingTimeInterval(5 * 86_400))
        let today = try await store.create(kind: .task, title: "Standup notes", dueAt: now.addingTimeInterval(3_600))

        let items = try await makeEngine(store).items(now: now)
        #expect(items.first?.entityID == late.id)
        #expect(items.first?.kind == .overdue)
        #expect(items.first?.reason == "due 3 days ago")
        #expect(items.dropFirst().first?.entityID == today.id)
        #expect(items.contains { $0.kind == .approaching || $0.kind == .unstarted })
    }

    @Test func aPromiseReadsAsAPromiseAndNamesWhoItIsTo() async throws {
        let store = try IntelligenceStore()
        let sarah = try await store.create(kind: .person, title: "Sarah")
        let promise = try await store.create(kind: .commitment, title: "Send Sarah the deck")
        try await store.record(subject: promise.id, .owedTo, object: sarah.id,
                               provenance: Provenance(sourceType: .conversation), at: now)

        let items = try await makeEngine(store).items(now: now)
        let item = try #require(items.first { $0.entityID == promise.id })
        #expect(item.kind == .promise)
        #expect(item.reason == "you promised Sarah, no date on it")
    }

    @Test func aDeadlineWithNothingUnderItIsRaisedHarderThanOneWithWork() async throws {
        let store = try IntelligenceStore()
        let friday = now.addingTimeInterval(3 * 86_400)
        let started = try await store.create(kind: .project, title: "Beta launch", dueAt: friday)
        _ = try await store.create(kind: .task, title: "Write notes", projectID: started.id)
        let untouched = try await store.create(kind: .project, title: "Thesis chapter", dueAt: friday)

        let items = try await makeEngine(store).items(now: now)
        let unstarted = try #require(items.first { $0.entityID == untouched.id })
        let approaching = try #require(items.first { $0.entityID == started.id })
        #expect(unstarted.kind == .unstarted)
        #expect(unstarted.reason.contains("nothing started"))
        #expect(approaching.kind == .approaching)
        #expect(unstarted.urgency > approaching.urgency)
    }

    @Test func questionsAreRaisedGentlyRatherThanLoudly() async throws {
        let store = try IntelligenceStore()
        let sarah = try await store.create(kind: .person, title: "Sarah")
        try await store.propose(Assertion(
            subjectID: sarah.id, predicate: .role, value: .text("design lead"), type: .inferred,
            provenance: Provenance(sourceType: .conversation), validFrom: now, createdAt: now
        ))
        _ = try await store.create(kind: .task, title: "Late thing", dueAt: now.addingTimeInterval(-86_400))

        let items = try await makeEngine(store).items(now: now)
        let question = try #require(items.first { $0.kind == .question })
        #expect(question.title == "Sarah is responsible for design lead?")
        #expect(question.assertionID != nil)
        // It sits below what is actually late.
        #expect(items.first?.kind == .overdue)
    }

    @Test func workThatNothingHasTouchedGoesQuietRatherThanSilent() async throws {
        let store = try IntelligenceStore()
        var old = try await store.create(kind: .project, title: "Old side project")
        old.updatedAt = now.addingTimeInterval(-40 * 86_400)
        try await store.update(old, at: old.updatedAt)

        let items = try await makeEngine(store).items(now: now)
        let stale = try #require(items.first { $0.kind == .stale })
        #expect(stale.reason.contains("40 days"))
        #expect(stale.urgency < 0.5)
    }

    @Test func anEmptyWorldSaysNothingNeedsYou() async throws {
        let store = try IntelligenceStore()
        let engine = makeEngine(store)
        let items = try await engine.items(now: now)
        #expect(items.isEmpty)
        #expect(engine.summary(items) == "Nothing needs you right now.")
    }

    @Test func theSpokenSummaryLeadsWithTheWorstThing() async throws {
        let store = try IntelligenceStore()
        _ = try await store.create(kind: .task, title: "Write the brief", dueAt: now.addingTimeInterval(-86_400))
        _ = try await store.create(kind: .task, title: "Standup notes", dueAt: now.addingTimeInterval(3_600))
        _ = try await store.create(kind: .task, title: "Book the room", dueAt: now.addingTimeInterval(2 * 86_400))

        let engine = makeEngine(store)
        let summary = engine.summary(try await engine.items(now: now))
        #expect(summary.hasPrefix("Write the brief — due yesterday."))
        #expect(summary.contains("2 more"))
    }

    @Test func askingWhatMattersPutsItInTheTurnContext() async throws {
        let store = try IntelligenceStore()
        _ = try await store.create(kind: .task, title: "Write the brief", dueAt: now.addingTimeInterval(-86_400))
        let intelligence = makeIntelligence(store)

        let context = try await intelligence.context(for: "what should I work on?", now: now)
        #expect(context.render().contains("Write the brief — due yesterday"))

        // An ordinary command still costs nothing.
        #expect(try await intelligence.context(for: "set a timer for five minutes", now: now).isEmpty)
    }

    @Test func theAttentionRulesAreTheOnesHomeShows() async throws {
        let store = try IntelligenceStore()
        _ = try await store.create(kind: .task, title: "Write the brief", dueAt: now.addingTimeInterval(-86_400))
        let snapshot = try await makeIntelligence(store).snapshot(now: now)
        #expect(snapshot.attention.first?.title == "Write the brief")
        #expect(!snapshot.isEmpty)
    }
}
