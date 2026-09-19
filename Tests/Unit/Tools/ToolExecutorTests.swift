import Core
import Foundation
import Permissions
import Telemetry
import Testing
@testable import Tools

@Suite struct ToolExecutorTests {
    private let alexTarget = ContactTarget(contactIdentifier: "c-alex-kim", displayName: "Alex Kim", phoneNumber: "(555) 010-1001", phoneLabel: "mobile")
    private let dictatedTarget = ContactTarget(contactIdentifier: nil, displayName: "555-1212", phoneNumber: "5551212", phoneLabel: nil)

    private func pending(_ action: ResolvedAction, id: UUID = UUID(), createdAt: Date = World.now, lifetime: TimeInterval = 120) -> PendingAction {
        PendingAction(id: id, action: action, humanReadableSummary: "summary", originalTranscript: "transcript", createdAt: createdAt, lifetime: lifetime)
    }

    /// An approved action and its token.
    private func approved(_ action: ResolvedAction, id: UUID = UUID(), createdAt: Date = World.now) throws -> (PendingAction, ConfirmationToken) {
        var pendingAction = pending(action, id: id, createdAt: createdAt)
        let tokenCandidate = pendingAction.approve(at: createdAt)
        let token = try #require(tokenCandidate)
        return (pendingAction, token)
    }

    private var message: ResolvedAction { .composeMessage(alexTarget, body: "Running late") }

    // MARK: Token binding — no side effects on any mismatch

    @Test func validTokenExecutesExactlyOnce() async throws {
        let suite = World.suite()
        let executor = ToolExecutor(environment: suite.environment)
        let (action, token) = try approved(message)

        let result = await executor.execute(action, token: token)
        #expect(result == .success(.messageSent(alexTarget)))
        #expect(await suite.recorder.effects == [.messageComposed(recipients: ["5550101001"], body: "Running late", outcome: .sent)])

        // Presenting the same approval again does nothing.
        let replay = await executor.execute(action, token: token)
        #expect(replay.failureCode == .confirmationMismatch)
        #expect(await suite.recorder.count == 1)
    }

    @Test func tokenForAnotherVersionIsRejected() async throws {
        let suite = World.suite()
        let executor = ToolExecutor(environment: suite.environment)
        let (version1, token1) = try approved(message)
        var version2 = version1.revised(action: .composeMessage(alexTarget, body: "Running very late"), humanReadableSummary: "s", originalTranscript: "t", now: World.now, lifetime: 120)
        let approval = version2.approve(at: World.now)
        _ = try #require(approval)

        let result = await executor.execute(version2, token: token1)
        #expect(result.failureCode == .confirmationMismatch)
        #expect(await suite.recorder.count == 0)
    }

    @Test func tokenWithAnotherDigestIsRejected() async throws {
        let suite = World.suite()
        let executor = ToolExecutor(environment: suite.environment)
        let id = UUID()
        let (original, _) = try approved(message, id: id)
        // Same id and version, different arguments: its token carries a different digest.
        let (_, otherToken) = try approved(.composeMessage(alexTarget, body: "Send me your password"), id: id)

        let result = await executor.execute(original, token: otherToken)
        #expect(result.failureCode == .confirmationMismatch)
        #expect(await suite.recorder.count == 0)
    }

    @Test func tokenForAnotherActionIsRejected() async throws {
        let suite = World.suite()
        let executor = ToolExecutor(environment: suite.environment)
        let (action, _) = try approved(message)
        let (_, foreignToken) = try approved(message)
        #expect(await executor.execute(action, token: foreignToken).failureCode == .confirmationMismatch)
        #expect(await suite.recorder.count == 0)
    }

    @Test func rejectedOrUnapprovedActionsNeverRun() async throws {
        let suite = World.suite()
        let executor = ToolExecutor(environment: suite.environment)

        var rejected = pending(message)
        let tokenCandidate = rejected.approve(at: World.now)
        let token = try #require(tokenCandidate)
        rejected.reject()
        #expect(await executor.execute(rejected, token: token).failureCode == .confirmationMismatch)

        let stillPending = pending(message)
        var copy = stillPending
        let copyTokenCandidate = copy.approve(at: World.now)
        let copyToken = try #require(copyTokenCandidate)
        #expect(await executor.execute(stillPending, token: copyToken).failureCode == .confirmationMismatch)
        #expect(await suite.recorder.count == 0)
    }

    @Test func expiredApprovalIsRejected() async throws {
        let suite = World.suite()
        let executor = ToolExecutor(environment: suite.environment)
        // Created and approved 3 minutes ago with a 2 minute lifetime.
        let (action, token) = try approved(message, createdAt: World.now.addingTimeInterval(-180))
        #expect(await executor.execute(action, token: token).failureCode == .expired)
        #expect(await suite.recorder.count == 0)
    }

