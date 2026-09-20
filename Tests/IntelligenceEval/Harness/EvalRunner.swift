import Agent
import Core
import Foundation
import Intelligence
import LLM

/// What one case did.
public struct EvalCaseResult: Sendable, Equatable {
    public var id: String
    public var suite: String
    public var passed: Bool
    /// One line per expectation that failed, in the case's own terms.
    public var failures: [String]
}

public struct EvalRun: Sendable, Equatable {
    public var results: [EvalCaseResult]

    public var passed: Int { results.count(where: \.passed) }
    public var failed: Int { results.count - passed }
    public var passRate: Double { results.isEmpty ? 1 : Double(passed) / Double(results.count) }

    public func bySuite() -> [String: (passed: Int, total: Int)] {
        var counts: [String: (passed: Int, total: Int)] = [:]
        for result in results {
            var entry = counts[result.suite] ?? (0, 0)
            entry.total += 1
            if result.passed { entry.passed += 1 }
            counts[result.suite] = entry
        }
        return counts
    }

    public var report: String {
        var lines = ["\(passed)/\(results.count) cases passed"]
        for (suite, counts) in bySuite().sorted(by: { $0.key < $1.key }) {
            lines.append("  \(suite): \(counts.passed)/\(counts.total)")
        }
        for result in results where !result.passed {
            lines.append("  ✗ \(result.id): " + result.failures.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}

/// Runs V2 evaluation cases against a real intelligence, one fresh world per case.
///
/// The extractor is injected: with a scripted one (or a case's own proposals) the suite is
/// deterministic and runs in CI; with the real model it measures what the model actually proposes.
/// Everything downstream of extraction — validation, policy, conflict resolution, retrieval,
/// scoping, attention — is the production code either way.
public struct IntelligenceEvalRunner: Sendable {
    public var extractor: (any MemoryExtracting)?
    public var planner: Planner?

    public init(extractor: (any MemoryExtracting)? = nil, planner: Planner? = nil) {
        self.extractor = extractor
        self.planner = planner
    }

    public func run(_ cases: [IntelligenceEvalCase]) async -> EvalRun {
        var results: [EvalCaseResult] = []
        for testCase in cases {
            results.append(await run(testCase))
        }
        return EvalRun(results: results)
    }

    public func run(_ testCase: IntelligenceEvalCase) async -> EvalCaseResult {
        do {
            let world = try await World(testCase: testCase, extractor: extractor)
            var failures: [String] = []
            for (index, step) in testCase.script.enumerated() {
                failures += try await world.run(step, index: index, planner: planner)
            }
            return EvalCaseResult(id: testCase.id, suite: testCase.suite, passed: failures.isEmpty, failures: failures)
        } catch {
            return EvalCaseResult(
                id: testCase.id, suite: testCase.suite, passed: false,
                failures: ["case could not run: \(error)"]
            )
        }
    }
}

// MARK: - One case's world

/// The store, the intelligence and the clock for a single case.
private final class World: @unchecked Sendable {
    let store: IntelligenceStore
    let intelligence: PersonalIntelligence
    let now: Date
    let calendar: Calendar

    init(testCase: IntelligenceEvalCase, extractor: (any MemoryExtracting)?) async throws {
        let zone = TimeZone(identifier: testCase.timezone) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        now = formatter.date(from: testCase.now) ?? Date()

        store = try IntelligenceStore()
        intelligence = PersonalIntelligence(
            store: store,
            dates: IntelligenceDateResolver(calendar: calendar),
            extractor: extractor ?? NoMemoryExtractor(),
            calendar: calendar
        )
        for step in testCase.setup { try await apply(step) }
    }

    // MARK: Setup

    private func apply(_ step: SetupStep) async throws {
        if let document = step.document {
            var projectID: UUID?
            if let project = document.project {
                projectID = try await resolveOrCreate(project, kind: "project").id
            }
            _ = try await intelligence.importDocument(
                data: Data(document.text.utf8),
                fileName: document.name,
                origin: .files,
                projectID: projectID,
                now: date(daysAgo: document.daysAgo)
            )
        }
        if let entity = step.entity {
            var projectID: UUID?
            if let project = entity.project {
                projectID = try await resolveOrCreate(project, kind: "project").id
            }
            _ = try await store.create(
                kind: EntityKind(rawValue: entity.kind) ?? .task,
                title: entity.title,
                status: entity.status.flatMap(EntityStatus.init(rawValue:)),
                projectID: projectID,
                dueAt: entity.due.flatMap(resolveDate),
                startsAt: entity.starts.flatMap(resolveDate)
            )
        }
        if let fact = step.fact {
            let subject = try await resolveOrCreate(fact.subject, kind: fact.subjectKind)
            var object: IntelligenceEntity?
            if let title = fact.object {
                object = try await resolveOrCreate(title, kind: fact.objectKind ?? "project")
            }
            var value: AssertionValue?
            if let when = fact.when, let resolved = resolveDate(when) {
                value = .date(resolved, phrase: when)
            } else if let text = fact.text {
                value = .text(text)
            }
            let type = MemoryType(rawValue: fact.type ?? "explicit") ?? .explicit
            try await store.record(Assertion(
                subjectID: subject.id,
                predicate: Predicate(fact.predicate),
                objectID: object?.id,
                value: value,
                type: type,
                provenance: Provenance(sourceType: type == .explicit ? .conversation : .system),
                validFrom: date(daysAgo: fact.daysAgo),
                createdAt: date(daysAgo: fact.daysAgo),
                updatedAt: date(daysAgo: fact.daysAgo)
            ))
        }
    }

    // MARK: Steps

    func run(_ step: ScriptStep, index: Int, planner: Planner?) async throws -> [String] {
        var failures: [String] = []
        let label = "step \(index + 1)"

        if let proposals = step.proposals {
            let report = try await MemoryPipeline(
                store: store, validator: MemoryValidator(dates: IntelligenceDateResolver(calendar: calendar))
            ).apply(
                MemoryProposalSet(memories: proposals),
                origin: .conversation(turnID: "eval-\(index)", excerpt: step.user),
                now: now
            )
            _ = report
        } else if let text = step.user, step.expect.holds != nil || step.expect.asks != nil {
            // No scripted proposals: the extractor (a real model, in a model run) decides.
            await intelligence.observe(turn: MemoryTurn(userText: text, turnID: "eval-\(index)", now: now))
        }

        if let holds = step.expect.holds {
            for statement in holds where try await !matches(statement, states: [.active]) {
                failures.append("\(label): expected \(statement.description)")
            }
        }
        if let absent = step.expect.absent {
            for statement in absent where try await matches(statement, states: [.active]) {
                failures.append("\(label): did not expect \(statement.description)")
            }
        }
        if let asks = step.expect.asks {
            for statement in asks where try await !matches(statement, states: [.proposed]) {
                failures.append("\(label): expected to be asked about \(statement.description)")
            }
        }

        if step.expect.contextContains != nil || step.expect.contextOmits != nil {
            let rendered = try await intelligence.context(for: step.user ?? "", now: now).render()
            for fragment in step.expect.contextContains ?? [] where !rendered.localizedCaseInsensitiveContains(fragment) {
                failures.append("\(label): context missing \"\(fragment)\"")
            }
            for fragment in step.expect.contextOmits ?? [] where rendered.localizedCaseInsensitiveContains(fragment) {
                failures.append("\(label): context should not mention \"\(fragment)\"")
            }
        }

        if step.expect.passageFrom != nil || step.expect.passageContains != nil {
            let passages = try await intelligence.passages(for: step.user ?? "", limit: 3, now: now)
            guard let best = passages.first else {
                failures.append("\(label): no passage found")
                return failures
            }
            if let document = step.expect.passageFrom, !best.document.title.localizedCaseInsensitiveContains(document) {
                failures.append("\(label): best passage came from \(best.document.title), expected \(document)")
            }
            if let text = step.expect.passageContains, !best.chunk.text.localizedCaseInsensitiveContains(text) {
                failures.append("\(label): best passage does not mention \"\(text)\"")
            }
        }

        if step.expect.planAllows != nil || step.expect.planForbids != nil {
            let request = step.user ?? ""
            let playbook = PlaybookLibrary.match(request)
            let mentioned = await intelligence.mentionedNames(in: request, now: now)
            let scope = Set(PlaybookLibrary.scope(for: request, playbook: playbook, excluding: mentioned))
            for capability in step.expect.planAllows ?? [] where !scope.contains(capability) {
                failures.append("\(label): \(capability) should be in scope")
            }
            for capability in step.expect.planForbids ?? [] where scope.contains(capability) {
                failures.append("\(label): \(capability) must not be in scope")
            }
            if let planner {
                do {
                    let plan = try await planner.plan(for: request, now: now)
                    for capability in step.expect.planForbids ?? []
                    where plan.steps.contains(where: { $0.capability == capability }) {
                        failures.append("\(label): the plan used \(capability)")
                    }
                } catch {
                    failures.append("\(label): planning failed (\(error))")
                }
            }
        }

        if step.expect.attentionFirst != nil || step.expect.attentionReason != nil {
            let items = try await intelligence.attention(now: now)
            guard let first = items.first else {
                failures.append("\(label): nothing was raised")
                return failures
            }
            if let title = step.expect.attentionFirst, !first.title.localizedCaseInsensitiveContains(title) {
                failures.append("\(label): first item is \"\(first.title)\", expected \"\(title)\"")
            }
            if let reason = step.expect.attentionReason, !first.reason.localizedCaseInsensitiveContains(reason) {
                failures.append("\(label): reason is \"\(first.reason)\", expected \"\(reason)\"")
            }
        }

        return failures
    }

    // MARK: Matching

    private func matches(_ statement: ExpectedStatement, states: [AssertionState]) async throws -> Bool {
        guard let subject = try await resolve(statement.subject, kind: nil) else { return false }
        let assertions = try await store.assertions(
            about: subject.id, includeIncoming: false, states: states, limit: 100
        )
        for assertion in assertions where assertion.predicate.rawValue == statement.predicate {
            if let object = statement.object {
                guard let objectID = assertion.objectID,
                      let entity = try await store.entity(objectID),
                      entity.title.localizedCaseInsensitiveContains(object) else { continue }
            }
            if let expected = statement.value {
                guard let value = assertion.value, valueMatches(value, expected) else { continue }
            }
            return true
        }
        return false
    }

    /// Text is compared loosely; a date is compared by the day it lands on, so "next friday" and
    /// "+4d" are the same expectation.
    private func valueMatches(_ value: AssertionValue, _ expected: String) -> Bool {
        switch value {
        case let .text(text):
            return text.localizedCaseInsensitiveContains(expected) || expected.localizedCaseInsensitiveContains(text)
        case let .date(date, phrase):
            if let target = resolveDate(expected) {
                return calendar.isDate(date, inSameDayAs: target)
            }
            return phrase?.localizedCaseInsensitiveContains(expected) ?? false
        case let .number(number):
            return String(number) == expected
        case let .flag(flag):
            return String(flag) == expected
        }
    }

    // MARK: Helpers

    private func resolve(_ title: String, kind: EntityKind?) async throws -> IntelligenceEntity? {
        if ["i", "me", "you", "my"].contains(title.lowercased()) {
            return try await store.entity(IntelligenceIdentity.userEntityID)
        }
        return try await store.resolve(title: title, kind: kind)
    }

    private func resolveOrCreate(_ title: String, kind: String) async throws -> IntelligenceEntity {
        let kind = EntityKind(rawValue: kind) ?? .project
        if let found = try await resolve(title, kind: kind) { return found }
        return try await store.create(kind: kind, title: title)
    }

    private func date(daysAgo: Int?) -> Date {
        guard let daysAgo else { return now }
        return calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
    }

    /// "+3d" / "-2d" for exact offsets, anything else through the production date parser, so the
    /// suite resolves phrases exactly as a turn would.
    private func resolveDate(_ phrase: String) -> Date? {
        if phrase.hasPrefix("+") || phrase.hasPrefix("-"), phrase.hasSuffix("d"),
           let days = Int(phrase.dropFirst().dropLast()) {
            return calendar.date(byAdding: .day, value: phrase.hasPrefix("-") ? -days : days, to: now)
        }
        return IntelligenceDateResolver(calendar: calendar).resolve(phrase, now: now)
    }
}
