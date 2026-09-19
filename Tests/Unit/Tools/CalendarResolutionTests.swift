import Core
import Foundation
import Testing
@testable import Tools

@Suite struct CreateEventResolutionTests {
    private func create(_ arguments: [String: ToolArgumentValue], suite: FakeToolSuite = World.suite()) async -> ResolutionOutcome {
        await World.resolve(.createCalendarEvent, arguments, suite: suite)
    }

    private func draft(_ outcome: ResolutionOutcome) -> EventDraft? {
        if case let .createCalendarEvent(draft)? = outcome.action { return draft }
        return nil
    }

    @Test func dateOnlyStartIsAllDay() async throws {
        let draft = try #require(draft(await create(["title": .string("Offsite"), "start": .string("friday")])))
        #expect(draft.isAllDay)
        #expect(draft.startDate == World.date(2026, 9, 18))
        #expect(draft.endDate == World.date(2026, 9, 19))
        #expect(draft.title == "Offsite")
        #expect(draft.location == nil)
    }

    @Test func durationSetsTheEnd() async throws {
        let draft = try #require(draft(await create([
            "title": .string("Call with Sam"), "start": .string("tomorrow at 3pm"), "duration_minutes": .integer(30),
        ])))
        #expect(!draft.isAllDay)
        #expect(draft.startDate == World.date(2026, 9, 18, 15, 0))
        #expect(draft.endDate == World.date(2026, 9, 18, 15, 30))
    }

    @Test func defaultDurationIsOneHour() async throws {
        let draft = try #require(draft(await create(["title": .string("Gym"), "start": .string("friday at 9am")])))
        #expect(draft.endDate == World.date(2026, 9, 18, 10, 0))
    }

    @Test func timeOnlyEndTakesTheStartDate() async throws {
        // The parser anchors "4pm" to today (Thursday); the event is on Friday.
        let draft = try #require(draft(await create([
            "title": .string("Review"), "start": .string("friday at 3pm"), "end": .string("4pm"),
        ])))
        #expect(draft.startDate == World.date(2026, 9, 18, 15, 0))
        #expect(draft.endDate == World.date(2026, 9, 18, 16, 0))
    }

    @Test func endWinsOverDuration() async throws {
        let draft = try #require(draft(await create([
            "title": .string("Review"), "start": .string("friday at 3pm"), "end": .string("4pm"), "duration_minutes": .integer(15),
        ])))
        #expect(draft.endDate == World.date(2026, 9, 18, 16, 0))
    }

    @Test func inferredMeridiemEndIsAfterTheStart() async throws {
        // "from 3 to 5": the parser read "5" as 5 AM.
        let draft = try #require(draft(await create([
            "title": .string("Workshop"), "start": .string("friday at 3pm"), "end": .string("5"),
        ])))
        #expect(draft.endDate == World.date(2026, 9, 18, 17, 0))
    }

    @Test func durationPhraseInTheEndSlotIsUnderstood() async throws {
        let draft = try #require(draft(await create([
            "title": .string("Hike"), "start": .string("friday at 9am"), "end": .string("2 hours"),
        ])))
        #expect(draft.endDate == World.date(2026, 9, 18, 11, 0))
    }

    @Test func endBeforeStartAsks() async throws {
        let clarification = try #require(await create([
            "title": .string("Review"), "start": .string("friday at 3pm"), "end": .string("2pm"),
        ]).clarification)
        #expect(clarification.reason == .dateUnclear)
        #expect(clarification.question == "The end time is before the start. When should it end?")
        #expect(clarification.missingArgument == "end")
    }

    @Test func unparseableStartAsksWhen() async throws {
        let clarification = try #require(await create(["title": .string("Party"), "start": .string("someday soonish")]).clarification)
        #expect(clarification.reason == .dateUnclear)
        #expect(clarification.question == "I didn't catch when. What day and time should I schedule it for?")
        #expect(clarification.missingArgument == "start")
    }

    @Test func missingStartAsksWhen() async throws {
        let clarification = try #require(await create(["title": .string("Party")]).clarification)
        #expect(clarification.reason == .missingField)
        #expect(clarification.question == "What day and time should I schedule it for?")
    }

    @Test func missingTitleAsksForOne() async throws {
        let clarification = try #require(await create(["title": .string("  "), "start": .string("friday")]).clarification)
        #expect(clarification.reason == .missingField)
        #expect(clarification.missingArgument == "title")
        #expect(clarification.question == "What should I call the event?")
    }

    @Test func dateOnlyStartWithDurationAsksForATime() async throws {
        let clarification = try #require(await create([
            "title": .string("Focus"), "start": .string("friday"), "duration_minutes": .integer(90),
        ]).clarification)
        #expect(clarification.question == "What time should it start?")
        #expect(clarification.reason == .dateUnclear)
    }

    @Test func outOfRangeDurationAsksHowLong() async throws {
        let clarification = try #require(await create([
            "title": .string("Focus"), "start": .string("friday at 9am"), "duration_minutes": .integer(2),
        ]).clarification)
        #expect(clarification.question == "How long should it be?")
        #expect(clarification.missingArgument == "duration_minutes")
    }

    @Test func locationIsKeptAndCleaned() async throws {
        let draft = try #require(draft(await create([
            "title": .string("Lunch"), "start": .string("friday at 2pm"), "location": .string("  Cafe\u{200B} Luna "),
        ])))
        #expect(draft.location == "Cafe Luna")
    }

    @Test func writeOnlyCalendarAccessCanCreate() async {
        let suite = World.suite(permissions: [.calendar: .limited])
        #expect(draft(await create(["title": .string("Gym"), "start": .string("friday at 9am")], suite: suite)) != nil)
    }

    @Test func calendarPermissionStates() async {
        let notAsked = World.suite(permissions: [.calendar: .notDetermined])
        #expect(await create(["title": .string("Gym"), "start": .string("friday")], suite: notAsked).permission == .calendar)
        let denied = World.suite(permissions: [.calendar: .denied])
        #expect(await create(["title": .string("Gym"), "start": .string("friday")], suite: denied).failure?.code == .permissionDenied)
    }
}

