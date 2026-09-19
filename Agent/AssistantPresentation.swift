import Core
import Foundation

/// Everything the assistant screen renders. Produced by the coordinator on the main actor;
/// the SwiftUI layer is a pure function of this value plus user intents.
public struct AssistantPresentation: Sendable, Equatable {
    public var state: AgentState
    /// Unstable live hypothesis while the user speaks (UI-only).
    public var partialTranscript: String?
    /// The last finalized user utterance.
    public var lastUserUtterance: String?
    /// What the assistant is saying or last said.
    public var assistantText: String?
    /// Recent conversation (bounded).
    public var turns: [ConversationTurn]
    /// Visible card for a consequential action awaiting confirmation (PRD §19).
    public var actionCard: ActionCard?
    /// Candidates offered in a clarification ("Alex Kim" / "Alex Chen").
    public var clarificationChoices: [ClarificationChoice]
    public var permissionPrompt: PermissionPrompt?
    /// Result of the last executed action, shown briefly.
    public var resultBanner: ResultBanner?
    /// Microphone input level 0...1 (drives the orb while listening).
    public var inputLevel: Float
    /// Assistant output level 0...1 (drives the orb while speaking).
    public var outputLevel: Float
    public var isSessionActive: Bool

    public init(
        state: AgentState = .booting,
        partialTranscript: String? = nil,
        lastUserUtterance: String? = nil,
        assistantText: String? = nil,
        turns: [ConversationTurn] = [],
        actionCard: ActionCard? = nil,
        clarificationChoices: [ClarificationChoice] = [],
        permissionPrompt: PermissionPrompt? = nil,
        resultBanner: ResultBanner? = nil,
        inputLevel: Float = 0,
        outputLevel: Float = 0,
        isSessionActive: Bool = false
    ) {
        self.state = state
        self.partialTranscript = partialTranscript
        self.lastUserUtterance = lastUserUtterance
        self.assistantText = assistantText
        self.turns = turns
        self.actionCard = actionCard
        self.clarificationChoices = clarificationChoices
        self.permissionPrompt = permissionPrompt
        self.resultBanner = resultBanner
        self.inputLevel = inputLevel
        self.outputLevel = outputLevel
        self.isSessionActive = isSessionActive
    }
}

/// Exact, deterministic rendering of a PendingAction: recipient, date/time and content.
public struct ActionCard: Sendable, Equatable, Identifiable {
    public struct Field: Sendable, Equatable, Hashable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public let id: UUID
    public let version: Int
    public let tool: ToolID
    /// "Send message", "Call", "Add to calendar", "Update event", "Create reminder".
    public let title: String
    /// SF Symbol name.
    public let systemImage: String
    public let fields: [Field]
    /// "Send", "Call", "Add", "Update", "Create".
    public let confirmLabel: String
    public let riskLevel: RiskLevel
    public let expiresAt: Date
    /// Explains that Apple's own screen will still ask (messages/calls).
    public let footnote: String?

    public init(id: UUID, version: Int, tool: ToolID, title: String, systemImage: String, fields: [Field],
                confirmLabel: String, riskLevel: RiskLevel, expiresAt: Date, footnote: String?) {
        self.id = id
        self.version = version
        self.tool = tool
        self.title = title
        self.systemImage = systemImage
        self.fields = fields
        self.confirmLabel = confirmLabel
        self.riskLevel = riskLevel
        self.expiresAt = expiresAt
        self.footnote = footnote
    }
}

public struct ClarificationChoice: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?

    public init(id: String, title: String, subtitle: String?) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

public struct PermissionPrompt: Sendable, Equatable {
    public let kind: PermissionKind
    public let title: String
    public let message: String
    /// True when iOS will no longer show the system prompt and Settings is the only path.
    public let requiresSettings: Bool

    public init(kind: PermissionKind, title: String, message: String, requiresSettings: Bool) {
        self.kind = kind
        self.title = title
        self.message = message
        self.requiresSettings = requiresSettings
    }
}

public struct ResultBanner: Sendable, Equatable {
    public enum Style: String, Sendable { case success, cancelled, failure }

    public let style: Style
    public let text: String
    public let systemImage: String

    public init(style: Style, text: String, systemImage: String) {
        self.style = style
        self.text = text
        self.systemImage = systemImage
    }
}
