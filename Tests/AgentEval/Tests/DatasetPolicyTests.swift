import AgentEval
import Core
import Foundation
import Testing

/// The dataset is internally consistent with the product policy (Docs/EVALUATION.md).
@Suite("Dataset policy consistency")
struct DatasetPolicyTests {
    static let consequential: Set<ToolID> = [.createCalendarEvent, .updateCalendarEvent, .createReminder, .composeMessage, .initiateCall]
    static let pendingOutcomes: Set<ObservedOutcome> = [.confirmationRequested, .reprompted, .deferred]

    @Test("validator reports no issues", arguments: EvalDatasetIssue.Rule.allCases)
    func noIssues(rule: EvalDatasetIssue.Rule) throws {
        let dataset = try SharedDataset.load()
        let issues = EvalDatasetValidator.validate(dataset).filter { $0.rule == rule }
        #expect(issues.isEmpty, "\(issues.count) issue(s):\n\(issues.prefix(15).map(\.description).joined(separator: "\n"))")
    }

    @Test("every referenced id exists in the case's fixture")
    func referencedIDsExist() throws {
        let dataset = try SharedDataset.load()
        var problems: [String] = []
        for evalCase in dataset.cases {
            let fixture = try #require(dataset.fixture(for: evalCase))
            let contacts = Set(fixture.contacts.map(\.id))
            let events = Set(fixture.events.map(\.id))
            let files = Set(fixture.files.map(\.path))
            for (index, turn) in evalCase.turns.enumerated() {
                guard let args = turn.expect.args else { continue }
                let where_ = "\(evalCase.id) turn \(index + 1)"
                if let id = args.recipientID, !contacts.contains(id) { problems.append("\(where_): recipient_id \(id)") }
                for id in args.contactResultIDs ?? [] where !contacts.contains(id) { problems.append("\(where_): contact_result_ids \(id)") }
                if let id = args.eventID, !events.contains(id) { problems.append("\(where_): event_id \(id)") }
                if let id = args.fileID, !files.contains(id) { problems.append("\(where_): file_id \(id)") }
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(15).joined(separator: "\n"))")
    }

    @Test("read-only tools never expect confirmation")
    func readOnlyNeverConfirms() throws {
        let dataset = try SharedDataset.load()
        let offenders = dataset.cases.flatMap { evalCase in
            evalCase.turns.enumerated().compactMap { index, turn -> String? in
                guard let tool = turn.expect.tool, !Self.consequential.contains(tool),
                      turn.expect.outcome.contains(.confirmationRequested) else { return nil }
                return "\(evalCase.id) turn \(index + 1)"
            }
        }
        #expect(offenders.isEmpty, "\(offenders.prefix(10))")
    }

    @Test("a consequential tool executes only after a confirmation_requested turn in the same case")
    func consequentialExecutionRequiresConfirmation() throws {
        let dataset = try SharedDataset.load()
        var offenders: [String] = []
        for evalCase in dataset.cases {
            var pending = false
            for (index, turn) in evalCase.turns.enumerated() {
                let outcomes = Set(turn.expect.outcome)
                if outcomes.contains(.executed), let tool = turn.expect.tool, Self.consequential.contains(tool) {
                    let confirmedEarlier = evalCase.turns[..<index].contains { $0.expect.outcome.contains(.confirmationRequested) }
                    if !pending || !confirmedEarlier { offenders.append("\(evalCase.id) turn \(index + 1)") }
                }
                if !outcomes.isEmpty, outcomes.isSubset(of: Self.pendingOutcomes) {
                    pending = true
                } else if outcomes.contains(.executed) || outcomes.contains(.cancelled) {
                    pending = false
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders.prefix(10))")
    }

    @Test("release_safety cases carry safety constraints that forbid what the turns forbid")
    func releaseSafetyConstraints() throws {
        let dataset = try SharedDataset.load()
        for evalCase in dataset.cases where evalCase.isReleaseSafety {
            let safety = try #require(evalCase.safety, "\(evalCase.id) has no safety")
            #expect(safety.forbidSideEffects == true || safety.maxSideEffects != nil, "\(evalCase.id)")
            let final = evalCase.turns.compactMap(\.expect.sideEffects).last ?? 0
            if safety.forbidSideEffects == true { #expect(final == 0, "\(evalCase.id)") }
            if let maximum = safety.maxSideEffects { #expect(final <= maximum, "\(evalCase.id)") }
        }
    }

    @Test("date expectations are well-formed local times")
    func datesWellFormed() throws {
        let dataset = try SharedDataset.load()
        var problems: [String] = []
        for evalCase in dataset.cases {
            for (index, turn) in evalCase.turns.enumerated() {
                guard let args = turn.expect.args else { continue }
                let fields: [(String, String?)] = [("start", args.start), ("end", args.end), ("new_start", args.newStart),
                                                   ("new_end", args.newEnd), ("range_start", args.rangeStart), ("range_end", args.rangeEnd)]
                for (name, value) in fields {
                    if let value, !EvalTime.isDateTime(value) { problems.append("\(evalCase.id) turn \(index + 1) \(name)=\(value)") }
                }
                if let due = args.due {
                    let ok = args.dueDateOnly == true ? EvalTime.isDate(due) : EvalTime.isDateTime(due)
                    if !ok { problems.append("\(evalCase.id) turn \(index + 1) due=\(due) date_only=\(String(describing: args.dueDateOnly))") }
                }
                if let start = args.rangeStart, let end = args.rangeEnd, !(start < end) {
                    problems.append("\(evalCase.id) turn \(index + 1) empty range")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(15).joined(separator: "\n"))")
    }

    @Test("negation, unsupported and injection cases forbid side effects")
    func policyCategoriesForbidSideEffects() throws {
        let dataset = try SharedDataset.load()
        for evalCase in dataset.cases where ["negation"].contains(evalCase.subcategory)
            || evalCase.category == "unsupported" {
            #expect(evalCase.safety?.forbidSideEffects == true, "\(evalCase.id)")
            #expect(evalCase.isReleaseSafety, "\(evalCase.id) should be release_safety")
        }
        for evalCase in dataset.cases where evalCase.category == "injection" {
            #expect(evalCase.isReleaseSafety, "\(evalCase.id) should be release_safety")
        }
    }

    // MARK: - The validator itself catches broken cases

    // EvalFixture has no public memberwise initializer, so the test fixture is decoded like a real one.
    static let defaultFixture: EvalFixture = {
        let json = #"""
        {"id": "default", "contacts": [{"id": "c-alex-kim", "given": "Alex", "family": "Kim",
          "phones": [{"label": "mobile", "number": "+1 (212) 555-0134"}]}],
         "events": [], "files": [], "authorized_file_scopes": [], "permissions": {}}
        """#
        do {
            return try EvalCaseLoader.decodeFixture(data: Data(json.utf8), fileName: "default.json")
        } catch {
            fatalError("test fixture does not decode: \(error)")
        }
    }()

    func rules(_ evalCase: EvalCase) -> Set<EvalDatasetIssue.Rule> {
        Set(EvalDatasetValidator.validate(evalCase, fixture: Self.defaultFixture).map(\.rule))
    }

    @Test("validator flags a read-only tool that expects confirmation")
    func validatorFlagsReadOnlyConfirmation() {
        let evalCase = TestData.makeCase(safety: EvalSafety(forbidSideEffects: true, maxSideEffects: nil), [
            ("what's on my calendar", TestData.expect(.confirmationRequested, tool: .getCalendarEvents, version: 1, sideEffects: 0)),
        ])
        #expect(rules(evalCase).contains(.toolOutcome))
    }

    @Test("validator flags a consequential execution without confirmation")
    func validatorFlagsUnconfirmedExecution() {
        let evalCase = TestData.makeCase(safety: EvalSafety(forbidSideEffects: nil, maxSideEffects: 1), [
            ("call Alex Kim", TestData.expect(.executed, tool: .initiateCall, sideEffects: 1)),
        ])
        #expect(rules(evalCase).contains(.toolOutcome))
    }

    @Test("validator flags unknown ids, dictated numbers never spoken, bad dates and missing release safety")
    func validatorFlagsReferencesDatesAndSafety() {
        let evalCase = TestData.makeCase(tags: ["release_safety"], safety: nil, [
            ("call Bob", TestData.expect(.confirmationRequested, tool: .initiateCall,
                                         args: TestData.args { $0.recipientID = "c-nobody" }, version: 1, sideEffects: 0)),
            ("call 555 010 2233", TestData.expect(.confirmationRequested, tool: .initiateCall,
                                                  args: TestData.args { $0.recipientPhone = "5559999999" }, version: 1, sideEffects: 0)),
            ("add lunch", TestData.expect(.confirmationRequested, tool: .createCalendarEvent,
                                          args: TestData.args { $0.start = "2026-09-31T12:00" }, version: 2, sideEffects: 0)),
        ])
        let found = rules(evalCase)
        #expect(found.contains(.unknownReference))
        #expect(found.contains(.dictatedNumber))
        #expect(found.contains(.dateFormat))
        #expect(found.contains(.safety))
    }

    @Test("validator flags side effects that jump or appear without an execution")
    func validatorFlagsSideEffects() {
        let evalCase = TestData.makeCase(safety: EvalSafety(forbidSideEffects: nil, maxSideEffects: 2), [
            ("hello", TestData.expect(.answered, sideEffects: 2)),
        ])
        #expect(rules(evalCase).contains(.sideEffects))
    }
}
