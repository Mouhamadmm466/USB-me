import Foundation
import Testing
@testable import Intelligence

/// A stand-in for V1's date parser: the pipeline must never do calendar arithmetic itself, so the
/// tests pin exactly which phrases resolve and what happens to the ones that do not.
struct FixedDateResolver: DatePhraseResolving {
    var offsets: [String: TimeInterval] = [
        "today": 0, "tomorrow": 86_400, "next friday": 4 * 86_400, "friday": 4 * 86_400,
        "next week": 7 * 86_400, "monday": 3 * 86_400,
    ]

    func resolve(_ phrase: String, now: Date) -> Date? {
        offsets[phrase.lowercased().trimmingCharacters(in: .whitespaces)].map { now.addingTimeInterval($0) }
    }
}

@Suite struct MemoryFilterTests {
    private func filter(_ known: [String] = []) -> MemoryFilter { MemoryFilter(knownNames: Set(known)) }

    @Test func ignoresTurnsWithNothingToRemember() {
        for text in ["what time is it", "thanks", "set a timer for five minutes", "play some music", "stop"] {
            #expect(!filter().evaluate(userText: text).isWorthwhile, "\(text) should not reach the model")
        }
    }

    @Test func catchesCommitmentsDecisionsAndPreferences() {
        #expect(filter().evaluate(userText: "I promised Sarah I'd send the deck by Friday").isWorthwhile)
        #expect(filter().evaluate(userText: "we decided to go with Postgres instead of Mongo").isWorthwhile)
        #expect(filter().evaluate(userText: "I'm allergic to shellfish").isWorthwhile)
        #expect(filter().evaluate(userText: "my advisor is Professor Diallo").isWorthwhile)
    }

    @Test func aQuestionOnlyCountsWhenItAlsoStatesSomething() {
        // Retrieval: the answer comes from memory, nothing goes into it.
        #expect(!filter().evaluate(userText: "when is the beta due?").isWorthwhile)
        #expect(!filter().evaluate(userText: "remind me to call mom tomorrow").isWorthwhile)
        // Says something on the way past.
        #expect(filter().evaluate(userText: "did I tell you we're going with Postgres?").isWorthwhile)
    }

    @Test func mentioningSomethingAlreadyKnownIsEnough() {
        let candidate = filter(["Beta launch", "Sarah Chen"]).evaluate(userText: "beta launch slipped again")
        #expect(candidate.triggers.contains(.knownEntity))
        #expect(candidate.isWorthwhile)
        #expect(!filter().evaluate(userText: "beta launch slipped again").triggers.contains(.knownEntity))
    }

    @Test func scoreRisesWithHowMuchIsThere() {
        let thin = filter().evaluate(userText: "the deck is ready")
        let thick = filter().evaluate(userText: "I promised Sarah I'd send the deck by Friday, we decided on the short version")
        #expect(thick.score > thin.score)
    }
}