@Suite struct UpdateEventResolutionTests {
    private func update(
        _ arguments: [String: ToolArgumentValue],
        session: SessionState = SessionState(),
        pins: [String: ClarificationCandidate] = [:],
        suite: FakeToolSuite = World.suite()
    ) async -> ResolutionOutcome {
        await World.resolve(.updateCalendarEvent, arguments, session: session, pins: pins, suite: suite)
    }

    private func resolved(_ outcome: ResolutionOutcome) -> (EventReference, EventChanges)? {
        if case let .updateCalendarEvent(event, changes)? = outcome.action { return (event, changes) }
        return nil
    }

    private var mondaySession: SessionState {
        var session = SessionState()
        session.lastCalendarEvent = World.teamSyncMonday
        return session
    }

    @Test func timeOnlyNewStartKeepsTheDateAndDuration() async throws {
        let (event, changes) = try #require(resolved(await update(["event_query": .string("it"), "new_start": .string("3pm")], session: mondaySession)))
        #expect(event.eventIdentifier == "e-team-sync-mon")
        #expect(changes.newStartDate == World.date(2026, 9, 21, 15, 0))
        #expect(changes.newEndDate == World.date(2026, 9, 21, 15, 30))
        #expect(changes.newTitle == nil)
    }

    @Test func dateOnlyNewStartKeepsTheTime() async throws {
        let (_, changes) = try #require(resolved(await update(["event_query": .string("that meeting"), "new_start": .string("tuesday")], session: mondaySession)))
        #expect(changes.newStartDate == World.date(2026, 9, 22, 10, 0))
        #expect(changes.newEndDate == World.date(2026, 9, 22, 10, 30))
    }