    // MARK: Messages

    @Test(arguments: [
        (MessageComposeOutcome.cancelled, ToolResult.cancelledByUser(.composeMessage)),
        (.failed, .failure(ToolFailure(tool: .composeMessage, code: .systemError))),
        (.unavailable, .failure(ToolFailure(tool: .composeMessage, code: .notAvailableOnDevice))),
    ])
    func composeOutcomesAreReportedTruthfully(outcome: MessageComposeOutcome, expected: ToolResult) async throws {
        let suite = World.suite(composeOutcomes: [outcome])
        let (action, token) = try approved(message)
        #expect(await ToolExecutor(environment: suite.environment).execute(action, token: token) == expected)
        #expect(await suite.messages.composeAttempts == 1)
    }

    @Test func deviceThatCannotTextNeverPresentsTheComposer() async throws {
        let suite = World.suite(canSendText: false)
        let (action, token) = try approved(message)
        let result = await ToolExecutor(environment: suite.environment).execute(action, token: token)
        #expect(result.failureCode == .notAvailableOnDevice)
        #expect(await suite.messages.composeAttempts == 0)
        #expect(await suite.recorder.count == 0)
    }

    // MARK: Calls

    @Test func callStartsWithDialableDigits() async throws {
        let suite = World.suite()
        let (action, token) = try approved(.initiateCall(alexTarget))
        #expect(await ToolExecutor(environment: suite.environment).execute(action, token: token) == .success(.callStarted(alexTarget)))
        #expect(await suite.recorder.effects == [.callStarted(digits: "5550101001")])
    }

    @Test func callFailuresAreNotReportedAsSuccess() async throws {
        let noPhone = World.suite(canPlaceCalls: false)
        let (first, firstToken) = try approved(.initiateCall(alexTarget))
        #expect(await ToolExecutor(environment: noPhone.environment).execute(first, token: firstToken).failureCode == .notAvailableOnDevice)

        let failing = World.suite()
        await failing.calls.setOpens(false)
        let (second, secondToken) = try approved(.initiateCall(alexTarget))
        #expect(await ToolExecutor(environment: failing.environment).execute(second, token: secondToken).failureCode == .systemError)
        #expect(await failing.recorder.count == 0)
    }

    @Test func dictatedNumberCallNeedsNoContactsPermission() async throws {
        let suite = World.suite(permissions: [.contacts: .denied])
        let (action, token) = try approved(.initiateCall(dictatedTarget))
        #expect(await ToolExecutor(environment: suite.environment).execute(action, token: token) == .success(.callStarted(dictatedTarget)))
    }

    @Test func revokedPermissionIsRecheckedBeforeTheSideEffect() async throws {
        let suite = World.suite()
        let (action, token) = try approved(.initiateCall(alexTarget))
        await suite.permissionBackend.set(.contacts, .denied)
        #expect(await ToolExecutor(environment: suite.environment).execute(action, token: token).failureCode == .permissionDenied)
        #expect(await suite.recorder.count == 0)

        let calendarSuite = World.suite()
        let draft = EventDraft(title: "Gym", startDate: World.date(2026, 9, 18, 9, 0), endDate: World.date(2026, 9, 18, 10, 0))
        let (event, eventToken) = try approved(.createCalendarEvent(draft))
        await calendarSuite.permissionBackend.set(.calendar, .restricted)
        #expect(await ToolExecutor(environment: calendarSuite.environment).execute(event, token: eventToken).failureCode == .permissionDenied)
        #expect(await calendarSuite.recorder.count == 0)
    }

    // MARK: Calendar and reminders

    @Test func createEventReturnsTheStoredEvent() async throws {
        let suite = World.suite()
        let draft = EventDraft(title: "Gym", startDate: World.date(2026, 9, 18, 9, 0), endDate: World.date(2026, 9, 18, 10, 0), location: "Downtown")
        let (action, token) = try approved(.createCalendarEvent(draft))
        let result = await ToolExecutor(environment: suite.environment).execute(action, token: token)
        guard case let .eventCreated(event)? = result.outcome else {
            Issue.record("expected eventCreated, got \(result)")
            return
        }
        #expect(event.title == "Gym")
        #expect(event.startDate == draft.startDate)
        #expect(event.location == "Downtown")
        #expect(await suite.recorder.effects == [.eventCreated(draft)])
    }

