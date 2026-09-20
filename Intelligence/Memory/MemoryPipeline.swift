import Foundation
import Telemetry

/// What became of one proposed statement.
public enum MemoryOutcome: Sendable, Equatable {
    /// Written and active.
    case recorded(UUID)
    /// Already known; the existing statement was strengthened.
    case reinforced(UUID)
    /// Written as `proposed`: it counts only once the user says yes.
    case proposed(UUID)
    /// Contradicts something more authoritative; stored for the user to settle.
    case conflicted(UUID, with: UUID)
    /// An existing statement stopped being true.
    case ended(UUID)
    /// The system wants to retract something but will not do it unasked.
    case endProposed(UUID)

    public var assertionID: UUID {
        switch self {
        case let .recorded(id), let .reinforced(id), let .proposed(id),
             let .conflicted(id, _), let .ended(id), let .endProposed(id): id
        }
    }

    /// True when the user has to answer before this means anything.
    public var needsUser: Bool {
        switch self {
        case .proposed, .conflicted, .endProposed: true
        case .recorded, .reinforced, .ended: false
        }
    }
}

/// One line of "here is what I learned", with everything needed to undo it.
public struct LearnedMemory: Sendable, Equatable {
    /// The deterministic sentence shown to the user: "Abdou works on Offline App".
    public var sentence: String
    public var outcome: MemoryOutcome
    public var subjectID: UUID
    /// Entities this statement brought into existence, so undo can take them back out.
    public var createdEntityIDs: [UUID]
    public var explanation: String
}

public struct MemoryReport: Sendable, Equatable {
    public var learned: [LearnedMemory] = []
    public var pending: [LearnedMemory] = []
    public var dropped: [RejectedMemory] = []

    public var isEmpty: Bool { learned.isEmpty && pending.isEmpty }
    public var all: [LearnedMemory] { learned + pending }
}

/// Everything between "the model proposed something" and "the store changed".
///
/// Validate → decide → resolve names to entities → write. Each stage can only narrow what gets
/// through, and the report carries the sentences and identifiers the activity feed needs to show
/// the change and undo it.
public struct MemoryPipeline: Sendable {
    public let store: IntelligenceStore
    public var validator: MemoryValidator
    public var policy: MemoryPolicy
    private let logger: PrivacySafeLogger?

    public init(
        store: IntelligenceStore,
        validator: MemoryValidator,
        policy: MemoryPolicy = MemoryPolicy(),
        logger: PrivacySafeLogger? = nil
    ) {
        self.store = store
        self.validator = validator
        self.policy = policy
        self.logger = logger
    }

    @discardableResult
    public func apply(
        _ proposals: MemoryProposalSet, origin: MemoryOrigin, now: Date = Date()
    ) async throws -> MemoryReport {
        let validation = validator.validate(proposals, origin: origin, now: now)
        var report = MemoryReport(dropped: validation.rejected)

        for memory in validation.accepted {
            let decision = policy.decide(memory)
            guard decision != .drop else {
                report.dropped.append(RejectedMemory(proposal: memory.proposal, reason: .lowConfidence))
                continue
            }
            do {
                guard let learned = try await write(memory, decision: decision, now: now) else {
                    report.dropped.append(RejectedMemory(proposal: memory.proposal, reason: .aboutNothing))
                    continue
                }
                if learned.outcome.needsUser { report.pending.append(learned) } else { report.learned.append(learned) }
            } catch {
                report.dropped.append(RejectedMemory(proposal: memory.proposal, reason: .illegalStatement))
                logger?.log(.error(domain: "intelligence", code: "memory_write"))
            }
        }
        logger?.log(.counter(name: "intelligence.learned", value: report.learned.count))
        return report
    }

    // MARK: - Writing