    @Test func absoluteNewStartPreservesDuration() async throws {
        let (_, changes) = try #require(resolved(await update(["event_query": .string("dentist"), "new_start": .string("friday at 2pm")])))
        #expect(changes.newStartDate == World.date(2026, 9, 18, 14, 0))
        #expect(changes.newEndDate == World.date(2026, 9, 18, 15, 0))
    }

    @Test func newDurationChangesOnlyTheEnd() async throws {
        let (_, changes) = try #require(resolved(await update(["event_query": .string("it"), "new_duration_minutes": .integer(60)], session: mondaySession)))
        #expect(changes.newStartDate == nil)
        #expect(changes.newEndDate == World.date(2026, 9, 21, 11, 0))
    }

    @Test func timeOnlyNewEndUsesTheEventDate() async throws {
        let (_, changes) = try #require(resolved(await update(["event_query": .string("it"), "new_end": .string("11am")], session: mondaySession)))
        #expect(changes.newEndDate == World.date(2026, 9, 21, 11, 0))
    }

    @Test func renameAndRelocate() async throws {
        let (_, changes) = try #require(resolved(await update([
            "event_query": .string("lunch with Alex"), "new_title": .string("Lunch with Alex and Sam"), "new_location": .string("Blue Door"),
        ])))
        #expect(changes.newTitle == "Lunch with Alex and Sam")
        #expect(changes.newLocation == "Blue Door")
        #expect(changes.newStartDate == nil)
    }

    @Test func noEffectiveChangeAsksWhatToChange() async throws {
        let clarification = try #require(await update(["event_query": .string("it"), "new_title": .string("Team sync")], session: mondaySession).clarification)
        #expect(clarification.reason == .missingField)
        #expect(clarification.question == "What should I change?")
        let sameTime = try #require(await update(["event_query": .string("it"), "new_start": .string("10am"), "new_end": .string("10am")], session: mondaySession).clarification)
        #expect(sameTime.question == "The end time is before the start. When should it end?")
    }

    @Test func endBeforeStartAsks() async throws {
        let clarification = try #require(await update(["event_query": .string("it"), "new_end": .string("10am")], session: mondaySession).clarification)
        #expect(clarification.reason == .dateUnclear)
        #expect(clarification.missingArgument == "new_end")
    }

    @Test func unparseableNewStartAsks() async throws {
        let clarification = try #require(await update(["event_query": .string("it"), "new_start": .string("whenever")], session: mondaySession).clarification)
        #expect(clarification.reason == .dateUnclear)
        #expect(clarification.question == "When should I move it to?")
        #expect(clarification.missingArgument == "new_start")
    }

    @Test func allDayEventGivenATimeBecomesAOneHourEvent() async throws {
        var session = SessionState()
        session.lastCalendarEvent = World.offsite
        let (_, changes) = try #require(resolved(await update(["event_query": .string("it"), "new_start": .string("3pm")], session: session)))
        #expect(changes.newStartDate == World.date(2026, 9, 25, 15, 0))
        #expect(changes.newEndDate == World.date(2026, 9, 25, 16, 0))
    }

    @Test func allDayEventMovedToAnotherDayStaysAllDay() async throws {
        var session = SessionState()
        session.lastCalendarEvent = World.offsite
        let (_, changes) = try #require(resolved(await update(["event_query": .string("it"), "new_start": .string("tuesday")], session: session)))
        #expect(changes.newStartDate == World.date(2026, 9, 22))
        #expect(changes.newEndDate == World.date(2026, 9, 23))
    }

    // MARK: Which event

    @Test func pronounWithoutLastEventAsksWhich() async throws {
        let clarification = try #require(await update(["event_query": .string("it"), "new_start": .string("3pm")]).clarification)
        #expect(clarification.reason == .eventNotFound)
        #expect(clarification.question == "Which event do you mean?")
    }

    @Test func pronounUsesFreshDataFromTheStore() async throws {
        // The session holds a stale copy; the store's current times are used for duration math.
        var session = SessionState()
        session.lastCalendarEvent = EventReference(
            eventIdentifier: "e-team-sync-mon", title: "Team sync",
            startDate: World.date(2026, 9, 21, 9, 0), endDate: World.date(2026, 9, 21, 11, 0)
        )
        let (event, changes) = try #require(resolved(await update(["event_query": .string("it"), "new_start": .string("3pm")], session: session)))
        #expect(event == World.teamSyncMonday)
        #expect(changes.newEndDate == World.date(2026, 9, 21, 15, 30))
    }

    @Test func deletedLastEventIsReported() async throws {
        var session = SessionState()
        session.lastCalendarEvent = EventReference(eventIdentifier: "e-gone", title: "Gone", startDate: World.now, endDate: World.now)
        let clarification = try #require(await update(["event_query": .string("it"), "new_start": .string("3pm")], session: session).clarification)
        #expect(clarification.reason == .eventNotFound)
        #expect(clarification.question == "I couldn't find that event anymore. Which event do you mean?")
    }

    @Test func sameTitledEventsAreAmbiguous() async throws {
        let clarification = try #require(await update(["event_query": .string("team sync"), "new_start": .string("3pm")]).clarification)
        #expect(clarification.reason == .eventAmbiguous)
        #expect(clarification.question == "Which Team sync: Monday, September 21 at 10 AM or Tuesday, September 22 at 10 AM?")
        #expect(clarification.candidates.map(\.displayText) == ["Team sync, Mon Sep 21 at 10:00 AM", "Team sync, Tue Sep 22 at 10:00 AM"])
        #expect(clarification.candidates.map(\.identifier) == ["e-team-sync-mon", "e-team-sync-tue"])
        #expect(clarification.candidates[1].matchTerms.contains("Tuesday"))
        #expect(clarification.missingArgument == "event_query")
    }

    @Test func dateWordsInTheQueryNarrowTheMatch() async throws {
        let (event, _) = try #require(resolved(await update(["event_query": .string("tuesday's team sync"), "new_start": .string("3pm")])))
        #expect(event.eventIdentifier == "e-team-sync-tue")
    }

    @Test func pinnedEventResolves() async throws {
        let pin = ClarificationCandidate(kind: .event, identifier: "e-team-sync-tue", displayText: "Team sync, Tue Sep 22 at 10:00 AM", matchTerms: [])
        let (event, changes) = try #require(resolved(await update(["event_query": .string("team sync"), "new_start": .string("3pm")], pins: ["event_query": pin])))
        #expect(event.eventIdentifier == "e-team-sync-tue")
        #expect(changes.newStartDate == World.date(2026, 9, 22, 15, 0))
    }

    @Test func unknownEventIsNotFound() async throws {
        let clarification = try #require(await update(["event_query": .string("board meeting"), "new_start": .string("3pm")]).clarification)
        #expect(clarification.reason == .eventNotFound)
        #expect(clarification.question == "I couldn't find board meeting on your calendar. Which event do you mean?")
    }

    @Test func eventsOutsideTheSearchWindowAreNotFound() async throws {
        let clarification = try #require(await update(["event_query": .string("conference"), "new_start": .string("3pm")]).clarification)
        #expect(clarification.reason == .eventNotFound)
    }

    @Test func kindWordsAloneFallBackToSearchWithoutALastEvent() async throws {
        // "the appointment" with no event in context: the only appointment matches.
        let (event, _) = try #require(resolved(await update(["event_query": .string("the appointment"), "new_start": .string("friday at 2pm")])))
        #expect(event.eventIdentifier == "e-dentist")
    }

    @Test func distinctTitlesAreListedByName() async throws {
        let breakfast = EventReference(eventIdentifier: "e-b", title: "Breakfast with Alex", startDate: World.date(2026, 9, 19, 8, 0), endDate: World.date(2026, 9, 19, 9, 0))
        let suite = World.suite(events: World.events + [breakfast])
        let clarification = try #require(await update(["event_query": .string("alex"), "new_start": .string("3pm")], suite: suite).clarification)
        #expect(clarification.question == "I found Lunch with Alex and Breakfast with Alex. Which one?")
    }

    @Test func fullCalendarAccessIsRequiredToUpdate() async {
        let suite = World.suite(permissions: [.calendar: .limited])
        let outcome = await update(["event_query": .string("dentist"), "new_start": .string("3pm")], suite: suite)
        #expect(outcome.failure?.code == .permissionDenied)
    }
}

