import Agent
import Core
import Foundation
import LLM

/// One evaluated case as recorded by `agent-eval run` (one JSON object per line in
/// `observations.jsonl`, appended as cases finish so long runs can resume).
public struct CaseObservation: Codable, Sendable, Equatable {
    public let id: String
    public let observations: [TurnObservation]
    /// Consequential side effects the fake adapters actually recorded (ground truth cross-check).
    public let recordedSideEffects: Int
    /// State-machine transitions the coordinator refused (must be 0).
    public let illegalTransitions: Int
    public let durationMilliseconds: Double
    /// Harness-level failure (fixture error, runtime crash); nil when the case ran.
    public let error: String?

    public init(id: String, observations: [TurnObservation], recordedSideEffects: Int, illegalTransitions: Int,
                durationMilliseconds: Double, error: String?) {
        self.id = id
        self.observations = observations
        self.recordedSideEffects = recordedSideEffects
        self.illegalTransitions = illegalTransitions
        self.durationMilliseconds = durationMilliseconds
        self.error = error
    }
}

/// Provenance of a run (written to `run.json`).
public struct RunManifest: Codable, Sendable {
    public let startedAt: Date
    public let modelIdentifier: String
    public let modelSHA256: String
    public let promptVersion: String
    public let runtime: String
    public let gitCommit: String?
    public let host: String
    public let threads: Int?
    public let caseCount: Int
    public let filters: [String]

    public init(startedAt: Date, modelIdentifier: String, modelSHA256: String, promptVersion: String, runtime: String,
                gitCommit: String?, host: String, threads: Int?, caseCount: Int, filters: [String]) {
        self.startedAt = startedAt
        self.modelIdentifier = modelIdentifier
        self.modelSHA256 = modelSHA256
        self.promptVersion = promptVersion
        self.runtime = runtime
        self.gitCommit = gitCommit
        self.host = host
        self.threads = threads
        self.caseCount = caseCount
        self.filters = filters
    }
}

/// Runs one case end to end against a language model and the case's fake world.
public enum CaseRunner {
    @MainActor
    public static func run(_ evalCase: EvalCase, fixture: EvalFixture, languageModel: any LanguageModel,
                           configuration: AgentConfiguration = .default) async -> CaseObservation {
        let started = Date()
        do {
            let clock = try FixtureEnvironment.clock(for: evalCase)
            let suite = try FixtureEnvironment.makeSuite(fixture: fixture, clock: clock)
            let coordinator = FixtureEnvironment.makeCoordinator(suite: suite, clock: clock, languageModel: languageModel,
                                                                 configuration: configuration)
            var observations: [TurnObservation] = []
            for turn in evalCase.turns {
                let transcript = FinalTranscript(text: turn.user, audioDurationSeconds: 0)
                let report = await coordinator.handle(.speech(transcript))
                observations.append(TurnObservation(report: report))
            }
            let recorded = await suite.recorder.consequentialEffects.count
            return CaseObservation(id: evalCase.id, observations: observations, recordedSideEffects: recorded,
                                   illegalTransitions: coordinator.illegalTransitionCount,
                                   durationMilliseconds: Date().timeIntervalSince(started) * 1000, error: nil)
        } catch {
            return CaseObservation(id: evalCase.id, observations: [], recordedSideEffects: 0, illegalTransitions: 0,
                                   durationMilliseconds: Date().timeIntervalSince(started) * 1000, error: String(describing: error))
        }
    }
}
