import Core
import Foundation

/// A `DateParsing` that answers from fixed tables, keyed by the folded, whitespace-collapsed
/// phrase. Unknown phrases return nil. For tests that must not depend on the real parser.
public struct ScriptedDateParser: DateParsing {
    private let dateTimes: [String: ParsedDateTime]
    private let ranges: [String: DateRange]
    private let durations: [String: Int]

    public init(
        dateTimes: [String: ParsedDateTime] = [:],
        ranges: [String: DateRange] = [:],
        durations: [String: Int] = [:]
    ) {
        self.dateTimes = Dictionary(dateTimes.map { (Self.key($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.ranges = Dictionary(ranges.map { (Self.key($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.durations = Dictionary(durations.map { (Self.key($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    static func key(_ phrase: String) -> String {
        TextTokens.fold(phrase).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public func parseDateTime(_ phrase: String) -> ParsedDateTime? { dateTimes[Self.key(phrase)] }
    public func parseRange(_ phrase: String) -> DateRange? { ranges[Self.key(phrase)] }
    public func parseDurationMinutes(_ phrase: String) -> Int? { durations[Self.key(phrase)] }

    /// A factory that ignores the clock (the tables already hold absolute dates).
    public var factory: DateParserFactory {
        let parser = self
        return { _ in parser }
    }
}
