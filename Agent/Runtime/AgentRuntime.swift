import Core
import Foundation
import Intelligence
import Telemetry

/// Hard limits on a job. Every one of them exists because the alternative is a phone that gets hot
/// while a 4B model tries the same thing twelve times.
public struct RuntimeLimits: Sendable, Equatable {
    public var maximumSteps: Int
    public var maximumAttemptsPerStep: Int
    public var wallClock: TimeInterval
    /// Stop and hand back to the user when the device is this hot.
    public var thermalCeiling: ThermalState

    public init(
        maximumSteps: Int = 8,
        maximumAttemptsPerStep: Int = 2,
        wallClock: TimeInterval = 120,
        thermalCeiling: ThermalState = .serious
    ) {
        self.maximumSteps = maximumSteps
        self.maximumAttemptsPerStep = maximumAttemptsPerStep
        self.wallClock = wallClock
        self.thermalCeiling = thermalCeiling
    }
}

/// What happened while a plan ran, as it happens.
public enum RuntimeEvent: Sendable, Equatable {
    case started(UUID)
    case stepStarted(UUID, summary: String, index: Int, of: Int)
    case stepFinished(UUID, observation: String)
    case blocked(UUID, PlanBlocker, message: String)
    case finished(UUID, summary: String)
    case failed(UUID, reason: String)
    case cancelled(UUID)
}

