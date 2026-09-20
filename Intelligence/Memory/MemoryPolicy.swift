import Foundation
import Telemetry

/// What happens to a statement that passed validation.
public enum MemoryDecision: String, Sendable, Equatable, CaseIterable, SafeLabelConvertible {
    /// Written straight away, and shown in the activity feed with an undo.
    case accept
    /// Written as `proposed`: the user is asked before it counts.
    case confirm
    /// Not written at all.
    case drop
}

/// The user's settings for what the system is allowed to learn. Every field is something they can
/// see and change; nothing here is implicit.
public struct MemoryPolicySettings: Sendable, Equatable, Codable {
    /// The master switch. Off means the system answers from what it already knows and learns nothing.
    public var learningEnabled: Bool
    /// Ask before keeping anything the model worked out rather than was told.
    public var confirmInferences: Bool
    /// Ask before keeping anything read from a document, a page or a connected service.
    public var confirmObservations: Bool
    /// Below this, an inference is not even worth a question.
    public var minimumInferenceConfidence: Double

    public init(
        learningEnabled: Bool = true,
        confirmInferences: Bool = true,
        confirmObservations: Bool = false,
        minimumInferenceConfidence: Double = 0.6
    ) {
        self.learningEnabled = learningEnabled
        self.confirmInferences = confirmInferences
        self.confirmObservations = confirmObservations
        self.minimumInferenceConfidence = minimumInferenceConfidence
    }

    public static let `default` = MemoryPolicySettings()
    /// Nothing is learned; used by the "don't remember this" control and by incognito turns.
    public static let off = MemoryPolicySettings(learningEnabled: false)
}

/// Decides whether a statement is kept, questioned or thrown away.
///
/// The asymmetry is deliberate: what the user says about their own world is taken at face value,
/// while anything the system worked out or read somewhere has to earn its place. Being wrong in
/// silence is worse than asking.
public struct MemoryPolicy: Sendable {
    public var settings: MemoryPolicySettings

    public init(settings: MemoryPolicySettings = .default) { self.settings = settings }

    public func decide(_ memory: ValidatedMemory) -> MemoryDecision {
        guard settings.learningEnabled else { return .drop }

        switch memory.type {
        case .explicit:
            // The user said it. Ending something they said is equally theirs to end.
            return .accept
        case .observed:
            return settings.confirmObservations ? .confirm : .accept
        case .inferred:
            guard memory.proposal.confidence >= settings.minimumInferenceConfidence else { return .drop }
            // Retracting something on a guess always asks: an unasked-for deletion is not recoverable
            // in the user's head, even when the row survives.
            if memory.proposal.operation == .end { return .confirm }
            return settings.confirmInferences ? .confirm : .accept
        case .derived:
            return .accept
        }
    }
}