@Suite struct ReadCalendarResolutionTests {
    @Test func rangePhraseResolves() async {
        let outcome = await World.resolve(.getCalendarEvents, ["when": .string("tomorrow")])
        #expect(outcome.action == .getCalendarEvents(DateRange(start: World.date(2026, 9, 18), end: World.date(2026, 9, 19), spokenDescription: "tomorrow")))
    }

    @Test func instantPhraseReadsThatDay() async {
        let outcome = await World.resolve(.getCalendarEvents, ["when": .string("friday at 3pm")])
        guard case let .getCalendarEvents(range)? = outcome.action else {
            Issue.record("expected a range")
            return
        }
        #expect(range.start == World.date(2026, 9, 18))
        #expect(range.end == World.date(2026, 9, 19))
    }

    @Test func unclearRangeAsks() async throws {
        let clarification = try #require(await World.resolve(.getCalendarEvents, ["when": .string("sometime")]).clarification)
        #expect(clarification.reason == .dateUnclear)
        #expect(clarification.question == "Which day should I check?")
        #expect(clarification.missingArgument == "when")
    }
}

@Suite struct ReminderResolutionTests {
    private func draft(_ outcome: ResolutionOutcome) -> ReminderDraft? {
        if case let .createReminder(draft)? = outcome.action { return draft }
        return nil
    }

