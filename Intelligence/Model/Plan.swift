import Foundation
import Telemetry

/// What a plan or one of its steps is doing right now.
public enum PlanState: String, CaseIterable, Sendable, Codable, Hashable, SafeLabelConvertible {
    /// Written by the model, not yet agreed to.
    case proposed
    /// The user said go.
    case approved
    case running
    /// Waiting on something: a permission, the network, an answer from the user.
    case blocked
    case completed
    case failed
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .proposed, .approved, .running, .blocked: false
        }
    }

    public var isLive: Bool { self == .running || self == .approved }
}

/// Why a step or plan stopped, in words the user can act on.
public enum PlanBlocker: String, CaseIterable, Sendable, Codable, Hashable, SafeLabelConvertible {
    case needsPermission
    case needsNetwork
    case needsConnection
    case needsConfirmation
    case needsAnswer
    case limitReached
    case thermal
    case failed

    public var isWaitingOnUser: Bool {
        switch self {
        case .needsPermission, .needsConfirmation, .needsAnswer, .needsConnection: true
        case .needsNetwork, .limitReached, .thermal, .failed: false
        }
    }
}

/// One thing the agent will do, and what it depends on.
///
/// A step names a capability and its arguments; Swift decides whether that capability may run at
/// all, asks for confirmation when it matters, and executes it. The model never executes anything
/// and never sees an identifier it did not receive.
public struct PlanStep: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public var planID: UUID
    public var ordinal: Int
    /// The capability to run, by name. Validated against the registry before the plan is stored.
    public var capability: String
    /// One line in the user's terms: "Read the syllabus for the midterm date".
    public var summary: String
    public var arguments: [String: String]
    /// Steps that must finish first. Always earlier in the plan (checked when the plan is validated).
    public var dependsOn: [UUID]
    public var requiresNetwork: Bool
    public var risk: Int
    public var state: PlanState
    public var blocker: PlanBlocker?
    /// What came of it, summarized for the next step's context — never the raw tool output.
    public var observation: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var attempts: Int

    public init(
        id: UUID = UUID(),
        planID: UUID,
        ordinal: Int,
        capability: String,
        summary: String,
        arguments: [String: String] = [:],
        dependsOn: [UUID] = [],
        requiresNetwork: Bool = false,
        risk: Int = 0,
        state: PlanState = .proposed,
        blocker: PlanBlocker? = nil,
        observation: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        attempts: Int = 0
    ) {
        self.id = id
        self.planID = planID
        self.ordinal = ordinal
        self.capability = capability
        self.summary = summary
        self.arguments = arguments
        self.dependsOn = dependsOn
        self.requiresNetwork = requiresNetwork
        self.risk = risk
        self.state = state
        self.blocker = blocker
        self.observation = observation
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.attempts = attempts
    }

    public var isFinished: Bool { state.isFinished }
}

/// A job the agent is doing on the user's behalf.
///
/// Carries its own capability allowlist: a plan built to research something cannot send a message,
/// no matter what a web page it reads asks for. The scope is decided when the plan is made, from
/// the request, and never widened by anything the plan reads.
public struct Plan: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    /// The user's own words, kept verbatim so the plan can always be explained.
    public var request: String
    /// One line of what the plan is for.
    public var title: String
    /// The goal or project this serves, when it has one.
    public var subjectID: UUID?
    public var state: PlanState
    public var blocker: PlanBlocker?
    /// Capabilities this job may use. Empty means nothing may run.
    public var scope: [String]
    public var steps: [PlanStep]
    public var stepBudget: Int
    public var summary: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        request: String,
        title: String,
        subjectID: UUID? = nil,
        state: PlanState = .proposed,
        blocker: PlanBlocker? = nil,
        scope: [String] = [],
        steps: [PlanStep] = [],
        stepBudget: Int = 8,
        summary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.request = request
        self.title = title
        self.subjectID = subjectID
        self.state = state
        self.blocker = blocker
        self.scope = scope
        self.steps = steps
        self.stepBudget = stepBudget
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// The next step whose dependencies are all done.
    public func nextRunnableStep() -> PlanStep? {
        let finished = Set(steps.filter { $0.state == .completed }.map(\.id))
        return steps
            .sorted { $0.ordinal < $1.ordinal }
            .first { step in
                (step.state == .proposed || step.state == .approved || step.state == .blocked)
                    && step.dependsOn.allSatisfy(finished.contains)
            }
    }

    public var completedSteps: Int { steps.count { $0.state == .completed } }
    public var isFinished: Bool { state.isFinished }

    /// True when every step has finished one way or another.
    public var allStepsSettled: Bool { steps.allSatisfy(\.isFinished) }

    /// "Step 2 of 5: Read the syllabus" — what the user sees while it runs, and what the next
    /// turn's context says the agent is in the middle of.
    public func progressLine() -> String? {
        guard state.isLive, let current = steps.first(where: { $0.state == .running }) ?? nextRunnableStep() else {
            return nil
        }
        return "Running: \(current.summary) (step \(current.ordinal + 1) of \(steps.count))"
    }

    /// Does this plan ever need the network? Decides whether it can run in airplane mode at all.
    public var requiresNetwork: Bool { steps.contains { $0.requiresNetwork } }
}