@Suite struct MemoryValidatorTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var validator: MemoryValidator { MemoryValidator(dates: FixedDateResolver()) }

    private func validate(_ proposals: [MemoryProposal], origin: MemoryOrigin = .conversation()) -> MemoryValidation {
        validator.validate(MemoryProposalSet(memories: proposals), origin: origin, now: now)
    }

    @Test func acceptsAWellFormedRelationshipAndResolvesTheDate() {
        let result = validate([
            MemoryProposal(subject: ProposedEntity(kind: .person, name: "Abdou"), predicate: .worksOn,
                           object: ProposedEntity(kind: .project, name: "Offline App"), text: "the voice loop"),
            MemoryProposal(subject: ProposedEntity(kind: .goal, name: "Ship the beta"), predicate: .deadline,
                           when: "next Friday"),
        ])
        #expect(result.rejected.isEmpty)
        #expect(result.accepted.count == 2)
        #expect(result.accepted[1].value?.dateValue == now.addingTimeInterval(4 * 86_400))
        // The user's words are kept alongside the resolved instant.
        #expect(result.accepted[1].value?.displayText == "next Friday")
    }

    @Test func refusesStatementsTheCatalogDoesNotAllow() {
        let cases: [(MemoryProposal, MemoryRejection)] = [
            (MemoryProposal(subject: ProposedEntity(kind: .person, name: "Sarah"), predicate: Predicate("owns_car"),
                            text: "yes"), .unknownPredicate),
            (MemoryProposal(subject: ProposedEntity(kind: .person, name: "Sarah"), predicate: .deadline,
                            when: "tomorrow"), .illegalStatement),
            (MemoryProposal(subject: ProposedEntity(kind: .task, name: "Ship"), predicate: .deadline,
                            when: "sometime soon"), .unresolvableDate),
            (MemoryProposal(subject: ProposedEntity(kind: .task, name: "Ship"), predicate: .deadline), .missingValue),
            (MemoryProposal(subject: ProposedEntity(kind: .person, name: ""), predicate: .role,
                            text: "design"), .emptyName),
            (MemoryProposal(subject: ProposedEntity(kind: .person, name: String(repeating: "a", count: 200)),
                            predicate: .role, text: "design"), .nameTooLong),
            (MemoryProposal(subject: ProposedEntity(kind: .person, name: "Sarah"), predicate: .role,
                            text: "design", confidence: 0.1), .lowConfidence),
            (MemoryProposal(subject: ProposedEntity(kind: .document, name: "notes.pdf"), predicate: .describes,
                            text: "meeting notes"), .unknownEntityKind),
            (MemoryProposal(subject: ProposedEntity(kind: .person, name: "Sarah"), predicate: .worksOn,
                            text: "design"), .aboutNothing),
        ]
        for (proposal, expected) in cases {
            let result = validate([proposal])
            #expect(result.accepted.isEmpty, "\(proposal.predicate) should not have been accepted")
            #expect(result.rejected.first?.reason == expected, "\(proposal.predicate) → \(String(describing: result.rejected.first?.reason))")
        }
    }

    @Test func onlyTheUsersOwnWordsCanCreateACommitmentOrDecision() {
        let commitment = MemoryProposal(
            subject: ProposedEntity(kind: .commitment, name: "Send the deck"), predicate: .deadline, when: "friday"
        )
        #expect(validate([commitment]).accepted.count == 1)
        // The same sentence found on a web page is not the user promising anything.
        let fromWeb = validate([commitment], origin: .observed(.web, sourceID: "page-1"))
        #expect(fromWeb.accepted.isEmpty)
        #expect(fromWeb.rejected.first?.reason == .notLearnable)
    }

    @Test func hedgedProposalsBecomeMarkedInferences() {
        let sure = validate([MemoryProposal(subject: ProposedEntity(kind: .person, name: "Sarah"),
                                            predicate: .role, text: "design", confidence: 0.95)])
        let hedged = validate([MemoryProposal(subject: ProposedEntity(kind: .person, name: "Sarah"),
                                              predicate: .role, text: "design", confidence: 0.5)])
        #expect(sure.accepted.first?.type == .explicit)
        #expect(sure.accepted.first?.authority == .userStatement)
        #expect(hedged.accepted.first?.type == .inferred)
        #expect(hedged.accepted.first?.authority == .inference)
    }

    @Test func aBatchCannotSayTheSameThingTwice() {
        let proposal = MemoryProposal(subject: ProposedEntity(kind: .person, name: "Sarah"), predicate: .role, text: "design")
        let result = validate([proposal, proposal])
        #expect(result.accepted.count == 1)
        #expect(result.rejected.map(\.reason) == [.duplicateInTurn])
    }

    @Test func observationsNeverGainTheAuthorityOfSpeech() {
        let result = validate(
            [MemoryProposal(subject: ProposedEntity(kind: .event, name: "Standup"), predicate: .starts, when: "tomorrow")],
            origin: .observed(.calendar, sourceID: "evt-1")
        )
        #expect(result.accepted.first?.type == .observed)
        #expect(result.accepted.first?.authority == .observation)
        #expect(result.accepted.first?.provenance.sourceType == .calendar)
    }
}

