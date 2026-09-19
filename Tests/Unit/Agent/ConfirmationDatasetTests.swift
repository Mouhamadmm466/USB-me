import AgentEval
import Core
import Foundation
import Testing
@testable import Agent

/// The deterministic confirmation classifier must agree with the evaluation dataset on every reply
/// to a pending action (1,700+ phrasings): approvals, rejections, deferrals, modifications and
/// unclear answers. A disagreement in the dangerous direction (anything classified `affirm` that
/// the dataset does not expect to execute) fails immediately.
@Suite struct ConfirmationDatasetTests {
    struct Reply {
        let caseID: String
        let text: String
        let tool: ToolID
        let expected: Set<ConfirmationReply>
    }

    static func replies() throws -> [Reply] {
        let dataset = try EvalCaseLoader.loadDataset()
        var result: [Reply] = []
        for evalCase in dataset.cases {
            var pendingTool: ToolID?
            var repromptsSoFar = 0
            for turn in evalCase.turns {
                let outcomes = Set(turn.expect.outcome)
                if let tool = pendingTool, outcomes.count == 1, let outcome = outcomes.first {
                    let expected: Set<ConfirmationReply>? = switch outcome {
                    case .executed: [.affirm]
                    // After two reprompts a third unclear answer also cancels.
                    case .cancelled: repromptsSoFar >= 2 ? [.unclear, .reject] : [.reject]
                    case .deferred: [.defer_]
                    case .reprompted: [.unclear]
                    case .confirmationRequested: [.modify]
                    default: nil
                    }
                    if let expected {
                        result.append(Reply(caseID: evalCase.id, text: turn.user, tool: turn.expect.tool ?? tool, expected: expected))
                    }
                }
                repromptsSoFar = outcomes == [.reprompted] ? repromptsSoFar + 1 : 0
                let pendingOutcomes: Set<ObservedOutcome> = [.confirmationRequested, .reprompted, .deferred]
                if !outcomes.isEmpty, outcomes.isSubset(of: pendingOutcomes) {
                    pendingTool = turn.expect.tool ?? pendingTool
                } else {
                    pendingTool = nil
                }
            }
        }
        return result
    }

    @Test func classifierAgreesWithTheDataset() throws {
        let classifier = ConfirmationClassifier()
        let replies = try Self.replies()
        #expect(replies.count > 1_000)
        var disagreements: [String] = []
        var unsafe: [String] = []
        for reply in replies {
            let got = classifier.classify(reply.text, pendingTool: reply.tool)
            // `modify` is sent to the model; an expected modification may also legitimately be
            // classified as unclear/reject only if the dataset says so — so compare exactly.
            if !reply.expected.contains(got) {
                disagreements.append("\(reply.caseID) [\(reply.tool.rawValue)] \"\(reply.text)\" expected \(reply.expected.map(\.rawValue).sorted()), got \(got.rawValue)")
                if got == .affirm { unsafe.append(disagreements.last!) }
            }
        }
        #expect(unsafe.isEmpty, "classified as approval but the dataset does not execute:\n\(unsafe.joined(separator: "\n"))")
        let rate = Double(replies.count - disagreements.count) / Double(replies.count)
        #expect(disagreements.isEmpty, "agreement \(String(format: "%.2f", rate * 100))% — \(disagreements.count) disagreements:\n\(disagreements.prefix(80).joined(separator: "\n"))")
    }
}
