import Core
import Foundation
import Intelligence
import Telemetry

/// What a step produced. Deliberately small: the next step sees a summary, never a raw tool result,
/// so a long document or a chatty API cannot push the user's own context out of the budget.
public struct StepOutcome: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        /// Done. The observation is what the next step (and the user) gets to see.
        case completed(String)
        /// Cannot proceed until something happens outside the runtime.
        case blocked(PlanBlocker, String)
        /// Tried and failed. The runtime decides whether to retry or give up.
        case failed(String)
    }

    public var result: Result
    /// Entities this step touched, so the plan's summary can link to them.
    public var entityIDs: [UUID]

    public init(result: Result, entityIDs: [UUID] = []) {
        self.result = result
        self.entityIDs = entityIDs
    }

    public static func completed(_ observation: String, entityIDs: [UUID] = []) -> StepOutcome {
        StepOutcome(result: .completed(observation), entityIDs: entityIDs)
    }

    public static func blocked(_ blocker: PlanBlocker, _ message: String) -> StepOutcome {
        StepOutcome(result: .blocked(blocker, message))
    }

    public static func failed(_ message: String) -> StepOutcome {
        StepOutcome(result: .failed(message))
    }

    public var observation: String? {
        if case let .completed(text) = result { return text }
        return nil
    }
}

/// Runs one step. Implemented once for the user's own world and once for the device's tools, so
/// the runtime itself never knows how any particular capability works.
public protocol StepExecuting: Sendable {
    /// True when this executor handles the capability at all.
    func handles(_ capability: CapabilityID) -> Bool
    /// Runs the step. `history` is what earlier steps observed, oldest first.
    func execute(_ step: PlanStep, plan: Plan, history: [String], now: Date) async -> StepOutcome
}

/// The capabilities that only need what is already on the device: the user's documents, what is
/// known about their world, and writing something down.
///
/// Nothing here can leave the phone or touch anything outside the intelligence store, which is why
/// these are the capabilities every playbook is allowed to use.
public struct IntelligenceStepExecutor: StepExecuting {
    public let intelligence: PersonalIntelligence
    public let artifacts: (any ArtifactWriting)?
    public var maximumObservation: Int
    private let logger: PrivacySafeLogger?

    public init(
        intelligence: PersonalIntelligence,
        artifacts: (any ArtifactWriting)? = nil,
        maximumObservation: Int = 400,
        logger: PrivacySafeLogger? = nil
    ) {
        self.intelligence = intelligence
        self.artifacts = artifacts
        self.maximumObservation = maximumObservation
        self.logger = logger
    }

    public func handles(_ capability: CapabilityID) -> Bool {
        [CapabilityID.searchKnowledge, .readDocument, .searchIntelligence, .writeArtifact, .remember, .askUser]
            .contains(capability)
    }

    public func execute(_ step: PlanStep, plan: Plan, history: [String], now: Date) async -> StepOutcome {
        switch CapabilityID(step.capability) {
        case .searchKnowledge: return await searchKnowledge(step, now: now)
        case .readDocument: return await readDocument(step, now: now)
        case .searchIntelligence: return await searchIntelligence(step, now: now)
        case .writeArtifact: return await writeArtifact(step, plan: plan, history: history, now: now)
        case .remember: return await remember(step, plan: plan, now: now)
        case .askUser:
            let question = step.arguments["question"] ?? "Could you tell me a bit more?"
            return .blocked(.needsAnswer, question)
        default:
            return .failed("\(step.capability) isn't something I can run.")
        }
    }

    // MARK: Capabilities

    private func searchKnowledge(_ step: PlanStep, now: Date) async -> StepOutcome {
        guard let query = step.arguments["query"] else { return .failed("No query.") }
        do {
            let passages = try await intelligence.passages(for: query, limit: 3, now: now)
            guard !passages.isEmpty else {
                return .completed("Nothing in the user's documents covers \(quoted(query)).")
            }
            let quoted = passages.map { "\($0.citation): \(trim($0.chunk.text))" }
            return .completed(quoted.joined(separator: "\n"), entityIDs: passages.map(\.document.id))
        } catch {
            return .failed("The documents couldn't be searched.")
        }
    }