@Suite struct MemoryPolicyTests {
    private func memory(type: MemoryType, confidence: Double = 0.9, operation: MemoryOperation = .add) -> ValidatedMemory {
        ValidatedMemory(
            proposal: MemoryProposal(operation: operation, subject: ProposedEntity(kind: .person, name: "Sarah"),
                                     predicate: .role, text: "design", confidence: confidence),
            spec: PredicateCatalog.spec(for: .role)!, value: .text("design"), type: type,
            authority: .default(for: type), provenance: Provenance(sourceType: .conversation)
        )
    }

    @Test func whatTheUserSaysIsKeptAndWhatTheModelGuessesIsAsked() {
        let policy = MemoryPolicy()
        #expect(policy.decide(memory(type: .explicit)) == .accept)
        #expect(policy.decide(memory(type: .inferred, confidence: 0.8)) == .confirm)
        #expect(policy.decide(memory(type: .inferred, confidence: 0.4)) == .drop)
        #expect(policy.decide(memory(type: .observed)) == .accept)
    }

    @Test func retractingOnAGuessAlwaysAsks() {
        var settings = MemoryPolicySettings.default
        settings.confirmInferences = false
        let policy = MemoryPolicy(settings: settings)
        #expect(policy.decide(memory(type: .inferred, confidence: 0.9)) == .accept)
        #expect(policy.decide(memory(type: .inferred, confidence: 0.9, operation: .end)) == .confirm)
    }

    @Test func theLearningSwitchStopsEverything() {
        let policy = MemoryPolicy(settings: .off)
        for type in MemoryType.allCases {
            #expect(policy.decide(memory(type: type)) == .drop)
        }
    }

    @Test func observationsCanBeMadeToAsk() {
        var settings = MemoryPolicySettings.default
        settings.confirmObservations = true
        #expect(MemoryPolicy(settings: settings).decide(memory(type: .observed)) == .confirm)
    }
}

