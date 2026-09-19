import Core
import Foundation
import LLM

/// What the agent did in response to one user utterance. Consumed by tests, the evaluation
/// harness and the diagnostics screen. Contains user content; never logged.
public struct TurnReport: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable, CaseIterable {
        case answered
        case clarificationRequested = "clarification_requested"
        case confirmationRequested = "confirmation_requested"
        case executed
        case cancelled
        case unsupported
        case permissionRequired = "permission_required"
        case reprompted
        case deferred
        case noAction = "no_action"
    }

    public struct Execution: Sendable, Equatable {
        public let action: ResolvedAction
        public let result: ToolResult
        /// Risk >= 1 (a real side effect was attempted through a native API).
        public let consequential: Bool
    }

    public var outcome: Outcome = .noAction
    public var spokenText: String = ""
    /// The pending action awaiting confirmation after this turn, if any.
    public var pendingAction: PendingAction?
    public var clarification: PendingClarification?
    public var executions: [Execution] = []
    public var modelOutputs: [String] = []
    public var modelMilliseconds: Double = 0
    public var validationErrors: [OutputValidationError] = []
    /// True when the turn ended because the user barged in over the assistant.
    public var interrupted = false

    public init() {}

    /// Consequential side effects that the native layer actually carried out (or handed to
    /// Apple's own UI, which the user then dismissed).
    public var consequentialExecutions: [Execution] {
        executions.filter { execution in
            guard execution.consequential else { return false }
            switch execution.result {
            case .success, .cancelledByUser: return true
            case .failure: return false
            }
        }
    }
}
