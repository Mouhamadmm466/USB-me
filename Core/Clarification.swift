import Foundation
import Telemetry

/// A candidate the user can pick when a request is ambiguous. Identifiers come from native stores.
public struct ClarificationCandidate: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case contact, phoneNumber, event, file }

    public let kind: Kind
    /// Native identifier (contact id, event id, file relative path, or phone number).
    public let identifier: String
    /// What the assistant says and shows ("Alex Kim", "mobile", "Team sync, Monday 10 AM").
    public let displayText: String
    /// Extra words the user may use to pick this candidate ("Kim", "mobile", "work").
    public let matchTerms: [String]

    public init(kind: Kind, identifier: String, displayText: String, matchTerms: [String]) {
        self.kind = kind
        self.identifier = identifier
        self.displayText = displayText
        self.matchTerms = matchTerms
    }
}

public enum ClarificationReason: String, Codable, Sendable, SafeLabelConvertible {
    case contactAmbiguous
    case contactNotFound
    case phoneNumberAmbiguous
    case contactHasNoPhone
    case missingField
    case eventAmbiguous
    case eventNotFound
    case dateUnclear
    case fileAmbiguous
    case fileNotFound
    case phoneNumberNotInTranscript
    /// The model itself asked a question (type == clarification).
    case modelQuestion
}

/// Structured, Swift-owned clarification. The partial tool call is kept so the answer can be
/// merged deterministically without re-asking the model when possible.
public struct PendingClarification: Sendable, Equatable {
    public let reason: ClarificationReason
    public let question: String
    public let candidates: [ClarificationCandidate]
    public let partialCall: ProposedToolCall?
    /// Name of the argument the answer fills (e.g. "message" when asked "What should it say?").
    public let missingArgument: String?
    public let originalTranscript: String
    public let createdAt: Date

    public init(
        reason: ClarificationReason,
        question: String,
        candidates: [ClarificationCandidate] = [],
        partialCall: ProposedToolCall? = nil,
        missingArgument: String? = nil,
        originalTranscript: String,
        createdAt: Date
    ) {
        self.reason = reason
        self.question = question
        self.candidates = candidates
        self.partialCall = partialCall
        self.missingArgument = missingArgument
        self.originalTranscript = originalTranscript
        self.createdAt = createdAt
    }
}