@Suite struct MemoryPipelineTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func makePipeline(
        settings: MemoryPolicySettings = .default
    ) throws -> (MemoryPipeline, IntelligenceStore) {
        let store = try IntelligenceStore()
        let pipeline = MemoryPipeline(
            store: store, validator: MemoryValidator(dates: FixedDateResolver()),
            policy: MemoryPolicy(settings: settings)
        )
        return (pipeline, store)
    }

    @Test func learningAWholeTurnCreatesWhatIsMissingAndWritesTheStatements() async throws {
        let (pipeline, store) = try makePipeline()
        let report = try await pipeline.apply(MemoryProposalSet(memories: [
            MemoryProposal(subject: ProposedEntity(kind: .person, name: "Abdou"), predicate: .worksOn,
                           object: ProposedEntity(kind: .project, name: "Offline App"), text: "the voice loop"),
            MemoryProposal(subject: ProposedEntity(kind: .goal, name: "Ship the beta"), predicate: .deadline,
                           when: "next Friday"),
        ]), origin: .conversation(turnID: "turn-7", excerpt: "Abdou is working on the voice loop"), now: now)

        #expect(report.dropped.isEmpty)
        #expect(report.learned.count == 2)
        #expect(report.pending.isEmpty)
        #expect(report.learned.map(\.sentence) == [
            "Abdou works on Offline App (the voice loop)", "Ship the beta is due next Friday",
        ])
        #expect(report.learned.first?.explanation == "You told me today.")

        let abdou = try await store.resolve(title: "Abdou", kind: .person)
        #expect(abdou != nil)
        let goal = try await store.resolve(title: "Ship the beta", kind: .goal)
        #expect(try await store.entity(goal!.id)?.dueAt == now.addingTimeInterval(4 * 86_400))
        // Provenance survives the whole pipeline: the excerpt is what the user actually said.
        let stored = try await store.assertions(about: abdou!.id).first
        #expect(stored?.provenance.sourceID == "turn-7")
        #expect(stored?.provenance.excerpt == "Abdou is working on the voice loop")
    }

    @Test func theUserIsAlwaysTheSamePerson() async throws {
        let (pipeline, store) = try makePipeline()
        for name in ["I", "me", "you"] {
            try await pipeline.apply(MemoryProposalSet(memories: [
                MemoryProposal(subject: ProposedEntity(kind: .person, name: name), predicate: .preference,
                               text: "no meetings before 10"),
            ]), origin: .conversation(), now: now)
        }
        // Three statements about one person, not three people called I, me and you.
        #expect(try await store.entities(kind: .person).count == 1)
        let mine = try await store.assertions(about: IntelligenceIdentity.userEntityID)
        #expect(mine.count == 1)
        #expect(mine.first?.value?.textValue == "no meetings before 10")
    }

    @Test func aGuessIsHeldBackUntilTheUserAgrees() async throws {
        let (pipeline, store) = try makePipeline()
        let report = try await pipeline.apply(MemoryProposalSet(memories: [
            MemoryProposal(subject: ProposedEntity(kind: .person, name: "Sarah"), predicate: .role,
                           text: "design", confidence: 0.6),
        ]), origin: .conversation(), now: now)

        #expect(report.learned.isEmpty)
        #expect(report.pending.count == 1)
        guard case let .proposed(id) = report.pending[0].outcome else { return #expect(Bool(false), "expected a question") }
        // Nothing has changed in the user's world yet.
        let sarah = try await store.resolve(title: "Sarah", kind: .person)
        #expect(sarah?.subtitle == nil)
        #expect(try await store.pendingAssertions().map(\.id) == [id])

        _ = try await store.confirm(id, at: now)
        #expect(try await store.resolve(title: "Sarah", kind: .person)?.subtitle == "design")
    }

    @Test func nothingIsInventedToRetractSomethingUnknown() async throws {
        let (pipeline, store) = try makePipeline()
        let report = try await pipeline.apply(MemoryProposalSet(memories: [
            MemoryProposal(operation: .end, subject: ProposedEntity(kind: .person, name: "Mystery"),
                           predicate: .worksOn, object: ProposedEntity(kind: .project, name: "Nowhere")),
        ]), origin: .conversation(), now: now)

        #expect(report.isEmpty)
        #expect(report.dropped.map(\.reason) == [.aboutNothing])
        #expect(try await store.resolve(title: "Mystery") == nil)
        #expect(try await store.resolve(title: "Nowhere") == nil)
    }

    @Test func endingAKnownRelationshipRetiresIt() async throws {
        let (pipeline, store) = try makePipeline()
        try await pipeline.apply(MemoryProposalSet(memories: [
            MemoryProposal(subject: ProposedEntity(kind: .person, name: "Sarah"), predicate: .worksOn,
                           object: ProposedEntity(kind: .project, name: "Beta launch")),
        ]), origin: .conversation(), now: now)

        let report = try await pipeline.apply(MemoryProposalSet(memories: [
            MemoryProposal(operation: .end, subject: ProposedEntity(kind: .person, name: "Sarah"),
                           predicate: .worksOn, object: ProposedEntity(kind: .project, name: "Beta launch")),
        ]), origin: .conversation(), now: now.addingTimeInterval(3_600))

        #expect(report.learned.count == 1)
        #expect(report.learned[0].sentence == "Sarah works on Beta launch — no longer true")
        let sarah = try await store.resolve(title: "Sarah", kind: .person)!
        #expect(try await store.assertions(about: sarah.id).isEmpty)
        #expect(try await store.assertions(about: sarah.id, states: [.ended]).count == 1)
    }

    @Test func nothingIsWrittenWhenLearningIsOff() async throws {
        let (pipeline, store) = try makePipeline(settings: .off)
        let report = try await pipeline.apply(MemoryProposalSet(memories: [
            MemoryProposal(subject: ProposedEntity(kind: .person, name: "Sarah"), predicate: .role, text: "design"),
        ]), origin: .conversation(), now: now)

        #expect(report.isEmpty)
        #expect(try await store.counts().totalEntities == 1)
        #expect(try await store.counts().activeAssertions == 0)
    }

    @Test func aDeclinedSuggestionLeavesNoDebris() async throws {
        let (pipeline, store) = try makePipeline()
        let report = try await pipeline.apply(MemoryProposalSet(memories: [
            MemoryProposal(subject: ProposedEntity(kind: .person, name: "Imaginary Friend"), predicate: .worksOn,
                           object: ProposedEntity(kind: .project, name: "Imaginary Project"), confidence: 0.65),
        ]), origin: .conversation(), now: now)

        let pending = try #require(report.pending.first)
        #expect(pending.createdEntityIDs.count == 2)

        // Saying no goes through the activity entry, which knows exactly what this statement
        // invented — and therefore what is safe to remove.
        let entry = try await store.record(pending.activityEntry(at: now))
        try await store.undo(entry.id, at: now)
        #expect(try await store.resolve(title: "Imaginary Friend") == nil)
        #expect(try await store.resolve(title: "Imaginary Project") == nil)

        // An entity the user already had is never swept up, even when the statement about it is
        // the only one it has.
        let sarah = try await store.create(kind: .person, title: "Sarah")
        let recorded = try await store.record(subject: sarah.id, .role, value: .text("design"),
                                              provenance: Provenance(sourceType: .conversation))
        try await store.reject(recorded.assertion.id, at: now)
        #expect(try await store.resolve(title: "Sarah") != nil)
    }

    @Test func aSecondMentionStrengthensRatherThanDuplicates() async throws {
        let (pipeline, store) = try makePipeline()
        let proposals = MemoryProposalSet(memories: [
            MemoryProposal(subject: ProposedEntity(kind: .person, name: "Sarah"), predicate: .worksOn,
                           object: ProposedEntity(kind: .project, name: "Beta launch")),
        ])
        try await pipeline.apply(proposals, origin: .conversation(), now: now)
        let second = try await pipeline.apply(proposals, origin: .conversation(), now: now.addingTimeInterval(600))

        if case .reinforced = second.learned.first?.outcome {} else {
            #expect(Bool(false), "the same fact twice should strengthen one statement")
        }
        #expect(try await store.entities(kind: .person).count == 2)  // the user and Sarah
        #expect(try await store.counts().activeAssertions == 1)
    }
}

