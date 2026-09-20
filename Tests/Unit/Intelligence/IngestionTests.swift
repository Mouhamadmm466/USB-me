import Foundation
import Testing
@testable import Intelligence

/// Ingestion is where a world model stops being hand-fed — and where it would become surveillance
/// if the rules were wrong. These tests are those rules.
@Suite struct IngestionTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(
        _ id: String, _ title: String, at offset: TimeInterval = 3_600,
        location: String? = nil, mentions: [String] = []
    ) -> IngestedItem {
        IngestedItem(
            sourceType: .calendar, sourceID: id, kind: .event, title: title,
            startsAt: now.addingTimeInterval(offset), endsAt: now.addingTimeInterval(offset + 1_800),
            status: .scheduled, location: location, mentions: mentions
        )
    }

    private func reminder(_ id: String, _ title: String, due: TimeInterval?, done: Bool = false) -> IngestedItem {
        IngestedItem(
            sourceType: .reminders, sourceID: id, kind: .task, title: title,
            dueAt: due.map { now.addingTimeInterval($0) }, status: done ? .done : .open
        )
    }

    @Test func anEventBecomesSomethingTheUserCanSeeWithItsProvenance() async throws {
        let store = try IntelligenceStore()
        let report = try await store.ingest([event("evt-1", "Beta review", location: "Room 3")],
                                            source: .calendar, prune: true, now: now)

        #expect(report.created == 1)
        let entity = try #require(try await store.entity(forSource: .calendar, sourceID: "evt-1"))
        #expect(entity.kind == .event)
        #expect(entity.title == "Beta review")
        #expect(entity.startsAt == now.addingTimeInterval(3_600))

        // Dates arrive as statements, so the user can see where each one came from.
        let assertions = try await store.assertions(about: entity.id, includeIncoming: false)
        let start = try #require(assertions.first { $0.predicate == .starts })
        #expect(start.type == .observed)
        #expect(start.authority == .observation)
        #expect(start.provenance.sourceType == .calendar)
        #expect(start.provenance.sourceID == "evt-1")
        #expect(start.explanation(now: now) == "I found it in your calendar today.")
        #expect(assertions.contains { $0.predicate == .location && $0.value?.textValue == "Room 3" })
    }

    @Test func whatTheUserSaidOutranksWhatTheCalendarSays() async throws {
        let store = try IntelligenceStore()
        try await store.ingest([event("evt-1", "Beta review")], source: .calendar, now: now)
        let entity = try #require(try await store.entity(forSource: .calendar, sourceID: "evt-1"))

        // They say it moved. Their word wins, and the calendar's version is kept as what it was.
        let moved = now.addingTimeInterval(4 * 3_600)
        try await store.record(subject: entity.id, .starts, value: .date(moved, phrase: "four o'clock"),
                               provenance: Provenance(sourceType: .conversation), at: now.addingTimeInterval(60))
        #expect(try await store.entity(entity.id)?.startsAt == moved)

        // A later sync of the unchanged calendar entry does not quietly put it back.
        try await store.ingest([event("evt-1", "Beta review")], source: .calendar,
                               now: now.addingTimeInterval(120))
        let current = try #require(try await store.entity(entity.id))
        #expect(current.startsAt == moved)
        let winning = try await store.activeAssertions(subjectID: entity.id, predicate: .starts).first
        #expect(winning?.provenance.sourceType == .conversation)
    }

    @Test func syncingTwiceChangesNothingTheSecondTime() async throws {
        let store = try IntelligenceStore()
        let items = [event("evt-1", "Beta review"), event("evt-2", "Standup", at: 7_200)]
        let first = try await store.ingest(items, source: .calendar, prune: true, now: now)
        let second = try await store.ingest(items, source: .calendar, prune: true,
                                            now: now.addingTimeInterval(300))

        #expect(first.created == 2)
        #expect(second.created == 0)
        #expect(second.updated == 0)
        #expect(second.unchanged == 2)
        #expect(try await store.entities(kind: .event).count == 2)
    }

    @Test func aChangedEventUpdatesTheOneThatIsAlreadyThere() async throws {
        let store = try IntelligenceStore()
        try await store.ingest([event("evt-1", "Beta review")], source: .calendar, now: now)
        let original = try #require(try await store.entity(forSource: .calendar, sourceID: "evt-1"))

        var moved = event("evt-1", "Beta review", at: 5 * 3_600)
        moved.location = "Room 9"
        let report = try await store.ingest([moved], source: .calendar, now: now.addingTimeInterval(60))

        #expect(report.updated == 1)
        #expect(report.created == 0)
        let entity = try #require(try await store.entity(forSource: .calendar, sourceID: "evt-1"))
        #expect(entity.id == original.id)
        #expect(entity.startsAt == now.addingTimeInterval(5 * 3_600))
        #expect(try await store.entities(kind: .event).count == 1)
    }

    @Test func aDeletedEventStopsHauntingTheWeek() async throws {
        let store = try IntelligenceStore()
        try await store.ingest([event("evt-1", "Beta review"), event("evt-2", "Standup", at: 7_200)],
                               source: .calendar, prune: true, now: now)
        let report = try await store.ingest([event("evt-1", "Beta review")],
                                            source: .calendar, prune: true, now: now.addingTimeInterval(60))

        #expect(report.removed == 1)
        #expect(try await store.entity(forSource: .calendar, sourceID: "evt-2") == nil)
        #expect(try await store.entity(forSource: .calendar, sourceID: "evt-1") != nil)
    }

    @Test func anEventTheUserHasTalkedAboutSurvivesBeingDeletedFromTheCalendar() async throws {
        let store = try IntelligenceStore()
        try await store.ingest([event("evt-1", "Beta review")], source: .calendar, prune: true, now: now)
        let entity = try #require(try await store.entity(forSource: .calendar, sourceID: "evt-1"))
        // The user attached something of their own to it.
        let project = try await store.create(kind: .project, title: "Beta launch")
        try await store.record(subject: entity.id, .belongsTo, object: project.id,
                               provenance: Provenance(sourceType: .conversation), at: now)

        let report = try await store.ingest([], source: .calendar, prune: true, now: now.addingTimeInterval(60))
        #expect(report.removed == 0)
        #expect(try await store.entity(entity.id) != nil)
    }

    @Test func anEventWithSomeoneOnItStopsHauntingTheWeekToo() async throws {
        let store = try IntelligenceStore()
        let sarah = try await store.create(kind: .person, title: "Sarah")
        try await store.ingest([event("evt-1", "Coffee with Sarah", mentions: ["Sarah"])],
                               source: .calendar, prune: true, now: now)
        let entity = try #require(try await store.entity(forSource: .calendar, sourceID: "evt-1"))

        let report = try await store.ingest([], source: .calendar, prune: true, now: now.addingTimeInterval(60))

        // The attendee link is this source's statement too, so it goes with it — otherwise it would
        // count as a reference and the event could never be let go of.
        #expect(report.removed == 1)
        #expect(try await store.entity(entity.id) == nil)
        #expect(try await store.activeAssertions(subjectID: sarah.id, predicate: .attends).isEmpty)
    }

    @Test func ingestionLinksToPeopleItAlreadyKnowsAndInventsNone() async throws {
        let store = try IntelligenceStore()
        let sarah = try await store.create(kind: .person, title: "Sarah")

        try await store.ingest(
            [event("evt-1", "Coffee with Sarah and Bartholomew", mentions: ["Sarah", "Bartholomew"])],
            source: .calendar, now: now
        )

        // Sarah exists, so the event is attached to her.
        let attends = try await store.activeAssertions(subjectID: sarah.id, predicate: .attends)
        #expect(attends.count == 1)
        #expect(attends.first?.authority == .observation)
        // Bartholomew does not, and a name on an invite is not evidence the user knows him.
        #expect(try await store.resolve(title: "Bartholomew") == nil)
        #expect(try await store.entities(kind: .person).count == 2)  // the user and Sarah
    }

    @Test func nothingIngestedCanPutTheUserOnTheHook() async throws {
        let store = try IntelligenceStore()
        // Even if a source claims something is a promise, it is not the user's voice.
        let claimed = IngestedItem(
            sourceType: .calendar, sourceID: "evt-1", kind: .commitment,
            title: "You agreed to pay the invoice", dueAt: now
        )
        let report = try await store.ingest([claimed], source: .calendar, now: now)
        #expect(report.created == 0)
        #expect(try await store.entities(kind: .commitment).isEmpty)
    }

    @Test func remindersArriveAsWorkWithTheirState() async throws {
        let store = try IntelligenceStore()
        try await store.ingest(
            [reminder("rem-1", "Send the deck", due: 86_400), reminder("rem-2", "Book the room", due: nil, done: true)],
            source: .reminders, now: now
        )

        let open = try #require(try await store.entity(forSource: .reminders, sourceID: "rem-1"))
        #expect(open.kind == .task)
        #expect(open.status == .open)
        #expect(open.dueAt == now.addingTimeInterval(86_400))
        let done = try #require(try await store.entity(forSource: .reminders, sourceID: "rem-2"))
        #expect(done.status == .done)
        // A finished reminder does not nag.
        #expect(!done.status.isOutstanding)
    }

    @Test func switchingASourceOffTakesBackWhatItBrought() async throws {
        let store = try IntelligenceStore()
        try await store.ingest([event("evt-1", "Beta review"), event("evt-2", "Standup", at: 7_200)],
                               source: .calendar, now: now)
        try await store.ingest([reminder("rem-1", "Send the deck", due: 86_400)], source: .reminders, now: now)

        let removed = try await store.forgetEverything(from: .calendar)
        #expect(removed == 2)
        #expect(try await store.entities(kind: .event).isEmpty)
        // Only that source: the reminders are untouched.
        #expect(try await store.entity(forSource: .reminders, sourceID: "rem-1") != nil)
    }

    @Test func whatTheCalendarBringsInFeedsWhatNeedsYou() async throws {
        let store = try IntelligenceStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        try await store.ingest([event("evt-1", "Beta review", at: 3_600)], source: .calendar, now: now)

        let items = try await AttentionEngine(store: store, calendar: calendar).items(now: now)
        #expect(items.contains { $0.title == "Beta review" })
    }

    @Test func somethingTheUserAlreadyHasIsRecognisedRatherThanDuplicated() async throws {
        let store = try IntelligenceStore()
        // The assistant put this in their reminders itself, so it is already here.
        let mine = try await store.create(kind: .task, title: "Send the deck")
        try await store.record(subject: mine.id, .deadline, value: .date(now, phrase: "today"),
                               provenance: Provenance(sourceType: .conversation), at: now)

        let report = try await store.ingest([reminder("rem-1", "Send the deck", due: 86_400)],
                                            source: .reminders, now: now)

        #expect(report.adopted == 1)
        #expect(report.created == 0)
        #expect(try await store.entities(kind: .task).count == 1)
        #expect(try await store.entity(forSource: .reminders, sourceID: "rem-1")?.id == mine.id)
        // And it is still the user's own deadline that stands.
        #expect(try await store.entity(mine.id)?.dueAt == now)
    }

    @Test func whatWasAlreadyYoursSurvivesSwitchingTheSourceOff() async throws {
        let store = try IntelligenceStore()
        let mine = try await store.create(kind: .task, title: "Send the deck")
        try await store.ingest([reminder("rem-1", "Send the deck", due: 86_400)], source: .reminders, now: now)
        try await store.ingest([reminder("rem-2", "Book the room", due: nil)], source: .reminders, now: now)

        let removed = try await store.forgetEverything(from: .reminders)

        // Only the one it created is gone; the one it recognised stays, minus what it said about it.
        #expect(removed == 1)
        #expect(try await store.entity(mine.id) != nil)
        #expect(try await store.resolve(title: "Book the room") == nil)
        let left = try await store.assertions(about: mine.id, includeIncoming: false)
        #expect(!left.contains { $0.provenance.sourceType == .reminders })
    }

    @Test func aNameThatMerelyStartsTheSameIsNotTheSameThing() async throws {
        let store = try IntelligenceStore()
        let longer = try await store.create(kind: .task, title: "Send the deck to Sarah")

        try await store.ingest([reminder("rem-1", "Send the deck", due: 86_400)], source: .reminders, now: now)

        // "Send the deck" is its own reminder, not a second name for the user's task.
        let ingested = try #require(try await store.entity(forSource: .reminders, sourceID: "rem-1"))
        #expect(ingested.id != longer.id)
        #expect(try await store.entities(kind: .task).count == 2)
    }

    @Test func aSyncNeverResurrectsSomethingTheUserPutAway() async throws {
        let store = try IntelligenceStore()
        let forgotten = try await store.create(kind: .task, title: "Send the deck")
        try await store.archive(forgotten.id, at: now)

        try await store.ingest([reminder("rem-1", "Send the deck", due: 86_400)], source: .reminders, now: now)

        let ingested = try #require(try await store.entity(forSource: .reminders, sourceID: "rem-1"))
        #expect(ingested.id != forgotten.id)
        #expect(try await store.entity(forgotten.id)?.archivedAt != nil)
    }

    @Test func twoDifferentEventsWithTheSameNameStayTwoThings() async throws {
        let store = try IntelligenceStore()
        try await store.ingest([event("evt-1", "Standup")], source: .calendar, now: now)
        try await store.ingest([event("evt-2", "Standup", at: 90_000)], source: .calendar,
                               now: now.addingTimeInterval(60))

        // The first one is already spoken for, so tomorrow's standup is its own event.
        #expect(try await store.entities(kind: .event).count == 2)
        let first = try #require(try await store.entity(forSource: .calendar, sourceID: "evt-1"))
        let second = try #require(try await store.entity(forSource: .calendar, sourceID: "evt-2"))
        #expect(first.id != second.id)
    }

    @Test func aDigestChangesOnlyWhenSomethingMeaningfulDoes() {
        let base = event("evt-1", "Beta review", location: "Room 3", mentions: ["Sarah"])
        #expect(base.digest == event("evt-1", "Beta review", location: "Room 3", mentions: ["Sarah"]).digest)
        #expect(base.digest != event("evt-1", "Beta review", location: "Room 9", mentions: ["Sarah"]).digest)
        #expect(base.digest != event("evt-1", "Beta review", at: 7_200, location: "Room 3", mentions: ["Sarah"]).digest)
        // The order names arrive in is not a change.
        var reordered = base
        reordered.mentions = ["Sarah"]
        #expect(base.digest == reordered.digest)
    }
}
