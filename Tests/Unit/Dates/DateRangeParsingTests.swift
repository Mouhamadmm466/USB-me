import Foundation
import Testing
import Tools

@Suite("parseRange")
struct DateRangeParsingTests {
    @Test(arguments: RangeCase.all)
    func parses(_ testCase: RangeCase) throws {
        let range = try #require(testCase.now.parser.parseRange(testCase.phrase))
        #expect(testCase.now.local(range.start) == LocalTime.expand(testCase.start))
        #expect(testCase.now.local(range.end) == LocalTime.expand(testCase.end))
        #expect(range.spokenDescription == testCase.spoken)
    }

    /// A day named without a time parses to that day's midnight, which is where its range starts.
    @Test(arguments: DateTimeCase.all.filter { if case .day = $0.expected { true } else { false } })
    func dateOnlyPhrasesAgreeWithTheirRange(_ testCase: DateTimeCase) throws {
        let parser = testCase.now.parser
        let parsed = try #require(parser.parseDateTime(testCase.phrase))
        let range = try #require(parser.parseRange(testCase.phrase))
        #expect(range.start == parsed.date)
        #expect(range.end > range.start)
    }
}

extension RangeCase {
    static let all = saturday + monday + sundayNight + yearEnd

    /// Sat 2026-09-19 10:00, New York.
    static let saturday = Now.sep19.ranges([
        ("today", "2026-09-19", "2026-09-20", "today"),
        ("tomorrow", "2026-09-20", "2026-09-21", "tomorrow"),
        ("yesterday", "2026-09-18", "2026-09-19", "yesterday"),
        ("tonight", "2026-09-19T17:00", "2026-09-20", "tonight"),
        ("this morning", "2026-09-19T06:00", "2026-09-19T12:00", "this morning"),
        ("this afternoon", "2026-09-19T12:00", "2026-09-19T17:00", "this afternoon"),
        ("this evening", "2026-09-19T17:00", "2026-09-19T21:00", "this evening"),
        ("tomorrow morning", "2026-09-20T06:00", "2026-09-20T12:00", "tomorrow morning"),
        ("tomorrow afternoon", "2026-09-20T12:00", "2026-09-20T17:00", "tomorrow afternoon"),
        ("tomorrow evening", "2026-09-20T17:00", "2026-09-20T21:00", "tomorrow evening"),
        ("tomorrow night", "2026-09-20T17:00", "2026-09-21", "tomorrow night"),
        ("last night", "2026-09-18T17:00", "2026-09-19", "last night"),
        ("in the morning", "2026-09-19T06:00", "2026-09-19T12:00", "this morning"),
        ("at night", "2026-09-19T17:00", "2026-09-20", "tonight"),
        ("friday", "2026-09-25", "2026-09-26", "Friday, September 25"),
        ("on friday", "2026-09-25", "2026-09-26", "Friday, September 25"),
        ("next friday", "2026-09-25", "2026-09-26", "Friday, September 25"),
        ("friday next week", "2026-09-25", "2026-09-26", "Friday, September 25"),
        ("monday", "2026-09-21", "2026-09-22", "Monday, September 21"),
        ("september 25", "2026-09-25", "2026-09-26", "Friday, September 25"),
        ("the 25th", "2026-09-25", "2026-09-26", "Friday, September 25"),
        ("9/25", "2026-09-25", "2026-09-26", "Friday, September 25"),
        ("the 18th", "2026-10-18", "2026-10-19", "Sunday, October 18"),
        ("september 25 2027", "2027-09-25", "2027-09-26", "Saturday, September 25, 2027"),
        ("the 5th of next month", "2026-10-05", "2026-10-06", "Monday, October 5"),
        ("day after tomorrow", "2026-09-21", "2026-09-22", "Monday, September 21"),
        ("day before yesterday", "2026-09-17", "2026-09-18", "Thursday, September 17"),
        ("in 3 days", "2026-09-22", "2026-09-23", "Tuesday, September 22"),
        ("in a week", "2026-09-26", "2026-09-27", "Saturday, September 26"),
        ("this past friday", "2026-09-18", "2026-09-19", "Friday, September 18"),
        ("last friday", "2026-09-11", "2026-09-12", "Friday, September 11"),
        ("friday morning", "2026-09-25T06:00", "2026-09-25T12:00", "Friday morning, September 25"),
        ("friday night", "2026-09-25T17:00", "2026-09-26", "Friday night, September 25"),
        ("saturday afternoon", "2026-09-26T12:00", "2026-09-26T17:00", "Saturday afternoon, September 26"),
        ("this week", "2026-09-14", "2026-09-21", "this week"),
        ("next week", "2026-09-21", "2026-09-28", "next week"),
        ("last week", "2026-09-07", "2026-09-14", "last week"),
        ("this weekend", "2026-09-19", "2026-09-21", "this weekend"),
        ("the weekend", "2026-09-19", "2026-09-21", "this weekend"),
        ("over the weekend", "2026-09-19", "2026-09-21", "this weekend"),
        ("weekend", "2026-09-19", "2026-09-21", "this weekend"),
        ("next weekend", "2026-09-26", "2026-09-28", "next weekend"),
        ("last weekend", "2026-09-12", "2026-09-14", "last weekend"),
        ("this month", "2026-09-01", "2026-10-01", "this month"),
        ("next month", "2026-10-01", "2026-11-01", "next month"),
        ("last month", "2026-08-01", "2026-09-01", "last month"),
        ("september", "2026-09-01", "2026-10-01", "September"),
        ("october", "2026-10-01", "2026-11-01", "October"),
        ("in october", "2026-10-01", "2026-11-01", "October"),
        ("august", "2027-08-01", "2027-09-01", "August 2027"),
        ("january 2027", "2027-01-01", "2027-02-01", "January 2027"),
        ("the next 3 days", "2026-09-19", "2026-09-22", "the next 3 days"),
        ("next 7 days", "2026-09-19", "2026-09-26", "the next 7 days"),
        ("the next two weeks", "2026-09-19", "2026-10-03", "the next 2 weeks"),
        ("the next couple of days", "2026-09-19", "2026-09-21", "the next 2 days"),
        // A phrase naming a moment covers the whole day containing it.
        ("tomorrow at 3pm", "2026-09-20", "2026-09-21", "tomorrow"),
        ("3pm", "2026-09-19", "2026-09-20", "today"),
        ("tonight at 1am", "2026-09-20", "2026-09-21", "tomorrow"),
        ("friday at noon", "2026-09-25", "2026-09-26", "Friday, September 25"),
    ])

