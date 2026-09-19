import Foundation

/// Resolves a date the way the user said it ("next Friday", "tomorrow at 3") into an instant.
/// Implemented outside this module by V1's deterministic parser: the model never does calendar
/// arithmetic, it only repeats the phrase.
public protocol MemoryDateResolving: Sendable {
    func resolve(_ phrase: String, now: Date) -> Date?
}

/// Where a batch of proposals came from, and the most it is allowed to become. A page the agent
/// read cannot produce a statement with the authority of the user's own voice.
public struct MemoryOrigin: Sendable, Equatable {
    public var provenance: Provenance
    public var type: MemoryType
    public var authority: Authority

    public init(provenance: Provenance, type: MemoryType, authority: Authority? = nil) {
        self.provenance = provenance
        self.type = type
        self.authority = min(authority ?? .default(for: type), .default(for: type))
    }

    /// The user speaking in a conversation turn.
    public static func conversation(turnID: String? = nil, excerpt: String? = nil) -> MemoryOrigin {
        MemoryOrigin(
            provenance: Provenance(sourceType: .conversation, sourceID: turnID, excerpt: excerpt),
            type: .explicit
        )
    }

    /// Something the agent read: a document, a page, a connected service.
    public static func observed(_ source: SourceType, sourceID: String? = nil, excerpt: String? = nil) -> MemoryOrigin {
        MemoryOrigin(provenance: Provenance(sourceType: source, sourceID: sourceID, excerpt: excerpt), type: .observed)
    }
}

public struct RejectedMemory: Sendable, Equatable {
    public var proposal: MemoryProposal
    public var reason: MemoryRejection
}

public struct MemoryValidation: Sendable, Equatable {
    public var accepted: [ValidatedMemory] = []
    public var rejected: [RejectedMemory] = []
}

/// Turns what the model emitted into statements the store is willing to consider.
///
/// Everything here is a refusal: unknown predicates, statements a kind cannot carry, dates that do
/// not resolve, values that are too long, commitments attributed to the user from something the
/// user did not say. The store trusts its caller, so this is where the model stops being trusted.
public struct MemoryValidator: Sendable {
    public var dates: any MemoryDateResolving
    /// Below this the model is guessing, and a guess is not worth asking the user about.
    public var minimumConfidence: Double
    public var maximumNameLength: Int

    public init(dates: any MemoryDateResolving, minimumConfidence: Double = 0.35, maximumNameLength: Int = 80) {
        self.dates = dates
        self.minimumConfidence = minimumConfidence
        self.maximumNameLength = maximumNameLength
    }

    public func validate(_ set: MemoryProposalSet, origin: MemoryOrigin, now: Date = Date()) -> MemoryValidation {
        var result = MemoryValidation()
        var seen = Set<String>()
        for proposal in set.memories {
            switch check(proposal, origin: origin, now: now) {
            case let .failure(reason):
                result.rejected.append(RejectedMemory(proposal: proposal, reason: reason))
            case let .success(memory):
                let fingerprint = [
                    proposal.operation.rawValue, proposal.subject.name.intelligenceFolded,
                    proposal.predicate.rawValue, proposal.object?.name.intelligenceFolded ?? "",
                    memory.value?.displayText ?? "",
                ].joined(separator: "|")
                guard seen.insert(fingerprint).inserted else {
                    result.rejected.append(RejectedMemory(proposal: proposal, reason: .duplicateInTurn))
                    continue
                }
                result.accepted.append(memory)
            }
        }
        return result
    }

    private func check(_ proposal: MemoryProposal, origin: MemoryOrigin, now: Date) -> Result<ValidatedMemory, MemoryRejection> {
        guard let spec = PredicateCatalog.spec(for: proposal.predicate) else { return .failure(.unknownPredicate) }
        guard spec.isLearnable else { return .failure(.notLearnable) }
        guard proposal.confidence >= minimumConfidence else { return .failure(.lowConfidence) }

        for entity in [proposal.subject, proposal.object].compacted() {
            guard !entity.name.isEmpty else { return .failure(.emptyName) }
            guard entity.name.count <= maximumNameLength else { return .failure(.nameTooLong) }
            guard EntityKind.learnable.contains(entity.kind) else { return .failure(.unknownEntityKind) }
        }

        // Only the user's own words can put them on the hook for something, or settle a decision.
        if [EntityKind.commitment, .decision].contains(proposal.subject.kind), !origin.provenance.sourceType.isUserVoice {
            return .failure(.notLearnable)
        }

        var value: AssertionValue?
        switch spec.kind {
        case .relationship:
            guard proposal.object != nil else { return .failure(.aboutNothing) }
            if let text = proposal.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                guard text.count <= 60 else { return .failure(.valueTooLong) }
                value = .text(text)
            }
        case .attribute:
            guard proposal.object == nil else { return .failure(.illegalStatement) }
            switch spec.valueKind {
            case .date:
                guard let phrase = proposal.when?.trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty else {
                    return .failure(.missingValue)
                }
                guard let date = dates.resolve(phrase, now: now) else { return .failure(.unresolvableDate) }
                value = .date(date, phrase: phrase)
            case let .text(maxLength):
                guard let text = proposal.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    return .failure(.missingValue)
                }
                guard text.count <= maxLength else { return .failure(.valueTooLong) }
                value = .text(text)
            case let .number(range):
                guard let text = proposal.text, let number = Double(text), range.contains(number) else {
                    return .failure(.missingValue)
                }
                value = .number(number)
            case .flag:
                value = .flag(proposal.text?.lowercased() != "no")
            case .none:
                return .failure(.illegalStatement)
            }
        }

        if let violation = PredicateCatalog.violation(
            predicate: proposal.predicate, subjectKind: proposal.subject.kind,
            objectKind: proposal.object?.kind, value: value
        ) {
            _ = violation
            return .failure(.illegalStatement)
        }

        // A hedged proposal is an inference no matter where it came from, and is marked as one.
        let type: MemoryType = proposal.confidence >= 0.75 ? origin.type : .inferred
        let authority = min(origin.authority, .default(for: type))
        return .success(ValidatedMemory(
            proposal: proposal, spec: spec, value: value, type: type,
            authority: authority, provenance: origin.provenance
        ))
    }
}

extension Array {
    /// `[Optional<T>]` → `[T]`, without the closure noise at each call site.
    func compacted<Wrapped>() -> [Wrapped] where Element == Wrapped? { compactMap { $0 } }
}
