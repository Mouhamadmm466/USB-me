import Foundation
import Intelligence
import IntelligenceEval
import Testing

/// The V2 evaluation, run as part of the ordinary test suite.
///
/// These cases are deterministic: the memory ones supply the proposals the extractor would have
/// made, so what is being measured is everything after that — validation, policy, conflict
/// resolution, retrieval, scoping and attention. A model run over the same cases (with a real
/// extractor injected) measures the model itself; the scoring is identical either way.
@Suite struct IntelligenceEvalSuite {
    private func load(_ suite: String) throws -> [IntelligenceEvalCase] {
        try IntelligenceEvalCases.load(suites: [suite])
    }

    private func check(_ suite: String) async throws {
        let cases = try load(suite)
        #expect(!cases.isEmpty, "no cases for \(suite)")
        let run = await IntelligenceEvalRunner().run(cases)
        #expect(run.failed == 0, Comment(rawValue: run.report))
    }

    @Test func memory() async throws { try await check("memory") }
    @Test func recall() async throws { try await check("recall") }
    @Test func retrieval() async throws { try await check("retrieval") }
    @Test func planning() async throws { try await check("planning") }
    @Test func safety() async throws { try await check("safety") }
    @Test func attention() async throws { try await check("attention") }

    @Test func everyCaseIsWellFormedAndUnique() throws {
        let cases = try IntelligenceEvalCases.load()
        #expect(cases.count >= 25)
        #expect(Set(cases.map(\.id)).count == cases.count)
        for testCase in cases {
            #expect(IntelligenceEvalCases.suites.contains(testCase.suite), "\(testCase.id): unknown suite")
            #expect(!testCase.script.isEmpty, "\(testCase.id): nothing happens")
            #expect(testCase.id.hasPrefix(testCase.suite + "."), "\(testCase.id): id should name its suite")
        }
    }

    @Test func theHarnessFailsWhenTheExpectationIsWrong() async throws {
        // A case that asserts something untrue must fail, or the suite proves nothing.
        let broken = IntelligenceEvalCase(
            id: "memory.sanity", suite: "memory", now: "2026-09-21T09:00:00",
            script: [ScriptStep(
                user: "nothing was said",
                proposals: [],
                expect: Expectation(holds: [ExpectedStatement(subject: "Nobody", predicate: "role", value: "ghost")])
            )]
        )
        let result = await IntelligenceEvalRunner().run(broken)
        #expect(!result.passed)
        #expect(result.failures.count == 1)
    }
}
