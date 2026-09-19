import CryptoKit
import Foundation

public enum ConfirmationStatus: String, Codable, Sendable {
    case pending
    case approved
    case rejected
}

/// A proposed consequential action awaiting (or holding) confirmation (PRD §9).
///
/// Immutable apart from `confirmationStatus`. Any argument change produces a *new version* via
/// `revised(...)` with approval cleared, so a "yes" can never apply to arguments the user has not
/// heard.
public struct PendingAction: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let version: Int
    public let tool: ToolID
    public let validatedArguments: ResolvedAction
    public let humanReadableSummary: String
    public let originalTranscript: String
    public let createdAt: Date
    public let expiresAt: Date
    public let riskLevel: RiskLevel
    public let confirmationRequired: Bool
    public private(set) var confirmationStatus: ConfirmationStatus
    /// SHA-256 over the canonical encoding of `validatedArguments`.
    public let argumentsDigest: String

    public init(
        id: UUID = UUID(),
        version: Int = 1,
        action: ResolvedAction,
        humanReadableSummary: String,
        originalTranscript: String,
        createdAt: Date,
        lifetime: TimeInterval
    ) {
        self.id = id
        self.version = version
        tool = action.tool
        validatedArguments = action
        self.humanReadableSummary = humanReadableSummary
        self.originalTranscript = originalTranscript
        self.createdAt = createdAt
        expiresAt = createdAt.addingTimeInterval(lifetime)
        riskLevel = action.riskLevel
        // Policy is derived from the risk level, never from the model's `requires_confirmation`.
        confirmationRequired = action.riskLevel.requiresConfirmation
        confirmationStatus = .pending
        argumentsDigest = ActionDigest.digest(of: action)
    }

    /// A new version with changed arguments. Approval is always cleared.
    public func revised(
        action: ResolvedAction,
        humanReadableSummary: String,
        originalTranscript: String,
        now: Date,
        lifetime: TimeInterval
    ) -> PendingAction {
        PendingAction(
            id: id,
            version: version + 1,
            action: action,
            humanReadableSummary: humanReadableSummary,
            originalTranscript: originalTranscript,
            createdAt: now,
            lifetime: lifetime
        )
    }

    public func isExpired(at date: Date) -> Bool { date >= expiresAt }

    /// Issues a token binding approval to this exact id, version and argument digest.
    /// Returns nil when the action is expired or already decided.
    public mutating func approve(at date: Date) -> ConfirmationToken? {
        guard confirmationStatus == .pending, !isExpired(at: date) else { return nil }
        confirmationStatus = .approved
        return ConfirmationToken(actionID: id, version: version, argumentsDigest: argumentsDigest, issuedAt: date)
    }

    public mutating func reject() {
        confirmationStatus = .rejected
    }

    /// Validates a token against this action. Used by the executor right before any side effect.
    public func accepts(_ token: ConfirmationToken, at date: Date) -> Bool {
        confirmationStatus == .approved
            && token.actionID == id
            && token.version == version
            && token.argumentsDigest == argumentsDigest
            && ActionDigest.digest(of: validatedArguments) == argumentsDigest
            && !isExpired(at: date)
    }
}

/// Proof that the user approved one exact PendingAction version.
public struct ConfirmationToken: Sendable, Equatable {
    public let actionID: UUID
    public let version: Int
    public let argumentsDigest: String
    public let issuedAt: Date
}

public enum ActionDigest {
    public static func digest(of action: ResolvedAction) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = (try? encoder.encode(action)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
