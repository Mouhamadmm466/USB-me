import Core
import Foundation
import Permissions
import Telemetry
import Testing
@testable import Tools

/// Deterministic world shared by the Tools tests: Thursday 2026-09-17 09:00 in New York.
enum World {
    static let timeZone = TimeZone(identifier: "America/New_York")!

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static let now = date(2026, 9, 17, 9, 0)
    static let clock = AgentClock.fixed(now, timeZone: timeZone)

    // MARK: Contacts

    static let alexKim = ContactRecord(
        identifier: "c-alex-kim", givenName: "Alex", familyName: "Kim",
        phones: [LabeledPhone(label: "mobile", number: "(555) 010-1001")]
    )
    static let alexChen = ContactRecord(
        identifier: "c-alex-chen", givenName: "Alex", familyName: "Chen", organization: "Acme",
        phones: [
            LabeledPhone(label: "mobile", number: "(555) 010-1002"),
            LabeledPhone(label: "work", number: "(555) 010-2002"),
        ]
    )
    static let johnSmith = ContactRecord(
        identifier: "c-john-smith", givenName: "John", familyName: "Smith", nickname: "Johnny",
        phones: [LabeledPhone(label: "home", number: "555-010-3003")]
    )
    static let kathrynLee = ContactRecord(
        identifier: "c-kathryn-lee", givenName: "Kathryn", familyName: "Lee",
        phones: [LabeledPhone(label: "iPhone", number: "+1 555 010 4004")]
    )
    static let robertDiaz = ContactRecord(
        identifier: "c-robert-diaz", givenName: "Robert", familyName: "Diaz", nickname: "Bobby",
        phones: [
            LabeledPhone(label: "mobile", number: "555-010-5005"),
            LabeledPhone(label: "work", number: "555-010-5006"),
        ]
    )
    static let samPatel = ContactRecord(identifier: "c-sam-patel", givenName: "Sam", familyName: "Patel", organization: "Globex")
    static let jordanParkA = ContactRecord(
        identifier: "c-jordan-park-1", givenName: "Jordan", familyName: "Park", organization: "Initech",
        phones: [LabeledPhone(label: "mobile", number: "555-010-6001")]
    )
    static let jordanParkB = ContactRecord(
        identifier: "c-jordan-park-2", givenName: "Jordan", familyName: "Park", organization: "Umbrella",
        phones: [LabeledPhone(label: "mobile", number: "555-010-6002")]
    )
    static let acmeDental = ContactRecord(
        identifier: "c-acme-dental", givenName: "", organization: "Acme Dental",
        phones: [LabeledPhone(label: "main", number: "555-010-7007")]
    )
    static let mariaGarcia = ContactRecord(
        identifier: "c-maria-garcia", givenName: "Maria", familyName: "Garcia",
        phones: [
            LabeledPhone(label: "home", number: "555-010-8001"),
            LabeledPhone(label: "work", number: "555-010-8002"),
            LabeledPhone(label: "other", number: "555-010-8003"),
        ]
    )
    static let leeWong = ContactRecord(
        identifier: "c-lee-wong", givenName: "Lee", familyName: "Wong",
        phones: [LabeledPhone(label: "mobile", number: "555-010-9009")]
    )

    static let contacts: [ContactRecord] = [
        alexKim, alexChen, johnSmith, kathrynLee, robertDiaz, samPatel, jordanParkA, jordanParkB, acmeDental,
        mariaGarcia, leeWong,
    ]

    // MARK: Events

    static let teamSyncMonday = EventReference(
        eventIdentifier: "e-team-sync-mon", title: "Team sync",
        startDate: date(2026, 9, 21, 10, 0), endDate: date(2026, 9, 21, 10, 30)
    )
    static let teamSyncTuesday = EventReference(
        eventIdentifier: "e-team-sync-tue", title: "Team sync",
        startDate: date(2026, 9, 22, 10, 0), endDate: date(2026, 9, 22, 10, 30)
    )
    static let lunchWithAlex = EventReference(
        eventIdentifier: "e-lunch-alex", title: "Lunch with Alex",
        startDate: date(2026, 9, 18, 12, 0), endDate: date(2026, 9, 18, 13, 0), location: "Cafe Luna"
    )
    static let dentist = EventReference(
        eventIdentifier: "e-dentist", title: "Dentist appointment",
        startDate: date(2026, 9, 24, 15, 0), endDate: date(2026, 9, 24, 16, 0)
    )
    static let offsite = EventReference(
        eventIdentifier: "e-offsite", title: "Company offsite",
        startDate: date(2026, 9, 25), endDate: date(2026, 9, 26), isAllDay: true
    )
    static let farFuture = EventReference(
        eventIdentifier: "e-far", title: "Conference",
        startDate: date(2026, 12, 20, 9, 0), endDate: date(2026, 12, 20, 17, 0)
    )

    static let events: [EventReference] = [teamSyncMonday, teamSyncTuesday, lunchWithAlex, dentist, offsite, farFuture]

    // MARK: Date phrases (scripted so these tests do not depend on the real parser)

    static func time(_ date: Date, inferred: Bool = false) -> ParsedDateTime {
        ParsedDateTime(date: date, hasTime: true, meridiemInferred: inferred)
    }

