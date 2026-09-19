import Core
import Foundation
import Testing
@testable import Agent

@Suite struct ActionSummarizerTests {
    let clock = AgentClock.fixed(ISO8601DateFormatter().date(from: "2026-09-19T14:00:00Z")!, timeZone: TimeZone(identifier: "America/New_York")!)

    private func day(_ offset: Int, hour: Int = 0) -> Date {
        let start = clock.calendar.startOfDay(for: clock.now())
        return clock.calendar.date(byAdding: .hour, value: offset * 24 + hour, to: start)!
    }

    @Test func movingAnAllDayEventToAClockTimeReadsBackTheTime() {
        let offsite = EventReference(eventIdentifier: "e1", title: "Offsite", startDate: day(3), endDate: day(4), isAllDay: true)
        let summarizer = ActionSummarizer(clock: clock)
        let prompt = summarizer.confirmationPrompt(for: .updateCalendarEvent(offsite, EventChanges(newStartDate: day(3, hour: 15), newEndDate: day(3, hour: 16))))
        #expect(prompt.contains("3 PM") || prompt.contains("3:00 PM"), "\(prompt)")
    }

    @Test func movingAnAllDayEventToAnotherDayStaysAllDay() {
        let offsite = EventReference(eventIdentifier: "e1", title: "Offsite", startDate: day(3), endDate: day(4), isAllDay: true)
        let summarizer = ActionSummarizer(clock: clock)
        let prompt = summarizer.confirmationPrompt(for: .updateCalendarEvent(offsite, EventChanges(newStartDate: day(5), newEndDate: day(6))))
        #expect(!prompt.contains("AM") && !prompt.contains("PM"), "\(prompt)")
    }
}
