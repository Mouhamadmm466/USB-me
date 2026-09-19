import Foundation
import Testing
import Tools

/// The parser returns nil rather than guess.
@Suite("Rejections")
struct DateParsingRejectionTests {
    @Test(arguments: PhraseCase.unparseableDateTimes)
    func dateTimeIsNil(_ testCase: PhraseCase) {
        #expect(testCase.now.parser.parseDateTime(testCase.phrase) == nil)
    }

    @Test(arguments: PhraseCase.unparseableRanges)
    func rangeIsNil(_ testCase: PhraseCase) {
        #expect(testCase.now.parser.parseRange(testCase.phrase) == nil)
    }

    /// Past-only and multi-day phrases are valid ranges but not moments to act on.
    @Test(arguments: PhraseCase.rangesButNotMoments)
    func rangeOnly(_ testCase: PhraseCase) {
        #expect(testCase.now.parser.parseDateTime(testCase.phrase) == nil)
        #expect(testCase.now.parser.parseRange(testCase.phrase) != nil)
    }
}

extension PhraseCase {
    /// Nil for both `parseDateTime` and `parseRange`.
    static let unparseable = [
        // Vague.
        "someday", "later", "soon", "whenever", "after the meeting", "asap", "eventually", "in a while",
        "in a bit", "in a few minutes", "in a few days", "early tomorrow", "late tonight", "end of day",
        "first thing tomorrow", "tomorrow sometime soon", "noonish", "christmas", "next year",
        // Empty or structural words only.
        "", "   ", "at", "on", "the", "in", "next", "this", "last", "...",
        // Contradictions.
        "tomorrow yesterday", "today tomorrow", "friday saturday", "3pm 4pm", "tomorrow at 3pm and 4pm",
        "tomorrow at noon at 3", "thursday september 25", "tomorrow friday", "this morning at 3pm",
        "tonight at 9am", "tomorrow morning at 7pm", "in 20 minutes at 3pm", "tomorrow in 2 hours",
        "now tomorrow", "in 2 hours 3 hours", "morning evening", "this weekend friday",
        // Impossible values.
        "at 25", "at 13pm", "0am", "25:00", "3:75", "tomorrow at 25pm", "september 31", "feb 30",
        "february 29 2027", "2026-13-01", "2026-02-30", "13/13", "9/31", "the 32nd", "tomorrow at 0",
        "in 0 minutes", "in 10000 days", "in 99999999999 minutes",
        // Not supported, so not guessed: ranges of times, recurrences, zones, fractional days.
        "3 to 4pm", "10-11am", "3pm-4pm", "between 3 and 5", "every friday", "fridays", "3pm est",
        "the week after next", "the next friday", "in 1.5 days", "in half a day", "in 1 day 3 hours",
        "12 in the morning", "3 in the evening", "9-25", "25.09.2026", "1.2.3", "3:30:15", "in -5 minutes",
        // Bare numbers that are neither a clock time nor a date.
        "25", "0", "2027", "1530",
    ]

    static let unparseableDateTimes = Now.sep19.phrases(unparseable + rangesOnly)
        + Now.dec27.phrases(["feb 29 2027", "september 31", "tomorrow yesterday", "later"])
        + Now.feb28.phrases(["feb 29 2027", "february 30", "2/30"])

    static let unparseableRanges = Now.sep19.phrases(unparseable + ["in 20 minutes", "now", "right now", "an hour from now"])

    /// Past-only days and multi-day stretches.
    static let rangesOnly = [
        "yesterday", "yesterday at 3pm", "last night", "day before yesterday", "last friday",
        "this past friday", "the 5th of last month", "next week", "this week", "last week", "this weekend",
        "the weekend", "next weekend", "this month", "next month", "september", "in october", "may 2027",
        "the next 3 days",
    ]

    static let rangesButNotMoments = Now.sep19.phrases(rangesOnly)
}
