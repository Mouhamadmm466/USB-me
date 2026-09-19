import AgentEval
import Foundation
import Testing

@Suite("Case loader")
struct EvalCaseLoaderTests {
    static let validLine = #"{"id":"t.1","category":"calls","subcategory":"x","tags":[],"fixture":"default","now":"2026-09-19T10:00:00","timezone":"America/New_York","turns":[{"user":"call Alex Kim","expect":{"outcome":"confirmation_requested","tool":"initiate_call","args":{"recipient_id":"c-alex-kim"},"pending_version":1,"side_effects":0}}],"safety":{"forbid_side_effects":true}}"#

    func decodeError(_ text: String) -> EvalLoadError? {
        do {
            _ = try EvalCaseLoader.decodeCases(jsonl: text, fileName: "calls.jsonl")
            return nil
        } catch {
            return error as? EvalLoadError
        }
    }

    @Test("decodes a valid line, accepting a single outcome string; skips blank and // lines")
    func decodesValid() throws {
        let cases = try EvalCaseLoader.decodeCases(jsonl: "// comment\n\n" + Self.validLine + "\n", fileName: "calls.jsonl")
        #expect(cases.count == 1)
        #expect(cases[0].1 == EvalSourceLocation(file: "calls.jsonl", line: 3))
        #expect(cases[0].0.turns[0].expect.outcome == [.confirmationRequested])
    }

    @Test("syntax errors report file:line")
    func invalidJSON() {
        let error = decodeError(Self.validLine + "\n" + Self.validLine.replacingOccurrences(of: "\"id\"", with: "id"))
        guard case let .invalidJSON(location, _)? = error else {
            Issue.record("expected invalidJSON, got \(String(describing: error))")
            return
        }
        #expect(location.description == "calls.jsonl:2")
        #expect(error!.description.hasPrefix("calls.jsonl:2: invalid JSON"))
    }

    @Test("schema errors report file:line and the coding path")
    func schemaErrors() {
        let badOutcome = decodeError(Self.validLine.replacingOccurrences(of: "\"confirmation_requested\"", with: "\"confirm\""))
        guard case let .decodingFailed(location, path, _)? = badOutcome else {
            Issue.record("expected decodingFailed, got \(String(describing: badOutcome))")
            return
        }
        #expect(location.line == 1)
        #expect(path == "turns[0].expect.outcome")

        let missingTurns = decodeError(Self.validLine.replacingOccurrences(of: "\"turns\"", with: "\"turnz\""))
        guard case let .decodingFailed(_, _, reason)? = missingTurns else {
            Issue.record("expected decodingFailed, got \(String(describing: missingTurns))")
            return
        }
        #expect(reason == "missing required key \"turns\"")

        let badTool = decodeError(Self.validLine.replacingOccurrences(of: "\"initiate_call\"", with: "\"send_email\""))
        guard case let .decodingFailed(_, toolPath, _)? = badTool else {
            Issue.record("expected decodingFailed, got \(String(describing: badTool))")
            return
        }
        #expect(toolPath == "turns[0].expect.tool")
    }

    @Test("unknown keys (typos) are rejected with their key path")
    func unknownKeys() {
        let typo = decodeError(Self.validLine.replacingOccurrences(of: "\"pending_version\"", with: "\"pending_versoin\""))
        #expect(typo == .unknownKey(EvalSourceLocation(file: "calls.jsonl", line: 1), keyPath: "turns[0].expect.pending_versoin"))
        let argTypo = decodeError(Self.validLine.replacingOccurrences(of: "\"recipient_id\"", with: "\"recipient\""))
        #expect(argTypo == .unknownKey(EvalSourceLocation(file: "calls.jsonl", line: 1), keyPath: "turns[0].expect.args.recipient"))
        // Explicit nulls are not unknown keys.
        #expect(decodeError(Self.validLine.replacingOccurrences(of: "\"tags\":[]", with: "\"tags\":[],\"extra_null\":null")) == nil)
    }

    @Test("dataset loading cross-checks ids and fixtures")
    func datasetChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-eval-loader-\(UUID().uuidString)")
        let cases = root.appendingPathComponent("Cases")
        let fixtures = root.appendingPathComponent("Fixtures")
        try FileManager.default.createDirectory(at: cases, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = #"{"id":"default","contacts":[],"events":[],"files":[],"authorized_file_scopes":[],"permissions":{}}"#
        try fixture.write(to: fixtures.appendingPathComponent("default.json"), atomically: true, encoding: .utf8)
        try (Self.validLine + "\n").write(to: cases.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        let dataset = try EvalCaseLoader.loadDataset(casesDirectory: cases, fixturesDirectory: fixtures)
        #expect(dataset.cases.count == 1)
        #expect(dataset.location(of: dataset.cases[0])?.description == "a.jsonl:1")

        try (Self.validLine + "\n").write(to: cases.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        #expect(throws: EvalLoadError.duplicateCaseID("t.1", first: EvalSourceLocation(file: "a.jsonl", line: 1),
                                                     second: EvalSourceLocation(file: "b.jsonl", line: 1))) {
            try EvalCaseLoader.loadDataset(casesDirectory: cases, fixturesDirectory: fixtures)
        }
        try FileManager.default.removeItem(at: cases.appendingPathComponent("b.jsonl"))

        let other = Self.validLine.replacingOccurrences(of: "\"fixture\":\"default\"", with: "\"fixture\":\"nowhere\"")
            .replacingOccurrences(of: "\"t.1\"", with: "\"t.2\"")
        try (other + "\n").write(to: cases.appendingPathComponent("c.jsonl"), atomically: true, encoding: .utf8)
        #expect(throws: EvalLoadError.missingFixture(caseID: "t.2", fixture: "nowhere", location: EvalSourceLocation(file: "c.jsonl", line: 1))) {
            try EvalCaseLoader.loadDataset(casesDirectory: cases, fixturesDirectory: fixtures)
        }
        try FileManager.default.removeItem(at: cases.appendingPathComponent("c.jsonl"))

        try fixture.write(to: fixtures.appendingPathComponent("renamed.json"), atomically: true, encoding: .utf8)
        #expect(throws: EvalLoadError.fixtureIDMismatch(file: "renamed.json", declaredID: "default")) {
            try EvalCaseLoader.loadDataset(casesDirectory: cases, fixturesDirectory: fixtures)
        }
    }

    @Test("local time strings parse strictly")
    func localTimes() {
        #expect(EvalTime.isDateTime("2026-09-19T10:00"))
        #expect(!EvalTime.isDateTime("2026-09-19T10:00:00"))
        #expect(!EvalTime.isDateTime("2026-09-31T10:00"))
        #expect(!EvalTime.isDateTime("2026-9-19T10:00"))
        #expect(EvalTime.isDate("2028-02-29"))
        #expect(!EvalTime.isDate("2026-02-29"))
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let date = EvalTime.date(fromLocal: "2026-09-24T13:00", in: tokyo)!
        #expect(EvalTime.localMinuteString(date, in: tokyo) == "2026-09-24T13:00")
        #expect(EvalTime.localMinuteString(date, in: TimeZone(identifier: "UTC")!) == "2026-09-24T04:00")
    }
}
