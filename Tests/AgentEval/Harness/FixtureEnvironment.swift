import Agent
import Core
import Foundation
import Permissions
import Tools

/// Builds the fake tool world for one evaluation case from its fixture, with the case's fixed
/// "now" and time zone. Fixture ids become native identifiers (e.g. contact "c-alex-kim").
public enum FixtureEnvironment {
    public enum FixtureError: Error, CustomStringConvertible {
        case badTimeZone(String)
        case badDate(String)
        case unknownPermission(String)

        public var description: String {
            switch self {
            case let .badTimeZone(value): "unknown time zone \(value)"
            case let .badDate(value): "unparseable local date-time \(value)"
            case let .unknownPermission(value): "unknown permission \(value)"
            }
        }
    }

    public static func clock(for evalCase: EvalCase) throws -> AgentClock {
        guard let zone = TimeZone(identifier: evalCase.timezone) else { throw FixtureError.badTimeZone(evalCase.timezone) }
        let now = try localDate(evalCase.now, zone: zone)
        return AgentClock.fixed(now, timeZone: zone)
    }

    public static func makeSuite(fixture: EvalFixture, clock: AgentClock) throws -> FakeToolSuite {
        let zone = clock.timeZone
        let contacts = fixture.contacts.map { contact in
            ContactRecord(
                identifier: contact.id,
                givenName: contact.given,
                familyName: contact.family ?? "",
                nickname: contact.nickname ?? "",
                organization: contact.organization ?? "",
                phones: contact.phones.map { LabeledPhone(label: $0.label, number: $0.number) }
            )
        }
        let events = try fixture.events.map { event in
            EventReference(
                eventIdentifier: event.id,
                title: event.title,
                startDate: try localDate(event.start, zone: zone),
                endDate: try localDate(event.end, zone: zone),
                isAllDay: event.allDay ?? false,
                location: event.location
            )
        }
        let files = try fixture.files.map { file in
            FileSummary(
                reference: FileReference(
                    scopeIdentifier: file.scope,
                    relativePath: file.path,
                    displayName: (file.path as NSString).lastPathComponent
                ),
                modifiedAt: try file.modified.map { try localDate($0, zone: zone) },
                byteSize: file.bytes
            )
        }
        return FakeToolSuite(
            contacts: contacts,
            events: events,
            files: files,
            authorizedScopes: fixture.authorizedFileScopes,
            permissions: try permissions(fixture.permissions),
            permissionResponses: try permissions(fixture.permissionResponses ?? [:]),
            canSendText: fixture.canSendText ?? true,
            canPlaceCalls: fixture.canPlaceCalls ?? true,
            clock: clock
        )
    }

    /// A coordinator wired to the fake world and the given language model (real or scripted).
    @MainActor
    public static func makeCoordinator(suite: FakeToolSuite, clock: AgentClock, languageModel: any LanguageModel,
                                       configuration: AgentConfiguration = .default) -> AgentCoordinator {
        let messages = suite.messages
        let calls = suite.calls
        let dependencies = AgentDependencies(
            languageModel: languageModel,
            resolver: ActionResolver(environment: suite.environment),
            executor: ToolExecutor(environment: suite.environment),
            permissions: suite.permissions,
            capabilities: CapabilityRegistry(
                canSendText: { await messages.canSendText() },
                canPlaceCalls: { await calls.canPlaceCalls() }
            ),
            clock: clock
        )
        return AgentCoordinator(dependencies: dependencies, configuration: configuration)
    }

    static func permissions(_ raw: [String: String]) throws -> [PermissionKind: PermissionStatus] {
        var result: [PermissionKind: PermissionStatus] = [:]
        for (key, value) in raw {
            guard let kind = PermissionKind(rawValue: key), let status = PermissionStatus(rawValue: value) else {
                throw FixtureError.unknownPermission("\(key)=\(value)")
            }
            result[kind] = status
        }
        return result
    }

    /// "YYYY-MM-DDTHH:MM[:SS]" or "YYYY-MM-DD" in `zone`.
    public static func localDate(_ text: String, zone: TimeZone) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = text.split(whereSeparator: { $0 == "T" || $0 == "-" || $0 == ":" }).map { Int($0) }
        guard parts.count >= 3, parts.allSatisfy({ $0 != nil }) else { throw FixtureError.badDate(text) }
        let values = parts.compactMap { $0 }
        var components = DateComponents()
        components.year = values[0]
        components.month = values[1]
        components.day = values[2]
        components.hour = values.count > 3 ? values[3] : 0
        components.minute = values.count > 4 ? values[4] : 0
        components.second = values.count > 5 ? values[5] : 0
        guard let date = calendar.date(from: components) else { throw FixtureError.badDate(text) }
        return date
    }
}

extension TurnObservation {
    /// Maps the coordinator's report onto the evaluation vocabulary.
    public init(report: TurnReport) {
        let outcome = ObservedOutcome(rawValue: report.outcome.rawValue) ?? .noAction
        let pending = report.pendingAction
        let lastExecution = report.executions.last
        let action = outcome == .executed ? (lastExecution?.action ?? pending?.validatedArguments) : (pending?.validatedArguments ?? lastExecution?.action)
        self.init(
            outcome: outcome,
            tool: action?.tool ?? report.clarification?.partialCall?.tool,
            action: action,
            pendingVersion: pending?.version,
            clarificationReason: outcome == .clarificationRequested ? report.clarification?.reason : nil,
            spokenText: report.spokenText,
            consequentialExecutions: report.consequentialExecutions.map(\.action),
            readOnlyExecutions: report.executions.filter { !$0.consequential }.map(\.action),
            modelOutputs: report.modelOutputs,
            modelLatencyMilliseconds: report.modelMilliseconds
        )
    }
}