    private func write(_ memory: ValidatedMemory, decision: MemoryDecision, now: Date) async throws -> LearnedMemory? {
        var created: [UUID] = []
        let sentence = memory.proposal.sentence(phrase: memory.spec)

        switch memory.proposal.operation {
        case .end:
            // Nothing is created to retract something: if the subject or object is unknown, there is
            // nothing there to have been true.
            guard let subject = try await resolve(memory.proposal.subject, creating: false, created: &created),
                  let target = try await existingStatement(memory, subjectID: subject.id) else { return nil }
            if decision == .confirm {
                return LearnedMemory(
                    sentence: sentence, outcome: .endProposed(target.id), subjectID: subject.id,
                    createdEntityIDs: [], explanation: target.explanation(now: now)
                )
            }
            try await store.end(target.id, at: now)
            return LearnedMemory(
                sentence: sentence, outcome: .ended(target.id), subjectID: subject.id,
                createdEntityIDs: [], explanation: target.explanation(now: now)
            )

        case .add:
            guard let subject = try await resolve(memory.proposal.subject, creating: true, created: &created) else { return nil }
            var objectID: UUID?
            if let proposedObject = memory.proposal.object {
                guard let object = try await resolve(proposedObject, creating: true, created: &created) else {
                    try await cleanUp(created)
                    return nil
                }
                objectID = object.id
            }

            let assertion = Assertion(
                subjectID: subject.id, predicate: memory.proposal.predicate, objectID: objectID,
                value: memory.value, type: memory.type, authority: memory.authority,
                confidence: memory.proposal.confidence, importance: memory.proposal.importance,
                state: decision == .confirm ? .proposed : .active, provenance: memory.provenance,
                validFrom: now, createdAt: now, updatedAt: now
            )

            do {
                let outcome: MemoryOutcome
                if decision == .confirm {
                    try await store.propose(assertion)
                    outcome = .proposed(assertion.id)
                } else {
                    switch try await store.record(assertion) {
                    case let .recorded(stored, _): outcome = .recorded(stored.id)
                    case let .reinforced(stored): outcome = .reinforced(stored.id)
                    case let .conflicted(proposed, existing): outcome = .conflicted(proposed.id, with: existing.id)
                    }
                }
                return LearnedMemory(
                    sentence: sentence, outcome: outcome, subjectID: subject.id,
                    createdEntityIDs: created, explanation: assertion.explanation(now: now)
                )
            } catch {
                try await cleanUp(created)
                throw error
            }
        }
    }

    /// The statement an `end` is talking about: the active one for this subject and predicate,
    /// matching the object when one was named.
    private func existingStatement(_ memory: ValidatedMemory, subjectID: UUID) async throws -> Assertion? {
        let active = try await store.activeAssertions(subjectID: subjectID, predicate: memory.proposal.predicate)
        guard let proposedObject = memory.proposal.object else { return active.first }
        guard let object = try await store.resolve(title: proposedObject.name, kind: proposedObject.kind) else { return nil }
        return active.first { $0.objectID == object.id }
    }

    /// Names to entities. The model never sees an identifier, so this is the only place a name
    /// becomes a row — and the only place a new one is created.
    private func resolve(
        _ proposed: ProposedEntity, creating: Bool, created: inout [UUID]
    ) async throws -> IntelligenceEntity? {
        if proposed.kind == .person, Self.selfReferences.contains(proposed.name.intelligenceFolded) {
            return try await store.entity(IntelligenceIdentity.userEntityID)
        }
        if let existing = try await store.resolve(title: proposed.name, kind: proposed.kind) { return existing }
        guard creating else { return nil }
        let entity = try await store.create(kind: proposed.kind, title: proposed.name)
        created.append(entity.id)
        return entity
    }

    /// Removes entities this batch invented when the statement that needed them did not survive.
    private func cleanUp(_ created: [UUID]) async throws {
        for id in created { try await store.forgetIfUnused(id) }
    }

    private static let selfReferences: Set<String> = ["i", "me", "my", "myself", "you", "user", "the user"]
}
