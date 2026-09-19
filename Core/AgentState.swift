import Foundation
import Telemetry

/// What the assistant is doing right now. Swift owns this state; model output never mutates it
/// directly (PRD §5). Every transition is validated against `AgentStateMachine.allowed`.
public enum AgentState: String, CaseIterable, Codable, Sendable, SafeLabelConvertible {
    case booting
    case downloadingModels
    case warmingModels
    case idle
    case listening
    case endpointing
    case transcribing
    case thinking
    case speaking
    case waitingForClarification
    case waitingForConfirmation
    case executing
    case reportingResult
    case interrupted
    case permissionRequired
    case error

    /// User-facing label (PRD §19: Listening, Understanding, Speaking, Waiting for confirmation, Executing).
    public var displayLabel: String {
        switch self {
        case .booting: "Starting"
        case .downloadingModels: "Downloading models"
        case .warmingModels: "Preparing"
        case .idle: "Ready"
        case .listening: "Listening"
        case .endpointing: "Listening"
        case .transcribing: "Understanding"
        case .thinking: "Understanding"
        case .speaking: "Speaking"
        case .waitingForClarification: "Waiting for your answer"
        case .waitingForConfirmation: "Waiting for confirmation"
        case .executing: "Executing"
        case .reportingResult: "Speaking"
        case .interrupted: "Listening"
        case .permissionRequired: "Permission needed"
        case .error: "Something went wrong"
        }
    }

    /// States in which the microphone pipeline is expected to be capturing.
    public var capturesAudio: Bool {
        switch self {
        case .listening, .endpointing, .speaking, .reportingResult, .waitingForConfirmation,
             .waitingForClarification, .interrupted:
            true
        default:
            false
        }
    }

    /// States in which the assistant's own voice may be playing (barge-in is possible).
    public var assistantIsSpeaking: Bool {
        self == .speaking || self == .reportingResult
    }
}

/// Privacy-safe reason attached to each transition (logged; contains no user content).
public enum TransitionReason: String, Codable, Sendable, SafeLabelConvertible {
    case launch
    case modelsMissing
    case modelsDownloaded
    case modelsReady
    case modelIntegrityFailure
    case memoryPressure
    case userStartedSession
    case userStoppedSession
    case typedInput
    case speechDetected
    case speechResumed
    case silenceDetected
    case transcriptReady
    case emptyTranscript
    case agentAnswered
    case agentUnsupported
    case clarificationRequested
    case confirmationRequested
    case autoExecuteReadOnly
    case userApproved
    case userRejected
    case userDeferred
    case userModified
    case confirmationUnclear
    case confirmationExpired
    case toolFinished
    case speechFinished
    case bargeIn
    case permissionNeeded
    case permissionResolved
    case permissionDenied
    case cancelled
    case timeout
    case audioInterruption
    case appBackgrounded
    case recovered
    case failure
}

public struct IllegalTransition: Error, Equatable, Sendable, CustomStringConvertible {
    public let from: AgentState
    public let to: AgentState
    public let reason: TransitionReason
    public var description: String { "Illegal transition \(from.rawValue) -> \(to.rawValue) (\(reason.rawValue))" }
}

public struct TransitionRecord: Equatable, Sendable {
    public let from: AgentState
    public let to: AgentState
    public let reason: TransitionReason
    public let date: Date
}

/// Deterministic, explicit state machine (PRD §5). Illegal transitions throw and are never applied.
public struct AgentStateMachine: Sendable {
    public private(set) var current: AgentState
    public private(set) var history: [TransitionRecord] = []
    private let historyLimit: Int
    private let logger: PrivacySafeLogger?

    public init(initial: AgentState = .booting, historyLimit: Int = 200, logger: PrivacySafeLogger? = .shared) {
        current = initial
        self.historyLimit = historyLimit
        self.logger = logger
    }

    /// The complete transition table. `error` is reachable from every state; the rest is explicit.
    public static let allowed: [AgentState: Set<AgentState>] = [
        .booting: [.downloadingModels, .warmingModels, .idle],
        .downloadingModels: [.warmingModels, .idle],
        .warmingModels: [.idle, .downloadingModels],
        .idle: [.listening, .thinking, .warmingModels, .downloadingModels, .permissionRequired],
        .listening: [.endpointing, .idle, .permissionRequired, .waitingForConfirmation, .waitingForClarification],
        .endpointing: [.transcribing, .listening, .idle],
        .transcribing: [.thinking, .listening, .idle, .executing, .speaking,
                        .waitingForConfirmation, .waitingForClarification],
        .thinking: [.speaking, .executing, .waitingForConfirmation, .waitingForClarification,
                    .permissionRequired, .idle, .interrupted, .listening],
        // .executing / .thinking: the user tapped Confirm or typed while the prompt was still playing.
        .speaking: [.waitingForConfirmation, .waitingForClarification, .idle, .listening, .interrupted,
                    .executing, .thinking],
        .waitingForClarification: [.listening, .thinking, .idle, .speaking, .permissionRequired],
        .waitingForConfirmation: [.listening, .executing, .idle, .speaking, .thinking],
        .executing: [.reportingResult, .permissionRequired, .idle],
        .reportingResult: [.idle, .listening, .interrupted, .thinking, .waitingForConfirmation,
                           .waitingForClarification],
        .interrupted: [.listening, .idle, .thinking],
        .permissionRequired: [.idle, .listening, .thinking, .executing, .speaking],
        .error: [.idle, .booting, .downloadingModels, .warmingModels],
    ]

    public static func canTransition(from: AgentState, to: AgentState) -> Bool {
        if from == to { return false }
        if to == .error { return from != .error }
        return allowed[from, default: []].contains(to)
    }

    @discardableResult
    public mutating func transition(to next: AgentState, reason: TransitionReason, now: Date = Date()) throws -> TransitionRecord {
        guard Self.canTransition(from: current, to: next) else {
            logger?.log(.safety(check: "illegal_transition", outcome: SafeLabel(next)))
            throw IllegalTransition(from: current, to: next, reason: reason)
        }
        let record = TransitionRecord(from: current, to: next, reason: reason, date: now)
        current = next
        history.append(record)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        logger?.log(.stateTransition(from: SafeLabel(record.from), to: SafeLabel(next), reason: SafeLabel(reason)))
        return record
    }

    /// Moves to `error` from anywhere (except `error` itself). Never throws.
    public mutating func fail(reason: TransitionReason = .failure, now: Date = Date()) {
        guard current != .error else { return }
        _ = try? transition(to: .error, reason: reason, now: now)
    }
}