    @Test func storeFailuresMapToFailureCodes() async throws {
        let suite = World.suite()
        await suite.calendar.setWriteFailure(.readOnly)
        let draft = EventDraft(title: "Gym", startDate: World.now, endDate: World.now.addingTimeInterval(3_600))
        let (action, token) = try approved(.createCalendarEvent(draft))
        #expect(await ToolExecutor(environment: suite.environment).execute(action, token: token).failureCode == .unsupported)
        #expect(await suite.recorder.count == 0)

        let reminders = World.suite()
        await reminders.reminders.setFailure(.noDefaultCalendar)
        let (reminder, reminderToken) = try approved(.createReminder(ReminderDraft(title: "x", dueDate: nil, dueHasTime: false)))
        #expect(await ToolExecutor(environment: reminders.environment).execute(reminder, token: reminderToken).failureCode == .notAvailableOnDevice)
    }

    @Test func updateEventAppliesChanges() async throws {
        let suite = World.suite()
        let changes = EventChanges(newStartDate: World.date(2026, 9, 21, 15, 0), newEndDate: World.date(2026, 9, 21, 15, 30))
        let (action, token) = try approved(.updateCalendarEvent(World.teamSyncMonday, changes))
        let result = await ToolExecutor(environment: suite.environment).execute(action, token: token)
        guard case let .eventUpdated(event)? = result.outcome else {
            Issue.record("expected eventUpdated, got \(result)")
            return
        }
        #expect(event.startDate == World.date(2026, 9, 21, 15, 0))
        #expect(event.eventIdentifier == "e-team-sync-mon")
        #expect(await suite.recorder.effects == [.eventUpdated(id: "e-team-sync-mon", changes: changes)])
    }

    @Test func updatingAMissingEventFails() async throws {
        let suite = World.suite(events: [])
        let (action, token) = try approved(.updateCalendarEvent(World.teamSyncMonday, EventChanges(newTitle: "x")))
        #expect(await ToolExecutor(environment: suite.environment).execute(action, token: token).failureCode == .notFound)
        #expect(await suite.recorder.count == 0)
    }

    @Test func reminderIsCreated() async throws {
        let suite = World.suite()
        let draft = ReminderDraft(title: "Pay rent", dueDate: World.date(2026, 9, 18), dueHasTime: false)
        let (action, token) = try approved(.createReminder(draft))
        #expect(await ToolExecutor(environment: suite.environment).execute(action, token: token) == .success(.reminderCreated(draft)))
        #expect(await suite.recorder.effects == [.reminderCreated(draft)])
        #expect(await suite.recorder.consequentialEffects.count == 1)
    }

    // MARK: Read-only path

    @Test func readOnlyPathRefusesConsequentialActions() async {
        let suite = World.suite()
        let executor = ToolExecutor(environment: suite.environment)
        let consequential: [ResolvedAction] = [
            message,
            .initiateCall(alexTarget),
            .createReminder(ReminderDraft(title: "x", dueDate: nil, dueHasTime: false)),
            .createCalendarEvent(EventDraft(title: "x", startDate: World.now, endDate: World.now)),
            .updateCalendarEvent(World.teamSyncMonday, EventChanges(newTitle: "x")),
        ]
        for action in consequential {
            #expect(await executor.executeReadOnly(action).failureCode == .confirmationMismatch, "\(action.tool.rawValue)")
        }
        #expect(await suite.recorder.count == 0)
        #expect(await suite.messages.composeAttempts == 0)
        #expect(await suite.calls.callAttempts == 0)
    }

