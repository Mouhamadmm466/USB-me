import Core
import Foundation
import Intelligence
import Tools

/// Lets the personal intelligence resolve date phrases with the very same parser the tools use.
///
/// One parser for both means "next Friday" in a memory and "next Friday" in a calendar event can
/// never land on different days — and the intelligence module stays free of the tool layer, since
/// it only knows the `DatePhraseResolving` protocol.
public struct IntelligenceDateResolver: DatePhraseResolving {
    private let factory: DateParserFactory
    private let calendar: Calendar

    public init(factory: @escaping DateParserFactory = DateParsers.standard, calendar: Calendar = .autoupdatingCurrent) {
        self.factory = factory
        self.calendar = calendar
    }

    public func resolve(_ phrase: String, now: Date) -> Date? {
        // The parser is anchored to the instant the phrase was said, so "tomorrow" in a memory
        // written last week still means the day after that one.
        factory(AgentClock(now: { now }, calendar: calendar)).parseDateTime(phrase)?.date
    }
}
