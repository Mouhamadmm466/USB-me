import Core
import Foundation
import Telemetry

/// The output types the model may produce (PRD §7, extended in V2 with `task`).
public enum AgentOutputType: String, Codable, Sendable, CaseIterable, SafeLabelConvertible {
    case answer
    case clarification
    case proposedAction = "proposed_action"
    /// A job: something that takes several steps and produces something, rather than one tool call.
    case task
    case unsupported
}

/// A structurally valid model output. Still untrusted: a `proposed_action` must be resolved
/// natively and (for risk >= 1) confirmed before anything executes.
public enum AgentOutput: Sendable, Equatable {
    case answer(speech: String)
    case clarification(speech: String)
    case unsupported(speech: String)
    /// `modelRequestedConfirmation` is recorded for evaluation only; policy comes from `RiskLevel`.
    case proposedAction(ProposedToolCall, modelRequestedConfirmation: Bool)
    /// The request is a job, not a command: `outcome` is what the user wants to end up with, in
    /// their own terms. Planning it is a separate, scoped pass — the model does not plan here.
    case task(outcome: String)

    public var type: AgentOutputType {
        switch self {
        case .answer: .answer
        case .clarification: .clarification
        case .unsupported: .unsupported
        case .proposedAction: .proposedAction
        case .task: .task
        }
    }

    public var speech: String? {
        switch self {
        case let .answer(speech), let .clarification(speech), let .unsupported(speech): speech
        case .proposedAction, .task: nil
        }
    }

    /// What the user wants to end up with, when this is a job.
    public var outcome: String? {
        if case let .task(outcome) = self { return outcome }
        return nil
    }
}

/// Why a model output was rejected. Every case leads to recovery, never to execution.
public enum OutputValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformedJSON
    case notAnObject
    case unknownType(String)
    case missingField(String)
    case unexpectedField(String)
    case wrongFieldType(String)
    case unknownTool(String)
    case unknownArgument(tool: ToolID, argument: String)
    case missingRequiredArgument(tool: ToolID, argument: String)
    case invalidEnumValue(tool: ToolID, argument: String)
    case valueTooLong(field: String, limit: Int)
    case valueOutOfRange(field: String)
    case invalidPhoneNumber
    case emptyValue(field: String)
    case missingOneOf(tool: ToolID, arguments: [String])
    case disallowedCharacters(field: String)

    public var description: String {
        switch self {
        case .malformedJSON: "malformed JSON"
        case .notAnObject: "top level is not an object"
        case let .unknownType(type): "unknown type \(type)"
        case let .missingField(field): "missing field \(field)"
        case let .unexpectedField(field): "unexpected field \(field)"
        case let .wrongFieldType(field): "wrong type for \(field)"
        case let .unknownTool(tool): "unknown tool \(tool)"
        case let .unknownArgument(tool, argument): "unknown argument \(argument) for \(tool.rawValue)"
        case let .missingRequiredArgument(tool, argument): "missing \(argument) for \(tool.rawValue)"
        case let .invalidEnumValue(tool, argument): "invalid value for \(argument) in \(tool.rawValue)"
        case let .valueTooLong(field, limit): "\(field) longer than \(limit)"
        case let .valueOutOfRange(field): "\(field) out of range"
        case .invalidPhoneNumber: "invalid phone number"
        case let .emptyValue(field): "empty \(field)"
        case let .missingOneOf(tool, arguments): "\(tool.rawValue) needs one of \(arguments.joined(separator: ", "))"
        case let .disallowedCharacters(field): "disallowed characters in \(field)"
        }
    }

    /// Privacy-safe code for telemetry.
    public var code: SafeLabel {
        switch self {
        case .malformedJSON: "malformed_json"
        case .notAnObject: "not_object"
        case .unknownType: "unknown_type"
        case .missingField: "missing_field"
        case .unexpectedField: "unexpected_field"
        case .wrongFieldType: "wrong_field_type"
        case .unknownTool: "unknown_tool"
        case .unknownArgument: "unknown_argument"
        case .missingRequiredArgument: "missing_required_argument"
        case .invalidEnumValue: "invalid_enum"
        case .valueTooLong: "value_too_long"
        case .valueOutOfRange: "value_out_of_range"
        case .invalidPhoneNumber: "invalid_phone"
        case .emptyValue: "empty_value"
        case .missingOneOf: "missing_one_of"
        case .disallowedCharacters: "disallowed_characters"
        }
    }
}
