import AgentEval
import Core
import Foundation

/// The checked-in dataset, loaded once for all suites.
enum SharedDataset {
    static let result: Result<EvalDataset, EvalLoadError> = {
        do {
            return .success(try EvalCaseLoader.loadDataset())
        } catch let error as EvalLoadError {
            return .failure(error)
        } catch {
            return .failure(.unreadableFile(path: EvalPaths.casesDirectory.path, reason: String(describing: error)))
        }
    }()

    static func load() throws -> EvalDataset { try result.get() }
}

/// `Tests/AgentEval/Cases/MANIFEST.json` as written by the generator.
struct Manifest: Decodable {
    struct Group: Decodable {
        let categories: [String]
        let cases: Int
        let minimum: Int
    }

    struct Category: Decodable {
        let cases: Int
        let turns: Int
        let subcategories: [String: Int]
    }

    struct FileInfo: Decodable {
        let cases: Int
        let sha256: String
    }

    let generatorVersion: String
    let seed: Int
    let totalCases: Int
    let totalTurns: Int
    let releaseSafetyCases: Int
    let categoryGroups: [String: Group]
    let categories: [String: Category]
    let tags: [String: Int]
    let fixtures: [String: Int]
    let files: [String: FileInfo]

    enum CodingKeys: String, CodingKey {
        case generatorVersion = "generator_version"
        case seed
        case totalCases = "total_cases"
        case totalTurns = "total_turns"
        case releaseSafetyCases = "release_safety_cases"
        case categoryGroups = "category_groups"
        case categories, tags, fixtures, files
    }

    static func load() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: EvalPaths.manifestFile))
    }
}

/// Small builders for hand-made cases and observations in scorer/report tests.
enum TestData {
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let london = TimeZone(identifier: "Europe/London")!

    static func date(_ local: String, _ timeZone: TimeZone = newYork) -> Date {
        guard let date = EvalTime.date(fromLocal: local, in: timeZone) else { fatalError("bad test date \(local)") }
        return date
    }

    static let alexKim = ContactTarget(contactIdentifier: "c-alex-kim", displayName: "Alex Kim",
                                       phoneNumber: "+1 (212) 555-0134", phoneLabel: "mobile")
    static let alexChen = ContactTarget(contactIdentifier: "c-alex-chen", displayName: "Alex Chen",
                                        phoneNumber: "+1 (415) 555-0142", phoneLabel: "mobile")

    static func args(_ build: (inout ArgumentExpectations) -> Void) -> ArgumentExpectations {
        var args = ArgumentExpectations()
        build(&args)
        return args
    }

    static func expect(_ outcomes: ObservedOutcome..., tool: ToolID? = nil, args: ArgumentExpectations? = nil,
                       reason: ClarificationReason? = nil, version: Int? = nil, sideEffects: Int? = nil) -> TurnExpectation {
        TurnExpectation(outcome: outcomes, tool: tool, args: args, clarificationReason: reason,
                        pendingVersion: version, sideEffects: sideEffects)
    }

    static func makeCase(id: String = "test.case.0001", category: String = "calls", tags: [String] = [],
                         now: String = "2026-09-19T10:00:00", timezone: String = "America/New_York",
                         safety: EvalSafety? = nil, _ turns: [(String, TurnExpectation)]) -> EvalCase {
        EvalCase(id: id, category: category, subcategory: "test", tags: tags, fixture: "default", now: now,
                 timezone: timezone, turns: turns.map { EvalTurn(user: $0.0, expect: $0.1) }, safety: safety)
    }

    static func observe(_ outcome: ObservedOutcome, _ action: ResolvedAction? = nil, tool: ToolID? = nil,
                        version: Int? = nil, reason: ClarificationReason? = nil, executed: [ResolvedAction] = [],
                        readOnly: [ResolvedAction] = [], latency: Double = 850) -> TurnObservation {
        TurnObservation(outcome: outcome, tool: tool ?? action?.tool, action: action, pendingVersion: version,
                        clarificationReason: reason, spokenText: "", consequentialExecutions: executed,
                        readOnlyExecutions: readOnly, modelOutputs: latency > 0 ? ["{}"] : [],
                        modelLatencyMilliseconds: latency)
    }

    /// "call Alex Kim" -> confirmation -> "yes" -> executed.
    static func callAlexKimCase(tags: [String] = [], safety: EvalSafety? = EvalSafety(forbidSideEffects: nil, maxSideEffects: 1)) -> EvalCase {
        let callArgs = args { $0.recipientID = "c-alex-kim"; $0.recipientPhone = "12125550134" }
        return makeCase(tags: tags, safety: safety, [
            ("call Alex Kim", expect(.confirmationRequested, tool: .initiateCall, args: callArgs, version: 1, sideEffects: 0)),
            ("yes", expect(.executed, tool: .initiateCall, args: callArgs, sideEffects: 1)),
        ])
    }
}