    /// Mon 2026-09-21 18:30, New York.
    static let monday = Now.sep21.ranges([
        ("this week", "2026-09-21", "2026-09-28", "this week"),
        ("next week", "2026-09-28", "2026-10-05", "next week"),
        ("this weekend", "2026-09-26", "2026-09-28", "this weekend"),
        ("next weekend", "2026-10-03", "2026-10-05", "next weekend"),
        ("next friday", "2026-10-02", "2026-10-03", "Friday, October 2"),
        ("this afternoon", "2026-09-21T12:00", "2026-09-21T17:00", "this afternoon"),
        ("in the evening", "2026-09-21T17:00", "2026-09-21T21:00", "this evening"),
        ("in the morning", "2026-09-22T06:00", "2026-09-22T12:00", "tomorrow morning"),
    ])

    /// Sun 2026-09-20 21:00, New York: "this weekend" is the one ending tonight.
    static let sundayNight = Now.sep20.ranges([
        ("this weekend", "2026-09-19", "2026-09-21", "this weekend"),
        ("next weekend", "2026-09-26", "2026-09-28", "next weekend"),
        ("this week", "2026-09-14", "2026-09-21", "this week"),
        ("next week", "2026-09-21", "2026-09-28", "next week"),
        ("tonight", "2026-09-20T17:00", "2026-09-21", "tonight"),
        ("in the evening", "2026-09-21T17:00", "2026-09-21T21:00", "tomorrow evening"),
    ])

    /// Sun 2026-12-27 23:10, New York: ranges crossing into 2027.
    static let yearEnd = Now.dec27.ranges([
        ("tomorrow", "2026-12-28", "2026-12-29", "tomorrow"),
        ("tonight", "2026-12-27T17:00", "2026-12-28", "tonight"),
        ("this week", "2026-12-21", "2026-12-28", "this week"),
        ("next week", "2026-12-28", "2027-01-04", "next week"),
        ("this weekend", "2026-12-26", "2026-12-28", "this weekend"),
        ("next weekend", "2027-01-02", "2027-01-04", "next weekend"),
        ("this month", "2026-12-01", "2027-01-01", "this month"),
        ("next month", "2027-01-01", "2027-02-01", "next month"),
        ("december", "2026-12-01", "2027-01-01", "December"),
        ("january", "2027-01-01", "2027-02-01", "January 2027"),
        ("friday", "2027-01-01", "2027-01-02", "Friday, January 1, 2027"),
        ("the next 7 days", "2026-12-27", "2027-01-03", "the next 7 days"),
    ])
}