/// Runs an approved plan, one step at a time, writing down what happened as it goes.
///
/// Swift owns the control flow: which step is next, whether it may run, whether to retry, when to
/// stop. The model's only role was writing the plan, and its only role from here on is filling in
/// text the user will read. Every step is checkpointed to the store before and after it runs, so a
/// job that is interrupted — by suspension, by a crash, by the user — can be resumed rather than
/// restarted.
public actor AgentRuntime {
    public let store: IntelligenceStore
    public var limits: RuntimeLimits
    private let executors: [any StepExecuting]
    private let clock: AgentClock
    private let logger: PrivacySafeLogger?
    private let thermal: @Sendable () -> ThermalState

    private var running: [UUID: Task<Plan, Never>] = [:]
    private var cancelled: Set<UUID> = []
    private var observers: [UUID: @Sendable (RuntimeEvent) -> Void] = [:]

    public init(
        store: IntelligenceStore,
        executors: [any StepExecuting],
        limits: RuntimeLimits = RuntimeLimits(),
        clock: AgentClock = AgentClock(),
        thermal: @escaping @Sendable () -> ThermalState = { ThermalProbe.current },
        logger: PrivacySafeLogger? = nil
    ) {
        self.store = store
        self.executors = executors
        self.limits = limits
        self.clock = clock
        self.thermal = thermal
        self.logger = logger
    }

    /// Receives events while jobs run. Returns a token to stop observing.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (RuntimeEvent) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func stopObserving(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: Running

    /// Starts an approved plan. Returns the plan as it ended — completed, blocked, failed or
    /// cancelled — and never throws: a job that goes wrong is a result, not an error.
    @discardableResult
    public func run(_ plan: Plan) async -> Plan {
        if let existing = running[plan.id] { return await existing.value }
        let task = Task { await execute(plan) }
        running[plan.id] = task
        let finished = await task.value
        running[plan.id] = nil
        return finished
    }

    /// Picks a plan back up where it stopped.
    @discardableResult
    public func resume(_ planID: UUID) async -> Plan? {
        guard var plan = try? await store.plan(planID), !plan.isFinished else { return nil }
        // A blocked plan only moves again once whatever blocked it has been dealt with.
        plan.blocker = nil
        plan.state = .approved
        return await run(plan)
    }

    /// Stops a job. The steps that already ran stay done; nothing new starts.
    public func cancel(_ planID: UUID) async {
        cancelled.insert(planID)
        running[planID]?.cancel()
        if var plan = try? await store.plan(planID), !plan.isFinished {
            plan.state = .cancelled
            plan.finishedAt = clock.now()
            _ = try? await store.save(plan)
            emit(.cancelled(planID))
        }
    }

    public func isRunning(_ planID: UUID) -> Bool { running[planID] != nil }

    // MARK: The loop

    private func execute(_ plan: Plan) async -> Plan {
        var plan = plan
        cancelled.remove(plan.id)
        plan.state = .running
        plan.blocker = nil
        plan.startedAt = plan.startedAt ?? clock.now()
        _ = try? await store.save(plan)
        emit(.started(plan.id))
        logger?.log(.counter(name: "runtime.plan.started", value: 1))

        let deadline = clock.now().addingTimeInterval(limits.wallClock)
        var history: [String] = plan.steps.compactMap(\.observation)
        // Attempts, not steps: a retry costs the runtime's hard ceiling but not the plan's budget,
        // which is about how much work the user agreed to, not how often it took to get there.
        var executions = 0

        while let next = plan.nextRunnableStep() {
            if cancelled.contains(plan.id) || Task.isCancelled {
                return await finish(plan, state: .cancelled, blocker: nil, summary: nil)
            }
            if plan.completedSteps >= plan.stepBudget || executions >= limits.maximumSteps {
                return await finish(plan, state: .blocked, blocker: .limitReached,
                                    summary: "I stopped after \(plan.completedSteps) steps.")
            }
            if clock.now() >= deadline {
                return await finish(plan, state: .blocked, blocker: .limitReached,
                                    summary: "This was taking too long, so I stopped.")
            }
            if thermal() >= limits.thermalCeiling {
                logger?.log(.thermal(state: SafeLabel(thermal())))
                return await finish(plan, state: .blocked, blocker: .thermal,
                                    summary: "Your phone is getting warm, so I paused.")
            }

            guard var step = plan.steps.first(where: { $0.id == next.id }) else { break }
            guard let executor = executors.first(where: { $0.handles(CapabilityID(step.capability)) }) else {
                step.state = .failed
                step.blocker = .failed
                step.observation = "\(step.capability) isn't available."
                plan = await record(step, in: plan)
                return await finish(plan, state: .failed, blocker: .failed,
                                    summary: "I couldn't do \(step.summary.lowercased()).")
            }

            step.state = .running
            step.startedAt = clock.now()
            step.attempts += 1
            plan = await record(step, in: plan)
            emit(.stepStarted(plan.id, summary: step.summary, index: step.ordinal + 1, of: plan.steps.count))

            let outcome = await executor.execute(step, plan: plan, history: history, now: clock.now())
            executions += 1

            switch outcome.result {
            case let .completed(observation):
                step.state = .completed
                step.observation = observation
                step.blocker = nil
                step.finishedAt = clock.now()
                history.append("\(step.summary): \(observation)")
                plan = await record(step, in: plan)
                emit(.stepFinished(plan.id, observation: observation))

            case let .blocked(blocker, message):
                step.state = .blocked
                step.blocker = blocker
                step.observation = message
                plan = await record(step, in: plan)
                emit(.blocked(plan.id, blocker, message: message))
                return await finish(plan, state: .blocked, blocker: blocker, summary: message)

            case let .failed(message):
                // One retry, then the job stops rather than grinding: a 4B model that failed a step
                // once usually fails it the same way twice.
                if step.attempts < limits.maximumAttemptsPerStep {
                    step.state = .proposed
                    step.observation = message
                    plan = await record(step, in: plan)
                    continue
                }
                step.state = .failed
                step.blocker = .failed
                step.observation = message
                step.finishedAt = clock.now()
                plan = await record(step, in: plan)
                return await finish(plan, state: .failed, blocker: .failed, summary: message)
            }
        }

        return await finish(plan, state: .completed, blocker: nil, summary: Self.summarize(plan, history: history))
    }

    /// Writes one step's new state and keeps the in-memory plan in step with it.
    private func record(_ step: PlanStep, in plan: Plan) async -> Plan {
        var plan = plan
        if let index = plan.steps.firstIndex(where: { $0.id == step.id }) {
            plan.steps[index] = step
        }
        try? await store.update(step)
        return plan
    }

    private func finish(_ plan: Plan, state: PlanState, blocker: PlanBlocker?, summary: String?) async -> Plan {
        var plan = plan
        plan.state = state
        plan.blocker = blocker
        plan.summary = summary ?? plan.summary
        plan.updatedAt = clock.now()
        if state.isFinished { plan.finishedAt = clock.now() }
        _ = try? await store.save(plan)

        switch state {
        case .completed:
            emit(.finished(plan.id, summary: plan.summary ?? "Done."))
            logger?.log(.counter(name: "runtime.plan.completed", value: 1))
            _ = try? await store.record(ActivityEntry(
                kind: .acted, headline: plan.title, detail: plan.summary,
                entityID: plan.id, createdAt: clock.now()
            ))
        case .failed:
            emit(.failed(plan.id, reason: plan.summary ?? "It didn't work."))
            logger?.log(.error(domain: "runtime", code: "plan_failed"))
        case .cancelled:
            emit(.cancelled(plan.id))
        default:
            break
        }
        return plan
    }

    private func emit(_ event: RuntimeEvent) {
        for observer in observers.values { observer(event) }
    }

    /// What the user is told at the end: what was done, in the plan's own words. Swift writes this,
    /// not the model, so it can never claim something that did not happen.
    static func summarize(_ plan: Plan, history: [String]) -> String {
        let done = plan.steps.filter { $0.state == .completed }
        guard !done.isEmpty else { return "I couldn't get anywhere with that." }
        if let artifact = done.last(where: { $0.capability == CapabilityID.writeArtifact.rawValue }),
           let observation = artifact.observation {
            return observation
        }
        if done.count == 1, let observation = done[0].observation {
            return observation
        }
        return "Done: " + done.map { $0.summary.lowercased() }.joined(separator: ", ") + "."
    }
}
