import Core
import Foundation
import Testing
import Tools

@Suite("Parser properties")
struct DateParsingPropertyTests {
    /// Case, surrounding punctuation and whitespace never change a reading (ASR and model output vary).
    @Test(arguments: DateTimeCase.all)
    func normalizationDoesNotChangeTheReading(_ testCase: DateTimeCase) {
        let parser = testCase.now.parser
        let reference = parser.parseDateTime(testCase.phrase)
        for variant in [testCase.phrase.uppercased(), "\"\(testCase.phrase)\"", "  \(testCase.phrase)?  ", "\(testCase.phrase)."] {
            #expect(parser.parseDateTime(variant) == reference, "\(variant)")
        }
    }

    /// Leading "on"/"at"/"by"/"for" are ignored.
    @Test(arguments: ["friday", "tomorrow", "the 25th", "september 25", "next friday", "3pm", "noon", "tomorrow at 3pm"])
    func leadingPrepositionsAreIgnored(_ phrase: String) throws {
        let parser = Now.sep19.parser
        let reference = try #require(parser.parseDateTime(phrase))
        for preposition in ["on", "at", "by", "for"] {
            #expect(parser.parseDateTime("\(preposition) \(phrase)") == reference, "\(preposition) \(phrase)")
        }
    }

    @Test func separateParsersAgree() {
        for testCase in DateTimeCase.all.prefix(80) {
            #expect(testCase.now.parser.parseDateTime(testCase.phrase) == testCase.now.parser.parseDateTime(testCase.phrase))
        }
    }

    /// The parser is a Sendable value; concurrent use gives the same answers as sequential use.
    @Test func parsesConcurrently() async {
        let parser = Now.sep19.parser
        let phrases = DateTimeCase.saturday.map(\.phrase)
        let expected = phrases.map { parser.parseDateTime($0) }
        await withTaskGroup(of: (Int, ParsedDateTime?).self) { group in
            for (index, phrase) in phrases.enumerated() {
                group.addTask { (index, parser.parseDateTime(phrase)) }
            }
            for await (index, parsed) in group {
                #expect(parsed == expected[index], "\(phrases[index])")
            }
        }
    }

    /// Only the injected clock matters: a clock whose calendar is not Gregorian (and has a different
    /// first weekday) reads phrases exactly like the Gregorian fixture in the same zone.
    @Test func usesOnlyTheInjectedTimeZone() {
        let now = Now.sep19
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = now.timeZone
        buddhist.firstWeekday = 1
        let foreign = DateExpressionParser(clock: AgentClock(now: { now.date }, calendar: buddhist))
        for testCase in DateTimeCase.saturday {
            #expect(foreign.parseDateTime(testCase.phrase) == now.parser.parseDateTime(testCase.phrase), "\(testCase.phrase)")
        }
        for testCase in RangeCase.saturday {
            #expect(foreign.parseRange(testCase.phrase) == now.parser.parseRange(testCase.phrase), "\(testCase.phrase)")
        }
    }

    /// Random word salad from the parser's own vocabulary never crashes and never breaks the
    /// result invariants, in zones with unusual offsets and DST rules.
    @Test func randomPhrasesKeepInvariants() {
        var random = SeededGenerator(seed: 0x5EED_D47E)
        let words = [
            "at", "on", "in", "the", "next", "this", "last", "past", "coming", "a", "an", "of", "and", "to", "half",
            "quarter", "tomorrow", "today", "tonight", "yesterday", "now", "day", "after", "week", "weekend", "month",
            "days", "hours", "minutes", "h", "am", "pm", "p.m.", "noon", "midnight", "morning", "evening", "night",
            "o'clock", "friday", "mon", "sept", "may", "first", "twenty", "fifth", "one", "twelve", "oh", "couple",
            "few", "3", "12", "0", "07", "25", "31", "1530", "2027", "930", "1.5", "3.30", "9/25", "25/9", "3:30",
            "15:00", "99:99", "25th", "-", "/", ",", "'s", "&", "@", "123456789", "from", "sharp", "till", "every",
        ]
        let zones = ["America/New_York", "Europe/London", "Asia/Tokyo", "Australia/Lord_Howe", "America/Santiago", "Asia/Kathmandu"]
        for _ in 0..<3_000 {
            let zone = TimeZone(identifier: zones.randomElement(using: &random)!)!
            let now = Date(timeIntervalSince1970: 1_750_000_000 + Double(random.next() % 150_000_000))
            let parser = DateExpressionParser(clock: .fixed(now, timeZone: zone))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let phrase = (0..<Int.random(in: 1...6, using: &random))
                .map { _ in words.randomElement(using: &random)! }
                .joined(separator: Bool.random(using: &random) ? " " : "")
            if let parsed = parser.parseDateTime(phrase) {
                #expect(parsed.hasTime || calendar.startOfDay(for: parsed.date) == parsed.date, "\(phrase)")
                #expect(parsed.hasTime || !parsed.meridiemInferred, "\(phrase)")
                #expect(parser.parseDateTime(phrase) == parsed, "\(phrase)")
            }
            if let range = parser.parseRange(phrase) {
                #expect(range.start < range.end, "\(phrase)")
                #expect(!range.spokenDescription.isEmpty, "\(phrase)")
            }
            if let minutes = parser.parseDurationMinutes(phrase) {
                #expect((1...1_440).contains(minutes), "\(phrase)")
            }
        }
    }

    /// The parser must read time only through the injected clock (see Core `AgentClock`), and must
    /// do day arithmetic with the calendar, never with fixed 86,400-second days.
    @Test func sourcesNeverReadTheSystemClock() throws {
        let folder = try #require(Self.parserSourceFolder())
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
            $0 == "DateExpressionParser.swift" || ($0.hasPrefix("DateParsing") && $0 != "DateParsing.swift")
        }
        #expect(files.count >= 2)
        for file in files {
            let source = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            for forbidden in ["Date()", "Calendar.current", "autoupdatingCurrent", "TimeZone.current", "Locale.current", "86400", "86_400"] {
                #expect(!source.contains(forbidden), "\(file) uses \(forbidden)")
            }
        }
    }

    /// `Tools/Calendar`, found by walking up from this file.
    private static func parserSourceFolder() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("Tools/Calendar")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("DateExpressionParser.swift").path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}

/// Deterministic pseudo-random numbers (64-bit LCG) so the fuzz test is reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 29)
    }
}