@Suite struct MemoryGrammarTests {
    @Test func theGrammarOnlyOffersLegalStatements() {
        let grammar = MemoryGrammar.grammar()
        // A person can have a role, but never a deadline.
        #expect(grammar.contains("p-person-role"))
        #expect(!grammar.contains("p-person-deadline"))
        #expect(grammar.contains("p-goal-deadline"))
        // Derived values are not the model's to propose.
        #expect(!grammar.contains("progress"))
        // Only the kinds the model is allowed to invent appear at all.
        #expect(!grammar.contains("\\\"kind\\\":\\\"artifact\\\""))
        #expect(grammar.contains("{\\\"memories\\\":[]}") || grammar.contains("\"memories\\\":[\""))
    }

    @Test func everyLearnableKindCanSaySomething() {
        let grammar = MemoryGrammar.grammar()
        for kind in MemoryGrammar.subjectKinds {
            #expect(grammar.contains("mem-\(kind.rawValue.replacingOccurrences(of: "_", with: "-"))"),
                    "nothing can be said about a \(kind.rawValue)")
        }
    }

    @Test func thePromptDescribesTheSameVocabularyAsTheGrammar() {
        let prompt = MemoryGrammar.promptSection()
        for kind in MemoryGrammar.subjectKinds {
            #expect(prompt.contains("- \(kind.rawValue):"))
        }
        #expect(prompt.contains("works_on → project"))
        #expect(prompt.contains("deadline → when"))
        #expect(!prompt.contains("derived_from"))
    }
}
