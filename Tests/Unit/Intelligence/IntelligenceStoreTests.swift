import Foundation
import Testing
@testable import Intelligence

/// The intelligence store is the one place where being wrong is permanent, so these tests are about
/// the rules that protect the user's world: nothing enters unvalidated, nothing overwrites something
/// they said, and everything can be explained and taken back.
@Suite struct IntelligenceStoreTests {
    private func makeStore() throws -> IntelligenceStore { try IntelligenceStore() }

    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Schema and identity

    @Test func opensWithUserEntityAndFullText() async throws {
        let store = try makeStore()
        let user = try await store.entity(IntelligenceIdentity.userEntityID)
        #expect(user?.kind == .person)
        #expect(user?.title == IntelligenceIdentity.userTitle)
        #expect(await store.searchMode == .fullText)
    }

    @Test func reopeningKeepsEverything() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("intel-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("intelligence.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let project = try await {
            let store = try IntelligenceStore(url: url)
            return try await store.create(kind: .project, title: "Beta launch")
        }()

        let reopened = try IntelligenceStore(url: url)
        #expect(try await reopened.entity(project.id)?.title == "Beta launch")
        // The user entity is seeded once, not on every open.
        #expect(try await reopened.entities(kind: .person).count == 1)
    }

    // MARK: Resolution

    @Test func resolvesByTitleAliasAndUnambiguousPrefix() async throws {
        let store = try makeStore()
        var sarah = try await store.create(kind: .person, title: "Sarah Chen")
        sarah.aliases = ["Sar"]
        try await store.update(sarah)

        #expect(try await store.resolve(title: "sarah chen")?.id == sarah.id)
        #expect(try await store.resolve(title: "Sar")?.id == sarah.id)
        #expect(try await store.resolve(title: "Sarah")?.id == sarah.id)
        #expect(try await store.resolve(title: "Sarah", kind: .project) == nil)

        // A prefix that fits two people resolves to neither: guessing attaches facts to the wrong person.
        _ = try await store.create(kind: .person, title: "Sarah Okonkwo")
        #expect(try await store.resolve(title: "Sarah") == nil)
    }

    // MARK: Writing and materialization

    @Test func attributeMaterializesOntoTheEntity() async throws {
        let store = try makeStore()
        let goal = try await store.create(kind: .goal, title: "Ship the beta")
        let friday = base.addingTimeInterval(4 * 86_400)

        let outcome = try await store.record(
            subject: goal.id, .deadline, value: .date(friday, phrase: "next Friday"),
            provenance: Provenance(sourceType: .conversation, sourceID: "turn-1", excerpt: "the beta is due next Friday"),
            at: base
        )
        #expect(outcome.isActive)
        #expect(try await store.entity(goal.id)?.dueAt == friday)

        // The phrase the user actually said survives, for the read-back.
        let stored = try await store.assertions(about: goal.id).first
        #expect(stored?.value?.displayText == "next Friday")
        #expect(stored?.explanation(now: base, calendar: .current) == "You told me today.")
    }

