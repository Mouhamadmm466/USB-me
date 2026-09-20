import Foundation

/// A thing the model claims exists, named the way the user named it. Proposals never carry
/// identifiers: the model does not get to point at rows in the user's store, only to describe
/// something that Swift then resolves (or creates).
public struct ProposedEntity: Sendable, Equatable, Codable {
    public var kind: EntityKind
    public var name: String

    public init(kind: EntityKind, name: String) {
        self.kind = kind
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the model wants done with a statement. `add` and `end` are enough for everything:
/// a correction is an `end` plus an `add`, resolved by authority in the store.
public enum MemoryOperation: String, Sendable, Codable, CaseIterable {
    case add
    case end
}

/// One proposed change to the user's intelligence, as the model emits it.
///
/// This is the wire shape (constrained by `MemoryGrammar`, checked by `MemoryValidator`), not
/// something that touches the store. Dates arrive as the phrase the user said — Swift resolves
/// them — and every proposal carries the words it came from, so the user can always see why.
public struct MemoryProposal: Sendable, Equatable, Codable {
    public var operation: MemoryOperation
    public var subject: ProposedEntity
    public var predicate: Predicate
    public var object: ProposedEntity?
    /// A text value, or the role in a relationship ("design").
    public var text: String?
    /// A date the way the user said it: "next Friday", "tomorrow at 3".
    public var when: String?
    public var confidence: Double
    /// The model's read of how much this matters (0…1); the policy uses it as one input, not as law.
    public var importance: Double

    enum CodingKeys: String, CodingKey {
        case operation = "op", subject, predicate, object, text, when, confidence, importance
    }

    public init(
        operation: MemoryOperation = .add,
        subject: ProposedEntity,
        predicate: Predicate,
        object: ProposedEntity? = nil,
        text: String? = nil,
        when: String? = nil,
        confidence: Double = 0.8,
        importance: Double = 0.5
    ) {
        self.operation = operation
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.text = text
        self.when = when
        self.confidence = confidence
        self.importance = importance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decodeIfPresent(MemoryOperation.self, forKey: .operation) ?? .add
        subject = try container.decode(ProposedEntity.self, forKey: .subject)
        predicate = Predicate(try container.decode(String.self, forKey: .predicate))
        object = try container.decodeIfPresent(ProposedEntity.self, forKey: .object)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        when = try container.decodeIfPresent(String.self, forKey: .when)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.8
        importance = try container.decodeIfPresent(Double.self, forKey: .importance) ?? 0.5
    }
}

/// The model's whole answer for one turn.
public struct MemoryProposalSet: Sendable, Equatable, Codable {
    public var memories: [MemoryProposal]

    public init(memories: [MemoryProposal] = []) { self.memories = memories }

    public var isEmpty: Bool { memories.isEmpty }
}

/// A proposal that survived validation: legal shape, resolved date, known predicate. It still has
/// to pass policy and entity resolution before anything is written.
public struct ValidatedMemory: Sendable, Equatable {
    public var proposal: MemoryProposal
    public var spec: PredicateSpec
    /// The resolved value for an attribute statement (nil for relationships without a role).
    public var value: AssertionValue?
    public var type: MemoryType
    public var authority: Authority
    public var provenance: Provenance

    public var isRelationship: Bool { proposal.object != nil }
}

/// Why a proposal was thrown away. Kept as a closed vocabulary so the diagnostics screen can count
/// rejections without ever logging their content.
public enum MemoryRejection: String, Error, Sendable, Equatable, CaseIterable {
    case unknownPredicate
    case illegalStatement
    case unknownEntityKind
    case emptyName
    case nameTooLong
    case unresolvableDate
    case missingValue
    case valueTooLong
    case lowConfidence
    case notLearnable
    case aboutNothing
    case duplicateInTurn
}

extension MemoryProposal {
    /// A single line for the activity feed and the confirmation prompt: "Abdou works on Offline App",
    /// "Ship the beta is due next Friday". Deterministic — the model never writes this sentence.
    public func sentence(phrase: PredicateSpec) -> String {
        var parts = [subject.name, phrase.phrase]
        if let object { parts.append(object.name) }
        if let text, object == nil || phrase.predicate == .worksOn {
            parts.append(object == nil ? text : "(\(text))")
        }
        if let when { parts.append(when) }
        let sentence = parts.joined(separator: " ")
        return operation == .end ? "\(sentence) — no longer true" : sentence
    }
}
