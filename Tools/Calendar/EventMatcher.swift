import Core
import Foundation

/// Finds the event a spoken `event_query` refers to by title-word overlap.
public enum EventMatcher {
    /// Words that never identify an event.
    static let stopwords: Set<String> = [
        "the", "a", "an", "my", "our", "your", "his", "her", "their", "with", "on", "at", "in", "for", "to",
        "of", "and", "from", "about", "calendar", "please", "that", "this", "it", "one",
    ]
    /// Words that describe the kind of event; they only count when nothing more specific was said.
    static let genericWords: Set<String> = [
        "meeting", "appointment", "appt", "event", "call", "session", "thing",
    ]

    /// Full queries that refer to the event just discussed.
    static let pronouns: Set<String> = [
        "it", "that", "this", "that one", "this one", "same one", "the same one", "same event",
        "the same event", "that event", "this event", "the event",
    ]
    /// Deictic phrases with a kind noun: the last event when there is one, otherwise a title search.
    static let deictics: Set<String> = [
        "that meeting", "this meeting", "the meeting", "my meeting", "that appointment", "this appointment",
        "the appointment", "my appointment", "that call", "this call", "the call",
    ]

    public enum Reference: Sendable, Equatable {
        case pronoun
        case deictic
        case search
    }

    public static func classify(_ query: String) -> Reference {
        let phrase = TextTokens.phrase(query)
        if pronouns.contains(phrase) { return .pronoun }
        if deictics.contains(phrase) { return .deictic }
        return .search
    }

    struct QueryTerms {
        let strong: [String]
        let generic: [String]
    }

    static func terms(of query: String) -> QueryTerms {
        let words = TextTokens.words(query).map(TextTokens.stem)
        let strong = words.filter { !stopwords.contains($0) && !genericWords.contains($0) }
        let generic = words.filter { genericWords.contains($0) }
        return QueryTerms(strong: deduplicated(strong), generic: deduplicated(generic))
    }

    private static func deduplicated(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }
    }

    /// Title tokens that `word` matches: exact/stem (2 points) or a close spelling (1 point).
    private static func score(_ word: String, in titleWords: [String]) -> Int {
        if titleWords.contains(word) { return 2 }
        guard word.count >= 5 else { return 0 }
        for titleWord in titleWords where titleWord.first == word.first && titleWord.count >= 5 {
            let limit = max(word.count, titleWord.count) >= 8 ? 2 : 1
            if EditDistance.damerauLevenshtein(word, titleWord) <= limit { return 1 }
        }
        return 0
    }

    public struct Scored: Sendable, Equatable {
        public let event: EventReference
        public let score: Int
        /// Query words that matched this event's title.
        public let matchedWords: Set<String>
    }

    /// Events matching the query, best first (ties keep upcoming events first, then by start).
    public static func rank(query: String, events: [EventReference], now: Date) -> [Scored] {
        let terms = terms(of: query)
        let useGeneric = terms.strong.isEmpty
        let words = useGeneric ? terms.generic : terms.strong
        guard !words.isEmpty else { return [] }

        let scored: [Scored] = events.compactMap { event in
            let titleWords = TextTokens.words(event.title).map(TextTokens.stem)
            var total = 0
            var matched = Set<String>()
            for word in words {
                let points = score(word, in: titleWords)
                if points > 0 {
                    total += points * 2
                    matched.insert(word)
                }
            }
            guard total > 0 else { return nil }
            if !useGeneric {
                // Kind words ("meeting") only break ties between events that share the specific words.
                total += terms.generic.filter { score($0, in: titleWords) > 0 }.count
            }
            return Scored(event: event, score: total, matchedWords: matched)
        }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return chronologicallyBefore(lhs.event, rhs.event, now: now)
        }
    }

    /// Upcoming (or in-progress) events first, then earlier start, then identifier.
    static func chronologicallyBefore(_ lhs: EventReference, _ rhs: EventReference, now: Date) -> Bool {
        let leftPast = lhs.endDate <= now
        let rightPast = rhs.endDate <= now
        if leftPast != rightPast { return !leftPast }
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        return lhs.eventIdentifier < rhs.eventIdentifier
    }

    /// The query words that did not match any of `events` and are not stopwords — typically a date
    /// qualifier ("tomorrow's standup" -> "tomorrow").
    static func residualPhrase(query: String, events: [Scored]) -> String? {
        let matched = events.reduce(into: Set<String>()) { $0.formUnion($1.matchedWords) }
        let residual = TextTokens.words(query).filter { word in
            let stemmed = TextTokens.stem(word)
            return !matched.contains(stemmed) && !genericWords.contains(stemmed)
                && !["the", "a", "an", "my", "our", "with", "please", "calendar"].contains(word)
        }
        return residual.isEmpty ? nil : residual.joined(separator: " ")
    }
}
