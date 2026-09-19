import Foundation
import Testing
import Tools

struct DurationCase: Sendable, CustomTestStringConvertible {
    let phrase: String
    let minutes: Int?

    var testDescription: String { "\"\(phrase)\" → \(minutes.map(String.init) ?? "nil")" }
}

@Suite("parseDurationMinutes")
struct DurationParsingTests {
    @Test(arguments: DurationCase.all)
    func parses(_ testCase: DurationCase) {
        #expect(Now.sep19.parser.parseDurationMinutes(testCase.phrase) == testCase.minutes)
    }

    /// Durations do not depend on the clock.
    @Test(arguments: [Now.sep19, .mar7, .tokyoSep20, .leapFeb28])
    func isIndependentOfNow(_ now: Now) {
        for testCase in DurationCase.all {
            #expect(now.parser.parseDurationMinutes(testCase.phrase) == testCase.minutes, "\(testCase.phrase)")
        }
    }
}

extension DurationCase {
    static let all: [DurationCase] = table.map { DurationCase(phrase: $0.key, minutes: $0.value) }

    private static let table: KeyValuePairs<String, Int?> = [
        // Minutes and hours, digits or words.
        "30 minutes": 30,
        "30 min": 30,
        "45 mins": 45,
        "5 minutes": 5,
        "1 minute": 1,
        "a minute": 1,
        "90 minutes": 90,
        "90min": 90,
        "90 m": 90,
        "twenty minutes": 20,
        "forty-five minutes": 45,
        "ninety minutes": 90,
        "45 MINUTES": 45,
        "an hour": 60,
        "1 hour": 60,
        "1 hr": 60,
        "1h": 60,
        "2 hours": 120,
        "2 hrs": 120,
        "two hours": 120,
        "a couple of hours": 120,
        "24 hours": 1440,
        "a day": 1440,
        // Fractions and compounds.
        "1.5 hours": 90,
        "1.25 hours": 75,
        "1.33 hours": 80,
        "an hour and a half": 90,
        "an hour and a quarter": 75,
        "one and a half hours": 90,
        "two and a half hours": 150,
        "half an hour": 30,
        "a half hour": 30,
        "half hour": 30,
        "half a day": 720,
        "a quarter of an hour": 15,
        "quarter of an hour": 15,
        "quarter hour": 15,
        "three quarters of an hour": 45,
        "1 hour 30 minutes": 90,
        "1 hour and 15 minutes": 75,
        "an hour and 15 minutes": 75,
        "1h30": 90,
        "2 hours 15": 135,
        "1:30": 90,
        "0:45": 45,
        "2.5 minutes": 3,
        // Bare numbers are minutes; leading "for"/"about" are ignored.
        "30": 30,
        "90": 90,
        "thirty": 30,
        "forty five": 45,
        "for 45 minutes": 45,
        "about an hour": 60,
        // Rejected: zero, over 24 hours, vague, not a duration, or readable as a clock time.
        "0": nil,
        "0 minutes": nil,
        "0.4 minutes": nil,
        "25 hours": nil,
        "1441 minutes": nil,
        "2 days": nil,
        "a week": nil,
        "a month": nil,
        "": nil,
        "a while": nil,
        "a few minutes": nil,
        "an hour or two": nil,
        "all day": nil,
        "forever": nil,
        "soon": nil,
        "30 seconds": nil,
        "minutes": nil,
        "1.5": nil,
        "-30": nil,
        "30 minutes 1 hour": nil,
        "1:75": nil,
        "tomorrow": nil,
        "3pm": nil,
        "15:00": nil,
        "930": nil,
        "120": nil,
    ]
}
