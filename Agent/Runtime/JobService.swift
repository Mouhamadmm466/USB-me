import Core
import Foundation
import Intelligence
import Telemetry

/// Everything jobs need, behind one door the coordinator can hold.
///
/// Planning, running, resuming and cancelling live here rather than in the coordinator, so the
/// conversation brain keeps its V1 shape: it decides *that* a job should be planned, and this
/// decides how.
public actor JobService {
    public let intelligence: PersonalIntelligence
    public nonisolated var store: IntelligenceStore { intelligence.store }
    private let planner: Planner
    private let runtime: AgentRuntime
    private let availability: @Sendable () async -> CapabilityAvailability
    private let logger: PrivacySafeLogger?

    public init(
        intelligence: PersonalIntelligence,
        planner: Planner,
        runtime: AgentRuntime,
        availability: @escaping @Sendable () async -> CapabilityAvailability = { .offline },
        logger: PrivacySafeLogger? = nil
    ) {
        self.intelligence = intelligence
        self.planner = planner
        self.runtime = runtime
        self.availability = availability
        self.logger = logger
    }

    /// Plans a job and saves it as a proposal. Nothing runs until `run` is called.
    public func plan(
        request: String, outcome: String, context: String? = nil, subjectID: UUID? = nil, now: Date = Date()
    ) async throws -> Plan {
        // The model's reading of the outcome is a hint for the planner; the request is the truth,
        // and is what the plan records and what the user sees.
        let hint = outcome.isEmpty || outcome == request ? request : "\(request)\nWhat they want: \(outcome)"
        // Things the request names are stripped before scope is decided, so an entity called
        // "call Bob" cannot smuggle a capability into a job by being mentioned.
        let mentioned = await intelligence.mentionedNames(in: request, now: now)
        let plan = try await planner.plan(
            for: hint, context: context, availability: await availability(), subjectID: subjectID,
            mentionedNames: mentioned, now: now
        )
        var proposal = plan
        proposal.request = request
        proposal.state = .proposed
        return try await store.save(proposal)
    }

    /// Runs an approved job, reporting the plan after every step so the card stays honest.
    @discardableResult
    public func run(
        _ planID: UUID, onUpdate: (@Sendable @MainActor (Plan) -> Void)? = nil
    ) async -> Plan? {
        guard var plan = try? await store.plan(planID), !plan.isFinished else { return nil }
        plan.state = .approved
        _ = try? await store.save(plan)

        var token: UUID?
        if let onUpdate {
            let store = store
            token = await runtime.observe { event in
                guard case .stepStarted = event else { return }
                Task { @MainActor in
                    if let updated = try? await store.plan(planID) { onUpdate(updated) }
                }
            }
        }
        defer { if let token { Task { await runtime.stopObserving(token) } } }
        return await runtime.run(plan)
    }

    public func resume(_ planID: UUID) async -> Plan? {
        await runtime.resume(planID)
    }

    public func cancel(_ planID: UUID) async {
        await runtime.cancel(planID)
    }

    /// Jobs that were still going when the app went away.
    public func resumable() async -> [Plan] {
        (try? await store.resumablePlans()) ?? []
    }

    /// What a finished job produced, if it produced something the user can open.
    public func artifactID(of plan: Plan) async -> UUID? {
        guard plan.state == .completed else { return nil }
        return try? await store.artifacts(limit: 1).first { $0.planID == plan.id }?.id
    }
}