    static func day(_ date: Date) -> ParsedDateTime {
        ParsedDateTime(date: date, hasTime: false, meridiemInferred: false)
    }

    static let parser = ScriptedDateParser(
        dateTimes: [
            "friday": day(date(2026, 9, 18)),
            "tuesday": day(date(2026, 9, 22)),
            "saturday": day(date(2026, 9, 19)),
            "tomorrow": day(date(2026, 9, 18)),
            "tomorrow at 3pm": time(date(2026, 9, 18, 15, 0)),
            "friday at 3pm": time(date(2026, 9, 18, 15, 0)),
            "friday at 2pm": time(date(2026, 9, 18, 14, 0)),
            "friday at 9am": time(date(2026, 9, 18, 9, 0)),
            // Bare times anchored to "today" (Thursday) by the parser.
            "3pm": time(date(2026, 9, 17, 15, 0)),
            "4pm": time(date(2026, 9, 17, 16, 0)),
            "2pm": time(date(2026, 9, 17, 14, 0)),
            "11am": time(date(2026, 9, 17, 11, 0)),
            "5": time(date(2026, 9, 17, 5, 0), inferred: true),
            "tomorrow at 9am": time(date(2026, 9, 18, 9, 0)),
            "10am": time(date(2026, 9, 17, 10, 0)),
        ],
        ranges: [
            "today": DateRange(start: date(2026, 9, 17), end: date(2026, 9, 18), spokenDescription: "today"),
            "tomorrow": DateRange(start: date(2026, 9, 18), end: date(2026, 9, 19), spokenDescription: "tomorrow"),
            "tuesday": DateRange(start: date(2026, 9, 22), end: date(2026, 9, 23), spokenDescription: "Tuesday"),
            "next week": DateRange(start: date(2026, 9, 21), end: date(2026, 9, 28), spokenDescription: "next week"),
        ],
        durations: [
            "2 hours": 120,
            "an hour": 60,
        ],
        timeOfDayOnly: ["3pm", "4pm", "2pm", "11am", "5", "10am"]
    )

    // MARK: Builders

    static func suite(
        contacts: [ContactRecord] = World.contacts,
        events: [EventReference] = World.events,
        files: [FileSummary] = [],
        authorizedScopes: [String] = [],
        permissions: [PermissionKind: PermissionStatus] = [:],
        canSendText: Bool = true,
        canPlaceCalls: Bool = true,
        composeOutcomes: [MessageComposeOutcome] = [],
        clock: AgentClock = World.clock,
        dateParser: DateParserFactory? = World.parser.factory
    ) -> FakeToolSuite {
        FakeToolSuite(
            contacts: contacts,
            events: events,
            files: files,
            authorizedScopes: authorizedScopes,
            permissions: permissions,
            canSendText: canSendText,
            canPlaceCalls: canPlaceCalls,
            composeOutcomes: composeOutcomes,
            clock: clock,
            dateParser: dateParser,
            logger: PrivacySafeLogger(ringCapacity: 50)
        )
    }

    static func context(
        _ transcript: String = "",
        session: SessionState = SessionState(),
        pins: [String: ClarificationCandidate] = [:]
    ) -> ResolutionContext {
        ResolutionContext(transcript: transcript, session: session, clock: clock, pinnedSelections: pins)
    }

    static func call(_ tool: ToolID, _ arguments: [String: ToolArgumentValue]) -> ProposedToolCall {
        ProposedToolCall(tool: tool, arguments: arguments)
    }

    static func resolve(
        _ tool: ToolID,
        _ arguments: [String: ToolArgumentValue],
        transcript: String = "",
        session: SessionState = SessionState(),
        pins: [String: ClarificationCandidate] = [:],
        suite: FakeToolSuite = World.suite()
    ) async -> ResolutionOutcome {
        await ActionResolver(environment: suite.environment)
            .resolve(call(tool, arguments), context: context(transcript, session: session, pins: pins))
    }

    static func file(_ scope: String, _ path: String, modified: Date? = nil) -> FileSummary {
        FileSummary(
            reference: FileReference(scopeIdentifier: scope, relativePath: path, displayName: (path as NSString).lastPathComponent),
            modifiedAt: modified,
            byteSize: 1_024
        )
    }
}

// MARK: - Outcome accessors

extension ResolutionOutcome {
    var action: ResolvedAction? {
        if case let .resolved(action) = self { return action }
        return nil
    }

    var clarification: PendingClarification? {
        if case let .needsClarification(clarification) = self { return clarification }
        return nil
    }

    var permission: PermissionKind? {
        if case let .needsPermission(kind) = self { return kind }
        return nil
    }

    var failure: ToolFailure? {
        if case let .failed(failure) = self { return failure }
        return nil
    }

    /// The call or message recipient of a resolved communication action.
    var target: ContactTarget? {
        switch action {
        case let .initiateCall(target)?: target
        case let .composeMessage(target, _)?: target
        default: nil
        }
    }
}

extension ToolResult {
    var outcome: ToolOutcome? {
        if case let .success(outcome) = self { return outcome }
        return nil
    }

    var failureCode: ToolFailureCode? {
        if case let .failure(failure) = self { return failure.code }
        return nil
    }
}
