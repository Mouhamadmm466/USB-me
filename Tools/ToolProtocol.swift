import Core
import Foundation

/// Everything a resolver needs to turn an untrusted `ProposedToolCall` into a `ResolvedAction`.
public struct ResolutionContext: Sendable {
    /// The user's finalized utterance. Used e.g. to verify that a dictated phone number really
    /// appears in what the user said (the model must not invent numbers).
    public let transcript: String
    /// Structured session state (last contact / event / resolved entities) for pronouns such as
    /// "him", "her", "it", "that meeting".
    public let session: SessionState
    public let clock: AgentClock
    /// Choices the user already made in a clarification, keyed by argument name
    /// (e.g. "contact_query" -> the exact contact candidate picked, "phone" -> number picked).
    public let pinnedSelections: [String: ClarificationCandidate]

    public init(
        transcript: String,
        session: SessionState,
        clock: AgentClock,
        pinnedSelections: [String: ClarificationCandidate] = [:]
    ) {
        self.transcript = transcript
        self.session = session
        self.clock = clock
        self.pinnedSelections = pinnedSelections
    }

    public func pinning(_ argument: String, _ candidate: ClarificationCandidate) -> ResolutionContext {
        var pins = pinnedSelections
        pins[argument] = candidate
        return ResolutionContext(transcript: transcript, session: session, clock: clock, pinnedSelections: pins)
    }
}

public enum ResolutionOutcome: Sendable, Equatable {
    /// Fully resolved against native stores; ready to become a PendingAction (or run, if read-only).
    case resolved(ResolvedAction)
    /// Ambiguous, not found, or missing information. Carries a deterministic spoken question.
    case needsClarification(PendingClarification)
    /// The tool needs this permission before it can resolve (e.g. contacts lookup).
    case needsPermission(PermissionKind)
    case failed(ToolFailure)
}

/// Resolves validated model proposals into native, typed actions (contacts lookup, date parsing,
/// event lookup, authorized-file lookup). Never executes side effects.
public protocol ActionResolving: Sendable {
    func resolve(_ call: ProposedToolCall, context: ResolutionContext) async -> ResolutionOutcome
}

/// Executes resolved actions through public iOS APIs.
///
/// Read-only (risk 0) actions run via `executeReadOnly`. Anything with risk >= 1 must go through
/// `execute(_:token:)`, which re-validates the confirmation token against the exact PendingAction
/// id/version/digest immediately before the side effect. The executor reports only what the
/// native API actually returned (PRD §1.2, §23 rule 8).
public protocol ToolExecuting: Sendable {
    func executeReadOnly(_ action: ResolvedAction) async -> ToolResult
    func execute(_ action: PendingAction, token: ConfirmationToken) async -> ToolResult
}
