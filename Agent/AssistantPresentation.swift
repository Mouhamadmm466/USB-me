import Core
import Foundation
import Intelligence

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
    /// A job the assistant has planned and is waiting to be allowed to run, or is running now.
    public var jobCard: JobCard?
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
        jobCard: JobCard? = nil,
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
        self.jobCard = jobCard
        self.inputLevel = inputLevel
        self.outputLevel = outputLevel
        self.isSessionActive = isSessionActive
    }
}

/// A job as the user sees it: what it will do, step by step, and where it has got to.
///
/// The steps are the plan's own summaries, written before anything ran, so approving this card is
/// approving exactly what will happen — and while it runs, the same card says which step is live.
public struct JobCard: Sendable, Equatable, Identifiable {
    public struct Step: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let summary: String
        public let state: PlanState
        /// True when this step will stop to ask before it does anything outside the phone.
        public let needsConfirmation: Bool

        public init(id: UUID, summary: String, state: PlanState, needsConfirmation: Bool) {
            self.id = id
            self.summary = summary
            self.state = state
            self.needsConfirmation = needsConfirmation
        }
    }

    public let id: UUID
    public let title: String
    public let request: String
    public let steps: [Step]
    public let state: PlanState
    public let blocker: PlanBlocker?
    /// What the assistant is waiting for, or what came of the job.
    public let message: String?
    /// Something the job produced and the user can open.
    public let artifactID: UUID?

    public init(
        id: UUID, title: String, request: String, steps: [Step], state: PlanState,
        blocker: PlanBlocker? = nil, message: String? = nil, artifactID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.request = request
        self.steps = steps
        self.state = state
        self.blocker = blocker
        self.message = message
        self.artifactID = artifactID
    }

    public var isAwaitingApproval: Bool { state == .proposed }
    public var isRunning: Bool { state == .running }

    public init(plan: Plan, message: String? = nil, artifactID: UUID? = nil) {
        self.init(
            id: plan.id,
            title: plan.title,
            request: plan.request,
            steps: plan.steps.sorted { $0.ordinal < $1.ordinal }.map {
                Step(id: $0.id, summary: $0.summary, state: $0.state,
                     needsConfirmation: $0.risk >= RiskLevel.externalCommunication.rawValue)
            },
            state: plan.state,
            blocker: plan.blocker,
            message: message ?? plan.summary,
            artifactID: artifactID
        )
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