    @Test func timedReminder() async throws {
        let draft = try #require(draft(await World.resolve(.createReminder, ["title": .string("Call the bank"), "due": .string("tomorrow at 9am")])))
        #expect(draft.title == "Call the bank")
        #expect(draft.dueDate == World.date(2026, 9, 18, 9, 0))
        #expect(draft.dueHasTime)
    }

    @Test func dateOnlyReminder() async throws {
        let draft = try #require(draft(await World.resolve(.createReminder, ["title": .string("Pay rent"), "due": .string("friday")])))
        #expect(draft.dueDate == World.date(2026, 9, 18))
        #expect(!draft.dueHasTime)
    }

    @Test func undatedReminder() async throws {
        let draft = try #require(draft(await World.resolve(.createReminder, ["title": .string("Buy milk")])))
        #expect(draft.dueDate == nil)
        #expect(!draft.dueHasTime)
    }

    @Test func unclearDueAsks() async throws {
        let clarification = try #require(await World.resolve(.createReminder, ["title": .string("Buy milk"), "due": .string("eventually")]).clarification)
        #expect(clarification.reason == .dateUnclear)
        #expect(clarification.question == "When should I remind you?")
        #expect(clarification.missingArgument == "due")
    }

    @Test func missingTitleAsks() async throws {
        let clarification = try #require(await World.resolve(.createReminder, ["title": .string("")]).clarification)
        #expect(clarification.question == "What should I remind you about?")
        let tooLong = try #require(await World.resolve(.createReminder, ["title": .string(String(repeating: "x", count: 121))]).clarification)
        #expect(tooLong.question == "That's too long for a reminder. What should I remind you about?")
    }

    @Test func remindersPermission() async {
        let notAsked = World.suite(permissions: [.reminders: .notDetermined])
        #expect(await World.resolve(.createReminder, ["title": .string("x")], suite: notAsked).permission == .reminders)
        let restricted = World.suite(permissions: [.reminders: .restricted])
        #expect(await World.resolve(.createReminder, ["title": .string("x")], suite: restricted).failure?.code == .permissionDenied)
    }

