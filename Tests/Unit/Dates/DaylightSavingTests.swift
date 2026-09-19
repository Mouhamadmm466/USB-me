import Foundation
import Testing
import Tools

/// Wall-clock results across DST changes, checked as absolute instants (with the UTC offset) and as
/// range lengths, so a fixed 86,400-second day or a wrong offset cannot pass.
@Suite("Daylight saving time")
struct DaylightSavingTests {
    struct InstantCase: Sendable, CustomTestStringConvertible {
        let now: Now
        let phrase: String
        /// "yyyy-MM-dd'T'HH:mm±hh:mm".
        let expected: String
        var testDescription: String { "\"\(phrase)\" @ \(now.label) → \(expected)" }
    }

    struct LengthCase: Sendable, CustomTestStringConvertible {
        let now: Now
        let phrase: String
        let hours: Double
        var testDescription: String { "\"\(phrase)\" @ \(now.label) lasts \(hours)h" }
    }

    static let instants: [InstantCase] = [
        // New York, spring forward on Sunday 2026-03-08 at 02:00.
        InstantCase(now: .mar7, phrase: "tomorrow", expected: "2026-03-08T00:00-05:00"),
        InstantCase(now: .mar7, phrase: "tomorrow at 1:59am", expected: "2026-03-08T01:59-05:00"),
        InstantCase(now: .mar7, phrase: "tomorrow at 2:30am", expected: "2026-03-08T03:30-04:00"),
        InstantCase(now: .mar7, phrase: "tomorrow at 9am", expected: "2026-03-08T09:00-04:00"),
        InstantCase(now: .mar7, phrase: "monday", expected: "2026-03-09T00:00-04:00"),
        InstantCase(now: .mar7, phrase: "in 24 hours", expected: "2026-03-08T13:00-04:00"),
        // New York, fall back on Sunday 2026-11-01 at 02:00: 01:30 happens twice; the first is used.
        InstantCase(now: .oct31, phrase: "tomorrow at 1:30am", expected: "2026-11-01T01:30-04:00"),
        InstantCase(now: .oct31, phrase: "tomorrow at 2am", expected: "2026-11-01T02:00-05:00"),
        InstantCase(now: .oct31, phrase: "tomorrow at 9am", expected: "2026-11-01T09:00-05:00"),
        InstantCase(now: .oct31, phrase: "in 2 days", expected: "2026-11-02T00:00-05:00"),
        InstantCase(now: .oct31, phrase: "in 24 hours", expected: "2026-11-01T11:00-05:00"),
        // London.
        InstantCase(now: .londonMar28, phrase: "tomorrow at 1:30am", expected: "2026-03-29T02:30+01:00"),
        InstantCase(now: .londonMar28, phrase: "tomorrow at 9am", expected: "2026-03-29T09:00+01:00"),
        InstantCase(now: .londonOct24, phrase: "tomorrow at 1:30am", expected: "2026-10-25T01:30+01:00"),
        InstantCase(now: .londonOct24, phrase: "tomorrow at 9am", expected: "2026-10-25T09:00+00:00"),
        // Tokyo has no DST; its local day starts at 15:00 UTC the previous day.
        InstantCase(now: .tokyoSep20, phrase: "tomorrow", expected: "2026-09-21T00:00+09:00"),
    ]

    static let lengths: [LengthCase] = [
        LengthCase(now: .mar7, phrase: "tomorrow", hours: 23),
        LengthCase(now: .mar7, phrase: "this weekend", hours: 47),
        LengthCase(now: .mar7, phrase: "this week", hours: 167),
        LengthCase(now: .mar7, phrase: "next week", hours: 168),
        LengthCase(now: .mar7, phrase: "tomorrow morning", hours: 6),
        LengthCase(now: .mar7, phrase: "this month", hours: 31 * 24 - 1),
        LengthCase(now: .oct31, phrase: "tomorrow", hours: 25),
        LengthCase(now: .oct31, phrase: "this weekend", hours: 49),
        LengthCase(now: .oct31, phrase: "next week", hours: 168),
        LengthCase(now: .londonMar28, phrase: "tomorrow", hours: 23),
        LengthCase(now: .londonOct24, phrase: "tomorrow", hours: 25),
        LengthCase(now: .tokyoSep20, phrase: "this week", hours: 168),
        LengthCase(now: .leapFeb28, phrase: "this month", hours: 29 * 24),
        LengthCase(now: .feb28, phrase: "this month", hours: 28 * 24),
    ]

    @Test(arguments: instants)
    func instant(_ testCase: InstantCase) throws {
        let parsed = try #require(testCase.now.parser.parseDateTime(testCase.phrase))
        #expect(testCase.now.localWithOffset(parsed.date) == testCase.expected)
    }

    @Test(arguments: lengths)
    func rangeLength(_ testCase: LengthCase) throws {
        let range = try #require(testCase.now.parser.parseRange(testCase.phrase))
        #expect(range.end.timeIntervalSince(range.start) == testCase.hours * 3600)
    }

    /// Relative hours are elapsed time: exactly 24 real hours later, whatever the wall clock says.
    @Test(arguments: [Now.mar7, .oct31, .londonMar28, .londonOct24])
    func relativeHoursAreElapsedTime(_ now: Now) throws {
        let parsed = try #require(now.parser.parseDateTime("in 24 hours"))
        #expect(parsed.date.timeIntervalSince(now.date) == 24 * 3600)
    }
}