    @Test func functionalPredicateSupersedesThePreviousValue() async throws {
        let store = try makeStore()
        let task = try await store.create(kind: .task, title: "Send the deck")
        let friday = base.addingTimeInterval(4 * 86_400)
        let monday = base.addingTimeInterval(7 * 86_400)

        let first = try await store.record(
            subject: task.id, .deadline, value: .date(friday, phrase: "Friday"),
            provenance: Provenance(sourceType: .conversation), at: base
        )
        let second = try await store.record(
            subject: task.id, .deadline, value: .date(monday, phrase: "Monday"),
            provenance: Provenance(sourceType: .conversation), at: base.addingTimeInterval(60)
        )

        guard case let .recorded(_, superseded) = second else { return #expect(Bool(false), "expected a supersede") }
        #expect(superseded.map(\.id) == [first.assertion.id])
        #expect(try await store.entity(task.id)?.dueAt == monday)

        // History is kept, with the window in which the old value was true.
        let previous = try await store.assertion(first.assertion.id)
        #expect(previous?.state == .superseded)
        #expect(previous?.supersededBy == second.assertion.id)
        #expect(previous?.validTo != nil)
        #expect(try await store.activeAssertions(subjectID: task.id, predicate: .deadline).count == 1)
    }

    @Test func setValuedPredicateAccumulates() async throws {
        let store = try makeStore()
        let app = try await store.create(kind: .project, title: "App")
        let sarah = try await store.create(kind: .person, title: "Sarah")
        let abdou = try await store.create(kind: .person, title: "Abdou")

        try await store.record(subject: sarah.id, .worksOn, object: app.id, value: .text("design"),
                               provenance: Provenance(sourceType: .conversation))
        try await store.record(subject: abdou.id, .worksOn, object: app.id,
                               provenance: Provenance(sourceType: .conversation))

        let onProject = try await store.assertions(about: app.id)
        #expect(onProject.count == 2)
        #expect(onProject.allSatisfy { $0.predicate == .worksOn })
    }

    @Test func identicalStatementIsReinforcedNotDuplicated() async throws {
        let store = try makeStore()
        let project = try await store.create(kind: .project, title: "App")
        let sarah = try await store.create(kind: .person, title: "Sarah")
        let source = Provenance(sourceType: .conversation)

        try await store.record(subject: sarah.id, .worksOn, object: project.id, confidence: 0.8, provenance: source)
        let again = try await store.record(
            subject: sarah.id, .worksOn, object: project.id, type: .observed, confidence: 0.6, provenance: source
        )

        guard case let .reinforced(merged) = again else { return #expect(Bool(false), "expected reinforcement") }
        #expect(merged.confidence > 0.8)
        #expect(try await store.assertions(about: sarah.id, includeIncoming: false).count == 1)
    }

    @Test func relationshipMaterializesProjectMembership() async throws {
        let store = try makeStore()
        let project = try await store.create(kind: .project, title: "Beta launch")
        let task = try await store.create(kind: .task, title: "Write release notes")

        try await store.record(subject: task.id, .belongsTo, object: project.id, provenance: Provenance(sourceType: .conversation))
        #expect(try await store.entity(task.id)?.projectID == project.id)
        #expect(try await store.entities(kind: .task, projectID: project.id).map(\.id) == [task.id])
    }

    // MARK: Authority

    @Test func inferenceCannotOverwriteWhatTheUserSaid() async throws {
        let store = try makeStore()
        let task = try await store.create(kind: .task, title: "Draft the email")
        let friday = base.addingTimeInterval(4 * 86_400)
        let sunday = base.addingTimeInterval(6 * 86_400)

        try await store.record(subject: task.id, .deadline, value: .date(friday, phrase: "Friday"),
                               provenance: Provenance(sourceType: .conversation), at: base)
        let guess = try await store.record(
            subject: task.id, .deadline, value: .date(sunday, phrase: "Sunday"), type: .inferred,
            provenance: Provenance(sourceType: .conversation), at: base.addingTimeInterval(60)
        )

        guard case let .conflicted(proposed, existing) = guess else { return #expect(Bool(false), "expected a conflict") }
        #expect(proposed.state == .proposed)
        #expect(existing.authority == .userStatement)
        // The user's value still stands until they settle it.
        #expect(try await store.entity(task.id)?.dueAt == friday)
        #expect(try await store.pendingAssertions().map(\.id) == [proposed.id])
    }

    @Test func confirmingAConflictMakesItWinAndRejectingRestoresTheOld() async throws {
        let store = try makeStore()
        let task = try await store.create(kind: .task, title: "Book the venue")
        let friday = base.addingTimeInterval(4 * 86_400)
        let sunday = base.addingTimeInterval(6 * 86_400)
        try await store.record(subject: task.id, .deadline, value: .date(friday, phrase: "Friday"),
                               provenance: Provenance(sourceType: .conversation), at: base)
        let guess = try await store.record(
            subject: task.id, .deadline, value: .date(sunday, phrase: "Sunday"), type: .inferred,
            provenance: Provenance(sourceType: .conversation), at: base.addingTimeInterval(60)
        )

        let confirmed = try await store.confirm(guess.assertion.id, at: base.addingTimeInterval(120))
        #expect(confirmed.state == .active)
        #expect(confirmed.userConfirmed)
        #expect(confirmed.authority == .userCorrection)
        #expect(try await store.entity(task.id)?.dueAt == sunday)

        try await store.reject(confirmed.id, at: base.addingTimeInterval(180))
        #expect(try await store.assertion(confirmed.id)?.state == .rejected)
        // Rejecting puts back what it had displaced, rather than leaving the task with no deadline.
        #expect(try await store.entity(task.id)?.dueAt == friday)
    }

    @Test func correctionKeepsBothRowsAndTheNewValueWins() async throws {
        let store = try makeStore()
        let person = try await store.create(kind: .person, title: "Sarah")
        let first = try await store.record(subject: person.id, .role, value: .text("design"),
                                           provenance: Provenance(sourceType: .conversation), at: base)
        let corrected = try await store.correct(
            first.assertion.id,
            with: Assertion(subjectID: person.id, predicate: .role, value: .text("research"),
                            provenance: Provenance(sourceType: .userEdit)),
            at: base.addingTimeInterval(300)
        )

        #expect(corrected.assertion.authority == .userCorrection)
        #expect(try await store.entity(person.id)?.subtitle == "research")
        #expect(try await store.assertion(first.assertion.id)?.state == .superseded)
        let history = try await store.assertions(about: person.id, states: [.active, .superseded])
        #expect(history.count == 2)
    }

    @Test func endingAStatementClearsWhatItMaterialized() async throws {
        let store = try makeStore()
        let event = try await store.create(kind: .event, title: "Standup")
        let recorded = try await store.record(
            subject: event.id, .starts, value: .date(base, phrase: "today"),
            provenance: Provenance(sourceType: .calendar, sourceID: "evt-1"), at: base
        )
        #expect(try await store.entity(event.id)?.startsAt == base)

        try await store.end(recorded.assertion.id, at: base.addingTimeInterval(60))
        #expect(try await store.assertion(recorded.assertion.id)?.state == .ended)
        #expect(try await store.entity(event.id)?.startsAt == nil)
    }

    @Test func expiryRetiresTimeBoxedStatements() async throws {
        let store = try makeStore()
        let project = try await store.create(kind: .project, title: "App")
        let recorded = try await store.record(
            subject: project.id, .status, value: .text(EntityStatus.paused.rawValue),
            provenance: Provenance(sourceType: .conversation),
            expiresAt: base.addingTimeInterval(3_600), at: base
        )
        #expect(try await store.entity(project.id)?.status == .paused)

        #expect(try await store.expire(now: base.addingTimeInterval(7_200)) == 1)
        #expect(try await store.assertion(recorded.assertion.id)?.state == .expired)
        #expect(try await store.entity(project.id)?.status == .active)
    }

    // MARK: Validation

    @Test func theCatalogRejectsStatementsThatMakeNoSense() async throws {
        let store = try makeStore()
        let person = try await store.create(kind: .person, title: "Sarah")
        let task = try await store.create(kind: .task, title: "Write the brief")

        // A person has no deadline.
        await #expect(throws: IntelligenceStoreError.self) {
            try await store.record(subject: person.id, .deadline, value: .date(base, phrase: "today"),
                                   provenance: Provenance(sourceType: .conversation))
        }
        // A task cannot be "achieved" — that is a goal's status.
        await #expect(throws: IntelligenceStoreError.self) {
            try await store.record(subject: task.id, .status, value: .text(EntityStatus.achieved.rawValue),
                                   provenance: Provenance(sourceType: .conversation))
        }
        // works_on points at a project, not a person.
        await #expect(throws: IntelligenceStoreError.self) {
            try await store.record(subject: person.id, .worksOn, object: task.id,
                                   provenance: Provenance(sourceType: .conversation))
        }
        // Unknown predicates cannot enter at all.
        await #expect(throws: IntelligenceStoreError.self) {
            try await store.record(subject: person.id, Predicate("owns_house"), value: .text("yes"),
                                   provenance: Provenance(sourceType: .conversation))
        }
        #expect(try await store.counts().activeAssertions == 0)
    }

    @Test func statementsAboutMissingEntitiesAreRefused() async throws {
        let store = try makeStore()
        let task = try await store.create(kind: .task, title: "Ship")
        await #expect(throws: IntelligenceStoreError.self) {
            try await store.record(subject: UUID(), .deadline, value: .date(base, phrase: "today"),
                                   provenance: Provenance(sourceType: .conversation))
        }
        await #expect(throws: IntelligenceStoreError.self) {
            try await store.record(subject: task.id, .belongsTo, object: UUID(),
                                   provenance: Provenance(sourceType: .conversation))
        }
    }

    // MARK: Search and export

    @Test func searchFindsByNameAliasAndRememberedText() async throws {
        let store = try makeStore()
        var project = try await store.create(kind: .project, title: "Beta launch")
        project.aliases = ["the beta"]
        try await store.update(project)
        let person = try await store.create(kind: .person, title: "Sarah Chen")
        try await store.record(subject: person.id, .note, value: .text("allergic to shellfish"),
                               provenance: Provenance(sourceType: .conversation))

        #expect(try await store.search("beta").map(\.id).contains(project.id))
        #expect(try await store.search("the beta").map(\.id).contains(project.id))
        #expect(try await store.search("shellfish").map(\.id).contains(person.id))
        #expect(try await store.search("beta launch").map(\.id).contains(project.id))
        // Every word has to match, so more typing narrows the list rather than widening it.
        #expect(try await store.search("nothing here at all").isEmpty)
        // Quotes and operators are treated as text, not as query syntax: "OR" is searched for
        // literally (and found nowhere) instead of turning this into "anything matching beta".
        #expect(try await store.search("\"beta\" OR (").isEmpty)
    }

    @Test func exportContainsEverythingAndDeletionLeavesNothing() async throws {
        let store = try makeStore()
        let project = try await store.create(kind: .project, title: "App")
        try await store.record(subject: project.id, .deadline, value: .date(base, phrase: "today"),
                               provenance: Provenance(sourceType: .conversation, excerpt: "due today"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(IntelligenceExport.self, from: try await store.export())
        #expect(export.entities.contains { $0.id == project.id })
        #expect(export.assertions.count == 1)
        #expect(export.assertions.first?.provenance.excerpt == "due today")

        try await store.deleteEverything()
        let counts = try await store.counts()
        #expect(counts.activeAssertions == 0)
        // Only the user themselves survives an erasure.
        #expect(counts.totalEntities == 1)
        #expect(try await store.entity(IntelligenceIdentity.userEntityID) != nil)
    }

    @Test func forgettingAnEntityTakesItsStatementsWithIt() async throws {
        let store = try makeStore()
        let project = try await store.create(kind: .project, title: "App")
        let person = try await store.create(kind: .person, title: "Sarah")
        try await store.record(subject: person.id, .worksOn, object: project.id,
                               provenance: Provenance(sourceType: .conversation))

        try await store.forget(person.id)
        #expect(try await store.entity(person.id) == nil)
        #expect(try await store.assertions(about: project.id).isEmpty)
        // The user is not deletable this way; erasure is a separate, explicit act.
        await #expect(throws: IntelligenceStoreError.self) {
            try await store.forget(IntelligenceIdentity.userEntityID)
        }
    }

    @Test func upcomingReturnsOutstandingDatedWork() async throws {
        let store = try makeStore()
        let soon = try await store.create(kind: .task, title: "Send the deck", dueAt: base.addingTimeInterval(3_600))
        _ = try await store.create(kind: .task, title: "Later", dueAt: base.addingTimeInterval(30 * 86_400))
        let done = try await store.create(kind: .task, title: "Already done", dueAt: base.addingTimeInterval(600))
        try await store.record(subject: done.id, .status, value: .text(EntityStatus.done.rawValue),
                               provenance: Provenance(sourceType: .conversation))

        let due = try await store.upcoming(through: base.addingTimeInterval(86_400))
        #expect(due.map(\.id) == [soon.id])
    }
}

@Suite struct PredicateCatalogTests {
    @Test func everyPredicateHasExactlyOneSpec() {
        let names = PredicateCatalog.all.map(\.predicate)
        #expect(Set(names).count == names.count)
    }

    @Test func relationshipsHaveObjectKindsAndAttributesDoNot() {
        for spec in PredicateCatalog.all {
            switch spec.kind {
            case .relationship: #expect(!spec.objectKinds.isEmpty, "\(spec.predicate) has nothing to point at")
            case .attribute:
                #expect(spec.objectKinds.isEmpty, "\(spec.predicate) is an attribute but names object kinds")
                #expect(spec.valueKind != .none, "\(spec.predicate) is an attribute with no value")
            }
        }
    }

    @Test func learnablePredicatesExistForEveryLearnableKind() {
        for kind in EntityKind.learnable {
            #expect(!PredicateCatalog.learnable(forSubject: kind).isEmpty, "nothing can be said about a \(kind.rawValue)")
        }
    }
}