    @Test func eventKitDueComponents() {
        let dateOnly = SystemEventKitStore.dueComponents(for: World.date(2026, 9, 18), hasTime: false, calendar: World.calendar)
        #expect(dateOnly.year == 2026 && dateOnly.month == 9 && dateOnly.day == 18)
        #expect(dateOnly.hour == nil && dateOnly.minute == nil)
        #expect(dateOnly.timeZone == nil)
        let timed = SystemEventKitStore.dueComponents(for: World.date(2026, 9, 18, 9, 30), hasTime: true, calendar: World.calendar)
        #expect(timed.hour == 9 && timed.minute == 30)
        #expect(timed.timeZone == World.timeZone)
    }
}

@Suite struct CalendarSupportTests {
    @Test(arguments: [
        ("4pm", true), ("at 3:30", true), ("noon", true), ("3", true), ("half past three", true),
        ("9 in the morning", true), ("5 p.m.", true), ("15:30", true), ("at 4 o'clock", true),
        ("tomorrow at 4", false), ("friday", false), ("in 2 hours", false), ("this afternoon", false),
        ("9/21", false), ("the 21st", false), ("tonight", false), ("next monday at 3", false), ("sept 3", false),
    ])
    func timeOnlyClassification(phrase: String, expected: Bool) {
        #expect(DatePhraseClassifier.isTimeOnly(phrase) == expected, "\(phrase)")
    }

    @Test func occurrenceIdentifiersRoundTrip() {
        let occurrence = World.date(2026, 9, 21, 10, 0)
        let encoded = EventIdentifierCodec.encode(eventIdentifier: "ABC:123", occurrence: occurrence)
        #expect(encoded != "ABC:123")
        let decoded = EventIdentifierCodec.decode(encoded)
        #expect(decoded.eventIdentifier == "ABC:123")
        #expect(decoded.occurrence == occurrence)
        #expect(EventIdentifierCodec.encode(eventIdentifier: "ABC:123", occurrence: nil) == "ABC:123")
        #expect(EventIdentifierCodec.decode("ABC:123").occurrence == nil)
    }

    @Test func eventFormatting() {
        #expect(EventFormatting.candidateText(World.teamSyncMonday, calendar: World.calendar) == "Team sync, Mon Sep 21 at 10:00 AM")
        #expect(EventFormatting.spokenWhen(World.teamSyncMonday, calendar: World.calendar) == "Monday, September 21 at 10 AM")
        #expect(EventFormatting.candidateText(World.offsite, calendar: World.calendar) == "Company offsite, Fri Sep 25, all day")
        #expect(EventFormatting.spokenTime(World.date(2026, 9, 21, 14, 45), calendar: World.calendar) == "2:45 PM")
    }

    @Test func eventMatcherPrefersSpecificWords() {
        let ranked = EventMatcher.rank(query: "my dentist appointment", events: World.events, now: World.now)
        #expect(ranked.first?.event.eventIdentifier == "e-dentist")
        #expect(ranked.count == 1)
        #expect(EventMatcher.rank(query: "the", events: World.events, now: World.now).isEmpty)
    }

    @Test func fakeCalendarKeepsAllDayOnlyForWholeDays() async throws {
        let recorder = SideEffectRecorder()
        let store = FakeCalendarStore(events: [World.offsite], recorder: recorder, calendar: World.calendar)
        let moved = try await store.updateEvent(identifier: "e-offsite", changes: EventChanges(newStartDate: World.date(2026, 9, 28), newEndDate: World.date(2026, 9, 29)))
        #expect(moved.isAllDay)
        let timed = try await store.updateEvent(identifier: "e-offsite", changes: EventChanges(newStartDate: World.date(2026, 9, 28, 15, 0), newEndDate: World.date(2026, 9, 28, 16, 0)))
        #expect(!timed.isAllDay)
        #expect(await recorder.count == 2)
    }
}