    @Test func searchContactsReturnsRankedMatches() async {
        let executor = ToolExecutor(environment: World.suite().environment)
        let result = await executor.executeReadOnly(.searchContacts(query: "Alex"))
        guard case let .contactsFound(found)? = result.outcome else {
            Issue.record("expected contacts")
            return
        }
        #expect(found.map(\.contactIdentifier) == ["c-alex-chen", "c-alex-kim"])
        #expect(found[0].phoneNumbers.count == 2)

        let many = (1...8).map { ContactRecord(identifier: "c-\($0)", givenName: "Alex", familyName: "N\($0)") }
        let capped = await ToolExecutor(environment: World.suite(contacts: many).environment).executeReadOnly(.searchContacts(query: "Alex"))
        if case let .contactsFound(list)? = capped.outcome { #expect(list.count == 5) } else { Issue.record("expected contacts") }

        let none = await executor.executeReadOnly(.searchContacts(query: "Taylor"))
        #expect(none == .success(.contactsFound([])))
    }

    @Test func calendarEventsAreListedInOrder() async {
        let range = DateRange(start: World.date(2026, 9, 18), end: World.date(2026, 9, 26), spokenDescription: "next week")
        let result = await ToolExecutor(environment: World.suite().environment).executeReadOnly(.getCalendarEvents(range))
        guard case let .eventsListed(events, listedRange)? = result.outcome else {
            Issue.record("expected events")
            return
        }
        #expect(events.map(\.eventIdentifier) == ["e-lunch-alex", "e-team-sync-mon", "e-team-sync-tue", "e-dentist", "e-offsite"])
        #expect(listedRange == range)
        let inverted = DateRange(start: range.end, end: range.start, spokenDescription: "x")
        #expect(await ToolExecutor(environment: World.suite().environment).executeReadOnly(.getCalendarEvents(inverted)).failureCode == .invalidArguments)
    }

    @Test func fileSearchAndOpen() async {
        let files = (1...12).map { World.file("docs", "Report \($0).pdf") }
        let suite = World.suite(files: files, authorizedScopes: ["docs"])
        let executor = ToolExecutor(environment: suite.environment)
        guard case let .filesFound(found)? = await executor.executeReadOnly(.searchFiles(query: "report")).outcome else {
            Issue.record("expected files")
            return
        }
        #expect(found.count == 10)

        let reference = files[0].reference
        #expect(await executor.executeReadOnly(.openFile(reference)) == .success(.fileOpened(reference)))
        #expect(await suite.recorder.effects == [.fileOpened(reference)])

        let escaping = FileReference(scopeIdentifier: "docs", relativePath: "../secret.pdf", displayName: "secret.pdf")
        #expect(await executor.executeReadOnly(.openFile(escaping)).failureCode == .invalidArguments)
        #expect(await suite.recorder.count == 1)
    }

    @Test func fileActionsWithoutAScopeFail() async {
        let executor = ToolExecutor(environment: World.suite().environment)
        #expect(await executor.executeReadOnly(.searchFiles(query: "x")).failureCode == .noAuthorizedScope)
    }

    @Test func appsOpenThroughTheLauncher() async {
        let suite = World.suite()
        let executor = ToolExecutor(environment: suite.environment)
        #expect(await executor.executeReadOnly(.openSupportedApp(.maps, query: "coffee")) == .success(.appOpened(.maps)))
        #expect(await executor.executeReadOnly(.openSupportedApp(.music, query: "ignored")) == .success(.appOpened(.music)))
        #expect(await suite.recorder.effects == [.appOpened(.maps, query: "coffee"), .appOpened(.music, query: nil)])

        await suite.apps.setUnavailable([.shortcuts])
        #expect(await executor.executeReadOnly(.openSupportedApp(.shortcuts, query: nil)).failureCode == .notAvailableOnDevice)
    }

    @Test func readOnlyActionsMayAlsoRunWithAToken() async throws {
        let suite = World.suite()
        let (action, token) = try approved(.openSupportedApp(.calendar, query: nil))
        #expect(await ToolExecutor(environment: suite.environment).execute(action, token: token) == .success(.appOpened(.calendar)))
    }
}

@Suite struct PrivacyLoggingTests {
    @Test func logsNeverContainUserContent() async throws {
        let logger = PrivacySafeLogger(ringCapacity: 500)
        let suite = FakeToolSuite(
            contacts: World.contacts,
            events: World.events,
            files: [World.file("docs", "Secret Merger Plan.pdf")],
            authorizedScopes: ["docs"],
            clock: World.clock,
            dateParser: World.parser.factory,
            logger: logger
        )
        let resolver = ActionResolver(environment: suite.environment)
        let executor = ToolExecutor(environment: suite.environment)
        let calls: [ProposedToolCall] = [
            World.call(.composeMessage, ["contact_query": .string("Alex Kim"), "message": .string("The vault code is 4321")]),
            World.call(.composeMessage, ["contact_query": .string("Taylor Swiftly"), "message": .string("hello")]),
            World.call(.initiateCall, ["phone_number": .string("5557654321")]),
            World.call(.updateCalendarEvent, ["event_query": .string("dentist"), "new_title": .string("Therapy session")]),
            World.call(.openFile, ["file_query": .string("merger plan")]),
            World.call(.openSupportedApp, ["app": .string("maps"), "query": .string("Hidden Valley Clinic")]),
        ]
        for call in calls {
            let outcome = await resolver.resolve(call, context: World.context("text Alex Kim the vault code is 4321"))
            if case let .resolved(action) = outcome {
                if action.riskLevel == .readOnly {
                    _ = await executor.executeReadOnly(action)
                } else {
                    var pending = PendingAction(action: action, humanReadableSummary: "s", originalTranscript: "t", createdAt: World.now, lifetime: 120)
                    let tokenCandidate = pending.approve(at: World.now)
                    let token = try #require(tokenCandidate)
                    _ = await executor.execute(pending, token: token)
                }
            }
        }
        let lines = logger.recentEvents().map(\.event.renderedLine)
        #expect(!lines.isEmpty)
        let forbidden = ["Alex", "Kim", "vault", "4321", "Taylor", "5557654321", "Therapy", "Dentist", "dentist", "Merger", "merger", "Hidden Valley", "Clinic"]
        for line in lines {
            for word in forbidden {
                #expect(!line.contains(word), "log line leaks user content: \(line)")
            }
        }
    }
}