    private func readDocument(_ step: PlanStep, now: Date) async -> StepOutcome {
        guard let name = step.arguments["document"] else { return .failed("No document.") }
        do {
            guard let entity = try await intelligence.store.resolve(title: name, kind: .document),
                  let document = try await intelligence.store.document(entity.id) else {
                return .completed("There's no document called \(quoted(name)).")
            }
            let about = step.arguments["about"] ?? name
            let passages = try await intelligence.store.passages(
                matching: about, limit: 3, documentID: document.id, now: now
            )
            let chunks = passages.isEmpty
                ? try await intelligence.store.chunks(of: document.id).prefix(2).map { $0.text }
                : passages.map(\.chunk.text)
            guard !chunks.isEmpty else { return .completed("\(document.title) has nothing in it to read.") }
            return .completed(
                "From \(document.title): " + chunks.map(trim).joined(separator: " … "),
                entityIDs: [document.id]
            )
        } catch {
            return .failed("That document couldn't be read.")
        }
    }

    private func searchIntelligence(_ step: PlanStep, now: Date) async -> StepOutcome {
        guard let query = step.arguments["query"] else { return .failed("No query.") }
        do {
            let context = try await intelligence.context(for: query, now: now)
            guard !context.isEmpty else {
                let found = try await intelligence.store.search(query, limit: 3)
                guard !found.isEmpty else { return .completed("Nothing known about \(quoted(query)) yet.") }
                return .completed(
                    found.map { "\($0.title) (\($0.kind.rawValue))" }.joined(separator: ", "),
                    entityIDs: found.map(\.id)
                )
            }
            return .completed(
                context.lines.map(\.text).joined(separator: "\n"), entityIDs: context.entityIDs
            )
        } catch {
            return .failed("What's known couldn't be searched.")
        }
    }

    private func writeArtifact(_ step: PlanStep, plan: Plan, history: [String], now: Date) async -> StepOutcome {
        guard let artifacts else { return .failed("Writing isn't available.") }
        guard let title = step.arguments["title"], let about = step.arguments["about"] else {
            return .failed("Nothing to write.")
        }
        let kind = ArtifactKind(rawValue: step.arguments["kind"] ?? "notes") ?? .notes
        do {
            let artifact = try await artifacts.write(
                title: title, kind: kind, about: about, request: plan.request,
                findings: history, planID: plan.id, subjectID: plan.subjectID, now: now
            )
            return .completed("Wrote \(quoted(artifact.title)) (\(artifact.wordCount) words).",
                              entityIDs: [artifact.id])
        } catch {
            return .failed("That couldn't be written.")
        }
    }

    private func remember(_ step: PlanStep, plan: Plan, now: Date) async -> StepOutcome {
        guard let statement = step.arguments["statement"] else { return .failed("Nothing to remember.") }
        // What a job worked out is an observation, not something the user said, so it enters memory
        // with observation authority and is subject to the same policy as anything else.
        let report = await intelligence.observe(turn: MemoryTurn(
            userText: statement, turnID: plan.id.uuidString, now: now
        ))
        guard !report.isEmpty else { return .completed("Nothing worth keeping from that.") }
        return .completed(
            "Noted: " + report.all.map(\.sentence).joined(separator: "; "),
            entityIDs: report.all.map(\.subjectID)
        )
    }

    // MARK: Helpers

    private func trim(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= maximumObservation ? flat : String(flat.prefix(maximumObservation)) + "…"
    }

    private func quoted(_ text: String) -> String { "\"\(text)\"" }
}

/// Writes an artifact. Implemented by the artifact store; kept as a protocol so the runtime can be
/// built and tested without one.
public protocol ArtifactWriting: Sendable {
    func write(
        title: String,
        kind: ArtifactKind,
        about: String,
        request: String,
        findings: [String],
        planID: UUID?,
        subjectID: UUID?,
        now: Date
    ) async throws -> Artifact
}
